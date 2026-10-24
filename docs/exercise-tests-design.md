# Exercise tests: design

Status: proposal, revised after review round 1 (see §14). Scope: grade
exercises with several named tests (some of them hidden), and show expected
vs actual for each test, in place of comparing stdout with one string. Old
lessons keep working. Unit checkpoint challenges (a sibling workstream) use
the same format.

Claims are labelled **Verified** (with a source or a local experiment),
**Inferred** (follows from verified facts) or **Unverified**. The local
experiments ran on x86_64 with `rustc 1.97.0` and the runner's flags. The
sandbox pins `rust:1.99.1-slim-bookworm` (`runner/sandbox.Dockerfile`).
Nothing here needs nightly.

## 1. Decisions at a glance

| # | Topic | Decision |
|---|---|---|
| 1 | Test model | **Two kinds of test in one list.** A **code test** is a few Rust statements that call the learner's code and use `check_eq!` / `check!` / `check_near!`. An **output test** compares what the learner's `main` prints with an expected string. Print-only beginner exercises use one output test. Function exercises use code tests, visible and hidden. |
| 2 | One compile | Learner code + a generated harness are compiled **once** with `rustc --test`, and the binary runs **once**. The build uses `-C opt-level=0` (round 3: it cuts the cost of a graded job from about 2.2× to about 1.4× of a plain run). All tests and `main` run on **one thread with a 16 MiB stack** (no `RUST_MIN_STACK`), each test isolated with `catch_unwind`. `main` runs last. **Only when the compile fails**, a quick `--emit=mir` check of the learner code alone (same flags as `/run`) decides whose error it is (§6.1). |
| 3 | Results | The harness writes its own **result records** to stdout, each tagged with a random **per-job nonce**. libtest's output is ignored, and so is its JSON (`--format json` is nightly-only). Learner prints can never be mistaken for results by accident. |
| 4 | Runner API | New **`POST /grade {code, tests}`**. It goes through the same gate as `/run` (IP limits, App Check, token limits), costs **one** rate-limit token, takes one job slot, and uses the same container, limits and caps. It is added to the Caddy route matcher. `/run` is unchanged. The server returns **machine codes, never English prose** (compiler diagnostics excepted). |
| 5 | Where verdicts are made | **On the server**, by a small pure crate `runner/grade`. The lesson checker uses the same crate through the `rr-grade` CLI, with CI pinned to the sandbox's Rust version. |
| 6 | Hidden tests | They **ship in the app bundle** and are hidden **in the UI only, not secret**. This is acceptable because progress is self-reported and unranked, and the reference `solution` is bundled already (§3.5). |
| 7 | Schema | Additive: `exercise.tests: [...]`. `expectedOutput` keeps its name and meaning; an exercise without `tests` is shown as one output test made from it, but (round 3) it is run with plain `/run` and compared in the app, so it costs one ordinary run and needs no new runner. Per test: `id`, `label` (prose: required and translated on visible tests, optional and untranslated on hidden ones), `hidden`, and either `code` (with optional `panics`) or `output`. |
| 8 | Solved | An exercise is solved when **every** test, visible and hidden, has status `pass`. It is never solved when the runner can't be reached. |
| 9 | Migration | PR 1: the harness, plus 3 exemplar lessons. PR 2: the other 55, in three groups (P 13 / F 23 / R 22, §9). After PR 2, the checker's strict mode requires `tests` on every exercise. |

## 2. Research findings

| Question | Finding | Label |
|---|---|---|
| How does Exercism's Rust runner grade? | It runs `cargo test --offline -- --include-ignored -Z unstable-options --format json` under `timeout 15s`. It maps the JSON events to `results.json` and maps test names to their source code (`test_code`). | Verified [E1] |
| Toolchain for that | Its Dockerfile: "As of April 2026, we need to use the nightly toolchain to get JSON test output". | Verified [E2] |
| What Exercism reports per test | `name`, `test_code`, `status` (pass/fail/error), `message`, and `output` ("must be limited to 500 chars"). Top-level `error` when no test could run. Limits: 20 s, 3 GB. No hidden tests are mentioned. | Verified [E3] |
| Is libtest `--format json` stable? | No. The rustc book: "unstable, and requires the `-Z unstable-options` flag". rust-lang/rust#49359 is still open. Locally: `error: The "json" format is only accepted on the nightly compiler`. | Verified [R1][R2], local |
| `rustc --test` | It builds a binary linked with libtest, sets `cfg(test)`, and generates its own `main`, which "will replace any existing `main` … though the existing `main` will still be compiled". Locally, the learner `main` stays callable as `super::main()` and gets no dead-code warning. | Verified [R1], local |
| libtest flags | `--exact` matches the full test path. `--test-threads N`. `--no-capture` (`--nocapture` is a deprecated alias). `#[should_panic]` exists. Tests run on a thread named after the test. | Verified [R1], local |
| Stack of the test thread | It is smaller than the main thread's: deep recursion that works in a plain binary overflows inside a `#[test]` (local: depth 20 000 with 256-byte frames). It passes with `RUST_MIN_STACK=8388608`. Round 3: that variable applies to **every** thread the learner starts, so 20 spawned threads failed under the 320 MB address-space cap; the harness now runs the tests on one thread it spawns itself with a 16 MiB stack, and learner threads keep the default stack. | Verified, local (reviewer reproduced it too); round 3, Docker |
| Panic isolation | `catch_unwind` catches unwinding panics (the default). The panic hook runs first. Aborts (stack overflow) are not caught. | Verified [R3] |
| `main() -> Result` | `std::process::Termination::report` has been stable since 1.61. For `Err(e)` it prints `Error: {e:?}`. | Verified (stability) [R4]; Inferred (Err text, std source via [R4]); test G8 |
| Private items from tests | `use super::*` in a child module sees the parent's private items and private `use` imports. Items private to a nested learner module stay private (E0603). | Verified, local |
| Learner names shadow the harness | The glob import also brings learner items that **shadow the prelude**: a learner `enum Option` or `struct String` breaks harness code that says `Option`/`String` (E0107/E0308/E0277). A learner `#![forbid(unused_variables)]` turns any `#[allow(unused_variables)]` in the harness into error E0453. | Verified, local (forbid case: from the reviewer, Inferred from lint rules) |
| rustc JSON diagnostics | `--error-format=json`: `$message_type`, `level`, `spans[]` (`file_name`, `line_start`, `is_primary`, `expansion`), `rendered`. Forward-compatible parsing is advised; no stability promise. | Verified [R5] |
| Where compile errors point (combined file) | (a) every failed compile adds a span-less "aborting due to N previous errors". (b) An error inside a check macro (e.g. missing `Debug`) has its primary span on the **macro definition** line; the call site is only in `expansion`. (c) A missing `}` in learner code points at the harness's **last line**, and the snippet shows harness lines. | Verified, local (and by the reviewer) |
| Learner-only check | `--emit=metadata` is **not enough**: it skips the MIR-stage deny lints. `let x: u8 = 255 + 1;` (`arithmetic_overflow`) and `[1, 2, 3][5]` (`unconditional_panic`) fail a full build but pass metadata. `--emit=mir` with the same `-C opt-level=1 -C overflow-checks=on` reports them, with output **byte-identical** to the full build (reviewer: 7 cases; me: these 2). It also catches type, borrow-check, missing-`main` (E0601) and other deny-lint errors. Cost: metadata 0.06 s, mir 0.08–0.10 s, full build 0.12–0.17 s. It does **not** see the learner's `#[cfg(test)]` code, because it is built without `--test`. | Verified, local (and by the reviewer) |
| Path remapping | `--remap-path-prefix <dir>=/tmp` rewrites both diagnostic paths and panic locations (given an absolute source path). | Verified, local |
| Capturing a function's prints | `dup`/`dup2` fd 1 onto a temp file (declared with `unsafe extern "C"`), run, flush, restore. This works, including when the closure panics. | Verified, local (glibc). Under gVisor: **Unverified** (test D3) |
| Compile cost (x86, opt-level=1) | Plain: 0.11 s. `--test` with no harness: 0.13 s. My prototype harness: 0 / 6 cases = 0.26 / 0.39 s. The reviewer's: 0 / 6 / 20 / 50 tests = 0.27 / 0.35 / 0.36 / 0.45 s. So the harness costs **≈ +0.15 s fixed**, and **0.002–0.025 s per test** depending on the types formatted. That is 3–4× the bare compile of a tiny program; container start comes on top for both. opt-level=0: 6 / 50 tests = 0.20 / 0.28 s. | Verified, local. ARM VM: **Unverified** (P1) |
| Codewars | Submission tests = fixed tests + random tests, which "are required to reject … hard-coding". "Assertions from sample tests should appear in submission tests as well." | Verified [C1][C2] |
| LeetCode | "Run" uses the examples; "Submit" judges a large hidden set. | Unverified (community) [L1][L2] |
| Coddy | Per test: input, expected and your output; some tests are hidden to stop printing the expected answer; every test must pass. | Unverified (search summary; page 403) [D1] |

