#!/usr/bin/env python3
"""Checks lesson content against the real Rust compiler.

For every lesson in assets/content/lessons/:
- each code section containing `fn main` must compile and run without
  compiler warnings, and if it ends with a `// Output:` comment block, that
  block must match what the program prints (code sections are shown as text
  in the app, so this comment is how learners see the output),
- each exercise is graded with `rr-grade` (the runner's own grading code, see
  runner/grade): its tests are `tests` or, for old lessons, `expectedOutput`
  read as one output test. The solution must pass every test, without
  warnings; the starter must fail at least one, and the tests must be able to
  use its code; hidden tests must differ from visible ones; the number of
  visible and hidden tests must meet the minimums below,
- each exercise needs 1 to 3 non-empty hints (strings),
- each quiz answer index must point at a real option,
- every lesson id in course.json has a file, and every file is in course.json,
- a course.json entry with `"checkpoint": true` has an exercise with a solution.

Translations (assets/content/<lang>/course.json and
assets/content/<lang>/lessons/<id>.json) are checked against their English
source without rustc, since the code in them is identical: same JSON shape,
every value equal except the translatable texts (TRANSLATABLE_KEYS), lists
of the same length, no translated file without an English one. See
docs/i18n/README.md.

Usage: python3 tool/check_lessons.py [--strict] [--lessons-dir DIR]
       python3 tool/check_lessons.py --self-test

Needs rustc and, to build `rr-grade`, cargo. The grader is `$RR_GRADE`, or
runner/target/release/rr-grade, which is brought up to date once per run with
`cargo build --release --locked -p rr-grade` in runner/ (a no-op when current;
if cargo is missing, an existing binary is used as is). CI pins the Rust
version to the sandbox's (see runner/sandbox.Dockerfile), so a lesson is
judged here as it will be judged by the runner.

Minimums (docs/exercise-tests-design.md, section 9): an exercise with `tests`
must always meet them. One that still has only `expectedOutput` is not
checked against them, unless --strict is given: then it is an error, as is a
missing `tests`. A legacy exercise is otherwise graded as one output test.

--strict: see above (used for the lessons that have been migrated).
--self-test: checks the checker on made-up exercises (a broken hidden test
must be caught).

Exercise tests (`exercise.tests`, 1 to 50, in display and run order):
  id      ^[a-z0-9][a-z0-9-]{0,39}$, unique in the exercise
  label   prose, at most 80 characters; required on visible tests, optional
          (a note for reviewers) on hidden ones
  hidden  true to hide the test in the app (code tests only)
  code    Rust statements, the body of a fn(): check_eq!(actual, expected);
          check!(cond); check_near!(a, b, tol); output_of(|| ...)
  panics  with code: the test passes only if the code panics with a message
          containing this text ("" = any panic)
  output  instead of code: what main must print
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

# Same flags the code runner uses (runner/src/sandbox.rs).
RUSTC_FLAGS = ["--edition", "2024", "-C", "opt-level=1", "-C", "overflow-checks=on"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTENT = os.path.join(ROOT, "assets", "content")
LESSONS = os.path.join(CONTENT, "lessons")
RUNNER = os.path.join(ROOT, "runner")

# What each lesson's exercise is (docs/exercise-tests-design.md, section 9).
#   P: print-only, one visible output test is enough
#   F: the learner changes a function: >= 2 visible + >= 2 hidden code tests
#   R: the learner's change is in main (restructured so a function holds it):
#      >= 1 visible + >= 2 hidden code tests
GROUP = {
    **{l: "P" for l in [
        "u0-l1", "u0-l2", "u0-l3", "u0-l4",
        "u1-l1", "u1-l2", "u1-l3", "u1-l4", "u1-l5",
        "u2-l1", "u2-l2", "u2-l3", "u2-l4",
    ]},
    **{l: "F" for l in [
        "u0-l5", "u2-l5", "u3-l1", "u3-l3", "u3-l4", "u3-l5", "u4-l2", "u4-l5",
        "u6-l2", "u6-l3", "u6-l4", "u7-l1", "u7-l2", "u7-l3", "u7-l4", "u7-l5",
        "u8-l3", "u9-l4", "u10-l1", "u11-l4", "u12-l1", "u12-l2", "u12-l3",
    ]},
    **{l: "R" for l in [
        "u4-l4", "u8-l1", "u10-l2", "u3-l2", "u4-l1", "u4-l3", "u5-l1", "u5-l2",
        "u5-l3", "u6-l1", "u8-l2", "u8-l4", "u8-l5", "u9-l1", "u9-l2", "u9-l3",
        "u10-l3", "u10-l4", "u11-l1", "u11-l2", "u11-l3", "u12-l4",
    ]},
}
# F lessons that need only one visible test.
ONE_VISIBLE_OK = {"u0-l5"}
# Lessons outside Units 0-2 where printing is the skill, so an exercise with a
# single output test is fine. Each needs a reason.
PRINT_ONLY_OK = {}
# Units whose exercises may be print-only.
PRINT_ONLY_UNITS = ("u0-", "u1-", "u2-")

TEST_KEYS = {"id", "label", "hidden", "code", "panics", "output"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")

# The only values a translation may change. Everything else (ids, numbers,
# types, tracks, code, starter, solution, expectedOutput, answer, ...) must
# equal the English file.
TRANSLATABLE_KEYS = {
    "title",
    "summary",
    "text",
    "prompt",
    "question",
    "options",
    "hints",
    "explanation",
    "label",
}

# Keys whose English text may mention code ("Read let x = 5; as ..."). The
# code in them has to stay as written in the translation (see code_tokens).
PROSE_KEYS = {
    "title", "summary", "text", "prompt", "question", "options", "hints", "label",
    "explanation",
}

# A translation folder is named by a language code (assets/content/vi) or a
# language with a region (assets/content/pt-BR, pt_BR). Other folders in
# assets/content (lessons, errors, ...) are not locales.
LOCALE_DIR = re.compile(r"^[a-z]{2,3}([-_][A-Za-z0-9]{2,8})?$")


def run(code):
    """Compiles and runs code. Returns (stdout, stderr, warnings); stdout is
    None if it doesn't compile."""
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "main.rs")
        exe = os.path.join(d, "prog")
        with open(src, "w") as f:
            f.write(code)
        built = subprocess.run(
            ["rustc", *RUSTC_FLAGS, "-o", exe, src], capture_output=True, text=True
        )
        if built.returncode != 0:
            return None, built.stderr, built.stderr
        ran = subprocess.run([exe], capture_output=True, text=True, timeout=10)
        return ran.stdout, ran.stderr, built.stderr.strip()


