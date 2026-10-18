import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/account/account_service.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// No accounts for anyone who may be under 13 (see AgeGroup.allowsAccounts).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const childYear = 2018;

  test('a child cannot sign in, and nothing is synced', () async {
    mockPrefs({'track': 'fast', 'birthYear': childYear});
    final accounts = FakeAccounts();
    final sync = FakeSync();
    final state = await makeState(accounts, sync);

    expect(state.accountsAllowed, isFalse);
    await expectLater(
      state.signIn(SignInMethod.google),
      throwsA(
        isA<AccountException>().having(
          (e) => e.kind,
          'kind',
          AccountErrorKind.ageRestricted,
        ),
      ),
    );
    expect(accounts.currentUser, isNull);
    await state.markCompleted('u1-l1');
    expect(sync.loads, isEmpty);
    expect(sync.completed, isEmpty);
  });

  test('signing in only to delete syncs and merges nothing', () async {
    mockPrefs({
      'track': 'fast',
      'birthYear': childYear,
      'completedLessons': ['u1-l1'],
    });
    final accounts = FakeAccounts();
    final sync = FakeSync(completed: {'u1-l9'});
    final state = await makeState(accounts, sync);

    await state.signIn(SignInMethod.google, toDelete: true);
    await settle();
    await state.syncing;
    expect(state.user, isNotNull);
    expect(sync.loads, isEmpty);
    expect(state.completedLessons, {'u1-l1'});

    await state.markCompleted('u1-l2');
    expect(sync.completed, {'u1-l9'});
  });

  test('a child whose delete-only sign-in created a new account: it is '
      'deleted at once, progress stays', () async {
    mockPrefs({
      'track': 'fast',
      'birthYear': childYear,
      'completedLessons': ['u1-l1'],
    });
    final accounts = FakeAccounts()..nextSignInIsNew = true;
    final sync = FakeSync();
    final state = await makeState(accounts, sync);

    await state.signIn(SignInMethod.google, toDelete: true);
    await settle();

    expect(accounts.deleted, isTrue);
    expect(accounts.reauthCount, 0);
    expect(state.user, isNull);
    expect(state.signInCreatedNoAccount, isTrue);
    expect(state.completedLessons, {'u1-l1'});
    expect(state.childAccountToDelete, isFalse);
    expect(sync.loads, isEmpty);
  });

  test('if deleting that new account fails, the child is signed out here '
      'and offered deletion', () async {
    mockPrefs({'track': 'fast', 'birthYear': childYear});
    final accounts = FakeAccounts()
      ..nextSignInIsNew = true
      ..deleteError = Exception('offline');
    final state = await makeState(accounts, FakeSync());

    await state.signIn(SignInMethod.google, toDelete: true);
    await settle();

    expect(accounts.deleted, isFalse);
    expect(state.user, isNull);
    expect(state.childAccountToDelete, isTrue);
  });

  test('an adult signing in with a new account keeps it', () async {
    mockPrefs({'track': 'fast'});
    final accounts = FakeAccounts()..nextSignInIsNew = true;
    final state = await makeState(accounts, FakeSync());
    await state.signIn(SignInMethod.google);
    await settle();
    await state.syncing;
    expect(accounts.deleted, isFalse);
    expect(state.user, isNotNull);
  });

  test('deleting as a child keeps the progress on this device', () async {
    mockPrefs({
      'track': 'fast',
      'birthYear': childYear,
      'completedLessons': ['u1-l1'],
    });
    final accounts = FakeAccounts();
    final sync = FakeSync(completed: {'u1-l9'});
    final state = await makeState(accounts, sync);
    await state.signIn(SignInMethod.google, toDelete: true);
    await settle();

    await state.deleteAccount();
    await settle();

    expect(accounts.deleted, isTrue);
    expect(sync.docs['u1'], isNull);
    expect(state.user, isNull);
    expect(state.completedLessons, {'u1-l1'});
    expect(state.track, isNotNull);
    expect(state.childAccountToDelete, isFalse);
  });

  test('a signed-in user who answers under 13 is signed out here, keeps '
      'their progress, and is offered deletion', () async {
    mockPrefs({'track': 'fast'}, ageKnown: false);
    final accounts = FakeAccounts();
    final sync = FakeSync(completed: {'u1-l3'});
    final state = await makeState(accounts, sync);
    await state.signIn(SignInMethod.google);
    await settle();
    await state.syncing;
    expect(state.completedLessons, {'u1-l3'});

    await state.age.setBirthYear(childYear);
    await state.syncing;
    await settle();

    expect(state.user, isNull);
    expect(accounts.currentUser, isNull);
    expect(accounts.deleted, isFalse);
    expect(state.completedLessons, {'u1-l3'});
    expect(state.childAccountToDelete, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('syncedUid'), isNull);

    // Nothing more reaches the cloud.
    await state.markCompleted('u1-l4');
    expect(sync.completed, {'u1-l3'});
  });

  test('already signed in at start with a child birth year: signed out, '
      'progress kept', () async {
    mockPrefs({
      'track': 'fast',
      'birthYear': childYear,
      'completedLessons': ['u1-l1'],
      'syncedUid': 'u1',
    });
    final accounts = FakeAccounts(
      initialUser: const AccountUser(uid: 'u1', displayName: 'Ferris'),
    );
    final sync = FakeSync(completed: {'u1-l9'});
    final state = await makeState(accounts, sync);
    await state.syncing;
    await settle();

    expect(state.user, isNull);
    expect(state.completedLessons, {'u1-l1'});
    expect(state.childAccountToDelete, isTrue);
    expect(sync.loads, isEmpty);
  });

  group('screens', () {
    Future<AppState> open(
      WidgetTester tester,
      String location,
      FakeAccounts accounts, {
      Map<String, Object> prefs = const {},
    }) async {
      mockPrefs({'track': 'fast', 'birthYear': childYear, ...prefs});
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = (await tester.runAsync(() async {
        final s = await makeState(accounts, FakeSync());
        await s.load();
        await s.syncing;
        return s;
      }))!;
      await tester.pumpWidget(
        RustLearnApp(state: state, initialLocation: location),
      );
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('Progress: device-only card, no sign-in', (tester) async {
      await open(tester, '/progress', FakeAccounts());
      expect(find.text('Your progress is saved on this device'), findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
      expect(find.text('Delete your account'), findsNothing);
    });

    testWidgets('Progress: a child signed out of an account is offered '
        'deletion, which keeps their progress', (tester) async {
      final accounts = FakeAccounts();
      final state = await open(
        tester,
        '/progress',
        accounts,
        prefs: const {
          'childAccountToDelete': 'u1',
          'completedLessons': ['u1-l1'],
        },
      );
      expect(find.text('Your progress is saved on this device'), findsOneWidget);
      await tester.tap(find.text('Delete your account'));
      await tester.pumpAndSettle();

      expect(find.text('Learn Rust: account deletion'), findsOneWidget);
      expect(
        find.text('For you, progress on this device stays, saved only here.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Delete account').last,
      );
      await tester.pumpAndSettle();

      expect(accounts.deleted, isTrue);
      expect(find.text('Your account has been deleted.'), findsOneWidget);
      expect(state.completedLessons, {'u1-l1'});
      expect(state.childAccountToDelete, isFalse);
    });

    testWidgets('/delete-account: a sign-in with no account says so', (
      tester,
    ) async {
      final accounts = FakeAccounts()..nextSignInIsNew = true;
      final state = await open(tester, '/delete-account', accounts);
      await tester.tap(find.text('Continue with Google'));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(state.user, isNull);
      expect(accounts.deleted, isTrue);
      expect(
        find.textContaining('There was no Learn Rust account'),
        findsOneWidget,
      );
    });

    testWidgets('/delete-account: a child who signs in and leaves without '
        'deleting is signed out again', (tester) async {
      final accounts = FakeAccounts();
      final state = await open(tester, '/delete-account', accounts);
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(state.user, isNotNull);

      await tester.tap(find.text('Go to the app'));
      await tester.pumpAndSettle();
      await tester.runAsync(settle);
      await tester.pumpAndSettle();

      expect(state.user, isNull);
      expect(accounts.deleted, isFalse);
      expect(state.childAccountToDelete, isTrue);
    });
  });
}
