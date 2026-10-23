# Rust code runner

A small HTTP service that compiles and runs learners' Rust code for the app.

The design for running it in production (hosting, App Check, rate limits,
deployment, manual steps) is in [`docs/production-design.md`](docs/production-design.md).
This file is the day-to-day reference.

## API

### `POST /run`

Body: `{"code": "fn main() { ... }"}`. Headers: `Content-Type: application/json`
and, in production, `X-Firebase-AppCheck: <App Check token>`. (`Authorization`
is ignored.) Every response carries `X-Request-Id`.

Success (status 200):

```json
{ "success": true, "stage": "run", "stdout": "Hello!\n", "stderr": "", "warnings": "", "durationMs": 480 }
```

`stage` is `compile` (compiler errors in `stderr`), `run` (the program ran;
`success` is false if it panicked or was stopped) or `timeout`. When
compiling succeeds, `warnings` holds the compiler's warnings and `stderr`
only the program's own error output. A program or compile that was stopped
for using too much memory is a normal 200 with `success: false` and a message
saying so.

Errors are JSON: `{"error": "<message>", "code": "<code>"}` (`error` is kept
for older app builds; match on `code`):

| Status | `code` | When | Headers |
|---|---|---|---|
| 400 | `code_empty` | no code | |
| 400, 415, 422 | `bad_request` | body isn't the expected JSON | |
| 401 | `app_check_missing` | App Check header absent (when required) | |
| 401 | `app_check_invalid` | bad signature, claims, expiry or unknown key | |
| 403 | `app_not_allowed` | valid token for an app that isn't allowlisted | |
| 413 | `code_too_long` | more than 64 KB of code | |
| 429 | `rate_limited` | a per-IP or per-token limit, or a full limiter | `Retry-After` |
| 500 | `internal` | the sandbox failed (rare) | |
| 503 | `busy` | the queue is full, or waited past the queue timeout | `Retry-After: 5` |
| 503 | `shutting_down` | the server is stopping | |
| 503 | `auth_unavailable` | the App Check keys aren't loaded | `Retry-After: 5` |
| 408 | (empty body) | the whole request ran past the overall timeout | |

The 401 messages are generic on purpose; the specific reason goes only to the
server log (`auth_error`).

### `POST /grade`

