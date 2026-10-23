//! The harness against a real `rustc`: what the generated code does, in the
//! cases the design doc lists. These grade on the host (no sandbox), so they
//! are about meaning, not isolation; `runner/tests/api.rs` repeats the
//! important ones through the server and, ignored by default, Docker.

use std::time::Duration;

use rr_grade::local::{Options, grade};
use rr_grade::{ErrorsIn, Response, Stage, Status, TestSpec};

fn code(id: &str, body: &str) -> TestSpec {
    TestSpec {
        id: id.into(),
        code: Some(body.into()),
        ..TestSpec::default()
    }
}

fn panics(id: &str, body: &str, text: &str) -> TestSpec {
    TestSpec {
        panics: Some(text.into()),
        ..code(id, body)
    }
}

fn output(id: &str, expected: &str) -> TestSpec {
    TestSpec {
        id: id.into(),
        output: Some(expected.into()),
        ..TestSpec::default()
    }
}

fn run(source: &str, tests: &[TestSpec]) -> Response {
    let opts = Options {
        run_timeout: Duration::from_secs(3),
        ..Options::default()
    };
    grade(source, tests, &opts).expect("grading ran")
}

fn statuses(r: &Response) -> Vec<Status> {
    r.tests.iter().map(|t| t.status).collect()
}

const ADD: &str = "fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn main() {\n    println!(\"{}\", add(1, 2));\n}\n";

#[test]
fn the_solution_passes_every_kind_of_test() {
    let r = run(
        ADD,
        &[
            code("one", "check_eq!(add(1, 1), 2);"),
            code("two", "check!(add(2, 2) == 4);"),
            code("near", "check_near!(add(1, 1) as f64 / 3.0, 0.667, 0.001);"),
            output("out", "3"),
            panics(
                "pan",
                "let v: Vec<i32> = Vec::new(); let _ = v[add(1, 1) as usize];",
                "index out of bounds",
            ),
        ],
    );
    assert_eq!(statuses(&r), [Status::Pass; 5], "{r:?}");
    assert_eq!(r.stage, Stage::Run);
    assert!(r.success);
    assert_eq!(r.stdout, "3\n");
    assert_eq!(r.warnings, "");
}

#[test]
fn a_todo_starter_panics_in_the_test_and_keeps_main_output_separate() {
    let r = run(
        "fn add(_a: i32, _b: i32) -> i32 {\n    todo!()\n}\n\nfn main() {\n    println!(\"hi\");\n}\n",
        &[code("one", "check_eq!(add(1, 1), 2);")],
    );
    assert_eq!(statuses(&r), [Status::Panic], "{r:?}");
    let t = &r.tests[0];
    assert!(
        t.message
            .as_deref()
            .unwrap()
            .contains("not yet implemented")
    );
    assert_eq!(t.line, Some(2), "the learner's line");
    assert_eq!(r.stdout, "hi\n");
}

#[test]
fn a_failed_check_reports_expression_expected_and_got() {
    let r = run(ADD, &[code("one", "check_eq!(add(-1, 1), 5);")]);
    let t = &r.tests[0];
    assert_eq!(t.status, Status::Fail);
    assert_eq!(t.expr.as_deref(), Some("add(-1, 1)"));
    assert_eq!(t.expected.as_deref(), Some("5"));
    assert_eq!(t.actual.as_deref(), Some("0"));
    let r = run(ADD, &[code("c", "check!(add(1, 1) == 3);")]);
    let t = &r.tests[0];
    assert_eq!(t.expr.as_deref(), Some("add(1, 1) == 3"));
    assert_eq!(
        (t.expected.as_deref(), t.actual.as_deref()),
        (Some("true"), Some("false"))
    );
    let r = run(
        ADD,
        &[code("n", "check_near!(add(1, 1) as f64, 2.5, 0.1);")],
    );
    assert!(
        r.tests[0]
            .expected
            .as_deref()
            .unwrap()
            .contains("within 0.1")
    );
}

#[test]
fn what_a_test_prints_is_kept_with_its_result() {
    let r = run(
        ADD,
        &[code(
            "p",
            "print!(\"no newline\"); check_eq!(add(1, 1), 3);",
        )],
    );
    assert_eq!(r.tests[0].status, Status::Fail);
    assert_eq!(r.tests[0].output.as_deref(), Some("no newline"));
    assert_eq!(r.stdout, "3\n", "tests' prints are not main's output");
}