def output_comment(code):
    """The lines of a trailing `// Output:` comment block, or None."""
    lines = code.rstrip().split("\n")
    if "// Output:" not in [l.strip() for l in lines]:
        return None
    start = max(i for i, l in enumerate(lines) if l.strip() == "// Output:")
    body = lines[start + 1:]
    if not all(l.startswith("//") for l in body):
        return None
    return "\n".join(l[3:] if l.startswith("// ") else l[2:] for l in body)


_GRADER = None


def rr_grade_binary():
    """The path of the grader; brought up to date on first use."""
    global _GRADER
    if _GRADER:
        return _GRADER
    given = os.environ.get("RR_GRADE")
    if given:
        _GRADER = given
        return given
    exe = os.path.join(RUNNER, "target", "release", "rr-grade")
    if shutil.which("cargo") is None:
        if not os.path.exists(exe):
            sys.exit("rr-grade is not built and cargo is not on PATH (see the usage)")
    else:
        # A stale binary would grade with old rules, so always ask cargo.
        print("Building rr-grade (cargo build --release --locked -p rr-grade) ...", flush=True)
        built = subprocess.run(
            ["cargo", "build", "--release", "--locked", "-p", "rr-grade"], cwd=RUNNER
        )
        if built.returncode != 0:
            sys.exit("could not build rr-grade")
    _GRADER = exe
    return exe