## 3. Test model

### 3.1 Two kinds, one list

| Kind | What it checks | Use for |
|---|---|---|
| **code** (`code`) | Rust statements run inside the learner's crate, e.g. `check_eq!(add(2, 3), 5);`. They can call any learner item, private ones too. With `panics`, the test passes only if the code panics with a message containing that text. | Every exercise where the learner writes a function, method, trait impl or type. Every checkpoint challenge. |
| **output** (`output`) | The stdout of the learner's `main`, normalised (§3.3), must equal `output`, and `main` must finish without panicking. | Print-only exercises (Units 0–2), and lessons where printing is the point. |

A print-only exercise has exactly one visible output test. Hidden output
tests are not allowed, because `main` takes no input. So in Units 0–2 a
print exercise can still be passed by printing the exact text. That is
accepted because printing is the skill being taught there (open question 3).
`output_of(|| greet("Ann"))` lets a code test check what a function prints.

### 3.2 Order and isolation

- Tests run in JSON order, one at a time, in one process. Each is wrapped
  in `catch_unwind`. `main` runs **last**, once; its stdout is the
  response's `stdout` and the input to every output test.
- The tests and `main` run on one thread named `main` with a 16 MiB stack: `/run`'s main thread has 8 MiB, but the unoptimised build has larger frames. 16 MiB is the most that leaves room for a learner's 20 threads under the 320 MB cap (24 MiB did not). Threads the learner starts have the default stack, as in `/run`.
- Tests share the process, so statics and thread-locals carry over from
  one test to the next. Authors must not rely on that (§10).
- Something that ends the process (the run timeout, a stack overflow,
  running out of memory, too much output, `process::exit`) stops the run.
  The test in progress gets `timeout` or `crashed`, and later tests get
  `not_run`.
  - Exception: `process::exit(0)` **inside `main`**, after every test has a
    record. Then `main` counts as finished `ok`, which matches what `/run`
    would show.

### 3.3 Output normalisation

Applied to both sides: `\r\n` becomes `\n`, trailing whitespace is removed
from each line, and leading and trailing blank lines are dropped. Today's
rule is `trim()` of the whole text; the difference is that leading spaces
on the first line now count. Verified: no current `expectedOutput` starts
with whitespace.

### 3.4 Check macros (available in `code`)

| Macro / fn | Passes when | Learner sees on failure |
|---|---|---|
| `check_eq!(actual, expected)` | `actual == expected` | **Checked:** `add(-1, 1)` · **Expected:** `0` · **Got:** `1` (`{:?}`) |
| `check!(condition)` | `condition` is true | **Checked:** `is_even(7) == false` · expected `true`, got `false` |
| `check_near!(actual, expected, tolerance)` | `(actual - expected).abs() <= tolerance` (f64) | as `check_eq!`, plus "within 0.001" |
| `output_of(closure) -> String` | (helper) | What the closure printed, capped at 64 KB |

- Argument order is fixed: **actual first**.
- A plain `assert!`, `unwrap()` or index panic inside a test is reported as
  `panic` with its message.
- Values need `Debug` and `PartialEq` (the starter derives them for learner
  types).
- Debug text is capped at 1 KB per value by a bounded writer.
- **Test bodies see the learner's names** (`use super::*`). If the learner
  defines their own `Option`, `Result` or `String`, a test body that says
  `Some(..)` or `String::from` gets theirs. Authors who need std
  explicitly write `::std::…`. The macros themselves always use
  `::core`/`::std` paths.

### 3.5 Hidden tests are not secret: accepted

Hidden tests ship in the app bundle and are hidden in the UI only.

1. **Nothing depends on the grade.** Completion is self-reported per user,
   the `solution` is bundled already, and there are no rankings,
   certificates or rewards.
2. **The goal is learning feedback**: hidden tests stop a learner from
   fitting their code to the visible examples. Digging them out of the app
   bundle only cheats oneself.
3. **Moving tests to the server is expensive**: a content store versioned
   against app releases, a stateful runner, and a server deploy for every
   content change.

Revisit this if grades ever count for something. Hidden tests would then
move to the server, keyed by `lessonId` + content hash, in the same format.

## 4. Exercise JSON schema

Additive. Unknown keys are ignored, and the sibling's `exercise.hints`
goes next to `tests`.

| Field | Type | Req. | Notes |
|---|---|---|---|
| `prompt`, `starter`, `solution` | string | as today | `solution` is required by the checker |
| `expectedOutput` | string | **no longer required** | Legacy. Only allowed when `tests` is absent. The app grades it as one output test, `id: "output"`, with a UI-provided label. |
| `tests` | array, 1–50 | new | Order = display and run order |
| `tests[].id` | string `^[a-z0-9][a-z0-9-]{0,39}$` | yes | Unique within the exercise; a stable key across locales and in results. Not shown. |
| `tests[].label` | string ≤ 80 | visible: yes · hidden: optional | **Prose key, translated, on visible tests only.** On hidden tests it is a note for reviewers: never shown, English only, and copied verbatim into the vi mirror. |
| `tests[].hidden` | bool | no (false) | Code tests only |
| `tests[].code` | string | one of | Rust statements: the body of a `fn()`. Non-prose. |
| `tests[].panics` | string | no | Code tests only. `""` = any panic; otherwise a substring of the panic message. |
| `tests[].output` | string | one of | Expected stdout of `main`. Non-prose. |

vi mirror rule: `id`, `hidden`, `code`, `panics`, `output` and hidden
`label`s must equal the English file. Visible `label`s are translated.

### 4.1 Print-only exercise (u0-l1, as it really is)

```json
"exercise": {
  "prompt": "Swap the lines so the program prints First, then Second, each on its own line.",
  "starter": "fn main() {\n    println!(\"Second\");\n    println!(\"First\");\n}",
  "solution": "fn main() {\n    println!(\"First\");\n    println!(\"Second\");\n}",
  "tests": [
    { "id": "first-then-second", "label": "Prints First, then Second", "output": "First\nSecond" }
  ]
}
```

### 4.2 Function exercise with visible and hidden tests (u6-l2)

```json
"exercise": {
  "prompt": "Finish check_age so it returns Err(String::from(\"too young\")) when age is under 18, and Ok(age) otherwise.",
  "starter": "fn check_age(age: u32) -> Result<u32, String> {\n    Ok(age)\n}\n\nfn main() {\n    match check_age(15) {\n        Ok(a) => println!(\"welcome, age {a}\"),\n        Err(e) => println!(\"error: {e}\"),\n    }\n}",
  "solution": "fn check_age(age: u32) -> Result<u32, String> {\n    if age < 18 {\n        Err(String::from(\"too young\"))\n    } else {\n        Ok(age)\n    }\n}\n\nfn main() { … unchanged … }",
  "tests": [
    { "id": "fifteen-too-young", "label": "15 is too young", "code": "check_eq!(check_age(15), Err(String::from(\"too young\")));" },
    { "id": "thirty-ok", "label": "30 is welcome", "code": "check_eq!(check_age(30), Ok(30));" },
    { "id": "boundary-18", "hidden": true, "label": "18 is the first allowed age", "code": "check_eq!(check_age(18), Ok(18));" },
    { "id": "boundary-17", "hidden": true, "code": "check_eq!(check_age(17), Err(String::from(\"too young\")));" }
  ]
}
```

