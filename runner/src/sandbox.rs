//! Compiling and running untrusted Rust code.
//!
//! `Sandbox::Docker` is the production backend: every job runs in a fresh,
//! throwaway container with no network, a read-only root filesystem,
//! dropped capabilities, an unprivileged user, and CPU, memory, process
//! and time limits. The source code goes in over stdin, so nothing is
//! mounted from the host.
//!
//! `Sandbox::Local` runs `rustc` directly on the host. It is only for local
//! development and tests and must never face the internet.

use std::collections::HashSet;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::task::JoinHandle;

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
    /// Compiler errors in the compile stage; otherwise the program's own stderr.
    pub stderr: String,
    /// Compiler warnings, when compiling succeeded.
    pub warnings: String,
    pub duration_ms: u64,
}

#[derive(Debug, Clone)]
pub struct Limits {
    /// Wall-clock limit for compiling.
    pub compile_timeout: Duration,
    /// Wall-clock limit for running the compiled program.
    pub run_timeout: Duration,
    /// Wall-clock limit for the whole job, container start included.
    pub job_timeout: Duration,
    /// Maximum bytes kept from each of stdout, stderr and warnings.
    pub max_output: usize,
    pub memory_mb: u32,
    pub cpus: f32,
    pub max_pids: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            compile_timeout: Duration::from_secs(10),
            run_timeout: Duration::from_secs(5),
            job_timeout: Duration::from_secs(20),
            max_output: 64 * 1024,
            memory_mb: 512,
            cpus: 1.0,
            max_pids: 64,
        }
    }
}

impl Limits {
    /// Rejects settings that would switch a limit off or hang every job.
    pub fn validate(&self) -> Result<(), String> {
        let secs = |d: Duration| d.as_secs();
        if secs(self.compile_timeout) == 0 || secs(self.run_timeout) == 0 {
            return Err("compile and run timeouts must be at least 1 second".into());
        }
        let hour = Duration::from_secs(3600);
        if self.compile_timeout > hour || self.run_timeout > hour || self.job_timeout > hour {
            return Err("timeouts must be at most an hour".into());
        }
        if self.job_timeout < self.compile_timeout + self.run_timeout + Duration::from_secs(2) {
            return Err(
                "job timeout must exceed compile + run timeouts by at least 2 seconds".into(),
            );
        }
        if self.max_output == 0 || self.memory_mb < 64 || self.max_pids < 8 || self.cpus <= 0.0 {
            return Err("output, memory (>= 64 MB), pids (>= 8) and cpus must be positive".into());
        }
        Ok(())
    }
}

/// Exit codes the job script uses before the learner's program starts.
const COMPILE_FAILED: i32 = 201;
const COMPILE_KILLED: i32 = 202;
const TIMED_OUT: i32 = 124;
/// 128 + SIGKILL: out of memory, or the program ignored the polite stop.
const KILLED: i32 = 137;
/// 128 + SIGXCPU: the program used up its CPU-time limit.
const CPU_LIMIT: i32 = 152;
/// Most compiler output kept before the program starts (warnings are capped
/// again when reported); past this the job counts as a compile failure.
const MAX_COMPILER_OUTPUT: usize = 4 * 1024 * 1024;

/// Written to stdout and stderr once compiling succeeds, right before the
/// learner's program starts. The program can't take back what was written
/// before it ran, so its presence on stdout proves the compile step passed,
/// and on stderr it separates compiler warnings from the program's output.
const MARKER: &[u8] = b"\x01RR-RUN\n";

/// Shell script run for every job. The source code arrives on stdin.
/// `$1` is the compile timeout, `$2` the run timeout (seconds), `$3` a
/// writable work dir. The program replaces the shell with `exec`, so the
/// job's exit code is the program's (or `timeout`'s) own.
const JOB_SCRIPT: &str = r#"
csecs="$1"; secs="$2"; work="$3"
cat > "$work/main.rs"
timeout --signal=KILL "$csecs" rustc --edition 2024 -C opt-level=1 -C overflow-checks=on \
  -o "$work/prog" "$work/main.rs" 1>&2
rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$rc" -eq 137 ] && exit 202
  exit 201
fi
printf '\001RR-RUN\n'
printf '\001RR-RUN\n' >&2
# A CPU-time limit the kernel enforces, in case the program stops `timeout`.
# The soft limit sends SIGXCPU; the hard limit a second later sends SIGKILL.
ulimit -t "$((secs + 2))"
ulimit -S -t "$((secs + 1))"
exec timeout --signal=TERM --kill-after=1 "$secs" "$work/prog" </dev/null
"#;

pub enum Sandbox {
    Docker(DockerSandbox),
    Local,
}

pub struct DockerSandbox {
    pub image: String,
    /// Container runtime, e.g. `runsc` for gVisor. `None` uses Docker's default.
    pub runtime: Option<String>,
    /// Name prefix for this server's containers, so a watchdog can find leftovers.
    prefix: String,
    /// Containers of jobs still in progress.
    live: Arc<Mutex<HashSet<String>>>,
}

impl Sandbox {
    pub fn docker(image: impl Into<String>, runtime: Option<String>) -> Self {
        let id = uuid::Uuid::new_v4().simple().to_string();
        Sandbox::Docker(DockerSandbox {
            image: image.into(),
            runtime,
            prefix: format!("rr-{}-", &id[..8]),
            live: Arc::default(),
        })
    }

    pub async fn run(&self, code: &str, limits: &Limits) -> std::io::Result<RunOutput> {
        let started = Instant::now();
        // Local mode needs a work dir on the host; Docker uses the container's /tmp.
        let local_dir = match self {
            Sandbox::Local => Some(tempfile::tempdir()?),
            Sandbox::Docker(_) => None,
        };
        let (mut cmd, mut guard) = match self {
            Sandbox::Docker(d) => d.command(limits),
            Sandbox::Local => {
                let dir = local_dir.as_ref().expect("local dir").path();
                (local_command(dir, limits), ContainerGuard::none())
            }
        };

        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        if matches!(self, Sandbox::Local) {
            guard.group = child.id();
        }
        let handle = JobHandle {
            container: guard.name.clone(),
            group: guard.group,
        };

        let job = tokio::time::timeout(
            limits.job_timeout,
            collect(&mut child, &handle, code, limits),
        )
        .await;
        let duration_ms = started.elapsed().as_millis() as u64;

        let collected = match job {
            Ok(result) => result?,
            Err(_) => {
                let _ = child.start_kill();
                guard.remove_now().await;
                return Ok(RunOutput {
                    success: false,
                    stage: Stage::Timeout,
                    stdout: String::new(),
                    stderr: format!(
                        "Time limit exceeded: the job took longer than {} seconds.",
                        limits.job_timeout.as_secs()
                    ),
                    warnings: String::new(),
                    duration_ms,
                });
            }
        };
        if collected.overflow || collected.timed_out {
            guard.remove_now().await;
        } else {
            // The container exited by itself, so `--rm` cleans it up.
            guard.disarm();
        }
        interpret(collected, limits, duration_ms)
    }

    /// Removes containers this server started that no job owns any more,
    /// in case a cleanup was missed.
    pub async fn reap_orphans(&self) {
        let Sandbox::Docker(d) = self else { return };
        let filter = format!("name=^{}", d.prefix);
        let Some(out) =
            docker_quiet(&["ps", "-a", "--format", "{{.Names}}", "--filter", &filter]).await
        else {
            return;
        };
        let names: Vec<String> = String::from_utf8_lossy(&out)
            .lines()
            .map(str::to_string)
            .filter(|n| !d.live.lock().unwrap().contains(n))
            .collect();
        if !names.is_empty() {
            tracing::warn!("removing {} orphaned job containers", names.len());
            let mut args = vec!["rm", "-f"];
            args.extend(names.iter().map(String::as_str));
            docker_quiet(&args).await;
        }
    }

