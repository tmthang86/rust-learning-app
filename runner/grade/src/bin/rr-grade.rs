//! `rr-grade`: grades one exercise attempt with the host's `rustc`.
//!
//! Reads `{"code": "...", "tests": [...]}` on stdin and prints the same JSON
//! as the runner's `POST /grade` on stdout. Exit status: 0 when grading
//! happened (whatever the verdicts), 2 for bad input or when `rustc` can't
//! run. The compiler is `rustc` from `PATH`, or `$RR_GRADE_RUSTC`.
//!
//! Not a sandbox: it runs the code on this machine. It is for lesson content
//! the maintainers wrote (`tool/check_lessons.py`).

use std::io::Read;
use std::process::ExitCode;

use rr_grade::TestSpec;
use rr_grade::local::{Options, grade};
use serde::Deserialize;

#[derive(Deserialize)]
struct Input {
    code: String,
    tests: Vec<TestSpec>,
}

fn main() -> ExitCode {
    if std::env::args().skip(1).any(|a| a == "-h" || a == "--help") {
        println!(
            "usage: rr-grade < request.json > response.json\n\nrequest: {{\"code\": \"...\", \"tests\": [{{\"id\": \"a\", \"code\": \"check!(true);\"}}]}}"
        );
        return ExitCode::SUCCESS;
    }
    let mut stdin = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut stdin) {
        eprintln!("rr-grade: could not read stdin: {e}");
        return ExitCode::from(2);
    }
    let input: Input = match serde_json::from_str(&stdin) {
        Ok(input) => input,
        Err(e) => {
            eprintln!("rr-grade: bad input: {e}");
            return ExitCode::from(2);
        }
    };
    let mut opts = Options::default();
    if let Ok(rustc) = std::env::var("RR_GRADE_RUSTC") {
        opts.rustc = rustc;
    }
    match grade(&input.code, &input.tests, &opts) {
        Ok(response) => {
            println!(
                "{}",
                serde_json::to_string(&response).expect("a response is always JSON")
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("rr-grade: {e}");
            ExitCode::from(2)
        }
    }
}