### 4.3 Panic case (illustrative: a checkpoint-style `divide`, not an existing lesson)

```json
{ "id": "divides", "label": "10 / 2 is 5", "code": "check_eq!(divide(10, 2), 5);" },
{ "id": "zero-divisor-panics", "label": "Dividing by zero panics with a clear message",
  "code": "let _ = divide(1, 0);", "panics": "cannot divide by zero" }
```

## 5. Harness and generated source

The server builds **one file**: the learner code unchanged (N lines), then
`\n`, then the generated code. Learner line numbers are unchanged.

```rust
<learner code, N lines>

#[doc(hidden)]
mod __rr {                       // harness machinery: NO glob import, only ::std / ::core paths
    pub const NONCE: &str = "<32 hex, fresh per job>";
    // records, escaping, bounded Debug writer, panic hook, case runner,
    // main runner, output_of (its unsafe fd code only if some test uses output_of)
}
#[cfg(test)]
mod __rr_tests {
    use super::*;                // test bodies see learner names (by design)
    // check_eq!/check!/check_near!: always emitted, used by __rr_t_self;
    // their expansions call ::core::/::std:: and crate::__rr::… only
    fn __rr_t_self() { check_eq!(1, 1); check!(true); check_near!(1.0, 1.0, 0.0); }
    fn __rr_t0() {
check_eq!(check_age(15), Err(String::from("too young")));
    }
    fn __rr_t1() { ... }
    #[test]
    fn __rr_grade() {
        crate::__rr::start();
        let _ = (crate::__rr::fail as fn(&str, &str, &str) -> !, /* …every helper… */);
        crate::__rr::case("__self", ::core::option::Option::None, __rr_t_self); // record dropped by the parser
        crate::__rr::case("fifteen-too-young", ::core::option::Option::None, __rr_t0);
        crate::__rr::main(|| { let _ = ::std::process::Termination::report(main()); });
        crate::__rr::done();
    }
}
```

- **No lint attributes** (`#[allow]`) anywhere in generated code, so a
  learner's `#![forbid(...)]` can't clash with them (E0453). The generated
  code is warning-free by construction, even under a learner
  `#![deny(warnings)]`:
  - **All** helpers and macros are always emitted. `__rr_grade` references
    each helper once, e.g. `let _ = (crate::__rr::fail as fn(&str, &str,
    &str) -> !, crate::__rr::case as fn(&str, Option<&str>, fn()), …);`.
    So nothing is `dead_code`. Verified: an unreferenced helper fails
    under `deny(warnings)`, a referenced one passes.
  - Each check macro is used at least once by the generated self-check
    `__rr_t_self` (`check_eq!(1, 1); check!(true); check_near!(1.0, 1.0,
    0.0);`). It runs first, so the macros never trigger `unused_macros`.
    Its record is dropped by the parser.
  - `main` is called through the glob import (`main()`, not
    `super::main()`), so `use super::*` is always used.
  - The **one conditional piece** is the `unsafe` fd code behind
    `output_of`. It is emitted only when some test's `code` contains
    `output_of`.
  - Warnings in generated lines are dropped anyway (§6.1).
- **Residuals.** These are reported as an `error` in the test, and the
  checker catches them for solutions:
  - a learner `deny(warnings)`/`forbid` plus a test body that warns (e.g.
    an unused `let`);
  - a learner `#![forbid(unsafe_code)]` plus a test that uses `output_of`.
    There is no safe stable way to capture fd 1, and E0453 was verified
    locally. Authors avoid `output_of` in lessons that teach
    `forbid(unsafe_code)`.
- The run command is `./prog --exact
  __rr_tests::__rr_grade --no-capture --test-threads=1 -q --color never`.
  `--exact` skips any `#[test]` the learner wrote.
- Compile uses `--remap-path-prefix` so paths and panic locations read
  `/tmp/main.rs`, as in `/run` (§6.3).

**Records.** Format: `\x01RR-T:<nonce>:<kind>` + (`\x1f` + escaped field)*
+ `\n`. Escaping turns `\` into `\\`, newline into `\n`, and other control
characters into `\u{..}`. A record is written in one `write_all` under the
stdout lock, after flushing `std::io::stdout()`. It goes to a `dup` of the
original fd 1, so `output_of` never captures it.

| Kind | Fields | Meaning |
|---|---|---|
| `case` | id | test starts; stdout until the next record is this test's `output` |
| `pass` | — | passed |
| `fail` | expr, expected, actual | a check failed |
| `panic` | message, line (empty when not in learner code) | panicked (not expected, or the message didn't match `panics`) |
| `nopanic` | — | `panics` was set but nothing panicked |
| `main` / `mainend` | — / `ok` \| `panic`+message | the stdout between them is `main`'s output |
| `done` | — | harness finished |

**Panic hook.** It is installed by `start()` and reinstalled before each
case. It stays **silent only on the grading thread** while a test case
runs, storing the message and location in a thread-local instead.
- Panics on other threads (e.g. threads the learner's code spawns, as in
  u11) go to the default hook, as in `/run`.
- While `main` runs, it prints `thread 'main' panicked at
  /tmp/main.rs:L:C:\n<msg>` to stderr. Current std prints `thread 'main'
  (<os thread id>) panicked at …` (verified on 1.97), and the harness can't
  get that id without `unsafe`, so it leaves it out.
  - **Contract for the sibling's error-explanation parser:** accept both
    forms, `^thread '([^']*)'(?: \(\d+\))? panicked at (.+):(\d+):(\d+):$`.
- A location is reported only for learner lines (≤ N).

**Forgery.** The nonce comes from the server's RNG for each job. The script
deletes the source files before the program starts, but the nonce is still
readable as plain text in the **binary** (`/tmp/prog`, or `/proc/self/exe`).
Honest learner prints can't match it by accident. A determined learner who
extracts it can fake their own pass, which fools only themselves (§3.5).
That is acceptable.

## 6. Runner changes

### 6.1 `POST /grade`

