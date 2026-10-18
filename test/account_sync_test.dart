import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/account/account_service.dart';
import 'package:rust_learn/account/progress_sync.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signing in merges device and cloud progress both ways', () async {
    SharedPreferences.setMockInitialValues({
      'completedLessons': ['u1-l1', 'u1-l2'],
    });
    final accounts = FakeAccounts();
    final sync = FakeSync(track: Track.fast, completed: {'u1-l2', 'u1-l3'});
    final state = await makeState(accounts, sync);

    await accounts.signIn(SignInMethod.google);
    await settle();
    await state.syncing;

    expect(state.completedLessons, {'u1-l1', 'u1-l2', 'u1-l3'});
    expect(sync.completed, {'u1-l1', 'u1-l2', 'u1-l3'});
    // The device had no track yet, so the cloud's choice is used.
    expect(state.track, Track.fast);
  });

  test('a track chosen on this device is uploaded when the cloud has none', () async {
    SharedPreferences.setMockInitialValues({'track': 'starter'});
    final accounts = FakeAccounts();
    final sync = FakeSync();
    final state = await makeState(accounts, sync);

    await accounts.signIn(SignInMethod.google);
    await settle();
    await state.syncing;

    expect(state.track, Track.starter);
    expect(sync.track, Track.starter);
  });

  test('progress made while signed in is saved to the cloud', () async {
    SharedPreferences.setMockInitialValues({});
    final accounts = FakeAccounts();
    final sync = FakeSync();
    final state = await makeState(accounts, sync);
    await accounts.signIn(SignInMethod.google);
    await settle();
    await state.syncing;

    await state.markCompleted('u1-l4');
    await state.chooseTrack(Track.fast);

    expect(sync.completed, contains('u1-l4'));
    expect(sync.track, Track.fast);
  });

  testWidgets('Progress screen offers sign-in, then shows the account', (tester) async {
    SharedPreferences.setMockInitialValues({'track': 'fast'});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final accounts = FakeAccounts();
    final state = (await tester.runAsync(() async {
      final s = await makeState(accounts, FakeSync());
      await s.load();
      return s;
    }))!;
    await tester.pumpWidget(RustLearnApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Progress'));
    await tester.pumpAndSettle();

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);

    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    expect(find.text('Ferris'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  test('progress made while signed out stays on the device', () async {
    SharedPreferences.setMockInitialValues({});
    final accounts = FakeAccounts();
    final sync = FakeSync();
    final state = await makeState(accounts, sync);

    await state.markCompleted('u1-l1');

    expect(state.isCompleted('u1-l1'), isTrue);
    expect(sync.completed, isEmpty);
  });

  Future<void> signInAndSync(FakeAccounts accounts, AppState state, String uid) async {
    accounts.signInAs(uid);
    await settle();
    await state.syncing;
  }

  group('shared device (B9)', () {
    test("signing out clears the device and the next account gets none of it",
        () async {
      SharedPreferences.setMockInitialValues({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      sync.doc('u2').completed.add('u2-only');
      final state = await makeState(accounts, sync);

      await signInAndSync(accounts, state, 'u1');
      await state.chooseTrack(Track.fast);
      await state.markCompleted('u1-l1');

      await accounts.signOut();
      await settle();
      await state.syncing;
      expect(state.completedLessons, isEmpty);
      expect(state.track, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('completedLessons'), isNull);
      expect(prefs.getString('syncedUid'), isNull);

      await signInAndSync(accounts, state, 'u2');
      expect(sync.doc('u2').completed, {'u2-only'});
      expect(sync.doc('u2').track, isNull);
      expect(state.completedLessons, {'u2-only'});
      // u1's cloud copy is untouched.
      expect(sync.doc('u1').completed, {'u1-l1'});
    });

    test('progress never synced to any account is merged on sign-in', () async {
      SharedPreferences.setMockInitialValues({
        'completedLessons': ['anon-1'],
      });
      final accounts = FakeAccounts();
      final sync = FakeSync(completed: {'cloud-1'});
      final state = await makeState(accounts, sync);

      await signInAndSync(accounts, state, 'u1');

      expect(sync.doc('u1').completed, {'anon-1', 'cloud-1'});
      expect(state.completedLessons, {'anon-1', 'cloud-1'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('syncedUid'), 'u1');
    });

    test("another account's progress left on the device is dropped, not uploaded",
        () async {
      SharedPreferences.setMockInitialValues({
        'completedLessons': ['u1-secret'],
        'track': 'starter',
        'syncedUid': 'u1',
        'trackDirty': true,
      });
      final accounts = FakeAccounts();
      final sync = FakeSync();
      sync.doc('u2')
        ..track = Track.fast
        ..completed.add('u2-l1');
      final state = await makeState(accounts, sync);

      await signInAndSync(accounts, state, 'u2');

      expect(sync.doc('u2').completed, {'u2-l1'});
      expect(sync.doc('u2').track, Track.fast);
      expect(state.completedLessons, {'u2-l1'});
      expect(state.track, Track.fast);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('syncedUid'), 'u2');
    });

    test('found signed out at start with an account\'s progress: cleared', () async {
      SharedPreferences.setMockInitialValues({
        'completedLessons': ['u1-l1'],
        'track': 'fast',
        'syncedUid': 'u1',
      });
      final accounts = FakeAccounts();
      final state = await makeState(accounts, FakeSync());
      expect(state.completedLessons, {'u1-l1'}); // until auth reports

      accounts.emit(null);
      await settle();
      await state.syncing;
      expect(state.completedLessons, isEmpty);
      expect(state.track, isNull);
    });
  });

  group('track sync (m12)', () {
    test('an unchanged device takes the track chosen on another device', () async {
      SharedPreferences.setMockInitialValues({
        'track': 'starter',
        'syncedUid': 'u1',
      });
      final accounts = FakeAccounts();
      final sync = FakeSync(track: Track.fast);
      final state = await makeState(accounts, sync);

      await signInAndSync(accounts, state, 'u1');

      expect(state.track, Track.fast);
      expect(sync.track, Track.fast);
      expect(sync.trackWrites, isEmpty);
    });

    test('a track changed on this device since the last sync is uploaded', () async {
      SharedPreferences.setMockInitialValues({
        'track': 'starter',
        'syncedUid': 'u1',
        'trackDirty': true,
      });
      final accounts = FakeAccounts();
      final sync = FakeSync(track: Track.fast);
      final state = await makeState(accounts, sync);

      await signInAndSync(accounts, state, 'u1');

      expect(state.track, Track.starter);
      expect(sync.track, Track.starter);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('trackDirty'), isFalse);
    });
  });

  group('merge races (m13)', () {
    test('the same user reported again does not merge twice', () async {
      SharedPreferences.setMockInitialValues({});
      const user = AccountUser(uid: 'u1');
      final accounts = FakeAccounts(initialUser: user);
      final sync = FakeSync();
      final state = await makeState(accounts, sync);
      accounts.emit(user); // authStateChanges repeats the current user
      accounts.emit(user);
      await settle();
      await state.syncing;

      expect(sync.loads, ['u1']);
    });

    test('a slow merge for a previous account is dropped', () async {
      SharedPreferences.setMockInitialValues({});
      final accounts = FakeAccounts();
      final sync = FakeSync(track: Track.fast, completed: {'u1-l1'});
      sync.doc('u2').completed.add('u2-l1');
      final state = await makeState(accounts, sync);

      sync.gate = Completer<void>();
      accounts.signInAs('u1');
      await settle();
      final slowMerge = state.syncing;
      accounts.signOut();
      await settle();
      accounts.signInAs('u2');
      await settle();
      sync.gate!.complete();
      await slowMerge;
      await state.syncing;

      expect(state.completedLessons, {'u2-l1'});
      expect(state.track, isNull);
      expect(sync.doc('u2').completed, {'u2-l1'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('syncedUid'), 'u2');
    });
  });

  test('malformed cloud fields are ignored instead of breaking sync (m11)', () {
    final p = RemoteProgress.fromMap({
      'track': 42,
      'completedLessons': ['u1-l1', 7, null, '', 'u1-l2'],
    });
    expect(p.track, isNull);
    expect(p.completed, {'u1-l1', 'u1-l2'});

    expect(RemoteProgress.fromMap({'completedLessons': 'oops'}).completed, isEmpty);
    expect(RemoteProgress.fromMap({'track': 'unknown'}).track, isNull);
    expect(RemoteProgress.fromMap(null).completed, isEmpty);
    expect(RemoteProgress.fromMap({'track': 'fast'}).track, Track.fast);
  });

  group('account deletion', () {
    Future<(FakeAccounts, FakeSync, AppState)> signedIn() async {
      SharedPreferences.setMockInitialValues({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      await state.chooseTrack(Track.fast);
      await state.markCompleted('u1-l1');
      return (accounts, sync, state);
    }

    test('deletes the cloud document, the account and the device progress', () async {
      final (accounts, sync, state) = await signedIn();

      await state.deleteAccount();
      await settle();

      expect(accounts.deleted, isTrue);
      expect(sync.docs.containsKey('u1'), isFalse);
      expect(state.user, isNull);
      expect(state.completedLessons, isEmpty);
      expect(state.track, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('completedLessons'), isNull);
      expect(prefs.getString('syncedUid'), isNull);
    });

    test('asks for a fresh sign-in when required, then deletes', () async {
      final (accounts, sync, state) = await signedIn();
      accounts.requiresRecentLogin = true;

      await state.deleteAccount();

      expect(accounts.reauthCount, 1);
      expect(accounts.deleteAttempts, 2);
      expect(accounts.deleted, isTrue);
      expect(sync.docs.containsKey('u1'), isFalse);
      expect(state.completedLessons, isEmpty);
    });

    test('cancelling the fresh sign-in keeps the account and its progress', () async {
      final (accounts, sync, state) = await signedIn();
      accounts
        ..requiresRecentLogin = true
        ..cancelReauth = true;

      await expectLater(state.deleteAccount(), throwsA(anything));

      expect(accounts.deleted, isFalse);
      expect(state.user?.uid, 'u1');
      expect(state.completedLessons, {'u1-l1'});
      // The cloud copy is put back from the device.
      expect(sync.doc('u1').completed, {'u1-l1'});
      expect(sync.doc('u1').track, Track.fast);
    });

    testWidgets('Progress screen deletes the account after confirmation',
        (tester) async {
      SharedPreferences.setMockInitialValues({'track': 'fast'});
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = (await tester.runAsync(() async {
        final s = await makeState(accounts, sync);
        await s.load();
        return s;
      }))!;
      await tester.pumpWidget(RustLearnApp(state: state, initialLocation: '/progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete your account?'), findsOneWidget);

      // Cancel keeps everything.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(accounts.deleted, isFalse);

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
      await tester.pumpAndSettle();

      expect(accounts.deleted, isTrue);
      expect(sync.docs.containsKey('u1'), isFalse);
      expect(state.user, isNull);
      // The device is fresh again, so the track question comes back.
      expect(find.text('Where would you like to start?'), findsOneWidget);
    });
  });
}
