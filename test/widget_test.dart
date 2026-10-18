import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/data/models.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppState> _state() async {
  final state = AppState(
    repository: CourseRepository(),
    runner: const PlaceholderCodeRunner(),
    prefs: await SharedPreferences.getInstance(),
  );
  await state.load();
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('course loads and tracks filter units', () async {
    final state = await _state();
    expect(state.course!.units, isNotEmpty);

    await state.chooseTrack(Track.fast);
    expect(state.visibleUnits.any((u) => u.id == 'u0'), isFalse);

    await state.chooseTrack(Track.starter);
    expect(state.visibleUnits.first.id, 'u0');
  });

  test('sample lesson parses with exercise and quiz', () async {
    final lesson = await CourseRepository().loadLesson('u1-l1');
    expect(lesson, isNotNull);
    expect(lesson!.exercise, isNotNull);
    expect(lesson.quiz, isNotEmpty);
    expect(await CourseRepository().loadLesson('does-not-exist'), isNull);
  });

  test('every Unit 1 lesson is written and parses', () async {
    final repo = CourseRepository();
    final course = await repo.loadCourse();
    final unit1 = course.units.firstWhere((u) => u.id == 'u1');
    for (final ref in unit1.lessons) {
      final lesson = await repo.loadLesson(ref.id);
      expect(lesson, isNotNull, reason: '${ref.id} is missing');
      expect(lesson!.title, ref.title);
      expect(lesson.exercise, isNotNull, reason: '${ref.id} has no exercise');
      expect(lesson.quiz, isNotEmpty, reason: '${ref.id} has no quiz');
    }
  });

  testWidgets('first launch asks for a track, then shows the course',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = await tester.runAsync(_state);
    await tester.pumpWidget(RustLearnApp(state: state!));
    await tester.pumpAndSettle();

    expect(find.text('Where would you like to start?'), findsOneWidget);

    await tester.tap(find.text('I already know another language'));
    await tester.pumpAndSettle();

    expect(find.text('Getting started'), findsOneWidget);
    expect(find.text('Programming basics'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);

    // Tablet / web width switches to a side rail.
    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
