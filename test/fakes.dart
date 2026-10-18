import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rust_learn/account/account_service.dart';
import 'package:rust_learn/account/progress_sync.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/data/models.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAccounts implements AccountService {
  FakeAccounts({AccountUser? initialUser}) : _user = initialUser;

  final _controller = StreamController<AccountUser?>.broadcast();
  AccountUser? _user;

  /// When true, the confirming sign-in is cancelled.
  bool cancelReauth = false;

  /// When set, deleting the user fails with this error.
  Object? deleteError;

  /// With [deleteError]: the account was removed anyway.
  bool goneDespiteError = false;

  /// Order of the deletion steps, for checking the sequence.
  final List<String> steps = [];
  int reauthCount = 0;
  bool deleted = false;

  void emit(AccountUser? user) {
    _user = user;
    _controller.add(user);
  }

  void signInAs(String uid) => emit(AccountUser(uid: uid, displayName: uid));

  @override
  bool get available => true;
  @override
  AccountUser? get currentUser => _user;
  @override
  Stream<AccountUser?> get userChanges => _controller.stream;
  @override
  List<SignInMethod> get methods => SignInMethod.values;
  /// When set, signing in fails with this error.
  Object? signInError;

  @override
  Future<void> signIn(SignInMethod method) async {
    final e = signInError;
    if (e != null) throw e;
    emit(const AccountUser(uid: 'u1', displayName: 'Ferris'));
  }
  @override
  Future<void> signOut() async => emit(null);

  @override
  Future<ReauthProof> reauthenticate() async {
    steps.add('reauth');
    reauthCount++;
    if (cancelReauth) throw const AccountException(AccountErrorKind.cancelled);
    return const ReauthProof(appleAuthorizationCode: 'code');
  }

  @override
  Future<void> deleteUser(ReauthProof proof) async {
    steps.add('deleteUser');
    final e = deleteError;
    if (e != null) {
      if (goneDespiteError) deleted = true;
      throw e;
    }
    deleted = true;
    // Firebase signs the user out after deleting them.
    emit(null);
  }

  @override
  Future<bool> accountStillExists() async => !deleted;
}

class CloudDoc {
  CloudDoc({this.track, Set<String>? completed, this.broken = false})
      : completed = completed ?? {};
  Track? track;
  final Set<String> completed;

  /// Holds a field firestore.rules refuses, so merge writes fail until the
  /// whole document is replaced.
  bool broken;
}

class FakeWriteError implements Exception {
  const FakeWriteError(this.what);
  final String what;
  @override
  String toString() => 'FakeWriteError($what)';
}

/// In-memory cloud with one document per uid.
class FakeSync implements ProgressSync {
  /// Seeds the document of `u1`, the account [FakeAccounts.signIn] uses.
  FakeSync({Track? track, Set<String>? completed, this.steps}) {
    docs['u1'] = CloudDoc(track: track, completed: completed);
  }

  final Map<String, CloudDoc> docs = {};
  final List<String> loads = [];
  final List<Track> trackWrites = [];
  int replaces = 0;

  /// When given, each call is logged here (shared with [FakeAccounts.steps]).
  final List<String>? steps;

  /// When set, `load` waits for it, to test slow networks.
  Completer<void>? gate;

  /// Simulates being offline for reads.
  bool failLoads = false;

  /// Simulates every write being refused.
  bool failWrites = false;

  /// What [flush] answers.
  bool flushResult = true;

  CloudDoc doc(String uid) => docs.putIfAbsent(uid, CloudDoc.new);

  // The `u1` document, for the original tests.
  Track? get track => docs['u1']?.track;
  Set<String> get completed => doc('u1').completed;

  void _write(String uid, {bool replacing = false}) {
    if (failWrites) throw const FakeWriteError('offline');
    if (!replacing && (docs[uid]?.broken ?? false)) {
      throw const FakeWriteError('permission-denied');
    }
  }

  @override
  Future<RemoteProgress> load(String uid, {bool fromServer = false}) async {
    steps?.add('load');
    loads.add(uid);
    final snapshot = docs[uid];
    final g = gate;
    if (g != null) await g.future;
    if (failLoads) throw const FakeWriteError('unavailable');
    return RemoteProgress(
      track: snapshot?.track,
      completed: {...?snapshot?.completed},
      needsRepair: snapshot?.broken ?? false,
    );
  }

  @override
  Future<void> addCompleted(String uid, Iterable<String> ids) async {
    _write(uid);
    doc(uid).completed.addAll(ids);
  }

  @override
  Future<void> setTrack(String uid, Track t) async {
    _write(uid);
    trackWrites.add(t);
    doc(uid).track = t;
  }

  @override
  Future<void> replace(String uid, {Track? track, required Set<String> completed}) async {
    steps?.add('replace');
    _write(uid, replacing: true);
    replaces++;
    docs[uid] = CloudDoc(track: track, completed: {...completed});
  }

  @override
  Future<void> deleteAll(String uid) async {
    steps?.add('deleteAll');
    _write(uid, replacing: true);
    docs.remove(uid);
  }

  @override
  Future<bool> flush(Duration timeout) async => flushResult;
}

/// Returns fixed output, e.g. the exercise's expected answer.
class FakeRunner implements CodeRunner {
  FakeRunner(this.result);
  RunResult result;

  @override
  Future<RunResult> run(String source) async => result;
}

/// Serves course content from memory instead of the bundled assets.
class MapBundle extends CachingAssetBundle {
  MapBundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) throw FlutterError('Unable to load asset: $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// A small course with one lesson of each kind.
CourseRepository fakeCourse({Map<String, String> extraFiles = const {}}) {
  String lesson(String id, {bool exercise = false, bool quiz = false}) =>
      jsonEncode({
        'id': id,
        'title': 'Lesson $id',
        'sections': [
          {'type': 'text', 'text': 'Body of $id'},
        ],
        if (exercise)
          'exercise': {
            'prompt': 'Print hi',
            'starter': 'fn main() {}',
            'expectedOutput': 'hi',
          },
        if (quiz)
          'quiz': [
            {
              'question': 'Pick B',
              'options': ['A', 'B'],
              'answer': 1,
            },
          ],
      });

  return CourseRepository(
    bundle: MapBundle({
      'assets/content/course.json': jsonEncode({
        'units': [
          {
            'id': 'u1',
            'number': 1,
            'title': 'Basics',
            'summary': 'The basics',
            'tracks': ['starter', 'fast'],
            'lessons': [
              {'id': 'plain', 'title': 'Lesson plain'},
              {'id': 'exercise', 'title': 'Lesson exercise'},
              {'id': 'quiz', 'title': 'Lesson quiz'},
            ],
          },
        ],
      }),
      'assets/content/lessons/plain.json': lesson('plain'),
      'assets/content/lessons/exercise.json': lesson(
        'exercise',
        exercise: true,
      ),
      'assets/content/lessons/quiz.json': lesson('quiz', quiz: true),
      ...extraFiles,
    }),
  );
}

Future<AppState> makeState(
  FakeAccounts accounts,
  FakeSync sync, {
  CourseRepository? repository,
  CodeRunner runner = const PlaceholderCodeRunner(),
}) async => AppState(
  repository: repository ?? CourseRepository(),
  runner: runner,
  prefs: await SharedPreferences.getInstance(),
  accounts: accounts,
  sync: sync,
);

Future<void> settle() => Future<void>.delayed(Duration.zero);