Request (labels and `hidden` aren't sent):

```json
{ "code": "fn check_age ...",
  "tests": [ { "id": "fifteen-too-young", "code": "check_eq!(...);" },
             { "id": "zero-divisor-panics", "code": "let _ = divide(1, 0);", "panics": "cannot divide by zero" },
             { "id": "first-then-second", "output": "First\nSecond" } ] }
```

Response 200 (the `/run` fields, plus `tests` and `compileErrorsIn`):

```json
{ "success": false, "stage": "run", "durationMs": 1830,
  "stdout": "error: too young\n", "stderr": "", "warnings": "",
  "compileErrorsIn": null, "reason": null,
  "tests": [
    { "id": "fifteen-too-young", "status": "pass" },
    { "id": "thirty-ok", "status": "fail", "expr": "check_age(30)", "expected": "Ok(30)", "actual": "Err(\"too young\")", "output": "" },
    { "id": "zero-divisor-panics", "status": "panic", "message": "attempt to divide by zero", "line": 3 },
    { "id": "boundary-17", "status": "crashed", "reason": "mem_limit" } ] }
```

- `tests` lists **every** requested id, in request order.
  - `status` ∈ `pass`, `fail`, `panic`, `nopanic`, `error`, `timeout`,
    `crashed`, `not_run`.
  - `reason` (on `crashed`/`error`, and top-level) is a **machine code**:
    `mem_limit`, `output_limit`, `stack_overflow`, `exit:<n>`, `no_main`,
    `tests_dont_fit`, `harness`. The app maps codes to ARB strings.
  - Free text from the server is only rustc's or the program's own:
    `message` = a panic message or a compiler diagnostic's one-line
    `message`. Compiler text stays English, as in `/run`.
- `success` keeps its `/run` meaning. The client never decides "solved"
  from it.
- `stderr` is the **whole run's** stderr: `eprintln!` from tests and
  `main`, plus panics from other threads. Per-test stderr is not
  attributed.
- Caps: `expected`/`actual` ≤ 1 KB, `output` ≤ 2 KB per test, `message`
  ≤ 1 KB, each with a truncation marker. The 64 KB stdout cap bounds the
  whole response.

**Compile classification.** On a successful compile, warnings are taken
from the combined JSON diagnostics. Only those whose primary span, after
following `expansion` back to the call site, lies in learner lines are
kept, and their `rendered` text is shown. When the combined compile
**fails**, the job script runs a second, cheap check on the learner code
alone, and the result decides:

For each combined-compile error, its **site** is found by taking the
primary span and following `expansion` back to the outermost call site.
Span-less diagnostics ("aborting due to…") are ignored. The rules apply in
order; the first that matches wins:

| # | Condition | `stage` | `compileErrorsIn` | Tests | `stderr` |
|---|---|---|---|---|---|
| 1 | Learner-only check (`--emit=mir`) **fails** | `compile` | `"code"` | all `not_run` | that check's human output **verbatim** (the same text as `/run`) |
| 2 | The check passes, but some error's site is a **learner line** (≤ N). Examples: the learner's own `#[cfg(test)]`/`mod tests` code (u9-l4), errors only seen under `--test`, post-monomorphisation errors | `compile` | `"code"` | all `not_run` | the `rendered` text of those diagnostics only (paths already `/tmp/main.rs`; snippets show learner lines) |
| 3 | The check passes and every error's site is in generated lines | `compile` | `"tests"` | Tests whose range holds a site: `error`, `message` = the diagnostic's one-line `message` (never a snippet), `reason: "tests_dont_fit"`. Other tests: `not_run`. | "" |
| 4 | The check passes and an error's site is in generated lines outside every test range | `compile` | `"tests"` | all `not_run`; top-level `reason`: `"no_main"` if the site is the `main()` call line, else `"harness"` | "" |
| — | Compiled | `run` / `timeout` | null | per records | as above |

`no_main` is a fallback only: a missing `main` (E0601) is normally caught
by rule 1. `harness` means a bug in the harness or a residual case from §5.
It is logged at `warn` (without code).

| Run outcome | Tests |
|---|---|
| Run timeout | the test in progress → `timeout`, later → `not_run` |
| Memory, stack overflow, output overflow, non-zero `process::exit` | the test in progress (or `main`) → `crashed` with `reason`; later → `not_run`. `reason` comes from the existing `interpret()` facts (`mem_limit`, overflow) and stderr's "has overflowed its stack". |
| Exit 0 without `done`, every test has a result | `main` counts as `ok` (§3.2) |
| Exit 0 without `done`, some tests have no result | the test in progress → `crashed`, `reason: "exit:0"` |

**Validation** (400, `code: "tests_invalid"`):
- 1–50 tests, unique ids matching the regex.
- Exactly one of `code`/`output`; `panics` only with `code`, ≤ 200 bytes.
- `code` ≤ 4 KB, `output` ≤ 8 KB, all test fields together ≤ 32 KB.
- The `/grade` body limit is `2 × (64 + 32) KB + 1 KB` = 193 KB, under
  Caddy's `max_size 256KB`.
- Test code is arbitrary Rust, like learner code, in the same sandbox, so
  accepting it from the client adds no new trust.

### 6.2 What stays the same (production-design guarantees)

- **Same gate**: `/grade` sits in the same router group as `/run`
  (IP buckets → App Check → token buckets), and **one request = one
  token**. No new bucket or config.
- Same semaphore and queue, same request timeout. Same container (gVisor,
  `--network none`, read-only root, tmpfs, cap-drop ALL, uid 65534,
  memory/cpu/pids, `ulimit -t`/`-v`, stdin `/dev/null`).
- Same `Limits`: compile 10 s; run 5 s for all tests plus `main`; job 20 s;
  64 KB output; 4 MB compiler output. The learner-only check runs only
  after a failed compile, when the run phase is skipped, and is bounded by
  the run timeout. So the time and resource envelope (compile + run ≤ job)
  is unchanged.
- Same markers, "never started → server error" logic and host-failure
  detection.
- Logs: plus `endpoint: "grade"`, `testsTotal`, `testsPassed`. Never code,
  test code, ids or output.
- **Edge**: `runner/deploy/Caddyfile.template` currently matches
  `@runner path /run /health` and answers everything else with 404. It
  becomes `path /run /grade /health`. `runner/deploy/smoke.sh` gets a
  `/grade` check (401 without an App Check header, like `/run`).

### 6.3 Job script and code layout

- `JOB_SCRIPT` gets two arguments: `$5` = mode (`run` | `grade`) and `$6` =
  the learner code's length in bytes (computed by the server). In `grade`
  mode:
  1. `mkdir -p "$work/g"`, then stdin goes to `$work/g/main.rs` (the
     combined file).
  2. Compile (compile timeout, as today):
     ```
     rustc --edition 2024 -C opt-level=0 -C overflow-checks=on --test \
       --error-format=json --remap-path-prefix "$work/g=$work" \
       -o "$work/prog" "$work/g/main.rs"
     ```
  3. If rustc was killed (rc 137): exit 202 as today, with **no**
     learner-only check.
  4. Any other failure: `head -c "$6" "$work/g/main.rs" > "$work/main.rs"`,
     print a marker `\x01RR-CHECK\n` on stdout and stderr, then:
     ```
     timeout --signal=KILL "$secs" rustc --edition 2024 -C opt-level=1 \
       -C overflow-checks=on --emit=mir -o "$work/l.mir" "$work/main.rs"
     ```
     This uses human output and the run timeout. The result is printed as
     `\x01RR-CHECK:<rc>\n` on stdout, then the script exits 201. If the
     check itself times out or is killed, the server applies rules 2–4
     using the combined diagnostics only.
  5. On success: `rm -rf "$work/g" "$work/main.rs"`, then
     `exec timeout … "$work/prog" <libtest args>`. (The learner-only check keeps
     `/run`'s flags, so its text matches `/run`'s.)

  `run` mode is byte for byte unchanged, and `check_sandbox` keeps using
  it.
- `interpret()` is shared. In grade mode the compiler stderr before
  `RR-CHECK` is JSON-per-line, and a line that isn't JSON is kept as text.
- New crate **`runner/grade`** (package `rr-grade`; dependencies `serde`,
  `serde_json`). Add `[workspace] members = ["grade"]` to
  `runner/Cargo.toml` and copy `grade/` in `runner/Dockerfile`.
  - `build(code, &[TestSpec], nonce) -> Generated { source, learner_lines, ranges, main_call_line }`
  - `classify_compile(&Generated, combined_json, learner_check: Option<Text>) -> CompileVerdict`
  - `results(&Generated, stdout, end: EndState) -> (Vec<TestResult>, MainResult)`, plus normalisation
  - `src/prelude/*.rs.txt`: harness pieces
  - `src/bin/rr-grade.rs`: checker CLI. It reads `{code, tests}` on stdin
    and does the same steps with host `rustc` and `std::process` (plus a
    10 s timeout). It works on macOS, and like today's checker it is not a
    sandbox.
- `rust-runner`: route + `grade` handler in `src/lib.rs` (sharing `run`'s
  slot and queue code), and a `mode` parameter in `src/sandbox.rs`.

## 7. App changes

| File | Change |
|---|---|
| `lib/data/models.dart` | `class ExerciseTest { String id; String? label; bool hidden; String? code; String? panics; String? output; }`. `Exercise.expectedOutput` becomes `String?`. A `tests` getter returns the list, or the legacy single output test. `fromJson` throws `FormatException` when there is neither. |
| `lib/runner/code_runner.dart` | `TestResult {id, status, expr?, expected?, actual?, output?, message?, line?, reason?}`; `GradeResult extends RunResult { List<TestResult> tests; String? compileErrorsIn; String? reason; }`. `CodeRunner.grade(String source, List<ExerciseTest> tests)`. `HttpCodeRunner` posts to `grade` with the same auth, retry, timeout and error mapping, plus `tests_invalid` → "This exercise couldn't be checked. Please update the app." `PlaceholderCodeRunner` and the fakes implement it. |
| `lib/features/editor/code_editor.dart` | Takes `List<ExerciseTest>? tests` in place of `expectedOutput` (`null` = playground → `/run`). With tests, **Run** calls `grade`. `_solved` = the result has every exercise test id with `status == pass`. Below the editor: the **Tests panel**, then the existing Output panel. |
| `lib/features/lesson/lesson_screen.dart` | Passes `exercise.tests`. `onSolved` → `markCompleted`, as today. |
| Strings | ARB keys in `lib/l10n/app_en.arb` and `app_vi.arb` (gen-l10n landed with the Vietnamese localization). Panel: `testsSummary`, `hiddenSummary`, `testStatus*`, `testRowLabel`, `testRowHint*`, `testChecked`, `testExpected`, `testGot`, `testPrinted`, `testShowCode`, `testPanicked`, `testPanickedAt`, `testDidNotPanic`, `testTimedOut`, `testNotRun`, `testFirstDifference`, `testMissingLine`, `testsCantUseYourCode`, `hiddenTestCantUseYourCode`, `hiddenOnlyFailing`, `legacyOutputLabel`; announcements: `announceTestsSummary`, `announceTestFailed`, `announceHiddenFailed`; the verdict reuses `exerciseSolved` / `exerciseNotYet`; one `testReason*` per `reason` code (`testReasonText(l10n, code)` maps the code); runner problems are `RunIssueKind.runnerNeedsUpdate` and `testsInvalid`. |

### 7.1 Tests panel

- Header: "Tests: 3 of 5 passed", with a progress bar.
- One row per **visible** test: an icon **and** a word (Passed / Failed /
  Took too long / Didn't run), plus `label`. The first failure is
  expanded. Expanded: Checked `expr`, Expected, Got, then the panic message,
  "Printed during this test" (folded), and "See the test code" (folded).
  Output tests show Expected and Got line by line, with the first
  differing line marked.
- **Hidden**: one row, "Hidden tests: 1 of 2 passed". No labels, values,
  messages or code.
  - If every visible test passes but a hidden one fails: "Your code passes
    the examples but not every hidden test. Try other inputs, like edge
    cases."
  - A hidden test with `error`: "A hidden test couldn't use your code:
    «message»".
- `compileErrorsIn == "tests"`: "Your code compiles, but the tests can't
  use it. Keep the names and types from the starter.", then the affected
  visible tests.
- `compileErrorsIn == "code"`: no panel. The compile errors show exactly as
  in `/run`.
- **Runner unavailable** (`PlaceholderCodeRunner`, network, 401/403, 429,
  503, or **404 from an old runner without `/grade`**): no Tests panel; the
  existing "Couldn't run your code" panel with the existing message; never
  solved. A 404 on `grade` maps to "The code runner needs an update. Try
  again later."
- The verdict "Correct! Nice work." is shown only when solved.

### 7.2 Accessibility

- After each run, an announcement from a new `gradeAnnouncement()` (or the
  existing live-region fallback). Example: "3 of 5 tests passed. Failed:
  15 is too young. Expected Err("too young"), got Ok(15). 1 hidden test
  failed." It names the first visible failure only, is clipped at 200
  characters, and ends with "Correct! Nice work." when solved.
- Each row is `MergeSemantics` with label "Failed: «label»" and a "Double
  tap to show details" hint. Expanded details are read in order. Status is
  never shown by colour alone, and expanding doesn't move focus.
- Text scales; rows wrap; Expected/Got are `SelectableText`.

## 8. Tooling and CI

`tool/check_lessons.py` calls `runner/target/release/rr-grade` (path from
`RR_GRADE`, or it runs `cargo build --release -p rr-grade` once).

| Check | Rule |
|---|---|
| Schema | `tests` xor `expectedOutput`; id regex and uniqueness; visible `label` non-empty ≤ 80; exactly one of `code`/`output`; `hidden`/`panics` only on code tests; at most one output test, never hidden. |
| Solution | Every test `pass`; no warnings in learner code. |
| Starter | At least one test not `pass`. If the starter compiles, it must not get `compileErrorsIn: "tests"`. If the starter doesn't compile in its own code (the "fix this error" lessons), whether its names fit the tests **can't be checked**: all tests are `not_run`. The reviewer checks it by hand, and the checker prints a note. |
| Hidden ≠ visible | Hidden `code` must differ from every visible `code`. |
| Minimums (one table, used by both checker and §9) | **Print-only** (only an output test): 1 visible output test; allowed for `u0-*`, `u1-*`, `u2-*` and the `PRINT_ONLY_OK` set (each with a reason). **Function exercise**: ≥ 2 visible code tests + ≥ 2 hidden. Exempt: `u0-l5` needs only ≥ 1 visible (Unit 0). **Restructured (group R)**: ≥ 1 visible + ≥ 2 hidden. **Checkpoint** (however the sibling marks it, e.g. `kind: "checkpoint"`): ≥ 3 visible + ≥ 3 hidden. The group is read from a `GROUP` map in the script, keyed by lesson id, with checkpoints detected from the marker. |
| Legacy | `expectedOutput` is graded as one output test. `--strict` makes any remaining `expectedOutput`, or a minimum violation, an error. |

CI (`.github/workflows/ci.yml`):
- The `lessons` job pins `toolchain: 1.99.1` (the sandbox's version, not
  floating `stable`), adds `Swatinem/rust-cache` (workspace `runner`) and
  `cargo build --release --locked -p rr-grade`.
- Note in `sandbox.Dockerfile`: bump both versions together.
- The `runner` job covers the new crate. The Docker sandbox job gets the
  grade cases (§12).

## 9. Migration of the 58 exercises

**PR 1** (harness) converts 3 exemplars: `u0-l1` (P), `u6-l2` (F) and
`u4-l4` (R: restructured to show the pattern).

**PR 2** migrates the other 55 and turns on `--strict`. It builds on PR 1,
and on the i18n PR if that has landed by then. In that case PR 2 also
updates `assets/content/vi/lessons/*`: non-prose fields copied, visible
labels translated. Neither `assets/content/vi/` nor `--strict` exists in
this repo yet.

Groups: verified by diffing starter vs solution outside `main`.

| Group | Lessons | How | Minimum |
|---|---|---|---|
| **P: print-only, Units 0–2** (13) | u0-l1..l4, u1-l1..l5, u2-l1..l4 | Script: `expectedOutput` → one output test with a hand-written label. | 1 visible output |
| **F: the learner changes a function** (23) | u0-l5, u2-l5, u3-l1, u3-l3, u3-l4, u3-l5, u4-l2, u4-l5, u6-l2, u6-l3, u6-l4, u7-l1, u7-l2, u7-l3, u7-l4, u7-l5, u8-l3, u9-l4, u10-l1, u11-l4, u12-l1, u12-l2, u12-l3 | Visible tests = the current example plus one more; ≥ 2 hidden edge cases. `main` stays as the playground. Prompt: "It should print X" → "Make `f` return …". | ≥ 2 vis + ≥ 2 hidden (u0-l5: ≥ 1 vis) |
| **R: the learner's change is only in `main`** (22) | u4-l4, u8-l1, u10-l2 (the function is already complete in the starter), plus u3-l2, u4-l1, u4-l3, u5-l1..l3, u6-l1, u8-l2, u8-l4, u8-l5, u9-l1..l3, u10-l3, u10-l4, u11-l1..l3, u12-l4 | Restructure: the starter gets a function with a fixed signature for the step the learner writes (u4-l4: `fn even_or_zero(numbers: &[i32]) -> i32` using `first_even` and `unwrap_or`; u8-l1: `fn minus_five() -> impl Fn(i32) -> i32`; u5-l1: `fn add_four_and_five(v: &mut Vec<i32>)`; u9-l1: `shop::…`, where making it `pub` is the task). Prompt rewritten. Or `PRINT_ONLY_OK` with a reason (candidate: u10-l2 drop order: keep an output test). | ≥ 1 vis + ≥ 2 hidden |

At risk:
- **u3-l1** (`greet` prints), **u7-l4** (`show` prints) and **u10-l2**
  (`work` prints the drop order) can only be tested on their prints, so they
  need `output_of`, which is Unverified under gVisor (D3). If D3 fails, all
  three go to `PRINT_ONLY_OK` with output tests, or their functions are
  changed to return a `String`.
- u9-l4 keeps its output test ("all tests passed") and adds hidden
  `check!(is_even(…))` tests.
- u11 tests: at most ~8 threads per test (`--pids-limit 64`) and within the
  5 s run limit.

## 10. Authoring guide (lessons and checkpoint challenges)

1. **Test what the learner writes.** If they write a function, use code
   tests. Use an output test only when printing is the skill.
2. **Fix the signature in the starter** and name it in the prompt. Stub
   bodies use `todo!()`, so tests fail with "not yet implemented". The
   starter must leave at least one test failing, so the learner's work
   must be inside what the tests call, not only in `main`.
   - Exception: when the lesson's point is adding a new item (a function,
     method, trait impl, module item, generic parameter), the starter may
     call it from `main` and not define it. The starter then doesn't
     compile, the compiler error shows what is missing, and the checker
     can't test the names against it (it prints a note; the reviewer checks
     by hand). Name the item so rustc has no suggestion for it (u0-l5 uses
     `add_numbers`: a call to `add(3, 4)` makes rustc suggest `3.add(4)`).
