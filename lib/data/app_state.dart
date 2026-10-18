import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_service.dart';
import '../account/progress_sync.dart';
import '../runner/code_runner.dart';
import 'course_repository.dart';
import 'models.dart';

/// App-wide state: the course, the learner's track and their progress.
///
/// Progress is always saved on the device. When the learner is signed in it
/// is also synced to the cloud through [sync].
///
/// Device progress belongs either to nobody (made while signed out and never
/// synced) or to the account it was last synced with ([_syncedUidKey]):
/// - signing in merges nobody's progress into the account;
/// - progress that belongs to another account is dropped and the cloud copy
///   is loaded instead;
/// - signing out (or deleting the account) clears the device, so the next
///   person on a shared device starts fresh.
class AppState extends ChangeNotifier {
  AppState({
    required this.repository,
    required this.runner,
    required this.prefs,
    this.accounts = const DisabledAccountService(),
    this.sync,
  }) {
    _track = Track.fromName(prefs.getString(_trackKey));
    _completed = (prefs.getStringList(_completedKey) ?? const []).toSet();
    _user = accounts.currentUser;
    _userSub = accounts.userChanges.listen(_onUserChanged);
    if (_user != null) syncing = _mergeWithCloud(_user!);
  }

  static const _trackKey = 'track';
  static const _completedKey = 'completedLessons';

  /// The account the device progress was last synced with; absent when the
  /// progress was never synced.
  static const _syncedUidKey = 'syncedUid';

  /// Set when the track was changed on this device and the cloud may not
  /// have that change yet. Without it the cloud's track wins on merge, so
  /// two devices don't keep overwriting each other's choice.
  static const _trackDirtyKey = 'trackDirty';

  final CourseRepository repository;
  final CodeRunner runner;
  final SharedPreferences prefs;
  final AccountService accounts;
  final ProgressSync? sync;

  late final StreamSubscription<AccountUser?> _userSub;

  Course? _course;
  Track? _track;
  Set<String> _completed = {};
  AccountUser? _user;
  bool _sawAuthEvent = false;
  bool _syncFailed = false;

  /// Lessons finished while a merge is running; a merge that replaces the
  /// device copy with the cloud's keeps them.
  final Set<String> _finishedDuringMerge = {};

  /// How long account deletion waits for each server step.
  static const serverTimeout = Duration(seconds: 20);

  /// Bumped on every account change; a merge that started under an older
  /// generation drops its result instead of writing stale progress.
  int _generation = 0;

  /// Completes when the latest sign-in merge has finished.
  Future<void> syncing = Future.value();

  Course? get course => _course;
  Track? get track => _track;
  Set<String> get completedLessons => Set.unmodifiable(_completed);
  AccountUser? get user => _user;

  /// True when the last attempt to sync with the cloud failed.
  bool get syncFailed => _syncFailed;

  Future<void> load() async {
    _course = await repository.loadCourse();
    notifyListeners();
  }

  Future<void> chooseTrack(Track track) async {
    _track = track;
    await prefs.setString(_trackKey, track.name);
    // A device that never synced (first launch forces a pick before anyone
    // can sign in) must not override an account's track, so only a change
    // made while signed in, or on a device that has synced, counts.
    if (_user != null || prefs.getString(_syncedUidKey) != null) {
      await prefs.setBool(_trackDirtyKey, true);
    }
    notifyListeners();
    _push((s, uid) async {
      await s.setTrack(uid, track);
      if (_track == track && _user?.uid == uid) {
        await prefs.setBool(_trackDirtyKey, false);
      }
    });
  }

  bool isCompleted(String lessonId) => _completed.contains(lessonId);

  Future<void> markCompleted(String lessonId) async {
    if (_completed.add(lessonId)) {
      if (_user != null) _finishedDuringMerge.add(lessonId);
      await prefs.setStringList(_completedKey, _completed.toList());
      notifyListeners();
      _push((s, uid) => s.addCompleted(uid, [lessonId]));
    }
  }

  /// Tries the cloud sync again after a failure.
  void retrySync() {
    final u = _user;
    if (u != null) syncing = _mergeWithCloud(u);
  }

