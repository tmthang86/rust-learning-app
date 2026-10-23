//! Whose fault is a compile failure: the learner's code or the tests?
//!
//! The combined file (learner code + harness) is compiled once. When that
//! fails, the job script also compiles the learner's code alone (`--emit=mir`,
//! same flags as `/run`) and the two outcomes decide, in order:
//!
//! | # | Condition | `compileErrorsIn` | Tests |
//! |---|---|---|---|
//! | 1 | the learner-only check fails | `code` | all `not_run`; the check's human output, verbatim |
//! | 2 | the check passes, but an error's site is a learner line | `code` | all `not_run`; those diagnostics' rendered text |
//! | 3 | every error's site lies inside test code | `tests` | tests holding a site: `error` (`tests_dont_fit`); others `not_run` |
//! | 4 | an error's site is generated code outside every test | `tests` | all `not_run`; reason `no_main` or `harness` |
//!
//! A diagnostic's *site* is its primary span after following macro
//! expansions back to the outermost call site. Diagnostics without a span
//! ("aborting due to N previous errors") are ignored. If the check itself
//! timed out or was killed, rules 2-4 apply on the combined diagnostics.

use serde::Serialize;

use crate::diag::{self, Diag};
use crate::generate::Generated;
use crate::{Status, TestResult, truncate_marked};

/// Which part of the compiled file holds the compile errors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ErrorsIn {
    Code,
    Tests,
}

/// The learner-only check (human output) the job script ran after the
/// combined compile failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckResult {
    /// The check compiled the learner's code without errors.
    pub passed: bool,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CompileVerdict {
    pub errors_in: ErrorsIn,
    /// Shown as the compile output (empty for `tests`).
    pub stderr: String,
    /// One result per requested test, in request order.
    pub tests: Vec<TestResult>,
    /// A machine code (`no_main`, `harness`) for rule 4.
    pub reason: Option<String>,
}

fn all_not_run(g: &Generated) -> Vec<TestResult> {
    g.ids
        .iter()
        .map(|id| TestResult::new(id, Status::NotRun))
        .collect()
}

/// Classifies a failed combined compile. `combined_json` is its stderr
/// (JSON diagnostics); `check` is the learner-only check, when it ran to an
/// end.
pub fn classify_compile(
    g: &Generated,
    combined_json: &str,
    check: Option<&CheckResult>,
) -> CompileVerdict {
    // Rule 1.
    if let Some(check) = check
        && !check.passed
    {
        return CompileVerdict {
            errors_in: ErrorsIn::Code,
            stderr: check.text.trim().to_string(),
            tests: all_not_run(g),
            reason: None,
        };
    }

    let diags = diag::parse(combined_json);
    let errors: Vec<&Diag> = diags
        .iter()
        .filter(|d| d.is_error() && d.line.is_some())
        .collect();

    // Rule 2.
    let in_code: Vec<&Diag> = errors
        .iter()
        .copied()
        .filter(|d| d.line.is_some_and(|l| g.is_learner_line(l)))
        .collect();
    if !in_code.is_empty() {
        let stderr = in_code
            .iter()
            .map(|d| d.rendered.as_deref().unwrap_or(&d.message).trim())
            .collect::<Vec<_>>()
            .join("\n\n");
        return CompileVerdict {
            errors_in: ErrorsIn::Code,
            stderr,
            tests: all_not_run(g),
            reason: None,
        };
    }

    // Rule 4: no located error at all counts as a harness problem.
    let outside = errors
        .iter()
        .find(|d| d.line.is_none_or(|l| g.test_at(l).is_none()));
    if errors.is_empty() || outside.is_some() {
        let reason = match outside {
            Some(d) if d.line == Some(g.main_call_line) => "no_main",
            _ => "harness",
        };
        return CompileVerdict {
            errors_in: ErrorsIn::Tests,
            stderr: String::new(),
            tests: all_not_run(g),
            reason: Some(reason.to_string()),
        };
    }

    // Rule 3.
    let mut tests = all_not_run(g);
    for d in &errors {
        let Some(index) = d.line.and_then(|l| g.test_at(l)) else {
            continue;
        };
        if tests[index].status == Status::Error {
            continue; // the first error of a test is the one reported
        }
        let mut t = TestResult::new(&g.ids[index], Status::Error).with_reason("tests_dont_fit");
        t.message = Some(truncate_marked(
            d.message.lines().next().unwrap_or(""),
            1024,
        ));
        tests[index] = t;
    }
    CompileVerdict {
        errors_in: ErrorsIn::Tests,
        stderr: String::new(),
        tests,
        reason: None,
    }
}

