//! Grading exercises with several tests.
//!
//! A pure crate: it builds the source that is compiled (the learner's code
//! plus a generated harness), turns the compiler's diagnostics and the
//! program's output into per-test results, and never runs anything itself,
//! except in [`local`], which drives the host's `rustc` for the lesson
//! checker. The runner (`/grade`) and `tool/check_lessons.py` (through the
//! `rr-grade` binary) share it, so a lesson is judged the same way in both.
//!
//! See `docs/exercise-tests-design.md`.

pub mod classify;
pub mod diag;
pub mod generate;
pub mod local;
pub mod normalize;
pub mod results;

use serde::{Deserialize, Serialize};

pub use classify::{CheckResult, CompileVerdict, ErrorsIn, classify_compile, learner_warnings};
pub use generate::{Generated, TestPlan, TestRange, build};
pub use normalize::normalize;
pub use results::{End, EndState, MainStatus, RunVerdict, results};

/// At most this many tests in one request.
pub const MAX_TESTS: usize = 50;
/// Largest `code` of one test, in bytes.
pub const MAX_TEST_CODE_BYTES: usize = 4 * 1024;
/// Largest expected `output` of one test, in bytes.
pub const MAX_TEST_OUTPUT_BYTES: usize = 8 * 1024;
/// Largest `panics` text, in bytes.
pub const MAX_PANICS_BYTES: usize = 200;
/// Largest total size of all test fields, in bytes.
pub const MAX_TESTS_BYTES: usize = 32 * 1024;

/// Every request to `/grade` and every run of `rr-grade` ends in exactly one
/// test result per requested test, with a status from this list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pass,
    Fail,
    Panic,
    Nopanic,
    Error,
    Timeout,
    Crashed,
    NotRun,
}

/// One test of a request. Labels and `hidden` are not sent to the server
/// (and are ignored if they are).
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct TestSpec {
    pub id: String,
    /// Rust statements: the body of a `fn()` (a code test).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Code tests only. `""` accepts any panic, otherwise the panic message
    /// must contain this text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub panics: Option<String>,
    /// The expected stdout of `main` (an output test).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
}

/// What became of one test.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TestResult {
    pub id: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expr: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actual: Option<String>,
    /// What the test printed (code tests), at most 2 KB.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// A panic message or a compiler diagnostic's one-line message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// The learner's source line of a panic.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// A machine code: `mem_limit`, `output_limit`, `stack_overflow`,
    /// `exit:<n>`, `tests_dont_fit`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl TestResult {
    pub fn new(id: &str, status: Status) -> Self {
        Self {
            id: id.to_string(),
            status,
            expr: None,
            expected: None,
            actual: None,
            output: None,
            message: None,
            line: None,
            reason: None,
        }
    }

    pub fn with_reason(mut self, reason: &str) -> Self {
        self.reason = Some(reason.to_string());
        self
    }
}

/// How far a graded job got (same meaning as the runner's `/run` stage).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    Compile,
    Run,
    Timeout,
}

/// The body of a `/grade` answer: the `/run` fields plus `tests`,
/// `compileErrorsIn` and `reason`. `rr-grade` prints the same JSON.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    pub success: bool,
    pub stage: Stage,
    pub duration_ms: u64,
    pub stdout: String,
    pub stderr: String,
    pub warnings: String,
    pub compile_errors_in: Option<ErrorsIn>,
    pub reason: Option<String>,
    pub tests: Vec<TestResult>,
}

/// Checks a request's tests. The error text names the problem but never
/// echoes test code.
pub fn validate(tests: &[TestSpec]) -> Result<(), String> {
    if tests.is_empty() || tests.len() > MAX_TESTS {
        return Err(format!("send between 1 and {MAX_TESTS} tests"));
    }
    let mut total = 0usize;
    let mut seen = std::collections::HashSet::new();
    for (i, t) in tests.iter().enumerate() {
        if !valid_id(&t.id) {
            return Err(format!(
                "test {i}: the id must match [a-z0-9][a-z0-9-]{{0,39}}"
            ));
        }
        if !seen.insert(t.id.as_str()) {
            return Err(format!("test {i}: the id is used twice"));
        }
        match (&t.code, &t.output) {
            (Some(_), None) | (None, Some(_)) => {}
            _ => return Err(format!("test {i}: send exactly one of code and output")),
        }
        if t.panics.is_some() && t.code.is_none() {
            return Err(format!("test {i}: panics needs code"));
        }
        let size = |s: &Option<String>| s.as_ref().map_or(0, String::len);
        if size(&t.code) > MAX_TEST_CODE_BYTES
            || size(&t.output) > MAX_TEST_OUTPUT_BYTES
            || size(&t.panics) > MAX_PANICS_BYTES
        {
            return Err(format!("test {i}: a field is too long"));
        }
        total += t.id.len() + size(&t.code) + size(&t.output) + size(&t.panics);
    }
    if total > MAX_TESTS_BYTES {
        return Err("the tests are too long together".into());
    }
    Ok(())
}

