# Continuous integration

`.github/workflows/ci.yml` runs on every push to `main`, every pull request,
and by hand (Actions → CI → Run workflow). A new push to the same pull
request cancels the older run.

Every action is pinned to a full commit SHA, with the release in a comment.
Dependabot (`.github/dependabot.yml`) opens a weekly pull request when a
newer action or a newer `functions/` npm package exists.

| Job | What it checks | Run it locally |
| --- | --- | --- |
| `flutter` | `flutter analyze` and `flutter test` on Flutter 3.47.7 | `flutter pub get && flutter analyze && flutter test` |
| `lessons` | Rust 1.99.1 (the sandbox's). Builds `rr-grade`, then every lesson example compiles (edition 2024) and every exercise is graded with its tests: the solution passes all of them, the starter fails one (`--self-test` checks the checker itself); every error-explanation example fails with its own error code or message, and every code is still emitted; every translated file under `assets/content/<lang>/` matches its English source; the checker's own tests | `cargo build --release --locked -p rr-grade` in `runner/`, then `python3 tool/check_lessons.py --self-test`, `python3 tool/check_lessons.py`, `python3 tool/test_check_lessons.py`, `python3 tool/check_errors.py` |
| `compat` | For every git tag `v*` (one per store release): extracts that tag's `assets/content/lessons` and runs `check_lessons.py --strict --lessons-dir` on it with the `rr-grade` built from the current commit, so released app bundles stay gradable. No tags: passes, nothing to check. See "Grade API versions" in `runner/docs/production-design.md` | build `rr-grade` as for `lessons`, then `git archive v1.0.0 assets/content/lessons \| tar -x -C /tmp/v1.0.0` and `python3 tool/check_lessons.py --strict --lessons-dir /tmp/v1.0.0/assets/content/lessons` |
| `runner` | `cargo fmt --all --check`, `cargo clippy -D warnings`, `cargo test`, for the server and the `rr-grade` crate | in `runner/`: `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace` |
| `runner-sandbox` | Builds the sandbox image and runs the Docker test (limits, no network) | in `runner/`: `docker build -t rust-runner-sandbox -f sandbox.Dockerfile . && cargo test -- --ignored` |
| `runner-gvisor` (arm64 and amd64) | The real sandbox: builds the runner with `runner/deploy/Dockerfile.build`, installs the pinned gVisor `.deb` (version and sha256 from `runner/deploy/vars.sh`) and `runner/deploy/daemon.json`, then `rust-runner --version`, `--self-check` and the ignored Docker tests (including `/grade` and `output_of`, the real u3-l1, u7-l4 and u10-l2 solutions graded through `/grade`, and the cost benchmark; they read the lessons from `RUNNER_LESSONS_DIR`) under `runsc`, on `ubuntu-24.04-arm` and `ubuntu-24.04`. Covers everything `runner-sandbox` does | Needs a Linux host with Docker: see the job in `ci.yml` |
| `firebase` | Firestore rules against the emulator, and the account-deletion Cloud Function against the Auth, Firestore and Functions emulators | `sh test/firestore_rules/run.sh`, then `cd functions && npm ci && npm test` |

The Firebase tests need Node 22 and Java 21. The first run downloads the
emulators.

## Notes

- **Generated localizations are not committed.** `lib/l10n/app_localizations*.dart`
  come from the ARB files; `flutter pub get` generates them (`generate: true`
  in `pubspec.yaml`, settings in `l10n.yaml`), so `flutter analyze` and
  `flutter test` need nothing extra. If an IDE or `dart analyze` shows missing
  `AppLocalizations`, run `flutter pub get` (or `flutter gen-l10n`).

- **gVisor.** GitHub's runners have Docker with the default `runc` runtime,
  so `runner-sandbox` leaves `RUNNER_DOCKER_RUNTIME` unset and checks the
  container limits and the blocked network, not gVisor. The `runner-gvisor`
  job installs the pinned `runsc` and runs the same tests under it, on arm64
  (the production CPU) and amd64. It is still not the real host: no Caddy, no
  systemd, no firewall, and a newer Docker than `DOCKER_VERSION`; run
  `smoke.sh` on the VM after a deploy.
- **The arm64 gVisor leg uses billed minutes in a private repo.** Since
  2026-01-29 the standard `ubuntu-24.04-arm` runners work in private
  repositories (2 vCPU, 8 GB); they draw from the account's included
  minutes and then bill per minute ([changelog][arm-private],
  [runner reference][runners-ref]). Only public repositories get them
  free. The leg therefore runs, but needs Actions billing to be in order;
  if its cost is a problem, require only the amd64 leg and run `smoke.sh`
  on the Oracle VM for arm64.

- **Release tags.** Tag every store release `v<version>`; the `compat` job
  only protects tagged releases.
- **Rust version.** The `lessons` job uses exactly the Rust version of the
  sandbox image (`runner/sandbox.Dockerfile`, 1.99.1), so a lesson passes CI
  only if the runner will grade it the same way. Bump the version in both
  files (and the digest in `runner/Dockerfile`) together. The other Rust jobs
  use the latest stable Rust with `clippy -D warnings`,
  so a new Rust release can turn CI red without any code change.
  `dtolnay/rust-toolchain` is pinned to the head of its `stable` branch;
  Dependabot may not bump it, so check it now and then.
- **Dart formatting is not checked yet.** 17 existing files are not
  formatted. Follow-up: run `dart format lib test` once, in a commit of its own
  when nobody else has open changes, then add
  `dart format --set-exit-if-changed lib test` to the `flutter` job.
- **Required checks.** Once the jobs are green, make them required in
  GitHub: Settings → Branches → add a rule for `main` → Require status
  checks to pass → pick the jobs by name (the gVisor job has two legs; require only the amd64 one, see the note on gVisor below): Flutter analyze and test, Lessons compile, Runner fmt, clippy, test, Released lessons still gradable, Runner Docker sandbox, Runner under gVisor (amd64), Firestore rules and Cloud Function.

[arm-private]: https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories
[runners-ref]: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
