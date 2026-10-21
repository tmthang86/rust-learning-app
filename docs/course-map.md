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
`note`) plus an optional `exercise` (starter code + expected output) and `quiz`.
Sections can be tagged `"track": "fast"` or `"track": "starter"` so one lesson
can show extra explanation to beginners and a "coming from X" comparison to
experienced developers.

Code sections are shown as read-only text; code runs only in the exercise
editor and the Playground tab. So when the text talks about what an example
prints, the example ends with a `// Output:` comment holding that output (most
Unit 7–12 examples have one), and `tool/check_lessons.py` checks the comment
against the real output.

### Checkpoint challenges

Every unit ends with a checkpoint: a lesson with id `uN-check` (for example
`u3-check`) listed last in the unit in `course.json` with `"checkpoint": true`.
The file has the same schema as any lesson (sections, `exercise`, `quiz`) and
`tool/check_lessons.py` requires an exercise with a solution. It is graded like
an exercise (the program's printed output is compared with `expectedOutput`),
counts as a normal lesson for progress (`N of M lessons done`) and syncs under
its id like any other lesson. The app shows it with a trophy icon and a
"Checkpoint" label in the course map. A checkpoint is designed around named
functions with fixed signatures (the learner implements `fn is_even(n: i32) ->
bool`, and so on), so a later multi-test grader can call those functions with
several inputs instead of only comparing one printed output.

## Release scope

- **First release:** Units 0–6 fully written (enough for a learner to write real
  small programs).
- **Updates after launch:** Units 7–12, roughly one unit every two weeks.
