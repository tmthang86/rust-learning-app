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
    /// The job was stopped for using too much memory. Not sent to clients.
    #[serde(skip)]
    pub mem_limit: bool,
    /// The sandbox gave a real compiler verdict (the program started, or the
    /// compiler reported errors), which proves it is working. Server health
    /// counts only these. Not sent to clients.
    #[serde(skip)]
    pub compiler_verdict: bool,
    /// Output was cut: the server's own byte cap was hit (or a stream was
    /// longer than the cap). Used for logs; not sent to clients.
    #[serde(skip)]
    pub truncated: bool,
}

impl RunOutput {
    fn new(success: bool, stage: Stage, duration_ms: u64) -> Self {
        Self {
            success,
            stage,
            stdout: String::new(),
            stderr: String::new(),
            warnings: String::new(),
            duration_ms,
            mem_limit: false,
            compiler_verdict: false,
            truncated: false,
        }
    }
}

/// The answer to `POST /grade`: the `/run` fields plus the per-test results.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GradeOutput {
    #[serde(flatten)]
    pub run: RunOutput,
    /// Where the compile errors are: the learner's code or the tests.
    pub compile_errors_in: Option<rr_grade::ErrorsIn>,
    /// A machine code for a problem that is not about one test (`no_main`,
    /// `harness`, or why a test crashed).
    pub reason: Option<String>,
    /// One result per requested test, in request order.
    pub tests: Vec<rr_grade::TestResult>,
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
    /// Size of the writable `/tmp` tmpfs. Its pages count toward the
    /// container's memory, so it also shrinks the program's address-space cap.
    pub tmpfs_mb: u32,
    pub cpus: f32,
    pub max_pids: u32,
}

/// Slack kept between the program's address-space cap and the container's
/// memory limit, on top of a full tmpfs (sandbox overhead). See
/// [`Limits::program_vmem_kb`].
const SANDBOX_OVERHEAD_MB: u32 = 64;
/// The smallest address space a learner program may get.
const MIN_PROGRAM_MB: u32 = 128;

impl Default for Limits {
    fn default() -> Self {
        Self {
            compile_timeout: Duration::from_secs(10),
            run_timeout: Duration::from_secs(5),
            job_timeout: Duration::from_secs(20),
            max_output: 64 * 1024,
            memory_mb: 512,
            tmpfs_mb: 128,
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
        if self.max_output == 0 || self.max_pids < 8 || self.cpus <= 0.0 || self.tmpfs_mb < 8 {
            return Err("output, tmpfs (>= 8 MB), pids (>= 8) and cpus must be positive".into());
        }
        let floor = self.tmpfs_mb + SANDBOX_OVERHEAD_MB + MIN_PROGRAM_MB;
        if self.memory_mb < floor {
            return Err(format!(
                "memory must be at least {floor} MB (tmpfs {} MB + {SANDBOX_OVERHEAD_MB} MB overhead + {MIN_PROGRAM_MB} MB for the program)",
                self.tmpfs_mb
            ));
        }
        Ok(())
    }

    /// Address-space cap for the learner's program, in KB (for `ulimit -v`):
    /// `memory - tmpfs - 64 MB`. Pages in the `/tmp` tmpfs count toward the
    /// sandbox's memory but not toward the program's address space, so the
    /// cap leaves room for a full tmpfs plus sandbox overhead. 320 MB at the
    /// defaults. Only the program is capped, never rustc.
    pub fn program_vmem_kb(&self) -> u64 {
        let mb = self
            .memory_mb
            .saturating_sub(self.tmpfs_mb + SANDBOX_OVERHEAD_MB);
        u64::from(mb) * 1024
    }
}

/// Exit codes the job script uses before the learner's program starts.
const COMPILE_FAILED: i32 = 201;
const COMPILE_KILLED: i32 = 202;
const TIMED_OUT: i32 = 124;
/// 128 + SIGKILL: out of memory, or the program ignored the polite stop.
const KILLED: i32 = 137;
/// 128 + SIGABRT: the program aborted, e.g. after a failed allocation.
const ABORTED: i32 = 134;
/// What Rust's allocator prints before aborting when an allocation fails.
const ALLOC_FAILED: &str = "memory allocation of";
/// 128 + SIGXCPU: the program used up its CPU-time limit.
const CPU_LIMIT: i32 = 152;
/// Most compiler output kept before the program starts (warnings are capped
/// again when reported); past this the job counts as a compile failure.
const MAX_COMPILER_OUTPUT: usize = 4 * 1024 * 1024;

/// Written to stdout right before `rustc` starts. Learner code can't print
/// before it, so its presence proves the job script itself got going. A job
/// without it never started (docker CLI killed, daemon restart, ...) and is a
/// server error, not the learner's.
const COMPILE_MARKER: &[u8] = b"\x01RR-COMPILE\n";

/// Written to stdout and stderr once compiling succeeds, right before the
/// learner's program starts. The program can't take back what was written
/// before it ran, so its presence on stdout (right after the compile marker)
/// proves the compile step passed, and on stderr it separates compiler
/// warnings from the program's output.
const RUN_MARKER: &[u8] = b"\x01RR-RUN\n";

/// What successful stdout starts with.
fn both_markers() -> Vec<u8> {
    [COMPILE_MARKER, RUN_MARKER].concat()
}

/// Shell script run for every job. The source code arrives on stdin.
/// `$1` is the compile timeout, `$2` the run timeout (seconds), `$3` a
/// writable work dir, `$4` the program's address-space cap in KB. `$5` is
/// the mode: absent or `run` for `/run`, `grade` for `/grade` (see the grade
/// block below; `/run` never reaches it). The program
/// replaces the shell with `exec`, so the job's exit code is the program's
/// (or `timeout`'s) own. The cap is set after compiling, so rustc is bound
/// only by the container's memory limit.
const JOB_SCRIPT: &str = r#"
csecs="$1"; secs="$2"; work="$3"; vmem="$4"
if [ "${5:-run}" = grade ]; then
  # Grade mode (POST /grade). $6: the learner's code length in bytes (the
  # first bytes of the file on stdin), $7: RUST_MIN_STACK for the program,
  # the rest: the test harness's own arguments. The file holds the learner's
  # code plus the generated harness; see rr-grade.
  llen="$6"; stack="$7"; shift 7
  mkdir -p "$work/g"
  cat > "$work/g/main.rs"
  printf '\001RR-COMPILE\n'
  { timeout --signal=KILL "$csecs" rustc --edition 2024 -C opt-level=1 -C overflow-checks=on \
    --test --error-format=json --remap-path-prefix "$work/g=$work" \
    -o "$work/prog" "$work/g/main.rs" 1>&3 2>&3; } 3>&2 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 137 ] && exit 202
    # Whose error is it? Compile the learner's code alone, as /run would
    # (--emit=mir finds the same errors as a full build). Its output follows
    # the RR-CHECK marker on stderr, its exit code comes after the marker on
    # stdout.
    head -c "$llen" "$work/g/main.rs" > "$work/main.rs"
    printf '\001RR-CHECK\n'
    printf '\001RR-CHECK\n' >&2
    { timeout --signal=KILL "$secs" rustc --edition 2024 -C opt-level=1 -C overflow-checks=on \
      --emit=mir -o "$work/l.mir" "$work/main.rs" 1>&3 2>&3; } 3>&2 2>/dev/null
    printf '\001RR-CHECK:%s\n' "$?"
    exit 201
  fi
  printf '\001RR-RUN\n'
  printf '\001RR-RUN\n' >&2
  # No source is left for the program to read.
  rm -rf "$work/g" "$work/main.rs"
  ulimit -t "$((secs + 2))"
  ulimit -S -t "$((secs + 1))"
  ulimit -v "$vmem"
  RUST_MIN_STACK="$stack" exec timeout --signal=TERM --kill-after=1 "$secs" "$work/prog" "$@" </dev/null