#[test]
fn panics_matches_a_substring_and_reports_a_mismatch() {
    let src = "fn halve(n: i32) -> i32 {\n    if n < 0 { panic!(\"negative input\"); }\n    n / 2\n}\nfn main() {}\n";
    let r = run(
        src,
        &[
            panics("match", "halve(-1);", "negative"),
            panics("any", "halve(-1);", ""),
            panics("wrong", "halve(-1);", "overflow"),
            panics("none", "halve(4);", "negative"),
            // A std panic whose message doesn't match.
            panics("div", "let z = halve(0); let _ = 1 / z;", "negative"),
        ],
    );
    assert_eq!(
        statuses(&r),
        [
            Status::Pass,
            Status::Pass,
            Status::Panic,
            Status::Nopanic,
            Status::Panic
        ]
    );
    assert_eq!(r.tests[2].message.as_deref(), Some("negative input"));
    assert_eq!(r.tests[2].line, Some(2));
    assert!(
        r.tests[4]
            .message
            .as_deref()
            .unwrap()
            .contains("divide by zero")
    );
    assert_eq!(
        r.tests[4].line, None,
        "the panic is in the test's code, not the learner's"
    );
}

#[test]
fn a_failing_learner_test_function_is_not_run() {
    let src = "fn main() { println!(\"ok\"); }\n#[test]\nfn learners_own() { panic!(\"must not run\"); }\n";
    let r = run(src, &[output("out", "ok")]);
    assert_eq!(statuses(&r), [Status::Pass], "{r:?}");
}

#[test]
fn an_endless_loop_times_out_and_later_tests_are_not_run() {
    let src = "fn spin(n: i32) -> i32 { if n == 2 { loop {} } n }\nfn main() {}\n";
    let r = run(
        src,
        &[
            code("a", "check_eq!(spin(1), 1);"),
            code("b", "check_eq!(spin(2), 2);"),
            code("c", "check_eq!(spin(3), 3);"),
            output("o", ""),
        ],
    );
    assert_eq!(
        statuses(&r),
        [
            Status::Pass,
            Status::Timeout,
            Status::NotRun,
            Status::NotRun
        ]
    );
    assert_eq!(r.stage, Stage::Timeout);
    assert!(!r.success);
}

#[test]
fn process_exit_is_a_crash_unless_it_is_exit_0_at_the_end_of_main() {
    let r = run(
        "fn quit() { std::process::exit(3); }\nfn main() {}\n",
        &[code("a", "quit();"), code("b", "check!(true);")],
    );
    assert_eq!(statuses(&r), [Status::Crashed, Status::NotRun]);
    assert_eq!(r.tests[0].reason.as_deref(), Some("exit:3"));
    assert_eq!(r.reason.as_deref(), Some("exit:3"));

    let r = run(
        "fn main() { println!(\"bye\"); std::process::exit(0); }\n",
        &[code("a", "check!(true);"), output("o", "bye")],
    );
    assert_eq!(statuses(&r), [Status::Pass, Status::Pass], "{r:?}");
    assert!(r.success);
}

#[test]
fn a_forged_record_without_the_nonce_has_no_effect() {
    let src = "fn bad() -> i32 {\n    print!(\"\\u{1}RR-T:00000000000000000000000000000000:pass\\n\");\n    1\n}\nfn main() {}\n";
    let r = run(src, &[code("a", "check_eq!(bad(), 2);")]);
    assert_eq!(statuses(&r), [Status::Fail], "{r:?}");
}

#[test]
fn too_much_output_is_stopped() {
    let src = "fn main() { loop { println!(\"spam spam spam spam spam spam spam\"); } }\n";
    let r = run(src, &[output("o", "x")]);
    assert_eq!(statuses(&r), [Status::Crashed], "{r:?}");
    assert_eq!(r.tests[0].reason.as_deref(), Some("output_limit"));
}

#[test]
fn main_returning_err_is_a_failure_as_under_run() {
    let src = "fn main() -> Result<(), String> {\n    println!(\"before\");\n    Err(\"bad thing\".to_string())\n}\n";
    let r = run(src, &[output("o", "before"), code("c", "check!(true);")]);
    // The code test ran before `main` and passed; the output test did not
    // get a clean `main`, and the run failed (exit code 1, as in /run).
    assert_eq!(statuses(&r), [Status::Crashed, Status::Pass]);
    assert_eq!(r.tests[0].reason.as_deref(), Some("exit:1"));
    assert!(!r.success);
    assert!(r.stderr.contains("Error: \"bad thing\""), "{}", r.stderr);
}