def grade(code, tests):
    """Grades code against tests with rr-grade. Returns (response dict, None),
    or (None, error text) when rr-grade could not grade."""
    wire = [
        {k: t[k] for k in ("id", "code", "panics", "output") if k in t} for t in tests
    ]
    try:
        done = subprocess.run(
            [rr_grade_binary()],
            input=json.dumps({"code": code, "tests": wire}),
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        return None, "rr-grade took longer than 120 s"
    if done.returncode != 0:
        return None, done.stderr.strip() or f"rr-grade exited {done.returncode}"
    try:
        return json.loads(done.stdout), None
    except ValueError:
        return None, f"rr-grade printed something that is not JSON: {done.stdout[:200]!r}"


def exercise_tests(exercise):
    """The exercise's tests, or the legacy single output test."""
    if "tests" in exercise:
        return exercise["tests"]
    return [{"id": "output", "output": exercise["expectedOutput"]}]


def schema_problems(lid, exercise):
    """Problems with the shape of `tests` / `expectedOutput`."""
    problems = []
    has_tests = "tests" in exercise
    if has_tests and "expectedOutput" in exercise:
        problems.append(f"{lid}: exercise has both tests and expectedOutput (use one)")
    if not has_tests:
        if not isinstance(exercise.get("expectedOutput"), str):
            problems.append(f"{lid}: exercise has neither tests nor expectedOutput")
        return problems
    tests = exercise["tests"]
    if not isinstance(tests, list) or not 1 <= len(tests) <= 50:
        return problems + [f"{lid}: tests must be a list of 1 to 50 tests"]
    seen = set()
    outputs = 0
    for i, t in enumerate(tests):
        where = f"{lid}: tests[{i}]"
        if not isinstance(t, dict):
            problems.append(f"{where} is not an object")
            continue
        tid = t.get("id")
        where = f"{lid}: test {tid!r}"
        if not isinstance(tid, str) or not ID_RE.match(tid):
            problems.append(f"{lid}: tests[{i}] id must match {ID_RE.pattern}")
        elif tid in seen:
            problems.append(f"{where} id is used twice")
        else:
            seen.add(tid)
        extra = set(t) - TEST_KEYS
        if extra:
            problems.append(f"{where} has unknown keys {sorted(extra)}")
        hidden = t.get("hidden", False)
        if not isinstance(hidden, bool):
            problems.append(f"{where} hidden must be true or false")
        label = t.get("label")
        if label is not None and (not isinstance(label, str) or len(label) > 80):
            problems.append(f"{where} label must be a string of at most 80 characters")
        if not hidden and not (isinstance(label, str) and label.strip()):
            problems.append(f"{where} is visible and needs a label")
        has_code, has_output = "code" in t, "output" in t
        if has_code == has_output:
            problems.append(f"{where} needs exactly one of code and output")
        for key in ("code", "panics", "output"):
            if key in t and not isinstance(t[key], str):
                problems.append(f"{where} {key} must be a string")
        if has_code and isinstance(t.get("code"), str) and not t["code"].strip():
            problems.append(f"{where} code is empty")
        if "panics" in t and not has_code:
            problems.append(f"{where} panics only goes with code")
        if has_output:
            outputs += 1
            if hidden:
                problems.append(f"{where} an output test cannot be hidden (main takes no input)")
    if outputs > 1:
        problems.append(f"{lid}: at most one output test")
    return problems


def minimum_problems(lid, lesson, exercise):
    """Messages for an exercise below its minimums (section 8's one table)."""
    tests = exercise_tests(exercise)
    code_tests = [t for t in tests if "code" in t]
    visible = [t for t in code_tests if not t.get("hidden")]
    hidden = [t for t in code_tests if t.get("hidden")]
    # A unit's end-of-unit challenge: `uN-check`, `"checkpoint": true` in course.json.
    checkpoint = re.fullmatch(r"u\d+-check", lid) is not None
    group = GROUP.get(lid)
    msgs = []
    if group is None and not checkpoint:
        return [f"{lid}: not in the GROUP map of tool/check_lessons.py"]
    if checkpoint:
        if len(visible) < 3 or len(hidden) < 3:
            msgs.append(
                f"{lid}: a checkpoint needs >= 3 visible and >= 3 hidden code tests "
                f"(has {len(visible)} and {len(hidden)})"
            )
        return msgs
    if not code_tests:
        if lid.startswith(PRINT_ONLY_UNITS) or lid in PRINT_ONLY_OK:
            return msgs
        return [f"{lid}: only an output test; printing is the skill only in Units 0-2 (PRINT_ONLY_OK)"]
    if group == "P":
        return msgs
    need_visible = 1 if group == "R" or lid in ONE_VISIBLE_OK else 2
    if len(visible) < need_visible or len(hidden) < 2:
        msgs.append(
            f"{lid}: needs >= {need_visible} visible and >= 2 hidden code tests "
            f"(has {len(visible)} and {len(hidden)})"
        )
    return msgs


def squash(code):
    return re.sub(r"\s+", " ", code).strip()


def check_exercise(lid, lesson, exercise):
    problems = []
    schema = schema_problems(lid, exercise)
    problems += schema
    hints = exercise.get("hints")
    if (
        not isinstance(hints, list)
        or not 1 <= len(hints) <= 3
        or not all(isinstance(h, str) and h.strip() for h in hints)
    ):
        problems.append(f"{lid}: exercise needs 1 to 3 non-empty hints (strings)")
    solution = exercise.get("solution")
    if not solution:
        problems.append(f"{lid}: exercise has no solution")
    if schema or not solution:
        return problems

    if "tests" not in exercise and STRICT:
        problems.append(f"{lid}: still uses expectedOutput (strict mode wants tests)")
    tests = exercise_tests(exercise)

    # Hidden tests must not repeat a visible one.
    visible_code = {squash(t["code"]) for t in tests if "code" in t and not t.get("hidden")}
    for t in tests:
        if t.get("hidden") and "code" in t and squash(t["code"]) in visible_code:
            problems.append(f"{lid}: hidden test {t['id']!r} has the same code as a visible test")

    # Old lessons are graded as they are until strict mode; the minimums are
    # for exercises that already have tests.
    if STRICT or "tests" in exercise:
        problems += minimum_problems(lid, lesson, exercise)

    # The solution passes everything, without warnings.
    res, err = grade(solution, tests)
    if res is None:
        problems.append(f"{lid}: could not grade the solution: {err}")
    else:
        bad = [t for t in res["tests"] if t["status"] != "pass"]
        if res["stage"] == "compile":
            problems.append(
                f"{lid}: solution doesn't compile (errors in {res['compileErrorsIn']})\n"
                f"{res['stderr'][:500]}{[t.get('message') for t in res['tests'] if t.get('message')]}"
            )
        elif bad:
            for t in bad:
                problems.append(f"{lid}: solution fails test {t['id']!r}: {describe(t)}")
        elif res["warnings"].strip():
            problems.append(f"{lid}: solution has compiler warnings\n{res['warnings'][:500]}")

    # The starter fails something, and the tests can use its code.
    starter = exercise["starter"]
    res, err = grade(starter, tests)
    if res is None:
        problems.append(f"{lid}: could not grade the starter: {err}")
    elif res["stage"] == "compile" and res["compileErrorsIn"] == "tests":
        problems.append(
            f"{lid}: the tests cannot use the starter's code (keep the names and types "
            f"the tests call): {[t.get('message') for t in res['tests'] if t.get('message')]}"
        )
    elif res["stage"] == "compile":
        # Only code tests call the starter's names; an output test can't misfit.
        if any("code" in t for t in tests):
            NOTES.append(
                f"{lid}: the starter doesn't compile, so whether its names fit the tests "
                "can't be checked here: review it by hand"
            )
    elif all(t["status"] == "pass" for t in res["tests"]):
        problems.append(f"{lid}: starter code already passes every test")
    return problems


def describe(t):
    """One line about a test result, for the checker's messages."""
    if t["status"] == "fail" and "expr" in t:
        return f"{t['expr']}: expected {t.get('expected')}, got {t.get('actual')}"
    if t["status"] == "fail":
        return f"expected {t.get('expected')!r}, got {t.get('actual')!r}"
    return " ".join(
        str(x) for x in (t["status"], t.get("message"), t.get("reason")) if x
    )


STRICT = False
NOTES = []


def check(path):
    problems = []
    lesson = read_json(path)
    lid = lesson["id"]

    for i, section in enumerate(lesson["sections"]):
        if section["type"] == "code" and "fn main" in section["code"]:
            out, err, warnings = run(section["code"])
            if out is None:
                problems.append(f"{lid}: code section {i} doesn't compile\n{err[:500]}")
            elif warnings:
                problems.append(f"{lid}: code section {i} has compiler warnings\n{warnings[:500]}")
            else:
                shown = output_comment(section["code"])
                # Trailing spaces can't be seen, so they don't count.
                tidy = lambda t: [l.rstrip() for l in t.rstrip().split("\n")]
                if shown is None and "output:" in section["code"].lower():
                    problems.append(
                        f"{lid}: code section {i} mentions Output: but has no trailing "
                        "// Output: block to check (put it last, one // line per printed line)"
                    )
                elif shown is not None and tidy(shown) != tidy(out):
                    problems.append(
                        f"{lid}: code section {i} Output comment doesn't match\n"
                        f"comment: {shown!r}\nprinted: {out!r}"
                    )

    exercise = lesson.get("exercise")
    if exercise:
        problems += check_exercise(lid, lesson, exercise)

    for q in lesson.get("quiz", []):
        if not 0 <= q["answer"] < len(q["options"]):
            problems.append(f"{lid}: quiz answer out of range in {q['question']!r}")

    return problems


def check_dir(lessons_dir):
    paths = sorted(glob.glob(os.path.join(lessons_dir, "*.json")))
    problems = [p for path in paths for p in check(path)]
    return paths, problems


def self_test():
    """The checker on made-up exercises: a good one passes, broken ones are
    caught."""
    good = {
        "id": "u6-l2",
        "title": "t",
        "sections": [{"type": "text", "text": "x"}],
        "exercise": {
            "prompt": "p",
            "starter": "fn double(n: i32) -> i32 {\n    todo!()\n}\n\nfn main() {\n    println!(\"{}\", double(2));\n}",
            "solution": "fn double(n: i32) -> i32 {\n    n * 2\n}\n\nfn main() {\n    println!(\"{}\", double(2));\n}",
            "hints": ["h"],
            "tests": [
                {"id": "two", "label": "2 doubles to 4", "code": "check_eq!(double(2), 4);"},
                {"id": "zero", "label": "0 doubles to 0", "code": "check_eq!(double(0), 0);"},
                {"id": "neg", "hidden": True, "code": "check_eq!(double(-3), -6);"},
                {"id": "big", "hidden": True, "code": "check_eq!(double(1000), 2000);"},
            ],
        },
    }

    def variant(edit):
        lesson = json.loads(json.dumps(good))
        edit(lesson["exercise"])
        return lesson

    def breaks(name, lesson, expect):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "u6-l2.json"), "w") as f:
                json.dump(lesson, f)
            done = subprocess.run(
                [sys.executable, os.path.abspath(__file__), "--lessons-dir", d],
                capture_output=True,
                text=True,
            )
        failed = []
        if (done.returncode == 1) != (expect is not None):
            failed.append(f"{name}: exit status {done.returncode}\n{done.stdout}")
        elif expect and expect not in done.stdout:
            failed.append(f"{name}: output lacks {expect!r}\n{done.stdout}")
        return failed

    wrong_hidden = variant(lambda e: e["tests"][2].update(code="check_eq!(double(-3), 6);"))
    same_code = variant(lambda e: e["tests"][2].update(code="check_eq!(double(2), 4);"))
    starter_solves = variant(lambda e: e.update(starter=e["solution"]))
    few_hidden = variant(lambda e: e["tests"].pop())
    no_label = variant(lambda e: e["tests"][0].pop("label"))
    renamed = variant(lambda e: e.update(starter=e["starter"].replace("double", "twice")))
    failures = []
    failures += breaks("good exercise", good, None)
    failures += breaks("broken hidden test", wrong_hidden, "solution fails test 'neg'")
    failures += breaks("hidden repeats visible", same_code, "same code as a visible test")
    failures += breaks("starter solves it", starter_solves, "already passes every test")
    failures += breaks("too few hidden tests", few_hidden, "needs >= 2 visible and >= 2 hidden")
    failures += breaks("visible test without label", no_label, "needs a label")
    failures += breaks("starter the tests can't use", renamed, "cannot use the starter")
    for f in failures:
        print("SELF-TEST FAIL", f)
    print(f"Self-test: {7 - len({f.split(':')[0] for f in failures})} of 7 cases behaved.")
    sys.exit(1 if failures else 0)


