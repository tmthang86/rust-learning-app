import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/error_explanations.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const _solution = 'fn main() {\n    println!("hi");\n}';

void main() {
  late AppState state;
  late FakeRunner runner;

  /// The `exercise` lesson from [fakeCourse], with hints and a solution.
  Future<void> open(
    WidgetTester tester, {
    String location = '/lesson/exercise',
    required RunResult result,
    String track = 'fast',
    List<String> hints = const [
      'Look at println',
      'Use println!',
      'Print "hi"',
    ],
  }) async {
    mockPrefs({'track': track});
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    runner = FakeRunner(result);
    state = (await tester.runAsync(() async {
      final s = AppState(
        repository: fakeCourse(
          extraFiles: {
            'assets/content/course.json': jsonEncode({
              'units': [
                {
                  'id': 'u0',
                  'number': 0,
                  'title': 'Start',
                  'summary': 's',
                  'tracks': ['starter'],
                  'lessons': [
                    {'id': 'starter-only', 'title': 'Starter only'},
                  ],
                },
                {
                  'id': 'u1',
                  'number': 1,
                  'title': 'Basics',
                  'summary': 's',
                  'tracks': ['starter', 'fast'],
                  'lessons': [
                    {'id': 'plain', 'title': 'Lesson plain'},
                    {'id': 'exercise', 'title': 'Lesson exercise'},
                  ],
                },
              ],
            }),
            'assets/content/lessons/exercise.json': jsonEncode({
              'id': 'exercise',
              'title': 'Lesson exercise',
              'sections': [
                {'type': 'text', 'text': 'Body of exercise'},
              ],
              'exercise': {
                'prompt': 'Print hi',
                'starter': 'fn main() {}',
                'expectedOutput': 'hi',
                'solution': _solution,
                'hints': hints,
              },
            }),
          },
        ),
        runner: runner,
        prefs: await SharedPreferences.getInstance(),
        errors: ErrorExplanationRepository(
          bundle: MapBundle({
            'assets/content/errors/index.json': jsonEncode([
              {
                'code': 'E0382',
                // Unknown, the current lesson, and one only the starter
                // track has: none of them is offered to a fast learner.
                'lessons': ['gone', 'exercise', 'plain', 'starter-only'],
              },
              {
                'id': 'syntax-missing-semicolon',
                'match': 'expected `;`',
                'lessons': [],
              },
            ]),
            'assets/content/errors/en.json': jsonEncode({
              'E0382': {
                'title': 'Use of moved value',
                'explanation': 'The value moved to another variable.',
                'fixes': ['Clone it.', 'Borrow it instead.'],
              },
              'syntax-missing-semicolon': {
                'title': 'Missing semicolon',
                'explanation': 'A statement needs a semicolon.',
                'fixes': ['Add a semicolon.'],
              },
            }),
          }),
        ),
      );
      await s.load();
      return s;
    }))!;
    await tester.pumpWidget(
      RustLearnApp(state: state, initialLocation: location),
    );
    await tester.pumpAndSettle();
  }

  const failed = RunResult(success: true, stage: RunStage.run, stdout: 'bye');

  Future<void> run(WidgetTester tester) async {
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
  }

  String codeText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('the editor turns off smart quotes and dashes', (tester) async {
    await open(tester, result: failed);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.smartQuotesType, SmartQuotesType.disabled);
    expect(field.smartDashesType, SmartDashesType.disabled);
  });

  group('hints', () {
    testWidgets('are revealed one at a time, in order, with a count', (
      tester,
    ) async {
      await open(tester, result: failed);
      expect(find.text('Show a hint (3 left)'), findsOneWidget);
      expect(find.textContaining('Hint 1 of 3'), findsNothing);

      await tester.tap(find.text('Show a hint (3 left)'));
      await tester.pumpAndSettle();
      expect(find.text('Hint 1 of 3: Look at println'), findsOneWidget);
      expect(find.textContaining('Hint 2 of 3'), findsNothing);

      await tester.tap(find.text('Show a hint (2 left)'));
      await tester.pumpAndSettle();
      expect(find.text('Hint 1 of 3: Look at println'), findsOneWidget);
      expect(find.text('Hint 2 of 3: Use println!'), findsOneWidget);

      await tester.tap(find.text('Show a hint (1 left)'));
      await tester.pumpAndSettle();
      expect(find.text('Hint 3 of 3: Print "hi"'), findsOneWidget);
      // None left: the button goes away.
      expect(find.textContaining('Show a hint'), findsNothing);
    });

    testWidgets('are announced through a live region (no announce support)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(supportsAnnounce: false);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await open(tester, result: failed);
      await tester.tap(find.text('Show a hint (3 left)'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.liveRegion == true &&
              (w.properties.label ?? '').startsWith('Hint 1 of 3: Look'),
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('are announced where the platform supports it', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(supportsAnnounce: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await open(tester, result: failed);
      tester.takeAnnouncements();
      await tester.tap(find.text('Show a hint (3 left)'));
      await tester.pumpAndSettle();
      expect(tester.takeAnnouncements().map((a) => a.message), [
        'Hint 1 of 3: Look at println',
      ]);
      semantics.dispose();
    });

    testWidgets('the last hint takes focus when its button goes away', (
      tester,
    ) async {
      await open(tester, result: failed, hints: const ['only one']);
      await tester.tap(find.text('Show a hint (1 left)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Show a hint'), findsNothing);
      final focus = FocusManager.instance.primaryFocus!;
      expect(
        find.descendant(
          of: find.byWidget(focus.context!.widget),
          matching: find.text('Hint 1 of 1: only one'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a lesson without hints has no hint button', (tester) async {
      await open(tester, result: failed, hints: const []);
      expect(find.textContaining('Show a hint'), findsNothing);
    });

    testWidgets('revealed hints stay after a run', (tester) async {
      await open(tester, result: failed);
      await tester.tap(find.text('Show a hint (3 left)'));
      await tester.pumpAndSettle();
      await run(tester);
      expect(find.text('Hint 1 of 3: Look at println'), findsOneWidget);
    });
  });

  group('solution', () {
    testWidgets('is not offered before a run', (tester) async {
      await open(tester, result: failed);
      expect(find.text('Show solution'), findsNothing);
    });

    testWidgets('is offered after a run that did not solve it', (tester) async {
      await open(tester, result: failed);
      await run(tester);
      expect(find.text('Show solution'), findsOneWidget);
      expect(find.text(_solution), findsNothing);

      await tester.tap(find.text('Show solution'));
      await tester.pumpAndSettle();
      expect(find.text(_solution), findsOneWidget);
      // Seeing it does not finish the lesson.
      expect(state.isCompleted('exercise'), isFalse);
      expect(find.text('Lesson complete'), findsNothing);
    });

    testWidgets('is offered after a timeout on its own', (tester) async {
      await open(
        tester,
        result: const RunResult(success: false, stage: RunStage.timeout),
      );
      await run(tester);
      expect(find.text('Show solution'), findsOneWidget);
    });

    testWidgets('is not offered after a first run that solves it', (
      tester,
    ) async {
      await open(
        tester,
        result: const RunResult(
          success: true,
          stage: RunStage.run,
          stdout: 'hi\n',
        ),
      );
      await run(tester);
      expect(find.text('Correct! Nice work.'), findsOneWidget);
      expect(find.text('Show solution'), findsNothing);
    });

    testWidgets('Put my code back undoes Copy to editor', (tester) async {
      await open(tester, result: failed);
      await tester.enterText(find.byType(TextField), 'my own code');
      await run(tester);
      await tester.tap(find.text('Show solution'));
      await tester.pumpAndSettle();
      // Nothing to undo yet.
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Put my code back'),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('Copy to editor'));
      await tester.pumpAndSettle();
      expect(codeText(tester), _solution);
      await tester.tap(find.text('Put my code back'));
      await tester.pumpAndSettle();
      expect(codeText(tester), 'my own code');
    });

    testWidgets('Put my code back survives copying twice', (tester) async {
      await open(tester, result: failed);
      await tester.enterText(find.byType(TextField), 'my own code');
      await run(tester);
      await tester.tap(find.text('Show solution'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy to editor'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'edited solution');
      await tester.tap(find.text('Copy to editor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Put my code back'));
      await tester.pumpAndSettle();
      expect(codeText(tester), 'my own code');
    });

    testWidgets('showing the solution moves focus to it', (tester) async {
      await open(tester, result: failed);
      await run(tester);
      await tester.tap(find.text('Show solution'));
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus!;
      expect(
        find.descendant(
          of: find.byWidget(focus.context!.widget),
          matching: find.text(_solution),
        ),
        findsOneWidget,
      );
    });

    testWidgets('is offered after a compile error and after a timeout', (
      tester,
    ) async {
      await open(
        tester,
        result: const RunResult(
          success: false,
          stage: RunStage.compile,
          stderr: 'error: expected `;`',
        ),
      );
      await run(tester);
      expect(find.text('Show solution'), findsOneWidget);

      runner.result = const RunResult(success: false, stage: RunStage.timeout);
      await run(tester);
      expect(find.text('Show solution'), findsOneWidget);
    });

    testWidgets('is not offered when the runner is unavailable', (
      tester,
    ) async {
      await open(tester, result: RunResult.unavailable('offline'));
      await run(tester);
      expect(find.text("Couldn't run your code"), findsOneWidget);
      expect(find.text('Show solution'), findsNothing);
    });

    testWidgets('Copy to editor replaces the code and does not run it', (
      tester,
    ) async {
      await open(tester, result: failed);
      await run(tester);
      expect(codeText(tester), 'fn main() {}');
      await tester.tap(find.text('Show solution'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy to editor'));
      await tester.pumpAndSettle();
      expect(codeText(tester), _solution);
      expect(state.isCompleted('exercise'), isFalse);

      // Running the copied (correct) program is what completes the lesson.
      runner.result = const RunResult(
        success: true,
        stage: RunStage.run,
        stdout: 'hi\n',
      );
      await run(tester);
      expect(state.isCompleted('exercise'), isTrue);
    });
  });

  group('error explanation cards', () {
    const known = RunResult(
      success: false,
      stage: RunStage.compile,
      stderr: 'error[E0382]: borrow of moved value: `s`\n --> main.rs:5:16\n',
    );

    testWidgets('show title, explanation, fixes and the official address', (
      tester,
    ) async {
      await open(tester, result: known);
      await run(tester);
      expect(find.text('What this error means'), findsOneWidget);
      expect(find.text('E0382: Use of moved value'), findsOneWidget);
      expect(find.text('The value moved to another variable.'), findsOneWidget);
      expect(find.text('Clone it.'), findsOneWidget);
      expect(find.text('Borrow it instead.'), findsOneWidget);
      expect(
        find.text('https://doc.rust-lang.org/error_codes/E0382.html'),
        findsOneWidget,
      );
      // The lesson that exists gets a button; the unknown one does not.
      expect(find.text('Review lesson: Lesson plain'), findsOneWidget);
      expect(find.textContaining('gone'), findsNothing);
      // Not the lesson the learner is in, nor one their track doesn't have.
      expect(find.text('Review lesson: Lesson exercise'), findsNothing);
      expect(find.textContaining('Starter only'), findsNothing);
    });

    testWidgets('the starter track is offered its own lessons too', (
      tester,
    ) async {
      await open(tester, result: known, track: 'starter');
      await run(tester);
      expect(find.text('Review lesson: Starter only'), findsOneWidget);
      expect(find.text('Review lesson: Lesson plain'), findsOneWidget);
      expect(find.text('Review lesson: Lesson exercise'), findsNothing);
    });

    testWidgets('a codeless error shows its title without the internal id', (
      tester,
    ) async {
      await open(
        tester,
        result: const RunResult(
          success: false,
          stage: RunStage.compile,
          stderr: 'error: expected `;`, found `println`\n --> main.rs:2:14\n',
        ),
      );
      await run(tester);
      expect(find.text('Missing semicolon'), findsOneWidget);
      expect(find.textContaining('syntax-missing-semicolon'), findsNothing);
      expect(find.textContaining('doc.rust-lang.org'), findsNothing);
    });

    testWidgets('a new failed run replaces the old cards', (tester) async {
      await open(tester, result: known);
      await run(tester);
      expect(find.text('E0382: Use of moved value'), findsOneWidget);
      runner.result = const RunResult(
        success: false,
        stage: RunStage.compile,
        stderr: 'error[E0599]: no method named `x` found\n',
      );
      await run(tester);
      expect(find.text('E0382: Use of moved value'), findsNothing);
      expect(find.text('E0599'), findsOneWidget);
    });

    testWidgets('the review button opens the lesson', (tester) async {
      await open(tester, result: known);
      await run(tester);
      await tester.tap(find.text('Review lesson: Lesson plain'));
      await tester.pumpAndSettle();
      expect(find.text('Body of plain'), findsOneWidget);
    });

    testWidgets('an unknown code shows only the code and official address', (
      tester,
    ) async {
      await open(
        tester,
        result: const RunResult(
          success: false,
          stage: RunStage.compile,
          stderr: 'error[E0599]: no method named `x` found\n',
        ),
      );
      await run(tester);
      expect(find.text('What this error means'), findsOneWidget);
      expect(find.text('E0599'), findsOneWidget);
      expect(
        find.text('https://doc.rust-lang.org/error_codes/E0599.html'),
        findsOneWidget,
      );
      expect(find.textContaining('Review lesson'), findsNothing);
    });

    testWidgets('are not shown for runs that compiled', (tester) async {
      await open(
        tester,
        result: const RunResult(
          success: true,
          stage: RunStage.run,
          // Like a panic message: the program's own stderr.
          stderr: 'error[E0382]: printed by the program',
        ),
      );
      await run(tester);
      expect(find.text('What this error means'), findsNothing);
    });

    testWidgets('also appear in the playground', (tester) async {
      await open(tester, location: '/playground', result: known);
      await run(tester);
      expect(find.text('E0382: Use of moved value'), findsOneWidget);
    });
  });
}
