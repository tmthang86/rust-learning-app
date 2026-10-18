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
    await prefs.setBool(_trackDirtyKey, true);
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

    try {
      final remote = await s.load(user.uid);
      if (stale()) return;

      final owner = prefs.getString(_syncedUidKey);
      if (owner != null && owner != user.uid) {
        // Left over from another account: never upload it, take the cloud's.
        _completed = {...remote.completed};
        _track = remote.track;
        await _saveLocal();
        await prefs.setBool(_trackDirtyKey, false);
      } else {
        final localOnly = _completed.difference(remote.completed);
        final remoteOnly = remote.completed.difference(_completed);
        if (remoteOnly.isNotEmpty) {
          _completed.addAll(remoteOnly);
          await prefs.setStringList(_completedKey, _completed.toList());
        }
        if (localOnly.isNotEmpty) await s.addCompleted(user.uid, localOnly);
        if (stale()) return;

        final local = _track;
        final dirty = prefs.getBool(_trackDirtyKey) ?? false;
        if (local != null && (dirty || remote.track == null)) {
          if (local != remote.track) await s.setTrack(user.uid, local);
          if (stale()) return;
          if (_track == local) await prefs.setBool(_trackDirtyKey, false);
        } else if (remote.track != null) {
          _track = remote.track;
          await prefs.setString(_trackKey, remote.track!.name);
          await prefs.setBool(_trackDirtyKey, false);
        }
      }
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
  /// this device. Throws if the account could not be deleted; the cloud
  /// progress is then put back from the device copy.
  Future<void> deleteAccount() async {
    final u = _user;
    if (u == null) return;
    final s = sync;
    _generation++; // Drop any merge still running for this account.

    // The cloud document goes first: once the account is gone, the
    // security rules no longer let this app delete it.
    if (s != null) await s.deleteAll(u.uid);
    try {
      await accounts.deleteAccount();
    } catch (_) {
      if (s != null) await _restoreCloud(s, u.uid);
      rethrow;
    }
    await _clearLocal();
  }

  Future<void> _restoreCloud(ProgressSync s, String uid) async {
    try {
      if (_completed.isNotEmpty) await s.addCompleted(uid, _completed);
      final t = _track;
      if (t != null) await s.setTrack(uid, t);
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
      debugPrint('Progress sync failed: $e');
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
