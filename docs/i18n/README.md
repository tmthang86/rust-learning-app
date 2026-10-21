# Translating Learn Rust

The app has two kinds of text, and each has its own place:

| What | English source | Other languages |
| --- | --- | --- |
| UI strings (buttons, dialogs, errors, accessibility labels) | `lib/l10n/app_en.arb` (the template) | `lib/l10n/app_<code>.arb` |
| Course content (unit titles, lesson texts, exercise prompts, quizzes) | `assets/content/course.json`, `assets/content/lessons/<id>.json` | `assets/content/<code>/course.json`, `assets/content/<code>/lessons/<id>.json` |

Available now: English (`en`, the source) and Vietnamese (`vi`). The `vi` UI is
complete; `vi` course content covers every unit and lesson title and the five
Unit 0 lessons, and everything else opens in English (see "Fallback").

Vietnamese terms and tone: [vi-glossary.md](vi-glossary.md).

## The contract for course content

A translated file is the English file with only the texts changed.

Translatable keys (the only values a translation may change):
`title`, `summary`, `text`, `prompt`, `question`, `options`, `hints`,
`explanation`, `label`.

`label` is `exercise.tests[].label`, the name of a test case. It comes with the
multi-test exercises (a separate pull request that has not landed yet); the
checker already treats it as a translatable text. Translate the label of a
visible test. A hidden test's label is copied unchanged: the checker allows a
translatable value to differ or to match the English one.

Everything else must be **byte-identical** to the English file: `id`, `number`,
`tracks`, `type`, `track`, `code`, `starter`, `solution`, `expectedOutput`,
`answer`, and any key not listed above. In particular:

- Same JSON shape: same keys, same list lengths, same order. Quiz options keep
  their order, so `answer` still points at the right one.
- Code, comments inside code, and quoted program output stay English. If an
  exercise prompt quotes the exact output (`prints First, then Second`), keep the
  quoted output as is.
- Rust keywords, identifiers, macro names (`println!`, `let`, `mut`) stay English
  in prose.
- `hints` is a list of strings (exercise hints); translate each, keep the count.
  Every exercise has 1 to 3 hints and the translated lesson needs the same
  number, or the app falls back to the English lesson.
- **Code inside prose stays as written** (rule below).
- The title in a lesson file must equal the title of that lesson in the same
  language's `course.json`. The map and the lesson then show the same title.

### Code inside prose

