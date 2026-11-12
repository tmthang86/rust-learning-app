import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rust_learn/app/theme.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/models.dart';
import 'package:rust_learn/features/editor/tests_panel.dart';
import 'package:rust_learn/l10n/app_localizations_en.dart';
import 'package:rust_learn/l10n/app_localizations_vi.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const _lessonWithTests = '''
{"id": "graded", "title": "Graded",
 "sections": [{"type": "text", "text": "Body of graded"}],
 "exercise": {
   "prompt": "Write is_adult",
   "starter": "fn is_adult(age: u32) -> bool { todo!() }\\nfn main() {}",
   "tests": [
     {"id": "fifteen-too-young", "label": "15 is too young",
      "code": "assert!(!is_adult(15));"},
     {"id": "thirty-ok", "label": "30 is an adult",
      "code": "assert!(is_adult(30));"},
     {"id": "boundary-18", "label": "SECRET boundary note", "hidden": true,
      "code": "assert!(is_adult(18)); // SECRETCODE"}
   ]}}
''';

const _legacyLesson = '''
{"id": "legacy", "title": "Legacy",
 "sections": [{"type": "text", "text": "Body of legacy"}],
 "exercise": {"prompt": "Print hi", "starter": "fn main() {}",
              "expectedOutput": "hi"}}
