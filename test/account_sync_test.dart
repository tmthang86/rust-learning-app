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
    // First launch forces a track pick before anyone can sign in.
    SharedPreferences.setMockInitialValues({
      'completedLessons': ['u1-l1', 'u1-l2'],
      'track': 'starter',
    });
    final accounts = FakeAccounts();
    final sync = FakeSync(track: Track.fast, completed: {'u1-l2', 'u1-l3'});
    final state = await makeState(accounts, sync);

    await accounts.signIn(SignInMethod.google);
    await settle();
    await state.syncing;

    expect(state.completedLessons, {'u1-l1', 'u1-l2', 'u1-l3'});
    expect(sync.completed, {'u1-l1', 'u1-l2', 'u1-l3'});
    // The device never synced, so its first-launch pick doesn't override
    // the account's track (F2).
    expect(state.track, Track.fast);
    expect(sync.track, Track.fast);
  });

  test(
    'a track chosen on this device is uploaded when the cloud has none',
    () async {
      SharedPreferences.setMockInitialValues({'track': 'starter'});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await makeState(accounts, sync);

      await accounts.signIn(SignInMethod.google);
      await settle();
      await state.syncing;

      expect(state.track, Track.starter);
      expect(sync.track, Track.starter);
    },
  );

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

  testWidgets('Progress screen offers sign-in, then shows the account', (
    tester,
  ) async {
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

  Future<void> signInAndSync(
    FakeAccounts accounts,
    AppState state,
    String uid,
  ) async {
    accounts.signInAs(uid);
    await settle();
    await state.syncing;
  }

  group('shared device (B9)', () {
    test(
      "signing out clears the device and the next account gets none of it",
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
      },
    );

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

    test(
      "another account's progress left on the device is dropped, not uploaded",
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
      },
    );

    test(
      'found signed out at start with an account\'s progress: cleared',
      () async {
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
      },
    );
  });

  group('track sync (m12)', () {
    test(
      'an unchanged device takes the track chosen on another device',
      () async {
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
      },
    );

    test(
      'a track changed on this device since the last sync is uploaded',
      () async {
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
      },
    );
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

    expect(
      RemoteProgress.fromMap({'completedLessons': 'oops'}).completed,
      isEmpty,
    );
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

    test(
      'deletes the cloud document, the account and the device progress',
      () async {
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
      },
    );

    test(
      'confirms first, then reads, deletes the document, then the user (F3)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final steps = <String>[];
        final accounts = FakeAccounts(steps: steps);
        final logged = FakeSync(steps: steps, completed: {'u1-l1'});
        final s2 = await makeState(accounts, logged);
        await signInAndSync(accounts, s2, 'u1');
        steps.clear();

        await s2.deleteAccount();

        // Auth and cloud steps in one list: confirm before touching data.
        expect(steps, ['reauth', 'load', 'deleteAll', 'deleteUser']);
        expect(accounts.reauthCount, 1);
        expect(logged.docs.containsKey('u1'), isFalse);
      },
    );

    test('cancelling the confirming sign-in changes nothing', () async {
      final (accounts, sync, state) = await signedIn();
      accounts.cancelReauth = true;

      await expectLater(
        state.deleteAccount(),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.cancelled,
          ),
        ),
      );

      expect(accounts.deleted, isFalse);
      expect(state.user?.uid, 'u1');
      expect(state.completedLessons, {'u1-l1'});
      expect(sync.doc('u1').completed, {'u1-l1'});
      expect(sync.loads, [
        'u1',
      ]); // only the sign-in merge; nothing read or deleted
    });

    test('offline: fails before deleting anything', () async {
      final (accounts, sync, state) = await signedIn();
      sync.failLoads = true;

      await expectLater(
        state.deleteAccount(),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.network,
          ),
        ),
      );
      expect(sync.doc('u1').completed, {'u1-l1'});
      expect(accounts.deleted, isFalse);
      expect(state.completedLessons, {'u1-l1'});
    });

    test(
      'if deleting the user fails, cloud and device progress are put back',
      () async {
        final (accounts, sync, state) = await signedIn();
        // Another device added a lesson the device doesn't know about.
        sync.doc('u1').completed.add('other-device');
        accounts.deleteError = const AccountException(AccountErrorKind.network);

        await expectLater(
          state.deleteAccount(),
          throwsA(isA<AccountException>()),
        );

        expect(sync.doc('u1').completed, {'u1-l1', 'other-device'});
        expect(sync.doc('u1').track, Track.fast);
        expect(state.completedLessons, {'u1-l1'});
        expect(state.user?.uid, 'u1');
      },
    );

    test('an error after the account is in fact gone does not recreate the document', () async {
      final (accounts, sync, state) = await signedIn();
      accounts
        ..deleteError = const AccountException(AccountErrorKind.network)
        ..goneDespiteError = true;

      await state.deleteAccount();

      expect(sync.docs.containsKey('u1'), isFalse);
      expect(state.completedLessons, isEmpty);
    });

    testWidgets('Progress screen deletes the account after confirmation', (
      tester,
    ) async {
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
      await tester.pumpWidget(
        RustLearnApp(state: state, initialLocation: '/progress'),
      );
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

  group('signing out before progress is saved (F1)', () {
    test('a failed first sync: asks instead of clearing', () async {
      SharedPreferences.setMockInitialValues({
        'completedLessons': ['anon-1'],
        'track': 'starter',
      });
      final accounts = FakeAccounts();
      final sync = FakeSync()..failLoads = true;
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      expect(state.syncFailed, isTrue);

      expect(await state.signOut(), isFalse);
      expect(state.user?.uid, 'u1');
      expect(state.completedLessons, {'anon-1'});

      expect(await state.signOut(force: true), isTrue);
      await settle();
      await state.syncing;
      expect(state.completedLessons, isEmpty);
    });

    test('retries the sync first and signs out when it works', () async {
      SharedPreferences.setMockInitialValues({
        'completedLessons': ['anon-1'],
        'track': 'starter',
      });
      final accounts = FakeAccounts();
      final sync = FakeSync()..failLoads = true;
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      sync.failLoads = false; // back online

      expect(await state.signOut(), isTrue);
      expect(sync.doc('u1').completed, {'anon-1'});
      expect(accounts.currentUser, isNull);
    });

    test('changes still waiting to be sent: asks', () async {
      SharedPreferences.setMockInitialValues({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      sync.flushResult = false;

      expect(await state.signOut(), isFalse);
      expect(state.user?.uid, 'u1');
    });

    testWidgets('the Progress screen asks before signing out', (tester) async {
      SharedPreferences.setMockInitialValues({'track': 'fast'});
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final accounts = FakeAccounts();
      final sync = FakeSync()..flushResult = false;
      final state = (await tester.runAsync(() async {
        final s = await makeState(accounts, sync);
        await s.load();
        return s;
      }))!;
      await tester.pumpWidget(
        RustLearnApp(state: state, initialLocation: '/progress'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out anyway?'), findsOneWidget);
      await tester.tap(find.text('Stay signed in'));
      await tester.pumpAndSettle();
      expect(state.user, isNotNull);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out anyway'));
      await tester.pumpAndSettle();
      expect(state.user, isNull);
    });
  });

  group('first-launch track (F2)', () {
    test(
      'a pick on a never-synced device does not override the account',
      () async {
        SharedPreferences.setMockInitialValues({});
        final accounts = FakeAccounts();
        final sync = FakeSync(track: Track.starter);
        final state = await makeState(accounts, sync);
        await state.chooseTrack(Track.fast); // the welcome screen

        await signInAndSync(accounts, state, 'u1');

        expect(state.track, Track.starter);
        expect(sync.track, Track.starter);
      },
    );

    test('a change made while signed in is kept on the next sync', () async {
      SharedPreferences.setMockInitialValues({'track': 'starter'});
      final accounts = FakeAccounts();
      final sync = FakeSync(track: Track.starter);
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      sync.failWrites = true; // the push fails, so the change stays pending
      await state.chooseTrack(Track.fast);
      await settle();
      sync.failWrites = false;

      state.retrySync();
      await state.syncing;
      expect(sync.track, Track.fast);
      expect(state.track, Track.fast);
    });
  });

  group('broken cloud documents (F4)', () {
    test(
      'a document the rules refuse is repaired with one full write',
      () async {
        SharedPreferences.setMockInitialValues({
          'completedLessons': ['local-1'],
          'track': 'starter',
        });
        final accounts = FakeAccounts();
        final sync = FakeSync(completed: {'cloud-1'});
        sync.doc('u1').breakWith({'track': 42});
        final state = await makeState(accounts, sync);

        await signInAndSync(accounts, state, 'u1');

        expect(state.syncFailed, isFalse);
        expect(sync.replaces, 1);
        expect(sync.doc('u1').broken, isFalse);
        expect(sync.doc('u1').completed, {'local-1', 'cloud-1'});
        expect(sync.doc('u1').track, Track.starter);

        // Later small writes work again.
        await state.markCompleted('later');
        await settle();
        expect(sync.doc('u1').completed, contains('later'));
      },
    );

    test('a failed background write shows as a sync problem', () async {
      SharedPreferences.setMockInitialValues({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      expect(state.syncFailed, isFalse);

      sync.failWrites = true;
      await state.markCompleted('x');
      await settle();
      expect(state.syncFailed, isTrue);

      sync.failWrites = false;
      state.retrySync();
      await state.syncing;
      expect(state.syncFailed, isFalse);
      expect(sync.doc('u1').completed, contains('x'));
    });

    test('the parser flags documents that need a repair', () {
      expect(RemoteProgress.fromMap({'track': 42}).needsRepair, isTrue);
      expect(RemoteProgress.fromMap({'extra': true}).needsRepair, isTrue);
      expect(
        RemoteProgress.fromMap({
          'completedLessons': ['a', 1],
        }).needsRepair,
        isTrue,
      );
      // updatedAt isn't judged: a pending server timestamp reads as null (N1).
      expect(RemoteProgress.fromMap({'updatedAt': null}).needsRepair, isFalse);
      expect(
        RemoteProgress.fromMap({'updatedAt': 'yesterday'}).needsRepair,
        isFalse,
      );
      // A cached or half-written snapshot never asks for a repair.
      expect(
        RemoteProgress.fromMap({'track': 42}, confirmed: false).needsRepair,
        isFalse,
      );
      expect(
        RemoteProgress.fromMap({
          'track': 'fast',
          'completedLessons': ['a'],
        }).needsRepair,
        isFalse,
      );
      expect(RemoteProgress.fromMap(null).needsRepair, isFalse);
    });
  });

  test('a lesson finished while another account\'s progress is dropped is kept (F10)', () async {
    SharedPreferences.setMockInitialValues({
      'completedLessons': ['u1-secret'],
      'track': 'fast',
      'syncedUid': 'u1',
    });
    final accounts = FakeAccounts();
    final sync = FakeSync();
    sync.doc('u2').completed.add('u2-l1');
    final state = await makeState(accounts, sync);

    sync.gate = Completer<void>();
    accounts.signInAs('u2');
    await settle();
    await state.markCompleted('done-meanwhile');
    sync.gate!.complete();
    await state.syncing;

    expect(state.completedLessons, {'u2-l1', 'done-meanwhile'});
    expect(sync.doc('u2').completed, {'u2-l1', 'done-meanwhile'});
  });

  testWidgets('/delete-account works without a track and deletes the account', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
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
    await tester.pumpWidget(
      RustLearnApp(state: state, initialLocation: '/delete-account'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Learn Rust: account deletion'), findsOneWidget);
    expect(
      find.text('Sign in with the account you want to delete.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete account').last);
    await tester.pumpAndSettle();

    expect(accounts.deleted, isTrue);
    expect(find.text('Your account has been deleted.'), findsOneWidget);
  });

  testWidgets('Apple sign-in for a Google email explains what to do (F10)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'track': 'fast'});
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final accounts = FakeAccounts()
      ..signInError = const AccountException(AccountErrorKind.otherProvider);
    final state = (await tester.runAsync(() async {
      final s = await makeState(accounts, FakeSync());
      await s.load();
      return s;
    }))!;
    await tester.pumpWidget(
      RustLearnApp(state: state, initialLocation: '/progress'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue with Apple'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Continue with Google" instead'),
      findsOneWidget,
    );
  });

  group('pending writes and cached reads (N1)', () {
    test(
      'an unconfirmed snapshot is merged, never used to rewrite the document',
      () async {
        SharedPreferences.setMockInitialValues({
          'completedLessons': ['phone-l1'],
          'track': 'fast',
          'syncedUid': 'u1',
        });
        final accounts = FakeAccounts();
        final sync = FakeSync(track: Track.fast, completed: {'tablet-l2'});
        sync.unconfirmedReads = true; // offline, or our write not acknowledged
        final state = await makeState(accounts, sync);

        await signInAndSync(accounts, state, 'u1');

        expect(sync.replaces, 0);
        expect(sync.doc('u1').completed, {'phone-l1', 'tablet-l2'});
      },
    );

    test('a broken document seen only in the cache is not rewritten', () async {
      SharedPreferences.setMockInitialValues({
        'track': 'fast',
        'syncedUid': 'u1',
      });
      final accounts = FakeAccounts();
      final sync = FakeSync(completed: {'tablet-l2'});
      sync.doc('u1').breakWith({'track': 42});
      sync.unconfirmedReads = true;
      final state = await makeState(accounts, sync);
      await state.markCompleted('phone-l1');

      await signInAndSync(accounts, state, 'u1');

      expect(sync.replaces, 0);
      expect(state.syncFailed, isTrue); // the merge write was refused
      expect(sync.doc('u1').completed, contains('tablet-l2'));

      // Once a confirmed server read shows it, it is repaired.
      sync.unconfirmedReads = false;
      state.retrySync();
      await state.syncing;
      expect(sync.replaces, 1);
      expect(sync.doc('u1').completed, {'tablet-l2', 'phone-l1'});
      expect(state.syncFailed, isFalse);
    });
  });

  group('late results and deletion (N2)', () {
    test('no background writes while the account is being deleted', () async {
      SharedPreferences.setMockInitialValues({});
      final accounts = FakeAccounts();
      final sync = FakeSync();
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      final epoch = state.accountEpoch;

      // Wait at the last step: the document is already deleted, and a
      // background write now would recreate it.
      accounts.deleteUserGate = Completer<void>();
      final deletion = state.deleteAccount();
      expect(state.accountEpoch, isNot(epoch));
      while (!accounts.steps.contains('deleteUser')) {
        await settle();
      }
      expect(sync.docs.containsKey('u1'), isFalse);
      await state.markCompleted('during-delete');
      await settle();
      accounts.deleteUserGate!.complete();
      await deletion;

      expect(sync.docs.containsKey('u1'), isFalse);
    });
  });

  test('a lesson the new account finishes during the sync is kept even if the '
      'previous account had it (N4)', () async {
    SharedPreferences.setMockInitialValues({
      'completedLessons': ['shared-l1', 'u1-only'],
      'track': 'fast',
      'syncedUid': 'u1',
    });
    final accounts = FakeAccounts();
    final sync = FakeSync();
    sync.doc('u2').completed.add('u2-l1');
    final state = await makeState(accounts, sync);

    sync.gate = Completer<void>();
    accounts.signInAs('u2');
    await settle();
    await state.markCompleted('shared-l1'); // looks done already (u1's)
    await settle();
    sync.gate!.complete();
    await state.syncing;

    expect(state.completedLessons, {'u2-l1', 'shared-l1'});
    expect(sync.doc('u2').completed, {'u2-l1', 'shared-l1'});
  });

  group('deletion edge cases (N5)', () {
    Future<(FakeAccounts, FakeSync, AppState)> signedIn() async {
      SharedPreferences.setMockInitialValues({});
      final accounts = FakeAccounts();
      final sync = FakeSync(completed: {'u1-l1'});
      final state = await makeState(accounts, sync);
      await signInAndSync(accounts, state, 'u1');
      return (accounts, sync, state);
    }

    test(
      "can't tell whether the account is gone: no restore, says so",
      () async {
        final (accounts, sync, state) = await signedIn();
        accounts
          ..deleteError = const AccountException(AccountErrorKind.network)
          ..stillExistsAnswer = () => null;

        await expectLater(
          state.deleteAccount(),
          throwsA(
            isA<AccountException>().having(
              (e) => e.kind,
              'kind',
              AccountErrorKind.unconfirmed,
            ),
          ),
        );
        expect(sync.docs.containsKey('u1'), isFalse); // not recreated
        expect(state.completedLessons, {'u1-l1'}); // kept on the device
      },
    );

    test('only offline errors are reported as offline', () async {
      final (accounts, sync, state) = await signedIn();
      sync.failWrites = true; // a refused delete, not a connection problem
      await expectLater(
        state.deleteAccount(),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.other,
          ),
        ),
      );

      sync
        ..failWrites = false
        ..failLoads = true;
      await expectLater(
        state.deleteAccount(),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.network,
          ),
        ),
      );
    });

    testWidgets('system back does not close the dialog while deleting', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'track': 'fast'});
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final accounts = FakeAccounts();
      final state = (await tester.runAsync(() async {
        final s = await makeState(accounts, FakeSync());
        await s.load();
        return s;
      }))!;
      await tester.pumpWidget(
        RustLearnApp(state: state, initialLocation: '/progress'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();

      accounts.reauthGate = Completer<void>();
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
      await tester.pump();

      // The dialog refuses system back while busy.
      final scope = find.ancestor(
        of: find.text('Delete your account?'),
        matching: find.byWidgetPredicate((w) => w is PopScope),
      );
      expect((tester.widget(scope.first) as PopScope).canPop, isFalse);

      accounts.reauthGate!.complete();
      await tester.pumpAndSettle();
      expect(accounts.deleted, isTrue);
    });
  });
}
