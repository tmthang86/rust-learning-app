#!/usr/bin/env python3
"""Checks lesson content against the real Rust compiler.

For every lesson in assets/content/lessons/:
- each code section containing `fn main` must compile and run without
  compiler warnings, and if it ends with a `// Output:` comment block, that
  block must match what the program prints (code sections are shown as text
  in the app, so this comment is how learners see the output),
- each exercise's solution must print the expected output, without warnings,
- each exercise's starter code must NOT already print it,
- each quiz answer index must point at a real option.

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
                if shown is not None and tidy(shown) != tidy(out):
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
        out, _, _ = run(exercise["starter"])
        if out is not None and out.strip() == expected:
            problems.append(f"{lid}: starter code already solves the exercise")

    for q in lesson.get("quiz", []):
        if not 0 <= q["answer"] < len(q["options"]):
            problems.append(f"{lid}: quiz answer out of range in {q['question']!r}")

    return problems


def main():
    paths = sorted(glob.glob(os.path.join(LESSONS, "*.json")))
    problems = [p for path in paths for p in check(path)]
    for p in problems:
        print("FAIL", p)
    print(f"Checked {len(paths)} lessons, {len(problems)} problems.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
