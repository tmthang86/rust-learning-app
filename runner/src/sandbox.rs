//! Compiling and running untrusted Rust code.
//!
//! `DockerSandbox` is the production backend: every job runs in a fresh,
//! throwaway container with no network, a read-only root filesystem,
//! dropped capabilities, an unprivileged user, and CPU, memory, process
//! and time limits.
//!
//! `LocalSandbox` runs `rustc` directly on the host. It is only for local
//! development and tests and must never face the internet.

use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::process::Command;

/// How far a job got.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    /// Compilation failed; `stderr` holds the compiler output.
    Compile,
    /// The program was compiled and ran (it may still have panicked).
    Run,
    /// The job hit a time limit.
    Timeout,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunOutput {
    pub success: bool,
    pub stage: Stage,
    pub stdout: String,
    pub stderr: String,
    pub duration_ms: u64,
}

#[derive(Debug, Clone)]
pub struct Limits {
    /// Wall-clock limit for running the compiled program.
    pub run_timeout: Duration,
    /// Wall-clock limit for the whole job, compile included.
    pub job_timeout: Duration,
    /// Maximum bytes kept from each of stdout and stderr.
    pub max_output: usize,
    pub memory_mb: u32,
    pub cpus: f32,
    pub max_pids: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            run_timeout: Duration::from_secs(5),
            job_timeout: Duration::from_secs(20),
            max_output: 64 * 1024,
            memory_mb: 512,
            cpus: 1.0,
            max_pids: 64,
        }
    }
}

/// Exit code the job script uses to signal a compile error. Chosen to avoid
/// clashing with rustc (1), panics (101) and `timeout` (124).
const COMPILE_FAILED: i32 = 201;
const TIMED_OUT: i32 = 124;
/// 128 + SIGKILL: the kernel's out-of-memory killer, or a program that
/// ignored the polite stop at the time limit.
const KILLED: i32 = 137;

/// Shell script run for every job. `$1` is the source file, `$2` the run
/// timeout in seconds, `$3` the output cap in bytes and `$4` a writable
/// work dir. Output from both the compiler and the program is capped with
/// `head` so a program printing in a loop can't exhaust memory.
///
/// Only plain pipelines are used, because bash waits for every stage of a
/// pipeline; with `>(...)` it may exit before a helper flushes its output.
/// For the run step, stderr is swapped onto the inner pipe and stdout onto
/// fd 3 so each stream gets its own cap, and the exit code goes through a
/// file because it can't escape the outer pipeline.
const JOB_SCRIPT: &str = r#"
src="$1"; secs="$2"; cap="$3"; work="$4"
rustc --edition 2024 -C opt-level=1 -o "$work/prog" "$src" 2>&1 >/dev/null | head -c "$cap" >&2
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 201
{ timeout --signal=TERM --kill-after=1 "$secs" "$work/prog" 2>&1 1>&3 3>&- | head -c "$cap" >&2
  echo "${PIPESTATUS[0]}" > "$work/rc"; } 3>&1 | head -c "$cap"
exit "$(cat "$work/rc")"
"#;

pub enum Sandbox {
    Docker { image: String },
    Local,
}

impl Sandbox {
    pub async fn run(&self, code: &str, limits: &Limits) -> std::io::Result<RunOutput> {
        let dir = tempfile::tempdir()?;
        let src = dir.path().join("main.rs");
        tokio::fs::write(&src, code).await?;
        make_readable(dir.path()).await?;

        let (mut cmd, container) = match self {
            Sandbox::Docker { image } => docker_command(image, dir.path(), limits),
            Sandbox::Local => (local_command(&src, dir.path(), limits), None),
        };

        let started = Instant::now();
        let child = cmd
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;

        let result = tokio::time::timeout(limits.job_timeout, child.wait_with_output()).await;
        let duration_ms = started.elapsed().as_millis() as u64;

        let output = match result {
            Ok(output) => output?,
            Err(_) => {
                // The docker CLI being killed doesn't stop the container.
                if let Some(name) = container {
                    let _ = Command::new("docker").args(["rm", "-f", &name]).output().await;
                }
                return Ok(RunOutput {
                    success: false,
                    stage: Stage::Timeout,
                    stdout: String::new(),
                    stderr: format!(
                        "Time limit exceeded: the job took longer than {} seconds.",
                        limits.job_timeout.as_secs()
                    ),
                    duration_ms,
                });
            }
        };

        let stdout = truncate(&output.stdout, limits.max_output);
        let mut stderr = truncate(&output.stderr, limits.max_output);
        let code = output.status.code();

        let (success, stage) = match code {
            Some(0) => (true, Stage::Run),
            Some(COMPILE_FAILED) => (false, Stage::Compile),
            Some(TIMED_OUT) => {
                stderr.push_str(&format!(
                    "\nTime limit exceeded: the program ran longer than {} seconds.",
                    limits.run_timeout.as_secs()
                ));
                (false, Stage::Timeout)
            }
            Some(KILLED) => {
                stderr.push_str("\nThe program was stopped because it used too much memory.");
                (false, Stage::Run)
            }
            _ => (false, Stage::Run),
        };

        Ok(RunOutput { success, stage, stdout, stderr: stderr.trim_start().to_string(), duration_ms })
    }
}

fn docker_command(image: &str, dir: &Path, limits: &Limits) -> (Command, Option<String>) {
    let name = format!("rr-{}", uuid::Uuid::new_v4());
    let mut cmd = Command::new("docker");
    cmd.args(["run", "--rm", "--name", &name])
        .args(["--network", "none"])
        .args(["--memory", &format!("{}m", limits.memory_mb)])
        .args(["--memory-swap", &format!("{}m", limits.memory_mb)])
        .args(["--cpus", &limits.cpus.to_string()])
        .args(["--pids-limit", &limits.max_pids.to_string()])
        .args(["--read-only", "--tmpfs", "/tmp:rw,exec,size=128m,mode=1777"])
        .args(["--cap-drop", "ALL", "--security-opt", "no-new-privileges"])
        .args(["--user", "65534:65534"])
        .args(["-v", &format!("{}:/src:ro", dir.display())])
        .arg(image)
        .args(["bash", "-c", JOB_SCRIPT, "job", "/src/main.rs"])
        .arg(limits.run_timeout.as_secs().to_string())
        .arg(limits.max_output.to_string())
        .arg("/tmp");
    (cmd, Some(name))
}

fn local_command(src: &Path, dir: &Path, limits: &Limits) -> Command {
    let mut cmd = Command::new("bash");
    cmd.args(["-c", JOB_SCRIPT, "job"])
        .arg(src)
        .arg(limits.run_timeout.as_secs().to_string())
        .arg(limits.max_output.to_string())
        .arg(dir);
    cmd
}

/// The container runs as `nobody`, so the mounted job dir must be readable.
async fn make_readable(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o755)).await?;
        tokio::fs::set_permissions(dir.join("main.rs"), std::fs::Permissions::from_mode(0o644))
            .await?;
    }
    Ok(())
}

fn truncate(bytes: &[u8], max: usize) -> String {
    let slice = &bytes[..bytes.len().min(max)];
    let mut text = String::from_utf8_lossy(slice).into_owned();
    if bytes.len() >= max {
        text.push_str("\n[output truncated]");
    }
    text
}
