import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/data/language.dart';
import 'package:rust_learn/data/models.dart';
import 'package:rust_learn/l10n/app_localizations.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// The fake course (see fakes.dart) with a Vietnamese translation of its
/// titles and of the 'plain', 'exercise' and 'quiz' lessons.
CourseRepository viCourse({Map<String, String> extraFiles = const {}}) {
  String lesson(String id, {bool exercise = false, bool quiz = false}) =>
      jsonEncode({
        'id': id,
        'title': 'Bài $id',
        'sections': [
          {'type': 'text', 'text': 'Nội dung $id'},
        ],
        if (exercise)
          'exercise': {
            'prompt': 'In ra hi',
            'starter': 'fn main() {}',
            'expectedOutput': 'hi',
          },
        if (quiz)
          'quiz': [
            {
              'question': 'Chọn B',
              'options': ['A', 'B'],
              'answer': 1,
            },
          ],
      });
  return fakeCourse(
    extraFiles: {
      'assets/content/vi/course.json': jsonEncode({
        'units': [
          {
            'id': 'u1',
            'number': 1,
            'title': 'Cơ bản',
            'summary': 'Những điều cơ bản',
            'tracks': ['starter', 'fast'],
            'lessons': [
              {'id': 'plain', 'title': 'Bài plain'},
              {'id': 'exercise', 'title': 'Bài exercise'},
              {'id': 'quiz', 'title': 'Bài quiz'},
            ],
          },
        ],
      }),
      'assets/content/vi/lessons/plain.json': lesson('plain'),
      'assets/content/vi/lessons/exercise.json': lesson(
        'exercise',
        exercise: true,
      ),
      'assets/content/vi/lessons/quiz.json': lesson('quiz', quiz: true),
      ...extraFiles,
    },
  );
}

