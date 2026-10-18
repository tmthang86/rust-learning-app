# Rust code runner

A small HTTP service that compiles and runs learners' Rust code for the app.

## API

`POST /run` with `{"code": "fn main() { ... }"}` returns:

```json
{ "success": true, "stage": "run", "stdout": "Hello!\n", "stderr": "", "durationMs": 480 }
```

`stage` is `compile` (compiler errors in `stderr`), `run` (the program ran;
`success` is false if it panicked or was stopped) or `timeout`.
`GET /health` returns `ok`.

## Sandbox

Every job runs in a fresh Docker container that is thrown away afterwards:

| Protection | Setting |
|---|---|
| No network | `--network none` |
| Can't change the system | read-only root, `--cap-drop ALL`, `no-new-privileges`, runs as `nobody` |
| Memory | 512 MB, no swap |
| CPU | 1 core |
| Processes | 64 max (stops fork bombs) |
| Time | 5 s to run, 20 s per job including compiling |
| Output | 64 KB per stream |
| Code size | 64 KB |
| Concurrency | 4 jobs at once by default; others queue |

The ignored test `docker_sandbox_runs_and_blocks_network` checks network,
file writes, memory and process limits against the real image.

## Running

```sh
docker build -t rust-runner-sandbox -f sandbox.Dockerfile .
cargo run --release                         # listens on 0.0.0.0:8080
cargo test                                  # fast tests, unsandboxed
cargo test -- --include-ignored             # also tests the Docker sandbox
```

Point the app at it with `flutter run --dart-define=RUNNER_URL=http://localhost:8080`.

Settings (environment variables): `RUNNER_ADDR`, `RUNNER_IMAGE`,
`RUNNER_MAX_JOBS`, `RUNNER_RUN_TIMEOUT_SECS`, `RUNNER_JOB_TIMEOUT_SECS`,
`RUNNER_MEMORY_MB`. `RUNNER_SANDBOX=local` skips Docker and runs code
directly on the machine; use it only for local development.

## Before going live

- Host it on a dedicated VM used for nothing else, since it controls Docker.
- Put it behind HTTPS and a per-user rate limit (a gateway or the accounts
  backend from step 3).
- Restrict CORS to the app's web domain.
