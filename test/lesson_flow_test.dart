import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/app/router.dart';
import 'package:rust_learn/data/app_state.dart';

import 'dart:async';

import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/features/editor/code_editor.dart';
import 'package:rust_learn/l10n/app_localizations_en.dart';
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
    mockPrefs(prefs);
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

  TextEditingValue v(String text, int start, [int? end]) => TextEditingValue(
    text: text,
    selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
  );

  test('Tab indents selected lines, Shift+Tab outdents them (F9)', () {
    const code = 'fn main() {\nlet a = 1;\nlet b = 2;\n}';
    // Select from inside line 2 to inside line 3.
    final indented = indentLines(v(code, 14, 25));
    expect(indented.text, 'fn main() {\n    let a = 1;\n    let b = 2;\n}');
    expect(indented.selection.start, 18);
    expect(indented.selection.end, 33);

    final back = outdentLines(indented);
    expect(back.text, code);
    expect(back.selection.start, 14);
    expect(back.selection.end, 25);

    // A selection ending at the start of a line leaves that line alone.
    final twoLines = indentLines(v('a\nb\nc', 0, 4));
    expect(twoLines.text, '    a\n    b\nc');

    // Outdent removes at most four spaces, and only spaces.
    expect(outdentLines(v('      x\n  y\nz', 0, 13)).text, '  x\ny\nz');
    // No selection: Tab inserts spaces at the cursor.
    expect(indentLines(v('ab', 1)).text, 'a    b');
  });

  testWidgets('Shift+Tab without a selection leaves the editor (F9)', (
    tester,
  ) async {
    await open(tester, '/playground');
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    final before = controller.text;
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.text, before);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('Ctrl+Enter runs the code (F9)', (tester) async {
    await open(
      tester,
      '/playground',
      runResult: const RunResult(
        success: true,
        stage: RunStage.run,
        stdout: 'ran',
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('ran'), findsOneWidget);
  });

  testWidgets(
    'every run is announced with its output, verdict on its own (F5)',
    (tester) async {
      await open(
        tester,
        '/lesson/exercise',
        runResult: const RunResult(
          success: true,
          stage: RunStage.run,
          stdout: 'hi\n',
        ),
      );
      final handle = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(supportsAnnounce: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      tester.takeAnnouncements();

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      final said = tester.takeAnnouncements().map((a) => a.message).toList();
      expect(said, [
        'Output: hi Correct! Nice work.',
        'Output: hi Correct! Nice work.',
      ]);

      final verdict = tester.getSemantics(find.text('Correct! Nice work.'));
      expect(verdict.label, 'Correct! Nice work.');
      handle.dispose();
    },
  );

  test('compile errors and failures are announced too (F5)', () {
    expect(
      runAnnouncement(
        AppLocalizationsEn(),
        const RunResult(
          success: false,
          stage: RunStage.compile,
          stderr: 'error[E0308]: mismatched types',
        ),
      ),
      "Your code didn't compile. error[E0308]: mismatched types",
    );
    expect(
      runAnnouncement(
        AppLocalizationsEn(),
        const RunResult(success: true, stage: RunStage.run, warnings: 'w'),
      ),
      'Your program ran with no output. There are compiler warnings.',
    );
  });

  CourseRepository longLesson() => fakeCourse(
    extraFiles: {
      'assets/content/lessons/long.json':
          '''
{"id": "long", "title": "Long",
 "sections": [${List.generate(40, (i) => '{"type": "text", "text": "Paragraph $i"}').join(',')}],
 "exercise": {"prompt": "Print hi", "starter": "fn main() {}", "expectedOutput": "hi"}}
''',
    },
  );

  testWidgets('the exercise code survives scrolling away and back (F7)', (
    tester,
  ) async {
    await open(tester, '/lesson/long', repository: longLesson());
    tester.view.physicalSize = const Size(390, 600);
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byType(TextField),
      300,
      scrollable: list,
    );
    await tester.enterText(
      find.byType(TextField),
      'fn main() { println!("mine"); }',
    );
    await tester.pump();
    // A focused field keeps itself alive; the learner has moved on.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('Paragraph 0'),
      -300,
      scrollable: list,
    );
    expect(
      find.byType(TextField, skipOffstage: false),
      findsOneWidget,
    ); // kept alive
    await tester.scrollUntilVisible(
      find.byType(TextField),
      300,
      scrollable: list,
    );
    expect(find.text('fn main() { println!("mine"); }'), findsOneWidget);
  });

  testWidgets(
    'a result that arrives after leaving the lesson still counts (F7)',
    (tester) async {
      final runner = _GatedRunner();
      mockPrefs({'track': 'fast'});
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(() async {
        final st = AppState(
          repository: fakeCourse(),
          runner: runner,
          prefs: await SharedPreferences.getInstance(),
        );
        await st.load();
        return st;
      }))!;
      await tester.pumpWidget(
        RustLearnApp(state: s, initialLocation: '/lesson/exercise'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run'));
      await tester.pump();
      await tester.tap(find.byTooltip('Back to lessons'));
      await tester.pumpAndSettle();
      expect(find.text('Learn Rust'), findsOneWidget);

      runner.gate.complete(
        const RunResult(success: true, stage: RunStage.run, stdout: 'hi'),
      );
      await tester.pumpAndSettle();
      expect(s.isCompleted('exercise'), isTrue);
    },
  );

  testWidgets(
    'a deep-linked lesson has a way back, also with system back (F8)',
    (tester) async {
      await open(tester, '/lesson/plain');
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue); // the app didn't close
      expect(find.text('Learn Rust'), findsOneWidget);
    },
  );

  testWidgets('a deep-linked lesson shows a button to the course map (F8)', (
    tester,
  ) async {
    await open(tester, '/lesson/plain');
    await tester.tap(find.byTooltip('Back to lessons'));
    await tester.pumpAndSettle();
    expect(find.text('Learn Rust'), findsOneWidget);
  });

  testWidgets(
    'a lesson opened from the course map keeps the normal back button',
    (tester) async {
      await open(tester, '/learn');
      await tester.tap(find.text('Basics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lesson plain'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back to lessons'), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
    },
  );

  testWidgets(
    'without announcement support, a live region changes every run (N3)',
    (tester) async {
      await open(
        tester,
        '/playground',
        runResult: const RunResult(
          success: true,
          stage: RunStage.run,
          stdout: 'hi',
        ),
      );
      final handle = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(supportsAnnounce: false);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      tester.takeAnnouncements();

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(r'^Run 1\. Output: hi')),
        findsOneWidget,
      );
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(r'^Run 2\. Output: hi')),
        findsOneWidget,
      );
      final live = tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'^Run 2\.')),
      );
      // Only the short summary: no heading or output text merged in, so
      // TalkBack doesn't read the output twice.
      expect(live.label, 'Run 2. Output: hi');
      expect(live.value, isEmpty);
      expect(live, isSemantics(isLiveRegion: true));
      // The output itself is a plain, separate node.
      expect(
        tester.getSemantics(find.text('Output')),
        isNot(isSemantics(isLiveRegion: true)),
      );
      expect(tester.takeAnnouncements(), isEmpty);
      handle.dispose();
    },
  );

  testWidgets(
    'a result arriving after sign-out does not mark the lesson (N2)',
    (tester) async {
      final runner = _GatedRunner();
      mockPrefs({'track': 'fast'});
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final accounts = FakeAccounts();
      final s = (await tester.runAsync(() async {
        final st = await makeState(
          accounts,
          FakeSync(),
          repository: fakeCourse(),
          runner: runner,
        );
        await st.load();
        return st;
      }))!;
      accounts.signInAs('u1');
      await tester.pumpWidget(
        RustLearnApp(state: s, initialLocation: '/lesson/exercise'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run'));
      await tester.pump();
      await tester.runAsync(() => s.signOut(force: true));
      await tester.pumpAndSettle();

      runner.gate.complete(
        const RunResult(success: true, stage: RunStage.run, stdout: 'hi'),
      );
      await tester.pumpAndSettle();
      expect(s.isCompleted('exercise'), isFalse);
    },
  );
}

class _GatedRunner implements CodeRunner {
  final gate = Completer<RunResult>();
  @override
  Future<RunResult> run(String source) => gate.future;
}