''';

GradeResult _graded(
  Map<String, TestResult> byId, {
  bool success = true,
  RunStage stage = RunStage.run,
  String stderr = '',
  String? compileErrorsIn,
  String? reason,
}) => GradeResult(
  success: success,
  stage: stage,
  stderr: stderr,
  compileErrorsIn: compileErrorsIn,
  reason: reason,
  tests: byId.values.toList(),
);

TestResult _pass(String id) => TestResult(id: id, status: TestStatus.pass);

TestResult _fail(
  String id, {
  String expr = 'is_adult(15)',
  String expected = 'false',
  String actual = 'true',
}) => TestResult(
  id: id,
  status: TestStatus.fail,
  expr: expr,
  expected: expected,
  actual: actual,
  line: 3,
);

void main() {
  final en = AppLocalizationsEn();
  final vi = AppLocalizationsVi();
  group('Exercise and ExerciseTest', () {
    test('a lesson with tests parses them, hidden and all', () {
      final e = Exercise.fromJson(
        jsonDecode(_lessonWithTests)['exercise'] as Map<String, dynamic>,
      );
      expect(e.tests.map((t) => t.id), [
        'fifteen-too-young',
        'thirty-ok',
        'boundary-18',
      ]);
      expect(e.tests.map((t) => t.hidden), [false, false, true]);
      expect(e.tests.first.label, '15 is too young');
      expect(e.expectedOutput, isNull);
    });

    test('expectedOutput alone becomes one output test called output', () {
      final e = Exercise.fromJson(
        jsonDecode(_legacyLesson)['exercise'] as Map<String, dynamic>,
      );
      expect(e.expectedOutput, 'hi');
      expect(e.tests, hasLength(1));
      expect(e.tests.single.id, 'output');
      expect(e.tests.single.isOutput, isTrue);
      expect(e.tests.single.output, 'hi');
      expect(e.tests.single.hidden, isFalse);
    });

    test('neither tests nor expectedOutput is a format error', () {
      expect(
        () => Exercise.fromJson({'prompt': 'p', 'starter': 's'}),
        throwsFormatException,
      );
      expect(
        () => Exercise.fromJson({'prompt': 'p', 'starter': 's', 'tests': []}),
        throwsFormatException,
      );
    });

    test('a test needs an id and exactly one of code and output', () {
      expect(() => ExerciseTest.fromJson({'code': 'x'}), throwsFormatException);
      expect(() => ExerciseTest.fromJson({'id': 'a'}), throwsFormatException);
      expect(
        () => ExerciseTest.fromJson({'id': 'a', 'code': 'x', 'output': 'y'}),
        throwsFormatException,
      );
    });

    test('wrongly typed fields are format errors, not type errors', () {
      for (final bad in [
        {'id': 'a', 'code': 'x', 'label': 5},
        {'id': 'a', 'code': 'x', 'panics': []},
        {'id': 5, 'code': 'x'},
      ]) {
        expect(() => ExerciseTest.fromJson(bad), throwsFormatException);
      }
      expect(
        () => Exercise.fromJson({'prompt': 'p', 'starter': 's', 'tests': 'x'}),
        throwsFormatException,
      );
      expect(
        () => Exercise.fromJson({
          'prompt': 'p',
          'starter': 's',
          'tests': [5],
        }),
        throwsFormatException,
      );
    });

    test('the request leaves out the label and hidden', () {
      final t = ExerciseTest.fromJson({
        'id': 'a',
        'label': 'A label',
        'hidden': true,
        'code': 'assert!(true);',
        'panics': 'boom',
      });
      expect(t.toRequestJson(), {
        'id': 'a',
        'code': 'assert!(true);',
        'panics': 'boom',
      });
      expect(ExerciseTest.legacy('hi').toRequestJson(), {
        'id': 'output',
        'output': 'hi',
      });
    });
  });

  group('GradeResult', () {
    final tests = [
      const ExerciseTest(id: 'a', label: 'A', code: 'x'),
      const ExerciseTest(id: 'b', hidden: true, code: 'y'),
    ];

    test('solves when every test, hidden ones too, passed', () {
      expect(_graded({'a': _pass('a'), 'b': _pass('b')}).solves(tests), isTrue);
    });

    test('a failing hidden test does not solve', () {
      expect(
        _graded({'a': _pass('a'), 'b': _fail('b')}).solves(tests),
        isFalse,
      );
    });

    test('a test the runner sent no result for does not solve', () {
      expect(_graded({'a': _pass('a')}).solves(tests), isFalse);
    });

    test('an unavailable runner never solves, nor does an empty list', () {
      expect(GradeResult.unavailable('offline').solves(tests), isFalse);
      expect(_graded({}).solves(const []), isFalse);
    });

    test('parses the wire format', () {
      final r = GradeResult.fromJson({
        'success': false,
        'stage': 'run',
        'stdout': '',
        'stderr': '',
        'compileErrorsIn': null,
        'tests': [
          {'id': 'a', 'status': 'pass'},
          {
            'id': 'b',
            'status': 'fail',
            'expr': 'f(1)',
            'expected': '2',
            'actual': '3',
            'line': 4,
          },
          {'id': 'c', 'status': 'not_run', 'reason': 'exit:3'},
        ],
      });
      expect(r.tests.map((t) => t.status), [
        TestStatus.pass,
        TestStatus.fail,
        TestStatus.notRun,
      ]);
      expect(r.testById('b')!.expected, '2');
      expect(r.testById('b')!.line, 4);
      expect(r.testById('c')!.reason, 'exit:3');
      expect(r.testById('nope'), isNull);
    });

    test('a result without tests, or with an unknown status, is rejected', () {
      expect(
        () => GradeResult.fromJson({'success': true, 'stage': 'run'}),
        throwsFormatException,
      );
      expect(
        () => TestResult.fromJson({'id': 'a', 'status': 'weird'}),
        throwsFormatException,
      );
    });
  });

  group('GradeResult.fromLegacyRun', () {
    GradeResult legacy(RunResult r) => GradeResult.fromLegacyRun(r, 'hi\n');

    test('matching output passes, ignoring whitespace around it', () {
      final r = legacy(
        const RunResult(success: true, stage: RunStage.run, stdout: ' hi'),
      );
      expect(r.tests.single.id, 'output');
      expect(r.tests.single.status, TestStatus.pass);
      expect(r.solves([ExerciseTest.legacy('hi')]), isTrue);
    });

    test('other output fails with expected and actual', () {
      final r = legacy(
        const RunResult(success: true, stage: RunStage.run, stdout: 'ho'),
      );
      expect(r.tests.single.status, TestStatus.fail);
      expect(r.tests.single.expected, 'hi\n');
      expect(r.tests.single.actual, 'ho');
    });

    test('a panic with the right output so far is still a failure', () {
      final r = legacy(
        const RunResult(success: false, stage: RunStage.run, stdout: 'hi'),
      );
      expect(r.tests.single.status, TestStatus.fail);
    });

    test('compile errors are the learner\'s, a timeout is a timeout', () {
      final c = legacy(
        const RunResult(success: false, stage: RunStage.compile, stderr: 'e'),
      );
      expect(c.compileErrorsIn, 'code');
      expect(c.tests.single.status, TestStatus.notRun);
      expect(showsTestsPanel(c), isFalse);
      final t = legacy(
        const RunResult(success: false, stage: RunStage.timeout),
      );
      expect(t.tests.single.status, TestStatus.timeout);
    });

    test('an unreachable runner stays unavailable', () {
      final r = legacy(RunResult.unavailable('offline'));
      expect(r.stage, RunStage.unavailable);
      expect(r.stderr, 'offline');
      expect(r.solves([ExerciseTest.legacy('hi')]), isFalse);
    });
  });

  group('Vietnamese strings', () {
    test('every reason code has its own Vietnamese sentence', () {
      final seen = <String>{};
      for (final code in [
        'mem_limit',
        'output_limit',
        'stack_overflow',
        'no_main',
        'tests_dont_fit',
        'harness',
        'exit:3',
      ]) {
        expect(seen.add(testReasonText(vi, code)), isTrue, reason: code);
      }
      expect(testReasonText(vi, 'exit:3'), contains('3'));
      expect(testReasonText(vi, 'new_code'), vi.testReasonUnknown);
    });

    test('the announcement follows the language', () {
      final tests = [const ExerciseTest(id: 'a', label: 'Nhãn', code: 'x')];
      final r = _graded({
        'a': _fail('a', expected: 'Err(1)', actual: 'Ok(15)'),
      });
      final text = gradeAnnouncement(vi, r, tests, solved: false);
      expect(text, startsWith('Đạt 0 trên 1 test.'));
      expect(text, contains('Không đạt: Nhãn.'));
      expect(text, contains('Ok(15)'));
      expect(
        gradeAnnouncement(vi, _graded({'a': _pass('a')}), tests, solved: true),
        endsWith(vi.exerciseSolved),
      );
    });

    test('plural forms work in both languages', () {
      expect(en.announceTestsSummary(1, 1), '1 of 1 test passed.');
      expect(en.announceTestsSummary(1, 2), '1 of 2 tests passed.');
      expect(en.announceHiddenFailed(1), '1 hidden test failed.');
      expect(en.announceHiddenFailed(3), '3 hidden tests failed.');
      expect(vi.announceHiddenFailed(3), '3 test ẩn không đạt.');
    });

    test(
      'a runner that needs an update is explained in the learner language',
      () {
        final r = GradeResult.unavailableFor(
          const RunIssue(RunIssueKind.runnerNeedsUpdate),
        );
        expect(r.errorText(vi), vi.runIssueRunnerNeedsUpdate);
        expect(r.errorText(en), en.runIssueRunnerNeedsUpdate);
        expect(r.stderr, en.runIssueRunnerNeedsUpdate);
      },
    );
  });

  group('reason codes', () {
    test('each code the runner sends has its own sentence', () {
      final seen = <String>{};
      for (final code in [
        'mem_limit',
        'output_limit',
        'stack_overflow',
        'no_main',
        'tests_dont_fit',
        'harness',
      ]) {
        final text = testReasonText(en, code);
        expect(text, isNot(en.testReasonUnknown), reason: code);
        expect(seen.add(text), isTrue, reason: 'distinct text for $code');
      }
      expect(testReasonText(en, 'exit:3'), contains('exit code 3'));
      expect(testReasonText(en, 'something_new'), en.testReasonUnknown);
    });
  });

  group('HttpCodeRunner.grade', () {
    final base = Uri.parse('https://runner.example/');
    final tests = [
      const ExerciseTest(id: 'a', label: 'Shown', hidden: true, code: 'x'),
      ExerciseTest.legacy('hi'),
    ];
    final okBody = jsonEncode({
      'success': true,
      'stage': 'run',
      'stdout': '',
      'stderr': '',
      'tests': [
        {'id': 'a', 'status': 'pass'},
        {'id': 'output', 'status': 'fail', 'expected': 'hi', 'actual': 'ho'},
      ],
    });
    String errorBody(String code) => jsonEncode({'error': 'x', 'code': code});

    test('posts code and tests to /grade and parses the answer', () async {
      late http.Request sent;
      final runner = HttpCodeRunner(
        base,
        client: MockClient((req) async {
          sent = req;
          return http.Response(okBody, 200);
        }),
      );

      final r = await runner.grade('fn main() {}', tests);

      expect(sent.url.toString(), 'https://runner.example/grade');
      expect(jsonDecode(sent.body), {
        'harness': 1,
        'code': 'fn main() {}',
        'tests': [
          {'id': 'a', 'code': 'x'},
          {'id': 'output', 'output': 'hi'},
        ],
      });
      expect(r.stage, RunStage.run);
      expect(r.testById('a')!.status, TestStatus.pass);
      expect(r.testById('output')!.actual, 'ho');
    });

    test('/run is still posted to /run with only the code', () async {
      late http.Request sent;
      final runner = HttpCodeRunner(
        base,
        client: MockClient((req) async {
          sent = req;
          return http.Response(
            jsonEncode({'success': true, 'stage': 'run'}),
            200,
          );
        }),
      );
      await runner.run('fn main() {}');
      expect(sent.url.toString(), 'https://runner.example/run');
      expect(jsonDecode(sent.body), {'code': 'fn main() {}'});
    });

    test('a bad App Check token is refreshed once, as for /run', () async {
      final tokens = <String?>[];
      final runner = HttpCodeRunner(
        base,
        auth: _FakeAuth(['stale', 'fresh']),
        client: MockClient((req) async {
          final token = req.headers['X-Firebase-AppCheck'];
          tokens.add(token);
          return token == 'fresh'
              ? http.Response(okBody, 200)
              : http.Response(errorBody('app_check_invalid'), 401);
        }),
      );

      final r = await runner.grade('x', tests);

      expect(tokens, ['stale', 'fresh']);
      expect(r.stage, RunStage.run);
    });

    Future<GradeResult> answering(http.Response response) => HttpCodeRunner(
      base,
      client: MockClient((_) async => response),
    ).grade('x', tests);

    test('a runner without /grade says it needs an update', () async {
      final r = await answering(http.Response('Not Found', 404));
      expect(r.stage, RunStage.unavailable);
      expect(r.stderr, en.runIssueRunnerNeedsUpdate);
      expect(r.solves(tests), isFalse);
    });

    test('tests_invalid has its own message', () async {
      final r = await answering(http.Response(errorBody('tests_invalid'), 400));
      expect(r.stage, RunStage.unavailable);
      expect(r.stderr, en.runIssueTestsInvalid);
    });

    test('harness_unsupported asks for an app update', () async {
      final r = await answering(
        http.Response(errorBody('harness_unsupported'), 400),
      );
      expect(r.stage, RunStage.unavailable);
      expect(r.issue!.kind, RunIssueKind.appNeedsUpdate);
      expect(r.stderr, en.runIssueAppNeedsUpdate);
      expect(r.errorText(vi), vi.runIssueAppNeedsUpdate);
    });

    test(
      'client_busy (429) says a run is in progress, not rate limited',
      () async {
        final r = await answering(
          http.Response(
            errorBody('client_busy'),
            429,
            headers: {'retry-after': '3'},
          ),
        );
        expect(r.issue!.kind, RunIssueKind.runInProgress);
        expect(r.stderr, en.runIssueRunInProgress);
        expect(r.errorText(vi), vi.runIssueRunInProgress);
      },
    );

    test('existing 429 and 503 mappings are unchanged', () async {
      final limited = await answering(
        http.Response(
          errorBody('rate_limited'),
          429,
          headers: {'retry-after': '7'},
        ),
      );
      expect(limited.issue!.kind, RunIssueKind.rateLimited);
      expect(limited.issue!.seconds, 7);
      final busy = await answering(http.Response(errorBody('busy'), 429));
      expect(busy.issue!.kind, RunIssueKind.busy);
      final down = await answering(http.Response(errorBody('busy'), 503));
      expect(down.issue!.kind, RunIssueKind.busy);
    });

    test('429 says the runner is busy, using Retry-After', () async {
      final r = await answering(
        http.Response(
          errorBody('rate_limited'),
          429,
          headers: {'retry-after': '7'},
        ),
      );
      expect(r.stage, RunStage.unavailable);
      expect(r.stderr, contains('7 seconds'));
    });

    test(
      'network failures, bad JSON and a missing tests list are unavailable',
      () async {
        final offline = await HttpCodeRunner(
          base,
          client: MockClient((_) async => throw http.ClientException('no')),
        ).grade('x', tests);
        expect(offline.stage, RunStage.unavailable);

        final garbage = await answering(http.Response('<html>', 200));
        expect(garbage.stage, RunStage.unavailable);

        final noTests = await answering(
          http.Response(jsonEncode({'success': true, 'stage': 'run'}), 200),
        );
        expect(noTests.stage, RunStage.unavailable);
        expect(noTests.solves(tests), isFalse);
      },
    );

    test('a 404 from /run keeps its old message', () {
      expect(
        HttpCodeRunner.errorMessage(http.Response('', 404)),
        isNot(en.runIssueRunnerNeedsUpdate),
      );
    });
  });

  group('gradeAnnouncement', () {
    final tests = [
      const ExerciseTest(id: 'a', label: 'A is fine', code: 'x'),
      const ExerciseTest(id: 'b', label: '15 is too young', code: 'y'),
      const ExerciseTest(id: 'h1', hidden: true, code: 'z'),
      const ExerciseTest(id: 'h2', hidden: true, code: 'z'),
    ];

    test('names the first visible failure and counts hidden failures', () {
      final r = _graded({
        'a': _pass('a'),
        'b': _fail('b', expected: 'Err(1)', actual: 'Ok(15)'),
        'h1': _fail('h1'),
        'h2': _pass('h2'),
      });
      final text = gradeAnnouncement(en, r, tests, solved: false);
      expect(text, startsWith('2 of 4 tests passed.'));
      expect(text, contains('Failed: 15 is too young.'));
      expect(text, contains('Expected Err(1), got Ok(15).'));
      expect(text, endsWith('1 hidden test failed.'));
      expect(text, isNot(contains('A is fine')));
    });

    test('hidden failures are only counted, never described', () {
      final r = _graded({
        'a': _pass('a'),
        'b': _pass('b'),
        'h1': _fail('h1', actual: 'LEAK'),
        'h2': _fail('h2', actual: 'LEAK'),
      });
      final text = gradeAnnouncement(en, r, tests, solved: false);
      expect(text, contains('2 hidden tests failed.'));
      expect(text, isNot(contains('LEAK')));
      expect(text, isNot(contains('Failed:')));
    });

    test(
      'is clipped at 200 characters and ends with the verdict if solved',
      () {
        final long = 'x' * 500;
        final r = _graded({'a': _fail('a', expected: long, actual: long)});
        final one = [const ExerciseTest(id: 'a', label: 'A', code: 'x')];
        final text = gradeAnnouncement(en, r, one, solved: false);
        expect(text.length, lessThanOrEqualTo(201));
        expect(text, endsWith('…'));

        final all = _graded({'a': _pass('a')});
        expect(
          gradeAnnouncement(en, all, one, solved: true),
          '1 of 1 test passed. ${en.exerciseSolved}',
        );
      },
    );

    test('says the tests cannot use the code in that case', () {
      final r = _graded(
        {'a': const TestResult(id: 'a', status: TestStatus.error)},
        success: false,
        stage: RunStage.compile,
        compileErrorsIn: 'tests',
        reason: 'tests_dont_fit',
      );
      expect(
        gradeAnnouncement(en, r, tests, solved: false),
        en.testsCantUseYourCode,
      );
    });
  });

  group('output comparison helpers', () {
    test('normalizedLines matches the runner', () {
      expect(normalizedLines('\n\na  \r\nb\n\n'), ['a', 'b']);
      expect(normalizedLines(''), isEmpty);
    });

    test('firstDifferingLine finds the line, or null', () {
      expect(firstDifferingLine(['a', 'b'], ['a', 'c']), 1);
      expect(firstDifferingLine(['a'], ['a', 'b']), 1);
      expect(firstDifferingLine(['a'], ['a']), isNull);
    });
  });

  group('in the lesson', () {
    late AppState state;
    late FakeRunner runner;

    Future<void> open(
      WidgetTester tester,
      String lesson,
      FakeRunner fake, {
      Map<String, Object> prefs = const {},
    }) async {
      runner = fake;
      mockPrefs({'track': 'fast', ...prefs});
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      state = (await tester.runAsync(() async {
        final s = AppState(
          repository: fakeCourse(
            extraFiles: {
              'assets/content/lessons/graded.json': _lessonWithTests,
              'assets/content/lessons/legacy.json': _legacyLesson,
            },
          ),
          runner: fake,
          prefs: await SharedPreferences.getInstance(),
        );
        await s.load();
        return s;
      }))!;
      await tester.pumpWidget(
        RustLearnApp(state: state, initialLocation: '/lesson/$lesson'),
      );
      await tester.pumpAndSettle();
    }

    Future<void> run(WidgetTester tester, {String button = 'Run'}) async {
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
    }

    const dummy = RunResult(success: true, stage: RunStage.run);

    testWidgets(
      'sends every test, hidden ones too, and no panel before a run',
      (tester) async {
        await open(tester, 'graded', FakeRunner(dummy, graded: _graded({})));
        expect(find.byType(TestsPanel), findsNothing);

        await run(tester);

        expect(runner.gradeRequests, hasLength(1));
        expect(runner.gradeRequests.single.map((t) => t.id), [
          'fifteen-too-young',
          'thirty-ok',
          'boundary-18',
        ]);
      },
    );

    testWidgets('the panel and the verdict speak Vietnamese', (tester) async {
      await open(
        tester,
        'graded',
        FakeRunner(
          dummy,
          graded: _graded({
            'fifteen-too-young': _fail('fifteen-too-young'),
            'thirty-ok': _pass('thirty-ok'),
            'boundary-18': _fail('boundary-18'),
          }),
        ),
        prefs: {'language': 'vietnamese'},
      );
      final semantics = tester.ensureSemantics();

      await run(tester, button: 'Chạy');

      expect(find.text('Test: đạt 1 trên 3'), findsOneWidget);
      expect(find.text('Test ẩn: đạt 0 trên 1'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Không đạt: 15 is too young'),
        findsOneWidget,
      );
      expect(find.text('Mong đợi: ', findRichText: true), findsWidgets);
      expect(find.text('Chưa đúng. Hãy tiếp tục thử nhé.'), findsOneWidget);
      expect(find.textContaining('Expected'), findsNothing);
      semantics.dispose();
    });

    testWidgets('all tests passing solves the lesson once', (tester) async {
      await open(
        tester,
        'graded',
        FakeRunner(
          dummy,
          graded: _graded({
            'fifteen-too-young': _pass('fifteen-too-young'),
            'thirty-ok': _pass('thirty-ok'),
            'boundary-18': _pass('boundary-18'),
          }),
        ),
      );
      expect(state.isCompleted('graded'), isFalse);

      await run(tester);

      expect(find.text('Tests: 3 of 3 passed'), findsOneWidget);
      expect(find.text('Hidden tests: 1 of 1 passed'), findsOneWidget);
      expect(find.text('Correct! Nice work.'), findsWidgets);
      expect(state.isCompleted('graded'), isTrue);
    });

    testWidgets(
      'a failing hidden test shows a count, a nudge, and nothing else',
      (tester) async {
        await open(
          tester,
          'graded',
          FakeRunner(
            dummy,
            graded: _graded({
              'fifteen-too-young': _pass('fifteen-too-young'),
              'thirty-ok': _pass('thirty-ok'),
              'boundary-18': _fail(
                'boundary-18',
                expr: 'SECRETEXPR',
                expected: 'SECRETEXPECTED',
                actual: 'SECRETACTUAL',
              ),
            }),
          ),
        );
        final semantics = tester.ensureSemantics();

        await run(tester);

        expect(find.text('Tests: 2 of 3 passed'), findsOneWidget);
        expect(find.text('Hidden tests: 0 of 1 passed'), findsOneWidget);
        expect(find.text(en.hiddenOnlyFailing), findsOneWidget);
        expect(find.text('Not quite yet. Keep trying.'), findsOneWidget);
        expect(state.isCompleted('graded'), isFalse);
        // Nothing about the hidden test is in the widget tree...
        for (final secret in ['SECRET', 'boundary-18', 'is_adult(18)']) {
          expect(find.textContaining(secret), findsNothing, reason: secret);
          expect(
            find.byWidgetPredicate(
              (w) => w is SelectableText && (w.data ?? '').contains(secret),
            ),
            findsNothing,
          );
          // ...nor in what a screen reader can reach.
          expect(
            find.bySemanticsLabel(RegExp(secret), skipOffstage: false),
            findsNothing,
            reason: secret,
          );
        }
        semantics.dispose();
      },
    );

    testWidgets('the first visible failure is open, the others folded', (
      tester,
    ) async {
      await open(
        tester,
        'graded',
        FakeRunner(
          dummy,
          graded: _graded({
            'fifteen-too-young': _fail(
              'fifteen-too-young',
              expr: 'is_adult(15)',
              expected: 'false',
              actual: 'true',
            ),
            'thirty-ok': _fail(
              'thirty-ok',
              expr: 'is_adult(30)',
              expected: 'true',
              actual: 'false',
            ),
            'boundary-18': _pass('boundary-18'),
          }),
        ),
      );

      await run(tester);

      expect(find.text('is_adult(15)'), findsOneWidget);
      expect(find.text('is_adult(30)'), findsNothing);

      await tester.tap(
        find.textContaining('30 is an adult', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('is_adult(30)'), findsOneWidget);
      // Opening one does not close the other.
      expect(find.text('is_adult(15)'), findsOneWidget);

      await tester.tap(
        find.textContaining('15 is too young', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('is_adult(15)'), findsNothing);
    });

    testWidgets('rows are buttons named by status and label', (tester) async {
      await open(
        tester,
        'graded',
        FakeRunner(
          dummy,
          graded: _graded({
            'fifteen-too-young': _fail('fifteen-too-young'),
            'thirty-ok': _pass('thirty-ok'),
            'boundary-18': _pass('boundary-18'),
          }),
        ),
      );
      final semantics = tester.ensureSemantics();

      await run(tester);

      expect(find.bySemanticsLabel('Failed: 15 is too young'), findsOneWidget);
      expect(find.bySemanticsLabel('Passed: 30 is an adult'), findsOneWidget);
      final node = tester.getSemantics(
        find.bySemanticsLabel('Failed: 15 is too young'),
      );
      expect(node.hint, en.testRowHintHide);
      semantics.dispose();
    });

    testWidgets('tests that cannot use the code: banner, no output panel', (
      tester,
    ) async {
      await open(
        tester,
        'graded',
        FakeRunner(
          dummy,
          graded: _graded(
            {
              'fifteen-too-young': const TestResult(
                id: 'fifteen-too-young',
                status: TestStatus.error,
                message: 'cannot find function `is_adult`',
                reason: 'tests_dont_fit',
              ),
              'thirty-ok': const TestResult(
                id: 'thirty-ok',
                status: TestStatus.error,
                reason: 'tests_dont_fit',
              ),
              'boundary-18': const TestResult(
                id: 'boundary-18',
                status: TestStatus.error,
                reason: 'tests_dont_fit',
              ),
            },
            success: false,
            stage: RunStage.compile,
            compileErrorsIn: 'tests',
            reason: 'tests_dont_fit',
            stderr: 'error[E0425]: cannot find function `is_adult`',
          ),
        ),
      );

      await run(tester);

      expect(find.text(en.testsCantUseYourCode), findsOneWidget);
      expect(find.byType(TestsPanel), findsOneWidget);
      // The generated tests' compiler text is not shown as the learner's.
      expect(find.textContaining('E0425'), findsNothing);
      expect(state.isCompleted('graded'), isFalse);
    });

    testWidgets('errors in the learner code show the compiler, no panel', (
      tester,
    ) async {
      await open(
        tester,
        'graded',
        FakeRunner(
          dummy,
          graded: _graded(
            {
              'fifteen-too-young': const TestResult(
                id: 'fifteen-too-young',
                status: TestStatus.notRun,
              ),
            },
            success: false,
            stage: RunStage.compile,
            compileErrorsIn: 'code',
            stderr: 'error: expected one of `;`',
          ),
        ),
      );

      await run(tester);

      expect(find.byType(TestsPanel), findsNothing);
      expect(find.textContaining('expected one of'), findsWidgets);
      expect(state.isCompleted('graded'), isFalse);
    });

    for (final (name, message) in [
      ('unavailable', 'Offline'),
      ('needs an update', en.runIssueRunnerNeedsUpdate),
      ('busy', "You're running code very quickly. Try again in a minute."),
    ]) {
      testWidgets('a runner that is $name: message, no panel, not solved', (
        tester,
      ) async {
        await open(
          tester,
          'graded',
          FakeRunner(dummy, graded: GradeResult.unavailable(message)),
        );

        await run(tester);

        expect(find.byType(TestsPanel), findsNothing);
        expect(find.textContaining(message), findsWidgets);
        expect(find.text('Correct! Nice work.'), findsNothing);
        expect(find.text('Not quite yet. Keep trying.'), findsNothing);
        expect(state.isCompleted('graded'), isFalse);
      });
    }

    testWidgets(
      'a legacy exercise is one test with a plain label, from a plain run',
      (tester) async {
        await open(
          tester,
          'legacy',
          FakeRunner(
            const RunResult(success: true, stage: RunStage.run, stdout: 'ho\n'),
          ),
        );

        await run(tester);

        // A legacy exercise is a plain run, compared in the app.
        expect(runner.gradeRequests, isEmpty);
        expect(find.text('Tests: 0 of 1 passed'), findsOneWidget);
        expect(
          find.textContaining(en.legacyOutputLabel, findRichText: true),
          findsOneWidget,
        );
        expect(state.isCompleted('legacy'), isFalse);
      },
    );

    testWidgets('a legacy exercise is solved by the right output', (
      tester,
    ) async {
      await open(
        tester,
        'legacy',
        FakeRunner(
          const RunResult(success: true, stage: RunStage.run, stdout: 'hi\n'),
        ),
      );

      await run(tester);

      expect(find.text('Tests: 1 of 1 passed'), findsOneWidget);
      expect(state.isCompleted('legacy'), isTrue);
    });
  });

  test('the panel text uses the code font from the theme', () {
    // A guard so the panel's monospace text stays tied to one definition.
    expect(codeTextStyle.fontFamily, isNotNull);
  });
}

class _FakeAuth implements RunnerAuth {
  _FakeAuth(this._tokens);
  final List<String?> _tokens;

  @override
  Future<String?> appCheckToken({bool refresh = false}) async =>
      _tokens.isEmpty ? null : _tokens.removeAt(0);
}
