//! Reading rustc's JSON diagnostics (`--error-format=json`).
//!
//! The format has no stability promise, so parsing is defensive: unknown
//! fields are ignored and a line that isn't a diagnostic is skipped. The
//! diagnostics are only used to decide where an error lies (in the learner's
//! lines or in a test's lines) and to pick out warnings; the text learners
//! see about their own errors comes from the compiler's human output.

use serde_json::Value;

/// One diagnostic, reduced to what grading needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diag {
    /// `error`, `warning`, `note`, ...
    pub level: String,
    /// The one-line message.
    pub message: String,
    /// The full human rendering.
    pub rendered: Option<String>,
    /// Where it lies in the compiled file: the line of its primary span,
    /// after following macro expansions back to the outermost call site.
    /// `None` for diagnostics without a span in the file ("aborting due to
    /// N previous errors"), and for spans in other files (std macros).
    pub line: Option<u32>,
}

impl Diag {
    pub fn is_error(&self) -> bool {
        self.level.starts_with("error")
    }
}

/// Parses the JSON diagnostics in `text`, one object per line. Lines that
/// are not JSON diagnostics are ignored.
pub fn parse(text: &str) -> Vec<Diag> {
    text.lines().filter_map(parse_line).collect()
}

fn parse_line(line: &str) -> Option<Diag> {
    let line = line.trim();
    if !line.starts_with('{') {
        return None;
    }
    let v: Value = serde_json::from_str(line).ok()?;
    // Artifact notices and the like have no `level`.
    let level = v.get("level")?.as_str()?.to_string();
    let message = v.get("message")?.as_str()?.to_string();
    let rendered = v
        .get("rendered")
        .and_then(Value::as_str)
        .map(str::to_string);
    let line = v
        .get("spans")
        .and_then(Value::as_array)
        .and_then(|spans| {
            spans
                .iter()
                .find(|s| s.get("is_primary").and_then(Value::as_bool) == Some(true))
        })
        .and_then(site_line);
    Some(Diag {
        level,
        message,
        rendered,
        line,
    })
}

/// The line of `span` in the compiled file, following `expansion` back to
/// the outermost call site.
fn site_line(span: &Value) -> Option<u32> {
    let mut span = span;
    // Macros can nest; the chain is short, but never loop forever.
    for _ in 0..32 {
        match span.get("expansion").and_then(|e| e.get("span")) {
            Some(call_site) if call_site.is_object() => span = call_site,
            _ => break,
        }
    }
    let file = span.get("file_name")?.as_str()?;
    let name = file.rsplit(['/', '\\']).next().unwrap_or(file);
    if name != "main.rs" {
        return None;
    }
    span.get("line_start")?.as_u64().map(|n| n as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_expansion_to_the_call_site() {
        let json = r#"{"$message_type":"diagnostic","message":"`Foo` doesn't implement `Debug`","level":"error","spans":[{"file_name":"/tmp/main.rs","line_start":120,"is_primary":true,"expansion":{"span":{"file_name":"/tmp/main.rs","line_start":210,"is_primary":false,"expansion":null},"macro_decl_name":"check_eq!"}}],"rendered":"error: x"}"#;
        let d = parse(json);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].line, Some(210));
        assert!(d[0].is_error());
        assert_eq!(d[0].rendered.as_deref(), Some("error: x"));
    }

    #[test]
    fn spanless_and_foreign_spans_have_no_line() {
        let aborting = r#"{"$message_type":"diagnostic","message":"aborting due to 1 previous error","level":"error","spans":[],"rendered":"error: aborting"}"#;
        assert_eq!(parse(aborting)[0].line, None);
        let std_file = r#"{"message":"m","level":"error","spans":[{"file_name":"<std macros>","line_start":3,"is_primary":true,"expansion":null}],"rendered":null}"#;
        assert_eq!(parse(std_file)[0].line, None);
    }

    #[test]
    fn skips_what_is_not_a_diagnostic() {
        let text =
            "not json\n{\"$message_type\":\"artifact\",\"artifact\":\"/tmp/prog\"}\n\n{\"broken\n";
        assert!(parse(text).is_empty());
    }

    #[test]
    fn uses_the_primary_span() {
        let json = r#"{"message":"m","level":"warning","spans":[{"file_name":"main.rs","line_start":1,"is_primary":false,"expansion":null},{"file_name":"main.rs","line_start":9,"is_primary":true,"expansion":null}],"rendered":"w"}"#;
        assert_eq!(parse(json)[0].line, Some(9));
    }
}
