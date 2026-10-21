//! The source that gets compiled: the learner's code, unchanged, then a
//! generated harness.
//!
//! ```text
//! <learner code, N lines>
//! <blank line>
//! mod __rr { ...machinery: records, panic hook, case runner... }
//! #[cfg(test)]
//! mod __rr_tests {
//!     use super::*;            // test bodies see the learner's names
//!     macro_rules! check_eq ...
//!     fn __rr_t0() { <test code> }
//!     #[test] fn __rr_grade() { ...runs every test, then main... }
//! }
//! ```
//!
//! The generated code has no lint attributes, so a learner's
//! `#![forbid(...)]` can't clash with it, and it is warning-free by
//! construction: every helper is referenced from `__rr_grade`, and the
//! self-check test uses every macro.

use crate::TestSpec;

const CORE: &str = include_str!("prelude/core.rs.txt");
const OUTPUT_OF: &str = include_str!("prelude/output_of.rs.txt");
const MACROS: &str = include_str!("prelude/macros.rs.txt");

/// The libtest arguments that run the generated test and nothing else
/// (`--exact` skips any `#[test]` the learner wrote).
pub const RUN_ARGS: [&str; 7] = [
    "--exact",
    "__rr_tests::__rr_grade",
    "--no-capture",
    "--test-threads=1",
    "-q",
    "--color",
    "never",
];

/// `RUST_MIN_STACK` for the graded program: the main thread's 8 MiB, so a
/// deep recursion that works in `/run` works inside a test too.
pub const MIN_STACK: &str = "8388608";

/// What a requested test is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TestPlan {
    /// A code test, with the optional `panics` text.
    Code { panics: Option<String> },
    /// An output test with its expected stdout.
    Output { expected: String },
}

/// The lines of one code test in the generated file (1-based, inclusive):
/// its `fn` line through its closing brace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TestRange {
    /// Index into [`Generated::ids`].
    pub test: usize,
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone)]
pub struct Generated {
    /// The whole file to compile.
    pub source: String,
    /// The first bytes of `source` that are the learner's code, exactly.
    pub learner_bytes: usize,
    /// Lines `1..=learner_lines` are the learner's.
    pub learner_lines: u32,
    /// Requested test ids, in request order.
    pub ids: Vec<String>,
    pub plans: Vec<TestPlan>,
    pub ranges: Vec<TestRange>,
    /// The line that calls the learner's `main`.
    pub main_call_line: u32,
    /// The per-job secret every result record carries.
    pub nonce: String,
}

impl Generated {
    pub fn is_learner_line(&self, line: u32) -> bool {
        line >= 1 && line <= self.learner_lines
    }

    /// The index of the code test whose lines hold `line`.
    pub fn test_at(&self, line: u32) -> Option<usize> {
        self.ranges
            .iter()
            .find(|r| r.start <= line && line <= r.end)
            .map(|r| r.test)
    }
}

struct Out {
    text: String,
    line: u32,
}

impl Out {
    /// Appends `s` (which may span lines) and returns the line it starts on.
    fn push(&mut self, s: &str) -> u32 {
        let start = self.line;
        self.text.push_str(s);
        self.line += s.matches('\n').count() as u32;
        start
    }
}