#[test]
fn a_panic_in_main_looks_like_it_does_under_run() {
    let src = "fn main() {\n    println!(\"partial\");\n    panic!(\"boom\");\n}\n";
    let r = run(src, &[output("o", "partial"), code("c", "check!(true);")]);
    assert_eq!(statuses(&r), [Status::Panic, Status::Pass]);
    assert_eq!(r.tests[0].message.as_deref(), Some("boom"));
    assert_eq!(r.tests[0].line, Some(3));
    assert_eq!(r.stdout, "partial\n");
    assert!(!r.success);
    let panic_line = r.stderr.lines().find(|l| l.contains("panicked")).unwrap();
    assert!(
        panic_line.starts_with("thread 'main' panicked at ") && panic_line.contains("main.rs:3:5"),
        "{panic_line}"
    );
}

#[test]
fn a_deep_recursion_has_the_main_threads_stack() {
    let src = "fn depth(n: u64, pad: [u8; 256]) -> u64 { if n == 0 { pad[0] as u64 } else { 1 + depth(n - 1, std::hint::black_box(pad)) } }\nfn main() { println!(\"{}\", depth(20_000, [0; 256])); }\n";
    let r = run(
        src,
        &[
            code("deep", "check_eq!(depth(20_000, [0; 256]), 20_000);"),
            output("o", "20000"),
        ],
    );
    assert_eq!(statuses(&r), [Status::Pass, Status::Pass], "{r:?}");
}

#[test]
fn learner_names_that_shadow_the_prelude_do_not_break_the_harness() {
    let src = r#"
#![allow(dead_code)]
enum Option { A, B }
struct String(i32);
struct Vec;
struct Box;
type Result<T> = std::result::Result<T, i32>;
fn Ok() {}
fn Err() {}
fn Some() {}
fn None() {}
fn double(n: i32) -> i32 { n * 2 }
fn main() { println!("{}", double(2)); }
"#;
    let r = run(
        src,
        &[code("a", "check_eq!(double(2), 4);"), output("o", "4")],
    );
    assert_eq!(statuses(&r), [Status::Pass, Status::Pass], "{r:?}");
}

#[test]
fn a_learner_forbid_does_not_clash_with_generated_code() {
    let src = "#![forbid(unused_variables)]\nfn id(n: i32) -> i32 { n }\nfn main() { println!(\"{}\", id(1)); }\n";
    let r = run(src, &[code("a", "check_eq!(id(1), 1);")]);
    assert_eq!(statuses(&r), [Status::Pass], "{r:?}");
    assert_eq!(r.warnings, "");
}

#[test]
fn deny_warnings_passes_because_generated_code_is_warning_free() {
    let src =
        "#![deny(warnings)]\nfn id(n: i32) -> i32 { n }\nfn main() { println!(\"{}\", id(1)); }\n";
    // One code test, one output test, a panics test, and output_of: every
    // optional piece of the harness at once.
    let r = run(
        src,
        &[
            code("a", "check_eq!(id(1), 1);"),
            output("o", "1"),
            panics(
                "p",
                "let r: Result<i32, i32> = Err(1); r.unwrap();",
                "called",
            ),
            code("cap", "check_eq!(output_of(|| main()), \"1\\n\");"),
        ],
    );
    assert_eq!(statuses(&r), [Status::Pass; 4], "{r:?}");
    assert_eq!(r.stage, Stage::Run);
}

#[test]
fn forbid_unsafe_code_with_output_of_is_a_test_error_the_documented_residual() {
    let src = "#![forbid(unsafe_code)]\nfn id(n: i32) -> i32 { n }\nfn main() {}\n";
    let r = run(
        src,
        &[code("cap", "check_eq!(output_of(|| { id(1); }), \"\");")],
    );
    // The generated unsafe code is refused, and it lies outside every test
    // body, so the harness reports it as such.
    assert_eq!(r.stage, Stage::Compile);
    assert_eq!(r.compile_errors_in, Some(ErrorsIn::Tests));
    // Without output_of the same learner code is fine.
    let r = run(src, &[code("a", "check_eq!(id(1), 1);")]);
    assert_eq!(statuses(&r), [Status::Pass], "{r:?}");
}

#[test]
fn output_of_captures_what_a_function_prints_even_when_it_panics() {
    let src =
        "fn greet(name: &str) { println!(\"Hello, {name}!\"); }\nfn main() { greet(\"Ann\"); }\n";
    let r = run(
        src,
        &[
            code(
                "a",
                "check_eq!(output_of(|| greet(\"Bo\")), \"Hello, Bo!\\n\");",
            ),
            code(
                "b",
                "let text = output_of(|| greet(\"Cy\")); check!(text.contains(\"Cy\"));",
            ),
            panics(
                "c",
                "output_of(|| { greet(\"Di\"); panic!(\"after\"); });",
                "after",
            ),
            code("d", "check_eq!(1, 1);"),
        ],
    );
    assert_eq!(statuses(&r), [Status::Pass; 4], "{r:?}");
    assert_eq!(r.stdout, "Hello, Ann!\n");
}