    /// The name prefix of this server's job containers (Docker mode only).
    pub fn container_prefix(&self) -> Option<&str> {
        match self {
            Sandbox::Docker(d) => Some(&d.prefix),
            Sandbox::Local => None,
        }
    }
}

/// Runs a Docker command for cleanup, giving up after 15 seconds so a hung
/// daemon can't block the server. Returns stdout, or None on failure.
async fn docker_quiet(args: &[&str]) -> Option<Vec<u8>> {
    let run = Command::new("docker")
        .args(args)
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(Duration::from_secs(15), run).await {
        Ok(Ok(out)) if out.status.success() => Some(out.stdout),
        _ => None,
    }
}

/// Removes every job container left by any earlier run of the server.
/// Call it at startup, before serving. It assumes one runner per Docker
/// daemon: it would also remove another runner's jobs.
pub async fn reap_all_job_containers() {
    let Some(out) = docker_quiet(&["ps", "-aq", "--filter", "name=^rr-"]).await else {
        return;
    };
    let ids: Vec<String> = String::from_utf8_lossy(&out)
        .lines()
        .map(str::to_string)
        .collect();
    if !ids.is_empty() {
        tracing::warn!(
            "removing {} job containers left from a previous run",
            ids.len()
        );
        let mut args = vec!["rm", "-f"];
        args.extend(ids.iter().map(String::as_str));
        docker_quiet(&args).await;
    }
}

/// Checks that Docker, the sandbox image and the runtime work, by running a
/// trivial program through the same path as real jobs. Call it at startup so
/// a broken setup fails loudly instead of answering every request with an
/// error. Limits are relaxed because the first compile can be slow.
pub async fn check_sandbox(sandbox: &Sandbox, limits: &Limits) -> Result<(), String> {
    let relaxed = Limits {
        compile_timeout: Duration::from_secs(60),
        run_timeout: limits.run_timeout,
        job_timeout: Duration::from_secs(60) + limits.run_timeout + Duration::from_secs(30),
        ..limits.clone()
    };
    match sandbox
        .run("fn main() { println!(\"ok\"); }", &relaxed)
        .await
    {
        Ok(out) if out.success && out.stdout == "ok\n" => Ok(()),
        Ok(out) => Err(format!(
            "sandbox check failed ({:?}): {}",
            out.stage,
            out.stderr.trim()
        )),
        Err(e) => Err(format!("sandbox check failed: {e}")),
    }
}

impl DockerSandbox {
    fn command(&self, limits: &Limits) -> (Command, ContainerGuard) {
        let name = format!("{}{}", self.prefix, uuid::Uuid::new_v4().simple());
        let mut cmd = Command::new("docker");
        cmd.args(["run", "-i", "--rm", "--init", "--name", &name])
            .args(["--pull", "never", "--log-driver", "none"])
            .args(["--network", "none", "--ipc", "none"])
            .args(["--memory", &format!("{}m", limits.memory_mb)])
            .args(["--memory-swap", &format!("{}m", limits.memory_mb)])
            .args(["--cpus", &limits.cpus.to_string()])
            .args(["--pids-limit", &limits.max_pids.to_string()])
            .args(["--ulimit", "core=0"])
            .args(["--read-only", "--tmpfs", "/tmp:rw,exec,size=128m,mode=1777"])
            .args(["--cap-drop", "ALL", "--security-opt", "no-new-privileges"])
            .args(["--user", "65534:65534"]);
        if let Some(runtime) = &self.runtime {
            cmd.args(["--runtime", runtime]);
        }
        cmd.arg(&self.image)
            .args(["bash", "-c", JOB_SCRIPT, "job"])
            .arg(limits.compile_timeout.as_secs().to_string())
            .arg(limits.run_timeout.as_secs().to_string())
            .arg("/tmp");
        self.live.lock().unwrap().insert(name.clone());
        (
            cmd,
            ContainerGuard {
                name: Some(name),
                live: Some(self.live.clone()),
                group: None,
            },
        )
    }
}

