import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/account/account_service.dart';
import 'package:rust_learn/account/progress_sync.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/data/models.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAccounts implements AccountService {
  final _controller = StreamController<AccountUser?>.broadcast();
  AccountUser? _user;

  void emit(AccountUser? user) {
    _user = user;
    _controller.add(user);
  }

  @override
  bool get available => true;
  @override
  AccountUser? get currentUser => _user;
  @override
  Stream<AccountUser?> get userChanges => _controller.stream;
  @override
  List<SignInMethod> get methods => SignInMethod.values;
  @override
  Future<void> signIn(SignInMethod method) async =>
      emit(const AccountUser(uid: 'u1', displayName: 'Ferris'));
  @override
  Future<void> signOut() async => emit(null);
}

class FakeSync implements ProgressSync {
  FakeSync({this.track, Set<String>? completed}) : completed = completed ?? {};

  Track? track;
  final Set<String> completed;

  @override
  Future<RemoteProgress> load(String uid) async =>
      RemoteProgress(track: track, completed: {...completed});
  @override
  Future<void> addCompleted(String uid, Iterable<String> ids) async => completed.addAll(ids);
  @override
  Future<void> setTrack(String uid, Track t) async => track = t;
}

Future<AppState> makeState(FakeAccounts accounts, FakeSync sync) async => AppState(
      repository: CourseRepository(),
      runner: const PlaceholderCodeRunner(),
      prefs: await SharedPreferences.getInstance(),
      accounts: accounts,
      sync: sync,
    );

Future<void> settle() => Future<void>.delayed(Duration.zero);

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
}
