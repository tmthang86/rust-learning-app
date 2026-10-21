#!/usr/bin/env python3
"""Checks lesson content against the real Rust compiler.

For every lesson in assets/content/lessons/:
- each code section containing `fn main` must compile and run without
  compiler warnings, and if it ends with a `// Output:` comment block, that
  block must match what the program prints (code sections are shown as text
  in the app, so this comment is how learners see the output),
- each exercise's solution must print the expected output, without warnings,
- each exercise's starter code must NOT already print it,
- each exercise needs 1 to 3 non-empty hints (strings),
- each quiz answer index must point at a real option,
- every lesson id in course.json has a file, and every file is in course.json,
- a course.json entry with `"checkpoint": true` has an exercise with a solution.

Usage: python3 tool/check_lessons.py   (needs rustc on PATH)
"""

import glob
import json
import os
import subprocess
import sys
import tempfile

# Same flags the code runner uses (runner/src/sandbox.rs).
RUSTC_FLAGS = ["--edition", "2024", "-C", "opt-level=1", "-C", "overflow-checks=on"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LESSONS = os.path.join(ROOT, "assets", "content", "lessons")


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


def check(path):
    problems = []
    lesson = load_json(path)
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
        expected = exercise["expectedOutput"].strip()
        solution = exercise.get("solution")
        if not solution:
            problems.append(f"{lid}: exercise has no solution")
        else:
            out, err, warnings = run(solution)
            if out is None or out.strip() != expected:
                problems.append(f"{lid}: solution printed {out!r}, expected {expected!r}\n{err[:500]}")
            elif warnings:
                problems.append(f"{lid}: solution has compiler warnings\n{warnings[:500]}")
        hints = exercise.get("hints")
        if (
            not isinstance(hints, list)
            or not 1 <= len(hints) <= 3
            or not all(isinstance(h, str) and h.strip() for h in hints)
        ):
            problems.append(f"{lid}: exercise needs 1 to 3 non-empty hints (strings)")
        out, _, _ = run(exercise["starter"])
        if out is not None and out.strip() == expected:
            problems.append(f"{lid}: starter code already solves the exercise")

    for q in lesson.get("quiz", []):
        if not 0 <= q["answer"] < len(q["options"]):
            problems.append(f"{lid}: quiz answer out of range in {q['question']!r}")

    return problems


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def check_course():
    """Cross-checks course.json against the lesson files."""
    problems = []
    course = load_json(os.path.join(ROOT, "assets", "content", "course.json"))
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
        lesson = load_json(os.path.join(LESSONS, lid + ".json"))
        if lesson.get("id") != lid:
            problems.append(f"{lid}.json: lesson id is {lesson.get('id')!r}, expected {lid!r}")
        if listed.get(lid, {}).get("checkpoint") is True:
            exercise = lesson.get("exercise")
            if not exercise or not exercise.get("solution"):
                problems.append(f"{lid}: checkpoint needs an exercise with a solution")
    return problems


def main():
    paths = sorted(glob.glob(os.path.join(LESSONS, "*.json")))
    problems = check_course() + [p for path in paths for p in check(path)]
    for p in problems:
        print("FAIL", p)
    print(f"Checked {len(paths)} lessons, {len(problems)} problems.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
