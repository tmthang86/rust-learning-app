#!/usr/bin/env python3
"""Checks the rustc error explanations in assets/content/errors/.

- index.json and en.json have exactly the same keys (code or id),
- every field is present and non-empty, fixes has 1 to 3 entries,
- every lesson id in `lessons` exists in assets/content/lessons/,
- every `code` is a real error code that rustc still emits
  (`rustc --explain CODE` works and isn't marked "no longer emitted"),
- every `example` fails to compile, and its FIRST error is the entry's own:
  `error[CODE]` for code entries, or an `error:` line containing `match` for
  id entries (so the example is a clean demonstration),
- no two codeless rules match the same error line (checked over all examples and
  the NEGATIVE programs below), and a rule never matches the first error of
  another entry's example,
- NEGATIVE programs (similar-looking errors that must not trigger a codeless
  rule, e.g. Rust's "no ternary operator") are not matched by any rule,
- en.json text has no backticks (the app shows plain text),
- any other <lang>.json in the folder (en is the source) only uses keys that
  exist in index.json, may leave entries out (the app then shows the English
  one), and for each entry it has: only the fields title, explanation and fixes
  (the prose; everything else about an error comes from index.json), the same
  number of fixes as English, and every piece of code in the English prose
  (&name, .clone(), E0382, i32, ...) copied as is (same rule as for lessons,
  see docs/i18n/README.md).

Usage: python3 tool/check_errors.py   (needs rustc on PATH)
"""

import glob
import json
import os
import subprocess
import sys
import tempfile

from check_lessons import lesson_vocabulary, missing_code

