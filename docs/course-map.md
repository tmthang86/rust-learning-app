# Course map

The course serves everyone from first-time programmers to experienced developers
coming from another language. Learners pick one of two entry tracks on first launch;
both tracks merge at Unit 1 and share everything after that.

| Track | Who it's for | Starts at |
|---|---|---|
| **Starter** | New to programming | Unit 0, then Unit 1 |
| **Fast track** | Knows another language (Python, JS, Java, C#, Go, C++...) | Unit 1, with "coming from X" notes in each lesson |

Every lesson follows the same shape: short explanation → runnable example →
small exercise in the editor → 2–4 quiz questions. Each unit ends with a
checkpoint challenge.

## Units

| # | Unit | Key lessons | Track |
|---|---|---|---|
| 0 | Programming basics | What a program is, values and variables, if/else, loops, functions | Starter only |
| 1 | Getting started | Hello world, Cargo, `println!`, variables and mutability, shadowing | Both |
| 2 | Types and control flow | Scalar and compound types, `if` as an expression, loops, functions | Both |
| 3 | Ownership | Moves, `Copy` vs `Clone`, borrowing, references, slices | Both |
| 4 | Structs and enums | Structs, methods, enums, `Option`, `match`, `if let` | Both |
| 5 | Collections and strings | `Vec`, `String` vs `&str`, `HashMap` | Both |
| 6 | Error handling | `panic!`, `Result`, the `?` operator, custom errors | Both |
| 7 | Generics and traits | Generic functions and types, traits, trait bounds, lifetimes | Both |
| 8 | Closures and iterators | Closures, `Iterator`, adapters, `collect` | Both |
| 9 | Modules, crates and testing | Modules, visibility, crates, `cargo test` | Both |
| 10 | Smart pointers | `Box`, `Rc`, `RefCell`, interior mutability | Both |
| 11 | Concurrency | Threads, channels, `Arc` and `Mutex`, intro to async | Both |
| 12 | Capstone projects | CLI tool, text adventure, mini web server | Both |

## Content format

Lessons live in `assets/content/lessons/<lesson-id>.json`; the unit list lives in
`assets/content/course.json`. A lesson is a list of sections (`text`, `code`,
`note`) plus an optional `exercise` (prompt, starter, solution, hints and tests)
and `quiz`.
Sections can be tagged `"track": "fast"` or `"track": "starter"` so one lesson
can show extra explanation to beginners and a "coming from X" comparison to
experienced developers.

Code sections are shown as read-only text; code runs only in the exercise
editor and the Playground tab. So when the text talks about what an example
prints, the example ends with a `// Output:` comment holding that output (most
Unit 7–12 examples have one), and `tool/check_lessons.py` checks the comment
against the real output.

### Exercise tests

An exercise is graded by `exercise.tests`, a list of 1 to 50 tests that run in
order on the runner's `POST /grade` (design: `exercise-tests-design.md`). The
exercise is solved when every test passes, hidden ones included. Lessons not
yet migrated keep `expectedOutput`: the checker reads it as one output test,
and the app runs it with plain `/run` and compares the output itself, showing
one test (`tests` and `expectedOutput` are never both present).

| Field | Meaning |
|---|---|
| `id` | `^[a-z0-9][a-z0-9-]{0,39}$`, unique in the exercise; never shown |
| `label` | Prose, at most 80 characters. Required on visible tests (it is translated); optional on hidden ones (a note for reviewers, never shown) |
| `hidden` | `true` shows the test only as a count. Code tests only. Hidden tests ship in the app bundle: hidden in the UI, not secret |
| `code` | A **code test**: Rust statements run inside the learner's crate, with `check_eq!(actual, expected);`, `check!(cond);`, `check_near!(a, b, tolerance);` and `output_of(\|\| ...)` for what a function prints. Actual comes first. They can call private items |
| `panics` | With `code`: passes only if the code panics with a message containing this text (`""` = any panic) |
| `output` | An **output test**: what `main` must print (compared after trimming trailing whitespace and blank edge lines). One at most, never hidden |

Write tests for what the learner writes: a function, with its signature fixed
in the starter (stub bodies use `todo!()`), visible tests for the prompt's
examples and hidden tests for edge cases. Use an output test only where
printing is the skill (Units 0-2). `python3 tool/check_lessons.py` grades the
solution (must pass everything) and the starter (must fail something) with the
runner's own grading crate. Minimums: a print-only exercise needs 1 visible
output test (Units 0-2 only); a function exercise needs 2 visible and 2 hidden
code tests; an exercise restructured so a function holds the learner's change
needs 1 visible and 2 hidden; a checkpoint challenge needs 3 and 3. `--strict`
(turned on once every lesson is migrated) makes `expectedOutput` and the
minimums errors.

### Checkpoint challenges

Every unit ends with a checkpoint: a lesson with id `uN-check` (for example
`u3-check`) listed last in the unit in `course.json` with `"checkpoint": true`.
The file has the same schema as any lesson (sections, `exercise`, `quiz`) and
`tool/check_lessons.py` requires an exercise with a solution. For now it is
graded by `expectedOutput` (the program's printed output is compared with it);
checkpoints move to `exercise.tests` later (3 visible and 3 hidden code tests,
see Exercise tests above),
counts as a normal lesson for progress (`N of M lessons done`) and syncs under
its id like any other lesson. The app shows it with a trophy icon and a
"Checkpoint" label in the course map. A checkpoint is designed around named
functions with fixed signatures (the learner implements `fn is_even(n: i32) ->
bool`, and so on), so the multi-test grader can call those functions with several
inputs instead of only comparing one printed output.

## Release scope

- **First release:** Units 0–6 fully written (enough for a learner to write real
  small programs).
- **Updates after launch:** Units 7–12, roughly one unit every two weeks.