void main() {
  setUp(() => mockPrefs({}));

  group('resolving the language', () {
    const vi = Locale('vi');
    const viVn = Locale('vi', 'VN');
    const en = Locale('en', 'US');
    const fr = Locale('fr');

    test('System follows a Vietnamese device, otherwise English', () {
      expect(resolveLanguageCode(AppLanguage.system, [vi]), 'vi');
      expect(resolveLanguageCode(AppLanguage.system, [viVn]), 'vi');
      expect(resolveLanguageCode(AppLanguage.system, [en]), 'en');
      expect(resolveLanguageCode(AppLanguage.system, [fr]), 'en');
      expect(resolveLanguageCode(AppLanguage.system, const []), 'en');
    });

    test('System uses the first supported language the device lists', () {
      expect(resolveLanguageCode(AppLanguage.system, [fr, viVn, en]), 'vi');
      expect(resolveLanguageCode(AppLanguage.system, [en, viVn]), 'en');
    });

    test('an explicit choice ignores the device', () {
      expect(resolveLanguageCode(AppLanguage.english, [viVn]), 'en');
      expect(resolveLanguageCode(AppLanguage.vietnamese, [en]), 'vi');
      expect(resolveLanguageCode(AppLanguage.vietnamese, [fr]), 'vi');
    });

    test('stored names round-trip; anything else means System', () {
      for (final l in AppLanguage.values) {
        expect(AppLanguage.fromName(l.name), l);
      }
      expect(AppLanguage.fromName(null), AppLanguage.system);
      expect(AppLanguage.fromName('klingon'), AppLanguage.system);
    });

    test('every supported language has strings', () {
      final supported = AppLocalizations.supportedLocales.map(
        (l) => l.languageCode,
      );
      expect(supported.toSet(), supportedLanguageCodes.toSet());
    });
  });

  group('the language setting', () {
    Future<AppState> make({
      List<Locale> device = const [Locale('en', 'US')],
      CourseRepository? repository,
    }) async => AppState(
      repository: repository ?? viCourse(),
      runner: const PlaceholderCodeRunner(),
      prefs: await SharedPreferences.getInstance(),
      deviceLocales: device,
    );

    test('defaults to System, so an English device gets English', () async {
      final state = await make();
      await state.load();
      expect(state.language, AppLanguage.system);
      expect(state.languageCode, 'en');
      expect(state.locale, const Locale('en'));
      expect(state.course!.units.single.title, 'Basics');
    });

    test('a Vietnamese device gets Vietnamese with no choice made', () async {
      final state = await make(device: const [Locale('vi', 'VN')]);
      await state.load();
      expect(state.locale, const Locale('vi'));
      expect(state.course!.units.single.title, 'Cơ bản');
    });

    test('the choice is saved and read back by the next launch', () async {
      final first = await make();
      await first.setLanguage(AppLanguage.vietnamese);
      expect(first.languageCode, 'vi');
      expect(
        (await SharedPreferences.getInstance()).getString('language'),
        'vietnamese',
      );

      final second = await make();
      expect(second.language, AppLanguage.vietnamese);
      await second.load();
      expect(second.course!.units.single.title, 'Cơ bản');

      await second.setLanguage(AppLanguage.system);
      expect(
        (await SharedPreferences.getInstance()).getString('language'),
        'system',
      );
    });

    test('a damaged stored value falls back to System', () async {
      mockPrefs({'language': 42.toString()});
      final state = await make(device: const [Locale('vi')]);
      expect(state.language, AppLanguage.system);
      expect(state.languageCode, 'vi');
    });

    test('changing language reloads the course and notifies', () async {
      final state = await make();
      await state.load();
      var notified = 0;
      state.addListener(() => notified++);

      await state.setLanguage(AppLanguage.vietnamese);
      expect(notified, greaterThan(0));
      await pumpEventQueue();
      expect(state.course!.units.single.title, 'Cơ bản');
      expect(state.course!.units.single.lessons.first.title, 'Bài plain');

      await state.setLanguage(AppLanguage.english);
      await pumpEventQueue();
      expect(state.course!.units.single.title, 'Basics');
    });

    test('picking the language that is already in use changes nothing', () async {
      final state = await make();
      await state.load();
      var notified = 0;
      state.addListener(() => notified++);
      await state.setLanguage(AppLanguage.system);
      expect(notified, 0);
    });

    test('device language changes matter only for System', () async {
      final state = await make();
      await state.load();

      state.updateDeviceLocales(const [Locale('vi', 'VN')]);
      await pumpEventQueue();
      expect(state.languageCode, 'vi');
      expect(state.course!.units.single.title, 'Cơ bản');

      await state.setLanguage(AppLanguage.english);
      await pumpEventQueue();
      state.updateDeviceLocales(const [Locale('fr')]);
      state.updateDeviceLocales(const [Locale('vi')]);
      await pumpEventQueue();
      expect(state.languageCode, 'en');
      expect(state.course!.units.single.title, 'Basics');
    });

    test('switching language keeps progress and the track', () async {
      final state = await make();
      await state.load();
      await state.chooseTrack(Track.fast);
      await state.markCompleted('quiz');
      await state.setLanguage(AppLanguage.vietnamese);
      await pumpEventQueue();
      expect(state.track, Track.fast);
      expect(state.isCompleted('quiz'), isTrue);
      expect(state.completedCount, 1);
      expect(state.totalLessons, 3);
    });
  });

  group('course content in another language', () {
    test('Vietnamese titles replace English ones, structure stays', () async {
      final course = await viCourse().loadCourse(language: 'vi');
      final unit = course.units.single;
      expect(unit.title, 'Cơ bản');
      expect(unit.summary, 'Những điều cơ bản');
      expect(unit.lessons.map((l) => l.id), ['plain', 'exercise', 'quiz']);
      expect(unit.lessons.map((l) => l.title), [
        'Bài plain',
        'Bài exercise',
        'Bài quiz',
      ]);
      expect(unit.number, 1);
      expect(unit.tracks, {Track.starter, Track.fast});
    });

    test('English and unknown codes load English', () async {
      final repo = viCourse();
      for (final language in ['en', 'xx', '../vi', 'VI', '']) {
        final course = await repo.loadCourse(language: language);
        expect(course.units.single.title, 'Basics', reason: language);
        final lesson = await repo.loadLesson('plain', language: language);
        expect(lesson!.title, 'Lesson plain', reason: language);
      }
    });

    test('a missing translated course falls back to English', () async {
      final course = await fakeCourse().loadCourse(language: 'vi');
      expect(course.units.single.title, 'Basics');
    });

    test('units and lessons the translation lacks keep their English', () async {
      final repo = fakeCourse(
        extraFiles: {
          'assets/content/vi/course.json': jsonEncode({
            'units': [
              {
                'id': 'u1',
                'number': 1,
                'title': 'Cơ bản',
                'summary': 'Tóm tắt',
                'tracks': ['starter'],
                'lessons': [
                  {'id': 'plain', 'title': 'Bài plain'},
                  // exercise and quiz are not translated here
                  {'id': 'only-in-vi', 'title': 'Không có trong tiếng Anh'},
                ],
              },
              {
                'id': 'u-extra',
                'number': 9,
                'title': 'Không có',
                'summary': '',
                'tracks': ['starter'],
                'lessons': <Object>[],
              },
            ],
          }),
        },
      );
      final course = await repo.loadCourse(language: 'vi');
      expect(course.units, hasLength(1)); // structure is the English one
      final unit = course.units.single;
      expect(unit.title, 'Cơ bản');
      expect(unit.tracks, {Track.starter, Track.fast}); // not from vi
      expect(unit.lessons.map((l) => l.title), [
        'Bài plain',
        'Lesson exercise',
        'Lesson quiz',
      ]);
    });

    test('a broken translated course falls back to English', () async {
      final repo = fakeCourse(
        extraFiles: {'assets/content/vi/course.json': '{"units": ['},
      );
      expect((await repo.loadCourse(language: 'vi')).units.single.title, 'Basics');
    });

    test('translated lessons are used, per file, with English as fallback', () async {
      final repo = viCourse();
      final vi = await repo.loadLesson('exercise', language: 'vi');
      expect(vi!.title, 'Bài exercise');
      expect(vi.sections.single.body, 'Nội dung exercise');
      expect(vi.exercise!.prompt, 'In ra hi');
      expect(vi.exercise!.expectedOutput, 'hi');

      final quiz = await repo.loadLesson('quiz', language: 'vi');
      expect(quiz!.quiz.single.question, 'Chọn B');
      expect(quiz.quiz.single.answer, 1);

      // No Vietnamese file for this one.
      final repo2 = fakeCourse(
        extraFiles: {
          'assets/content/vi/lessons/plain.json': jsonEncode({
            'id': 'plain',
            'title': 'Bài plain',
            'sections': [
              {'type': 'text', 'text': 'Nội dung plain'},
            ],
          }),
        },
      );
      expect((await repo2.loadLesson('plain', language: 'vi'))!.title, 'Bài plain');
      expect(
        (await repo2.loadLesson('exercise', language: 'vi'))!.title,
        'Lesson exercise',
      );
    });

    test('a lesson missing in English is missing, even if translated', () async {
      final repo = fakeCourse(
        extraFiles: {
          'assets/content/vi/lessons/ghost.json': jsonEncode({
            'id': 'ghost',
            'title': 'Ma',
            'sections': <Object>[],
          }),
        },
      );
      expect(await repo.loadLesson('ghost', language: 'vi'), isNull);
    });

    test('a translation that changes more than texts is not used', () async {
      Map<String, Object?> base() => {
        'id': 'quiz',
        'title': 'Bài quiz',
        'sections': [
          {'type': 'text', 'text': 'Nội dung quiz'},
        ],
        'quiz': [
          {
            'question': 'Chọn B',
            'options': ['A', 'B'],
            'answer': 1,
          },
        ],
      };
      final changes = <String, void Function(Map<String, Object?>)>{
        'answer': (m) => ((m['quiz'] as List).first as Map)['answer'] = 0,
        'option count': (m) =>
            (((m['quiz'] as List).first as Map)['options'] as List).add('C'),
        'quiz length': (m) => m['quiz'] = <Object>[],
        'section count': (m) => (m['sections'] as List).add({
          'type': 'text',
          'text': 'Thêm',
        }),
        'section type': (m) =>
            ((m['sections'] as List).first as Map)['type'] = 'note',
        'id': (m) => m['id'] = 'other',
        'exercise added': (m) => m['exercise'] = {
          'prompt': 'p',
          'starter': 's',
          'expectedOutput': 'o',
        },
        'broken json': (m) => m['sections'] = 'nope',
      };
      for (final entry in changes.entries) {
        final m = base();
        entry.value(m);
        final repo = fakeCourse(
          extraFiles: {'assets/content/vi/lessons/quiz.json': jsonEncode(m)},
        );
        final lesson = await repo.loadLesson('quiz', language: 'vi');
        expect(lesson!.title, 'Lesson quiz', reason: entry.key);
      }
    });

    test('an unreadable translated lesson file gives the English one', () async {
      final repo = fakeCourse(
        extraFiles: {'assets/content/vi/lessons/plain.json': '{"id": '},
      );
      expect((await repo.loadLesson('plain', language: 'vi'))!.title, 'Lesson plain');
    });

    test('code and exercises of a translation must equal the English ones', () async {
      Lesson lesson(String starter, String solution, String code) => Lesson.fromJson({
        'id': 'x',
        'title': 'x',
        'sections': [
          {'type': 'code', 'code': code},
        ],
        'exercise': {
          'prompt': 'p',
          'starter': starter,
          'expectedOutput': 'o',
          'solution': solution,
        },
      });
      final a = lesson('s', 'sol', 'code');
      expect(a.hasSameStructureAs(lesson('s', 'sol', 'code')), isTrue);
      expect(a.hasSameStructureAs(lesson('s2', 'sol', 'code')), isFalse);
      expect(a.hasSameStructureAs(lesson('s', 'sol2', 'code')), isFalse);
      expect(a.hasSameStructureAs(lesson('s', 'sol', 'code2')), isFalse);
    });
  });

  group('the bundled Vietnamese content', () {
    test('every translated lesson fits its English lesson', () async {
      final repo = CourseRepository();
      final course = await repo.loadCourse();
      final vi = await repo.loadCourse(language: 'vi');
      expect(
        vi.units.map((u) => u.id).toList(),
        course.units.map((u) => u.id).toList(),
      );
      expect(vi.units.first.title, isNot(course.units.first.title));

      final translated = Directory('assets/content/vi/lessons')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
          .toList();
      expect(translated, isNotEmpty);
      for (final id in translated) {
        final en = await repo.loadLesson(id);
        final tr = await repo.loadLesson(id, language: 'vi');
        expect(en, isNotNull, reason: id);
        expect(
          tr!.title,
          isNot(en!.title),
          reason: '$id was not used (does not fit the English lesson?)',
        );
        expect(tr.hasSameStructureAs(en), isTrue, reason: id);
        expect(tr.quiz.map((q) => q.answer), en.quiz.map((q) => q.answer));
      }
    });

    test('lessons without a translation open in English', () async {
      final repo = CourseRepository();
      final en = await repo.loadLesson('u1-l1');
      final vi = await repo.loadLesson('u1-l1', language: 'vi');
      expect(vi!.title, en!.title);
    });

    test('the course listing is translated for every unit and lesson', () async {
      final repo = CourseRepository();
      final en = await repo.loadCourse();
      final vi = await repo.loadCourse(language: 'vi');
      for (final (i, unit) in en.units.indexed) {
        expect(vi.units[i].title, isNot(unit.title), reason: unit.id);
        expect(vi.units[i].summary, isNot(unit.summary), reason: unit.id);
      }
    });
  });

  group('UI strings', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;

    Set<String> keys(Map<String, dynamic> m) =>
        m.keys.where((k) => !k.startsWith('@')).toSet();

    Set<String> placeholders(String message) => RegExp(
      r'\{(\w+)(?:,[^{}]*(?:\{[^{}]*\}[^{}]*)*)?\}',
    ).allMatches(message).map((m) => m.group(1)!).toSet();

    test('Vietnamese has exactly the English keys', () {
      expect(keys(arb('vi')), keys(arb('en')));
    });

    test('Vietnamese messages use the same placeholders as English', () {
      final en = arb('en'), vi = arb('vi');
      for (final key in keys(en)) {
        expect(
          placeholders(vi[key] as String),
          placeholders(en[key] as String),
          reason: key,
        );
      }
    });

    test('no Vietnamese message is just a copy of the English one', () {
      final en = arb('en'), vi = arb('vi');
      // Brand names and language names are the same in both languages.
      const same = {
        'appTitle',
        'languageEnglish',
        'languageVietnamese',
      };
      for (final key in keys(en).difference(same)) {
        expect(vi[key], isNot(en[key]), reason: '$key is not translated');
      }
    });

    test('the sign-in buttons are quoted the way the buttons read', () {
      final vi = arb('vi');
      expect(vi['errOtherProviderGoogle'], contains('"${vi['continueWithGoogle']}"'));
      expect(vi['errOtherProviderApple'], contains('"${vi['continueWithApple']}"'));
      expect(vi['storeAlreadyOwned'], contains('"${vi['restorePurchases']}"'));
    });
  });

  group('screens', () {
    /// Lets a course reload that a language change started finish: the
    /// bundle is read on the real event loop, which pumping alone doesn't
    /// run.
    Future<void> courseReloaded(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }

    Future<AppState> start(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      bool ageKnown = false,
      String location = '/learn',
      CourseRepository? repository,
    }) async {
      mockPrefs(prefs, ageKnown: ageKnown);
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = (await tester.runAsync(() async {
        final s = AppState(
          repository: repository ?? viCourse(),
          runner: const PlaceholderCodeRunner(),
          prefs: await SharedPreferences.getInstance(),
          deviceLocales: tester.platformDispatcher.locales,
        );
        await s.load();
        return s;
      }))!;
      await tester.pumpWidget(
        RustLearnApp(state: state, initialLocation: location),
      );
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('the first screen can be switched to Vietnamese', (tester) async {
      await start(tester);
      expect(find.text('What year were you born?'), findsOneWidget);
      expect(find.text('Hệ thống'), findsNothing);

      // The picker is there before the learner has read anything.
      expect(find.text('System'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Tiếng Việt'), findsOneWidget);

      await tester.tap(find.text('Tiếng Việt'));
      await tester.pumpAndSettle();

      expect(find.text('Bạn sinh năm nào?'), findsOneWidget);
      expect(find.text('Chào mừng bạn'), findsOneWidget);
      expect(find.text('Tiếp tục'), findsOneWidget);
      expect(find.text('What year were you born?'), findsNothing);
      // Language names stay in their own language.
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Tiếng Việt'), findsOneWidget);
      expect(find.text('Hệ thống'), findsOneWidget);
    });

    testWidgets('Vietnamese carries through age, track, map and lesson', (
      tester,
    ) async {
      await start(tester);
      await tester.tap(find.text('Tiếng Việt'));
      await tester.pumpAndSettle();
      await courseReloaded(tester);

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.text('Tiếp tục'));
      await tester.pumpAndSettle();
      expect(find.text('Vui lòng nhập năm gồm bốn chữ số.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '1990');
      await tester.tap(find.text('Tiếp tục'));
      await tester.pumpAndSettle();
      expect(find.text('Bạn muốn bắt đầu từ đâu?'), findsOneWidget);
      // The picker is on this screen too.
      expect(find.text('Ngôn ngữ'), findsOneWidget);

      await tester.tap(find.text('Tôi đã biết một ngôn ngữ lập trình khác'));
      await tester.pumpAndSettle();

      // Course map.
      expect(find.text('Cơ bản'), findsOneWidget);
      expect(find.text('Basics'), findsNothing);
      expect(
        find.textContaining('Đã hoàn thành 0/3 bài học'),
        findsOneWidget,
      );
      expect(find.text('Học'), findsOneWidget); // navigation

      await tester.tap(find.text('Cơ bản'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bài exercise'));
      await tester.pumpAndSettle();

      expect(find.text('Nội dung exercise'), findsOneWidget);
      expect(find.text('In ra hi'), findsOneWidget);
      expect(find.text('Thử ngay'), findsOneWidget);
      expect(find.text('Chạy'), findsOneWidget);
      expect(find.text('Body of exercise'), findsNothing);
    });

    testWidgets('the Progress screen switches language, even back', (
      tester,
    ) async {
      final state = await start(
        tester,
        prefs: {'track': 'fast'},
        ageKnown: true,
        location: '/progress',
      );
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('0 of 3 lessons done'), findsOneWidget);

      await tester.tap(find.text('Tiếng Việt'));
      await tester.pumpAndSettle();
      expect(state.languageCode, 'vi');
      expect(find.text('Ngôn ngữ'), findsOneWidget);
      expect(find.text('Lộ trình học'), findsOneWidget);
      expect(find.text('Đã hoàn thành 0/3 bài học'), findsOneWidget);
      expect(find.text('Tiến độ'), findsWidgets);

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(state.languageCode, 'en');
      expect(find.text('Learning track'), findsOneWidget);
      expect(find.text('Progress'), findsWidgets);

      // And it is remembered.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('language'), 'english');
    });

    testWidgets('a Vietnamese device gets Vietnamese until told otherwise', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = const [Locale('vi', 'VN')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await start(tester);
      expect(find.text('Bạn sinh năm nào?'), findsOneWidget);

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('What year were you born?'), findsOneWidget);
    });

    testWidgets('other device languages get English', (tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('fr', 'FR')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await start(tester);
      expect(find.text('What year were you born?'), findsOneWidget);
    });

    testWidgets('changing the device language is followed while on System', (
      tester,
    ) async {
      await start(tester);
      expect(find.text('What year were you born?'), findsOneWidget);

      tester.platformDispatcher.localesTestValue = const [Locale('vi')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpAndSettle();
      expect(find.text('Bạn sinh năm nào?'), findsOneWidget);
    });

    testWidgets('an open lesson switches language and keeps typed code', (
      tester,
    ) async {
      final state = await start(
        tester,
        prefs: {'track': 'fast'},
        ageKnown: true,
        location: '/lesson/exercise',
      );
      expect(find.text('Body of exercise'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'fn main() { /* mine */ }',
      );

      await tester.runAsync(() => state.setLanguage(AppLanguage.vietnamese));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(find.text('Nội dung exercise'), findsOneWidget);
      expect(find.text('Body of exercise'), findsNothing);
      expect(find.text('fn main() { /* mine */ }'), findsOneWidget);
    });

    testWidgets('quiz and scoring work the same in Vietnamese', (tester) async {
      final state = await start(
        tester,
        prefs: {'track': 'fast', 'language': 'vietnamese'},
        ageKnown: true,
        location: '/lesson/quiz/quiz',
      );
      expect(state.languageCode, 'vi');
      expect(find.text('Kiểm tra: Bài quiz'), findsOneWidget);
      expect(find.text('Chọn B'), findsOneWidget);

      await tester.tap(find.text('A')); // wrong answer
      await tester.pump();
      await tester.tap(find.text('Kiểm tra'));
      await tester.pumpAndSettle();
      expect(find.text('Chưa đúng. Đáp án là: B'), findsOneWidget);
      expect(find.text('Sai, đây là đáp án của bạn'), findsOneWidget);
      expect(find.text('Đáp án đúng'), findsOneWidget);

      await tester.tap(find.text('Tiếp theo'));
      await tester.pumpAndSettle();
      expect(find.text('Đúng 0/1 câu'), findsOneWidget);
      expect(find.text('Hãy xem lại bài học và thử lại.'), findsOneWidget);
      expect(state.isCompleted('quiz'), isFalse);
    });

    testWidgets('a lesson with no translation shows English in Vietnamese', (
      tester,
    ) async {
      // 'plain' translated in viCourse; an extra English-only lesson:
      final repo = viCourse(
        extraFiles: {
          'assets/content/lessons/english-only.json': jsonEncode({
            'id': 'english-only',
            'title': 'Only English',
            'sections': [
              {'type': 'text', 'text': 'English body'},
            ],
          }),
        },
      );
      await start(
        tester,
        prefs: {'track': 'fast', 'language': 'vietnamese'},
        ageKnown: true,
        location: '/lesson/english-only',
        repository: repo,
      );
      expect(find.text('English body'), findsOneWidget);
      // The chrome around it is Vietnamese.
      expect(find.text('Đánh dấu là đã xong'), findsOneWidget);
    });

    testWidgets('runner problems are shown in the learner\'s language', (
      tester,
    ) async {
      await start(
        tester,
        prefs: {'track': 'fast', 'language': 'vietnamese'},
        ageKnown: true,
        location: '/lesson/exercise',
      );
      await tester.tap(find.text('Chạy'));
      await tester.pumpAndSettle();
      expect(find.text('Không thể chạy code của bạn'), findsOneWidget);
      expect(find.textContaining('Bản dựng này chưa thiết lập'), findsOneWidget);
    });

    testWidgets('the app title is localized for the task switcher', (
      tester,
    ) async {
      await start(tester);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final context = tester.element(find.byType(Scaffold).first);
      expect(app.onGenerateTitle!(context), 'Learn Rust');
      expect(app.supportedLocales, AppLocalizations.supportedLocales);
      expect(app.locale, const Locale('en'));
    });
  });

  test('the runner turns server answers into issues the UI can translate', () {
    final l10n = _vi();
    expect(const RunIssue(RunIssueKind.busy, seconds: 5).message(l10n), contains('5 giây'));
    expect(const RunIssue(RunIssueKind.busy).message(l10n), contains('ít phút'));
    expect(
      const RunIssue(RunIssueKind.serverText, text: 'from the server').message(l10n),
      'from the server',
    );
    expect(
      RunResult.unavailableFor(const RunIssue(RunIssueKind.tooLong)).stderr,
      'Your code is too long to run. Try making it shorter.',
    );
    expect(
      const RunResult(success: false, stage: RunStage.unavailable, stderr: 'plain')
          .errorText(l10n),
      'plain',
    );
  });
}

AppLocalizations _vi() => lookupAppLocalizations(const Locale('vi'));