#[test]
fn a_panic_in_a_thread_the_learner_spawns_goes_to_stderr() {
    let src = "fn spawn_panic() {\n    let _ = std::thread::spawn(|| panic!(\"in thread\")).join();\n}\nfn main() {}\n";
    let r = run(src, &[code("a", "spawn_panic();")]);
    assert_eq!(statuses(&r), [Status::Pass], "{r:?}");
    assert!(r.stderr.contains("in thread"), "{}", r.stderr);
}

#[test]
fn compile_error_in_the_learners_code_is_theirs_with_the_compilers_own_text() {
    for (name, src) in [
        (
            "missing brace",
            "fn add(a: i32, b: i32) -> i32 {\n    a + b\n\nfn main() {}\n",
        ),
        (
            "type error",
            "fn add(a: i32, b: i32) -> i32 { \"x\" }\nfn main() {}\n",
        ),
        (
            "borrow error",
            "fn add(a: i32, b: i32) -> i32 { let s = String::new(); let t = s; let _u = s; a + b }\nfn main() {}\n",
        ),
        (
            "arithmetic overflow",
            "fn add(a: i32, b: i32) -> i32 { let x: u8 = 255 + 1; a + b + x as i32 }\nfn main() {}\n",
        ),
        (
            "unconditional panic",
            "fn add(a: i32, b: i32) -> i32 { a + b + [1, 2, 3][5] }\nfn main() {}\n",
        ),
        ("no main", "fn add(a: i32, b: i32) -> i32 { a + b }\n"),
    ] {
        let r = run(src, &[code("one", "check_eq!(add(1, 1), 2);")]);
        assert_eq!(r.stage, Stage::Compile, "{name}");
        assert_eq!(r.compile_errors_in, Some(ErrorsIn::Code), "{name}: {r:?}");
        assert_eq!(statuses(&r), [Status::NotRun], "{name}");
        assert!(r.stderr.contains("error"), "{name}: {}", r.stderr);
        assert!(r.stderr.contains("main.rs"), "{name}: {}", r.stderr);
        assert_eq!(r.reason, None, "{name}");
    }
}

#[test]
fn a_learners_own_cfg_test_error_is_theirs_too() {
    let src = "fn add(a: i32, b: i32) -> i32 { a + b }\nfn main() {}\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() { let x: i32 = \"a\"; }\n}\n";
    let r = run(src, &[code("one", "check_eq!(add(1, 1), 2);")]);
    assert_eq!(r.stage, Stage::Compile);
    assert_eq!(r.compile_errors_in, Some(ErrorsIn::Code), "{r:?}");
    assert!(r.stderr.contains("mismatched types"), "{}", r.stderr);
    assert_eq!(r.reason, None, "never a harness reason");
}

#[test]
fn a_renamed_function_means_the_tests_cannot_use_the_code() {
    let src = "fn plus(a: i32, b: i32) -> i32 { a + b }\nfn main() {}\n";
    let r = run(
        src,
        &[
            code("one", "check_eq!(add(1, 1), 2);"),
            code("two", "check!(true);"),
            output("o", ""),
        ],
    );
    assert_eq!(r.stage, Stage::Compile);
    assert_eq!(r.compile_errors_in, Some(ErrorsIn::Tests), "{r:?}");
    assert_eq!(
        statuses(&r),
        [Status::Error, Status::NotRun, Status::NotRun]
    );
    assert_eq!(r.tests[0].reason.as_deref(), Some("tests_dont_fit"));
    assert!(
        r.tests[0]
            .message
            .as_deref()
            .unwrap()
            .contains("cannot find function")
    );
    assert_eq!(r.stderr, "");
}

#[test]
fn a_type_without_debug_is_found_in_the_test_that_checks_it() {
    let src = "struct P(i32);\nimpl PartialEq for P { fn eq(&self, o: &P) -> bool { self.0 == o.0 } }\nfn p(n: i32) -> P { P(n) }\nfn main() {}\n";
    let r = run(
        src,
        &[
            code("ok", "check!(p(1) == p(1));"),
            code("needs-debug", "check_eq!(p(1), p(1));"),
        ],
    );
    assert_eq!(r.compile_errors_in, Some(ErrorsIn::Tests), "{r:?}");
    assert_eq!(statuses(&r), [Status::NotRun, Status::Error]);
    assert!(
        r.tests[1].message.as_deref().unwrap().contains("Debug"),
        "{:?}",
        r.tests[1]
    );
}