# ---- Code inside prose -------------------------------------------------
#
# Lesson prose and quiz options mention code without marking it ("Read
# let apples = 5; as ...", options like "==" or "Grade A"). A translation may
# reword the sentence but must leave that code as it is, or a translated
# `if age = 18` teaches something false and a changed option changes which
# answer is right. The English text is scanned for "code tokens" and each one
# must still be in the translation. The scan is a heuristic, tuned to catch
# operators, calls, paths, macros, generics, quoted program output and
# similar, without flagging ordinary English words.

# Word-like pieces that are code on their own.
_CODE_WORD = re.compile(
    r"""
      ::                      # paths: std::fmt, Rc::clone
    | \w\(                    # calls: greet(), Some(42)
    | \(\)                    # unit and empty argument lists
    | [{}\[\]]                # braces and brackets: {}, {name}, v[0]
    | ->  | =>                # arrows
    | [=!<>+\-*/%]=           # ==, !=, <=, >=, +=, -=, *=
    | &&  | \|\|              # logical operators
    | \.\.                    # ranges: 1..=5
    | &['\w\[]                # &str, &mut, &'a, &[T]
    | \#\[                    # attributes
    | ^\|\w+\|$              # closure parameters: |x|
    | \w<[\w&'_]              # generics: Vec<i32>
    | \d;$                    # statements: let x = 5;
    | \w\.(rs|toml|lock|json)$ | ^src/   # file names: main.rs, src/lib.rs
    | ^--\w                   # command-line flags
    | ^[a-z][a-z0-9]*_\w+     # snake_case identifiers
    | ^E\d{4}$                # error codes
    | ^[iu](8|16|32|64|128|size)$ | ^f(32|64)$   # number types
    | ^'[a-z]+$               # lifetimes: 'a, 'static
    """,
    re.VERBOSE,
)
# Rust keywords that are never ordinary English words: code wherever they
# appear, as a bare word.
_CODE_KEYWORDS = {"let", "mut", "fn", "const", "struct", "enum", "impl", "mod", "pub", "dyn"}
_BARE_KEYWORDS = _CODE_KEYWORDS - {"let"}
# "let" is the exception: it is an everyday English word ("it won't let you",
# "let several threads send"), so it is code only in code shape: "let x =",
# "let mut", "let (a, b) =", "let Some(x) =".
_LET_SHAPE = re.compile(
    r"\blet\s+(?:mut\b|\w+\s*[=:;]|[A-Z]\w*\(|\()"
    r"|\b(?:if|while)\s+let\b|\blet-else\b"
)
# Plain words in parentheses after a name are prose, not arguments:
# "Some(that variable)". Code made of words ("v.get(i as usize)",
# "Some(ref x)", "fn rename(mut self)") has keywords or types among them and
# is kept.
_PROSE_ARGS = re.compile(r"\b([A-Za-z_]\w*)\(\s*([a-z]+(?:\s+[a-z]+)+)\s*\)")
_ARG_CODE_WORDS = {
    "as", "ref", "self", "mut", "dyn", "impl", "fn", "let", "in", "move", "usize",
    "isize", "bool", "char", "str", "box", "where", "for", "if", "else", "match",
}


