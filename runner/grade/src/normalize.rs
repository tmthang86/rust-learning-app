//! How program output is compared with an expected string.

/// `\r\n` becomes `\n`, trailing whitespace is removed from each line, and
/// leading and trailing blank lines are dropped. Applied to both sides.
///
/// (The old rule was `trim()` of the whole text; the difference is that
/// leading spaces on the first line now count.)
pub fn normalize(text: &str) -> String {
    let text = text.replace("\r\n", "\n");
    let lines: Vec<&str> = text.split('\n').map(str::trim_end).collect();
    let first = lines.iter().position(|l| !l.is_empty());
    let Some(first) = first else {
        return String::new();
    };
    let last = lines.iter().rposition(|l| !l.is_empty()).unwrap_or(first);
    lines[first..=last].join("\n")
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn normalisation_table() {
        let cases: &[(&str, &str)] = &[
            ("", ""),
            ("\n\n", ""),
            ("   \n  \n", ""),
            ("hi", "hi"),
            ("hi\n", "hi"),
            ("\n\nhi\n\n", "hi"),
            ("hi  \nthere\t\n", "hi\nthere"),
            ("a\r\nb\r\n", "a\nb"),
            ("a\r\n\r\nb", "a\n\nb"),
            ("  indented\nx", "  indented\nx"),
            ("\n  indented", "  indented"),
            ("a\n\n\nb", "a\n\n\nb"),
            ("a \n \nb", "a\n\nb"),
            ("tab\there", "tab\there"),
        ];
        for (input, want) in cases {
            assert_eq!(normalize(input), *want, "input {input:?}");
        }
    }

    #[test]
    fn both_sides_compare_equal_after_normalising() {
        assert_eq!(normalize("First\r\nSecond\r\n"), normalize("First\nSecond"));
        assert_ne!(
            normalize(" First"),
            normalize("First"),
            "leading spaces count"
        );
    }
}
