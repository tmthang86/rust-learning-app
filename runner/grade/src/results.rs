//! Turning the graded program's stdout into one result per test.
//!
//! The harness writes **records** to stdout, each tagged with the job's
//! nonce:
//!
//! ```text
//! \x01RR-T:<nonce>:<kind> (\x1f <escaped field>)* \n
//! ```
//!
//! | Kind | Fields | Meaning |
//! |---|---|---|
//! | `case` | id | a test starts; stdout up to the next record is its output |
//! | `pass` | | it passed |
//! | `fail` | expr, expected, actual | a check failed |
//! | `panic` | message, line | it panicked (unexpectedly, or the message didn't match) |
//! | `nopanic` | | `panics` was set but nothing panicked |
//! | `main` / `mainend` | / `ok` or `panic`, message, line | stdout in between is `main`'s output |
//! | `done` | | the harness finished |
//!
//! Escaping: `\` is `\\`, a newline is `\n`, other control characters are
//! `\u{hex}`. Anything that is not a well-formed record with the right nonce
//! (a learner print, libtest's own lines) is plain text.

use std::collections::HashMap;

use crate::generate::{Generated, TestPlan};
use crate::normalize::normalize;
use crate::{Status, TestResult, truncate_marked};

const VALUE_CAP: usize = 1024;
const OUTPUT_CAP: usize = 2 * 1024;
/// Output tests show more: the learner compares whole lines.
const OUTPUT_TEST_CAP: usize = 2 * 1024;

/// How the process ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum End {
    /// It exited by itself with this code (128 + signal when killed).
    Exited(i32),
    /// The run timeout.
    TimedOut,
    /// Stopped for using too much memory.
    MemLimit,
    /// Stopped for printing too much.
    OutputLimit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EndState {
    pub end: End,
    /// stderr says the program overflowed its stack.
    pub stack_overflow: bool,
}

impl EndState {
    pub fn exited(code: i32) -> Self {
        Self {
            end: End::Exited(code),
            stack_overflow: false,
        }
    }

    /// The status and reason of whatever was running when the process ended.
    fn interrupted(&self) -> (Status, Option<String>) {
        match self.end {
            End::TimedOut => (Status::Timeout, None),
            End::MemLimit => (Status::Crashed, Some("mem_limit".into())),
            End::OutputLimit => (Status::Crashed, Some("output_limit".into())),
            End::Exited(_) if self.stack_overflow => {
                (Status::Crashed, Some("stack_overflow".into()))
            }
            End::Exited(code) => (Status::Crashed, Some(format!("exit:{code}"))),
        }
    }
}

/// What happened to the learner's `main`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MainStatus {
    Ok,
    Panicked {
        message: String,
        line: Option<u32>,
    },
    /// It did not finish (a test crashed first, or `main` itself did).
    NotFinished,
}

#[derive(Debug, Clone)]
pub struct RunVerdict {
    /// One result per requested test, in request order.
    pub tests: Vec<TestResult>,
    /// What `main` printed.
    pub main_stdout: String,
    pub main: MainStatus,
    /// The reason of the first crashed test, for the response's top level.
    pub reason: Option<String>,
}

#[derive(Debug)]
struct Record {
    kind: String,
    fields: Vec<String>,
}

#[derive(Debug)]
enum Item {
    Text(String),
    Rec(Record),
}

fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('\\') => out.push('\\'),
            Some('n') => out.push('\n'),
            Some('u') => {
                let rest = chars.as_str();
                let parsed = rest.strip_prefix('{').and_then(|r| {
                    // At most 8 hex digits, so an unclosed `\u{` costs a few
                    // bytes to look at, not the rest of the text.
                    let end = r.char_indices().take(9).find(|(_, c)| *c == '}')?.0;
                    let ch = char::from_u32(u32::from_str_radix(&r[..end], 16).ok()?)?;
                    Some((ch, end + 2))
                });
                match parsed {
                    Some((ch, used)) => {
                        out.push(ch);
                        chars = rest[used..].chars();
                    }
                    None => out.push_str("\\u"),
                }
            }
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Whether a record has the shape its kind needs: the right number of
/// fields and, where a field picks between meanings, one of them. Anything
/// else (the learner can print what it likes) is plain output.
fn well_formed(kind: &str, fields: &[String]) -> bool {
    match kind {
        "case" => fields.len() == 1,
        "pass" | "nopanic" | "main" | "done" => fields.is_empty(),
        "fail" => fields.len() == 3,
        "panic" => fields.len() == 2,
        "mainend" => {
            (fields.len() == 1 && fields[0] == "ok") || (fields.len() == 3 && fields[0] == "panic")
        }
        _ => false,
    }
}