def _drop_prose_args(text):
    def replace(m):
        words = m.group(2).split()
        if any(w in _ARG_CODE_WORDS or re.fullmatch(r"[iuf]\d+", w) for w in words):
            return m.group(0)
        return m.group(1)

    return _PROSE_ARGS.sub(replace, text)


# Words that make an option code ("for x in &v") when nothing else is prose.
_RUST_KEYWORDS = _CODE_KEYWORDS | {
    "for", "in", "if", "else", "new", "break", "return", "loop", "while",
    "match", "self", "use", "as", "ref", "trait", "where", "move", "static",
    "async", "await", "type", "crate",
}
# Operators that are code when they stand alone between spaces.
_CODE_OPERATORS = {
    "=", "==", "!=", "<", ">", "<=", ">=", "+", "*", "%", "&", "&&", "||", "|",
    "+=", "-=", "*=", "/=", "->", "=>", "..", "..=", "!", "{", "}", "{}", "()",
    "_", "::", ";", "#", "{:?}", "{:#?}", "[]",
}
_TRAILING_PUNCTUATION = ".,?:"
_QUOTED = re.compile(r'"((?:[^"\\]|\\.)*)"')
_MACRO_CALL = re.compile(r"\b([a-z_][a-z0-9_]*)!\s*[(\[{]")
_NUMBER = re.compile(r"^-?[0-9][0-9_.]*$")


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def check_course():
    """Cross-checks course.json against the lesson files."""
    problems = []
    course = read_json(os.path.join(ROOT, "assets", "content", "course.json"))
    listed = {}
    for unit in course["units"]:
        uid = unit["id"]
        lessons = unit["lessons"]
        checkpoints = []
        for i, ref in enumerate(lessons):
            if ref["id"] in listed:
                problems.append(f"course.json: lesson id {ref['id']} is listed twice")
            listed[ref["id"]] = ref
            flag = ref.get("checkpoint", False)
            if not isinstance(flag, bool):
                problems.append(
                    f"course.json: {ref['id']} has checkpoint {flag!r}; it must be true or false"
                )
            elif flag:
                checkpoints.append(ref)
                if i != len(lessons) - 1:
                    problems.append(f"course.json: checkpoint {ref['id']} must be the last lesson of {uid}")
                if ref["id"] != uid + "-check":
                    problems.append(f"course.json: checkpoint {ref['id']} must have id {uid}-check")
        if lessons and len(checkpoints) != 1:
            problems.append(
                f"course.json: unit {uid} has {len(checkpoints)} checkpoints, expected exactly 1"
            )
    files = {
        os.path.splitext(os.path.basename(p))[0]
        for p in glob.glob(os.path.join(LESSONS, "*.json"))
    }
    for lid in sorted(set(listed) - files):
        problems.append(f"course.json lists {lid} but assets/content/lessons/{lid}.json is missing")
    for lid in sorted(files - set(listed)):
        problems.append(f"assets/content/lessons/{lid}.json is not listed in course.json")
    for lid in sorted(files):
        lesson = read_json(os.path.join(LESSONS, lid + ".json"))
        if lesson.get("id") != lid:
            problems.append(f"{lid}.json: lesson id is {lesson.get('id')!r}, expected {lid!r}")
        if listed.get(lid, {}).get("checkpoint") is True:
            exercise = lesson.get("exercise")
            if not exercise or not exercise.get("solution"):
                problems.append(f"{lid}: checkpoint needs an exercise with a solution")
    return problems


def _looks_like_code(comment):
    """A comment that is commented-out code: it has a `;`, `!(`, `=` or ends
    in `)`. A sentence about the code does not."""
    return bool(re.search(r";|!\s*\(|=", comment)) or comment.endswith(")")