3. **Visible tests = the prompt's examples** (2–3, simplest first).
   **Hidden tests = the edge cases** (empty, zero, negative, max, ties,
   unicode, the error path), plus at least one input a hard-coded answer
   wouldn't match. What a visible test checks, a hidden test checks with
   other values [C2].
4. **One idea per test.** The label names the behaviour ("Returns None for
   an empty list"), in ≤ 80 characters of plain words, because it gets
   translated. Hidden tests may omit the label.
5. `check_eq!(actual, expected)`, learner's call first. `check_near!` for
   floats. `panics` only when a panic is the intended behaviour.
6. Test bodies see the learner's names. If a lesson defines its own
   `Option`/`Result`-like type, write `::std::option::Option` in the test.
7. Don't depend on test order, statics, time, randomness or stdin (stdin
   is empty). Keep each test under ~100 ms.
8. Run `python3 tool/check_lessons.py`: the solution passes everything and
   the starter fails something.
9. Limits that differ from `/run`: inside an `output_of` closure, file
   writes over 64 KB fail (`EFBIG`) and printing over 64 KB panics; keep
   to ≤ 20 threads per test (the 16 MiB grading thread shares the 320 MB
   cap); a learner `forbid` of one of the lints the harness allows is a
   `harness` error. A check inside a spawned thread whose `join` result is
   ignored is lost.