  /// Signs out, first making sure this device's progress reached the
  /// account. Returns false, without signing out, when it may not have: the
  /// first sync never finished, a background write failed, or changes are
  /// still waiting to be sent. Signing out clears the device, so the UI
  /// then asks before calling again with [force].
  Future<bool> signOut({bool force = false}) async {
    final u = _user;
    final s = sync;
    if (!force && u != null && s != null) {
      if (prefs.getString(_syncedUidKey) != u.uid || _syncFailed) {
        try {
          await (syncing = _mergeWithCloud(u)).timeout(const Duration(seconds: 10));
        } on TimeoutException {
          // Treated as not saved below.
        }
      }
      final saved = prefs.getString(_syncedUidKey) == u.uid &&
          !_syncFailed &&
          await s.flush(const Duration(seconds: 5));
      if (!saved) return false;
    }
    await accounts.signOut();
    return true;
  }

  void _onUserChanged(AccountUser? user) {
    final firstEvent = !_sawAuthEvent;
    _sawAuthEvent = true;
    final previous = _user;
    _user = user;

    if (user != null && user.uid == previous?.uid) {
      // Same account (a token refresh, or the first event repeating the
      // user we started with): nothing to merge again.
      notifyListeners();
      return;
    }

    _generation++;
    if (user == null) {
      // Signed out now, or found signed out at start while the device still
      // holds an account's progress (the session ended while the app was
      // closed).
      if (previous != null ||
          (firstEvent && prefs.getString(_syncedUidKey) != null)) {
        syncing = _clearLocal();
      } else {
        notifyListeners();
      }
      return;
    }
    notifyListeners();
    syncing = _mergeWithCloud(user);
  }

  /// Puts the device back to a fresh state.
  Future<void> _clearLocal() async {
    _track = null;
    _completed = {};
    _syncFailed = false;
    notifyListeners();
    await prefs.remove(_trackKey);
    await prefs.remove(_completedKey);
    await prefs.remove(_syncedUidKey);
    await prefs.remove(_trackDirtyKey);
  }

  /// Combines device and cloud progress so neither side loses anything, as
  /// long as the device progress is this account's or nobody's.
  Future<void> _mergeWithCloud(AccountUser user) async {
    final s = sync;
    if (s == null) return;
    final generation = ++_generation;
    bool stale() => generation != _generation || _user?.uid != user.uid;
    _finishedDuringMerge.clear();

    try {
      final remote = await s.load(user.uid);
      if (stale()) return;

      final owner = prefs.getString(_syncedUidKey);
      final Track? finalTrack;
      if (owner != null && owner != user.uid) {
        // Left over from another account: never upload it, take the cloud's.
        // Lessons finished since this sign-in are this account's (they were
        // already sent to it), so they stay.
        _completed = {...remote.completed, ..._finishedDuringMerge};
        _track = finalTrack = remote.track;
        await _saveLocal();
        if (remote.needsRepair) {
          await s.replace(user.uid, track: finalTrack, completed: {..._completed});
        }
      } else {
        final localOnly = _completed.difference(remote.completed);
        final local = _track;
        final dirty = prefs.getBool(_trackDirtyKey) ?? false;
        final pushTrack = local != null && (dirty || remote.track == null);
        finalTrack = pushTrack ? local : (remote.track ?? local);

        _completed.addAll(remote.completed);
        _track = finalTrack;
        await _saveLocal();

        if (remote.needsRepair) {
          // One write with everything, so the rules accept it.
          await s.replace(user.uid, track: finalTrack, completed: {..._completed});
        } else {
          if (localOnly.isNotEmpty) await s.addCompleted(user.uid, localOnly);
          if (stale()) return;
          if (pushTrack && local != remote.track) await s.setTrack(user.uid, local);
        }
      }
      if (stale()) return;
      if (_track == finalTrack) await prefs.setBool(_trackDirtyKey, false);
      await prefs.setString(_syncedUidKey, user.uid);
      _syncFailed = false;
      notifyListeners();
    } catch (e) {
      // Offline or misconfigured: keep working from the device copy.
      debugPrint('Progress sync failed: $e');
      if (!stale()) {
        _syncFailed = true;
        notifyListeners();
      }
    }
  }

