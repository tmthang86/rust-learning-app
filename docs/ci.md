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
| `lessons` | Every lesson example and exercise solution compiles (edition 2024) | `python3 tool/check_lessons.py` |
| `runner` | `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` | in `runner/`: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` |
| `runner-sandbox` | Builds the sandbox image and runs the Docker test (limits, no network) | in `runner/`: `docker build -t rust-runner-sandbox -f sandbox.Dockerfile . && cargo test -- --ignored` |
| `firebase` | Firestore rules against the emulator, and the account-deletion Cloud Function against the Auth, Firestore and Functions emulators | `sh test/firestore_rules/run.sh`, then `cd functions && npm ci && npm test` |

The Firebase tests need Node 22 and Java 21. The first run downloads the
emulators.

## Notes

- **gVisor is not on CI.** GitHub's runners have Docker with the default
  `runc` runtime, so `runner-sandbox` leaves `RUNNER_DOCKER_RUNTIME` unset.
  It checks the container limits and the blocked network, not gVisor. Test
  gVisor on the real host.
- **Rust version.** CI uses the latest stable Rust with `clippy -D warnings`,
  so a new Rust release can turn CI red without any code change.
  `dtolnay/rust-toolchain` is pinned to the head of its `stable` branch;
  Dependabot may not bump it, so check it now and then.
- **Dart formatting is not checked yet.** 17 existing files are not
  formatted. Follow-up: run `dart format lib test` once, in a commit of its own
  when nobody else has open changes, then add
  `dart format --set-exit-if-changed lib test` to the `flutter` job.
- **Required checks.** Once the jobs are green, make them required in
  GitHub: Settings → Branches → add a rule for `main` → Require status
  checks to pass → pick the jobs by name: Flutter analyze and test, Lessons compile, Runner fmt, clippy, test, Runner Docker sandbox, Firestore rules and Cloud Function.
