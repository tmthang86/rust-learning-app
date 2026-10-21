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

Translations (assets/content/<lang>/course.json and
assets/content/<lang>/lessons/<id>.json) are checked against their English
source without rustc, since the code in them is identical: same JSON shape,
every value equal except the translatable texts (TRANSLATABLE_KEYS), lists
of the same length, no translated file without an English one. See
docs/i18n/README.md.

Usage: python3 tool/check_lessons.py   (needs rustc on PATH)
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile

# Same flags the code runner uses (runner/src/sandbox.rs).
RUSTC_FLAGS = ["--edition", "2024", "-C", "opt-level=1", "-C", "overflow-checks=on"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTENT = os.path.join(ROOT, "assets", "content")
LESSONS = os.path.join(CONTENT, "lessons")

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

# A translation folder is named by a plain language code (assets/content/vi).
# Other folders in assets/content (lessons, errors, ...) are not locales.
LOCALE_DIR = re.compile(r"^[a-z]{2,3}$")


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
        out, _, _ = run(exercise["starter"])
        if out is not None and out.strip() == expected:
            problems.append(f"{lid}: starter code already solves the exercise")

    for q in lesson.get("quiz", []):
        if not 0 <= q["answer"] < len(q["options"]):
            problems.append(f"{lid}: quiz answer out of range in {q['question']!r}")

    return problems


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

        course_path = os.path.join(base, "course.json")
        if os.path.exists(course_path):
            en = load_json(english_course, lang, problems)
            tr = load_json(course_path, lang, problems)
            if en is not None and tr is not None:
                problems += compare_translation(en, tr, f"{lang}/course.json")
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
            problems += found
            if not found:
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
    paths = sorted(glob.glob(os.path.join(LESSONS, "*.json")))
    problems = [p for path in paths for p in check(path)]
    translation_problems, summary = check_translations()
    problems += translation_problems
    for p in problems:
        print("FAIL", p)
    for line in summary:
        print(line)
    print(f"Checked {len(paths)} lessons, {len(problems)} problems.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