fn local_command(dir: &std::path::Path, limits: &Limits) -> Command {
    let mut cmd = Command::new("bash");
    cmd.args(["-c", JOB_SCRIPT, "job"])
        .arg(limits.compile_timeout.as_secs().to_string())
        .arg(limits.run_timeout.as_secs().to_string())
        .arg(dir);
    // Own process group, so the whole job can be killed at once.
    #[cfg(unix)]
    cmd.process_group(0);
    cmd
}

/// Cleans up after a job when it ends any way other than finishing by
/// itself: timeout, output overflow, an error, or the client disconnecting
/// (which drops the request future). In Docker mode it force-removes the
/// container; in local mode it kills the job's process group.
struct ContainerGuard {
    name: Option<String>,
    live: Option<Arc<Mutex<HashSet<String>>>>,
    /// Local mode: the job's process group. Always killed on drop, since a
    /// learner program may outlive the shell that started it.
    group: Option<u32>,
}

impl ContainerGuard {
    fn none() -> Self {
        Self {
            name: None,
            live: None,
            group: None,
        }
    }

    fn disarm(&mut self) {
        if let (Some(name), Some(live)) = (self.name.take(), &self.live) {
            live.lock().unwrap().remove(&name);
        }
    }

    async fn remove_now(&mut self) {
        // Keep the name until the rm finishes: if this future is dropped
        // part-way, Drop still removes the container and forgets the name.
        if let Some(name) = self.name.clone() {
            docker_quiet(&["rm", "-f", &name]).await;
            self.name = None;
            if let Some(live) = &self.live {
                live.lock().unwrap().remove(&name);
            }
        }
    }
}

impl Drop for ContainerGuard {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.group.take() {
            let _ = std::process::Command::new("kill")
                .args(["-KILL", "--", &format!("-{pid}")])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        let Some(name) = self.name.take() else { return };
        if let Some(live) = &self.live {
            live.lock().unwrap().remove(&name);
        }
        let remove = move || {
            let _ = std::process::Command::new("docker")
                .args(["rm", "-f", &name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        };
        match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                handle.spawn_blocking(remove);
            }
            Err(_) => {
                std::thread::spawn(remove);
            }
        }
    }
}

struct Collected {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    overflow: bool,
    /// The host-side run timer fired.
    timed_out: bool,
    code: Option<i32>,
}

/// Sends the code, then reads both output streams with a hard byte cap.
/// If either stream goes over the cap, the job is killed.
/// How to stop every process of a job, not just the `docker` CLI or shell.
struct JobHandle {
    container: Option<String>,
    group: Option<u32>,
}

impl JobHandle {
    async fn kill(&self, child: &mut Child) {
        if let Some(name) = &self.container {
            docker_quiet(&["kill", name]).await;
        }
        #[cfg(unix)]
        if let Some(pid) = self.group {
            let _ = Command::new("kill")
                .args(["-KILL", "--", &format!("-{pid}")])
                .output()
                .await;
        }
        let _ = child.start_kill();
    }
}

