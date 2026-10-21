# Hints, solutions and rustc error explanations

Static help for learners who are stuck. No AI and no network calls beyond the
code runner, so it costs nothing per use, collects no data and works for every
age group, including under-13 learners.

## Why this shape (research)

- Hint ladders: novices get more out of hints that go from general guidance to
  concrete code than from vague hints alone (Xiao, Hou and Stamper, 2024,
  https://arxiv.org/html/2404.02213v1). Educators rate short hints at about a
  US grade 9 reading level or below as best, and dislike hints that offer
  alternative solutions (Brown et al., 2024, https://arxiv.org/html/2411.18151v1).
- Error messages: the ITiCSE 2019 working group on programming error messages
  (Becker et al., summary at
  https://neverworkintheory.org/2021/09/02/compiler-error-messages-considered-unhelpful.html)
  recommends lowering cognitive load, giving context, a positive tone, examples
  and hints toward a fix. Enhanced messages help understanding but are not a
  silver bullet, so they sit next to the real compiler output, never replace it.
- Which errors: JetBrains RustRover data puts type errors (E0599, E0308, E0433)
  at the top for Rust users
  (https://blog.jetbrains.com/rust/2023/12/20/the-most-common-rust-compiler-errors-as-encountered-in-rustrover-part-2/);
  the ownership and borrowing errors (E0382, E0499, E0502, ...) come from our
  own Unit 3 and 7 content and the starters of our exercises.

## Data

### Exercise hints (lesson JSON)

`exercise.hints`: 1 to 3 strings, shown one at a time, in order:
1. A nudge: what to look at or which idea from the lesson applies. No code.
2. The tool: the syntax or method to use, with at most a small fragment.
3. (optional) Nearly the answer: says exactly what to change, but the learner
   still types it.

Rules: plain English, at most about 40 words each, only ideas taught in this
lesson or earlier, never contradicting the reference `solution`, valid for both
tracks. `hints` is a translatable key (Vietnamese mirror under
`assets/content/vi/lessons/`).

### Error explanations

- `assets/content/errors/index.json` (not translated): a list of entries with
  the matching rule and data used by checks:
  - `{"code": "E0382", "lessons": ["u3-l1"], "example": "<broken program>"}`
  - Errors without a code (mostly syntax errors) use `"id": "syntax-..."` plus
    `"match": "<substring of rustc's error line>"` instead of `code`.
  - `example` must fail to compile with exactly that code (or message) under
    the runner's flags; `tool/check_errors.py` checks this.
- `assets/content/errors/en.json` (translatable; `vi.json` later):
  `{"E0382": {"title": "...", "explanation": "...", "fixes": ["...", "..."]}}`,
  keyed by `code` or `id`. Missing locale entries fall back to English per
  entry.
- Official page for a code: `https://doc.rust-lang.org/error_codes/<CODE>.html`
  (derived, not stored). Sources and check dates: `docs/error-sources.md`.

Writing rules for explanations: friendly, no blame, about grade 6-8 reading
level (under-13 learners use this), explanation at most about 60 words, 1 to 3
fixes, each an action. Every statement must agree with the official error
index entry (`rustc --explain <CODE>` prints the same text offline).

## App behavior

- Hints: under the exercise's Run row, a "Show a hint" button reveals the next
  hint ("Hint 1 of 3"); revealed hints stay visible.
- Solution: a "Show solution" button appears once the learner has run the
  exercise at least once without solving it (a run that reached the compiler
  or ran; "runner unavailable" doesn't count). It shows the reference solution
  with "Copy to editor". Seeing it does not complete the lesson; running a
  correct program does.
- Error explanations: when a run fails to compile, the app reads codes from
  `error[E....]` lines in stderr (and the `match` rules for codeless errors),
  keeps the first 3 distinct ones, and shows a "What this means" card for each:
  title, explanation, fixes, a "Review lesson" link when the entry names a
  lesson, and the official page address. Unknown codes show only the official
  page address. Shown in lessons and the playground.
- External links: the official page is shown as selectable text, not opened,
  so under-13 learners aren't sent out of the app.