/// Builds the file for `code` and `tests` (already validated). `nonce` is
/// fresh for each job.
pub fn build(code: &str, tests: &[TestSpec], nonce: &str) -> Generated {
    let learner_lines = code.lines().count() as u32;
    let mut out = Out {
        text: String::with_capacity(code.len() + 8192),
        line: 1,
    };
    out.push(code);
    out.push("\n");
    let uses_output_of = tests
        .iter()
        .any(|t| t.code.as_deref().is_some_and(|c| c.contains("output_of")));

    out.push("\nmod __rr {\n");
    let core = CORE
        .replace("__NONCE__", nonce)
        .replace("__LEARNER_LINES__", &learner_lines.to_string());
    out.push(&core);
    if uses_output_of {
        out.push(OUTPUT_OF);
    }
    out.push("}\n");

    out.push("#[cfg(test)]\nmod __rr_tests {\n    use super::*;\n");
    if uses_output_of {
        out.push("    use crate::__rr::output_of;\n");
    }
    out.push(MACROS);
    out.push(
        "    fn __rr_t_self() {\n        check_eq!(1, 1);\n        check!(true);\n        check_near!(1.0, 1.0, 0.0);\n    }\n",
    );

    let mut ranges = Vec::new();
    for (i, t) in tests.iter().enumerate() {
        let Some(body) = &t.code else { continue };
        let start = out.push(&format!("    fn __rr_t{i}() {{\n"));
        out.push(body);
        out.push("\n");
        let end = out.push("    }\n");
        ranges.push(TestRange {
            test: i,
            start,
            end,
        });
    }

    out.push("    #[test]\n    fn __rr_grade() {\n        crate::__rr::start();\n");
    out.push(
        "        let _ = (\n            crate::__rr::start as fn(),\n            crate::__rr::fail as fn(&str, &str, &str) -> !,\n            crate::__rr::case as fn(&str, ::core::option::Option<&str>, fn()),\n            crate::__rr::main as fn(fn()),\n            crate::__rr::done as fn(),\n            crate::__rr::dbg::<i32> as fn(&i32) -> ::std::string::String,\n        );\n",
    );
    if uses_output_of {
        out.push("        let _ = output_of::<fn()> as fn(fn()) -> ::std::string::String;\n");
    }
    out.push("        crate::__rr::case(\"__self\", ::core::option::Option::None, __rr_t_self);\n");
    let mut plans = Vec::new();
    for (i, t) in tests.iter().enumerate() {
        match &t.code {
            Some(_) => {
                let panics = match &t.panics {
                    Some(p) => format!("::core::option::Option::Some({p:?})"),
                    None => "::core::option::Option::None".to_string(),
                };
                out.push(&format!(
                    "        crate::__rr::case({:?}, {panics}, __rr_t{i});\n",
                    t.id
                ));
                plans.push(TestPlan::Code {
                    panics: t.panics.clone(),
                });
            }
            None => plans.push(TestPlan::Output {
                expected: t.output.clone().unwrap_or_default(),
            }),
        }
    }
    let main_call_line = out.push(
        "        crate::__rr::main(|| { let _ = ::std::process::Termination::report(main()); });\n",
    );
    out.push("        crate::__rr::done();\n    }\n}\n");

    Generated {
        source: out.text,
        learner_bytes: code.len(),
        learner_lines,
        ids: tests.iter().map(|t| t.id.clone()).collect(),
        plans,
        ranges,
        main_call_line,
        nonce: nonce.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn code_test(id: &str, code: &str) -> TestSpec {
        TestSpec {
            id: id.into(),
            code: Some(code.into()),
            ..TestSpec::default()
        }
    }

    fn output_test(id: &str, out: &str) -> TestSpec {
        TestSpec {
            id: id.into(),
            output: Some(out.into()),
            ..TestSpec::default()
        }
    }

    const LEARNER: &str = "fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn main() {\n    println!(\"{}\", add(1, 2));\n}\n";

    #[test]
    fn learner_code_and_its_line_numbers_are_unchanged() {
        let g = build(LEARNER, &[code_test("t", "check_eq!(add(1, 1), 2);")], "N0");
        assert!(g.source.starts_with(LEARNER));
        assert_eq!(g.learner_bytes, LEARNER.len());
        assert_eq!(g.learner_lines, 7);
        // Code without a final newline works the same.
        let no_nl = LEARNER.trim_end();
        let g = build(no_nl, &[code_test("t", "check!(true);")], "N0");
        assert!(g.source.starts_with(no_nl));
        assert_eq!(&g.source[g.learner_bytes..g.learner_bytes + 1], "\n");
        assert_eq!(g.learner_lines, 7);
        assert!(g.is_learner_line(7) && !g.is_learner_line(8) && !g.is_learner_line(0));
    }

    #[test]
    fn ranges_and_main_call_line_point_at_the_right_lines() {
        let tests = [
            code_test("one", "check_eq!(add(1, 1), 2);"),
            output_test("out", "3"),
            code_test("two", "let x = 1;\ncheck!(x == 1);"),
        ];
        let g = build(LEARNER, &tests, "N0");
        let lines: Vec<&str> = g.source.lines().collect();
        assert_eq!(g.ranges.len(), 2, "output tests have no range");
        for r in &g.ranges {
            let first = lines[r.start as usize - 1];
            let last = lines[r.end as usize - 1];
            assert!(
                first.starts_with(&format!("    fn __rr_t{}()", r.test)),
                "{first}"
            );
            assert_eq!(last, "    }");
        }
        let one = g.ranges[0];
        assert_eq!(lines[one.start as usize], "check_eq!(add(1, 1), 2);");
        let two = g.ranges[1];
        assert_eq!(two.end - two.start, 3, "header, two lines, closing brace");
        assert_eq!(g.test_at(one.start + 1), Some(0));
        assert_eq!(g.test_at(two.start + 2), Some(2));
        assert_eq!(g.test_at(1), None);
        assert!(
            lines[g.main_call_line as usize - 1].contains("Termination::report(main())"),
            "{}",
            lines[g.main_call_line as usize - 1]
        );
        assert_eq!(g.ids, ["one", "out", "two"]);
        assert_eq!(g.plans.len(), 3);
    }

    #[test]
    fn every_helper_is_referenced_from_the_grading_test() {
        let g = build(LEARNER, &[code_test("t", "check!(true);")], "N0");
        let grade = &g.source[g.source.find("fn __rr_grade()").unwrap()..];
        for helper in ["start", "fail", "case", "main", "done", "dbg"] {
            assert!(
                grade.contains(&format!("crate::__rr::{helper}")),
                "{helper} is not referenced"
            );
        }
        // The self-check uses every macro, so none is unused.
        let slf = &g.source[g.source.find("fn __rr_t_self()").unwrap()..];
        for m in [
            "check_eq!(1, 1)",
            "check!(true)",
            "check_near!(1.0, 1.0, 0.0)",
        ] {
            assert!(slf.contains(m), "{m}");
        }
    }

    #[test]
    fn unsafe_capture_code_only_comes_with_output_of() {
        let plain = build(LEARNER, &[code_test("t", "check!(true);")], "N0");
        assert!(
            !plain.source.contains("unsafe"),
            "no unsafe without output_of"
        );
        let g = build(
            LEARNER,
            &[code_test("t", "check_eq!(output_of(|| main()), \"3\\n\");")],
            "N0",
        );
        assert!(g.source.contains("unsafe extern \"C\""));
        assert!(g.source.contains("use crate::__rr::output_of;"));
        // The generated part of the file (after the learner's code).
        let generated = &g.source[g.learner_bytes..];
        assert!(!generated.contains("#[allow") && !generated.contains("#![allow"));
    }

    #[test]
    fn nonce_and_learner_line_count_are_filled_in() {
        let g = build(LEARNER, &[code_test("t", "check!(true);")], "abc123");
        assert!(g.source.contains("pub const NONCE: &str = \"abc123\";"));
        assert!(g.source.contains("pub const LEARNER_LINES: u32 = 7;"));
        assert!(!g.source.contains("__NONCE__") && !g.source.contains("__LEARNER_LINES__"));
    }

    #[test]
    fn panics_text_is_a_valid_string_literal() {
        let t = TestSpec {
            id: "p".into(),
            code: Some("let _ = 1;".into()),
            panics: Some("say \"hi\"\n\\ done".into()),
            ..TestSpec::default()
        };
        let g = build(LEARNER, &[t], "N0");
        assert!(
            g.source.contains("Some(\"say \\\"hi\\\"\\n\\\\ done\")"),
            "{}",
            &g.source[g.source.find("__rr_grade").unwrap()..]
        );
    }
}