def _strip_comment(line):
    """The line without a trailing // comment (a // inside a string stays)."""
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string and ch == "\\":
            i += 2
            continue
        if ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i].rstrip()
        i += 1
    return line


def lesson_vocabulary(lesson):
    """What the English lesson's own code says: the string literals and
    program output (a quoted "Grade A" in prose is code only when the
    lesson's code prints or uses it), and the macro names in use."""
    chunks = [
        s.get("code", "")
        for s in lesson.get("sections", [])
        if isinstance(s, dict) and isinstance(s.get("code"), str)
    ]
    exercise = lesson.get("exercise")
    if isinstance(exercise, dict):
        chunks += [
            exercise[k]
            for k in ("starter", "solution", "expectedOutput")
            if isinstance(exercise.get(k), str)
        ]
    literals = set()
    outputs = set()
    macros = {"println", "print", "eprintln", "format", "vec", "panic", "assert"}
    for chunk in chunks:
        macros.update(_MACRO_CALL.findall(chunk))
        in_output_block = False
        for line in chunk.splitlines():
            line = line.strip()
            if line.startswith("//"):
                # Comments are not program output, except the lines of a
                # "// Output:" block, which show what the program prints.
                # Commented-out code ("// println!("{a}");") is still code;
                # a quoted string in a prose comment is not.
                comment = line[2:].strip()
                if comment.lower().startswith("output"):
                    in_output_block = True
                elif in_output_block and comment:
                    literals.add(comment)
                    outputs.add(comment)
                elif _looks_like_code(comment):
                    literals.add(comment)
                    literals.update(m.group(1) for m in _QUOTED.finditer(comment))
                    outputs.update(m.group(1) for m in _QUOTED.finditer(comment))
                continue
            in_output_block = False
            code = _strip_comment(line)
            literals.update(m.group(1) for m in _QUOTED.finditer(code))
            outputs.update(m.group(1) for m in _QUOTED.finditer(code))
            if code:
                literals.add(code)
    if isinstance(exercise, dict) and isinstance(exercise.get("expectedOutput"), str):
        outputs.update(l.strip() for l in exercise["expectedOutput"].splitlines())
    # Text the program prints can appear in prose without quotes ("prints
    # Even when ..."), and then it has to stay as it is. Plain lowercase
    # words are left out: they are as likely to be ordinary English.
    printed = {
        o
        for o in outputs
        if len(o) >= 3 and not (o.isalpha() and o.islower()) and re.search(r"\w", o)
    }
    return {"literals": literals, "macros": macros, "printed": printed}


def _clean_token(word):
    word = word.rstrip(_TRAILING_PUNCTUATION)
    # "(see foo()" -> "foo()": drop a bracket the token doesn't close.
    while word.startswith("(") and word.count("(") > word.count(")"):
        word = word[1:]
    while word.endswith(")") and word.count(")") > word.count("("):
        word = word[:-1]
    word = word.rstrip(_TRAILING_PUNCTUATION)
    if word.endswith("'s"):
        word = word[:-2]
    return word


# Where program output counts as code in prose: after "prints"/"output"/a
# colon ("it should print: Even"), not wherever the same words happen to occur
# ("the end of main" is not the output "end of main").
_AFTER_PRINT = r"(?i:\bprint(?:s|ed|ing)?\s+(?:the\s+(?:text|word|line|message)\s+)?|\boutput\s+|:\s*)"


def word_tokens(text, vocab):
    """Code pieces found by their shape, as a Counter (each occurrence counts:
    `==` twice in the English text must be twice in the translation)."""
    tokens = Counter()
    unquoted = _drop_prose_args(_QUOTED.sub(" ", text))
    found = len(_LET_SHAPE.findall(unquoted))
    if found:
        tokens["let"] += found
    for word in unquoted.split():
        word = _clean_token(word)
        if not word:
            continue
        macro = re.match(r"([a-z_][a-z0-9_]*)!", word)
        if (
            word in _CODE_OPERATORS
            or word in _BARE_KEYWORDS
            or _CODE_WORD.search(word)
            or (macro and macro.group(1) in vocab["macros"])
            or _NUMBER.match(word)
        ):
            tokens[word] += 1
    return tokens


def text_tokens(text, vocab):
    """Code pieces that are text, found by what the lesson's code prints:
    quoted strings the code has, and output right after "prints"/a colon.
    Looked for as is in the translation, since its own words around them
    change."""
    tokens = Counter()
    for m in _QUOTED.finditer(text):
        inside = m.group(1)
        if inside in vocab["literals"] or not inside.strip() or inside in ("...", "{}"):
            tokens[m.group(0)] += 1
    unquoted = _QUOTED.sub(" ", text)
    for out in vocab["printed"]:
        found = re.findall(
            _AFTER_PRINT + re.escape(out) + r"(?![\w])", unquoted
        )
        if found:
            tokens[out] += len(found)
    return tokens


def code_tokens(text, vocab):
    """All code tokens of `text` (a Counter)."""
    return word_tokens(text, vocab) + text_tokens(text, vocab)


def missing_code(en, tr, vocab):
    """Code tokens of the English `en` that the translation `tr` lacks or has
    fewer times, as sorted names."""
    missing = []
    have = word_tokens(tr, vocab)
    for token, n in word_tokens(en, vocab).items():
        if have[token] < n:
            missing.append(token)
    for token, n in text_tokens(en, vocab).items():
        if tr.count(token) < n:
            missing.append(token)
    return sorted(set(missing))


