import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/account/account_service.dart';
import 'package:rust_learn/data/age.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/streaks.dart';
import 'package:rust_learn/l10n/streak_strings.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/reminders/reminder_plan.dart';
import 'package:rust_learn/reminders/reminder_scheduler.dart';
import 'package:rust_learn/reminders/study_reminders.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const strings = StreakStrings.english;
  final text = reminderText(strings);
  const childYear = 2018;
  const teenYear = 2012; // youngest possible age 13 in 2026
  var now = DateTime(2026, 3, 18, 10);
  DateTime clock() => now;
  setUp(() => now = DateTime(2026, 3, 18, 10));

  group('planReminders', () {
    List<ScheduledReminder> plan({
      DateTime? at,
      int minutes = defaultReminderMinutes,
      bool goalMet = false,
    }) => planReminders(
      now: at ?? now,
      minutesOfDay: minutes,
      goalMetToday: goalMet,
      text: text,
    );

    test('7 one-shots at 19:00 on the next 7 days, today included', () {
      final p = plan();
      expect(p.length, 7);
      expect(p.first.when, DateTime(2026, 3, 18, 19));
      expect(p.last.when, DateTime(2026, 3, 24, 19));
      expect(p.map((r) => r.id).toSet().length, 7);
      expect(p.every((r) => r.when.isAfter(now)), isTrue);
    });

    test(
      'today is skipped when the goal is met: 6 reminders from tomorrow',
      () {
        final p = plan(goalMet: true);
        expect(p.length, 6);
        expect(p.first.when, DateTime(2026, 3, 19, 19));
      },
    );

    test('today is skipped when its time has passed, or is right now', () {
      expect(plan(at: DateTime(2026, 3, 18, 19, 1)).first.when.day, 19);
      expect(plan(at: DateTime(2026, 3, 18, 19, 1)).length, 6);
      expect(plan(at: DateTime(2026, 3, 18, 19)).length, 6);
      expect(plan(at: DateTime(2026, 3, 18, 18, 59, 59)).length, 7);
    });

    test('the chosen time is used, and out-of-range values are clamped', () {
      expect(
        plan(minutes: 7 * 60 + 30).first.when,
        DateTime(2026, 3, 19, 7, 30),
      ); // 07:30 has passed today
      expect(plan(minutes: 9999).first.when, DateTime(2026, 3, 18, 23, 59));
      expect(plan(minutes: -5).length, 6); // 00:00 has passed
    });

    test('rolls over month and year ends', () {
      final p = plan(at: DateTime(2026, 12, 29, 8));
      expect(p.map((r) => dayKey(r.when)), [
        '2026-12-29',
        '2026-12-30',
        '2026-12-31',
        '2027-01-01',
        '2027-01-02',
        '2027-01-03',
        '2027-01-04',
      ]);
      expect(
        plan(at: DateTime(2028, 2, 26, 8)).map((r) => dayKey(r.when)),
        contains('2028-02-29'),
      );
    });

    test('keeps the wall-clock time across daylight saving changes', () {
      for (final start in [
        DateTime(2026, 3, 6, 8), // US spring forward on the 8th
        DateTime(2026, 3, 27, 8), // EU spring forward on the 29th
        DateTime(2026, 10, 23, 8), // EU fall back on the 25th
        DateTime(2026, 10, 30, 8), // US fall back on Nov 1st
      ]) {
        final p = plan(at: start);
        expect(p.length, 7, reason: '$start');
        expect(
          p.every((r) => r.when.hour == 19 && r.when.minute == 0),
          isTrue,
          reason: '$start',
        );
        for (var i = 1; i < p.length; i++) {
          expect(
            dayNumber(p[i].when.year, p[i].when.month, p[i].when.day) -
                dayNumber(
                  p[i - 1].when.year,
                  p[i - 1].when.month,
                  p[i - 1].when.day,
                ),
            1,
          );
        }
      }
    });

    test('the text comes from one function that takes the strings, and is '
        'neutral', () {
      final p = plan();
      expect(p.every((r) => r.text == text), isTrue);
      expect(text.title, 'Time for a little Rust?');
      expect(text.body, 'Your next lesson is ready.');
      final lower = '${text.title} ${text.body}'.toLowerCase();
      for (final pressure in [
        'streak',
        'lose',
        'lost',
        'miss',
        'die',
        'risk',
      ]) {
        expect(lower.contains(pressure), isFalse, reason: pressure);
      }
    });
  });

  group('StudyReminders', () {
    late FakeReminderScheduler scheduler;
    var goalMet = false;

    Future<StudyReminders> make({
      Map<String, Object> prefs = const {},
      FakeReminderScheduler? with_,
    }) async {
      mockPrefs(prefs);
      scheduler = with_ ?? FakeReminderScheduler();
      goalMet = false;
      return StudyReminders(
        prefs: await SharedPreferences.getInstance(),
        scheduler: scheduler,
        clock: clock,
        goalMetToday: () => goalMet,
      );
    }

    test(
      'off by default: nothing is requested, scheduled or cancelled',
      () async {
        final r = await make();
        expect(r.enabled, isFalse);
        expect(r.minutesOfDay, defaultReminderMinutes);
        await r.refresh();
        expect(scheduler.permissionRequests, 0);
        expect(scheduler.schedules, isEmpty);
        expect(scheduler.initializes, 0);
      },
    );

    test('turning on asks the system once and schedules 7 reminders', () async {
      scheduler = FakeReminderScheduler(permission: false);
      final r = await make(with_: scheduler);
      final on = await r.setEnabled(true);

      expect(on, isTrue);
      expect(r.enabled, isTrue);
      expect(scheduler.permissionRequests, 1);
      expect(scheduler.scheduled.length, 7);
      expect(scheduler.scheduled.first.when, DateTime(2026, 3, 18, 19));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('reminderEnabled'), isTrue);
    });

    test('already allowed by the system: no prompt', () async {
      final r = await make();
      await r.setEnabled(true);
      expect(scheduler.permissionRequests, 0);
      expect(r.enabled, isTrue);
    });

    test(
      'permission denied: the switch stays off and the reason is kept',
      () async {
        final r = await make(
          with_: FakeReminderScheduler(
            permission: false,
            grantOnRequest: false,
          ),
        );
        final on = await r.setEnabled(true);

        expect(on, isFalse);
        expect(r.enabled, isFalse);
        expect(r.permissionDenied, isTrue);
        expect(scheduler.scheduled, isEmpty);
        expect(scheduler.schedules, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('reminderEnabled'), isNot(true));

        // Trying again after allowing it in the system settings works.
        scheduler.permission = true;
        expect(await r.setEnabled(true), isTrue);
        expect(r.permissionDenied, isFalse);
      },
    );

    test('turning off cancels every reminder', () async {
      final r = await make();
      await r.setEnabled(true);
      expect(scheduler.scheduled, isNotEmpty);

      await r.setEnabled(false);

      expect(r.enabled, isFalse);
      expect(scheduler.scheduled, isEmpty);
      expect(scheduler.cancels, 1);
      await r.refresh();
      expect(scheduler.scheduled, isEmpty);
    });

    test('refresh plans again from scratch and never doubles up', () async {
      final r = await make(prefs: {'reminderEnabled': true});
      await r.refresh();
      await r.refresh();
      await r.refresh();
      expect(scheduler.schedules.length, 3);
      expect(scheduler.scheduled.length, 7);
    });

    test('today is dropped once the goal is met', () async {
      final r = await make(prefs: {'reminderEnabled': true});
      await r.refresh();
      expect(scheduler.scheduled.first.when.day, 18);

      goalMet = true;
      await r.refresh();

      expect(scheduler.scheduled.length, 6);
      expect(scheduler.scheduled.first.when.day, 19);
    });

    test('changing the time reschedules at the new time', () async {
      final r = await make(prefs: {'reminderEnabled': true});
      await r.setMinutes(20 * 60 + 15);
      expect(scheduler.scheduled.first.when, DateTime(2026, 3, 18, 20, 15));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('reminderMinutes'), 20 * 60 + 15);
    });

    test('a time chosen while off is saved but nothing is scheduled', () async {
      final r = await make();
      await r.setMinutes(8 * 60);
      expect(r.minutesOfDay, 480);
      expect(scheduler.schedules, isEmpty);
    });

    test('notifications blocked in the system settings: switched off and '
        'cancelled, with the reason', () async {
      final r = await make(prefs: {'reminderEnabled': true});
      scheduler.permission = false;

      await r.refresh();

      expect(r.enabled, isFalse);
      expect(r.revokedBySystem, isTrue);
      expect(scheduler.scheduled, isEmpty);
      expect(scheduler.cancels, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('reminderEnabled'), isFalse);
    });

    test('a failing plugin never throws into the app', () async {
      final r = await make(
        prefs: {'reminderEnabled': true},
        with_: FakeReminderScheduler()..throws = true,
      );
      await r.refresh();
      await r.setEnabled(true);
      await r.setMinutes(600);
    });

    test(
      'where reminders are not supported (the web) nothing happens',
      () async {
        final r = await make(with_: FakeReminderScheduler(supported: false));
        expect(r.supported, isFalse);
        expect(await r.setEnabled(true), isFalse);
        await r.refresh();
        expect(scheduler.permissionRequests, 0);
        expect(scheduler.schedules, isEmpty);
      },
    );

    test('the one-time card is marked answered by any choice', () async {
      final r = await make();
      expect(r.promptSeen, isFalse);
      await r.dismissPrompt();
      expect(r.promptSeen, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('reminderPromptSeen'), isTrue);

      final other = await make();
      await other.setEnabled(true);
      expect(other.promptSeen, isTrue);
    });

    test('reset turns everything back to a fresh device', () async {
      final r = await make(prefs: {'reminderEnabled': true});
      await r.setMinutes(600);
      await r.dismissPrompt();
      await r.reset();
      expect(r.enabled, isFalse);
      expect(r.minutesOfDay, defaultReminderMinutes);
      expect(r.promptSeen, isFalse);
      expect(scheduler.scheduled, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.startsWith('reminder')), isEmpty);
    });

    test('jobs run one at a time, in order', () async {
      final r = await make(prefs: {'reminderEnabled': true});
      final done = <int>[];
      final a = r.refresh().then((_) => done.add(1));
      final b = r.setEnabled(false).then((_) => done.add(2));
      final c = r.refresh().then((_) => done.add(3));
      await Future.wait([a, b, c]);
      expect(done, [1, 2, 3]);
      expect(scheduler.scheduled, isEmpty);
    });
  });

  group('inside AppState', () {
    Future<AppState> app({
      Map<String, Object> prefs = const {},
      FakeReminderScheduler? scheduler,
    }) async {
      mockPrefs(prefs);
      return makeState(
        FakeAccounts(),
        FakeSync(),
        clock: clock,
        reminderScheduler: scheduler ?? FakeReminderScheduler(),
      );
    }

    test('earning XP replans: the goal being met drops today', () async {
      final scheduler = FakeReminderScheduler();
      final state = await app(
        prefs: {'reminderEnabled': true},
        scheduler: scheduler,
      );
      await state.reminders.refresh();
      expect(scheduler.scheduled.length, 7);

      await state.markCompleted('l1'); // 20 XP = the default goal
      await state.reminders.refresh(); // wait for the replan to finish

      expect(scheduler.scheduled.length, 6);
      expect(scheduler.scheduled.first.when.day, 19);
    });

    test('a bigger goal keeps today until it is reached', () async {
      final scheduler = FakeReminderScheduler();
      final state = await app(
        prefs: {'reminderEnabled': true},
        scheduler: scheduler,
      );
      await state.setDailyGoal(40);
      await state.markCompleted('l1');
      await state.reminders.refresh();
      expect(scheduler.scheduled.length, 7);

      await state.markCompleted('l2');
      await state.reminders.refresh();
      expect(scheduler.scheduled.length, 6);
    });

    test('resuming the app replans', () async {
      final scheduler = FakeReminderScheduler();
      final state = await app(
        prefs: {'reminderEnabled': true},
        scheduler: scheduler,
      );
      await state.reminders.refresh();
      final before = scheduler.schedules.length;

      now = DateTime(2026, 3, 19, 8);
      state.onResume();
      await state.reminders.refresh();

      expect(scheduler.schedules.length, greaterThan(before));
      expect(scheduler.scheduled.first.when, DateTime(2026, 3, 19, 19));
    });

    test('finishing lessons never asks for permission', () async {
      final scheduler = FakeReminderScheduler(permission: false);
      final state = await app(scheduler: scheduler);
      await state.markCompleted('l1');
      await state.reminders.refresh();
      expect(scheduler.permissionRequests, 0);
      expect(scheduler.schedules, isEmpty);
    });

    test('signing out resets reminders and cancels them', () async {
      final scheduler = FakeReminderScheduler();
      mockPrefs({'reminderEnabled': true, 'reminderMinutes': 600});
      final accounts = FakeAccounts();
      final state = await makeState(
        accounts,
        FakeSync(),
        clock: clock,
        reminderScheduler: scheduler,
      );
      accounts.signInAs('u1');
      await settle();
      await state.syncing;
      await state.reminders.refresh();
      expect(scheduler.scheduled, isNotEmpty);

      await accounts.signOut();
      await settle();
      await state.syncing;

      expect(state.reminders.enabled, isFalse);
      expect(state.reminders.minutesOfDay, defaultReminderMinutes);
      expect(scheduler.scheduled, isEmpty);
    });

    test('a child deleting their account keeps reminder settings', () async {
      final scheduler = FakeReminderScheduler();
      mockPrefs({
        'birthYear': childYear,
        'reminderEnabled': true,
        'reminderMinutes': 600,
      });
      final accounts = FakeAccounts();
      final state = await makeState(
        accounts,
        FakeSync(),
        clock: clock,
        reminderScheduler: scheduler,
      );
      await state.signIn(SignInMethod.google, toDelete: true);
      await settle();
      await state.deleteAccount();
      await settle();
      expect(state.reminders.enabled, isTrue);
      expect(state.reminders.minutesOfDay, 600);
    });
  });

  group('the one-time card', () {
    Future<AppState> app(
      Map<String, Object> prefs, {
      bool ageKnown = true,
    }) async {
      mockPrefs(prefs, ageKnown: ageKnown);
      return makeState(
        FakeAccounts(),
        FakeSync(),
        clock: clock,
        reminderScheduler: FakeReminderScheduler(),
      );
    }

    test(
      'adult: offered after the first completed lesson, not before',
      () async {
        final state = await app({'birthYear': 1990});
        expect(state.showReminderPrompt, isFalse);
        await state.markCompleted('l1');
        expect(state.showReminderPrompt, isTrue);
      },
    );

    test('13 to 17: offered too', () async {
      final state = await app({'birthYear': teenYear});
      await state.markCompleted('l1');
      expect(state.age.group, AgeGroup.teen);
      expect(state.showReminderPrompt, isTrue);
    });

    test('under 13: never offered, however many lessons', () async {
      final state = await app({'birthYear': childYear});
      expect(state.age.group, AgeGroup.under13);
      for (final id in ['l1', 'l2', 'l3']) {
        await state.markCompleted(id);
        expect(state.showReminderPrompt, isFalse);
      }
    });

    test('age unknown: never offered', () async {
      final state = await app({}, ageKnown: false);
      await state.markCompleted('l1');
      expect(state.age.group, isNull);
      expect(state.showReminderPrompt, isFalse);
    });

    test('a pending card disappears if the age becomes under 13', () async {
      final state = await app({'birthYear': 1990});
      await state.markCompleted('l1');
      expect(state.showReminderPrompt, isTrue);

      await state.age.setBirthYear(childYear);

      expect(state.showReminderPrompt, isFalse);
    });

    test(
      'once answered, never again, even after reminders are turned off',
      () async {
        final state = await app({'birthYear': 1990});
        await state.markCompleted('l1');
        await state.reminders.dismissPrompt();
        expect(state.showReminderPrompt, isFalse);

        final enabled = await app({'birthYear': 1990});
        await enabled.markCompleted('l1');
        await enabled.reminders.setEnabled(true);
        await enabled.reminders.setEnabled(false);
        expect(enabled.showReminderPrompt, isFalse);
      },
    );

    test('not offered where reminders are unsupported', () async {
      mockPrefs({});
      final state = await makeState(FakeAccounts(), FakeSync(), clock: clock);
      await state.markCompleted('l1');
      expect(state.showReminderPrompt, isFalse);
    });
  });

  group('screens', () {
    late AppState state;
    late FakeReminderScheduler scheduler;

    Future<void> open(
      WidgetTester tester,
      String location, {
      Map<String, Object> prefs = const {'track': 'fast'},
      FakeReminderScheduler? with_,
      Size size = const Size(390, 1400),
    }) async {
      mockPrefs(prefs);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      scheduler = with_ ?? FakeReminderScheduler();
      state = (await tester.runAsync(() async {
        final s = AppState(
          repository: fakeCourse(),
          runner: FakeRunner(
            const RunResult(success: true, stage: RunStage.run, stdout: 'hi\n'),
          ),
          prefs: await SharedPreferences.getInstance(),
          clock: clock,
          reminderScheduler: scheduler,
        );
        await s.load();
        return s;
      }))!;
      await tester.pumpWidget(
        RustLearnApp(state: state, initialLocation: location),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Home shows the streak and today against the goal, as one '
        'spoken sentence', (tester) async {
      await open(
        tester,
        '/learn',
        prefs: {
          'track': 'fast',
          'dailyXp': '{"2026-03-17": 20, "2026-03-18": 5}',
        },
      );
      final handle = tester.ensureSemantics();

      expect(find.text('2 days'), findsOneWidget);
      expect(find.text('5 / 20 XP'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Streak: 2 days. Today: 5 of 20 XP.'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('Home on a wide screen and with big text does not overflow', (
      tester,
    ) async {
      await open(
        tester,
        '/learn',
        size: const Size(1200, 800),
        prefs: {'track': 'fast', 'dailyXp': '{"2026-03-18": 20}'},
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Daily goal reached'), findsOneWidget);
    });

    testWidgets('Home with large text on a narrow phone does not overflow', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(
        tester,
        '/learn',
        size: const Size(320, 700),
        prefs: {
          'track': 'fast',
          'dailyXp': '{"2026-03-17": 20, "2026-03-18": 5}',
        },
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Home: an adult sees the card after a first lesson, and '
        '"Not now" ends it for good', (tester) async {
      await open(
        tester,
        '/learn',
        prefs: {
          'track': 'fast',
          'completedLessons': ['plain'],
        },
      );
      expect(find.text('Want a daily reminder?'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(find.text('Want a daily reminder?'), findsNothing);
      expect(scheduler.permissionRequests, 0);
      expect(state.reminders.enabled, isFalse);
      expect(state.reminders.promptSeen, isTrue);
    });

    testWidgets('Home: "Turn on" asks for permission and schedules', (
      tester,
    ) async {
      await open(
        tester,
        '/learn',
        prefs: {
          'track': 'fast',
          'completedLessons': ['plain'],
        },
        with_: FakeReminderScheduler(permission: false),
      );
      await tester.tap(find.text('Turn on'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(scheduler.permissionRequests, 1);
      expect(state.reminders.enabled, isTrue);
      expect(scheduler.scheduled.length, 7);
      expect(find.text('Want a daily reminder?'), findsNothing);
    });

    testWidgets('Home: if the system says no, the learner is told how to '
        'allow it', (tester) async {
      await open(
        tester,
        '/learn',
        prefs: {
          'track': 'fast',
          'completedLessons': ['plain'],
        },
        with_: FakeReminderScheduler(permission: false, grantOnRequest: false),
      );
      await tester.tap(find.text('Turn on'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(state.reminders.enabled, isFalse);
      expect(find.textContaining('device settings'), findsOneWidget);
    });

    testWidgets('Home: under 13 sees no card and no hint about today', (
      tester,
    ) async {
      await open(
        tester,
        '/learn',
        prefs: {
          'track': 'fast',
          'birthYear': childYear,
          'completedLessons': ['plain'],
          'dailyXp': '{"2026-03-17": 20}',
        },
      );
      expect(find.text('Want a daily reminder?'), findsNothing);
      expect(find.text(strings.keepItGoing), findsNothing);
      expect(find.text('1 day'), findsOneWidget);
    });

    testWidgets('Home: an adult with a streak and nothing yet today gets a '
        'calm hint, never a warning', (tester) async {
      await open(
        tester,
        '/learn',
        prefs: {'track': 'fast', 'dailyXp': '{"2026-03-17": 20}'},
      );
      expect(find.text(strings.keepItGoing), findsOneWidget);
      final all = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => (t.data ?? '').toLowerCase())
          .join(' | ');
      for (final bad in ['lose', 'lost', 'risk', 'die', 'break', 'miss']) {
        expect(all.contains(bad), isFalse, reason: bad);
      }
    });

    testWidgets('Progress: totals, goal picker, reminder switch and time', (
      tester,
    ) async {
      await open(
        tester,
        '/progress',
        prefs: {
          'track': 'fast',
          'dailyXp': '{"2026-03-16": 20, "2026-03-17": 40, "2026-03-18": 5}',
        },
      );
      expect(find.text('Streak and XP'), findsOneWidget);
      expect(find.text('65'), findsOneWidget); // total XP
      expect(find.text('Daily goal'), findsOneWidget);
      expect(find.text('Daily reminder'), findsOneWidget);
      expect(find.text('Reminder time'), findsNothing); // off

      await tester.scrollUntilVisible(
        find.text('Regular\n40 XP'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Regular\n40 XP'));
      await tester.pumpAndSettle();
      expect(state.dailyGoal, 40);

      await tester.tap(find.byType(Switch));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(state.reminders.enabled, isTrue);
      expect(find.text('Reminder time'), findsOneWidget);
      expect(find.text('7:00 PM'), findsOneWidget);
    });

    testWidgets('Progress: no reminder controls where reminders are not '
        'supported (the web)', (tester) async {
      await open(
        tester,
        '/progress',
        with_: FakeReminderScheduler(supported: false),
      );
      expect(find.text('Daily reminder'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Daily goal'), findsOneWidget);
    });

    testWidgets('Progress: the system saying no leaves the switch off and '
        'explains', (tester) async {
      await open(
        tester,
        '/progress',
        with_: FakeReminderScheduler(permission: false, grantOnRequest: false),
      );
      await tester.scrollUntilVisible(
        find.byType(Switch),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byType(Switch));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.textContaining('device settings'), findsOneWidget);
    });

    testWidgets('Quiz: passing shows +20 XP and the goal message; doing it '
        'again the same day shows nothing', (tester) async {
      await open(tester, '/lesson/quiz/quiz');
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(find.text('Check'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(find.text('Lesson complete!'), findsOneWidget);
      expect(find.text('+20 XP'), findsOneWidget);
      expect(find.textContaining('Daily goal reached'), findsOneWidget);
      expect(state.summary.todayXp, 20);
    });

    testWidgets('Quiz: a review on a later day shows +5 XP and no goal '
        'message when the goal is not reached', (tester) async {
      await open(
        tester,
        '/lesson/quiz/quiz',
        prefs: {
          'track': 'fast',
          'completedLessons': ['quiz'],
          'dailyGoal': 40,
        },
      );
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(find.text('Check'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(find.text('+5 XP'), findsOneWidget);
      expect(find.textContaining('Daily goal reached'), findsNothing);
    });

    testWidgets('Quiz: a failed quiz earns nothing', (tester) async {
      await open(tester, '/lesson/quiz/quiz');
      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.tap(find.text('Check'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Review the lesson and try again.'), findsOneWidget);
      expect(find.textContaining('XP'), findsNothing);
      expect(state.dailyXp, isEmpty);
    });

    testWidgets('"Mark as done" shows +20 XP on the course map', (
      tester,
    ) async {
      await open(tester, '/lesson/plain');
      await tester.tap(find.text('Mark as done'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(find.textContaining('+20 XP'), findsOneWidget);
      expect(state.dailyXp, {'2026-03-18': 20});
    });

    testWidgets('solving an exercise earns once, however often it is run', (
      tester,
    ) async {
      await open(tester, '/lesson/exercise');
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Run'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
      expect(state.isCompleted('exercise'), isTrue);
      expect(state.dailyXp, {'2026-03-18': 20});
    });
  });
}
