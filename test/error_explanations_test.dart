import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/data/error_explanations.dart';
import 'package:rust_learn/data/models.dart';

import 'fakes.dart';

/// Real `rustc --edition 2024` output (rustc 1.97); see test/fixtures.
String fixture(String name) =>
    File('test/fixtures/rustc_$name.txt').readAsStringSync();

const codeRules = [
  ErrorRule(key: 'E0382', code: 'E0382'),
  ErrorRule(key: 'E0308', code: 'E0308'),
];
const syntaxRule = ErrorRule(
  key: 'syntax-missing-semicolon',
  match: 'expected `;`',
);

void main() {
  group('findErrorKeys', () {
    test('reads the code from an error line and ignores a warning', () {
      // a: E0382 error, then an unused-variable warning, then the summary.
      expect(findErrorKeys(fixture('a'), codeRules), ['E0382']);
    });

    test('a codeless error is found through its match text', () {
      expect(findErrorKeys(fixture('b'), [...codeRules, syntaxRule]), [
        'syntax-missing-semicolon',
      ]);
    });

    test('a codeless error nobody wrote a rule for gives nothing', () {
      expect(findErrorKeys(fixture('b'), codeRules), isEmpty);
    });

    test('keeps order of first appearance, not the summary order', () {
      // c prints E0425 first; its closing line lists "E0308, E0425".
      expect(findErrorKeys(fixture('c'), codeRules), ['E0425', 'E0308']);
    });

    test('repeated codes count once', () {
      const twice =
          'error[E0308]: mismatched types\n--> x\n\n'
          'error[E0308]: mismatched types\n--> y\n\n'
          'error: aborting due to 2 previous errors\n';
      expect(findErrorKeys(twice, const []), ['E0308']);
    });

    test('keeps the first 3 of more than 3 codes', () {
      expect(findErrorKeys(fixture('e'), const []), [
        'E0425',
        'E0308',
        'E0689',
      ]);
    });

    test('summary lines are not errors, even when a rule would match', () {
      const rule = ErrorRule(key: 'aborting', match: 'previous error');
      expect(findErrorKeys(fixture('b'), [rule]), isEmpty);
      expect(
        findErrorKeys('For more information, try `rustc --explain E0382`.', []),
        isEmpty,
      );
    });

    test('warning lines with a code-like text are ignored', () {
      expect(
        findErrorKeys('warning[E0123]: something\nwarning: unused', const []),
        isEmpty,
      );
    });

    test('Windows line endings work', () {
      final crlf = fixture('c').replaceAll('\n', '\r\n');
      expect(findErrorKeys(crlf, codeRules), ['E0425', 'E0308']);
      expect(
        findErrorKeys(fixture('b').replaceAll('\n', '\r\n'), [syntaxRule]),
        ['syntax-missing-semicolon'],
      );
    });

    test('a code inside a source excerpt line is not an error', () {
      const excerpt =
          'error[E0308]: mismatched types\n'
          ' --> main.rs:12:9\n'
          '  |\n'
          '12 |     let s = "error[E0499]";\n'
          '  |             ^^^^^^^^^^^^^^^\n'
          '  = note: error[E0382] in a note\n'
          '  = help: error: expected `;` in a help line\n';
      expect(findErrorKeys(excerpt, [...codeRules, syntaxRule]), ['E0308']);
    });

    test('empty output gives nothing', () {
      expect(findErrorKeys('', codeRules), isEmpty);
    });
  });

  test('official URL', () {
    expect(
      officialErrorUrl('E0382'),
      'https://doc.rust-lang.org/error_codes/E0382.html',
    );
  });

  group('ErrorExplanationRepository', () {
    String index() => jsonEncode([
      {
        'code': 'E0382',
        'lessons': ['u3-l1'],
        'example': 'x',
      },
      {
        'id': 'syntax-missing-semicolon',
        'match': 'expected `;`',
        'lessons': [],
      },
      {'oops': true},
    ]);
    String en() => jsonEncode({
      'E0382': {
        'title': 'Moved',
        'explanation': 'e',
        'fixes': ['a', 'b'],
      },
      'syntax-missing-semicolon': {
        'title': 'Missing ;',
        'explanation': 'e',
        'fixes': ['add ;'],
      },
    });

    ErrorExplanationRepository repo(Map<String, String> files) =>
        ErrorExplanationRepository(bundle: MapBundle(files));

    test('explains known errors in English', () async {
      final r = repo({
        'assets/content/errors/index.json': index(),
        'assets/content/errors/en.json': en(),
      });
      final help = await r.explain(fixture('a'));
      expect(help.single.key, 'E0382');
      expect(help.single.text!.title, 'Moved');
      expect(help.single.text!.fixes, ['a', 'b']);
      expect(help.single.lessons, ['u3-l1']);
      expect(help.single.officialUrl, officialErrorUrl('E0382'));

      final syntax = await r.explain(fixture('b'));
      expect(syntax.single.key, 'syntax-missing-semicolon');
      expect(syntax.single.officialUrl, isNull);
    });

    test('a missing vi file falls back to English', () async {
      final r = repo({
        'assets/content/errors/index.json': index(),
        'assets/content/errors/en.json': en(),
      });
      final help = await r.explain(fixture('a'), lang: 'vi');
      expect(help.single.text!.title, 'Moved');
    });

    test(
      'vi wins per entry and missing entries fall back to English',
      () async {
        final r = repo({
          'assets/content/errors/index.json': index(),
          'assets/content/errors/en.json': en(),
          'assets/content/errors/vi.json': jsonEncode({
            'E0382': {'title': 'Da chuyen', 'explanation': 'e', 'fixes': []},
          }),
        });
        expect(
          (await r.explain(fixture('a'), lang: 'vi')).single.text!.title,
          'Da chuyen',
        );
        expect(
          (await r.explain(fixture('b'), lang: 'vi')).single.text!.title,
          'Missing ;',
        );
      },
    );

    test('an unknown code has no text but keeps its official page', () async {
      final r = repo({
        'assets/content/errors/index.json': index(),
        'assets/content/errors/en.json': en(),
      });
      final help = await r.explain(fixture('c'));
      expect(help.map((h) => h.key), ['E0425', 'E0308']);
      expect(help.every((h) => h.text == null), isTrue);
      expect(help.first.officialUrl, officialErrorUrl('E0425'));
    });

    test('malformed files give no text and do not throw', () async {
      final r = repo({
        'assets/content/errors/index.json': '{not json',
        'assets/content/errors/en.json': '[1, 2',
      });
      final help = await r.explain(fixture('a'));
      // The code is still known from rustc's output.
      expect(help.single.key, 'E0382');
      expect(help.single.text, isNull);
      expect(await r.explain(fixture('b')), isEmpty);
    });

    test('files of the wrong shape and bad entries are skipped', () async {
      final r = repo({
        'assets/content/errors/index.json': '{"a": 1}',
        'assets/content/errors/en.json': jsonEncode({
          'E0382': {'title': 5},
        }),
      });
      expect((await r.explain(fixture('a'))).single.text, isNull);
    });

    test('missing files give nothing and do not throw', () async {
      final r = repo({});
      expect(await r.rules(), isEmpty);
      expect(await r.explain(fixture('b')), isEmpty);
    });

    test('files are read once', () async {
      var reads = 0;
      final bundle = _CountingBundle({
        'assets/content/errors/index.json': index(),
        'assets/content/errors/en.json': en(),
      }, () => reads++);
      final r = ErrorExplanationRepository(bundle: bundle);
      await r.explain(fixture('a'));
      await r.explain(fixture('a'));
      expect(reads, 2); // index + en, once each
    });
  });

  group('Exercise hints', () {
    Exercise parse(Map<String, dynamic> extra) => Exercise.fromJson({
      'prompt': 'p',
      'starter': 's',
      'expectedOutput': 'o',
      ...extra,
    });

    test('are read in order', () {
      expect(
        parse({
          'hints': ['one', 'two'],
        }).hints,
        ['one', 'two'],
      );
    });

    test('default to none', () {
      expect(parse({}).hints, isEmpty);
    });

    test('ignore entries that are not strings', () {
      expect(
        parse({
          'hints': ['one', 2, null],
        }).hints,
        ['one'],
      );
    });
  });

  test('Course.lessonTitle finds a lesson in any unit', () {
    final course = Course.fromJson({
      'units': [
        {
          'id': 'u',
          'number': 1,
          'title': 't',
          'summary': 's',
          'tracks': ['fast'],
          'lessons': [
            {'id': 'a', 'title': 'Lesson A'},
          ],
        },
      ],
    });
    expect(course.lessonTitle('a'), 'Lesson A');
    expect(course.lessonTitle('zzz'), isNull);
  });
}

class _CountingBundle extends MapBundle {
  _CountingBundle(super.files, this.onRead);
  final void Function() onRead;

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    onRead();
    return super.loadString(key, cache: cache);
  }
}