# let/const/static, optional mut, one name / tuple / variant pattern, an
# optional ": type", then "=" or ";". Not just any text before an "=": the
# prose option "let mut and then =" is words.
_DECLARATION = re.compile(
    r"(let|const|static)\s+(mut\s+)?"
    r"(\w+(\([^()=;]*\))?|\([^()=;]*\))"
    r"(\s*:\s*[^=;]+)?\s*[=;]"
)


def is_code_option(option, vocab):
    """A quiz option that is code or program output, not words: it must be
    byte-identical in a translation."""
    text = option.strip()
    if not text:
        return False
    if not re.search(r"[^\W\d_]", text):  # no letters at all: ==, 5, {}
        return True
    if _QUOTED.fullmatch(text) or text in vocab["literals"]:
        return True
    # A declaration or a command: "let mut x = 1;", "fn greet", "cargo new".
    if (
        _DECLARATION.match(text)
        or re.match(r"(fn|struct|enum|impl|mod)\s+\w+$", text)
        or re.match(r"(fn|struct|enum|impl|mod)\s[\x20-\x7e]*[{(<;]", text)
        or re.match(r"(cargo|rustc)\s[\x20-\x7e]+$", text)
    ):
        return True
    words = text.split()
    # Only keywords and one-letter names: "mut", "let", "pub struct", "mut self".
    if all(w in _RUST_KEYWORDS or re.fullmatch(r"[a-z]\d?", w) for w in words) and any(
        w in _CODE_KEYWORDS for w in words
    ):
        return True
    plain = [w for w in words if not code_tokens(w, vocab)]
    # Every word is code, a Rust keyword or a one-letter name ("for x in &v"),
    # with at least one real code token among them.
    return len(plain) < len(words) and all(
        w in _RUST_KEYWORDS or re.fullmatch(r"[a-z]\d?", w) for w in plain
    )


def compare_code(en, tr, where, vocab, path="$"):
    """Problems where code in the English prose of `en` is not in `tr`.
    Walks both trees in step; call it only on a pair that passed
    compare_translation (so the shapes agree)."""
    problems = []
    if isinstance(en, dict) and isinstance(tr, dict):
        for key, value in en.items():
            if key not in tr:
                continue
            here = f"{path}.{key}"
            if key in PROSE_KEYS:
                problems += compare_code_text(
                    value, tr[key], where, vocab, here, option=key == "options"
                )
            else:
                problems += compare_code(value, tr[key], where, vocab, here)
    elif isinstance(en, list) and isinstance(tr, list) and len(en) == len(tr):
        for i, (a, b) in enumerate(zip(en, tr)):
            problems += compare_code(a, b, where, vocab, f"{path}[{i}]")
    return problems


def compare_code_text(en, tr, where, vocab, path, option=False):
    if isinstance(en, list) and isinstance(tr, list) and len(en) == len(tr):
        problems = []
        for i, (a, b) in enumerate(zip(en, tr)):
            problems += compare_code_text(
                a, b, where, vocab, f"{path}[{i}]", option=option
            )
        return problems
    if not (isinstance(en, str) and isinstance(tr, str)):
        return []
    if option and is_code_option(en, vocab):
        if en != tr:
            return [
                f"{where}: {path} is code or program output and must stay "
                f"{en!r}, got {tr!r}"
            ]
        return []
    missing = missing_code(en, tr, vocab)
    if missing:
        return [
            f"{where}: {path} changes code from the English text: "
            + ", ".join(repr(t) for t in missing)
            + " missing (code in prose must be copied as is)"
        ]
    return []


def compare_translation(en, tr, where, path="$"):
    """Problems where the translation `tr` differs from the English `en`
    in more than translatable texts. Walks both trees generically, so new
    fields in the English files are covered without changes here."""
    problems = []
    if isinstance(en, dict):
        if not isinstance(tr, dict):
            return [f"{where}: {path} should be an object"]
        for key in sorted(set(en) | set(tr)):
            here = f"{path}.{key}"
            if key not in tr:
                problems.append(f"{where}: {here} is missing")
            elif key not in en:
                problems.append(f"{where}: {here} is not in the English file")
            elif key in TRANSLATABLE_KEYS:
                problems += compare_texts(en[key], tr[key], where, here)
            else:
                problems += compare_translation(en[key], tr[key], where, here)
        return problems
    if isinstance(en, list):
        if not isinstance(tr, list):
            return [f"{where}: {path} should be a list"]
        if len(en) != len(tr):
            return [f"{where}: {path} has {len(tr)} items, English has {len(en)}"]
        for i, (a, b) in enumerate(zip(en, tr)):
            problems += compare_translation(a, b, where, f"{path}[{i}]")
        return problems
    # A scalar that is not a translatable text: must be identical, and of the
    # same type (so 1 is not true, and 1 is not 1.0).
    if type(en) is not type(tr) or en != tr:
        return [f"{where}: {path} must equal the English value {en!r}, got {tr!r}"]
    return []


def compare_texts(en, tr, where, path):
    """A translatable value is a string, or a list of strings (options,
    hints): same kind and same length, non-empty if the English is."""
    if isinstance(en, str):
        if not isinstance(tr, str):
            return [f"{where}: {path} should be a string"]
        if en.strip() and not tr.strip():
            return [f"{where}: {path} is empty"]
        return []
    if isinstance(en, list) and all(isinstance(x, str) for x in en):
        if not (isinstance(tr, list) and all(isinstance(x, str) for x in tr)):
            return [f"{where}: {path} should be a list of strings"]
        if len(en) != len(tr):
            return [f"{where}: {path} has {len(tr)} items, English has {len(en)}"]
        return [
            f"{where}: {path}[{i}] is empty"
            for i, (a, b) in enumerate(zip(en, tr))
            if a.strip() and not b.strip()
        ]
    # Not a plain text (a future field shaped differently): compare it like
    # any other value, translatable keys inside it still being free.
    return compare_translation(en, tr, where, path)