## 11. Risks and open questions

| Risk | Mitigation |
|---|---|
| Compile cost: the harness adds ≈ +0.15 s plus 0.002–0.025 s per test (x86); 3–4× a tiny program's bare compile | Round 3 measured whole jobs (container start included), x86, Docker runc, median of 9: at `opt-level=1` a graded job was 2.1–2.4× a `/run` job; at `opt-level=0` it is **u6-l2 0.398 s vs 0.275 s (1.45×), u12-l2 0.416 s vs 0.305 s (1.37×), u0-l1 0.397 s vs 0.260 s (1.53×)** (median of 15; a run of 9 gave 1.46, 1.34, 1.48). So two of three meet the 1.5× target and the print-only one sits at the edge: the cost is code generation of the harness (0.18 s of `--emit=obj` against 0.03 s for the bare program), not linking. Legacy exercises no longer use `/grade` at all. Still to measure: ARM, and gVisor (not installed here). |
| JSON diagnostics drift | Only used to place errors inside test code. Errors in learner code use the human output of the learner-only check. Parsing is defensive, and Rust is pinned by digest. |
| `output_of` under gVisor | D3. If it fails, drop it; u3-l1 and u7-l4 then take the fallback in §9. |
| Learner names and lints vs harness | The machinery lives in `mod __rr` with absolute paths and no lint attributes, and every helper is referenced. Residuals (test `error`, caught by the checker for solutions): a learner `deny(warnings)` plus a warning in a test body; `forbid(unsafe_code)` plus `output_of`. |
| Learner-only check misses an error class | Rule 2 (§6.1) reports any combined-compile error whose site is a learner line as `code`, so a check that passes can't turn learner errors into `harness`. G3b and G3c pin this. |
| Shared process state | Authoring rule 7. |
| Old app or old runner | `/run` is unchanged. Exercises that have `tests` need the new runner and Caddy: an app that gets 404 on `/grade` shows "needs an update" and never marks the exercise solved. Exercises with only `expectedOutput` (55 of 58 until PR 2) use `/run` and need nothing. |

Open questions for the owner:

1. Is it OK that hidden tests are **in the bundle, not secret**? Is any
   reward or ranking planned?
2. Should a failing hidden test show any hint? Proposed: only the count
   plus the "try edge cases" nudge.
3. Do we accept that Unit 0–2 print exercises can be passed by printing
   the exact text?
4. One "Run" button that runs the tests (proposed) vs separate "Run" and
   "Check" buttons?

## 12. Test plan

**`runner/grade` unit tests:**
- `build`: learner line numbers unchanged; ranges and the `main` call line
  are right; every helper is referenced from `__rr_grade`; the `unsafe` fd
  code appears only when a test uses `output_of`; no `#[allow`/`#![allow`
  in the output.
- `results`: pass/fail/panic/nopanic; records split by `print!` with no
  newline; wrong-nonce or garbled records are treated as text; exit 0 with
  and without all results; every id returned in order.
- Normalisation table.
- `classify_compile` fixtures:
  - an error in learner code (missing `}`, a type error, a borrow error);
  - an error only in a test via a macro (missing `Debug`, E0277), walked
    through `expansion`;
  - a renamed function;
  - a site in generated non-test lines → `harness` (and `no_main` for the
    `main()` call line; normally unreachable because E0601 is caught by
    rule 1);
  - an error at a learner line with a passing check → rule 2;
  - the span-less "aborting" diagnostic ignored;
  - warnings filtered to learner lines.

**Runner integration (`tests/api.rs`, Local):**
- G1 the solution passes. G2 a `todo!()` starter → `panic` "not yet
  implemented".
- G3 renamed function → `compileErrorsIn: tests`, `tests_dont_fit`.
- G3b `compileErrorsIn: code` with `stderr` **equal to `/run`'s** for the
  same code, for: a missing `}`, a type error, a borrow error,
  `let x: u8 = 255 + 1;` (arithmetic_overflow), and `[1, 2, 3][5]`
  (unconditional_panic). The last two would pass a metadata-only check,
  which is why the check uses `--emit=mir`.
- G3c a learner `#[cfg(test)] mod tests { … let x: i32 = "a"; … }` (passes
  the learner-only check) → rule 2: `compileErrorsIn: code`, `stderr` =
  that diagnostic's rendered text; no `harness` reason.
