import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/app/router.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  late AppState state;

  Future<void> open(
    WidgetTester tester,
    String location, {
    Map<String, Object> prefs = const {'track': 'fast'},
    CourseRepository? repository,
    RunResult? runResult,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    state = (await tester.runAsync(() async {
      final s = AppState(
        repository: repository ?? fakeCourse(),
        runner: runResult == null
            ? const PlaceholderCodeRunner()
            : FakeRunner(runResult),
        prefs: await SharedPreferences.getInstance(),
      );
      await s.load();
      return s;
    }))!;
    await tester.pumpWidget(
      RustLearnApp(state: state, initialLocation: location),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    '"Mark as done" on a deep-linked lesson goes to the course map (m15)',
    (tester) async {
      await open(tester, '/lesson/plain');
      expect(find.text('Body of plain'), findsOneWidget);

      await tester.tap(find.text('Mark as done'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(state.isCompleted('plain'), isTrue);
      expect(find.text('Learn Rust'), findsOneWidget); // the course map
    },
  );

  testWidgets('a deep link survives the first-launch track question (m15)', (
    tester,
  ) async {
    await open(tester, '/lesson/plain', prefs: const {});
    expect(find.text('Where would you like to start?'), findsOneWidget);

    await tester.tap(find.text('I already know another language'));
    await tester.pumpAndSettle();

    expect(find.text('Body of plain'), findsOneWidget);
  });

  test('only in-app paths are accepted as the place to return to', () {
    expect(safeReturnLocation('/lesson/u1-l1'), '/lesson/u1-l1');
    expect(safeReturnLocation(null), '/learn');
    expect(safeReturnLocation('https://evil.example'), '/learn');
    expect(safeReturnLocation('//evil.example'), '/learn');
    expect(safeReturnLocation('/welcome?from=/x'), '/learn');
  });

  testWidgets('quiz for a missing lesson says so instead of spinning (m16)', (
    tester,
  ) async {
    await open(tester, '/lesson/nope/quiz');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('This lesson is still being written.'), findsOneWidget);

    await tester.tap(find.text('Back to lessons'));
    await tester.pumpAndSettle();
    expect(find.text('Learn Rust'), findsOneWidget);
  });

  testWidgets('quiz for a lesson without questions says so (m16)', (
    tester,
  ) async {
    await open(tester, '/lesson/plain/quiz');
    expect(find.text("This lesson doesn't have a quiz."), findsOneWidget);
  });

  testWidgets(
    'a corrupt lesson file is reported as broken, not unwritten (m16)',
    (tester) async {
      final repo = fakeCourse(
        extraFiles: {
          'assets/content/lessons/broken.json': '{"id": "broken", "title": ',
        },
      );
      await open(tester, '/lesson/broken', repository: repo);
      expect(find.textContaining("couldn't be opened"), findsOneWidget);
      expect(find.text('This lesson is still being written.'), findsNothing);

      await open(tester, '/lesson/broken/quiz', repository: repo);
      expect(find.textContaining("couldn't be opened"), findsOneWidget);
    },
  );

  testWidgets('solving the exercise completes the lesson (m17)', (
    tester,
  ) async {
    await open(
      tester,
      '/lesson/exercise',
      runResult: const RunResult(
        success: true,
        stage: RunStage.run,
        stdout: 'hi\n',
      ),
    );
    // A lesson with an exercise is completed by solving it.
    expect(find.text('Mark as done'), findsNothing);
    expect(state.isCompleted('exercise'), isFalse);

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(find.text('Correct! Nice work.'), findsOneWidget);
    expect(state.isCompleted('exercise'), isTrue);
    expect(find.text('Lesson complete'), findsOneWidget);
  });

  testWidgets('a wrong answer does not complete the lesson (m17)', (
    tester,
  ) async {
    await open(
      tester,
      '/lesson/exercise',
      runResult: const RunResult(
        success: true,
        stage: RunStage.run,
        stdout: 'bye',
      ),
    );
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(find.text('Not quite yet. Keep trying.'), findsOneWidget);
    expect(state.isCompleted('exercise'), isFalse);
  });

  testWidgets(
    'warnings are shown apart from output; compile errors stand out',
    (tester) async {
      await open(
        tester,
        '/playground',
        runResult: const RunResult(
          success: true,
          stage: RunStage.run,
          stdout: 'hello',
          warnings: 'warning: unused variable: `x`',
        ),
      );
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Output'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(
        find.text('Compiler warnings (your program still ran)'),
        findsOneWidget,
      );
      // Folded away until asked for.
      expect(find.textContaining('unused variable'), findsNothing);
      await tester.tap(find.text('Compiler warnings (your program still ran)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('unused variable'), findsOneWidget);

      (state.runner as FakeRunner).result = const RunResult(
        success: false,
        stage: RunStage.compile,
        stderr: 'error[E0308]: mismatched types',
      );
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text("Your code didn't compile"), findsOneWidget);
      expect(find.textContaining('mismatched types'), findsOneWidget);
      expect(
        find.text('Compiler warnings (your program still ran)'),
        findsNothing,
      );
    },
  );

  testWidgets('code field: labelled, and Tab inserts four spaces (m18)', (
    tester,
  ) async {
    await open(tester, '/playground');
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('Rust code')), findsWidgets);

    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, startsWith('    fn main()'));
    expect(controller.selection.baseOffset, 4);
    // Focus stays in the editor.
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    handle.dispose();
  });

  testWidgets(
    'quiz answers say right or wrong in words, not only colour (m18)',
    (tester) async {
      await open(tester, '/lesson/quiz/quiz');
      final handle = tester.ensureSemantics();

      await tester.tap(find.text('A'));
      await tester.pump();
      expect(
        tester.getSemantics(
          find
              .ancestor(
                of: find.text('A'),
                matching: find.byType(MergeSemantics),
              )
              .first,
        ),
        matchesSemantics(
          label: 'A',
          isChecked: true,
          hasCheckedState: true,
          isInMutuallyExclusiveGroup: true,
          isSelected: true,
          hasSelectedState: true,
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );

      await tester.tap(find.text('Check'));
      await tester.pump();

      expect(find.text('Wrong, your answer'), findsOneWidget);
      expect(find.text('Correct answer'), findsOneWidget);
      expect(find.text('Not quite. The answer is: B'), findsOneWidget);
      handle.dispose();
    },
  );
}
