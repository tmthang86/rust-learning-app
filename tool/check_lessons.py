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
from collections import Counter

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
        re.match(r"(let|const|static)\s[\x20-\x7e]*[=;]", text)
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
    paths = sorted(glob.glob(os.path.join(LESSONS, "*.json")))
    problems = check_course() + [p for path in paths for p in check(path)]
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