/// Compiler warnings after a successful compile: only those whose site is a
/// learner line, as the compiler rendered them.
pub fn learner_warnings(g: &Generated, combined_json: &str) -> String {
    diag::parse(combined_json)
        .iter()
        .filter(|d| d.level == "warning" && d.line.is_some_and(|l| g.is_learner_line(l)))
        .map(|d| {
            d.rendered
                .as_deref()
                .unwrap_or(&d.message)
                .trim()
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TestSpec;
    use crate::generate::build;

    const LEARNER: &str = "fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn main() {\n    println!(\"{}\", add(1, 2));\n}\n";

    fn gen_() -> Generated {
        let tests = [
            TestSpec {
                id: "one".into(),
                code: Some("check_eq!(add(1, 1), 2);".into()),
                ..TestSpec::default()
            },
            TestSpec {
                id: "out".into(),
                output: Some("3".into()),
                ..TestSpec::default()
            },
            TestSpec {
                id: "two".into(),
                code: Some("check_eq!(add(2, 2), 4);".into()),
                ..TestSpec::default()
            },
        ];
        build(LEARNER, &tests, "N0")
    }

    /// A one-line diagnostic with a primary span at `line` (and, when
    /// `call_site` is set, the macro expansion's call site).
    fn diag_json(level: &str, message: &str, line: Option<u32>, call_site: Option<u32>) -> String {
        let spans = match (line, call_site) {
            (Some(l), Some(c)) => format!(
                r#"[{{"file_name":"/tmp/main.rs","line_start":{l},"is_primary":true,"expansion":{{"span":{{"file_name":"/tmp/main.rs","line_start":{c},"is_primary":false,"expansion":null}},"macro_decl_name":"check_eq!"}}}}]"#
            ),
            (Some(l), None) => format!(
                r#"[{{"file_name":"/tmp/main.rs","line_start":{l},"is_primary":true,"expansion":null}}]"#
            ),
            _ => "[]".to_string(),
        };
        format!(
            r#"{{"$message_type":"diagnostic","message":"{message}","level":"{level}","spans":{spans},"rendered":"{level}: {message}\n --> /tmp/main.rs\n"}}"#
        )
    }

    fn aborting() -> String {
        diag_json("error", "aborting due to 1 previous error", None, None)
    }

    fn failed_check(text: &str) -> CheckResult {
        CheckResult {
            passed: false,
            text: text.into(),
        }
    }

    fn passed_check() -> CheckResult {
        CheckResult {
            passed: true,
            text: String::new(),
        }
    }

    #[test]
    fn rule_1_a_failed_learner_check_wins_and_is_verbatim() {
        let g = gen_();
        // The combined diagnostics point at the harness (a missing brace in
        // the learner's code would), but the check's text is what counts.
        let combined = format!(
            "{}\n{}",
            diag_json(
                "error",
                "this file contains an unclosed delimiter",
                Some(g.main_call_line),
                None
            ),
            aborting()
        );
        let v = classify_compile(
            &g,
            &combined,
            Some(&failed_check("error: mismatched types\n")),
        );
        assert_eq!(v.errors_in, ErrorsIn::Code);
        assert_eq!(v.stderr, "error: mismatched types");
        assert!(v.tests.iter().all(|t| t.status == Status::NotRun));
        assert_eq!(v.tests.len(), 3);
        assert_eq!(v.reason, None);
    }

    #[test]
    fn rule_2_an_error_on_a_learner_line_with_a_passing_check() {
        let g = gen_();
        // e.g. the learner's own #[cfg(test)] module with a type error.
        let combined = format!(
            "{}\n{}",
            diag_json("error", "mismatched types", Some(3), None),
            aborting()
        );
        let v = classify_compile(&g, &combined, Some(&passed_check()));
        assert_eq!(v.errors_in, ErrorsIn::Code);
        assert!(v.stderr.contains("mismatched types"), "{}", v.stderr);
        assert!(
            !v.stderr.contains("aborting"),
            "span-less diagnostics are ignored"
        );
        assert_eq!(v.reason, None, "never a harness reason");
        // Without a check result (it timed out) rule 2 still applies.
        assert_eq!(
            classify_compile(&g, &combined, None).errors_in,
            ErrorsIn::Code
        );
    }

    #[test]
    fn rule_3_a_macro_error_in_a_test_is_found_through_the_expansion() {
        let g = gen_();
        let two = g.ranges[1];
        let combined = format!(
            "{}\n{}",
            // Primary span on the macro definition (a generated line outside
            // any test), the call site inside test "two".
            diag_json(
                "error",
                "`Foo` doesn't implement `Debug`",
                Some(g.ranges[0].start - 6),
                Some(two.start + 1)
            ),
            aborting()
        );
        let v = classify_compile(&g, &combined, Some(&passed_check()));
        assert_eq!(v.errors_in, ErrorsIn::Tests);
        assert_eq!(v.reason, None);
        assert_eq!(v.tests[0].status, Status::NotRun);
        assert_eq!(v.tests[1].status, Status::NotRun, "output test");
        let t = &v.tests[2];
        assert_eq!(t.status, Status::Error);
        assert_eq!(t.reason.as_deref(), Some("tests_dont_fit"));
        assert_eq!(
            t.message.as_deref(),
            Some("`Foo` doesn't implement `Debug`")
        );
        assert_eq!(v.stderr, "");
    }

    #[test]
    fn rule_3_a_renamed_function_breaks_every_test_that_calls_it() {
        let g = gen_();
        let combined = [
            diag_json(
                "error",
                "cannot find function `add` in this scope",
                Some(g.ranges[0].start + 1),
                None,
            ),
            diag_json(
                "error",
                "cannot find function `add` in this scope",
                Some(g.ranges[1].start + 1),
                None,
            ),
            aborting(),
        ]
        .join("\n");
        let v = classify_compile(&g, &combined, Some(&passed_check()));
        assert_eq!(v.errors_in, ErrorsIn::Tests);
        assert_eq!(v.tests[0].status, Status::Error);
        assert_eq!(v.tests[2].status, Status::Error);
        assert_eq!(v.tests[1].status, Status::NotRun);
    }

    #[test]
    fn rule_4_generated_lines_outside_tests_are_a_harness_problem() {
        let g = gen_();
        let combined = format!(
            "{}\n{}",
            diag_json("error", "oops", Some(g.learner_lines + 5), None),
            aborting()
        );
        let v = classify_compile(&g, &combined, Some(&passed_check()));
        assert_eq!(v.errors_in, ErrorsIn::Tests);
        assert_eq!(v.reason.as_deref(), Some("harness"));
        assert!(v.tests.iter().all(|t| t.status == Status::NotRun));

        // The call to the learner's main().
        let combined = diag_json(
            "error",
            "cannot find function `main`",
            Some(g.main_call_line),
            None,
        );
        let v = classify_compile(&g, &combined, Some(&passed_check()));
        assert_eq!(v.reason.as_deref(), Some("no_main"));
    }

    #[test]
    fn rule_4_also_covers_a_failure_without_any_located_error() {
        let g = gen_();
        let v = classify_compile(&g, &aborting(), Some(&passed_check()));
        assert_eq!(v.errors_in, ErrorsIn::Tests);
        assert_eq!(v.reason.as_deref(), Some("harness"));
        let v = classify_compile(&g, "error: linking with `cc` failed\n", None);
        assert_eq!(v.reason.as_deref(), Some("harness"));
    }

    #[test]
    fn a_test_error_next_to_a_harness_error_is_still_a_harness_problem() {
        let g = gen_();
        let combined = [
            diag_json("error", "in a test", Some(g.ranges[0].start + 1), None),
            diag_json("error", "in the harness", Some(g.learner_lines + 5), None),
        ]
        .join("\n");
        let v = classify_compile(&g, &combined, Some(&passed_check()));
        assert_eq!(v.reason.as_deref(), Some("harness"));
    }

    #[test]
    fn warnings_are_filtered_to_learner_lines() {
        let g = gen_();
        let json = [
            diag_json("warning", "unused variable: `x`", Some(2), None),
            diag_json(
                "warning",
                "unused import",
                Some(g.ranges[0].start + 1),
                None,
            ),
            diag_json("warning", "1 warning emitted", None, None),
            diag_json("error", "not a warning", Some(2), None),
        ]
        .join("\n");
        let w = learner_warnings(&g, &json);
        assert!(w.contains("unused variable"), "{w}");
        assert!(
            !w.contains("unused import") && !w.contains("emitted") && !w.contains("not a warning"),
            "{w}"
        );
        assert_eq!(learner_warnings(&g, ""), "");
    }
}
