#!/usr/bin/env python3
"""Adds quiz explanations from draft files to the lesson JSON files.

A draft file holds records separated by blank lines:

    <lessonId> <question index>
    en| English explanation
    vi| Vietnamese explanation

Each text is written as an "explanation" field right after the question's
"answer" line, in assets/content/lessons/<id>.json (en) and
assets/content/vi/lessons/<id>.json (vi). The insert is textual, so the files
keep their hand-made compact formatting; every other byte stays as it was.
The result is parsed again and compared with the original (nothing but the
new fields may change). A question that already has an explanation is an
error, as is a record for a question that doesn't exist or a quiz question
left without one.

Usage: python3 tool/inject_quiz_explanations.py DRAFT.txt [DRAFT.txt ...]
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = {
    "en": os.path.join(ROOT, "assets", "content", "lessons"),
    "vi": os.path.join(ROOT, "assets", "content", "vi", "lessons"),
}
HEADER = re.compile(r"^([a-z0-9-]+) (\d+)$")
ANSWER = re.compile(r'^(?P<indent>[ \t]*)"answer": (?P<n>\d+)(?P<comma>,?)[ \t]*$', re.M)


def parse(paths):
    """{(lesson id, index): {"en": text, "vi": text}}"""
    records = {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            blocks = re.split(r"\n[ \t]*\n", f.read().strip())
        for block in blocks:
            lines = [l.strip() for l in block.strip().split("\n") if l.strip()]
            m = HEADER.match(lines[0]) if lines else None
            if not m or len(lines) != 3:
                sys.exit(f"{path}: bad record:\n{block}")
            key = (m.group(1), int(m.group(2)))
            texts = {}
            for line in lines[1:]:
                lang, sep, text = line.partition("|")
                if not sep or lang not in DIRS or not text.strip():
                    sys.exit(f"{path}: bad line in {key}: {line!r}")
                texts[lang] = text.strip()
            if set(texts) != set(DIRS):
                sys.exit(f"{path}: {key} needs one en| and one vi| line")
            if key in records:
                sys.exit(f"{path}: {key} given twice")
            records[key] = texts
    return records


def inject(path, texts):
    """texts: {question index: explanation}. Rewrites path in place."""
    with open(path, encoding="utf-8") as f:
        source = f.read()
    before = json.loads(source)
    quiz = before.get("quiz", [])
    matches = list(ANSWER.finditer(source))
    if len(matches) != len(quiz):
        sys.exit(f"{path}: found {len(matches)} answer lines for {len(quiz)} questions")
    for i in texts:
        if not 0 <= i < len(quiz):
            sys.exit(f"{path}: no question {i}")
    for i, q in enumerate(quiz):
        if "explanation" in q:
            sys.exit(f"{path}: question {i} already has an explanation")
        if i not in texts:
            sys.exit(f"{path}: question {i} has no explanation in the drafts")
        if q["answer"] != int(matches[i].group("n")):
            sys.exit(f"{path}: answer line {i} doesn't match the quiz")
    # Back to front, so earlier offsets stay valid.
    for i in sorted(texts, reverse=True):
        m = matches[i]
        value = json.dumps(texts[i], ensure_ascii=False)
        line = (
            f'{m.group("indent")}"answer": {m.group("n")},\n'
            f'{m.group("indent")}"explanation": {value}{m.group("comma")}'
        )
        source = source[: m.start()] + line + source[m.end():]
    after = json.loads(source)
    for i, q in enumerate(after["quiz"]):
        if q.pop("explanation") != texts[i]:
            sys.exit(f"{path}: question {i} explanation didn't round-trip")
    if after != before:
        sys.exit(f"{path}: something other than explanations changed")
    with open(path, "w", encoding="utf-8") as f:
        f.write(source)


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        sys.exit(__doc__.strip())
    records = parse(sys.argv[1:])
    lessons = sorted({lid for lid, _ in records})
    for lid in lessons:
        for lang, folder in DIRS.items():
            path = os.path.join(folder, f"{lid}.json")
            if not os.path.exists(path):
                sys.exit(f"{path}: missing")
            inject(path, {i: t[lang] for (l, i), t in records.items() if l == lid})
    # Every lesson with a quiz must be covered.
    for lang, folder in DIRS.items():
        for name in sorted(os.listdir(folder)):
            lid = name[: -len(".json")]
            if name.endswith(".json") and lid not in lessons:
                with open(os.path.join(folder, name), encoding="utf-8") as f:
                    quiz = json.load(f).get("quiz", [])
                if any("explanation" not in q for q in quiz):
                    print(f"WARNING {lang}/{lid}: quiz questions without explanations")
    print(f"Added {len(records)} explanations to {len(lessons)} lessons (en + vi).")


if __name__ == "__main__":
    main()
