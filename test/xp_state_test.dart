import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/account/account_service.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/streaks.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// XP, the daily goal and streaks inside AppState: earned when a lesson is
/// finished, kept on the device, and synced exactly like the completed
/// lessons (merge, other account, sign-out, children).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const childYear = 2018;
  var now = DateTime(2026, 3, 18, 10);
  final today = '2026-03-18';
  final yesterday = '2026-03-17';
  DateTime clock() => now;

  setUp(() => now = DateTime(2026, 3, 18, 10));

  Future<void> signInAndSync(
    FakeAccounts accounts,
    AppState state,
    String uid,
  ) async {
    accounts.signInAs(uid);
    await settle();
    await state.syncing;
  }

  Future<AppState> signedOut([FakeSync? sync, FakeAccounts? accounts]) =>
      makeState(accounts ?? FakeAccounts(), sync ?? FakeSync(), clock: clock);

  group('earning XP', () {
    test('a first finish earns 20, shown in today and the total', () async {
      mockPrefs({});
      final state = await signedOut();

      final award = await state.markCompleted('l1');

      expect(award, const XpAward(xp: 20, goalReached: true));
      expect(state.dailyXp, {today: 20});
      expect(state.summary.todayXp, 20);
      expect(state.summary.totalXp, 20);
      expect(state.summary.currentStreak, 1);
    });

    test(
      'finishing a done lesson again on a later day is a review: 5',
      () async {
        mockPrefs({});
        final state = await signedOut();
        await state.markCompleted('l1');

        now = DateTime(2026, 3, 19, 9);
        final award = await state.markCompleted('l1');

        expect(award.xp, xpReview);
        expect(state.dailyXp, {today: 20, '2026-03-19': 5});
        expect(state.summary.currentStreak, 2);
        expect(state.completedLessons, {'l1'});
      },
    );

    test('a lesson earns XP once per day: repeats of the same finish '
        '(a solved exercise run again, then the quiz) add nothing', () async {
      mockPrefs({});
      final state = await signedOut();
      expect((await state.markCompleted('l1')).xp, 20);
      expect((await state.markCompleted('l1')).xp, 0);
      expect((await state.markCompleted('l1')).xp, 0);
      expect(state.dailyXp, {today: 20});
      // Another lesson still earns.
      expect((await state.markCompleted('l2')).xp, 20);
      expect(state.dailyXp, {today: 40});
    });

    test('the once-a-day rule survives a restart', () async {
      mockPrefs({});
      final first = await signedOut();
      await first.markCompleted('l1');

      final second = await signedOut();
      expect((await second.markCompleted('l1')).xp, 0);
      expect(second.dailyXp, {today: 20});
    });

    test(
      'the goal-reached flag is set once, by the award that crosses it',
      () async {
        mockPrefs({});
        final state = await signedOut();
        await state.setDailyGoal(40);
        final a = await state.markCompleted('l1');
        final b = await state.markCompleted('l2');
        final c = await state.markCompleted('l3');
        expect(a.goalReached, isFalse);
        expect(b.goalReached, isTrue);
        expect(c.goalReached, isFalse);
        expect(state.summary.goalMet(state.dailyGoal), isTrue);
      },
    );

    test('XP and the goal are saved on the device', () async {
      mockPrefs({});
      final state = await signedOut();
      await state.setDailyGoal(60);
      await state.markCompleted('l1');

      final again = await signedOut();
      expect(again.dailyGoal, 60);
      expect(again.dailyXp, {today: 20});
      expect(again.summary.totalXp, 20);
    });

    test('the daily goal defaults to 20 and only accepts the three '
        'choices', () async {
      mockPrefs({});
      final state = await signedOut();
      expect(state.dailyGoal, 20);
      await state.setDailyGoal(30);
      expect(state.dailyGoal, 20);
      await state.setDailyGoal(40);
      expect(state.dailyGoal, 40);
    });

    test('a bad stored goal or log falls back instead of failing', () async {
      mockPrefs({'dailyGoal': 35, 'dailyXp': 'not json {'});
      final state = await signedOut();
      expect(state.dailyGoal, 20);
      expect(state.dailyXp, isEmpty);

      mockPrefs({
        'dailyXp': '{"2026-03-18": 20, "junk": 5, "2026-03-17": "x"}',
      });
      final other = await signedOut();
      expect(other.dailyXp, {today: 20});
    });

    test('the summary follows the clock past midnight', () async {
      mockPrefs({});
      final state = await signedOut();
      await state.markCompleted('l1');
      expect(state.summary.todayXp, 20);

      now = DateTime(2026, 3, 19, 0, 5);
      expect(state.summary.todayXp, 0);
      expect(state.summary.currentStreak, 1); // yesterday still counts

      now = DateTime(2026, 3, 21, 8);
      expect(state.summary.currentStreak, 0);
      expect(state.summary.longestStreak, 1);
    });

    test('a clock set into the past does not break anything', () async {
      mockPrefs({'dailyXp': '{"2026-03-18": 20, "2026-03-17": 20}'});
      final state = await signedOut();
      now = DateTime(2026, 3, 1);
      expect(state.summary.currentStreak, 0);
      expect(state.summary.totalXp, 40);
    });
  });

  group('syncing XP', () {
    test(
      'signed in: a finished lesson sends only that day, as its total',
      () async {
        mockPrefs({});
        final accounts = FakeAccounts();
        final sync = FakeSync();
        final state = await signedOut(sync, accounts);
        await signInAndSync(accounts, state, 'u1');
        sync.xpWrites.clear();

        await state.markCompleted('l1');
        await state.markCompleted('l2');
        await settle();

        expect(sync.xpWrites, [
          {today: 20},
          {today: 40},
        ]);
        expect(sync.dailyXp, {today: 40});
        expect(sync.completed, {'l1', 'l2'});
      },
    );

    test(
      'a review sends nothing extra for the lesson list but the XP',
      () async {
        mockPrefs({
          'completedLessons': ['l1'],
        });
        final accounts = FakeAccounts();
        final sync = FakeSync(completed: {'l1'});
        final state = await signedOut(sync, accounts);
        await signInAndSync(accounts, state, 'u1');

        await state.markCompleted('l1');
        await settle();

        expect(sync.dailyXp, {today: xpReview});
      },
    );

    test(
      'signing in merges per day with the larger value, never a sum',
      () async {
        mockPrefs({'dailyXp': '{"2026-03-16": 30, "2026-03-17": 10}'});
        final accounts = FakeAccounts();
        final sync = FakeSync(dailyXp: {'2026-03-17': 40, '2026-03-18': 5});
        final state = await signedOut(sync, accounts);

        await signInAndSync(accounts, state, 'u1');

        final expected = {'2026-03-16': 30, '2026-03-17': 40, '2026-03-18': 5};
        expect(state.dailyXp, expected);
        expect(sync.dailyXp, expected);
        // Only the day where the device was ahead was written.
        expect(sync.xpWrites, [
          {'2026-03-16': 30},
        ]);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('dailyXp'), contains('"2026-03-17":40'));
      },
    );

    test(
      'merging the same data again changes nothing and writes nothing',
      () async {
        mockPrefs({'dailyXp': '{"2026-03-17": 20}'});
        final accounts = FakeAccounts();
        final sync = FakeSync(dailyXp: {'2026-03-17': 20});
        final state = await signedOut(sync, accounts);
        await signInAndSync(accounts, state, 'u1');
        state.retrySync();
        await state.syncing;
        expect(state.dailyXp, {'2026-03-17': 20});
        expect(sync.xpWrites, isEmpty);
      },
    );

    test('a cloud-only day reaches the device and its streak', () async {
      mockPrefs({});
      final accounts = FakeAccounts();
      final sync = FakeSync(dailyXp: {yesterday: 20, '2026-03-16': 20});
      final state = await signedOut(sync, accounts);
      await signInAndSync(accounts, state, 'u1');
      expect(state.summary.currentStreak, 2);
      expect(state.summary.totalXp, 40);
      expect(sync.xpWrites, isEmpty);
    });

    test(
      "another account's XP on the device is dropped, not uploaded",
      () async {
        mockPrefs({
          'dailyXp': '{"2026-03-17": 500}',
          'dailyGoal': 60,
          'syncedUid': 'u1',
        });
        final accounts = FakeAccounts();
        final sync = FakeSync();
        sync.doc('u2').dailyXp['2026-03-16'] = 20;
        final state = await signedOut(sync, accounts);
        expect(state.dailyXp, {'2026-03-17': 500}); // until the merge

        await signInAndSync(accounts, state, 'u2');

        expect(state.dailyXp, {'2026-03-16': 20});
        expect(sync.doc('u2').dailyXp, {'2026-03-16': 20});
        expect(sync.xpWrites, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('dailyXp'), '{"2026-03-16":20}');
      },
    );

    test('XP earned while the sign-in merge runs belongs to the new account '
        'and is not mixed with the old data', () async {
      mockPrefs({
        'dailyXp': '{"2026-03-18": 100}', // the other account's today
        'syncedUid': 'u1',
        'completedLessons': ['old'],
      });
      final accounts = FakeAccounts();
      final sync = FakeSync();
      sync.doc('u2').dailyXp['2026-03-18'] = 20;
      final gate = Completer<void>();
      sync.gate = gate;
      final state = await signedOut(sync, accounts);

      accounts.signInAs('u2');
      await settle();
      final during = state.markCompleted('new');
      await during;
      // Nothing of the old 100 XP (and no half-way total) reached u2.
      expect(sync.xpWrites, isEmpty);
      gate.complete();
      await settle();
      await state.syncing;

      // The cloud's 20 plus the 20 earned during the merge.
      expect(state.dailyXp, {today: 40});
      expect(sync.doc('u2').dailyXp, {today: 40});
      expect(sync.xpWrites, [
        {today: 40},
      ]);
    });

    test('XP earned while a normal merge runs is sent too', () async {
      mockPrefs({'dailyXp': '{"2026-03-17": 20}'});
      final accounts = FakeAccounts();
      final sync = FakeSync(dailyXp: {'2026-03-17': 20});
      final gate = Completer<void>();
      sync.gate = gate;
      final state = await signedOut(sync, accounts);

      accounts.signInAs('u1');
      await settle();
      await state.markCompleted('l1');
      gate.complete();
      await settle();
      await state.syncing;

      expect(sync.dailyXp, {'2026-03-17': 20, today: 20});
    });

    test('XP earned during a foreign-account merge that fails is kept '
        'when the merge is retried', () async {
      mockPrefs({'dailyXp': '{"2026-03-18": 100}', 'syncedUid': 'u1'});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      sync.doc('u2').dailyXp['2026-03-16'] = 20;
      final gate = Completer<void>();
      sync.gate = gate;
      final state = await signedOut(sync, accounts);

      accounts.signInAs('u2');
      await settle();
      expect((await state.markCompleted('new')).xp, 20);
      sync.failLoads = true; // the load fails once it is released
      gate.complete();
      await settle();
      await state.syncing;
      expect(state.syncFailed, isTrue);

      sync.failLoads = false;
      sync.gate = null;
      state.retrySync();
      await state.syncing;

      expect(state.syncFailed, isFalse);
      expect(state.dailyXp, {'2026-03-16': 20, today: 20});
      expect(sync.doc('u2').dailyXp, {'2026-03-16': 20, today: 20});
      expect(sync.xpWrites, isNotEmpty);
    });

    test('XP earned between the failed merge and its retry is also kept, '
        'and is not mixed with the old data', () async {
      mockPrefs({'dailyXp': '{"2026-03-18": 100}', 'syncedUid': 'u1'});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      sync.failLoads = true;
      final state = await signedOut(sync, accounts);

      accounts.signInAs('u2');
      await settle();
      await state.syncing;
      expect(state.syncFailed, isTrue);
      await state.markCompleted('new');
      await settle();
      expect(sync.xpWrites, isEmpty, reason: 'nothing of the old 100 XP');

      sync.failLoads = false;
      state.retrySync();
      await state.syncing;

      expect(state.dailyXp, {today: 20});
      expect(sync.doc('u2').dailyXp, {today: 20});
    });

    test('the merge finishing while markCompleted waits for the device '
        'storage does not lose the award', () async {
      mockPrefs({'dailyXp': '{"2026-03-18": 100}', 'syncedUid': 'u1'});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final gate = Completer<void>();
      sync.gate = gate;
      final state = await signedOut(sync, accounts);

      accounts.signInAs('u2');
      await settle();
      gate.complete();
      final award = state.markCompleted('new'); // the load resumes meanwhile
      expect((await award).xp, 20);
      await settle();
      await state.syncing;

      expect(state.dailyXp, {today: 20});
      expect(sync.doc('u2').dailyXp, {today: 20});
    });

    test('XP earned while the merge is still writing is sent when it ends, '
        'and signing out does not lose it', () async {
      mockPrefs({'dailyXp': '{"2026-03-17": 20}'});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final gate = Completer<void>();
      sync.xpGate = gate; // the merge's own XP write is slow
      final state = await signedOut(sync, accounts);

      accounts.signInAs('u1');
      await settle();
      await settle();
      await state.markCompleted('l1'); // while that write is pending
      await settle();
      gate.complete();
      await settle();
      await state.syncing;
      await settle();

      expect(sync.dailyXp, {'2026-03-17': 20, today: 20});
      expect(await state.signOut(), isTrue);
      await settle();
      expect(state.dailyXp, isEmpty);
      expect(sync.dailyXp, {'2026-03-17': 20, today: 20});
    });

    test('XP earned while the last write of a merge is pending is not '
        'lost, and signing out waits for it', () async {
      mockPrefs({'dailyXp': '{"2026-03-17": 20}'});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final gates = {1: Completer<void>(), 2: Completer<void>()};
      sync.onXpWrite = (call) => gates[call]?.future ?? Future.value();
      final state = await signedOut(sync, accounts);

      accounts.signInAs('u1');
      await settle();
      await settle();
      await state.markCompleted('l1'); // during the merge's first write
      gates[1]!.complete();
      await settle();
      await settle();
      await state.markCompleted('l2'); // during the next one
      await settle();
      gates[2]!.complete();
      await settle();
      await state.syncing;
      await settle();
      await settle();

      expect(sync.dailyXp, {'2026-03-17': 20, today: 40});
      expect(await state.signOut(), isTrue);
      await settle();
      expect(state.dailyXp, isEmpty);
      expect(sync.dailyXp, {'2026-03-17': 20, today: 40});
    });

    test('XP earned after the merge but before a slow write is acknowledged '
        'is still sent', () async {
      mockPrefs({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await signedOut(sync, accounts);
      await signInAndSync(accounts, state, 'u1');
      final gate = Completer<void>();
      sync.xpGate = gate;

      await state.markCompleted('l1');
      await state.markCompleted('l2');
      gate.complete();
      await settle();

      expect(sync.dailyXp, {today: 40});
    });

    test('signing out right after earning XP while a merge runs asks '
        'instead of dropping it', () async {
      mockPrefs({'dailyXp': '{"2026-03-17": 20}', 'syncedUid': 'u1'});
      final accounts = FakeAccounts(
        initialUser: const AccountUser(uid: 'u1', displayName: 'Ferris'),
      );
      final sync = FakeSync();
      final gate = Completer<void>();
      sync.gate = gate;
      final state = await signedOut(sync, accounts);
      await state.markCompleted('l1');

      final out = state.signOut();
      gate.complete();
      final signedOutNow = await out;
      await settle();
      await state.syncing;

      // Either it waited for the merge and everything reached the cloud, or
      // it refused. It must never clear the device with XP only here.
      if (signedOutNow) {
        expect(sync.dailyXp[today], 20);
      } else {
        expect(state.dailyXp[today], 20);
      }
    });

    test('midnight between earning and sending does not crash', () async {
      mockPrefs({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await signedOut(sync, accounts);
      await signInAndSync(accounts, state, 'u1');

      final f = state.markCompleted('l1');
      now = DateTime(2026, 3, 19, 0, 0, 1); // the day changes mid-write
      final award = await f;
      await settle();

      expect(award.xp, 20);
      expect(sync.dailyXp, {today: 20});
    });

    test('a document with a wrong type for dailyXp is repaired with one '
        'rewrite that keeps the merged days', () async {
      mockPrefs({'dailyXp': '{"2026-03-17": 20}'});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      sync.doc('u1').breakWith({'dailyXp': 'oops'});
      final state = await signedOut(sync, accounts);

      await signInAndSync(accounts, state, 'u1');

      expect(sync.replaces, 1);
      expect(sync.dailyXp, {'2026-03-17': 20});
      expect(sync.doc('u1').broken, isFalse);
    });

    test(
      'bad days inside a good map are ignored, not a reason to rewrite',
      () async {
        mockPrefs({});
        final accounts = FakeAccounts();
        final sync = FakeSync();
        sync.doc('u1').breakWith({
          'dailyXp': {
            '2026-03-17': 20,
            'junk': 5,
            '2026-03-16': 'x',
            '2026-03-15': -4,
          },
        });
        final state = await signedOut(sync, accounts);

        await signInAndSync(accounts, state, 'u1');

        expect(sync.replaces, 0);
        expect(state.dailyXp, {'2026-03-17': 20});
      },
    );

    test('offline writes: the failure shows, and the next merge sends the '
        'days that are ahead', () async {
      mockPrefs({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await signedOut(sync, accounts);
      await signInAndSync(accounts, state, 'u1');

      sync.failWrites = true;
      await state.markCompleted('l1');
      await settle();
      expect(state.syncFailed, isTrue);
      expect(sync.dailyXp, isEmpty);

      sync.failWrites = false;
      state.retrySync();
      await state.syncing;
      expect(state.syncFailed, isFalse);
      expect(sync.dailyXp, {today: 20});
    });

    test('a failed deletion puts the XP back with the rest', () async {
      mockPrefs({'dailyXp': '{"2026-03-16": 30}'});
      final accounts = FakeAccounts()
        ..deleteError = const AccountException(AccountErrorKind.network);
      final sync = FakeSync(dailyXp: {'2026-03-17': 20});
      final state = await signedOut(sync, accounts);
      await signInAndSync(accounts, state, 'u1');
      expect(sync.dailyXp, {'2026-03-16': 30, '2026-03-17': 20});

      await expectLater(state.deleteAccount(), throwsA(isA<Object>()));

      expect(sync.dailyXp, {'2026-03-16': 30, '2026-03-17': 20});
      expect(state.dailyXp, {'2026-03-16': 30, '2026-03-17': 20});
    });
  });

  group('sign-out and deletion', () {
    test('signing out clears XP, the goal and the earned-today list', () async {
      mockPrefs({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await signedOut(sync, accounts);
      await signInAndSync(accounts, state, 'u1');
      await state.setDailyGoal(40);
      await state.markCompleted('l1');

      await accounts.signOut();
      await settle();
      await state.syncing;

      expect(state.dailyXp, isEmpty);
      expect(state.summary, StreakSummary.empty);
      expect(state.dailyGoal, defaultDailyGoal);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dailyXp'), isNull);
      expect(prefs.getInt('dailyGoal'), isNull);
      expect(prefs.getString('xpAwardedToday'), isNull);
      // The cloud copy stays for the next sign-in.
      expect(sync.doc('u1').dailyXp, {today: 20});

      // The next person is not held back by the last one's finished list.
      expect((await state.markCompleted('l1')).xp, 20);
    });

    test('deleting an account as an adult clears the device', () async {
      mockPrefs({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await signedOut(sync, accounts);
      await signInAndSync(accounts, state, 'u1');
      await state.markCompleted('l1');

      await state.deleteAccount();
      await settle();

      expect(sync.docs['u1'], isNull);
      expect(state.dailyXp, isEmpty);
    });

    test(
      'signing in again after sign-out brings the XP back from the cloud',
      () async {
        mockPrefs({});
        final accounts = FakeAccounts();
        final sync = FakeSync();
        final state = await signedOut(sync, accounts);
        await signInAndSync(accounts, state, 'u1');
        await state.markCompleted('l1');
        await accounts.signOut();
        await settle();
        await state.syncing;

        await signInAndSync(accounts, state, 'u1');

        expect(state.dailyXp, {today: 20});
      },
    );
  });

  group('children (under 13)', () {
    test('XP works on the device but nothing is synced', () async {
      mockPrefs({'birthYear': childYear});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await signedOut(sync, accounts);

      await state.markCompleted('l1');
      await settle();

      expect(state.dailyXp, {today: 20});
      expect(state.summary.currentStreak, 1);
      expect(sync.loads, isEmpty);
      expect(sync.xpWrites, isEmpty);
      expect(sync.dailyXp, isEmpty);
    });

    test('signing in only to delete syncs and merges no XP', () async {
      mockPrefs({'birthYear': childYear, 'dailyXp': '{"2026-03-17": 20}'});
      final accounts = FakeAccounts();
      final sync = FakeSync(dailyXp: {'2026-03-10': 99});
      final state = await signedOut(sync, accounts);

      await state.signIn(SignInMethod.google, toDelete: true);
      await settle();
      await state.markCompleted('l1');
      await settle();

      expect(sync.loads, isEmpty);
      expect(sync.xpWrites, isEmpty);
      expect(sync.dailyXp, {'2026-03-10': 99});
      expect(state.dailyXp, {'2026-03-17': 20, today: 20});
    });

    test('deleting the account keeps the child\'s XP and goal on the '
        'device', () async {
      mockPrefs({
        'birthYear': childYear,
        'dailyXp': '{"2026-03-17": 20}',
        'dailyGoal': 40,
      });
      final accounts = FakeAccounts();
      final sync = FakeSync(dailyXp: {'2026-03-10': 99});
      final state = await signedOut(sync, accounts);
      await state.signIn(SignInMethod.google, toDelete: true);
      await settle();

      await state.deleteAccount();
      await settle();

      expect(accounts.deleted, isTrue);
      expect(state.dailyXp, {'2026-03-17': 20});
      expect(state.dailyGoal, 40);
    });

    test('a signed-in user who answers under 13 keeps their XP here and '
        'nothing more is sent', () async {
      mockPrefs({}, ageKnown: false);
      final accounts = FakeAccounts();
      final sync = FakeSync(dailyXp: {'2026-03-16': 20});
      final state = await signedOut(sync, accounts);
      await state.signIn(SignInMethod.google);
      await settle();
      await state.syncing;
      expect(state.dailyXp, {'2026-03-16': 20});

      await state.age.setBirthYear(childYear);
      await state.syncing;
      await settle();
      await state.markCompleted('l1');
      await settle();

      expect(state.user, isNull);
      expect(state.dailyXp, {'2026-03-16': 20, today: 20});
      expect(sync.dailyXp, {'2026-03-16': 20});
      expect(sync.xpWrites, isEmpty);
    });

    test(
      'a failed deletion puts back only what the cloud already had',
      () async {
        mockPrefs({'birthYear': childYear, 'dailyXp': '{"2026-03-17": 20}'});
        final accounts = FakeAccounts()
          ..deleteError = const AccountException(AccountErrorKind.network);
        final sync = FakeSync(dailyXp: {'2026-03-10': 99});
        final state = await signedOut(sync, accounts);
        await state.signIn(SignInMethod.google, toDelete: true);
        await settle();

        await expectLater(state.deleteAccount(), throwsA(isA<Object>()));

        expect(sync.dailyXp, {'2026-03-10': 99});
      },
    );
  });
}
