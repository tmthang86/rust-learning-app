//! Grading with the host's `rustc`, for `tool/check_lessons.py` (through the
//! `rr-grade` binary) and for this crate's own tests.
//!
//! It takes the same steps as the runner's job script, with plain
//! `std::process`: it works on macOS too, and like the old checker it is
//! **not a sandbox**. Only run lesson content you trust. Time and output
//! limits are the runner's (compile 10 s, run 5 s, 64 KB of output); there is
//! no address-space cap.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::classify::{CheckResult, ErrorsIn, classify_compile, learner_warnings};
use crate::generate::{RUN_ARGS, build};
use crate::results::{End, EndState, MainStatus, results};
use crate::{Response, Stage, Status, TestResult, TestSpec, validate};

/// The flags `/run` compiles with (`runner/src/sandbox.rs`): used for the
/// learner-only check, whose text must match `/run`'s.
const FLAGS: [&str; 6] = [
    "--edition",
    "2024",
    "-C",
    "opt-level=1",
    "-C",
    "overflow-checks=on",
];

/// The flags of the combined build (the job script's grade block).
const GRADE_FLAGS: [&str; 6] = [
    "--edition",
    "2024",
    "-C",
    "opt-level=0",
    "-C",
    "overflow-checks=on",
];

/// Most bytes read from rustc's output (JSON diagnostics can be long).
const COMPILE_CAPTURE: usize = 4 * 1024 * 1024;
/// Most bytes read from the graded program, as in the runner.
const RUN_CAPTURE: usize = 64 * 1024;

#[derive(Debug, Clone)]
pub struct Options {
    /// The compiler to run.
    pub rustc: String,
    /// Wall-clock limit for compiling.
    pub compile_timeout: Duration,
    /// Wall-clock limit for the learner-only check and for running.
    pub run_timeout: Duration,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            rustc: "rustc".into(),
            compile_timeout: Duration::from_secs(10),
            run_timeout: Duration::from_secs(5),
        }
    }
}

struct Captured {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    status: Option<ExitStatus>,
    timed_out: bool,
    overflow: bool,
}

fn read_all<R: Read + Send + 'static>(
    mut reader: R,
    cap: usize,
    overflow: Arc<AtomicBool>,
) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            match reader.read(&mut chunk) {
                Ok(0) | Err(_) => return buf,
                Ok(n) => {
                    if buf.len() + n > cap {
                        overflow.store(true, Ordering::SeqCst);
                        // Keep draining so the child can finish being killed.
                        continue;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
            }
        }
    })
}

#[cfg(unix)]
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

/// Kills the child and everything it started: it leads its own process
/// group, so a grandchild holding the output pipes can't make us wait.
fn kill_group(child: &mut std::process::Child) {
    #[cfg(unix)]
    {
        // SAFETY: a plain signal to the process group the child leads.
        unsafe {
            kill(-(child.id() as i32), 9);
        }
    }
    let _ = child.kill();
}

fn run_capped(cmd: &mut Command, timeout: Duration, cap: usize) -> std::io::Result<Captured> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let overflow = Arc::new(AtomicBool::new(false));
    let out = read_all(child.stdout.take().expect("piped"), cap, overflow.clone());
    let err = read_all(child.stderr.take().expect("piped"), cap, overflow.clone());
    let started = Instant::now();
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            // Whatever it left running goes too.
            kill_group(&mut child);
            break Some(status);
        }
        if started.elapsed() > timeout {
            timed_out = true;
        }
        if timed_out || overflow.load(Ordering::SeqCst) {
            kill_group(&mut child);
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    Ok(Captured {
        stdout: out.join().unwrap_or_default(),
        stderr: err.join().unwrap_or_default(),
        status,
        timed_out,
        overflow: overflow.load(Ordering::SeqCst),
    })
}

fn exit_code(status: &ExitStatus) -> i32 {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        status
            .code()
            .or_else(|| status.signal().map(|s| 128 + s))
            .unwrap_or(-1)
    }
    #[cfg(not(unix))]
    {
        status.code().unwrap_or(-1)
    }
}

