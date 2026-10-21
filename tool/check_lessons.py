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
- each quiz answer index must point at a real option.

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

# Same flags the code runner uses (runner/src/sandbox.rs).
RUSTC_FLAGS = ["--edition", "2024", "-C", "opt-level=1", "-C", "overflow-checks=on"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LESSONS = os.path.join(ROOT, "assets", "content", "lessons")
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
    checkpoint = lesson.get("kind") == "checkpoint" or exercise.get("kind") == "checkpoint"
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
    lesson = json.load(open(path))
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
    for n in NOTES:
        print("NOTE", n)
    for p in problems:
        print("FAIL", p)
    print(f"Checked {len(paths)} lessons, {len(problems)} problems.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