Grades an exercise that has several tests (some hidden in the app's UI). Same
headers, gate, rate limits (one request costs one token), slots and sandbox as
`/run`. Body:

```json
{ "code": "fn check_age(...) { ... }",
  "tests": [ { "id": "fifteen", "code": "check_eq!(check_age(15), Err(String::from(\"too young\")));" },
             { "id": "zero", "code": "let _ = divide(1, 0);", "panics": "cannot divide" },
             { "id": "prints", "output": "error: too young" } ] }
```

A `code` test is a few Rust statements run inside the learner's crate with
`check_eq!(actual, expected)`, `check!(cond)`, `check_near!(a, b, tol)` and
`output_of(|| ...)`. An `output` test compares what `main` prints. Answer:

```json
{ "success": false, "stage": "run", "durationMs": 1830, "stdout": "error: too young\n",
  "stderr": "", "warnings": "", "compileErrorsIn": null, "reason": null,
  "tests": [ { "id": "fifteen", "status": "pass" },
             { "id": "zero", "status": "fail", "expr": "check_age(30)", "expected": "Ok(30)", "actual": "Err(\"too young\")" } ] }
```

`status` is `pass`, `fail`, `panic`, `nopanic`, `error`, `timeout`, `crashed`
or `not_run`; `reason` is a machine code (`mem_limit`, `output_limit`,
`stack_overflow`, `exit:<n>`, `no_main`, `tests_dont_fit`, `harness`). With
`compileErrorsIn: "code"` the learner's own code does not compile and `stderr`
holds the same text `/run` would show; with `"tests"` the code compiles but the
tests cannot use it (a renamed function). An invalid test list is
`400 tests_invalid`. The details are in
[`docs/production-design.md`](docs/production-design.md) and
[`../docs/exercise-tests-design.md`](../docs/exercise-tests-design.md).

The grading logic lives in the `grade/` crate (`rr-grade`), which
`tool/check_lessons.py` also uses, through the `rr-grade` command.

### `GET /health`

No auth, no rate limit, never cached. JSON:

```json
{"status":"ok","lastGoodJobSecsAgo":42,"keysReady":true,"diskFreeMb":11834,
 "runs":{"ok":1520,"runFailed":40,"compileError":310,"timeout":12,"memLimit":3,"rateLimited":4,"busy":0,"internal":0},
 "uptimeSecs":86400,"version":"0.2.0"}
```

`status` is `"ok"` (HTTP 200) when the sandbox gave a real compiler verdict in
the last 30 minutes, the App Check keys are loaded (if required) and at least
2 GB of disk is free (where Docker keeps its images; if the free space
cannot be read, `diskFreeMb` is `null` and the runner counts as unhealthy).
Otherwise it is
`"unhealthy"` with HTTP 503 and the same body. Counters are totals since
start. A job killed by the host, a timeout or an internal error is not a
verdict, so a host that keeps failing jobs goes unhealthy; an idle runner runs
a hello-world self-check after 10 quiet minutes to stay provably alive.

## Sandbox

Every job runs in a fresh Docker container that is thrown away afterwards.
The code goes in over stdin, so nothing is mounted from the host.

| Protection | Setting |
|---|---|
| No network | `--network none` |
| Can't change the system | read-only root, `--cap-drop ALL`, `no-new-privileges`, runs as `nobody` |
| Memory | 512 MB for the container, no swap. The learner's program is further capped to 320 MB of address space (see below); the compiler is not. |
| Scratch space | `/tmp` is a 128 MB tmpfs (it counts toward the container's memory) |
| CPU | 1 core |
| Processes | 64 max (stops fork bombs) |
| Kernel isolation | gVisor (`--runtime runsc`), required in production |
| Time | 10 s to compile, 5 s to run (enforced in the container, by a CPU-time limit, and by a timer on the server), 20 s per job |
| Output | 64 KB per stream, enforced by the server; the job is killed past it |
| Leftovers | containers are removed on timeout, overflow or client disconnect; a watchdog and a startup sweep remove any missed ones |
| Code size | 64 KB |
| Concurrency | `RUNNER_MAX_JOBS` jobs at once (4 by default); up to `RUNNER_MAX_QUEUED` (16) wait up to 10 s, the rest get 503 at once |

**Why the program has its own memory cap.** Under gVisor, Docker's `--memory`
kill is nondeterministic: sometimes only the program dies, sometimes the whole
sandbox. So the job script runs `ulimit -v` for the learner's program only,
at `memory - tmpfs - 64 MB` (320 MB at the defaults). A program that goes past
it gets a failed allocation ("memory allocation of N bytes failed") and the
learner sees "The program was stopped: it used too much memory." A full tmpfs
plus a maxed-out program stays under the container's limit. Things to know:

- Each thread's default 8 MB stack counts toward the cap, so a program can
  start only about 30 threads (measured: 26 under gVisor, 30 under runc, with
  nothing else allocated) before `thread::spawn` fails; 320 MB / 8 MB is the
  theoretical 40.
- `RUNNER_MEMORY_MB` must be at least tmpfs + 192 MB (320 MB at the default).
- The compiler is bound only by the container's memory. If it is killed, the
  learner sees "Compiling was stopped: it used too much memory."

The job script prints two markers on stdout (`\x01RR-COMPILE\n` before rustc,
then `\x01RR-RUN\n` once compiling succeeded). Learner code can't print before
them, so they prove how far the job got. A job without the first marker never
started (Docker was killed, the daemon restarted, ...), which is a 500, not a
learner result.

## Running

```sh
docker build -t rust-runner-sandbox -f sandbox.Dockerfile .
RUNNER_ENV=development RUNNER_ALLOW_RUNC=1 cargo run --release   # Docker with plain runc; listens on 0.0.0.0:8080
RUNNER_ENV=development RUNNER_SANDBOX=local cargo run --release   # no Docker: runs code directly on this machine
cargo test                                  # unit and integration tests (no Docker needed)
cargo test -- --include-ignored             # also tests the Docker sandbox
```

**A plain `cargo run` now exits.** `RUNNER_ENV` defaults to `production`, and
production refuses to start without its configuration (see below). That is
intended: forgetting a setting must never leave a runner open. Set
`RUNNER_ENV=development` for local work. In development App Check is off, rate
limits are on at their defaults, and any web origin may call the runner unless
you set `RUNNER_ALLOWED_ORIGINS`. `RUNNER_SANDBOX=local` runs code unsandboxed
and is for local development only.

Point the app at a development runner with
`flutter run --dart-define=RUNNER_URL=http://localhost:8080`; no App Check is
needed.

`rust-runner --version` prints the version and exits (before reading any
configuration). `rust-runner --self-check` runs one hello-world through the
sandbox and exits 0 or 1; it does not touch other runners' containers.

### Settings (environment variables)

Invalid values stop the server at startup, and all problems are listed at
once (exit code 2).

| Variable | Default | Notes |
|---|---|---|
| `RUNNER_ENV` | `production` | `production` or `development`. Fail-closed default. |
| `RUNNER_ADDR` | `0.0.0.0:8080` | Production: must be loopback (Caddy faces the internet). |
| `RUNNER_APP_CHECK` | `required` in production, `off` in development | `required` or `off`. Production needs `required`. |
| `RUNNER_FIREBASE_PROJECT_NUMBER` | | Digits. Required when App Check is required. Issuer and audience check. |
| `RUNNER_FIREBASE_PROJECT_ID` | | Optional; adds `projects/<id>` as a second accepted audience. |
| `RUNNER_APP_CHECK_APP_IDS` | | Comma list of Firebase app IDs (`1:<number>:<android\|ios\|web>:<hex>`). Required when App Check is required. A valid token for any other app gets 403. |
| `RUNNER_APP_CHECK_JWKS_URL` | Google's `/v1/jwks` | Development only (`http` allowed); production must use the default. |
| `RUNNER_TRUSTED_PROXIES` | empty | CIDR list of reverse proxies whose `X-Forwarded-For` is believed (`127.0.0.1/32,::1/128`). Required in production. |
| `RUNNER_LIMIT_TOKEN_PER_MIN` / `_BURST` / `_PER_HOUR` | 20 / 10 / 300 | Per App Check token (about one device). Burst must not exceed the per-minute rate. `0` switches a bucket off in development only. |
| `RUNNER_LIMIT_IP_PER_MIN` / `_BURST` / `_PER_HOUR` | 120 / 60 / 3000 | Per client IP, checked before authentication. |
| `RUNNER_LIMIT_MAX_KEYS` | 50000 | Keys each limiter keeps (1000 to 1000000). When full, new keys get 429 and existing ones keep working. |
| `RUNNER_MAX_JOBS` | 4 | Jobs running at once. |
| `RUNNER_MAX_QUEUED` | 16 | Requests allowed to wait for a slot (0 to 1000); more get 503 at once. |
| `RUNNER_QUEUE_TIMEOUT_SECS` | 10 | How long a queued request waits (at most 600). |
| `RUNNER_COMPILE_TIMEOUT_SECS` / `RUNNER_RUN_TIMEOUT_SECS` / `RUNNER_JOB_TIMEOUT_SECS` | 10 / 5 / 20 | |
| `RUNNER_MEMORY_MB` | 512 | At least tmpfs + 192 MB. |
| `RUNNER_IMAGE` | `rust-runner-sandbox` | Sandbox image. In production, pin it by digest. |
| `RUNNER_DOCKER_RUNTIME` | unset | Production: must be `runsc`. |
| `RUNNER_ALLOW_RUNC` | unset | `1` allows Docker's default runtime in development. Production: must be unset. |
| `RUNNER_SANDBOX` | `docker` | `local` skips Docker (development only; refused in production). |
| `RUNNER_ALLOWED_ORIGINS` | empty | Comma list of `https://host[:port]` web origins for CORS. Production: required, no `*`. Empty or `*` allows any origin in development. |
| `RUNNER_LOG_FORMAT` | `json` in production, `text` in development | |
| `RUST_LOG` | `info` | `tracing` filter. |

In production the server also checks, at startup, that the Docker daemon has a
`runsc` runtime and that the sandbox works (it runs `rustc --version` and a
hello-world in the sandbox, which also warms the toolchain), and refuses to
start otherwise. Run one runner per Docker daemon: the startup sweep removes
every `rr-*` container. On SIGTERM it stops taking jobs (queued and new
requests get 503 `shutting_down`) and finishes jobs in progress, giving up
after 45 s, so give it a stop timeout of at least 60 s (`TimeoutStopSec=60` in
systemd, `docker stop -t 60`).

### Logs

One JSON line per `/run` request (`event: "run_finished"`) with the request
ID, outcome (`ok`, `run_failed` for a panic or non-zero exit, `compile_error`,
`timeout`, `mem_limit`, `rate_limited`, `auth_failed`, `busy`, `bad_request`, `internal`), stage, timings, sizes,
platform and a hashed client key. A `summary` line every 60 s. Never logged:
code, program output, tokens or other header values, full IPs, the user agent,
compiler output from failed starts.

## Tests

- `cargo test`: unit tests (config rules, client IP, App Check verification with
  test keys, key cache with paused time, rate limits with a fake clock,
  `interpret()` exit-code mapping) and integration tests (`tests/api.rs`,
  `tests/app_check.rs`, `tests/log_hygiene.rs`) that use the unsandboxed local
  backend and the test keys in `tests/fixtures/`. Nothing reads environment
  variables, so `RUNNER_ENV` doesn't matter.
- `cargo test -- --include-ignored`: also the Docker suite (network, read-only
  root, memory hog, a full tmpfs plus an allocation loop run five times, fork
  bomb, `/proc/1/fd/1` bypass, frozen timer, cleanup after cancel, rustc out
  of memory). Settings: `RUNNER_DOCKER_RUNTIME` (e.g. `runsc`), `RUNNER_IMAGE`
  (default `rust-runner-sandbox`) and `RUNNER_TEST_CONTAINER_PREFIX` (name
  prefix of every container the tests start, default `rr-test-<random>-`, so a
  script can check for leftovers of its own run).

## Building the image

The release binary (and a prebuilt test binary) for the x86-64 Linux VM is
built by `deploy/Dockerfile.build` with `cargo-zigbuild`, against glibc 2.36,
on any build host without emulation; `deploy/push.sh` runs it for you (see
`deploy/README.md`). `Dockerfile` is only a small image for running the runner
in a container during development (it needs the Docker socket and defaults to
`RUNNER_ENV=development`). Production runs the binary as a systemd service.

## Going live

See [`docs/production-design.md`](docs/production-design.md): hosting, the
gVisor host setup, App Check, Caddy, rate limits, the deploy and rollback
flow, and the manual steps (M1 to M13).
