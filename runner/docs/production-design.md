# Runner: production design

Status: design, not built yet. Date: 2026-10-20 (revised after review round 1;
see §12). Scope: the runner service in `runner/`, the app's runner client in
`lib/runner/`, and the few lines in `lib/main.dart` and `ios/` that wire them
up.

**How this was researched.** The egress proxy blocked `firebase.google.com`,
`docs.cloud.google.com`, `gvisor.dev`, `docs.docker.com`, `caddyserver.com`,
Hetzner and DigitalOcean from this environment. I used primary sources that
were reachable instead:

- gVisor doc sources on GitHub, and the gVisor `.deb` itself (unpacked)
- Firebase Admin SDK and FlutterFire source code
- the live Google JWKS endpoint
- crates.io, pub.dev, and the apt indexes for gVisor and Docker
- Docker Hub, mirror.gcr.io, and the Cloud Run pricing page

Where I could only rely on a search-result summary of an official page, it
is marked *(search extract)*. Anything not checked is marked **Unverified**,
and §11 collects them. Findings the reviewer verified on a real runsc host
are marked *(reviewer-verified)*.

---

## 1. Summary of decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Hosting | One dedicated **GCE e2-medium** VM (2 shared vCPU, 4 GB, Ubuntu 24.04 LTS) in **`asia-southeast1` (Singapore)**, with the region kept as a variable. **No service account.** SSH only through IAP. 20 GB pd-balanced disk. About **US$36–40/month** (**Unverified** for Singapore). gVisor's `systrap` platform needs no nested virtualization (verified in the gVisor docs). Grow by resizing the VM first, then by adding VMs. **Cloud Run is rejected** for running rustc directly. |
| 2 | Sandbox fix (blocker) | Under runsc, Docker's `--memory` OOM kill is nondeterministic. Add `ulimit -v` for the learner's **program only**: memory − tmpfs − 64 MB, which is 320 MB at the defaults. Add a **compile-start marker**. A kill (rc 137) after that marker and before the run marker counts as "compiling used too much memory". A 137 with no start marker stays a server error. Map rc 134 "allocation failed" to the too-much-memory message. Run the full ignored Docker suite under runsc on the VM. |
| 3 | Auth on `/run` | **Firebase App Check is required in production.** The token arrives in the `X-Firebase-AppCheck` header and is verified in Rust: RS256, keys from `https://firebaseappcheck.googleapis.com/v1/jwks`, issuer `https://firebaseappcheck.googleapis.com/<PROJECT_NUMBER>`, audience containing `projects/<PROJECT_NUMBER>`, and `sub` in an allowlist of app IDs. **No ID tokens at launch** ([DECIDED]): `Authorization` is ignored. **No replay protection.** JWT crate: `jsonwebtoken` 11.1 (`aws_lc_rs`). |
| 4 | Threat model | App Check **raises the cost** of abuse: an attacker needs a genuine device or browser and a fresh attestation about every hour. It is **not a hard gate**. A rooted device, a farm of real phones, or reCAPTCHA solvers get through. The real bounds are the per-IP limit, the per-token limit and the fixed capacity of one VM (2 jobs at a time, queue of 16). The worst case is "runs are slow for everyone", never a bigger bill or a host compromise. |
| 5 | Fail-closed config | `RUNNER_ENV` defaults to `production`. In production the server refuses to start unless App Check is configured, the runtime is gVisor, CORS origins are explicit, rate limits are on, and the listen address is loopback. `RUNNER_APP_CHECK` defaults to `required` in production and `off` in development. |
| 6 | Rate limits | In-process **`governor` 0.10** keyed token buckets. **Per App Check token** (= per device for the token's ~1 h life): 20/min with burst 10, plus 300/hour. **Per IP:** 120/min with burst 60, plus 3000/hour. Each limiter holds at most 50,000 keys. Global protection is the job semaphore plus a queue cap. Over a limit, the server answers 429 with `Retry-After`. The client IP is the rightmost `X-Forwarded-For` entry, and only when the TCP peer is Caddy (loopback). There is no per-app bucket ([DECIDED]). |
| 7 | Edge | **Caddy** (official apt repo) on the VM. It handles automatic TLS (using the Let's Encrypt **staging** CA while testing setup), HTTP/1.1 and HTTP/2, header/body/write/idle timeouts and a 256 KB body cap, and exposes only `/run` and `/health`. **No Cloudflare and no nftables connection cap at launch.** CORS stays in the runner, with an explicit origin list, and `Retry-After` is exposed to the browser. |
| 8 | Host and deploy | The runner runs as a **hardened systemd service** under a `rust-runner` user in the `docker` group. That is root-equivalent, which is accepted on a dedicated VM with no cloud credentials. Docker CE uses `default-runtime: runsc`. **`runsc`, `docker-ce`, `docker-ce-cli` and `containerd.io` are pinned and held**, and upgraded monthly via `install.sh` plus the smoke test. Unattended upgrades cover Ubuntu security only, with reboots at 03:00 Vietnam time. **No userns-remap.** The sandbox image is pulled **by digest from `mirror.gcr.io`**. The binary is **built on Thang's laptop** with Docker and **cargo-zigbuild** in a native `$BUILDPLATFORM` stage (no QEMU), targeting `x86_64-unknown-linux-gnu.2.36`. It is built from `git archive HEAD` and shipped with its sha256. `install.sh` checks that the binary runs and that its glibc requirement is ≤ 2.39 before switching. **Nothing is compiled on the serving VM.** Each release is a directory (binary, env, image digest), so rollback restores all three. |
| 9 | App client | Add `firebase_app_check: ^0.5.0` (compatible with `firebase_core ^5.0.0`). Providers: Play Integrity, App Attest with DeviceCheck fallback, and reCAPTCHA Enterprise, with debug providers in debug builds. iOS needs a **new `Runner.entitlements`** with the App Attest environment. `HttpCodeRunner` gets a `RunnerAuth` that adds the header. On a 401 for a bad token it retries once with a fresh token. 401, 403 and 429 get their own messages. With no Firebase, it sends no header. |
| 10 | Observability | JSON logs go to journald, one line per request. They include the request ID, outcome, stage, timings, code size, platform and a hashed client key. **Never logged:** code, output, tokens, full IP. Every 60 s a summary line is written. `/health` returns JSON (status, last good job, disk free, counters), which the uptime check content-matches. A **required** billing budget alert and a weekly log review. No Prometheus. |

---

## 2. Hosting

### Options considered

| Option | Monthly cost (approx.) | Pros | Cons |
|---|---|---|---|
| **GCE e2-medium**, asia-southeast1 | VM ≈ $30 (**Unverified**: the only verified figure is us-central1 at $24.46; Singapore is typically ~20–25 % more), 20 GB pd-balanced ≈ $2.5, in-use external IPv4 ≈ $3.65 → **≈ $36–40** | Same Google account and billing as Firebase. IAP SSH, so no public port 22. The VM can run with no service account. Uptime checks and budget alerts are built in. Easy resize. Close to Vietnam and SE Asia. | Costs a bit more than Hetzner/DO. Shared-core E2 bursts above 1 vCPU only briefly. |
| GCE e2-medium, us-central1 | ≈ $31 | Cheapest GCE region | About 200 ms more round trip from Vietnam. That is minor next to a 1–3 s run, but there is no reason to pay it. |
| GCE e2-standard-2 (2 vCPU, 8 GB) | ≈ $49 in us-central1, more in Singapore | Sustained 2 vCPU | Not needed at launch volume. This is the first resize step. |
| Hetzner CPX22 (2 vCPU, 4 GB) | ≈ €19.99 incl. IPv4 *(third-party, Aug–Sep 2026)* | Cheapest | Prices changed twice in 2026. Hetzner has no SE Asia region except Singapore, at a different price (**Unverified**). It is another account. |
| DigitalOcean Basic 2 vCPU / 4 GB | ≈ $24 *(search extract)* | Simple, has a Singapore region | Another account. SSH would be public without extra setup. |
| GCE e2-micro (free tier) | $0 | Free | 1 GB RAM is too small for rustc plus gVisor. |
| **Cloud Run, rustc directly** (gen1 = gVisor), concurrency 1 | Probably inside the free tier (180,000 vCPU-s and 360,000 GiB-s per month) | Scales to zero, no host to patch | **Rejected on safety grounds**, below. |

**Why Cloud Run is rejected for running learner code directly:**

1. **Instance reuse.** With concurrency 1, requests still run one after
   another on the same instance and the same gVisor kernel. Learner code
   could leave a background process behind (`setsid`, a double fork). That
   process would see the next learner's code and output, or tamper with the
   server. Cloud Run gives a kernel boundary per *instance*, not per
   request.
2. **The metadata server.** Every instance can get an OAuth access token and
   ID tokens for its service account from `metadata.google.internal` (Cloud
   Run container contract; **Unverified**, since the page was blocked here,
   but this is long-documented behaviour).
3. **Outbound network** is on by default. Turning it off needs a VPC with
   all-traffic egress and no NAT, and the metadata server stays reachable
   even then.
4. Docker cannot run inside Cloud Run, so there are no per-job containers.

From a search extract of the Cloud Run docs: "The first generation execution
environment is based on gVisor"; second generation is a microVM.

### Choice

- **Machine:** `e2-medium`, image family `ubuntu-2404-lts-amd64`, 20 GB
  `pd-balanced`, Shielded VM.
- **Region:** variable `REGION`, default `asia-southeast1`, zone
  `asia-southeast1-b`. Every script and command takes `REGION`/`ZONE` from
  `runner/deploy/vars.sh`.
- **Service account:** `--no-service-account --no-scopes`.
- **Runner settings:** `RUNNER_MAX_JOBS=2`, `RUNNER_MAX_QUEUED=16`.
- **Capacity:** about 1–3 s per run (**Unverified** under gVisor on
  e2-medium; `smoke.sh` measures it), so roughly 40–80 runs/min at peak.
  Thousands of runs per day is far below that.

**Scaling later:**

1. **Vertical:** stop the VM, change the machine type, start it. Go to
   e2-standard-2, then e2-standard-4, and raise `RUNNER_MAX_JOBS` to match.
   The trigger is the summary log: `queue_wait_max_ms` above 2000, or
   frequent `busy` responses.
2. **Horizontal:** several VMs behind a load balancer, with per-instance
   rate limits divided by N. This is out of scope until it is needed.

**gVisor without nested virtualization: verified.** The platforms guide
says: "The `systrap` platform is a better choice when running inside a VM,
or on a machine without virtualization support". systrap "relies on
`seccomp`'s `SECCOMP_RET_TRAP` feature". It has been the default since
mid-2023. Leave the platform at its default.

---

## 3. Sandbox fix under gVisor (blocker)

**Problem** *(reviewer-verified on runsc 20261012.0 with Docker 29.9.1)*. The
ignored `docker_sandbox_runs_and_blocks_network` test fails at the memory
hog: the response has stage `timeout` instead of "too much memory". Under
runsc, the cgroup OOM kill is nondeterministic:

- Sometimes the whole sandbox dies at about 448 MB. Docker then exits 137
  and the wrapper shell is gone.
- Sometimes only the program dies.

If rustc itself is OOM-killed, there is no marker on stdout, and
`interpret()` (`sandbox.rs`, the "job failed before compiling" branch)
returns `Err`, so the learner gets a 500.

**Fix (spec):**

1. **Limit the program's address space, not rustc's.** In `JOB_SCRIPT`,
   before the final `exec`, add `ulimit -v "$4"`. The new 4th argument is
   `limits.program_vmem_kb()`, which equals `(memory_mb − tmpfs_mb − 64) ×
   1024`. Pages in the `/tmp` tmpfs count toward the sandbox's memory but
   not toward the program's address space, so the cap leaves room for a
   full tmpfs plus 64 MB of sandbox overhead.
   - With the defaults (512 MB memory, 128 MB tmpfs) the cap is **320 MB**.
     A full tmpfs plus a maxed-out program then reaches 448 MB at most, in
     theory. The test in item 5 checks that this stays below the ~448 MB
     point where the sandbox died *(reviewer-verified)*. If that test fails
     under runsc, lower the 64 MB overhead constant until it passes; don't
     shrink the tmpfs.
   - *(Reviewer-verified)*: a capped program gets rc 134 and "memory
     allocation of N bytes failed".
   - rustc stays uncapped: it fails at 409600 KB and works at 786432 KB
     *(reviewer-verified)*. It is bound only by the container's `--memory`.
   - `Limits` gains `tmpfs_mb: u32` (default 128). It is used for both the
     `--tmpfs /tmp:…size=<tmpfs_mb>m` argument and the cap. Add
     `program_vmem_kb()` (derived; no env var).
   - `Limits::validate` requires `memory_mb >= tmpfs_mb + 64 + 128`, so the
     program cap is always ≥ 128 MB. Default 8 MB thread stacks count toward
     the cap, so a program gets about 30 threads at 320 MB. Document that in
     the README.
2. **Compile-start marker.** `JOB_SCRIPT` prints `\001RR-COMPILE\n` to
   **stdout** after `cat > main.rs` and before `rustc`.
   - The existing run marker `\001RR-RUN\n` follows on stdout once
     compiling succeeds, so successful stdout starts with
     `COMPILE_MARKER + RUN_MARKER`.
   - Learner code can't print before either marker.
   - The stdout reader starts the run timer when stdout begins with both
     markers, and `interpret()` strips both.
   - stderr is unchanged (only the run marker, which separates warnings
     from program stderr).
3. **Exit-code mapping in `interpret()`:**

   | Stdout has | Exit | Result |
   |---|---|---|
   | no compile marker | anything (137 included) | `Err`, i.e. 500. The job never got going: the docker CLI was SIGKILLed or OOM-killed in the runner's cgroup, dockerd restarted, the sweep ran `rm -f`, the sentry crashed, or Docker returned 125–127. |
   | compile marker only | 201 | compile error (as today) |
   | compile marker only | 202 | compile timeout (as today) |
   | compile marker only | 137 | `Ok`, `Stage::Compile`, `success: false`, stderr = compiler output so far + "Compiling was stopped: it used too much memory." Outcome `mem_limit`. |
   | compile marker only | other | `Err` |
   | both markers | 134 and program stderr contains `memory allocation of` | `(false, Stage::Run)` + "The program was stopped: it used too much memory." Outcome `mem_limit`. |
   | both markers | others | as today (134 without that text is a normal abort) |

   A host failure that happens *between* the two markers still looks like
   a compile OOM. That window is narrow, and it is accepted. It is caught
   by the next two points.
4. **Liveness counts only compiler verdicts.** `health.last_good_job` is set
   only when the run marker is present, or when the exit code is 201 (a
   compile error is a real verdict from a working sandbox). Not on 202, 137
   or `Err`.
   - So a host that keeps killing jobs never refreshes liveness.
   - The idle self-check (hello world) then runs within 10 min and fails,
     and `/health` goes unhealthy within 30 min.
   - **Alerting on a high `mem_limit` rate:** the 60 s summary logs
     `warn` with `event = "mem_limit_rate_high"` when `mem_limit` is more
     than 20 % of at least 10 runs in that minute. `/health` exposes
     `runs.memLimit`. The weekly review (M13) looks for that warning.
     Lessons rarely hit the limit, so a high rate means abuse or a host
     problem.
5. **Rewrite the "job failed before compiling" error** so it logs the exit
   code at `error` and the first 200 bytes of stderr at `debug` only.
   Compiler output can echo learner code.
6. **Tests:**
   - Unit tests for `interpret()` with a synthetic `Collected`:
     - **(no markers, 137) → `Err`**;
     - (no markers, 0) → `Err`;
     - (compile marker, 137) → `Ok`, Compile, mem message;
     - (compile marker, 201) → compile error;
     - (both markers, 134, "memory allocation of 1 bytes failed") → mem
       message;
     - (both markers, 134, other text) → plain failed run;
     - stdout that is `RR-RUN` without `RR-COMPILE` → `Err` (stage can't be
       faked).
     - Each case also asserts whether liveness counts it.
   - The ignored Docker test's memory-hog assertion accepts either
     too-much-memory message, but never `timeout` and never a non-200.
   - New ignored test `tmpfs_full_then_allocate`: the program writes
     `tmpfs_mb − 8` MB to `/tmp/fill`, then allocates in a loop until it
     fails. It expects 200, stage `run` and the too-much-memory message,
     run 5 times in a row (the OOM was nondeterministic).
   - New ignored test `rustc_oom_is_a_learner_error`: a huge const-eval that
     makes rustc exceed `--memory` gets 200 with stage `compile` (or
     `timeout` via 202), never a 500.
6. **Confirm under runsc** by running the **entire ignored suite** on the VM
   (`smoke.sh`, §7): network blocked, read-only root, the memory hog, the
   pids/fork bomb, the `/proc/1/fd/1` write bypass, the frozen-timer case,
   the container cleanup after cancel, plus the two new tests. The laptop
   build exports the compiled test binary (§7), so no cargo is needed on
   the VM.
7. **Required test change:** `tests/api.rs` hard-codes the image as
   `"rust-runner-sandbox"` (line 258). The ignored tests must read:
   - `RUNNER_IMAGE` (default `rust-runner-sandbox`, for local dev);
   - `RUNNER_DOCKER_RUNTIME` (already read);
   - **`RUNNER_TEST_CONTAINER_PREFIX`** (default `rr-test-<random8>-`).

   For the prefix, add `Sandbox::docker_with_prefix(image, runtime, prefix)`
   (the existing `Sandbox::docker` calls it with a random `rr-<8hex>-`).
   All Docker sandboxes in the ignored tests use that prefix, so
   `smoke.sh` can check for leftovers belonging to the test run alone. Live
   jobs also match `^rr-`.

---

## 4. Abuse protection on `/run`

### Options considered

- **API key in the app:** public once shipped. Rejected.
- **Require sign-in:** this locks out under-13 users (no accounts, under
  the COPPA decision) and anyone who doesn't sign in. Rejected.
- **Optional ID token for per-user limits:** dropped for launch
  ([DECIDED]). It adds a second key set, a second verifier and a client
  retry path, and it only helps signed-in users. It can be added later
  without changing the contract: the server ignores `Authorization` today.
- **Firebase App Check (chosen):** it attests "genuine app or web domain"
  without identifying the person.

### Threat model

App Check makes abuse **more expensive**. A script needs a real attested
device, or a browser that passes reCAPTCHA, and it must re-attest about
hourly. It does **not** stop:

- a determined attacker with real or rooted devices;
- a reCAPTCHA farm;
- someone replaying a stolen token for up to an hour.

So App Check is the first filter, and these bound the damage:

- **per-IP** limits;
- **per-token** limits (one token ≈ one device-hour);
- **fixed capacity**: one VM, 2 concurrent jobs, a queue of 16 and a 10 s
  queue timeout. Abuse can make the runner slow or busy for others. It
  cannot raise the bill (fixed-price VM) or reach other systems (gVisor, no
  network, no credentials on the host).

reCAPTCHA Enterprise score threshold: App Check's reCAPTCHA Enterprise
provider has a configurable minimum score in the Firebase console. Keep the
default at first, and raise it only if the logs show web abuse (manual step
M4).

### App Check verification (Rust)

Firebase's custom-backend docs *(search extract)* list the steps: fetch the
JWKS; check the signature; check the header is RS256 with type JWT; check
the issuer and audience (your project); check expiry; optionally check the
subject (app ID) against an allowlist. Cache the keys for up to 6 h.

The Admin Node SDK (`src/app-check/token-verifier.ts`) confirms:

- `JWKS_URL = https://firebaseappcheck.googleapis.com/v1/jwks`
- issuer prefix `https://firebaseappcheck.googleapis.com/`
- `alg RS256`
- `aud` is an array containing `projects/<project>`
- `sub` is non-empty

On 2026-10-20 the live endpoint answered `Cache-Control: public,
max-age=21600` with RSA keys that have `kid`s.

| Check | Rule |
|---|---|
| Header | `X-Firebase-AppCheck`. Missing → 401 `app_check_missing`. Over 4 KB → 401 `app_check_invalid`. |
| JOSE header | Fixed `Validation::new(Algorithm::RS256)` (never trust the token's `alg`). `typ == "JWT"`. `kid` present in the cached set. |
| Signature | `DecodingKey::from_jwk` for that `kid`. |
| `iss` | Exactly `https://firebaseappcheck.googleapis.com/<RUNNER_FIREBASE_PROJECT_NUMBER>`. |
| `aud` | Contains `projects/<RUNNER_FIREBASE_PROJECT_NUMBER>` or `projects/<RUNNER_FIREBASE_PROJECT_ID>`; set both as allowed audiences. (**Unverified** which ones real tokens carry. Step M9 checks.) |
| `exp` | Required, in the future, with 60 s leeway. |
| `sub` | In `RUNNER_APP_CHECK_APP_IDS`, else **403** `app_not_allowed`. |

**Key cache:**

- Fetch at startup. Until keys load, `/run` answers 503 `auth_unavailable`
  with `Retry-After: 5` (fail closed). Retry with backoff of 1 s, doubling,
  up to 60 s.
- Expiry is the response's `max-age`, clamped to 5 min–6 h. Refresh 5 min
  before expiry.
- An unknown `kid` triggers at most one refresh per 60 s, behind a
  `tokio::sync::Mutex`. Concurrent requests wait for it, up to 5 s.
- If a refresh fails, keep the old keys. With no successful refresh for
  24 h, drop the keys and answer 503.
- Fetch timeout is 10 s. Parse the body as JSON whatever its
  `Content-Type`.

### Replay protection (limited-use tokens): **no**

1. Consuming a token needs a call to
   `https://firebaseappcheck.googleapis.com/v1beta/projects/{projectId}:verifyAppCheckToken`
   (Admin SDK source) with Google OAuth credentials. That would put a cloud
   credential on the VM.
2. Limited-use tokens are minted for **every** request and last 5 min, not
   adjustable *(search extract)*. Each one is a new attestation, against
   Play Integrity's default 10,000 requests/day *(search extract)* and
   reCAPTCHA's 10,000 free assessments/month *(search extract)*. Normal
   tokens last 1 h by default (configurable from 30 min to 7 days).
3. The per-token limit already bounds what a replayed token can do.

### Crate

- **`jsonwebtoken` 11.1.0** (2026-09-16; 10.1 → 11.1 shipped through
  2025–26), with `default-features = false, features = ["aws_lc_rs"]`.
  - `reqwest` 0.13's default rustls already pulls in `aws-lc-rs`, so there
    is a single crypto library.
  - This avoids the `rsa` crate behind the `rust_crypto` feature, which has
    advisory RUSTSEC-2023-0071. That advisory is about private-key timing
    and doesn't affect verification, but `cargo audit` would flag it.
  - `aws-lc-sys` needs only a C/C++ compiler for non-FIPS
    `x86_64-unknown-linux-gnu`; CMake is "never required" (verified on
    aws-lc-rs's Linux requirements page). Whether `zig cc` works as that
    compiler is **Unverified**. §7 "Build and release flow" gives the
    fallback (`rust_crypto` + rustls/ring).
- Rejected: `jwt-simple` 0.15.0 (fine, but less direct JWK support).

---

## 5. Rate limits

- **In-process `governor` 0.10.4** keyed limiters. There is a single
  instance, so no external store. A restart resets the counters, which is
  acceptable.
- **`tower_governor` 0.8.0** supports axum 0.8 but keys before
  verification. Rejected for about 120 lines of our own middleware.
- **Algorithm:** GCRA token buckets. Each scope has a short bucket and an
  hourly bucket, and both must allow the request.

| Scope | Key | Short bucket | Hourly bucket | Env vars |
|---|---|---|---|---|
| **Per App Check token** (≈ per device) | HMAC-SHA256(process key, raw token) | 20/min, burst 10 | 300/hour | `RUNNER_LIMIT_TOKEN_PER_MIN`, `RUNNER_LIMIT_TOKEN_BURST`, `RUNNER_LIMIT_TOKEN_PER_HOUR` |
| **Per IP** (all `/run` requests, before auth) | IPv4 address | 120/min, burst 60 | 3000/hour | `RUNNER_LIMIT_IP_PER_MIN`, `RUNNER_LIMIT_IP_BURST`, `RUNNER_LIMIT_IP_PER_HOUR` |
| Global | — | `RUNNER_MAX_JOBS` running + ≤ `RUNNER_MAX_QUEUED` waiting (`RUNNER_QUEUE_TIMEOUT_SECS`) | — | existing + `RUNNER_MAX_QUEUED` |

**Hourly burst semantics (explicit):** the hourly bucket is
`Quota::per_hour(N)`. Its burst equals N, so the full hour's allowance is
available at once and refills at N/60 per minute. The short bucket is what
smooths requests within the hour. Example per token: at most 10 runs back
to back, then 20/min, and at most 300 within any rolling hour (sustained
5/min after that). Per IP: up to 60 back to back, then 120/min, then
sustained 50/min after 3000 in an hour.

**Why these numbers:** a learner runs 1–4 times a minute, so 20/min per
device leaves room for fast "edit, run, edit" loops. The per-IP limit is
loose so that a classroom of 30–40 or a mobile carrier's CGNAT works. The
per-device limit carries the fairness, and capacity is the real ceiling.

**Order in the `/run` gate:**

1. Client IP → per-IP buckets → 429.
2. App Check verify → 401/403.
3. Per-token buckets → 429.
4. Handler: body parse → queue cap (an `AtomicUsize` of waiters; over the
   cap → 503 `busy`) → semaphore with timeout (503 `busy`).

governor can't refund a cell when a later bucket rejects. This is accepted
and noted in a code comment.

- **Retry-After:** the rejecting bucket's
  `ceil(not_until.wait_time_from(now))` seconds, at least 1. For `busy` it is
  5.
- **Key cap:** each keyed limiter holds at most **50,000** keys
  (`RUNNER_LIMIT_MAX_KEYS`). `retain_recent()` keeps a key for up to an hour
  (the hourly bucket's period), so cleanup alone doesn't bound memory.
  - Before checking a key, if `limiter.len() >= max` and the key is new,
    reject with 429 `rate_limited` and `Retry-After: 60`, and log `warn`
    once per minute. Existing keys keep working.
  - Every 60 s, call `retain_recent()` then `shrink_to_fit()`.
  - 50k keys × 4 limiters is a few MB.
- **Disabling:** `0` disables a bucket in development only. Production
  rejects 0 for any bucket.

**Client IP behind Caddy:**

- Serve with `into_make_service_with_connect_info::<SocketAddr>()`.
- `RUNNER_TRUSTED_PROXIES` is a list of CIDRs. Production requires it, and
  the default deploy value is `127.0.0.1/32,::1/128`.
- If the peer is **not** trusted: client IP = peer IP, and `X-Forwarded-For`
  is ignored.
- If the peer **is** trusted: join all `X-Forwarded-For` values, split on
  `,`, and walk from the right, skipping trusted entries. The first one that
  parses as an IP is the client IP. If none parses, log `warn` and use the
  peer IP.
- **Why this is safe:** when the connecting client is untrusted, Caddy's
  `reverse_proxy` deletes incoming `X-Forwarded-For`/`-Proto`/`-Host` and
  sets `X-Forwarded-For` to the real client IP. By default no proxies are
  trusted (verified in `reverseproxy.go`).
- Production requires `RUNNER_ADDR` to be loopback.
- **IPv6: future.** The VM is created IPv4-only (GCE default, no
  dual-stack). If an IPv6 client IP ever appears, key it by the full
  address and log it once. Adding /64 grouping is listed as future work.
- Rejected: `axum-client-ip` 1.3.1, which doesn't check that the peer is a
  trusted proxy.

---

## 6. Edge

### Caddy

Caddy comes from its official apt repository (stable). The version is
**Unverified**: whatever is current on install day, recorded by
`smoke.sh`. Option names were checked in Caddy's `serveroptions.go`.

| Concern | Setting |
|---|---|
| Slow headers | `timeouts { read_header 10s }` |
| Slow body | `read_body 20s` |
| Long runs | `write 60s` (worst case ≈ 10 s queue + 20 s job + 5 s) |
| Keep-alive | `idle 120s` |
| Header size | `max_header_size 16KB` |
| Body | `request_body { max_size 256KB }` |
| Protocols | `protocols h1 h2` (TCP 443 only) |
| Paths | `/run`, `/health` → `reverse_proxy 127.0.0.1:8080 { transport http { dial_timeout 2s response_header_timeout 50s } }`; everything else → `respond 404` |
| Headers | `Strict-Transport-Security "max-age=31536000"`, `X-Content-Type-Options nosniff`, `-Server` |
| Logs | no `log` directive (Caddy's access log is off unless configured) |
| ACME testing | when `install.sh --acme-staging` is used, the global option `acme_ca https://acme-staging-v02.api.letsencrypt.org/directory` is rendered. Use it until the first full setup works, then rerun without it, to stay clear of Let's Encrypt production rate limits. |

There is no connection-count limit at launch: Caddy's timeouts handle
slow-loris clients, and the runner's limits handle request floods. An
nftables per-IP connection cap is future work, only if needed.

### Cloudflare: not at launch

It would add another account, a list of trusted IP ranges, origin firewall
rules and a `CF-Connecting-IP` code path. App Check plus the limits cover
app-level abuse. Revisit only under a volumetric attack.

### CORS

Handled by tower-http `CorsLayer` in the runner:

- **Origins:** an exact list from `RUNNER_ALLOWED_ORIGINS`. Production
  rejects an empty list and `*`.
- **Methods:** `GET, POST`.
- **`allow_headers`:** `content-type, x-firebase-appcheck` (new).
- **`expose_headers`:** `retry-after, x-request-id` (new). Without this,
  Flutter web can't read `Retry-After`.
- **`max_age`:** 3600 s.

---

## 7. Host hardening and deployment

### Server process: systemd service

Anyone who can use the Docker socket is root. A runner container with the
socket mounted would be no safer than a host process, so the runner is a
plain systemd service.

- It runs as the `rust-runner` user with `SupplementaryGroups=docker`.
- A compromise of the server equals host root. That is accepted because the
  VM is dedicated, holds no cloud credentials and has no service account,
  and only ports 80/443 are open.
- Rootless Docker plus runsc was rejected: gVisor has known rootless gaps
  (issues #9435, #9918, status **Unverified**), and it is more moving parts.

### What is secret on the host

- **No cloud credentials:** no service account, no keys, no deploy tokens.
- **The only secret material:** Caddy's TLS private keys and ACME account
  key in `/var/lib/caddy`. If they leak, someone could impersonate the
  runner's domain until the certificate is revoked and reissued (manual
  step: delete `/var/lib/caddy/.local/share/caddy` and restart Caddy).
- **Not secret:** Firebase project number and ID, app IDs and the App Check
  public keys.

### Docker daemon `/etc/docker/daemon.json` (in the repo as `deploy/daemon.json`)

```json
{
  "default-runtime": "runsc",
  "runtimes": { "runsc": { "path": "/usr/bin/runsc" } },
  "icc": false,
  "no-new-privileges": true,
  "userland-proxy": false,
  "live-restore": false,
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

- `/usr/bin/runsc` is verified: it is the path in the 20261012.0 `.deb`.
- The `.deb` also installs `/usr/bin/gvisor-bin/gvisor_sentry` and the other
  helpers, plus `/usr/bin/containerd-shim-runsc-v1`.
- **The `.deb` postinst runs `runsc install --clobber=false`**, then
  `systemctl reload docker`, but only if `/etc/docker/daemon.json` exists
  (verified by unpacking the package).
- So `setup-host.sh` must:
  1. install Docker;
  2. write our `daemon.json`;
  3. install the pinned `runsc` (`--clobber=false` keeps our entry);
  4. `cmp` `/etc/docker/daemon.json` with `deploy/daemon.json`, failing
     loudly on any difference;
  5. restart Docker.
- `install.sh` repeats the `cmp` on every deploy.
- **Unverified:** Docker 29 with runsc as the default runtime. `smoke.sh`
  proves it.

### userns-remap: do not enable

- No container on this host runs under runc (runner and Caddy are systemd;
  jobs are runsc).
- gVisor already runs its Sentry and Gofer unprivileged in their own
  namespaces with seccomp.
- Jobs run as `nobody` with no capabilities.
- Whether runsc works with daemon-wide userns-remap is **Unverified**.

Update the README line accordingly.

### Package pinning and upgrades

- `deploy/vars.sh` pins:
  - `RUNSC_VERSION=20261012.0`
  - `DOCKER_VERSION=5:29.9.1-1~ubuntu.24.04~noble` (for `docker-ce` and
    `docker-ce-cli`)
  - `CONTAINERD_VERSION=2.4.2-2~ubuntu.24.04~noble`
  These were current in the apt indexes on 2026-10-20.
- `setup-host.sh` installs exactly these versions, then runs `apt-mark hold
  runsc docker-ce docker-ce-cli containerd.io`.
- Upgrading Docker restarts dockerd, which kills running jobs, so these
  packages never auto-upgrade.
- **Monthly upgrade** (manual step M12): bump the versions in `vars.sh`,
  then run `push.sh --upgrade-packages`, which runs `install.sh
  --upgrade-packages`. That unholds, installs the pinned versions, re-holds,
  re-asserts `daemon.json`, restarts dockerd and the runner, and runs
  `smoke.sh`. If the smoke test fails, it reinstalls the previous versions
  (recorded in `/opt/rust-runner/packages.prev`) with `apt-get install -y
  --allow-downgrades runsc=… docker-ce=… docker-ce-cli=… containerd.io=…`,
  then re-holds them.
- runc ships inside `containerd.io`. It isn't used for jobs, but `smoke.sh`
  fails if `runc --version` is below 1.2.8 (the November 2025 escape
  fixes).
- `unattended-upgrades`: Ubuntu security pocket only (the default),
  `Automatic-Reboot "true"`, `Automatic-Reboot-Time "20:00"`. The VM clock
  is UTC, so 20:00 UTC is **03:00 Vietnam time (UTC+7)**. A reboot restarts
  everything in about a minute.
- GCE host maintenance: E2 live-migrates (`--maintenance-policy=MIGRATE`,
  the default).

### Firewall, SSH

- **VPC firewall:** allow `tcp:80,443` from anywhere to tag `rust-runner`.
  Allow `tcp:22` only from `35.235.240.0/20` (IAP). Delete or restrict the
  default network's `default-allow-ssh` and `default-allow-rdp` rules.
- **SSH:** OS Login (`enable-oslogin=TRUE`) and `gcloud compute ssh
  --tunnel-through-iap`.
- **Metadata server:** jobs have `--network none`. There is no service
  account, so the metadata server has no token to hand out.

### Sandbox image pinned by digest

- Use the official image. It installs Rust with `--profile minimal`
  (verified in rust-lang/docker-rust `stable/bookworm/slim/Dockerfile`), and
  bash and `timeout` are present.
- Pull it from **Google's Docker Hub mirror** to avoid Docker Hub's
  anonymous pull rate limits (Docker Hub answered 429 *(reviewer-verified)*):
  `RUNNER_IMAGE=mirror.gcr.io/library/rust@sha256:a24e292b4af7bdee351a31d3a6379972a5652f0ea22a1b6d6883324ac4f5097c`.
  This is the index digest of `rust:1.99.1-slim-bookworm`. The mirror served
  that digest (HTTP 200) on 2026-10-20.
- `install.sh` runs `docker pull "$RUNNER_IMAGE"`, and the runner keeps
  `--pull never`.
- `sandbox.Dockerfile` becomes `FROM <that digest>` only, kept for adding
  crates later. Its no-op `rustup component remove rust-docs` step goes.

### Health, warm-up, shutdown

- **Startup:** sweep `rr-*` containers, then run `check_sandbox`, which also
  warms the toolchain. New in production: require `runsc` in `docker info
  --format '{{json .Runtimes}}'`.
- **Liveness signal:** `last_good_job` is updated whenever *any* job
  finishes and `sandbox.run` returned `Ok`, real or self-check alike. A
  background task runs `check_sandbox` only when `last_good_job` is older
  than 10 min. It needs a free slot (`try_acquire`); if none is free, it
  retries in 30 s. Sustained load can't make the runner look unhealthy,
  because load produces good jobs.
- **`GET /health`** returns JSON, `Cache-Control: no-store`:

  ```json
  {"status":"ok","lastGoodJobSecsAgo":42,"keysReady":true,"diskFreeMb":11834,
   "runs":{"ok":1520,"compileError":310,"timeout":12,"rateLimited":4,"busy":0,"internal":0},
   "uptimeSecs":86400,"version":"0.2.0"}
  ```

  - `status` is `"ok"` (HTTP 200) when `lastGoodJobSecsAgo` ≤ 1800, keys are
    ready (if App Check is required) and `diskFreeMb` ≥ 2048. Otherwise it
    is `"unhealthy"` (HTTP 503) with the same body.
  - Disk free is `statvfs` on `/var/lib/containerd`, where Docker 29's
    containerd image store keeps images and snapshots, via the `libc`
    crate (already a transitive dependency). If that path is missing, fall
    back to `/var/lib/docker`.
  - Counters are totals since start. There is no PII in this body.
  - The uptime check content-matches `"status":"ok"`.
- **systemd:** `Restart=always`, `RestartSec=2`, `StartLimitIntervalSec=300`,
  `StartLimitBurst=10`, `TimeoutStopSec=60`, `KillMode=mixed`.
- **Logs:** journald `SystemMaxUse=500M`, `MaxRetentionSec=14day`. Jobs use
  `--log-driver none`.

### Build and release flow

**Decision: build on the laptop, ship a checked binary.** Nothing is
compiled on the serving VM.

**Why the current Dockerfile can't be used as is:** `runner/Dockerfile`
builds `FROM rust:1-slim`, which is now Debian 13 with **glibc 2.41**
*(reviewer-verified)*. Ubuntu 24.04 ships glibc 2.39, so that binary would
not run on the VM. (The earlier claim that it links against glibc 2.36 was
wrong.)

**[DECIDED] Native cross-build with cargo-zigbuild, no QEMU.** A new
`zigbuild` stage in `runner/Dockerfile`:

```dockerfile
FROM --platform=$BUILDPLATFORM rust:1.99.1-slim-bookworm@sha256:a24e292b4af7bdee351a31d3a6379972a5652f0ea22a1b6d6883324ac4f5097c AS zigbuild
ARG ZIG_VERSION=<pinned>          # a zig release cargo-zigbuild 0.23 supports; tarball sha256 pinned below
ARG ZIG_SHA256=<pinned>
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -fsSLo /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-$(uname -m)-linux-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
RUN cargo install cargo-zigbuild --version 0.23.4 --locked \
 && rustup target add x86_64-unknown-linux-gnu
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY tests ./tests
RUN cargo zigbuild --release --locked --target x86_64-unknown-linux-gnu.2.36 \
 && cargo zigbuild --release --locked --target x86_64-unknown-linux-gnu.2.36 --tests --no-run --message-format=json > /tmp/tests.json \
 && mkdir /out && cp target/x86_64-unknown-linux-gnu/release/rust-runner /out/ \
 && jq -r 'select(.reason=="compiler-artifact" and .target.name=="api" and .executable!=null) | .executable' /tmp/tests.json | xargs -I{} cp {} /out/rust-runner-tests

FROM scratch AS export
COPY --from=zigbuild /out/ /
```

(Add `jq` to the apt line. Pin `ZIG_VERSION` and `ZIG_SHA256` at
implementation time from ziglang.org's download index; which zig versions
cargo-zigbuild 0.23.4 supports is **Unverified**, so check its README and
CI. Tarball naming has been `zig-<arch>-linux-<ver>` since zig 0.14.)

- The base image is a multi-arch index pinned by digest, so with
  `--platform=$BUILDPLATFORM` the stage runs **natively** on Apple Silicon
  (arm64) and on x86. Only the *target* is x86_64.
- The `.2.36` suffix makes zig link against glibc 2.36 symbol versions,
  which is ≤ 2.39. (This is cargo-zigbuild's documented "specify glibc
  version" feature. Its README's same-host caveat no longer appears in the
  current version.)
- **C code under zig (`aws-lc-sys`):** aws-lc-rs's Linux requirements page
  says that for non-FIPS `x86_64-unknown-linux-gnu` it needs only a
  **C/C++ compiler, never CMake** (CMake and Go are only for FIPS). With
  zigbuild that compiler is `zig cc`. **Unverified:** that `aws-lc-sys`
  builds under `zig cc`.
- **First implementation task:** run this stage once. If `aws-lc-sys`
  fails under zig, switch to:
  - `jsonwebtoken` with `features = ["rust_crypto"]`;
  - `reqwest` with `default-features = false, features = ["json",
    "rustls-no-provider", "http2"]`, plus `rustls` with the `ring`
    provider installed at startup
    (`rustls::crypto::ring::default_provider().install_default()`).

  `ring` is also C and is likewise **Unverified** under zig. If that fails
  too, `cargo-zigbuild` is the wrong tool: build in a
  `rust:…-slim-bookworm` stage under `--platform=linux/amd64` and accept
  QEMU on Apple Silicon. Record the result in this doc. Under the fallback,
  `cargo audit` will flag `rsa` (RUSTSEC-2023-0071). That advisory concerns
  private-key operations only, so add it to the audit ignore list with
  that reason.
- The old `build` and runtime stages stay for local container use, but the
  `build` stage is pinned to `rust:1.99.1-slim-bookworm@sha256:…` too.

- `push.sh` on Thang's laptop (needs Docker with buildx and gcloud):
  1. **Refuse a dirty tree:** `git diff --quiet && git diff --cached
     --quiet` and no untracked files under `runner/`. Otherwise exit with
     "commit first". The release ID is `git rev-parse --short=12 HEAD`.
  2. Build from **`git archive HEAD`**, never from the working copy:
     `git archive --format=tar HEAD runner | docker buildx build -f
     runner/Dockerfile --target export -o type=local,dest=dist -`. The tar
     contains `runner/`, so the Dockerfile's `COPY` paths are relative to
     `runner/`. Use `docker buildx build ... --build-context` or adjust the
     paths accordingly when implementing.
  3. `sha256sum dist/* > dist/SHA256SUMS`. **This only guards the copy in
     transit** (truncation or corruption over SSH). It proves nothing about
     where the binary came from: anything that can tamper with the laptop
     can tamper with the binary and its sum together. Provenance comes from
     the later CI step.
  4. `tar` `dist/` and `runner/deploy/` (from `git archive HEAD
     runner/deploy`), and stream them over `gcloud compute ssh
     --tunnel-through-iap` into `~/incoming/<id>/`.
  5. Run `sudo ~/incoming/<id>/deploy/install.sh <id>`.
- `install.sh <id>` on the VM:
  1. Verify `SHA256SUMS`.
  2. **Check the binary before switching:** `./rust-runner --version` exits
     0. (Add a `--version` flag to `main.rs` that prints
     `CARGO_PKG_VERSION` and exits before reading config.) Then
     `objdump -T rust-runner | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail
     -1` must be ≤ `GLIBC_2.39`. Both checks also apply to
     `rust-runner-tests`. `setup-host.sh` installs `binutils` for
     `objdump`. On failure, abort without touching `current`.
  3. Create `/opt/rust-runner/releases/<id>/` containing `rust-runner`,
     `rust-runner-tests`, `env` (copied from `production.env`) and
     `image` (the `RUNNER_IMAGE` value).
  4. `docker pull` the image and re-assert `daemon.json`.
  5. Render the Caddyfile.
  6. Atomically repoint the symlink `/opt/rust-runner/current` → this
     release.
  7. `systemctl restart rust-runner`, reload Caddy, and wait up to 120 s
     for `/health` to report `"status":"ok"`.
  8. Run `smoke.sh`.
  9. On failure, roll back automatically (below).
  It keeps the last 3 releases and never `docker image prune`s images that
  those releases reference.
- **Rollback:** `install.sh --rollback` repoints `current` to the previous
  release. That restores **binary, env file and image digest** together,
  because the unit reads `EnvironmentFile=/opt/rust-runner/current/env` and
  `ExecStart=/opt/rust-runner/current/rust-runner`. Then it restarts and
  runs the health check.
- **Env file in git:** `runner/deploy/production.env` is committed. Every
  value is non-secret (project number and ID, app IDs, origins, domain,
  image digest, limits). This makes the deployed config versioned and
  reviewable. There is no ACME email, so Caddy runs without one, which is
  allowed. Thang's address stays out of the repo.
- **Later CI** (not designed here): CI runs **the same** `zigbuild`/`export`
  target on a stock x86 runner. It attaches `dist/` plus `SHA256SUMS` and a
  build provenance attestation to a GitHub Release, and `push.sh` then
  downloads and verifies the release instead of building. The Dockerfile is
  the single build definition for laptop and CI.

### First-run sequence (explicit)

| Step | Who / where | What |
|---|---|---|
| 1 | Thang, console/laptop | M1–M8 (§10): Firebase project, billing and **budget alert**, App Check, VM, firewall, DNS. |
| 2 | Laptop | Fill in `runner/deploy/production.env` (project number and ID, app IDs, origin, domain) and commit it. |
| 3 | Laptop | `runner/deploy/push.sh --setup`: uploads `deploy/` and runs `sudo deploy/setup-host.sh` on the VM. That installs the pinned packages, `daemon.json`, Caddy, users, journald and unattended-upgrades config, and creates `/opt/rust-runner/`. It ends with `smoke.sh --host-only` (runsc and Docker checks, no runner yet). |
| 4 | Laptop | `runner/deploy/push.sh --acme-staging`: builds, uploads and runs `install.sh <sha> --acme-staging`. That brings up the runner and gets a *staging* certificate. Run the smoke test. |
| 5 | Laptop | `runner/deploy/push.sh`: the same release again, now with the production CA. |
| 6 | Thang | M9 (end-to-end with a debug build) and M10 (uptime check). |

Every later deploy is step 5 only.

### Deployment files (`runner/deploy/`)

| File | Contents |
|---|---|
| `vars.sh` | `PROJECT`, `REGION=asia-southeast1`, `ZONE=asia-southeast1-b`, `VM=rust-runner`, pinned package versions |
| `production.env` | Runner env (below); committed |
| `daemon.json` | As above |
| `Caddyfile.template` | `{{RUNNER_DOMAIN}}`, `{{ACME_CA_LINE}}` placeholders |
| `rust-runner.service` | systemd unit (below) |
| `journald-runner.conf`, `52unattended-upgrades-runner` | Config snippets |
| `setup-host.sh` | Idempotent host setup (step 3) |
| `install.sh` | Release install, `--rollback`, `--upgrade-packages`, `--acme-staging` |
| `push.sh` | Laptop side: `--setup`, default deploy, `--acme-staging`, `--upgrade-packages`, `--rollback` |
| `smoke.sh` | Checks below; `--host-only` skips the runner parts |

**`smoke.sh` checks** (each prints PASS/FAIL; it exits non-zero on any
FAIL):

1. `runsc --version` reports exactly `$RUNSC_VERSION`.
   `/usr/bin/gvisor-bin/gvisor_sentry` exists and is executable.
2. `docker info` lists runtime `runsc`, and `Default Runtime: runsc`.
   `docker version` matches the pinned Docker version.
3. `/etc/docker/daemon.json` is byte-identical to `deploy/daemon.json`.
4. `runc --version` ≥ 1.2.8.
5. `docker run --rm --runtime runsc --network none "$RUNNER_IMAGE" dmesg`
   shows gVisor's boot messages.
6. On the host, the metadata server lists no service accounts
   (`curl -s -H 'Metadata-Flavor: Google'
   http://169.254.169.254/computeMetadata/v1/instance/service-accounts/`).
7. *(Runner parts follow.)* `PREFIX="rr-smoke-$(date +%s)-"`, then
   `RUNNER_DOCKER_RUNTIME=runsc RUNNER_IMAGE="$RUNNER_IMAGE"
   RUNNER_TEST_CONTAINER_PREFIX="$PREFIX" ./rust-runner-tests --ignored
   --test-threads=1`. This is the **full ignored Docker suite under
   runsc**:
   - network, read-only root, memory hog, `tmpfs_full_then_allocate`;
   - fork bomb, `/proc/1/fd/1` bypass, timer freeze;
   - cleanup after cancel, rustc OOM.

   Afterwards `docker ps -a --filter "name=^$PREFIX"` must be empty. Filter
   on this run's prefix only, because live jobs also match `^rr-`. The
   suite shares the host with live traffic for about a minute, which is
   acceptable. It runs with the runner's limits, and the live runner's
   watchdog only reaps its own prefix.
8. `curl http://127.0.0.1:8080/health` has `"status":"ok"`. `POST /run`
   through Caddy with no header gets 401. `systemd-analyze security
   rust-runner` output is printed for information only.
9. `rust-runner --self-check` five times, printing durations (latency
   baseline).

**`rust-runner.service`:**

```ini
[Unit]
Description=Rust code runner
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
User=rust-runner
Group=rust-runner
SupplementaryGroups=docker
EnvironmentFile=/opt/rust-runner/current/env
Environment=DOCKER_CONFIG=/run/rust-runner/docker
RuntimeDirectory=rust-runner
ExecStart=/opt/rust-runner/current/rust-runner
Restart=always
RestartSec=2
TimeoutStopSec=60
KillMode=mixed
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
MemoryMax=512M

[Install]
WantedBy=multi-user.target
```

**Unverified:** that the docker CLI works under these flags. `smoke.sh`
step 7/8 proves it. If a flag breaks it, remove that one flag.

---

## 8. Implementation spec (runner)

### Environment variables

Existing variables keep their meaning. New or changed:

| Variable | Default | Validation | Production rule |
|---|---|---|---|
| `RUNNER_ENV` | `production` | `production` \| `development` | fail-closed default |
| `RUNNER_ADDR` | `0.0.0.0:8080` | socket address | must be loopback |
| `RUNNER_APP_CHECK` | `required` if production, `off` if development | `required` \| `off` | must be `required` |
| `RUNNER_FIREBASE_PROJECT_NUMBER` | — | digits, 1–20 | required when App Check is required |
| `RUNNER_FIREBASE_PROJECT_ID` | — | `^[a-z][a-z0-9-]{4,29}$` | optional (adds the second audience) |
| `RUNNER_APP_CHECK_APP_IDS` | — | comma list, each `^\d+:\d+:(android\|ios\|web):[0-9a-f]+$` | non-empty when required; also gives `platform` for logs |
| `RUNNER_APP_CHECK_JWKS_URL` | `https://firebaseappcheck.googleapis.com/v1/jwks` | URL; `http` only in development | must be the default |
| `RUNNER_TRUSTED_PROXIES` | empty | CIDR list | non-empty |
| `RUNNER_LIMIT_TOKEN_PER_MIN` / `_TOKEN_BURST` / `_TOKEN_PER_HOUR` | 20 / 10 / 300 | u32, burst ≤ rate | > 0 |
| `RUNNER_LIMIT_IP_PER_MIN` / `_IP_BURST` / `_IP_PER_HOUR` | 120 / 60 / 3000 | u32, burst ≤ rate | > 0 |
| `RUNNER_LIMIT_MAX_KEYS` | 50000 | 1000–1,000,000 | |
| `RUNNER_MAX_QUEUED` | 16 | 0–1000 | |
| `RUNNER_DOCKER_RUNTIME` | unset | | must be `runsc` |
| `RUNNER_ALLOW_RUNC` | unset | | must be unset |
| `RUNNER_SANDBOX` | docker | | `local` refused |
| `RUNNER_ALLOWED_ORIGINS` | empty | `https://host[:port]` list (`http` in development) | non-empty, no `*` |
| `RUNNER_LOG_FORMAT` | `json` in production, `text` in development | `json` \| `text` | |
| `RUST_LOG` | `info` | EnvFilter | |

Notes:

- `RUNNER_MEMORY_MB` validation rises to ≥ `tmpfs_mb + 192` = 320 at the default tmpfs (section 3).
- `RUNNER_DOMAIN` in the env file is read by `install.sh` only. The runner
  ignores it.
- `config.rs` exposes `Config::from_env_map(&HashMap<String, String>) ->
  Result<Config, Vec<String>>`. It reports every problem at once, and
  `main` prints them and exits with code 2.

`runner/deploy/production.env`:

```
RUNNER_ENV=production
RUNNER_ADDR=127.0.0.1:8080
RUNNER_DOCKER_RUNTIME=runsc
RUNNER_IMAGE=mirror.gcr.io/library/rust@sha256:a24e292b4af7bdee351a31d3a6379972a5652f0ea22a1b6d6883324ac4f5097c
RUNNER_MAX_JOBS=2
RUNNER_MAX_QUEUED=16
RUNNER_TRUSTED_PROXIES=127.0.0.1/32,::1/128
RUNNER_ALLOWED_ORIGINS=https://REPLACE-web-app-domain
RUNNER_FIREBASE_PROJECT_NUMBER=REPLACE
RUNNER_FIREBASE_PROJECT_ID=REPLACE
RUNNER_APP_CHECK_APP_IDS=REPLACE-android,REPLACE-ios,REPLACE-web
RUNNER_DOMAIN=runner.REPLACE
```

`install.sh` refuses a file that still contains `REPLACE`.

### Dev-flow changes (README, Dockerfile, `cargo run`)

- **README "Running":** `RUNNER_ENV=development RUNNER_ALLOW_RUNC=1 cargo
  run --release`. Plain `cargo run` now exits, asking for production
  config, which is intended. Document `RUNNER_ENV=development
  RUNNER_SANDBOX=local` for machines without Docker. Update the settings
  list. Replace "Before going live" with a link to this doc. Add the 40
  threads / 320 MB note, the `/health` JSON and the new error codes.
- **Dockerfile:** it becomes the build recipe (`build` + `export` stages).
  The runtime stage stays for local container use, but its `ENV` line
  becomes `RUNNER_ENV=development RUNNER_ADDR=0.0.0.0:8080`. Drop the
  baked-in `RUNNER_DOCKER_RUNTIME=runsc`: production doesn't use this image,
  and a dev runs whichever runtime they have. Bump `docker:28-cli` to
  `docker:29-cli`.
- **`sandbox.Dockerfile`:** `FROM` the pinned digest only.
- **Tests:** `tests/api.rs` builds state via the new
  `AppState::for_tests(sandbox, limits)` (auth off, limits off) and wraps
  the router in `MockConnectInfo`. Nothing reads env vars, so `cargo test`
  is unaffected by `RUNNER_ENV`.
- **App dev:** `flutter run --dart-define=RUNNER_URL=http://localhost:8080`
  against a development runner works unchanged, with no App Check.

### HTTP contract

**`POST /run`**

- Headers: `Content-Type: application/json` and `X-Firebase-AppCheck` (in
  production). `Authorization` is ignored.
- Body: unchanged.
- Every response carries `X-Request-Id`.
- Errors are `{"error": "<message>", "code": "<code>"}`. `error` stays for
  older builds.

| Status | `code` | When | Headers |
|---|---|---|---|
| 200 | — | run result (unchanged) | |
| 400 | `code_empty` | | |
| 400/415/422 | `bad_request` | JSON rejection | |
| 401 | `app_check_missing` | header absent (when required) | |
| 401 | `app_check_invalid` | signature, claims, expiry or unknown `kid` | |
| 403 | `app_not_allowed` | valid token, `sub` not allowlisted | |
| 413 | `code_too_long` | | |
| 429 | `rate_limited` | any bucket or key cap | `Retry-After` |
| 500 | `internal` | sandbox failure (now rare; see §3) | |
| 503 | `busy` | queue cap or queue timeout | `Retry-After: 5` |
| 503 | `shutting_down` | | |
| 503 | `auth_unavailable` | no usable keys | `Retry-After: 5` |
| 408 | empty | overall timeout (unchanged) | |

401 messages are generic ("This app couldn't be verified."). The specific
reason goes only to logs (`auth_error`).

**`GET /health`:** JSON (§7). No auth, no rate limit.

### Module layout (`runner/src/`)

```
lib.rs        router, AppState (+ for_tests), `/run` handler
main.rs       Config → state → background tasks → serve with ConnectInfo; `--self-check` runs check_sandbox once (exit 0/1)
config.rs     Config, from_env_map, production rules
errors.rs     ApiError { status, code, message, retry_after } + IntoResponse
gate.rs       `/run` middleware: client IP → IP buckets → App Check → token buckets; puts `Caller { app_id, platform, token_key }` in extensions
client_ip.rs  TrustedProxies, client_ip(peer, headers)
app_check.rs  KeyCache (trait KeySource; HttpKeySource via reqwest; StaticKeySource for tests; refresh task; kid-miss refresh) + verify()
ratelimit.rs  RateLimits (ip_short, ip_long, token_short, token_long) over governor, key cap, cleanup task
telemetry.rs  tracing init, Hasher (HMAC-SHA256 with a random key per process start), counters, 60 s summary
health.rs     HealthState (last_good_job, keys_ready, disk_free) + idle self-check task
sandbox.rs    §3 fixes; production runtime check helper
```

### Crates

| Crate | Version | Features | Use |
|---|---|---|---|
| `jsonwebtoken` | `11.1.0` | `default-features = false, features = ["aws_lc_rs"]` | JWT/JWK verification |
| `reqwest` | `0.13.5` | defaults + `json` | JWKS fetch |
| `governor` | `0.10.4` | defaults | rate limits |
| `aws-lc-rs` | `1.18.2` | defaults | HMAC (already transitive) |
| `libc` | `0.2` (already transitive) | — | `statvfs` |
| `tracing-subscriber` | `0.3.23` (existing) | add `json`, `env-filter` | logs |

Dev: `jsonwebtoken` with `use_pem` for minting test tokens. Check `cargo
tree -d` for a single `aws-lc-rs`. The `jsonwebtoken` 11.x API names
(`DecodingKey::from_jwk`, `jwk::JwkSet`, `Validation::{set_audience,
set_issuer, leeway}`) exist in 8.x–10.x; **Unverified** for 11.x, so check
docs.rs.

### Test plan

Fixtures in `runner/tests/fixtures/`, clearly named as test-only keys:

- two RSA keys generated with `openssl genpkey -algorithm RSA -pkeyopt
  rsa_keygen_bits:2048`;
- `jwks.json` with both public keys, `kid` `test-1` / `test-2`.

Unit tests:

- `config.rs`: production with nothing set → every missing item listed.
  `RUNNER_APP_CHECK=off` in production → error. Development with nothing set
  → OK, App Check off. `*` origin in production → error. Malformed app ID →
  error. A limit of 0 in production → error.
- `client_ip.rs`: untrusted peer with spoofed XFF → peer. Trusted peer →
  rightmost entry. Trusted entries skipped. Garbage → peer. Multiple
  headers are joined.
- `app_check.rs`:
  - valid → OK;
  - expired 61 s ago → error; expired 30 s ago → OK (leeway);
  - wrong `iss` → error; `aud` without the project → error;
  - `sub` not allowlisted → `AppNotAllowed`;
  - unknown `kid` → error;
  - HS256 signed with the public key as secret → error; `alg: none` →
    error;
  - missing `typ` → error;
  - wrong key for the `kid` → error;
  - token over 4 KB → error.
- Key cache, with `start_paused` time and a counting fake source:
  - `max-age` clamps and refresh before expiry;
  - 50 concurrent unknown-`kid` lookups → 1 fetch;
  - a second unknown `kid` within 60 s → no fetch;
  - a failed fetch keeps the old keys;
  - 24 h with no success → not ready.
- `ratelimit.rs`, with governor's `FakeRelativeClock`:
  - burst then reject; `Retry-After` correct;
  - the hourly cap bounds the sustained rate;
  - the key cap rejects new keys while existing keys still pass;
  - `retain_recent` drops idle keys.
- `sandbox.rs` `interpret()` cases from §3.

Integration tests (`tests/api.rs` and a new `tests/app_check.rs`, using
`Sandbox::Local` and `StaticKeySource`):

- **Auth:** no header → 401 `app_check_missing`. Bad token → 401
  `app_check_invalid`. Valid → 200. Valid with `Authorization: garbage` →
  200 (ignored). Failing key source → 503 `auth_unavailable`.
- **Limits:** with `TOKEN_PER_MIN=1, BURST=1`, the second request with the
  same token gets 429 and `Retry-After`, and a different token passes. Two
  XFF IPs from a trusted peer get separate IP buckets; from an untrusted
  peer they share one.
- **CORS:** a preflight for `x-firebase-appcheck` from an allowed origin
  passes; another origin gets no `Access-Control-Allow-Origin`.
  `retry-after` is exposed.
- **Queue cap:** with `MAX_JOBS=1, MAX_QUEUED=0`, a second concurrent
  request gets 503 `busy` immediately.
- **Health:** fresh state with no good job → 503; after one run → 200, and
  the JSON has the expected keys.
- **JWKS over HTTP:** a local axum server on `127.0.0.1:0` serves
  `jwks.json` with `max-age=300` and counts hits. `HttpKeySource` parses it
  and honours the header.
- **Log hygiene:** capture `tracing` output to a buffer. Run code containing
  a marker and send a token containing a marker. Assert that neither
  marker, nor the client IP string, appears in the logs.
- **Ignored Docker tests:** the existing ones, adjusted per §3, plus
  `rustc_oom_is_a_learner_error`. They run on the VM via `smoke.sh` under
  runsc.

---

## 9. App client changes

### Package and platform setup

- `firebase_app_check: ^0.5.0`: published 2026-10-15, depends on
  `firebase_core: ^5.0.0`, Dart `^3.6.0`, Flutter ≥ 3.27. Breaking change:
  `activate` takes `providerWeb` / `providerAndroid` / `providerApple`.
- **Android:** no extra change. `firebase_core` 5.0.0 itself already
  requires minSdk 24 (its changelog says "require minSdk 24"). If the
  current `flutter.minSdkVersion` is lower, that is already a problem with
  the existing dependency, separate from App Check.
- **iOS: code change.** The repo has no `ios/Runner/*.entitlements`, and
  the deployment target is 15.0, so App Attest is available.
  - Add `ios/Runner/Runner.entitlements` containing
    `com.apple.developer.devicecheck.appattest-environment` = `production`.
  - Set `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` in the
    **Runner target's** three build configurations (Debug, Release,
    Profile) in `ios/Runner.xcodeproj/project.pbxproj`. These are the
    `XCBuildConfiguration` blocks that contain `INFOPLIST_FILE =
    Runner/Info.plist;`, currently around lines 397, 578 and 600. **Not**
    the project-level blocks that set `IPHONEOS_DEPLOYMENT_TARGET`.
  - Manual step M4b: enable the App Attest capability on the App ID in the
    Apple Developer portal. **Unverified** whether `production` must be
    switched to `development` for local device builds. Debug builds use the
    debug provider, so it shouldn't matter.
- **Web:** reCAPTCHA Enterprise. Release builds pass
  `--dart-define=APP_CHECK_WEB_SITE_KEY=…`.

### Activation (`lib/main.dart`, after `Firebase.initializeApp`)

```dart
const _debugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');
const _webSiteKey = String.fromEnvironment('APP_CHECK_WEB_SITE_KEY');

Future<bool> _activateAppCheck() async {
  try {
    if (kIsWeb && !kDebugMode && _webSiteKey.isEmpty) return false;
    final debug = _debugToken.isEmpty ? null : _debugToken;
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? AndroidDebugProvider(debugToken: debug)
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? AppleDebugProvider(debugToken: debug)
          : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      providerWeb: kDebugMode
          ? WebDebugProvider(debugToken: debug)
          : ReCaptchaEnterpriseProvider(_webSiteKey),
    );
    return true;
  } catch (e) {
    debugPrint('App Check is off: $e');
    return false;
  }
}
```

- Don't call `FirebaseApp.configure()` in `AppDelegate`. FlutterFire warns
  that `providerApple` is then ignored on devices.
- Debug tokens are registered in the console and passed only through
  `--dart-define` in debug builds. Never commit them. If one leaks, revoke
  it, because it works against production.

### `lib/runner/code_runner.dart`

```dart
/// Proves to the runner that the request comes from this app.
abstract class RunnerAuth {
  /// App Check token, or null if unavailable.
  Future<String?> appCheckToken({bool refresh = false});
}

class NoRunnerAuth implements RunnerAuth {
  const NoRunnerAuth();
  @override
  Future<String?> appCheckToken({bool refresh = false}) async => null;
}
```

- `FirebaseRunnerAuth` lives in `lib/runner/firebase_runner_auth.dart`, so
  tests don't need plugins. It calls
  `FirebaseAppCheck.instance.getToken(refresh)` with a 10 s timeout and
  returns null on any error (the error is logged, never the token).
- `HttpCodeRunner(baseUrl, {client, RunnerAuth auth = const NoRunnerAuth()})`
  sends `X-Firebase-AppCheck` when the token is non-null.
- On 401 with code `app_check_invalid`, or `app_check_missing` when a
  refreshed token is now available, it refreshes **once** and retries
  **once**. The 45 s budget covers both attempts.
- `codeRunnerFromEnvironment({RunnerAuth auth = const NoRunnerAuth()})`.
  `main.dart` passes `FirebaseRunnerAuth()` when Firebase and App Check both
  started.

`errorMessage` matches on `code` first:

| Status / code | Message |
|---|---|
| 401 (any) | "This copy of the app couldn't be verified, so code can't run right now. Make sure the app is up to date (from the App Store or Google Play) and try again." |
| 403 | "This version of the app can't run code. Please update the app." |
| 429 `rate_limited` | "You're running code very quickly. Try again in N seconds." (N from `Retry-After`; without it, "Try again in a minute.") |
| 503 `busy` / `auth_unavailable`, 429 without code | existing "The code runner is busy…" text |

Tests (`MockClient` and a fake `RunnerAuth`):

- the header is present or absent as expected;
- 401 `app_check_invalid` → one retry with `refresh: true` → success;
- a second 401 → message, and no third request;
- 429 with and without `Retry-After`;
- 403;
- `NoRunnerAuth` sends no header.

---

## 10. Observability and manual steps

### Logs

JSON lines to journald. The per-request event `run_finished` has these
fields:

- `request_id`
- `outcome`: `ok` / `compile_error` / `timeout` / `mem_limit` /
  `rate_limited` / `auth_failed` / `busy` / `bad_request` / `internal`
- `stage`, `status`, `queue_ms`, `duration_ms`
- `code_bytes`, `stdout_bytes`, `stderr_bytes`, `truncated`
- `platform`: `android` / `ios` / `web` / `none`
- `limiter`, on 429
- `auth_error`, on 401/403
- `client`: HMAC-SHA256(per-process random key, IP) cut to 12 hex chars,
  for same-day correlation only

**Never logged:** code, stdout/stderr/warnings, tokens or any header
values, the full IP, the user agent, or compiler stderr from failed starts
(§3, item 4).

Summary every 60 s: runs by outcome, average and max `duration_ms` and
`queue_ms`, `slots_busy`, `queued`, limiter key counts, key-cache age.
Startup events: non-default config values, runsc and Docker versions, image
digest, self-check result.

No Prometheus. Nothing would scrape it, and it would need a service
account.

### Manual steps only Thang can do

| # | Step |
|---|---|
| M1 | Create the Firebase project (docs/firebase-setup.md step 1). Note the **project number** and **project ID**. |
| M2 | Enable billing **and create a budget alert (required)**: Billing → Budgets & alerts, $60/month, email at 50/90/100 %. |
| M3 | Register the apps (`flutterfire configure`) and note the three **App IDs**. |
| M4 | App Check console. **Android:** Play Integrity, linked to Play Console, with the SHA-256 app-signing fingerprint. **iOS:** App Attest and DeviceCheck (Team ID, DeviceCheck key). **Web:** reCAPTCHA Enterprise key for the web domain, minimum score at the default; raise it only if web abuse shows in the logs. Leave the token TTL at 1 h. Don't enable App Check *enforcement* for Firestore/Auth here; that is a separate decision. |
| M4b | Apple Developer portal: enable the **App Attest** capability on the app's App ID. |
| M5 | Register a debug token for dev devices and emulators. Keep it out of git. |
| M6 | Create the VM (values from `vars.sh`): `gcloud compute instances create rust-runner --zone asia-southeast1-b --machine-type e2-medium --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud --boot-disk-size 20GB --boot-disk-type pd-balanced --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring --no-service-account --no-scopes --tags rust-runner --metadata enable-oslogin=TRUE`. Reserve and attach a static external IPv4. |
| M7 | Firewall: allow `tcp:80,443` (tag `rust-runner`) and `tcp:22` from `35.235.240.0/20`. **Delete `default-allow-ssh` and `default-allow-rdp`.** Grant yourself `roles/iap.tunnelResourceAccessor`. |
| M8 | DNS `A` record `runner.<domain>` → the static IP, before step 4 of the first run. |
| M9 | End-to-end: a debug build with `--dart-define=RUNNER_URL=https://runner.<domain> --dart-define=APP_CHECK_DEBUG_TOKEN=…`, then press Run. To check the claim format, print one token in that debug session and decode it **locally**: `echo "$TOKEN" \| cut -d. -f2 \| tr '_-' '/+' \| base64 -d 2>/dev/null \| jq .` (add `=` padding if `base64` complains). Never paste it into a website. Check `iss` and `aud` against §4, then check that a request with no header gets 401. |
| M10 | Cloud Monitoring uptime check on `https://runner.<domain>/health` every 5 min, content match `"status":"ok"`, email alert. **Unverified:** that this stays within the free allotment. |
| M11 | Release builds with `RUNNER_URL` (and `APP_CHECK_WEB_SITE_KEY` on web). Review the store privacy forms for App Check / Play Integrity (**Unverified** what is required). |
| M12 | **Monthly:** bump the pinned runsc, Docker and containerd versions and the sandbox image digest, then `push.sh --upgrade-packages` and a deploy. The smoke test gates both. |
| M13 | **Weekly (10 min):** `gcloud compute ssh rust-runner --tunnel-through-iap -- 'journalctl -u rust-runner --since -7d -o cat \| jq -c "select(.event==\"summary\")" \| tail -50'`. Look at the 429/401/`internal` counts, queue max and disk free. Also skim `journalctl -p warning --since -7d`. |

---

## 11. Sources

Fetched directly (2026-10-20):

- gVisor install guide: https://github.com/google/gvisor/blob/master/g3doc/user_guide/install.md
- gVisor platforms guide: https://github.com/google/gvisor/blob/master/g3doc/architecture_guide/platforms.md
- systrap README: https://github.com/google/gvisor/blob/master/pkg/sentry/platform/systrap/README.md
- gVisor Docker quick start: https://github.com/google/gvisor/blob/master/g3doc/user_guide/quick_start/docker.md
- gVisor apt index and the 20261012.0 `.deb` (postinst; `/usr/bin/runsc`; `/usr/bin/gvisor-bin/gvisor_sentry`): https://storage.googleapis.com/gvisor/releases/dists/release/main/binary-amd64/Packages
- Firebase Admin Node SDK: https://github.com/firebase/firebase-admin-node/blob/master/src/app-check/token-verifier.ts, https://github.com/firebase/firebase-admin-node/blob/master/src/utils/jwt.ts, https://github.com/firebase/firebase-admin-node/blob/master/src/app-check/app-check-api-client-internal.ts
- App Check JWKS (live, `max-age=21600`): https://firebaseappcheck.googleapis.com/v1/jwks
- FlutterFire App Check source: https://github.com/firebase/flutterfire/tree/main/packages/firebase_app_check
- firebase_app_check changelog: https://pub.dev/packages/firebase_app_check/changelog
- firebase_core changelog (5.0.0 requires minSdk 24): https://github.com/firebase/flutterfire/blob/main/packages/firebase_core/firebase_core/CHANGELOG.md
- crates.io: jsonwebtoken 11.1.0, governor 0.10.4, tower_governor 0.8.0, reqwest 0.13.5, axum-client-ip 1.3.1, aws-lc-rs 1.18.2
- Caddy `reverseproxy.go` and `serveroptions.go`: https://github.com/caddyserver/caddy
- Docker apt index (docker-ce 29.9.1, containerd.io 2.4.2): https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-amd64/Packages
- runc branches: https://github.com/opencontainers/runc
- Rust slim Dockerfile: https://github.com/rust-lang/docker-rust/blob/master/stable/bookworm/slim/Dockerfile
- Docker Hub digest of `rust:1.99.1-slim-bookworm`; mirror.gcr.io served the same digest: https://mirror.gcr.io/v2/library/rust/manifests/sha256:a24e292b4af7bdee351a31d3a6379972a5652f0ea22a1b6d6883324ac4f5097c
- Rust stable 1.99.1: https://static.rust-lang.org/dist/channel-rust-stable.toml
- Cloud Run pricing: https://cloud.google.com/run/pricing

Search extracts and third-party sources (re-verify before relying on them):

- Firebase custom-backend verification: https://firebase.google.com/docs/app-check/custom-resource-backend
- Limited-use tokens: https://firebase.google.com/docs/ai-logic/app-check
- Token TTL: https://firebase.google.com/docs/reference/appcheck/rest/v1/projects.apps.playIntegrityConfig
- Play Integrity quota: https://support.google.com/googleplay/android-developer/contact/piaqr
- App Check web / reCAPTCHA Enterprise: https://firebase.google.com/docs/app-check/web
- reCAPTCHA tiers: https://docs.cloud.google.com/recaptcha/docs/compare-tiers
- Cloud Run execution environments: https://docs.cloud.google.com/run/docs/about-execution-environments
- Cloud Run container contract: https://docs.cloud.google.com/run/docs/container-contract (not fetched)
- GCE prices: https://gcloud-compute.com/e2-medium.html, https://www.economize.cloud/resources/gcp/pricing/compute-engine/e2-standard-2/
- Hetzner: https://privatedevops.com/news/hetzner-june-2026-cloud-price-increase-what-to-do
- DigitalOcean: https://kuberns.com/blogs/digitalocean-pricing/
- gVisor rootless issues: https://github.com/google/gvisor/issues/9435, https://github.com/google/gvisor/issues/9918
- Earlier research: `/mnt/project-files/research/2026-10-18-decisions.md` §3

### Unverified items

1. Which audiences real App Check tokens carry (M9 checks).
2. `aws-lc-sys` (and the `ring` fallback) building under `zig cc`. Also
   which zig versions cargo-zigbuild 0.23.4 supports. This is the first
   implementation task.
3. jsonwebtoken 11.x API names.
4. Docker 29 with runsc as the default runtime (`smoke.sh` checks).
5. runsc with userns-remap (not used).
6. systemd flags with the docker CLI (`smoke.sh` checks).
7. e2-medium price in asia-southeast1; GCLB cost; uptime-check free allotment.
8. Caddy's current version.
9. Run latency under gVisor (`smoke.sh` measures).
10. App Attest entitlement value for local device builds.
11. Store privacy-form requirements for App Check.
12. Whether the 320 MB program cap plus a full 128 MB tmpfs stays below the
    point where the sandbox dies (`tmpfs_full_then_allocate` checks).

---

## 12. Review round 1: changelog

Changed:

1. **gVisor memory (blocker):** new §3. The program-only `ulimit -v` (384 MB
   at 512 MB) is passed as a 4th script argument. rc 134 + "memory
   allocation of" and rc 137 with no marker now give learner results instead
   of a 500. The leaky compiler-stderr error log is cut. The memory floor
   rises to 256 MB. There are new `interpret()` unit tests and an ignored
   rustc-OOM test, and the full ignored suite runs under runsc in `smoke.sh`,
   shipped as a prebuilt test binary.
2. **iOS App Attest:** added `Runner.entitlements` and
   `CODE_SIGN_ENTITLEMENTS` as code changes, and portal step M4b. I
   verified that the repo has no entitlements file and the target is 15.0.
3. **ID tokens removed** [DECIDED]: `id_token.rs`, the second JWKS, the
   per-user limits, the `id_token_invalid` code and the client branch are
   all gone. `Authorization` is ignored.
4. **Per-app bucket removed** [DECIDED]. A per-token bucket (HMAC of the
   token) replaces it. There is an explicit threat model (§1 #4, §4) and a
   reCAPTCHA score note (M4).
5. **Limits loosened:** per IP 120/min, burst 60, 3000/hour. Per token
   20/min, burst 10, 300/hour. Hourly burst semantics are spelled out.
6. **Key cap** of 50k per limiter (new keys get 429). IPv6 /64 grouping and
   the nftables rules are cut (marked future). The failed-auth bucket is
   also cut: the per-IP bucket already counts failures.
7. **Image source:** `mirror.gcr.io/library/rust@sha256:a24e…`. I verified
   that the mirror serves that digest.
8. **Deploy:**
   - an explicit first-run table;
   - the binary is built on the laptop with Docker buildx (linux/amd64) and
     shipped with `SHA256SUMS`; no cargo or rustup on the VM;
   - release directories plus a `current` symlink, so rollback restores
     binary, env and image together;
   - `production.env` is committed (all values are non-secret), and the
     ACME email is dropped.
9. **Pinned packages:** `runsc`, `docker-ce`, `docker-ce-cli` and
   `containerd.io` are pinned and held, with monthly gated upgrades. The
   region is `asia-southeast1` (a variable in `vars.sh`). Reboots are at
   20:00 UTC = 03:00 UTC+7. The Singapore e2-medium price **could not be
   verified** (blocked); it is estimated at about $30 and marked
   Unverified.
10. **Host checks:** `smoke.sh` asserts `gvisor_sentry`, the exact runsc
    version and a byte-identical `daemon.json`. `daemon.json` is written
    before the runsc install. I verified that the postinst runs `runsc
    install --clobber=false` only when `daemon.json` exists.
11. **Health:** any successful job counts as liveness. The self-check runs
    only when idle for 10 min.
12. **Config:** `RUNNER_APP_CHECK` defaults to `off` in development. Added
    the README, Dockerfile, `sandbox.Dockerfile`, `cargo run` and test
    changes.
13. **Secrets:** stated that `/var/lib/caddy` holds TLS and ACME keys.
    Added `--acme-staging` for setup.
14. **Budget alert required** (M2). `/health` returns JSON with counters
    and disk free for content matching. Weekly log review (M13).
15. **Debug token:** decoded locally with `cut | base64 -d` (M9).
16. **minSdk:** reworded; it is `firebase_core` 5.0.0's own requirement.

Also cut as overengineering for launch: the 24 h daily HMAC key rotation
(now one key per process), the histogram percentiles in the summary (now
average and max), `tower-http` request-id features (set in the middleware),
`TasksMax` and a few lesser systemd flags, and `jti` tracking.

Rejected or adjusted:

- **"Use systemd-run MemoryMax and CARGO_BUILD_JOBS=1 to build on the VM"**:
  I chose the other option the reviewer offered, building elsewhere. A
  release build on a 4 GB shared-core VM would compete with live jobs for
  minutes. It would also need rustup on the host, more attack surface and
  disk.
- **Run the ignored suite with cargo on the VM**: adjusted. A prebuilt test
  binary from the laptop build is used instead, which keeps the VM
  toolchain-free.
- **IPv6**: not supported, rather than half-supported. The VM is
  IPv4-only, and a stray IPv6 key is handled by full-address keying.

## 13. Review round 2: changelog

1. **Exit 137 with no marker is no longer a learner result.**
   - Added a compile-start marker (`\001RR-COMPILE\n` on stdout before
     rustc).
   - No start marker plus 137 (docker CLI killed, dockerd restart, sweep
     `rm -f`, sentry crash) → `Err`/500.
   - Start marker but no run marker plus 137 → compile `mem_limit`.
   - `last_good_job` is set only on a compiler verdict (run marker present,
     or rc 201). A host that keeps killing jobs therefore fails the idle
     self-check and goes unhealthy.
   - New `mem_limit_rate_high` warning, and `runs.memLimit` in `/health`.
   - New unit tests, including (no markers, 137) → `Err`.
2. **Program cap = memory − tmpfs − 64 MB = 320 MB** at the defaults. I
   picked the formula and kept the 128 MB tmpfs, because shrinking the
   tmpfs to 64 MB with a 384 MB cap would sit exactly at the ~448 MB death
   point. `tmpfs_mb` becomes a `Limits` field. New ignored test
   `tmpfs_full_then_allocate`, run 5 times. The memory floor is now
   tmpfs + 192 MB.
3. **Build** [DECIDED]:
   - the false glibc 2.36 claim is corrected (`rust:1-slim` = Debian 13 /
     glibc 2.41);
   - a native `FROM --platform=$BUILDPLATFORM` stage pinned by digest uses
     cargo-zigbuild 0.23.4 to target `x86_64-unknown-linux-gnu.2.36`, with
     zig pinned by version and sha256 (no QEMU);
   - `push.sh` refuses a dirty tree and builds from `git archive HEAD`;
   - `install.sh` checks `--version` and the highest GLIBC symbol ≤ 2.39
     (via `objdump`, so `binutils` is added) before switching `current`;
   - SHA256SUMS is described as guarding transit only;
   - a later CI runs the same target.
   - aws-lc-rs needs no CMake for non-FIPS x86_64 (verified). `zig cc`
     compatibility is **Unverified**, so building it is the first
     implementation task. The fallback is `rust_crypto` plus rustls/ring,
     with QEMU as the last resort.
4. **`smoke.sh`** filters on its own `RUNNER_TEST_CONTAINER_PREFIX`. Listed
   as required changes: the ignored tests must read `RUNNER_IMAGE`
   (`tests/api.rs:258` hard-codes `rust-runner-sandbox`) and the prefix,
   and `Sandbox::docker_with_prefix` must be added.
5. **`CODE_SIGN_ENTITLEMENTS`** goes in the Runner target's configurations
   (the blocks with `INFOPLIST_FILE = Runner/Info.plist`, lines 397/578/600,
   verified).
6. **Nits:** package rollback uses `apt-get install --allow-downgrades`;
   disk free comes from `/var/lib/containerd`, falling back to
   `/var/lib/docker`.
