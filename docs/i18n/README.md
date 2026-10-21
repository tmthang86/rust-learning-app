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

`label` is `exercise.tests[].label`, the name of a test case. Translate the label
of a visible test. A hidden test's label is copied unchanged: the checker allows
a translatable value to differ or to match the English one.

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

`python3 tool/check_lessons.py` enforces this for every `assets/content/<code>/`
folder (a folder named by a 2-3 letter language code). It walks the English and
translated files generically, so new fields added to the English lessons are
covered without changing the checker. It needs `rustc` only for the English
checks; translated files are compared to English, not compiled.

```
python3 tool/check_lessons.py          # English compile checks + translation checks
python3 tool/test_check_lessons.py     # tests of the checker itself, no rustc needed
```

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
and `title` of each lesson; ids, numbers and tracks stay.

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
  (`{total, plural, =1{lesson} other{lessons}}`). Then add the Vietnamese (and
  any other) translation.
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
(`resolveLanguageCode` in `lib/data/language.dart`). `AppState.locale` goes to
`MaterialApp.router(locale: ...)`, and `AppState` reloads the course when the
language changes, and open lesson and quiz screens reload their lesson.

## Checks that run in CI

- `flutter analyze` and `flutter test` (language resolution and persistence,
  repository fallback, the Vietnamese screens, ARB key and placeholder parity).
- `python3 tool/check_lessons.py` (English compile checks and the translation
  checks) and `python3 tool/test_check_lessons.py`.

## Other files that live nearby

- `lib/l10n` holds the generated `app_localizations*.dart` (gitignored) and
  hand-written Dart files such as `l10n.dart`. More hand-written files, for
  example `help_strings.dart`, can sit beside them; only the generated files are
  ignored.
- `assets/content/errors/<lang>.json` (compiler-error help text) is a separate
  feature, not a lesson mirror. The lesson checker does not look at it.