async fn collect(
    child: &mut Child,
    job: &JobHandle,
    code: &str,
    limits: &Limits,
) -> std::io::Result<Collected> {
    let mut stdin = child.stdin.take().expect("piped stdin");
    let source = code.as_bytes().to_vec();
    let writer = tokio::spawn(async move {
        let _ = stdin.write_all(&source).await;
        let _ = stdin.shutdown().await;
    });

    // stderr carries compiler warnings and the program's stderr.
    let out_cap = limits.max_output + MARKER.len();

    // The run timer starts when the program does (the marker on stdout). It
    // backs up the in-container `timeout`, which the program could freeze.
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let run_limit = limits.run_timeout + Duration::from_secs(2);
    let run_deadline = async move {
        if started_rx.await.is_ok() {
            tokio::time::sleep(run_limit).await;
        } else {
            std::future::pending::<()>().await;
        }
    };
    tokio::pin!(run_deadline);
    let mut out_task: ReadTask = Some(tokio::spawn(read_capped(
        child.stdout.take().expect("stdout"),
        out_cap,
        Some(started_tx),
    )));
    let mut err_task: ReadTask = Some(tokio::spawn(read_stderr(
        child.stderr.take().expect("stderr"),
        limits.max_output,
    )));
    let mut stdout = None;
    let mut stderr = None;
    let mut overflow = false;
    let mut timed_out = false;

    let result = async {
        while !overflow && !timed_out && (stdout.is_none() || stderr.is_none()) {
            tokio::select! {
                _ = &mut run_deadline => timed_out = true,
                r = join(&mut out_task), if stdout.is_none() => {
                    let (buf, over) = r?;
                    overflow |= over;
                    stdout = Some(buf);
                }
                r = join(&mut err_task), if stderr.is_none() => {
                    let (buf, over) = r?;
                    overflow |= over;
                    stderr = Some(buf);
                }
            }
        }
        if overflow || timed_out {
            job.kill(child).await;
        }
        let status = child.wait().await?;
        // After the process ends the other stream reaches EOF quickly.
        if stdout.is_none() {
            stdout = Some(finish(&mut out_task).await);
        }
        if stderr.is_none() {
            stderr = Some(finish(&mut err_task).await);
        }
        // A process killed by a signal has no exit code; report it the way a
        // shell does (128 + signal) so it is treated as stopped or timed out.
        use std::os::unix::process::ExitStatusExt;
        Ok::<_, std::io::Error>(status.code().or_else(|| status.signal().map(|s| 128 + s)))
    }
    .await;

    writer.abort();
    for task in [out_task, err_task].into_iter().flatten() {
        task.abort();
    }
    let code = result?;
    Ok(Collected {
        stdout: stdout.unwrap_or_default(),
        stderr: stderr.unwrap_or_default(),
        overflow,
        timed_out,
        code,
    })
}

type ReadTask = Option<JoinHandle<std::io::Result<(Vec<u8>, bool)>>>;

async fn join(task: &mut ReadTask) -> std::io::Result<(Vec<u8>, bool)> {
    let handle = task.as_mut().expect("task polled after completion");
    let result = handle.await.map_err(std::io::Error::other)?;
    *task = None;
    result
}

/// Collects what's left of a stream after the process ended, briefly.
async fn finish(task: &mut ReadTask) -> Vec<u8> {
    match tokio::time::timeout(Duration::from_secs(2), join(task)).await {
        Ok(Ok((buf, _))) => buf,
        _ => Vec::new(),
    }
}

async fn read_capped<R: AsyncRead + Unpin>(
    mut reader: R,
    cap: usize,
    mut started: Option<tokio::sync::oneshot::Sender<()>>,
) -> std::io::Result<(Vec<u8>, bool)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let n = reader.read(&mut chunk).await?;
        if n == 0 {
            return Ok((buf, false));
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.len() >= MARKER.len()
            && let Some(tx) = started.take()
            && buf.starts_with(MARKER)
        {
            let _ = tx.send(());
        }
        if buf.len() > cap {
            buf.truncate(cap);
            return Ok((buf, true));
        }
    }
}