  Future<void> _saveLocal() async {
    await prefs.setStringList(_completedKey, _completed.toList());
    final t = _track;
    if (t == null) {
      await prefs.remove(_trackKey);
    } else {
      await prefs.setString(_trackKey, t.name);
    }
  }

  /// Deletes the signed-in account, its cloud progress and the progress on
  /// this device. Throws [AccountException] if the account wasn't deleted;
  /// the cloud progress is then put back.
  ///
  /// Call it straight from the button press: the first thing it does is
  /// the confirming sign-in, which opens a pop-up on the web.
  Future<void> deleteAccount() async {
    final u = _user;
    if (u == null) throw const AccountException(AccountErrorKind.notSignedIn);
    final proof = await accounts.reauthenticate();
    _generation++; // Drop any merge still running for this account.
    final s = sync;

    var remote = const RemoteProgress();
    if (s != null) {
      // Read from the server: offline, this fails before anything is
      // deleted. The copy is kept to put back if deleting the account fails.
      remote = await _server(s.load(u.uid, fromServer: true));
      try {
        // The document goes before the account: once the account is gone,
        // the security rules no longer let this app delete it.
        await _server(s.deleteAll(u.uid));
      } catch (_) {
        // A timed-out delete may still be queued; the restore is queued
        // after it, so the document ends up back either way.
        await _restoreCloud(s, u.uid, remote);
        rethrow;
      }
    }

    try {
      await _server(accounts.deleteUser(proof));
    } catch (_) {
      if (!await accounts.accountStillExists()) {
        // The error came after the account was in fact removed.
        await _clearLocal();
        return;
      }
      if (s != null) await _restoreCloud(s, u.uid, remote);
      rethrow;
    }
    await _clearLocal();
  }

  static Future<T> _server<T>(Future<T> step) async {
    try {
      return await step.timeout(serverTimeout);
    } on AccountException {
      rethrow;
    } on TimeoutException catch (e) {
      throw AccountException(AccountErrorKind.network, e);
    } catch (e) {
      // Firestore reports being offline as an error from the server read.
      throw AccountException(AccountErrorKind.network, e);
    }
  }

  /// Puts back everything the cloud and this device knew.
  Future<void> _restoreCloud(ProgressSync s, String uid, RemoteProgress remote) async {
    try {
      await s
          .replace(uid,
              track: _track ?? remote.track,
              completed: {...remote.completed, ..._completed})
          .timeout(serverTimeout);
    } catch (e) {
      debugPrint('Restoring cloud progress failed: $e');
    }
  }

  /// Sends one change to the cloud without making the UI wait for it.
  /// Firestore queues writes while offline and sends them later.
  void _push(Future<void> Function(ProgressSync s, String uid) write) {
    final s = sync;
    final u = _user;
    if (s == null || u == null) return;
    unawaited(write(s, u.uid).catchError((Object e) {
      // Shown on the Progress screen, which offers a retry (a full merge,
      // which also repairs a document the rules refuse).
      debugPrint('Progress sync failed: $e');
      if (_user?.uid == u.uid) {
        _syncFailed = true;
        notifyListeners();
      }
    }));
  }

  /// Units shown for the learner's track, or every unit if none is chosen.
  List<Unit> get visibleUnits {
    final c = _course;
    if (c == null) return const [];
    final t = _track;
    return t == null ? c.units : c.unitsFor(t);
  }

  int get totalLessons =>
      visibleUnits.fold(0, (sum, u) => sum + u.lessons.length);

  int get completedCount => visibleUnits
      .expand((u) => u.lessons)
      .where((l) => _completed.contains(l.id))
      .length;

  @override
  void dispose() {
    _userSub.cancel();
    super.dispose();
  }
}

/// Makes [AppState] available to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  /// For build methods: rebuilds the caller when the state changes.
  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// For callbacks and init code: reads the state without subscribing.
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
