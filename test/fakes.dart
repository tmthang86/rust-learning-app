import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
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

  /// When true, deleting needs a recent sign-in first.
  bool requiresRecentLogin = false;

  /// When true, the re-authentication prompt is cancelled.
  bool cancelReauth = false;
  int reauthCount = 0;
  int deleteAttempts = 0;
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
  @override
  Future<void> signIn(SignInMethod method) async =>
      emit(const AccountUser(uid: 'u1', displayName: 'Ferris'));
  @override
  Future<void> signOut() async => emit(null);

  @override
  Future<void> deleteAccount() async {
    var recent = !requiresRecentLogin;
    await deleteWithRecentLogin(
      delete: () async {
        deleteAttempts++;
        if (!recent) throw FirebaseAuthException(code: 'requires-recent-login');
        deleted = true;
      },
      reauthenticate: () async {
        reauthCount++;
        if (cancelReauth) {
          throw FirebaseAuthException(code: 'web-context-cancelled');
        }
        recent = true;
      },
    );
    // Firebase signs the user out after deleting them.
    emit(null);
  }
}

class CloudDoc {
  CloudDoc({this.track, Set<String>? completed}) : completed = completed ?? {};
  Track? track;
  final Set<String> completed;
}

/// In-memory cloud with one document per uid.
class FakeSync implements ProgressSync {
  /// Seeds the document of `u1`, the account [FakeAccounts.signIn] uses.
  FakeSync({Track? track, Set<String>? completed}) {
    docs['u1'] = CloudDoc(track: track, completed: completed);
  }

  final Map<String, CloudDoc> docs = {};
  final List<String> loads = [];
  final List<Track> trackWrites = [];

  /// When set, `load` waits for it, to test slow networks.
  Completer<void>? gate;

  CloudDoc doc(String uid) => docs.putIfAbsent(uid, CloudDoc.new);

  // The `u1` document, for the original tests.
  Track? get track => docs['u1']?.track;
  Set<String> get completed => doc('u1').completed;

  @override
  Future<RemoteProgress> load(String uid) async {
    loads.add(uid);
    final snapshot = docs[uid];
    final g = gate;
    if (g != null) await g.future;
    return RemoteProgress(
      track: snapshot?.track,
      completed: {...?snapshot?.completed},
    );
  }

  @override
  Future<void> addCompleted(String uid, Iterable<String> ids) async =>
      doc(uid).completed.addAll(ids);
  @override
  Future<void> setTrack(String uid, Track t) async {
    trackWrites.add(t);
    doc(uid).track = t;
  }

  @override
  Future<void> deleteAll(String uid) async => docs.remove(uid);
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