#[test]
fn warnings_in_the_learners_lines_are_kept_and_the_harness_adds_none() {
    let src = "fn id(n: i32) -> i32 {\n    let unused = 1;\n    n\n}\nfn main() { println!(\"{}\", id(1)); }\n";
    let r = run(src, &[code("a", "check_eq!(id(1), 1);")]);
    assert_eq!(statuses(&r), [Status::Pass]);
    assert!(r.warnings.contains("unused variable"), "{}", r.warnings);
    assert!(!r.warnings.contains("__rr"), "{}", r.warnings);
    // A test body that warns is not shown to the learner.
    let r = run(
        ADD,
        &[code(
            "w",
            "let unused_in_test = 1; check_eq!(add(1, 1), 2);",
        )],
    );
    assert_eq!(r.warnings, "");
}

#[test]
fn bad_requests_are_refused_before_anything_runs() {
    let opts = Options::default();
    assert!(grade(ADD, &[], &opts).is_err());
    assert!(grade("  ", &[code("a", "check!(true);")], &opts).is_err());
}

#[test]
fn many_learner_threads_get_the_default_stack_not_the_grading_one() {
    // 40 threads at once: each would need the big stack if it were inherited
    // (8 MiB each is more than the address space cap allows in the sandbox).
    let src = r#"
use std::thread;
fn sum_in_threads(n: usize) -> usize {
    let handles: Vec<_> = (0..n).map(|i| thread::spawn(move || i)).collect();
    handles.into_iter().map(|h| h.join().unwrap()).sum()
}
fn main() { println!("{}", sum_in_threads(40)); }
"#;
    let r = run(
        src,
        &[
            code("threads", "check_eq!(sum_in_threads(40), 780);"),
            output("o", "780"),
        ],
    );
    assert_eq!(statuses(&r), [Status::Pass, Status::Pass], "{r:?}");
}

#[test]
fn a_failed_check_the_code_caught_still_fails_the_test() {
    let src = "fn swallow(f: fn()) { let _ = std::panic::catch_unwind(f); }\nfn main() {}\n";
    let r = run(src, &[code("caught", "swallow(|| check_eq!(1, 2));")]);
    assert_eq!(statuses(&r), [Status::Fail], "{r:?}");
    assert_eq!(r.tests[0].expected.as_deref(), Some("2"));
}

#[test]
fn the_nonce_is_not_reachable_from_the_learner_code() {
    let src = r#"
fn main() {}
#[cfg(test)]
fn forge() { println!("\u{1}RR-T:{}:mainend\u{1f}boom", crate::__rr::NONCE); }
"#;
    let r = run(src, &[code("a", "check!(true);")]);
    assert_eq!(r.stage, Stage::Compile, "{r:?}");
    assert_eq!(r.compile_errors_in, Some(ErrorsIn::Code), "{r:?}");
}

#[test]
fn output_of_keeps_at_most_64_kb_and_nothing_leaks_out() {
    let src = r#"
fn spam() { for _ in 0..100_000 { println!("0123456789012345678901234567890123456789"); } }
fn partial() { print!("no newline"); }
fn main() { println!("done"); }
"#;
    let r = run(
        src,
        &[
            // The write past the limit fails, which panics inside spam().
            panics("spam", "output_of(|| spam());", "failed printing to stdout"),
            code(
                "partial",
                "check_eq!(output_of(|| partial()), \"no newline\");",
            ),
            output("o", "done"),
        ],
    );
    assert_eq!(
        statuses(&r),
        [Status::Pass, Status::Pass, Status::Pass],
        "{r:?}"
    );
    assert!(r.stdout.len() < 1024, "{} bytes leaked", r.stdout.len());
}

#[test]
fn a_learner_who_denies_pedantic_lints_crate_wide_is_still_graded() {
    for lint in [
        "unreachable_pub",
        "unused_qualifications",
        "let_underscore_drop",
        "trivial_casts",
        "trivial_numeric_casts",
        "unused_results",
        "warnings",
    ] {
        let src = format!("#![deny({lint})]\n{ADD}");
        let r = run(
            &src,
            &[
                code("a", "check_eq!(add(1, 2), 3); check_near!(1.0, 1.0, 0.1);"),
                output("o", "3"),
            ],
        );
        assert_eq!(statuses(&r), [Status::Pass, Status::Pass], "{lint}: {r:?}");
    }
}