fn parse_items(stdout: &str, nonce: &str) -> Vec<Item> {
    let prefix = format!("\u{1}RR-T:{nonce}:");
    let mut items = Vec::new();
    let mut pos = 0;
    let mut text_from = 0;
    while let Some(found) = stdout[pos..].find(&prefix) {
        let start = pos + found;
        let body_start = start + prefix.len();
        let Some(len) = stdout[body_start..].find('\n') else {
            break; // cut off: plain text
        };
        let body = &stdout[body_start..body_start + len];
        let end = body_start + len + 1;
        let mut parts = body.split('\u{1f}');
        let kind = parts.next().unwrap_or("").to_string();
        let fields: Vec<String> = parts.map(unescape).collect();
        if well_formed(&kind, &fields) {
            if start > text_from {
                items.push(Item::Text(stdout[text_from..start].to_string()));
            }
            items.push(Item::Rec(Record { kind, fields }));
            text_from = end;
        }
        pos = end;
    }
    if text_from < stdout.len() {
        items.push(Item::Text(stdout[text_from..].to_string()));
    }
    items
}

#[derive(Debug)]
enum MainEnd {
    Ok,
    Panic(String, Option<u32>),
}

/// Reads the graded program's `stdout` into one result per test of `g`.
pub fn results(g: &Generated, stdout: &str, end: &EndState) -> RunVerdict {
    let mut done_cases: HashMap<String, TestResult> = HashMap::new();
    let mut current: Option<(String, String)> = None; // (id, printed so far)
    let mut main_started = false;
    let mut main_out = String::new();
    let mut main_end: Option<MainEnd> = None;

    for item in parse_items(stdout, &g.nonce) {
        match item {
            Item::Text(t) => {
                if main_started && main_end.is_none() {
                    main_out.push_str(&t);
                } else if let Some((_, printed)) = &mut current {
                    printed.push_str(&t);
                }
            }
            Item::Rec(r) => {
                let f = |i: usize| r.fields.get(i).map_or("", String::as_str);
                match r.kind.as_str() {
                    "case" => current = Some((f(0).to_string(), String::new())),
                    "pass" | "fail" | "panic" | "nopanic" => {
                        if let Some((id, printed)) = current.take() {
                            done_cases
                                .entry(id.clone())
                                .or_insert_with(|| case_result(&id, &r, printed));
                        }
                    }
                    "main" => {
                        current = None;
                        main_started = true;
                    }
                    "mainend" if main_started => {
                        main_end = Some(if f(0) == "ok" {
                            MainEnd::Ok
                        } else {
                            MainEnd::Panic(
                                truncate_marked(f(1), VALUE_CAP),
                                f(2).parse::<u32>().ok(),
                            )
                        });
                    }
                    _ => {}
                }
            }
        }
    }

    // The first code test without a result is the one the process stopped
    // in (or before); everything after it never ran.
    let first_missing = g
        .plans
        .iter()
        .enumerate()
        .find(|(i, p)| matches!(p, TestPlan::Code { .. }) && !done_cases.contains_key(&g.ids[*i]))
        .map(|(i, _)| i);

    // `process::exit(0)` inside `main`, after every test: `main` finished.
    let main_status = match (&main_end, first_missing, end.end) {
        (Some(MainEnd::Ok), _, _) => MainStatus::Ok,
        (Some(MainEnd::Panic(m, l)), _, _) => MainStatus::Panicked {
            message: m.clone(),
            line: *l,
        },
        (None, None, End::Exited(0)) if main_started => MainStatus::Ok,
        _ => MainStatus::NotFinished,
    };

    let mut tests = Vec::with_capacity(g.ids.len());
    for (i, plan) in g.plans.iter().enumerate() {
        let id = &g.ids[i];
        let result = match plan {
            TestPlan::Code { .. } => match done_cases.get(id) {
                Some(done) => done.clone(),
                None if first_missing == Some(i) => interrupted(id, end),
                None => TestResult::new(id, Status::NotRun),
            },
            TestPlan::Output { expected } => match &main_status {
                MainStatus::Ok => output_result(id, expected, &main_out),
                MainStatus::Panicked { message, line } => {
                    let mut t = TestResult::new(id, Status::Panic);
                    t.message = Some(message.clone());
                    t.line = *line;
                    t
                }
                MainStatus::NotFinished if first_missing.is_some() => {
                    TestResult::new(id, Status::NotRun)
                }
                MainStatus::NotFinished => interrupted(id, end),
            },
        };
        tests.push(result);
    }
    let reason = tests
        .iter()
        .find(|t| t.status == Status::Crashed)
        .and_then(|t| t.reason.clone());
    RunVerdict {
        tests,
        main_stdout: main_out,
        main: main_status,
        reason,
    }
}

