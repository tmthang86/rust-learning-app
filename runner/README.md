# Rust code runner

A small HTTP service that compiles and runs learners' Rust code for the app.

## API

`POST /run` with `{"code": "fn main() { ... }"}` returns:

```json
{ "success": true, "stage": "run", "stdout": "Hello!\n", "stderr": "", "warnings": "", "durationMs": 480 }
```

`stage` is `compile` (compiler errors in `stderr`), `run` (the program ran;
`success` is false if it panicked or was stopped) or `timeout`. When
compiling succeeds, `warnings` holds the compiler's warnings and `stderr`
only the program's own error output.
Errors are JSON too: `{"error": "..."}` with status 400, 408, 413, 422, 500
or 503 (busy; comes with `Retry-After`).
`GET /health` returns `ok`.

## Sandbox

Every job runs in a fresh Docker container that is thrown away afterwards.
The code goes in over stdin, so nothing is mounted from the host.

| Protection | Setting |
|---|---|
| No network | `--network none` |
| Can't change the system | read-only root, `--cap-drop ALL`, `no-new-privileges`, runs as `nobody` |
| Memory | 512 MB, no swap |
| CPU | 1 core |
| Processes | 64 max (stops fork bombs) |
| Kernel isolation | gVisor (`--runtime runsc`), required unless `RUNNER_ALLOW_RUNC=1` |
| Time | 10 s to compile, 5 s to run, 20 s per job |
| Output | 64 KB per stream, enforced by the server; the job is killed past it |
| Leftovers | containers are removed on timeout, overflow or client disconnect; a watchdog and a startup sweep remove any missed ones |
| Code size | 64 KB |
| Concurrency | 4 jobs at once by default; others wait up to 10 s, then get 503 |

The ignored test `docker_sandbox_runs_and_blocks_network` checks network,
file writes, memory and process limits against the real image.

## Running

```sh
docker build -t rust-runner-sandbox -f sandbox.Dockerfile .
RUNNER_ALLOW_RUNC=1 cargo run --release     # dev without gVisor; listens on 0.0.0.0:8080
cargo test                                  # fast tests, unsandboxed
cargo test -- --include-ignored             # also tests the Docker sandbox
```

Point the app at it with `flutter run --dart-define=RUNNER_URL=http://localhost:8080`.

Settings (environment variables): `RUNNER_ADDR`, `RUNNER_IMAGE`,
`RUNNER_DOCKER_RUNTIME` (`runsc` for gVisor), `RUNNER_ALLOW_RUNC`,
`RUNNER_MAX_JOBS`, `RUNNER_QUEUE_TIMEOUT_SECS`, `RUNNER_COMPILE_TIMEOUT_SECS`,
`RUNNER_RUN_TIMEOUT_SECS`, `RUNNER_JOB_TIMEOUT_SECS`, `RUNNER_MEMORY_MB`,
`RUNNER_ALLOWED_ORIGINS` (comma-separated web origins for CORS). Invalid
values stop the server at startup. `RUNNER_SANDBOX=local` skips Docker and
runs code directly on the machine; use it only for local development.

The first compile after the image is pulled can be slow while the
toolchain loads from disk; run one warm-up job after deploying.

## Before going live

- Host it on a dedicated VM used for nothing else, since it controls Docker.
  Install gVisor and keep runc and the kernel patched (runc escape fixes:
  1.2.8 / 1.3.3, November 2025). Enable Docker user-namespace remapping.
- Require a signed-in user or Firebase App Check token on `/run`, and add
  per-user and per-IP rate limits (not built yet).
- Put it behind HTTPS on a reverse proxy that also limits connections and
  slow requests.
- Set `RUNNER_ALLOWED_ORIGINS` to the app's web domain.
- Pin the sandbox image by digest.

Research behind these choices: `/mnt/project-files/research/2026-10-18-decisions.md`
(project files), section 3.