def lesson_titles(course):
    """{lesson id: title} from a course.json (units[].lessons[])."""
    titles = {}
    for unit in course.get("units", []) if isinstance(course, dict) else []:
        for lesson in unit.get("lessons", []) if isinstance(unit, dict) else []:
            if isinstance(lesson, dict) and isinstance(lesson.get("id"), str):
                titles[lesson["id"]] = lesson.get("title")
    return titles


def texts_differ(en, tr):
    """True when the translatable texts of `tr` are not all the English
    ones (compare_translation has already made sure the shapes agree)."""
    if isinstance(en, dict) and isinstance(tr, dict):
        return any(
            k in tr and (en[k] != tr[k] if k in TRANSLATABLE_KEYS else texts_differ(en[k], tr[k]))
            for k in en
        )
    if isinstance(en, list) and isinstance(tr, list):
        return any(texts_differ(a, b) for a, b in zip(en, tr))
    return False


def load_json(path, where, problems):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        problems.append(f"{where}: can't read {os.path.relpath(path, ROOT)}: {e}")
        return None


def check_translations(content=CONTENT):
    """Checks every assets/content/<lang>/ against the English files.
    Returns (problems, summary lines)."""
    problems = []
    summary = []
    langs = sorted(
        d
        for d in os.listdir(content)
        if LOCALE_DIR.match(d) and os.path.isdir(os.path.join(content, d))
    )
    english_course = os.path.join(content, "course.json")
    english_lessons = sorted(
        os.path.splitext(os.path.basename(p))[0]
        for p in glob.glob(os.path.join(content, "lessons", "*.json"))
    )
    for lang in langs:
        base = os.path.join(content, lang)
        done = 0

        course_titles = {}
        course_path = os.path.join(base, "course.json")
        if os.path.exists(course_path):
            en = load_json(english_course, lang, problems)
            tr = load_json(course_path, lang, problems)
            if en is not None and tr is not None:
                found = compare_translation(en, tr, f"{lang}/course.json")
                if not found:
                    found = compare_code(
                        en, tr, f"{lang}/course.json", lesson_vocabulary({})
                    )
                problems += found
                if not found:
                    course_titles = lesson_titles(tr)
        else:
            problems.append(f"{lang}: course.json is missing (titles stay English)")

        lesson_files = sorted(glob.glob(os.path.join(base, "lessons", "*.json")))
        for path in lesson_files:
            lid = os.path.splitext(os.path.basename(path))[0]
            where = f"{lang}/lessons/{lid}.json"
            if lid not in english_lessons:
                problems.append(f"{where}: no English lesson {lid}.json (orphan file)")
                continue
            en = load_json(os.path.join(content, "lessons", f"{lid}.json"), lang, problems)
            tr = load_json(path, lang, problems)
            if en is None or tr is None:
                continue
            if isinstance(tr, dict) and tr.get("id") != lid:
                problems.append(f"{where}: id {tr.get('id')!r} should be {lid!r}")
            found = compare_translation(en, tr, where)
            if not found:
                found = compare_code(en, tr, where, lesson_vocabulary(en))
            if not found and isinstance(tr, dict):
                shown = course_titles.get(lid)
                if shown is not None and shown != tr.get("title"):
                    found = [
                        f"{where}: title {tr.get('title')!r} differs from the "
                        f"title {shown!r} in {lang}/course.json (the map and "
                        "the lesson must show the same title)"
                    ]
            problems += found
            # A copy of the English file passes the checks above but is not
            # a translation yet.
            if not found and texts_differ(en, tr):
                done += 1
        stray = [
            os.path.relpath(p, content)
            for p in glob.glob(os.path.join(base, "**", "*"), recursive=True)
            if os.path.isfile(p)
            and os.path.relpath(p, base) != "course.json"
            and not (
                os.path.dirname(os.path.relpath(p, base)) == "lessons"
                and p.endswith(".json")
            )
        ]
        for p in stray:
            problems.append(f"{p}: not a course.json or lessons/<id>.json file")
        summary.append(f"{lang}: {done} of {len(english_lessons)} lessons translated")
    return problems, summary


def main():
    global STRICT
    args = sys.argv[1:]
    if "-h" in args or "--help" in args:
        print((__doc__ or "").strip())
        sys.exit(0)
    known = {"--self-test", "--strict", "--lessons-dir"}
    for i, a in enumerate(args):
        is_dir_value = i > 0 and args[i - 1] == "--lessons-dir"
        if a.startswith("-") and a not in known and not is_dir_value:
            sys.exit(f"unknown option {a} (see --help)")
    if "--self-test" in args:
        self_test()
    STRICT = "--strict" in args
    lessons_dir = LESSONS
    if "--lessons-dir" in args:
        lessons_dir = args[args.index("--lessons-dir") + 1]
    paths, problems = check_dir(lessons_dir)
    summary = []
    # The course map and the translations describe the real content folder;
    # a --lessons-dir run (the self-test) checks lesson files only.
    if os.path.abspath(lessons_dir) == os.path.abspath(LESSONS):
        problems = check_course() + problems
        translation_problems, summary = check_translations()
        problems += translation_problems
    for n in NOTES:
        print("NOTE", n)
    for p in problems:
        print("FAIL", p)
    for line in summary:
        print(line)
    print(f"Checked {len(paths)} lessons, {len(problems)} problems.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