# Same flags the code runner uses (runner/src/sandbox.rs).
RUSTC_FLAGS = ["--edition", "2024", "-C", "opt-level=1", "-C", "overflow-checks=on"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ERRORS = os.path.join(ROOT, "assets", "content", "errors")
LESSONS = os.path.join(ROOT, "assets", "content", "lessons")

# Programs whose rustc errors must NOT match any codeless rule.
NEGATIVES = {
    "ternary": 'fn main() {\n    let a = 1;\n    let c = a > 0 ? 1 : 2;\n}\n',
    "named-after-positional": 'fn main() {\n    println!("{x}", x = 1, 2);\n}\n',
}


def compile_errors(code):
    """Compiles code. Returns (compiled_ok, list of `error...` lines); a
    timeout counts as a failure with an explanatory error line."""
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "main.rs")
        with open(src, "w") as f:
            f.write(code)
        try:
            built = subprocess.run(
                ["rustc", *RUSTC_FLAGS, "-o", os.path.join(d, "prog"), src],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired:
            return False, ["error: TIMEOUT: rustc took longer than 60 s"]
    errors = [
        l
        for l in built.stderr.splitlines()
        if l.startswith("error") and "aborting due to" not in l
    ]
    return built.returncode == 0, errors


def key_of(entry):
    return entry.get("code") or entry.get("id")


def non_empty_str(v):
    return isinstance(v, str) and v.strip() != ""


def check_text(key, e, where, problems):
    texts = [e.get("title", ""), e.get("explanation", "")] + list(e.get("fixes") or [])
    if any(isinstance(t, str) and "`" in t for t in texts):
        problems.append(f"{key}: {where} text contains a backtick (plain text only)")
    for field in ("title", "explanation"):
        if not non_empty_str(e.get(field)):
            problems.append(f"{key}: {where} {field} missing or empty")
    fixes = e.get("fixes")
    if not isinstance(fixes, list) or not 1 <= len(fixes) <= 3:
        problems.append(f"{key}: {where} fixes must be a list of 1 to 3 strings")
    elif not all(non_empty_str(f) for f in fixes):
        problems.append(f"{key}: {where} has an empty fix")
    extra = set(e) - {"title", "explanation", "fixes"}
    if extra:
        problems.append(f"{key}: {where} has unknown fields {sorted(extra)}")


def check_translation(key, english, tr, name, problems):
    """A translated entry has as many fixes as the English one and keeps the
    code in the English prose (names, calls, types, error codes) as it is."""
    en_fixes = english.get("fixes") if isinstance(english.get("fixes"), list) else []
    tr_fixes = tr.get("fixes") if isinstance(tr.get("fixes"), list) else []
    if len(tr_fixes) != len(en_fixes):
        problems.append(
            f"{key}: {name} has {len(tr_fixes)} fixes, English has {len(en_fixes)}"
        )
    pairs = [("title", english.get("title"), tr.get("title")),
             ("explanation", english.get("explanation"), tr.get("explanation"))]
    pairs += [(f"fixes[{i}]", a, b) for i, (a, b) in enumerate(zip(en_fixes, tr_fixes))]
    vocab = lesson_vocabulary({})
    for field, en_text, tr_text in pairs:
        if not (isinstance(en_text, str) and isinstance(tr_text, str)):
            continue
        missing = missing_code(en_text, tr_text, vocab)
        if missing:
            problems.append(
                f"{key}: {name} {field} changes code from the English text: "
                + ", ".join(repr(t) for t in missing)
                + " missing (code in prose must be copied as is)"
            )


def main():
    problems = []
    index = json.load(open(os.path.join(ERRORS, "index.json")))
    en = json.load(open(os.path.join(ERRORS, "en.json")))
    lesson_ids = {
        os.path.basename(p)[:-5] for p in glob.glob(os.path.join(LESSONS, "*.json"))
    }

    keys = []
    for entry in index:
        key = key_of(entry)
        if not key:
            problems.append(f"index entry without code or id: {entry!r}")
            continue
        if key in keys:
            problems.append(f"{key}: duplicated in index.json")
        keys.append(key)

    only_index = sorted(set(keys) - set(en))
    only_en = sorted(set(en) - set(keys))
    if only_index:
        problems.append(f"in index.json but not en.json: {only_index}")
    if only_en:
        problems.append(f"in en.json but not index.json: {only_en}")

    fired = {}  # key -> error lines of its example
    for entry in index:
        key = key_of(entry)
        if not key:
            continue
        is_code = "code" in entry
        allowed = {"code", "lessons", "example"} if is_code else {"id", "match", "lessons", "example"}
        if set(entry) != allowed:
            problems.append(f"{key}: index fields should be {sorted(allowed)}, got {sorted(entry)}")
        if not isinstance(entry.get("lessons"), list):
            problems.append(f"{key}: lessons must be a list")
        if len(set(entry.get("lessons", []))) != len(entry.get("lessons", [])):
            problems.append(f"{key}: duplicate lesson ids")
        for lid in entry.get("lessons", []):
            if lid not in lesson_ids:
                problems.append(f"{key}: unknown lesson {lid!r}")
        if not is_code and not non_empty_str(entry.get("match")):
            problems.append(f"{key}: match missing or empty")
        if key in en:
            check_text(key, en[key], "en.json", problems)

        if is_code:
            try:
                r = subprocess.run(
                    ["rustc", "--explain", key], capture_output=True, text=True, timeout=30
                )
            except subprocess.TimeoutExpired:
                problems.append(f"{key}: rustc --explain timed out")
                r = None
            if r is None:
                pass
            elif r.returncode != 0:
                problems.append(f"{key}: not a real error code (rustc --explain failed)")
            elif "no longer emitted" in r.stdout:
                problems.append(f"{key}: rustc no longer emits this code")

        example = entry.get("example")
        if not non_empty_str(example):
            problems.append(f"{key}: example missing or empty")
            continue
        ok, errors = compile_errors(example)
        fired[key] = errors
        if ok:
            problems.append(f"{key}: example compiles but must fail")
        elif not errors:
            problems.append(f"{key}: example failed without any error line")
        elif is_code and not errors[0].startswith(f"error[{key}]"):
            problems.append(f"{key}: first error of the example is {errors[0]!r}")
        elif not is_code and not (
            errors[0].startswith("error:") and entry["match"] in errors[0]
        ):
            problems.append(
                f"{key}: first error of the example is {errors[0]!r}, "
                f"expected an `error:` line containing {entry['match']!r}"
            )

    # Codeless rules must not collide, and must not fire on other entries.
    rules = [(key_of(e), e["match"]) for e in index if "match" in e]
    lines_seen = {k: list(v) for k, v in fired.items()}
    for name, code in NEGATIVES.items():
        ok, errors = compile_errors(code)
        if ok or not errors:
            problems.append(f"negative {name!r}: should fail to compile")
        lines_seen[f"negative:{name}"] = errors
        for rid, m in rules:
            if any(m in l for l in errors):
                problems.append(f"{rid}: match {m!r} wrongly fires on negative {name!r}")
    for owner, errors in lines_seen.items():
        for l in errors:
            hits = [rid for rid, m in rules if m in l]
            if len(hits) > 1:
                problems.append(f"error line {l!r} (example {owner}) matches several rules: {hits}")
    for rid, m in rules:
        for owner, errors in fired.items():
            if owner != rid and errors and m in errors[0]:
                problems.append(f"{rid}: match {m!r} fires on the first error of {owner}")

    # Other languages: only known keys, same shape.
    for path in sorted(glob.glob(os.path.join(ERRORS, "*.json"))):
        name = os.path.basename(path)
        if name in ("index.json", "en.json"):
            continue
        data = json.load(open(path))
        if not isinstance(data, dict):
            problems.append(f"{name}: should be an object of error entries")
            continue
        for key, e in data.items():
            if key not in keys:
                problems.append(f"{name}: unknown key {key!r}")
            elif not isinstance(e, dict):
                problems.append(f"{key}: {name} entry should be an object")
            else:
                check_text(key, e, name, problems)
                check_translation(key, en[key], e, name, problems)

    for p in problems:
        print("FAIL", p)
    print(f"Checked {len(index)} error entries, {len(problems)} problems.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