- G3d a learner `#![deny(warnings)]` → solution passes (all helpers
  referenced; `use super::*` used). A learner `#![forbid(unsafe_code)]` with
  an `output_of` test → test `error` (documented residual).
- G4 `loop {}` in test 2 → `timeout` for test 2, `not_run` for test 3.
  G5 `process::exit(3)` in a test → `crashed` `exit:3`, and
  `process::exit(0)` at the end of `main` → solved.
- G6 a forged record line has no effect. G7 too much output →
  `output_limit`.
- G8 `main() -> Result` with `Err` → "Error: …" in stderr.
- G9 `panics` substring match and mismatch. G10 a failing learner
  `#[test]` is not run.
- G11 validation 400s. G12 alternating `/run` and `/grade` drains one shared
  bucket.
- G13 recursion depth 20 000 (256-byte frames) passes in both `/run` and
  `/grade` (the 16 MiB grading thread). G13b 20 spawned threads work in
  both (local and Docker).
- G14 shadowing fixtures: the learner defines `Option`, `Result<T>`,
  `String`, `Vec`, `Box`, `Ok`/`Err`/`Some`/`None`; a test that uses
  `check_eq!` on learner functions still compiles and runs.
- G15 a learner `#![forbid(unused_variables)]` with clean tests passes.
- G16 a panic in a learner-spawned thread during a test appears in
  `stderr`.
- Log hygiene: no test code or output in the logs.

**Docker sandbox job (gVisor):** D1 G1–G4 and G13 through Docker. D2 no
source file is left when the program runs. D3 `output_of` works under
runsc.

**Deploy:** `smoke.sh` checks `POST /grade` without a header → 401 through
Caddy (not 404).

**Performance:** P1 on the VM: median of 20 for u6-l2 and u12-l2, `/run`
vs `/grade`, whole job. Recorded in the PR.

**App:**
- Model parsing, and the legacy synthesis.
- `HttpCodeRunner.grade`: mapping, 401 retry, `tests_invalid`, 404 →
  update message.
- Editor widget tests: all pass → `onSolved` once; hidden failing → count
  only, and the hidden label is absent from the tree; first failure
  expanded; compile-in-tests banner; runner unavailable / 429 / 404 → no
  panel, never solved.
- Semantics: announcement text and row labels.
- Reason codes → strings.

**Checker:** a fixture with a broken hidden test → exit 1 (`--self-test`).

## 13. Files touched (PR 1)

Runner and deploy:
- `runner/Cargo.toml` (workspace), `runner/grade/**` (new)
- `runner/src/lib.rs`, `runner/src/sandbox.rs`, `runner/src/telemetry.rs`
- `runner/Dockerfile`, `runner/sandbox.Dockerfile` (comment only)
- `runner/tests/api.rs`, `runner/tests/log_hygiene.rs`
- `runner/deploy/Caddyfile.template`, `runner/deploy/smoke.sh`
- `runner/deploy/README.md` (smoke step, curl example)
- `runner/docs/production-design.md` (HTTP contract: `/grade`)

App:
- `lib/data/models.dart`, `lib/runner/code_runner.dart`
- `lib/features/editor/code_editor.dart` (+ `tests_panel.dart`)
- `lib/features/lesson/lesson_screen.dart`
- strings, `test/**`

Tooling and content:
- `tool/check_lessons.py`, `.github/workflows/ci.yml`
- the three exemplar lesson JSON files
- `docs/course-map.md` (content format)

## 14. Review round 1 (changelog)

Every finding was re-checked locally before it was accepted.

**Accepted:**
- **B1 compile classification.** All three parts reproduced: the
  span-less "aborting…" diagnostic; macro errors with the primary span on
  the definition, the call site only in `expansion`; a missing `}` pointing
  at the harness's last line.
  - Fix: on a failed compile only, an `--emit=metadata` check (changed to `--emit=mir` in round 2) of the
    learner code, whose human output is used verbatim. Otherwise, walk
    `expansion` to a test range and ignore span-less diagnostics.
  - Change from the reviewer's suggestion: the learner file is written as
    `$work/main.rs` and the combined one as `$work/g/main.rs`, with
    `--remap-path-prefix`, so paths match `/run` exactly. Both are verified
    locally.
  - The check is bounded by the run timeout, so the envelope is unchanged.
- **B2 Caddy.** Confirmed `@runner path /run /health` + `respond 404`.
  `/grade` added there and in `smoke.sh`; listed in §13. Also checked: the
  `/grade` body limit (193 KB) is under Caddy's 256 KB.
- **M1 stack.** Reproduced (the threshold depends on frame size: depth
  20 000 with 256-byte frames overflows only under `--test`), and fixed by
  `RUST_MIN_STACK=8388608` (verified; replaced in round 3, see below). Test G13.
- **M2 shadowing / forbid.** Reproduced with learner `Option` and `String`.
  The machinery moved to a separate `mod __rr` (no glob import, absolute
  paths). Lint attributes removed from generated code and only used
  helpers emitted, so `forbid` can't clash. Residual case documented.
  Tests G14, G15, and authoring rule 6.
- **M3 groups.** A diff confirmed exactly u4-l4, u8-l1 and u10-l2 change
  only `main`. They moved to R (F = 23, R = 22). The exemplar is now u6-l2
  and the §4.3 example is marked illustrative. u3-l1 and u7-l4 are flagged
  as at risk with a fallback.
- **M4 prose from the server.** Replaced with `reason` codes and ARB keys.
- **Minor, all accepted:**
  - the `process::exit(0)` rule;
  - the hook is silent only on the grading thread;
  - `stderr` documented as the whole run's;
  - the nonce described as plain text in the binary;
  - cost numbers updated to include the reviewer's figures;
  - CI pinned to 1.99.1;
  - one table of minimums;
  - the starter-fit check documented as unverifiable when the starter
    doesn't compile;
  - the real u0-l1 example;
  - hidden labels optional and untranslated;
  - PR 2's dependency on the i18n PR and the absence of `vi/` and
    `--strict` stated;
  - the unavailable / 429 / 404 UX;
  - §13 files.

**Partly accepted:**
- The reviewer measured 0.002–0.005 s per test; I measured 0.025 s. Both
  are real: my cases formatted `HashMap`/`String`/`Option` values, which
  means more generic code. The doc now gives the range rather than
  replacing one figure with the other.

**Rejected:** none.

## 15. Review round 2 (changelog)

All findings were reproduced locally before being accepted.

- **N1 accepted.** `let x: u8 = 255 + 1;` and `[1, 2, 3][5]`:
  `--emit=metadata` exits 0, while `--emit=mir` (same `-C` flags) and the
  full build exit 1 with **byte-identical** output. The learner-only check
  now uses `--emit=mir` (§6.3), and the §2 claim is corrected. Timing:
  metadata 0.061 s, mir 0.077 s, full 0.125 s. Test G3b.
- **N2 accepted.** A learner `#[cfg(test)]` type error passes the mir check
  (rc 0). New rule 2 in §6.1: any combined-compile error whose site is
  ≤ N → `compileErrorsIn: "code"` with those diagnostics' rendered text.
  Classification is now an ordered table. Test G3c.
- **N3 accepted.** Verified: an unreferenced helper fails under
  `#![deny(warnings)]` (`dead_code`), and referencing it from `__rr_grade`
  fixes it.
  - All helpers and macros are always emitted.
  - Helpers are referenced once, and a self-check case uses each macro.
  - `main()` is called via the glob import.
  - Only the `unsafe` capture code is conditional. Test G3d.
- **N4 accepted as a residual.** `forbid(unsafe_code)` + `#[allow]` →
  E0453 (verified). There is no safe stable fd capture, so it is
  documented in §5, the checker catches it, and there is an authoring note.