fi
cat > "$work/main.rs"
printf '\001RR-COMPILE\n'
# When `timeout` kills rustc it dies of SIGKILL too, and bash would print
# "job: line N: PID Killed ..." to the learner. The group sends the shell's
# own stderr to /dev/null while rustc's output goes to the real stderr (fd 3).
{ timeout --signal=KILL "$csecs" rustc --edition 2024 -C opt-level=1 -C overflow-checks=on \
  -o "$work/prog" "$work/main.rs" 1>&3 2>&3; } 3>&2 2>/dev/null
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
# Cap the program's address space (KB). Under gVisor the container's memory
# limit alone kills nondeterministically; this makes allocation fail cleanly.
ulimit -v "$vmem"
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
        Self::docker_with_prefix(image, runtime, format!("rr-{}-", &id[..8]))
    }

    /// Like [`Sandbox::docker`] with an explicit container name prefix, so a
    /// test run can check for leftovers of its own containers only.
    pub fn docker_with_prefix(
        image: impl Into<String>,
        runtime: Option<String>,
        prefix: impl Into<String>,
    ) -> Self {
        Sandbox::Docker(DockerSandbox {
            image: image.into(),
            runtime,
            prefix: prefix.into(),
            live: Arc::default(),
        })
    }

    pub async fn run(&self, code: &str, limits: &Limits) -> std::io::Result<RunOutput> {
        match self.execute(code, &JobKind::Run, limits).await? {
            Execution::Finished(collected, duration_ms) => {
                interpret(collected, limits, duration_ms)
            }
            Execution::JobTimeout(duration_ms) => Ok(job_timeout_output(limits, duration_ms)),
        }
    }

    /// Grades `code` against `tests` (`POST /grade`): one compile of the
    /// learner's code plus a generated harness, one run. Same container,
    /// limits and caps as [`Sandbox::run`].
    pub async fn grade(
        &self,
        code: &str,
        tests: &[rr_grade::TestSpec],
        limits: &Limits,
    ) -> std::io::Result<GradeOutput> {
        let nonce = uuid::Uuid::new_v4().simple().to_string();
        let generated = rr_grade::build(code, tests, &nonce);
        let kind = JobKind::Grade {
            learner_bytes: generated.learner_bytes,
        };
        match self.execute(&generated.source, &kind, limits).await? {
            Execution::Finished(collected, duration_ms) => {
                interpret_grade(&generated, collected, limits, duration_ms)
            }
            Execution::JobTimeout(duration_ms) => Ok(GradeOutput {
                tests: generated
                    .ids
                    .iter()
                    .map(|id| rr_grade::TestResult::new(id, rr_grade::Status::NotRun))
                    .collect(),
                compile_errors_in: None,
                reason: None,
                run: job_timeout_output(limits, duration_ms),
            }),
        }
    }

    /// Starts the job, feeds it `stdin` and collects what it produced.
    async fn execute(
        &self,
        stdin: &str,
        kind: &JobKind,
        limits: &Limits,
    ) -> std::io::Result<Execution> {
        let started = Instant::now();
        // Local mode needs a work dir on the host; Docker uses the container's /tmp.
        let local_dir = match self {
            Sandbox::Local => Some(tempfile::tempdir()?),
            Sandbox::Docker(_) => None,
        };
        let (mut cmd, mut guard) = match self {
            Sandbox::Docker(d) => d.command(limits, kind),
            Sandbox::Local => {
                let dir = local_dir.as_ref().expect("local dir").path();
                (local_command(dir, limits, kind), ContainerGuard::none())
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
            collect(&mut child, &handle, stdin, limits),
        )
        .await;
        let duration_ms = started.elapsed().as_millis() as u64;

        let collected = match job {
            Ok(result) => result?,
            Err(_) => {
                let _ = child.start_kill();
                guard.remove_now().await;
                return Ok(Execution::JobTimeout(duration_ms));
            }
        };
        // A docker CLI killed by a signal may leave its container running.
        if collected.overflow || collected.timed_out || collected.signaled {
            guard.remove_now().await;
        } else {
            // The container exited by itself, so `--rm` cleans it up.
            guard.disarm();
        }
        if let Some(e) = host_failure(&collected, matches!(self, Sandbox::Docker(_))) {
            return Err(e);
        }
        Ok(Execution::Finished(collected, duration_ms))
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

/// Names of the container runtimes the Docker daemon has registered, from
/// `docker info`. Used to insist on gVisor (`runsc`) in production.
pub async fn docker_runtimes() -> Result<Vec<String>, String> {
    let out = docker_quiet(&["info", "--format", "{{json .Runtimes}}"])
        .await
        .ok_or("could not run `docker info`; is the Docker daemon reachable?")?;
    let value: serde_json::Value = serde_json::from_slice(&out)
        .map_err(|e| format!("could not read the runtimes from `docker info`: {e}"))?;
    Ok(value
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default())
}

/// The Docker server version, for the startup log. Best effort.
pub async fn docker_server_version() -> Option<String> {
    let out = docker_quiet(&["version", "--format", "{{.Server.Version}}"]).await?;
    Some(String::from_utf8_lossy(&out).trim().to_string())
}

/// The sandbox image's ID (its content digest), for the startup log. Best effort.
pub async fn docker_image_id(image: &str) -> Option<String> {
    let out = docker_quiet(&["image", "inspect", "--format", "{{.Id}}", image]).await?;
    Some(String::from_utf8_lossy(&out).trim().to_string())
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
    fn command(&self, limits: &Limits, kind: &JobKind) -> (Command, ContainerGuard) {
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
            .args([
                "--read-only",
                "--tmpfs",
                &format!("/tmp:rw,exec,size={}m,mode=1777", limits.tmpfs_mb),
            ])
            .args(["--cap-drop", "ALL", "--security-opt", "no-new-privileges"])
            .args(["--user", "65534:65534"]);
        if let Some(runtime) = &self.runtime {
            cmd.args(["--runtime", runtime]);
        }
        cmd.arg(&self.image)
            .args(["bash", "-c", JOB_SCRIPT, "job"])
            .arg(limits.compile_timeout.as_secs().to_string())
            .arg(limits.run_timeout.as_secs().to_string())
            .arg("/tmp")
            .arg(limits.program_vmem_kb().to_string())
            .args(kind.script_args());
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

fn local_command(dir: &std::path::Path, limits: &Limits, kind: &JobKind) -> Command {
    let mut cmd = Command::new("bash");
    cmd.args(["-c", JOB_SCRIPT, "job"])
        .arg(limits.compile_timeout.as_secs().to_string())
        .arg(limits.run_timeout.as_secs().to_string())
        .arg(dir)
        .arg(limits.program_vmem_kb().to_string())
        .args(kind.script_args());
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

/// Which job the script runs.
enum JobKind {
    Run,
    Grade {
        /// Length of the learner's code, the first bytes of the file.
        learner_bytes: usize,
    },
}

impl JobKind {
    /// The script's arguments after the four common ones. `/run` passes
    /// none, so its invocation is the one it always was.
    fn script_args(&self) -> Vec<String> {
        match self {
            JobKind::Run => Vec::new(),
            JobKind::Grade { learner_bytes } => {
                let mut args = vec![
                    "grade".to_string(),
                    learner_bytes.to_string(),
                    rr_grade::generate::MIN_STACK.to_string(),
                ];
                args.extend(rr_grade::generate::RUN_ARGS.iter().map(|a| a.to_string()));
                args
            }
        }
    }
}

enum Execution {
    Finished(Collected, u64),
    /// The whole job passed `job_timeout` (the duration so far).
    JobTimeout(u64),
}

fn job_timeout_output(limits: &Limits, duration_ms: u64) -> RunOutput {
    RunOutput {
        stderr: format!(
            "Time limit exceeded: the job took longer than {} seconds.",
            limits.job_timeout.as_secs()
        ),
        ..RunOutput::new(false, Stage::Timeout, duration_ms)
    }
}

struct Collected {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    overflow: bool,
    /// The host-side run timer fired.
    timed_out: bool,
    code: Option<i32>,
    /// The child process ended because of a signal (so `code` is 128 + signal,
    /// made up by us). In Docker mode the child is the `docker` CLI, and a
    /// signal means someone killed the CLI, not that the container exited.
    signaled: bool,
}

/// A signalled `docker` CLI that we did not kill ourselves is a host failure
/// (OOM killer, an operator, a crash), not a result of the learner's code. Its
/// made-up 137 would otherwise read as "out of memory" to the learner and
/// count as proof that the toolchain works.
fn host_failure(c: &Collected, docker: bool) -> Option<std::io::Error> {
    if docker && c.signaled && !c.overflow && !c.timed_out {
        return Some(std::io::Error::other(format!(
            "docker CLI was killed by a signal (reported as exit {:?})",
            c.code
        )));
    }
    None
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

    // stdout starts with both markers; stderr carries compiler warnings and
    // the program's stderr.
    let prefix = both_markers();
    let out_cap = limits.max_output + prefix.len();

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
        Some((prefix, started_tx)),
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
        let code = status.code().or_else(|| status.signal().map(|s| 128 + s));
        Ok::<_, std::io::Error>((code, status.signal().is_some()))
    }
    .await;

    writer.abort();
    for task in [out_task, err_task].into_iter().flatten() {
        task.abort();
    }
    let (code, signaled) = result?;
    Ok(Collected {
        stdout: stdout.unwrap_or_default(),
        stderr: stderr.unwrap_or_default(),
        overflow,
        timed_out,
        code,
        signaled,
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
    mut started: Option<(Vec<u8>, tokio::sync::oneshot::Sender<()>)>,
) -> std::io::Result<(Vec<u8>, bool)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let n = reader.read(&mut chunk).await?;
        if n == 0 {
            return Ok((buf, false));
        }
        buf.extend_from_slice(&chunk[..n]);
        // Once enough has arrived to tell, the run timer starts only if
        // stdout begins with both markers (the program is about to run).
        if let Some((prefix, _)) = &started
            && buf.len() >= prefix.len()
        {
            let (prefix, tx) = started.take().expect("checked above");
            if buf.starts_with(&prefix) {
                let _ = tx.send(());
            }
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
            let from = searched.saturating_sub(RUN_MARKER.len() - 1);
            if let Some(i) = find(&buf[from..], RUN_MARKER) {
                program_start = Some(from + i + RUN_MARKER.len());
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

/// Turns what the job script produced into a result. Returns `Err` when the
/// job never got going (a server problem, not the learner's).
fn interpret(c: Collected, limits: &Limits, duration_ms: u64) -> std::io::Result<RunOutput> {
    let max = limits.max_output;

    // Without the compile-start marker the script never ran: the docker CLI
    // was killed, dockerd restarted, the container was swept, the sentry
    // crashed, or Docker itself failed (125-127). Never the learner's fault,
    // whatever the exit code (137 included).
    if !c.stdout.starts_with(COMPILE_MARKER) {
        // Compiler output can echo learner code, so only the exit code is in
        // the error; a few bytes of stderr are for debugging at `debug` only.
        tracing::debug!(
            "failed job stderr (first 200 bytes): {}",
            String::from_utf8_lossy(&c.stderr[..c.stderr.len().min(200)])
        );
        return Err(std::io::Error::other(format!(
            "job failed before compiling (exit {:?})",
            c.code
        )));
    }

    let after_compile = &c.stdout[COMPILE_MARKER.len()..];
    if !after_compile.starts_with(RUN_MARKER) {
        // Compiling did not succeed (or the container died while it ran).
        let stderr = text(&c.stderr, max, c.overflow);
        let mut out = RunOutput::new(false, Stage::Compile, duration_ms);
        match c.code {
            _ if c.overflow => out.stderr = stderr,
            Some(COMPILE_FAILED) => {
                out.stderr = stderr;
                out.compiler_verdict = true;
            }
            Some(COMPILE_KILLED) => {
                out.stage = Stage::Timeout;
                out.stderr = format!(
                    "{stderr}\nCompiling was stopped: it took longer than {} seconds or used too much memory.",
                    limits.compile_timeout.as_secs()
                );
            }
            // The whole container was killed while compiling: out of memory.
            Some(KILLED) => {
                out.mem_limit = true;
                out.stderr = format!("{stderr}\nCompiling was stopped: it used too much memory.");
            }
            other => {
                tracing::debug!(
                    "failed compile stderr (first 200 bytes): {}",
                    String::from_utf8_lossy(&c.stderr[..c.stderr.len().min(200)])
                );
                return Err(std::io::Error::other(format!(
                    "job failed while compiling (exit {other:?})"
                )));
            }
        }
        out.stderr = out.stderr.trim().to_string();
        out.truncated = c.overflow || c.stderr.len() > max;
        return Ok(out);
    }

    let stdout = &after_compile[RUN_MARKER.len()..];
    let (warnings, program_err) = match find(&c.stderr, RUN_MARKER) {
        Some(i) => (&c.stderr[..i], &c.stderr[i + RUN_MARKER.len()..]),
        None => (&c.stderr[..], &[][..]),
    };
    let truncated = c.overflow || stdout.len() > max || program_err.len() > max;
    let stdout = text(stdout, max, c.overflow && stdout.len() >= max);
    let mut stderr = text(program_err, max, c.overflow && program_err.len() >= max);
    let mut mem_limit = false;

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
            // The address-space cap made an allocation fail: Rust prints
            // "memory allocation of N bytes failed" and aborts (SIGABRT).
            Some(ABORTED) if find(program_err, ALLOC_FAILED.as_bytes()).is_some() => {
                mem_limit = true;
                stderr.push_str("\nThe program was stopped: it used too much memory.");
                (false, Stage::Run)
            }
            Some(KILLED) => {
                mem_limit = true;
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
        mem_limit,
        compiler_verdict: true,
        truncated,
    })
}

/// Written to stdout and stderr by grade mode when the combined compile
/// failed, right before the learner-only check runs.
const CHECK_MARKER: &[u8] = b"\x01RR-CHECK\n";
/// Written to stdout after the check, followed by its exit code and a newline.
const CHECK_RESULT: &[u8] = b"\x01RR-CHECK:";

/// [`interpret`] for a graded job.
fn interpret_grade(
    g: &rr_grade::Generated,
    c: Collected,
    limits: &Limits,
    duration_ms: u64,
) -> std::io::Result<GradeOutput> {
    let max = limits.max_output;
    let not_run = |g: &rr_grade::Generated| -> Vec<rr_grade::TestResult> {
        g.ids
            .iter()
            .map(|id| rr_grade::TestResult::new(id, rr_grade::Status::NotRun))
            .collect()
    };

    // The program started: results come from its records.
    if c.stdout.starts_with(&both_markers()) {
        let program_stdout = c.stdout[both_markers().len()..].to_vec();
        let (warnings_raw, program_err) = match find(&c.stderr, RUN_MARKER) {
            Some(i) => (
                c.stderr[..i].to_vec(),
                c.stderr[i + RUN_MARKER.len()..].to_vec(),
            ),
            None => (c.stderr.clone(), Vec::new()),
        };
        let code = c.code;
        let overflow = c.overflow;
        let mut run = interpret(c, limits, duration_ms)?;
        let end = rr_grade::EndState {
            end: if run.stage == Stage::Timeout {
                rr_grade::End::TimedOut
            } else if overflow {
                rr_grade::End::OutputLimit
            } else if run.mem_limit {
                rr_grade::End::MemLimit
            } else {
                rr_grade::End::Exited(code.unwrap_or(-1))
            },
            stack_overflow: find(&program_err, b"has overflowed its stack").is_some(),
        };
        let stdout_text = String::from_utf8_lossy(&program_stdout);
        let verdict = rr_grade::results(g, &stdout_text, &end);
        // What /run would call the program's stdout is `main`'s output. The
        // program's stderr is the whole run's, without the server's prose
        // (a timeout and the like are the tests' statuses).
        run.stdout = text(verdict.main_stdout.as_bytes(), max, overflow);
        run.stderr = text(&program_err, max, overflow && program_err.len() >= max);
        run.warnings = text(
            rr_grade::learner_warnings(g, &String::from_utf8_lossy(&warnings_raw)).as_bytes(),
            max,
            false,
        )
        .trim()
        .to_string();
        run.success =
            matches!(end.end, rr_grade::End::Exited(0)) && verdict.main == rr_grade::MainStatus::Ok;
        return Ok(GradeOutput {
            run,
            compile_errors_in: None,
            reason: verdict.reason,
            tests: verdict.tests,
        });
    }

    // Compiling failed, and the learner-only check ran: whose error is it?
    if c.code == Some(COMPILE_FAILED) && !c.overflow && c.stdout.starts_with(COMPILE_MARKER) {
        let combined_json;
        let check_text;
        match find(&c.stderr, CHECK_MARKER) {
            Some(i) => {
                combined_json = String::from_utf8_lossy(&c.stderr[..i]).into_owned();
                check_text =
                    String::from_utf8_lossy(&c.stderr[i + CHECK_MARKER.len()..]).into_owned();
            }
            None => {
                combined_json = String::from_utf8_lossy(&c.stderr).into_owned();
                check_text = String::new();
            }
        }
        // `RR-CHECK:<exit code>`; a check that was killed (137) or timed out
        // has no verdict.
        let rc = find(&c.stdout, CHECK_RESULT).and_then(|i| {
            let rest = &c.stdout[i + CHECK_RESULT.len()..];
            let end = rest.iter().position(|b| *b == b'\n')?;
            std::str::from_utf8(&rest[..end]).ok()?.parse::<i32>().ok()
        });
        let check = match rc {
            Some(0) => Some(rr_grade::CheckResult {
                passed: true,
                text: String::new(),
            }),
            Some(137) | Some(124) | None => None,
            Some(_) => Some(rr_grade::CheckResult {
                passed: false,
                text: text(check_text.as_bytes(), max, false),
            }),
        };
        let verdict = rr_grade::classify_compile(g, &combined_json, check.as_ref());
        if verdict.reason.as_deref() == Some("harness") {
            // A bug in the harness, or a documented residual. Logged
            // without any code.
            tracing::warn!(event = "grade_harness", "the test harness did not compile");
        }
        let mut run = RunOutput::new(false, Stage::Compile, duration_ms);
        run.stderr = text(verdict.stderr.as_bytes(), max, false);
        run.compiler_verdict = true;
        run.truncated = verdict.stderr.len() > max;
        return Ok(GradeOutput {
            run,
            compile_errors_in: Some(verdict.errors_in),
            reason: verdict.reason,
            tests: verdict.tests,
        });
    }

    // The compiler printed too much: the combined diagnostics are cut off
    // and say nothing reliable.
    if c.stdout.starts_with(COMPILE_MARKER) && c.overflow {
        let mut run = RunOutput::new(false, Stage::Compile, duration_ms);
        run.stderr = "The compiler printed too much output.".to_string();
        run.truncated = true;
        return Ok(GradeOutput {
            run,
            compile_errors_in: Some(rr_grade::ErrorsIn::Code),
            reason: None,
            tests: not_run(g),
        });
    }

    // Everything else is as in /run: not started (a server error), compile
    // killed or out of memory.
    let run = interpret(c, limits, duration_ms)?;
    Ok(GradeOutput {
        run,
        compile_errors_in: None,
        reason: None,
        tests: not_run(g),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn collected(stdout: &[u8], stderr: &[u8], code: Option<i32>) -> Collected {
        Collected {
            stdout: stdout.to_vec(),
            stderr: stderr.to_vec(),
            overflow: false,
            timed_out: false,
            code,
            signaled: false,
        }
    }

    fn interp(c: Collected) -> std::io::Result<RunOutput> {
        interpret(c, &Limits::default(), 5)
    }

    #[test]
    fn a_signalled_docker_cli_is_a_host_failure_not_a_container_exit() {
        // The program had started (both markers) when the CLI was killed.
        let mut stdout = COMPILE_MARKER.to_vec();
        stdout.extend_from_slice(RUN_MARKER);
        let mut c = collected(&stdout, b"RR-RUN-ish", Some(137));
        c.signaled = true;
        assert!(host_failure(&c, true).is_some());
        // Without the signal it is the container's own exit 137: a learner result.
        c.signaled = false;
        assert!(host_failure(&c, true).is_none());
        assert!(interp(c).unwrap().mem_limit);
        // Local mode: the signal is the program's own, so it is a result.
        let mut c = collected(&stdout, b"", Some(137));
        c.signaled = true;
        assert!(host_failure(&c, false).is_none());
        // A kill we did ourselves (output cap, run timer) is not a host failure.
        for (overflow, timed_out) in [(true, false), (false, true)] {
            let mut c = collected(&stdout, b"", Some(137));
            c.signaled = true;
            c.overflow = overflow;
            c.timed_out = timed_out;
            assert!(host_failure(&c, true).is_none());
        }
    }

    #[test]
    fn no_markers_is_a_server_error_even_for_137() {
        for code in [Some(137), Some(0), Some(125), Some(201), None] {
            let c = collected(b"", b"docker: something", code);
            assert!(interp(c).is_err(), "exit {code:?}");
        }
    }

    #[test]
    fn run_marker_without_compile_marker_cannot_fake_a_stage() {
        // Learner code that prints the run marker by itself must not count.
        let c = collected(RUN_MARKER, b"", Some(0));
        assert!(interp(c).is_err());
        let c = collected(b"x\x01RR-COMPILE\n", b"", Some(0));
        assert!(interp(c).is_err());
    }

    #[test]
    fn error_does_not_leak_stderr() {
        let c = collected(b"", b"secret learner code fn main()", Some(137));
        let msg = interp(c).unwrap_err().to_string();
        assert!(msg.contains("137"), "{msg}");
        assert!(!msg.contains("secret"), "{msg}");
    }

    #[test]
    fn compile_marker_and_137_is_a_compile_memory_stop() {
        let c = collected(COMPILE_MARKER, b"partial compiler output", Some(137));
        let out = interp(c).unwrap();
        assert!(!out.success);
        assert_eq!(out.stage, Stage::Compile);
        assert!(
            out.stderr.starts_with("partial compiler output"),
            "{}",
            out.stderr
        );
        assert!(
            out.stderr
                .contains("Compiling was stopped: it used too much memory.")
        );
        assert!(out.mem_limit);
        assert!(
            !out.compiler_verdict,
            "a host-looking kill must not refresh liveness"
        );
    }

    #[test]
    fn compile_error_counts_for_liveness() {
        let c = collected(COMPILE_MARKER, b"error[E0308]: mismatched types", Some(201));
        let out = interp(c).unwrap();
        assert_eq!(out.stage, Stage::Compile);
        assert!(!out.success && !out.mem_limit);
        assert!(out.stderr.contains("mismatched types"));
        assert!(out.compiler_verdict);
    }

    #[test]
    fn compile_timeout_does_not_count_for_liveness() {
        let c = collected(COMPILE_MARKER, b"", Some(202));
        let out = interp(c).unwrap();
        assert_eq!(out.stage, Stage::Timeout);
        assert!(!out.compiler_verdict && !out.mem_limit);
    }

    #[test]
    fn compile_marker_and_other_exit_is_a_server_error() {
        for code in [Some(0), Some(1), Some(125), Some(139), None] {
            let c = collected(COMPILE_MARKER, b"", code);
            assert!(interp(c).is_err(), "exit {code:?}");
        }
    }

    #[test]
    fn failed_allocation_is_a_memory_stop() {
        let stdout = both_markers();
        let c = collected(
            &stdout,
            b"\x01RR-RUN\nmemory allocation of 1 bytes failed\n",
            Some(134),
        );
        let out = interp(c).unwrap();
        assert!(!out.success);
        assert_eq!(out.stage, Stage::Run);
        assert!(
            out.stderr
                .contains("The program was stopped: it used too much memory.")
        );
        assert!(out.mem_limit);
        assert!(out.compiler_verdict);
    }

    #[test]
    fn plain_abort_is_a_normal_failed_run() {
        let stdout = both_markers();
        let c = collected(&stdout, b"\x01RR-RUN\nsome other abort\n", Some(134));
        let out = interp(c).unwrap();
        assert!(!out.success);
        assert_eq!(out.stage, Stage::Run);
        assert!(!out.stderr.contains("too much memory"));
        assert!(!out.mem_limit);
        assert!(out.compiler_verdict);
    }

    #[test]
    fn successful_run_strips_both_markers() {
        let mut stdout = both_markers();
        stdout.extend_from_slice(b"hello\n");
        let c = collected(&stdout, b"warning: x\n\x01RR-RUN\n", Some(0));
        let out = interp(c).unwrap();
        assert!(out.success);
        assert_eq!(out.stage, Stage::Run);
        assert_eq!(out.stdout, "hello\n");
        assert_eq!(out.warnings, "warning: x");
        assert!(out.compiler_verdict && !out.mem_limit);
    }

    #[test]
    fn truncated_follows_the_servers_overflow_flag_not_the_text() {
        let mut stdout = both_markers();
        // A program that prints the marker text itself is not "truncated".
        stdout.extend_from_slice(b"[output truncated]");
        let out = interp(collected(&stdout, b"\x01RR-RUN\n", Some(0))).unwrap();
        assert!(!out.truncated, "program text must not set the flag");

        // The server cut the stream: truncated, whatever the text says.
        let mut stdout = both_markers();
        stdout.extend_from_slice(b"abc");
        let mut c = collected(&stdout, b"\x01RR-RUN\n", Some(137));
        c.overflow = true;
        let out = interp(c).unwrap();
        assert!(out.truncated);

        // Compile stage too.
        let mut c = collected(COMPILE_MARKER, b"error: x", Some(COMPILE_FAILED));
        c.overflow = true;
        assert!(interp(c).unwrap().truncated);
        let c = collected(COMPILE_MARKER, b"error: x", Some(COMPILE_FAILED));
        assert!(!interp(c).unwrap().truncated);
    }

    #[test]
    fn killed_program_is_reported_as_memory() {
        let stdout = both_markers();
        let c = collected(&stdout, b"\x01RR-RUN\n", Some(137));
        let out = interp(c).unwrap();
        assert_eq!(out.stage, Stage::Run);
        assert!(out.stderr.contains("too much memory"));
        assert!(out.mem_limit);
    }

    #[test]
    fn program_timeout_and_cpu_limit() {
        let stdout = both_markers();
        for code in [124, 152] {
            let c = collected(&stdout, b"\x01RR-RUN\n", Some(code));
            let out = interp(c).unwrap();
            assert_eq!(out.stage, Stage::Timeout, "exit {code}");
            assert!(out.compiler_verdict && !out.mem_limit);
        }
    }

    // --- grade mode ---

    const NONCE: &str = "00112233445566778899aabbccddeeff";

    fn generated() -> rr_grade::Generated {
        let tests = [
            rr_grade::TestSpec {
                id: "a".into(),
                code: Some("check!(true);".into()),
                ..Default::default()
            },
            rr_grade::TestSpec {
                id: "o".into(),
                output: Some("hi".into()),
                ..Default::default()
            },
        ];
        rr_grade::build("fn main() { println!(\"hi\"); }\n", &tests, NONCE)
    }

    fn rec(kind: &str, fields: &[&str]) -> String {
        let mut s = format!("\x01RR-T:{NONCE}:{kind}");
        for f in fields {
            s.push('\x1f');
            s.push_str(f);
        }
        s.push('\n');
        s
    }

    fn graded(c: Collected) -> std::io::Result<GradeOutput> {
        interpret_grade(&generated(), c, &Limits::default(), 7)
    }

    fn statuses(out: &GradeOutput) -> Vec<rr_grade::Status> {
        out.tests.iter().map(|t| t.status).collect()
    }

    fn passing_run_stdout() -> Vec<u8> {
        let mut stdout = both_markers();
        let mut body = String::from("running 1 test\n");
        body += &rec("case", &["a"]);
        body += &rec("pass", &[]);
        body += &rec("main", &[]);
        body += "hi\n";
        body += &rec("mainend", &["ok"]);
        body += &rec("done", &[]);
        stdout.extend_from_slice(body.as_bytes());
        stdout
    }

    #[test]
    fn a_graded_run_reads_the_records() {
        let c = collected(
            &passing_run_stdout(),
            b"warn\n\x01RR-RUN\nto stderr\n",
            Some(0),
        );
        let out = graded(c).unwrap();
        assert!(out.run.success);
        assert_eq!(out.run.stage, Stage::Run);
        assert_eq!(out.run.stdout, "hi\n");
        assert_eq!(out.run.stderr, "to stderr\n");
        assert_eq!(statuses(&out), [rr_grade::Status::Pass; 2]);
        assert!(out.compile_errors_in.is_none() && out.reason.is_none());
        assert!(out.run.compiler_verdict && !out.run.mem_limit);
    }

    #[test]
    fn a_graded_run_that_times_out_or_crashes_says_so_per_test() {
        use rr_grade::Status::*;
        let mut stdout = both_markers();
        stdout.extend_from_slice(rec("case", &["a"]).as_bytes());
        // The in-container timer.
        let out = graded(collected(&stdout, b"\x01RR-RUN\n", Some(124))).unwrap();
        assert_eq!(
            (out.run.stage, statuses(&out)),
            (Stage::Timeout, vec![Timeout, NotRun])
        );
        assert!(
            !out.run.stderr.contains("Time limit"),
            "no server prose: {}",
            out.run.stderr
        );
        // The host-side timer.
        let mut c = collected(&stdout, b"\x01RR-RUN\n", Some(137));
        c.timed_out = true;
        let out = graded(c).unwrap();
        assert_eq!(statuses(&out), [Timeout, NotRun]);
        // Too much output.
        let mut c = collected(&stdout, b"\x01RR-RUN\n", Some(137));
        c.overflow = true;
        let out = graded(c).unwrap();
        assert_eq!(statuses(&out), [Crashed, NotRun]);
        assert_eq!(out.tests[0].reason.as_deref(), Some("output_limit"));
        assert_eq!(out.reason.as_deref(), Some("output_limit"));
        // Memory.
        let out = graded(collected(&stdout, b"\x01RR-RUN\n", Some(137))).unwrap();
        assert_eq!(out.tests[0].reason.as_deref(), Some("mem_limit"));
        assert!(out.run.mem_limit);
        let out = graded(collected(
            &stdout,
            b"\x01RR-RUN\nmemory allocation of 9 bytes failed\n",
            Some(134),
        ))
        .unwrap();
        assert_eq!(out.tests[0].reason.as_deref(), Some("mem_limit"));
        // Stack overflow, and any other exit.
        let out = graded(collected(
            &stdout,
            b"\x01RR-RUN\nthread 'x' has overflowed its stack\n",
            Some(134),
        ))
        .unwrap();
        assert_eq!(out.tests[0].reason.as_deref(), Some("stack_overflow"));
        let out = graded(collected(&stdout, b"\x01RR-RUN\n", Some(3))).unwrap();
        assert_eq!(out.tests[0].reason.as_deref(), Some("exit:3"));
    }

    #[test]
    fn a_failed_combined_compile_uses_the_learner_only_check() {
        let json = r#"{"message":"mismatched types","level":"error","spans":[{"file_name":"/tmp/main.rs","line_start":1,"is_primary":true,"expansion":null}],"rendered":"error: json"}"#;
        let mut stderr = json.as_bytes().to_vec();
        stderr.extend_from_slice(b"\n\x01RR-CHECK\nerror[E0308]: mismatched types\n");
        let mut stdout = COMPILE_MARKER.to_vec();
        stdout.extend_from_slice(b"\x01RR-CHECK\n\x01RR-CHECK:1\n");
        let out = graded(collected(&stdout, &stderr, Some(201))).unwrap();
        assert_eq!(out.run.stage, Stage::Compile);
        assert_eq!(out.compile_errors_in, Some(rr_grade::ErrorsIn::Code));
        assert_eq!(out.run.stderr, "error[E0308]: mismatched types");
        assert_eq!(statuses(&out), [rr_grade::Status::NotRun; 2]);
        assert!(out.run.compiler_verdict);

        // A check that was killed has no verdict; the combined diagnostics
        // decide (here: an error in the learner's line 1).
        let mut stdout = COMPILE_MARKER.to_vec();
        stdout.extend_from_slice(b"\x01RR-CHECK\n\x01RR-CHECK:137\n");
        let out = graded(collected(&stdout, &stderr, Some(201))).unwrap();
        assert_eq!(out.compile_errors_in, Some(rr_grade::ErrorsIn::Code));
        assert_eq!(out.run.stderr, "error: json");

        // The check passed and the error is in a test: the tests don't fit.
        let g = generated();
        let line = g.ranges[0].start + 1;
        let in_test = format!(
            r#"{{"message":"cannot find function `f`","level":"error","spans":[{{"file_name":"/tmp/main.rs","line_start":{line},"is_primary":true,"expansion":null}}],"rendered":"x"}}"#
        );
        let mut stderr = in_test.into_bytes();
        stderr.extend_from_slice(b"\n\x01RR-CHECK\n");
        let mut stdout = COMPILE_MARKER.to_vec();
        stdout.extend_from_slice(b"\x01RR-CHECK\n\x01RR-CHECK:0\n");
        let out = graded(collected(&stdout, &stderr, Some(201))).unwrap();
        assert_eq!(out.compile_errors_in, Some(rr_grade::ErrorsIn::Tests));
        assert_eq!(out.run.stderr, "");
        assert_eq!(
            statuses(&out),
            [rr_grade::Status::Error, rr_grade::Status::NotRun]
        );
    }

    #[test]
    fn graded_jobs_that_never_started_or_were_killed_while_compiling_are_as_in_run() {
        assert!(graded(collected(b"", b"docker: boom", Some(125))).is_err());
        let out = graded(collected(COMPILE_MARKER, b"", Some(202))).unwrap();
        assert_eq!(out.run.stage, Stage::Timeout);
        assert!(out.compile_errors_in.is_none());
        assert_eq!(statuses(&out), [rr_grade::Status::NotRun; 2]);
        let out = graded(collected(COMPILE_MARKER, b"partial", Some(137))).unwrap();
        assert!(out.run.mem_limit);
        assert!(!out.run.compiler_verdict);
        assert!(graded(collected(COMPILE_MARKER, b"", Some(1))).is_err());
    }

    #[test]
    fn a_program_cannot_fake_the_check_markers() {
        // Printing them while running changes nothing: the run markers are
        // there, so the records decide.
        let mut stdout = passing_run_stdout();
        stdout.extend_from_slice(b"\x01RR-CHECK:0\n");
        let out = graded(collected(&stdout, b"\x01RR-RUN\n\x01RR-CHECK\n", Some(0))).unwrap();
        assert_eq!(out.run.stage, Stage::Run);
        assert_eq!(statuses(&out), [rr_grade::Status::Pass; 2]);
    }

    #[test]
    fn the_script_arguments_of_each_job_kind() {
        assert!(
            JobKind::Run.script_args().is_empty(),
            "/run passes nothing extra"
        );
        let args = JobKind::Grade { learner_bytes: 42 }.script_args();
        assert_eq!(&args[..3], ["grade", "42", "8388608"]);
        assert_eq!(&args[3..], rr_grade::generate::RUN_ARGS);
    }

    #[test]
    fn program_memory_cap_follows_the_formula() {
        let l = Limits::default();
        assert_eq!(l.program_vmem_kb(), 320 * 1024);
        let l = Limits {
            memory_mb: 1024,
            tmpfs_mb: 256,
            ..Limits::default()
        };
        assert_eq!(l.program_vmem_kb(), (1024 - 256 - 64) * 1024);
    }

    #[test]
    fn memory_floor_follows_tmpfs() {
        assert!(Limits::default().validate().is_ok());
        let at_floor = Limits {
            memory_mb: 128 + 64 + 128,
            ..Limits::default()
        };
        assert!(at_floor.validate().is_ok());
        let below = Limits {
            memory_mb: 128 + 64 + 127,
            ..Limits::default()
        };
        assert!(below.validate().is_err());
        let big_tmpfs = Limits {
            tmpfs_mb: 384,
            ..Limits::default()
        };
        assert!(big_tmpfs.validate().is_err());
    }
}