fn interrupted(id: &str, end: &EndState) -> TestResult {
    let (status, reason) = end.interrupted();
    let mut t = TestResult::new(id, status);
    t.reason = reason;
    t
}

fn case_result(id: &str, r: &Record, printed: String) -> TestResult {
    let f = |i: usize| r.fields.get(i).map_or("", String::as_str);
    let mut t = match r.kind.as_str() {
        "pass" => return TestResult::new(id, Status::Pass),
        "fail" => {
            let mut t = TestResult::new(id, Status::Fail);
            t.expr = Some(truncate_marked(f(0), VALUE_CAP));
            t.expected = Some(truncate_marked(f(1), VALUE_CAP));
            t.actual = Some(truncate_marked(f(2), VALUE_CAP));
            t
        }
        "panic" => {
            let mut t = TestResult::new(id, Status::Panic);
            t.message = Some(truncate_marked(f(0), VALUE_CAP));
            t.line = f(1).parse::<u32>().ok();
            t
        }
        _ => TestResult::new(id, Status::Nopanic),
    };
    if !printed.is_empty() {
        t.output = Some(truncate_marked(&printed, OUTPUT_CAP));
    }
    t
}

fn output_result(id: &str, expected: &str, printed: &str) -> TestResult {
    if normalize(printed) == normalize(expected) {
        return TestResult::new(id, Status::Pass);
    }
    let mut t = TestResult::new(id, Status::Fail);
    t.expected = Some(truncate_marked(expected, OUTPUT_TEST_CAP));
    t.actual = Some(truncate_marked(printed, OUTPUT_TEST_CAP));
    t
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TestSpec;
    use crate::generate::build;

    const NONCE: &str = "0123456789abcdef0123456789abcdef";

    fn code(id: &str) -> TestSpec {
        TestSpec {
            id: id.into(),
            code: Some("check!(true);".into()),
            ..TestSpec::default()
        }
    }

    fn output(id: &str, expected: &str) -> TestSpec {
        TestSpec {
            id: id.into(),
            output: Some(expected.into()),
            ..TestSpec::default()
        }
    }

    fn gen_(tests: &[TestSpec]) -> Generated {
        build("fn main() {}\n", tests, NONCE)
    }

    fn rec(kind: &str, fields: &[&str]) -> String {
        let mut s = format!("\u{1}RR-T:{NONCE}:{kind}");
        for f in fields {
            s.push('\u{1f}');
            s.push_str(&f.replace('\\', "\\\\").replace('\n', "\\n"));
        }
        s.push('\n');
        s
    }

    fn statuses(v: &RunVerdict) -> Vec<Status> {
        v.tests.iter().map(|t| t.status).collect()
    }

    /// A clean run: self-check, then the given case records, then main.
    fn run(cases: &[(&str, &[&str])], main_out: &str) -> String {
        let mut s = String::from("\nrunning 1 test\n");
        s += &rec("case", &["__self"]);
        s += &rec("pass", &[]);
        for (id, result) in cases {
            s += &rec("case", &[id]);
            for r in result.iter() {
                s += r;
            }
        }
        s += &rec("main", &[]);
        s += main_out;
        s += &rec("mainend", &["ok"]);
        s += &rec("done", &[]);
        s += ".\ntest result: ok.\n";
        s
    }

    #[test]
    fn pass_fail_panic_and_nopanic() {
        let g = gen_(&[code("a"), code("b"), code("c"), code("d")]);
        let mut s = String::new();
        s += &rec("case", &["__self"]);
        s += &rec("pass", &[]);
        s += &rec("case", &["a"]);
        s += &rec("pass", &[]);
        s += &rec("case", &["b"]);
        s += "printed in b\n";
        s += &rec("fail", &["add(1, 1)", "2", "3"]);
        s += &rec("case", &["c"]);
        s += &rec("panic", &["index out of bounds", "4"]);
        s += &rec("case", &["d"]);
        s += &rec("nopanic", &[]);
        s += &rec("main", &[]);
        s += "hello\n";
        s += &rec("mainend", &["ok"]);
        s += &rec("done", &[]);
        let v = results(&g, &s, &EndState::exited(0));
        assert_eq!(
            statuses(&v),
            [Status::Pass, Status::Fail, Status::Panic, Status::Nopanic]
        );
        let b = &v.tests[1];
        assert_eq!(b.expr.as_deref(), Some("add(1, 1)"));
        assert_eq!(b.expected.as_deref(), Some("2"));
        assert_eq!(b.actual.as_deref(), Some("3"));
        assert_eq!(b.output.as_deref(), Some("printed in b\n"));
        assert_eq!(v.tests[2].message.as_deref(), Some("index out of bounds"));
        assert_eq!(v.tests[2].line, Some(4));
        assert_eq!(v.main_stdout, "hello\n");
        assert_eq!(v.main, MainStatus::Ok);
        assert_eq!(v.tests[0].output, None);
    }

    #[test]
    fn every_id_comes_back_in_request_order() {
        let g = gen_(&[code("z"), output("o", "hi"), code("a")]);
        let s = run(
            &[("z", &[&rec("pass", &[])]), ("a", &[&rec("pass", &[])])],
            "hi\n",
        );
        let v = results(&g, &s, &EndState::exited(0));
        let ids: Vec<&str> = v.tests.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, ["z", "o", "a"]);
        assert_eq!(statuses(&v), [Status::Pass; 3]);
    }

    #[test]
    fn output_tests_compare_normalised_main_output() {
        let g = gen_(&[output("o", "First\nSecond")]);
        let v = results(&g, &run(&[], "First  \r\nSecond\n\n"), &EndState::exited(0));
        assert_eq!(statuses(&v), [Status::Pass]);
        let v = results(&g, &run(&[], "Second\nFirst\n"), &EndState::exited(0));
        assert_eq!(statuses(&v), [Status::Fail]);
        assert_eq!(v.tests[0].expected.as_deref(), Some("First\nSecond"));
        assert_eq!(v.tests[0].actual.as_deref(), Some("Second\nFirst\n"));
    }

    #[test]
    fn a_panic_in_main_fails_output_tests() {
        let g = gen_(&[output("o", "hi")]);
        let mut s = rec("main", &[]);
        s += "hi\n";
        s += &rec("mainend", &["panic", "boom", "3"]);
        s += &rec("done", &[]);
        let v = results(&g, &s, &EndState::exited(0));
        assert_eq!(statuses(&v), [Status::Panic]);
        assert_eq!(v.tests[0].message.as_deref(), Some("boom"));
        assert_eq!(v.tests[0].line, Some(3));
        assert_eq!(
            v.main,
            MainStatus::Panicked {
                message: "boom".into(),
                line: Some(3)
            }
        );
    }

    #[test]
    fn records_are_found_after_print_without_newline() {
        let g = gen_(&[code("a"), output("o", "ab")]);
        // `print!("a")` in the test, `print!("ab")` in main: no newline, so
        // the record starts in the middle of a line.
        let mut s = rec("case", &["a"]);
        s += "a";
        s += &rec("pass", &[]);
        s += &rec("main", &[]);
        s += "ab";
        s += &rec("mainend", &["ok"]);
        s += &rec("done", &[]);
        let v = results(&g, &s, &EndState::exited(0));
        assert_eq!(statuses(&v), [Status::Pass, Status::Pass]);
        assert_eq!(v.main_stdout, "ab");
    }

    #[test]
    fn wrong_nonce_and_garbled_records_are_plain_text() {
        let g = gen_(&[output("o", "x")]);
        let forged = "\u{1}RR-T:ffffffffffffffffffffffffffffffff:pass\n";
        let garbled_kind = format!("\u{1}RR-T:{NONCE}:bogus\u{1f}x\n");
        let garbled_fields = format!("\u{1}RR-T:{NONCE}:fail\u{1f}only-one\n");
        let cut_off = format!("\u{1}RR-T:{NONCE}:pass");
        let mut s = rec("main", &[]);
        s += forged;
        s += &garbled_kind;
        s += &garbled_fields;
        s += &rec("mainend", &["ok"]);
        s += &rec("done", &[]);
        s += &cut_off;
        let v = results(&g, &s, &EndState::exited(0));
        assert_eq!(
            v.main_stdout,
            format!("{forged}{garbled_kind}{garbled_fields}")
        );
        assert_eq!(statuses(&v), [Status::Fail]);
    }

    #[test]
    fn a_forged_pass_for_a_test_that_did_not_run_has_no_effect() {
        let g = gen_(&[code("a"), code("b")]);
        // Test "a" prints a pass for "b" without the nonce, then loops.
        let mut s = rec("case", &["a"]);
        s += "\u{1}RR-T:wrong:pass\n";
        let v = results(
            &g,
            &s,
            &EndState {
                end: End::TimedOut,
                stack_overflow: false,
            },
        );
        assert_eq!(statuses(&v), [Status::Timeout, Status::NotRun]);
    }

    /// The learner can print any record with the right nonce (if it finds
    /// it): whatever the shape, grading must not panic.
    #[test]
    fn malformed_records_never_panic() {
        let g = gen_(&[code("a"), code("b"), output("o", "x")]);
        let kinds = [
            "case", "pass", "fail", "panic", "nopanic", "main", "mainend", "done", "other", "",
        ];
        let values = [
            "",
            "ok",
            "panic",
            "boom",
            "-1",
            "99999999999",
            "\\u{zz}",
            "\\u{",
        ];
        let ends = [
            EndState {
                end: End::Exited(0),
                stack_overflow: false,
            },
            EndState {
                end: End::TimedOut,
                stack_overflow: false,
            },
            EndState {
                end: End::Exited(1),
                stack_overflow: true,
            },
        ];
        let mut cases = 0;
        for kind in kinds {
            for arity in 0..=4usize {
                for value in values {
                    let fields = vec![value; arity];
                    let forged = rec(kind, &fields);
                    // Alone, after a case, and after main started.
                    for prefix in [
                        String::new(),
                        rec("case", &["a"]),
                        rec("case", &["a"]) + &rec("pass", &[]) + &rec("main", &[]),
                    ] {
                        let stdout = format!("{prefix}{forged}{}", rec("done", &[]));
                        for end in &ends {
                            let v = results(&g, &stdout, end);
                            assert_eq!(v.tests.len(), 3, "{kind} {arity} {value:?}");
                            cases += 1;
                        }
                    }
                }
            }
        }
        assert!(cases > 1000);
    }

    #[test]
    fn a_mainend_that_is_neither_ok_nor_panic_is_plain_output() {
        let g = gen_(&[output("o", "hi\n")]);
        let mut s = rec("main", &[]);
        s += "hi\n";
        s += &rec("mainend", &["boom"]);
        s += &rec("mainend", &["ok"]);
        let v = results(
            &g,
            &s,
            &EndState {
                end: End::Exited(0),
                stack_overflow: false,
            },
        );
        // The forged line is part of what the program printed, and the real
        // end of `main` still counts.
        assert!(v.main_stdout.contains("boom"));
        assert_eq!(statuses(&v), [Status::Fail]);
        assert_eq!(v.main, MainStatus::Ok);
    }

    #[test]
    fn many_unclosed_unicode_escapes_are_cheap() {
        let text = "\\u{".repeat(200_000);
        let started = std::time::Instant::now();
        assert_eq!(unescape(&text), text);
        assert!(started.elapsed() < std::time::Duration::from_secs(2));
    }

    #[test]
    fn timeout_marks_the_running_test_and_the_rest_not_run() {
        let g = gen_(&[code("a"), code("b"), code("c"), output("o", "x")]);
        let mut s = rec("case", &["a"]);
        s += &rec("pass", &[]);
        s += &rec("case", &["b"]);
        let v = results(
            &g,
            &s,
            &EndState {
                end: End::TimedOut,
                stack_overflow: false,
            },
        );
        assert_eq!(
            statuses(&v),
            [
                Status::Pass,
                Status::Timeout,
                Status::NotRun,
                Status::NotRun
            ]
        );
        assert_eq!(v.main, MainStatus::NotFinished);
    }

    #[test]
    fn crashes_carry_a_machine_reason() {
        let g = gen_(&[code("a"), code("b")]);
        let s = rec("case", &["a"]);
        let cases = [
            (
                EndState {
                    end: End::MemLimit,
                    stack_overflow: false,
                },
                "mem_limit",
            ),
            (
                EndState {
                    end: End::OutputLimit,
                    stack_overflow: false,
                },
                "output_limit",
            ),
            (
                EndState {
                    end: End::Exited(134),
                    stack_overflow: true,
                },
                "stack_overflow",
            ),
            (EndState::exited(3), "exit:3"),
            (EndState::exited(0), "exit:0"),
        ];
        for (end, reason) in cases {
            let v = results(&g, &s, &end);
            assert_eq!(statuses(&v), [Status::Crashed, Status::NotRun], "{reason}");
            assert_eq!(v.tests[0].reason.as_deref(), Some(reason));
            assert_eq!(v.reason.as_deref(), Some(reason));
        }
    }

    #[test]
    fn a_crash_before_any_test_blames_the_first_one() {
        let g = gen_(&[code("a"), code("b")]);
        let v = results(&g, "", &EndState::exited(139));
        assert_eq!(statuses(&v), [Status::Crashed, Status::NotRun]);
        assert_eq!(v.tests[0].reason.as_deref(), Some("exit:139"));
    }

    #[test]
    fn exit_in_main_after_every_test_counts_as_main_finished() {
        let g = gen_(&[code("a"), output("o", "hi")]);
        let mut s = rec("case", &["a"]);
        s += &rec("pass", &[]);
        s += &rec("main", &[]);
        s += "hi\n"; // then process::exit(0): no mainend, no done
        let v = results(&g, &s, &EndState::exited(0));
        assert_eq!(statuses(&v), [Status::Pass, Status::Pass]);
        assert_eq!(v.main, MainStatus::Ok);
        // The same with a non-zero exit is a crash of main.
        let v = results(&g, &s, &EndState::exited(3));
        assert_eq!(statuses(&v), [Status::Pass, Status::Crashed]);
        assert_eq!(v.tests[1].reason.as_deref(), Some("exit:3"));
    }

    #[test]
    fn exit_zero_inside_a_test_is_a_crash_of_that_test() {
        let g = gen_(&[code("a"), code("b")]);
        let s = rec("case", &["a"]);
        let v = results(&g, &s, &EndState::exited(0));
        assert_eq!(statuses(&v), [Status::Crashed, Status::NotRun]);
        assert_eq!(v.tests[0].reason.as_deref(), Some("exit:0"));
    }

    #[test]
    fn main_that_times_out_fails_only_output_tests() {
        let g = gen_(&[code("a"), output("o", "x")]);
        let mut s = rec("case", &["a"]);
        s += &rec("pass", &[]);
        s += &rec("main", &[]);
        let v = results(
            &g,
            &s,
            &EndState {
                end: End::TimedOut,
                stack_overflow: false,
            },
        );
        assert_eq!(statuses(&v), [Status::Pass, Status::Timeout]);
    }

    #[test]
    fn values_are_capped_and_escapes_round_trip() {
        let g = gen_(&[code("a")]);
        let big = "x".repeat(5000);
        let mut s = rec("case", &["a"]);
        s += &rec("fail", &["e", &big, "line1\nline2 \\ end"]);
        s += &rec("main", &[]);
        s += &rec("mainend", &["ok"]);
        s += &rec("done", &[]);
        let v = results(&g, &s, &EndState::exited(0));
        let t = &v.tests[0];
        assert!(t.expected.as_ref().unwrap().ends_with("...[truncated]"));
        assert!(t.expected.as_ref().unwrap().len() < 1100);
        assert_eq!(t.actual.as_deref(), Some("line1\nline2 \\ end"));
    }

    #[test]
    fn unicode_escapes_are_decoded() {
        assert_eq!(unescape("a\\u{1f}b\\u{e9}"), "a\u{1f}b\u{e9}");
        assert_eq!(unescape("bad\\u{zz}"), "bad\\u{zz}");
        assert_eq!(unescape("end\\"), "end\\");
        assert_eq!(unescape("\\x"), "\\x");
    }
}