- **N5 accepted.** Verified: 1.97 prints `thread 'main' (<id>) panicked
  at`. The harness can't get the OS thread id without `unsafe`, so the
  parser contract accepts both forms (regex in §5).
- **N6 accepted.** After rc 137, skip the check and exit 202. Added
  `mkdir -p "$work/g"`. The check is bounded with `timeout --signal=KILL`,
  and a killed check falls back to rules 2–4.
- **N7 accepted (kept as a fallback).** `no_main` is normally unreachable
  (E0601 is caught by rule 1). It is kept as a cheap fallback rather than
  folded into `harness`, because the learner-facing advice is different.

## 16. Review round 3 (changelog)

Each finding was reproduced before the fix.

- **Major 1 accepted.** A learner could print a `mainend` record with one
  field and make the server index out of bounds (the handler panicked). The
  record parser now checks values as well as arity per kind (`mainend` is
  exactly `ok`, or `panic` plus two fields) and reads fields with `get`
  everywhere. `NONCE` and `LEARNER_LINES` are private to `mod __rr`, so
  learner code cannot read them (a compile error in the learner's code).
  Tests: every record kind with every arity 0–4 and odd values must not
  panic (`malformed_records_never_panic`), a bad `mainend`, and an unclosed
  `\u{` run (the unescape no longer scans the rest of the text for each).
  Residual: a determined learner can still find the nonce by reading its own
  binary; this lets it forge only the record kinds it could print anyway, and
  only for its own grade.
- **Major 2 accepted, with the coordinator's two decisions.** (a) Legacy
  `expectedOutput`-only exercises use plain `/run` and the old client-side
  compare, shown as one output test (`GradeResult.fromLegacyRun`). (b) The
  combined build uses `-C opt-level=0` (keeping `overflow-checks=on`); the
  learner-only check keeps `/run`'s flags. Measured, whole jobs (container
  start included), x86, Docker runc, after one warm-up round:

  | lesson | `/run` | `/grade` | ratio |
  |---|---|---|---|
  | u6-l2 (4 tests) | 0.275 s | 0.398 s | 1.45 |
  | u12-l2 (1 output test) | 0.305 s | 0.416 s | 1.37 |
  | u0-l1 (1 output test) | 0.260 s | 0.397 s | 1.53 |

  (Median of 15 rounds; an earlier run of 9 gave 1.46, 1.34 and 1.48.)
  Before: u6-l2 0.28 → 0.63 s (2.2×), u12-l2 2.1×, u0-l1 2.4× (coordinator's
  numbers). ARM and gVisor were not measured. The test is
  `cost_grade_against_run_on_lesson_solutions` (ignored, Docker). Because
  frames are larger at opt-level 0, a recursion that fits `/run`'s 8 MiB could
  overflow in an 8 MiB grading thread (the 20 000-deep test did), so the
  grading thread has 16 MiB.
- **Major 3 accepted.** `RUST_MIN_STACK` applied to every learner thread: 20
  spawned threads failed with "failed to spawn thread" under the address-space
  cap. It is gone; the tests and `main` run on one thread the harness spawns
  with a 16 MiB stack (24 MiB broke 20 learner threads under the 320 MB cap,
  16 MiB does not), named `main`. If the spawn fails, they run on the calling
  thread. Tests: G13 (deep recursion) and G13b (20 threads), locally and in
  Docker.
- **Minor, accepted.** A check whose unwind the learner caught
  (`catch_unwind`) now fails the test (`FAILURE` is checked after `Ok`).
  Authoring note: a check inside a spawned thread whose join result is
  ignored is lost. `output_of` limits the capture file to 64 KB
  (`RLIMIT_FSIZE`, `SIGXFSZ` ignored), so a flood fails that test with
  "failed printing to stdout" instead of filling the tmpfs; the rlimit is
  restored before the final flush, so a line left in the buffer does not leak.
  `interpret_grade` marks `main`'s stdout "[output truncated]" only if `main`
  printed, and drops docker's "write /dev/stdout: broken pipe" line.
  `rr-grade` (local mode) now uses the runner's limits (compile 10 s, run and
  check 5 s, 64 KB of program output), kills the whole process group, and
  builds at opt-level 0; it still has no address-space cap.
  `main()` returning `Err` is a failed run as in `/run` (the harness exits
  with code 1: output tests are `crashed` with reason `exit:1`; code tests
  already ran).
- **Minor, partly accepted.** Learner `#![deny(unreachable_pub)]`,
  `unused_qualifications`, `let_underscore_drop`, `trivial_casts`,
  `trivial_numeric_casts` made the harness fail (reason `harness`). The
  generated modules now carry an `allow` of exactly those five (a lint the
  learner `forbid`s is still an error, as is tripping it; no other lint is
  listed because allowing a forbidden lint is itself an error).
  `#![no_implicit_prelude]` is the learner's own breakage (their `println!`
  fails, as in `/run`). A learner-defined `mod __rr` is not handled
  (documented residual).
- **Minor, accepted.** `check_lessons.py`: the docstring now states what
  `--strict` does; `--help` prints the usage; unknown options are refused;
  `rr-grade` is built with `--locked` and brought up to date once per run.
  `models.dart`: wrongly typed `label`, `panics` or `tests` are a
  `FormatException`. `code_editor.dart` is formatted again. The u4-l4 starter
  no longer warns about an unused parameter.

## Sources

- [E1] exercism/rust-test-runner `src/main.rs`: https://raw.githubusercontent.com/exercism/rust-test-runner/main/src/main.rs
- [E2] exercism/rust-test-runner `Dockerfile`: https://raw.githubusercontent.com/exercism/rust-test-runner/main/Dockerfile (README: https://github.com/exercism/rust-test-runner)
- [E3] Exercism test runner interface: https://raw.githubusercontent.com/exercism/docs/main/building/tooling/test-runners/interface.md
- [R1] The rustc book, Tests: https://doc.rust-lang.org/rustc/tests/index.html
- [R2] rust-lang/rust#49359: https://github.com/rust-lang/rust/issues/49359
- [R3] `std::panic::catch_unwind`: https://doc.rust-lang.org/std/panic/fn.catch_unwind.html
- [R4] `std::process::Termination`: https://doc.rust-lang.org/std/process/trait.Termination.html
- [R5] The rustc book, JSON Output: https://doc.rust-lang.org/rustc/json.html
- [C1] Codewars, submission tests: https://docs.codewars.com/authoring/guidelines/submission-tests/
- [C2] Codewars, sample tests: https://docs.codewars.com/authoring/guidelines/sample-tests/
- [L1] LeetCode discuss: https://leetcode.com/discuss/general-discussion/548314/accepted-then-wrong-answer-how-to-view-all-test-cases
- [L2] LeetCode support (403 to the fetch tool; search summary): https://support.leetcode.com/hc/en-us/articles/360012016874-Start-your-Coding-Practice
- [D1] Coddy help (403 to the fetch tool; search summary): https://coddy.tech/help/how-lessons-work, https://coddy.tech/help/answer-marked-wrong
- Local experiments (rustc 1.97.0, x86_64):
  - libtest JSON is refused on stable; `--test` keeps `main` callable;
  - glob-import privacy; `Option`/`String` shadowing breaks the harness;
  - a harness prototype (nonce records, `catch_unwind`, `panics`,
    `Termination`);
  - `dup2` capture; JSON diagnostic spans and `expansion`;
  - `--emit=metadata` vs `--emit=mir` errors; `--remap-path-prefix`;
  - test-thread stack vs `RUST_MIN_STACK`; compile timings.
- In this repo: `runner/src/sandbox.rs`, `runner/src/lib.rs`,
  `runner/deploy/Caddyfile.template`, `runner/deploy/smoke.sh`,
  `runner/docs/production-design.md`,
  `lib/features/editor/code_editor.dart`, `tool/check_lessons.py`,
  `assets/content/lessons/*.json`.