/// Reads stderr: compiler output first, then (after the marker) the
/// program's own stderr. Only the program part is capped tightly; a long
/// compiler output doesn't stop the job, it's trimmed when reported.
async fn read_stderr<R: AsyncRead + Unpin>(
    mut reader: R,
    max: usize,
) -> std::io::Result<(Vec<u8>, bool)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let mut searched: usize = 0;
    let mut program_start: Option<usize> = None;
    loop {
        let n = reader.read(&mut chunk).await?;
        if n == 0 {
            return Ok((buf, false));
        }
        buf.extend_from_slice(&chunk[..n]);
        if program_start.is_none() {
            let from = searched.saturating_sub(MARKER.len() - 1);
            if let Some(i) = find(&buf[from..], MARKER) {
                program_start = Some(from + i + MARKER.len());
            } else {
                searched = buf.len();
                if buf.len() > MAX_COMPILER_OUTPUT {
                    buf.truncate(MAX_COMPILER_OUTPUT);
                    return Ok((buf, true));
                }
            }
        }
        if let Some(start) = program_start
            && buf.len() - start > max
        {
            buf.truncate(start + max);
            return Ok((buf, true));
        }
    }
}

fn interpret(c: Collected, limits: &Limits, duration_ms: u64) -> std::io::Result<RunOutput> {
    let max = limits.max_output;
    let compiled = c.stdout.starts_with(MARKER);

    if !compiled {
        let stderr = text(&c.stderr, max, c.overflow);
        let (stage, stderr) = match c.code {
            _ if c.overflow => (Stage::Compile, stderr),
            Some(COMPILE_FAILED) => (Stage::Compile, stderr),
            Some(COMPILE_KILLED) => (
                Stage::Timeout,
                format!(
                    "{stderr}\nCompiling was stopped: it took longer than {} seconds or used too much memory.",
                    limits.compile_timeout.as_secs()
                ),
            ),
            // Anything else (Docker's own 125-127 included) means the job
            // never got going: a server problem, not the learner's.
            other => {
                return Err(std::io::Error::other(format!(
                    "job failed before compiling (exit {other:?}): {}",
                    String::from_utf8_lossy(&c.stderr[..c.stderr.len().min(500)])
                )));
            }
        };
        return Ok(RunOutput {
            success: false,
            stage,
            stdout: String::new(),
            stderr: stderr.trim().to_string(),
            warnings: String::new(),
            duration_ms,
        });
    }

    let stdout = &c.stdout[MARKER.len()..];
    let (warnings, program_err) = match find(&c.stderr, MARKER) {
        Some(i) => (&c.stderr[..i], &c.stderr[i + MARKER.len()..]),
        None => (&c.stderr[..], &[][..]),
    };
    let stdout = text(stdout, max, c.overflow && stdout.len() >= max);
    let mut stderr = text(program_err, max, c.overflow && program_err.len() >= max);

    let (success, stage) = if c.timed_out {
        stderr.push_str(&format!(
            "\nTime limit exceeded: the program ran longer than {} seconds.",
            limits.run_timeout.as_secs()
        ));
        (false, Stage::Timeout)
    } else if c.overflow {
        stderr.push_str("\nThe program was stopped because it printed too much output.");
        (false, Stage::Run)
    } else {
        match c.code {
            Some(0) => (true, Stage::Run),
            Some(TIMED_OUT) | Some(CPU_LIMIT) => {
                stderr.push_str(&format!(
                    "\nTime limit exceeded: the program ran longer than {} seconds.",
                    limits.run_timeout.as_secs()
                ));
                (false, Stage::Timeout)
            }
            Some(KILLED) => {
                stderr.push_str(
                    "\nThe program was stopped: it used too much memory or didn't stop at the time limit.",
                );
                (false, Stage::Run)
            }
            _ => (false, Stage::Run),
        }
    };

    Ok(RunOutput {
        success,
        stage,
        stdout,
        stderr: stderr.trim_start().to_string(),
        warnings: text(warnings, max, false).trim().to_string(),
        duration_ms,
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn text(bytes: &[u8], max: usize, truncated: bool) -> String {
    let slice = &bytes[..bytes.len().min(max)];
    let mut s = String::from_utf8_lossy(slice).into_owned();
    if truncated || bytes.len() > max {
        s.push_str("\n[output truncated]");
    }
    s
}