/// `^[a-z0-9][a-z0-9-]{0,39}$`
pub fn valid_id(id: &str) -> bool {
    let b = id.as_bytes();
    !b.is_empty()
        && b.len() <= 40
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

/// Cuts `s` to at most `max` bytes (on a character boundary) and marks the
/// cut.
pub fn truncate_marked(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut cut = max;
    while !s.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}...[truncated]", &s[..cut])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn code(id: &str) -> TestSpec {
        TestSpec {
            id: id.into(),
            code: Some("check!(true);".into()),
            ..TestSpec::default()
        }
    }

    #[test]
    fn id_rules() {
        for ok in ["a", "0", "a-b", "first-then-second", &"a".repeat(40)] {
            assert!(valid_id(ok), "{ok}");
        }
        for bad in ["", "-a", "A", "a_b", "a b", &"a".repeat(41), "é"] {
            assert!(!valid_id(bad), "{bad}");
        }
    }

    #[test]
    fn validation_rules() {
        assert!(validate(&[code("a"), code("b")]).is_ok());
        assert!(validate(&[]).is_err());
        assert!(validate(&[code("a"), code("a")]).is_err(), "duplicate id");
        let many: Vec<_> = (0..51).map(|i| code(&format!("t{i}"))).collect();
        assert!(validate(&many).is_err());
        let fifty: Vec<_> = (0..50).map(|i| code(&format!("t{i}"))).collect();
        assert!(validate(&fifty).is_ok());

        let neither = TestSpec {
            id: "n".into(),
            ..TestSpec::default()
        };
        assert!(validate(&[neither]).is_err());
        let both = TestSpec {
            id: "b".into(),
            code: Some("x".into()),
            output: Some("y".into()),
            ..TestSpec::default()
        };
        assert!(validate(&[both]).is_err());
        let panics_on_output = TestSpec {
            id: "p".into(),
            output: Some("y".into()),
            panics: Some("z".into()),
            ..TestSpec::default()
        };
        assert!(validate(&[panics_on_output]).is_err());

        let long_code = TestSpec {
            id: "l".into(),
            code: Some("x".repeat(MAX_TEST_CODE_BYTES + 1)),
            ..TestSpec::default()
        };
        assert!(validate(&[long_code]).is_err());
        let long_panics = TestSpec {
            id: "l".into(),
            code: Some("x".into()),
            panics: Some("x".repeat(MAX_PANICS_BYTES + 1)),
            ..TestSpec::default()
        };
        assert!(validate(&[long_panics]).is_err());
        // 9 x 4 KB = 36 KB of code in total is over the 32 KB cap.
        let big: Vec<_> = (0..9)
            .map(|i| TestSpec {
                id: format!("b{i}"),
                code: Some("x".repeat(MAX_TEST_CODE_BYTES)),
                ..TestSpec::default()
            })
            .collect();
        assert!(validate(&big).is_err());
    }

    #[test]
    fn validation_errors_do_not_echo_test_code() {
        let t = TestSpec {
            id: "SECRET_ID".into(),
            code: Some("SECRET_CODE".into()),
            ..TestSpec::default()
        };
        let msg = validate(&[t]).unwrap_err();
        assert!(!msg.contains("SECRET"), "{msg}");
    }

    #[test]
    fn truncation_is_marked_and_char_safe() {
        assert_eq!(truncate_marked("abc", 10), "abc");
        assert_eq!(truncate_marked("abcdef", 3), "abc...[truncated]");
        assert_eq!(truncate_marked("ééé", 3), "é...[truncated]");
    }
}