/// A directory removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new() -> std::io::Result<Self> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let dir = std::env::temp_dir().join(format!("rr-grade-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(dir.join("g"))?;
        Ok(Self(dir))
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// 32 hex digits from the OS's random source (a time-based value if it
/// can't be read).
fn nonce() -> String {
    let mut bytes = [0u8; 16];
    let ok = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .is_ok();
    if !ok {
        use std::hash::{BuildHasher, Hasher};
        for chunk in bytes.chunks_mut(8) {
            let mut h = std::collections::hash_map::RandomState::new().build_hasher();
            h.write_u128(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |d| d.as_nanos()),
            );
            chunk.copy_from_slice(&h.finish().to_le_bytes()[..chunk.len()]);
        }
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn not_run(ids: &[String], stage: Stage, stderr: String, ms: u64) -> Response {
    Response {
        success: false,
        stage,
        duration_ms: ms,
        stdout: String::new(),
        stderr,
        warnings: String::new(),
        compile_errors_in: None,
        reason: None,
        tests: ids
            .iter()
            .map(|id| TestResult::new(id, Status::NotRun))
            .collect(),
    }
}

/// Compiles and runs `code` against `tests`. `Err` means the request itself
/// is bad (see [`validate`]) or the host couldn't run the compiler.
pub fn grade(code: &str, tests: &[TestSpec], opts: &Options) -> Result<Response, String> {
    validate(tests)?;
    if code.trim().is_empty() {
        return Err("code is empty".into());
    }
    let started = Instant::now();
    let g = build(code, tests, &nonce());
    let dir = TempDir::new().map_err(|e| format!("could not make a temp dir: {e}"))?;
    let work = dir.path();
    let combined = work.join("g").join("main.rs");
    std::fs::write(&combined, &g.source).map_err(|e| e.to_string())?;
    let ms = |s: Instant| s.elapsed().as_millis() as u64;
    let spawn_err = |e: std::io::Error| format!("could not run {}: {e}", opts.rustc);

    let mut compile = Command::new(&opts.rustc);
    compile
        .args(GRADE_FLAGS)
        .arg("--test")
        .arg("--error-format=json")
        .arg("--remap-path-prefix")
        .arg(format!("{}={}", work.join("g").display(), work.display()))
        .arg("-o")
        .arg(work.join("prog"))
        .arg(&combined);
    let built =
        run_capped(&mut compile, opts.compile_timeout, COMPILE_CAPTURE).map_err(spawn_err)?;
    let json = String::from_utf8_lossy(&built.stderr).into_owned();

    if built.timed_out || built.overflow {
        return Ok(not_run(
            &g.ids,
            Stage::Timeout,
            "Compiling was stopped: it took too long or printed too much.".into(),
            ms(started),
        ));
    }
    if !built.status.is_some_and(|s| s.success()) {
        // Same as the job script: the learner's code alone, human output.
        let learner = work.join("main.rs");
        std::fs::write(&learner, &g.source.as_bytes()[..g.learner_bytes])
            .map_err(|e| e.to_string())?;
        let mut check = Command::new(&opts.rustc);
        check
            .args(FLAGS)
            .arg("--emit=mir")
            .arg("-o")
            .arg(work.join("l.mir"))
            .arg(&learner);
        let checked =
            run_capped(&mut check, opts.run_timeout, COMPILE_CAPTURE).map_err(spawn_err)?;
        let check = if checked.timed_out || checked.overflow {
            None
        } else {
            Some(CheckResult {
                passed: checked.status.is_some_and(|s| s.success()),
                text: String::from_utf8_lossy(&checked.stderr).into_owned(),
            })
        };
        let verdict = classify_compile(&g, &json, check.as_ref());
        return Ok(Response {
            success: false,
            stage: Stage::Compile,
            duration_ms: ms(started),
            stdout: String::new(),
            stderr: verdict.stderr,
            warnings: String::new(),
            compile_errors_in: Some(verdict.errors_in),
            reason: verdict.reason,
            tests: verdict.tests,
        });
    }
    let warnings = learner_warnings(&g, &json);

    // The sources are gone before the program starts, as in the sandbox.
    let _ = std::fs::remove_dir_all(work.join("g"));
    let _ = std::fs::remove_file(work.join("main.rs"));
    let mut run = Command::new(work.join("prog"));
    run.args(RUN_ARGS);
    let ran = run_capped(&mut run, opts.run_timeout, RUN_CAPTURE)
        .map_err(|e| format!("could not run the program: {e}"))?;
    let stdout = String::from_utf8_lossy(&ran.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&ran.stderr).into_owned();
    let code = ran.status.as_ref().map_or(-1, exit_code);
    let end = EndState {
        end: if ran.timed_out {
            End::TimedOut
        } else if ran.overflow {
            End::OutputLimit
        } else {
            End::Exited(code)
        },
        stack_overflow: stderr.contains("has overflowed its stack"),
    };
    let verdict = results(&g, &stdout, &end);
    let finished = matches!(end.end, End::Exited(0)) && verdict.main == MainStatus::Ok;
    Ok(Response {
        success: finished,
        stage: if ran.timed_out {
            Stage::Timeout
        } else {
            Stage::Run
        },
        duration_ms: ms(started),
        stdout: verdict.main_stdout,
        stderr,
        warnings,
        compile_errors_in: None::<ErrorsIn>,
        reason: verdict.reason,
        tests: verdict.tests,
    })
}