English prose and quiz options mention code without marking it ("Read
`let apples = 5;` as ...", the option `==`, the option `Grade A`). A translation
may reword the sentence, but the checker requires every *code token* of the
English text (in `title`, `summary`, `text`, `prompt`, `question`, `options`, `hints`,
`label` and `explanation`, in lessons and in `course.json`) to be in the
translated text, character for character, as many times as in English. A code
token is one of:

- an operator or punctuation of code: `=`, `==`, `!=`, `<=`, `+=`, `->`, `=>`,
  `&&`, `..=`, `{}`, `{:?}`, `()`, `&mut`, `&str`, `&'a`;
- a call, path or generic: `greet();`, `Some(42)`, `std::fmt`, `Vec<i32>`,
  `x.len()`, `v[0]`, `#[test]`;
- a macro known from the lesson's code (`println!`, `vec!`), a `snake_case`
  name, a number type (`i32`, `u8`, `f64`), an error code (`E0308`), a file name
  (`Cargo.toml`, `src/main.rs`), a flag (`--words`), a Rust-only keyword (`let`,
  `mut`, `fn`, `const`, `struct`, `enum`, `impl`, `mod`, `pub`, `dyn`), a bare
  number;
- a quoted string that the lesson's own code or expected output has
  (`"Grade A"`), and a line of that output written right after "prints",
  "print:" or a colon (`it should print: Even`). Quoted words that are not in
  the lesson's code (`"store this value"`), and the same words elsewhere in a
  sentence ("the end of main"), are ordinary words and may be translated.

A quiz option that is *only* code or program output (`==`, `greet();`, `"7"`,
`Grade A`, `let mut x = 1;`, `for x in &v`) must be byte-identical to English.
Words around code tokens can be translated freely. The scan is a heuristic:
when it flags something that is not code, rewrite the English or the
translation so the token appears as is (a translator can always keep the
English token in the sentence).

**The checker is a safety net, not a proof.** It cannot see that an
identifier was renamed (`let apples = 5;` -> `let táo = 5;`, "a function called
`add`" -> another name), that output was reordered ("First, then Second" ->
"Second, then First"), that lowercase one-word output was translated, or that a
sentence now says something false around intact code. Every translation batch
therefore also gets an independent reviewer who checks the code in the prose
by hand, line by line, against the English.

`python3 tool/check_lessons.py` enforces this for every `assets/content/<code>/`
folder (a folder named by a 2-3 letter language code, with an optional region
such as `pt-BR`). The app itself only loads the codes in `supportedLanguageCodes`,
so a region folder is checked but not loaded until the language is added. It walks the English and
translated files generically, so new fields added to the English lessons are
covered without changing the checker. It needs `rustc` only for the English
checks; translated files are compared to English, not compiled.

```
python3 tool/check_lessons.py          # English compile checks + translation checks
python3 tool/test_check_lessons.py     # tests of the checker itself, no rustc needed
python3 tool/check_errors.py           # error explanations, incl. other languages
```

The summary line `vi: 5 of 58 lessons translated` counts only files that pass
every check and whose texts differ from English, so a copied English file is
not counted.

## Add or update a lesson translation

1. Copy `assets/content/lessons/<id>.json` to
   `assets/content/<code>/lessons/<id>.json`.
2. Translate only the translatable keys (see above). Follow the glossary.
3. Keep the file formatted like the English one (the checker doesn't care, but
   diffs stay readable).
4. Add the lesson title to `assets/content/<code>/course.json` (see below).
5. Run `python3 tool/check_lessons.py`, then `flutter test`.

When an English lesson changes, change the translation too. If the shape
differs (a section added, an option removed), `check_lessons.py` fails in CI.
At run time the app also refuses a translated lesson whose structure doesn't
match the English one (`Lesson.hasSameStructureAs`) and shows the English lesson
instead, so a stale translation can never change how an exercise or quiz is
checked.

`course.json` is a full mirror too: translate `title` and `summary` of each unit
and `title` of each lesson; ids, numbers and tracks stay. The lesson screen and
the quiz screen show the title from the course map, so a lesson that has no
translated file still opens under its translated title.

## Fallback

`CourseRepository` (lib/data/course_repository.dart) takes a language code:

- `loadCourse(language: 'vi')` reads the English `course.json`, then replaces
  titles and summaries from `vi/course.json` where the ids match. The structure
  (units, lessons, tracks, order) always comes from English.
- `loadLesson(id, language: 'vi')` uses `vi/lessons/<id>.json` when it exists,
  parses, and has the same structure as the English lesson. Otherwise the English
  lesson is used. No translated file for a lesson means that lesson is English
  inside a Vietnamese app.
- Unknown or malformed language codes mean English.

Progress, quiz scoring and exercise checks use lesson ids and option indexes,
which don't change with the language.

## Add a new UI language (for example `fr`)

1. `lib/l10n/app_fr.arb`: copy `app_en.arb`, translate every value, drop the
   `@key` description blocks (they live only in the template). Keep the same
   `{placeholders}`. `test/localization_test.dart` checks that the keys and
   placeholders match English.
2. `flutter pub get` (or `flutter gen-l10n`) generates `AppLocalizations`. The
   generated files, `lib/l10n/app_localizations*.dart`, are **not committed**
   (see `.gitignore`); `flutter pub get` creates them, so `flutter analyze`
   and `flutter test` work right after it, in CI too.
3. `lib/data/language.dart`: add the code to `supportedLanguageCodes`, a value
   to `AppLanguage` (and its `code`).
4. `lib/features/settings/language_picker.dart`: add a segment. Write the
   language's name in that language (`Tiếng Việt`, `Français`).
5. Add `<locale android:name="fr"/>` to
   `android/app/src/main/res/xml/locales_config.xml` (Android 13+ per-app
   language) and `<string>fr</string>` to `CFBundleLocalizations` in
   `ios/Runner/Info.plist`.
6. Optional content: `assets/content/fr/course.json` and
   `assets/content/fr/lessons/`, and list both folders in `pubspec.yaml` under
   `flutter: assets:` (Flutter doesn't include sub-folders on its own).
7. Write `docs/i18n/<code>-glossary.md`.

## UI strings

- Use `context.l10n.someKey` (extension in `lib/l10n/l10n.dart`). In code with
  no `BuildContext`, take an `AppLocalizations l10n` parameter; don't store
  localized strings.
- New keys: add to `app_en.arb` with an `@key` description when the meaning isn't
  obvious, and a `placeholders` block (with `type`) for every `{name}`. Numbers
  that change the wording use ICU plurals
  (`{total, plural, =1{lesson} other{lessons}}`, also for seconds and minutes).
  Then add the Vietnamese (and any other) translation; Vietnamese has no
  plural forms, so its plural has only `other`.
- Log and debug strings (`debugPrint`) and string literals that are Rust code
  are not localized.
- The code runner reports problems as `RunIssue` values (kind plus numbers), and
  the UI turns them into text with `RunResult.errorText(l10n)`. English text is
  also kept in `RunResult.stderr` for logs and tests.
- Texts that other parties write (the ad consent form is Google's UMP form,
  store prices, the runner's own error text, rustc's messages) are shown as they
  come.

## The language setting

Learners choose **System** (default), **English** or **Tiếng Việt**, on the first
screen, on the track picker and in Progress. It is stored on the device in
`SharedPreferences` (`language`, not synced to the account). **System** uses the
first language in the device's preferred list that the app supports, else English
(`resolveLanguageCode` in `lib/data/language.dart`). That is Flutter's own
default locale resolution on purpose: a device set to French then Vietnamese
gets Vietnamese, not English. `AppState.locale` goes to
`MaterialApp.router(locale: ...)`, and `AppState` reloads the course when the
language changes, and open lesson and quiz screens reload their lesson.

## Hints, solutions and compiler-error explanations

- The labels and buttons around hints, the solution and the explanation cards
  are ordinary UI strings in the ARB files (`showHintLeft`, `hintLabel`,
  `errorCardHeading`, ...). The hint texts are lesson content (`exercise.hints`).
- The explanation cards read `assets/content/errors/<lang>.json`
  (`ErrorExplanationRepository.explain(stderr, lang: ...)`). The cards ask for the
  app's language and load again when it changes. An entry a language doesn't
  have comes in English, entry by entry, so a partial `vi.json` is fine.
- Only `title`, `explanation` and `fixes` are prose. `tool/check_errors.py`
  checks every `<lang>.json` besides `en.json`: known keys only, only those
  three fields, the same number of fixes as English, and the code in the English
  text (`&name`, `.clone()`, `i32`, `E0382`) copied as is. This is not a lesson
  mirror, and `check_lessons.py` doesn't look at it. `errors/vi.json` isn't
  written yet.

## Checks that run in CI

- `flutter analyze` and `flutter test` (language resolution and persistence,
  repository fallback, the Vietnamese screens, ARB key and placeholder parity).
- `python3 tool/check_lessons.py` (English compile checks and the translation
  checks), `python3 tool/test_check_lessons.py` and `python3 tool/check_errors.py`.
