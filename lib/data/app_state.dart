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

  /// Completes when the latest sign-in merge has finished.
  Future<void> syncing = Future.value();

  Course? get course => _course;
  Track? get track => _track;
  Set<String> get completedLessons => Set.unmodifiable(_completed);
  AccountUser? get user => _user;

  Future<void> load() async {
    _course = await repository.loadCourse();
    notifyListeners();
  }

  Future<void> chooseTrack(Track track) async {
    _track = track;
    await prefs.setString(_trackKey, track.name);
    notifyListeners();
    _push((s, uid) => s.setTrack(uid, track));
  }

  bool isCompleted(String lessonId) => _completed.contains(lessonId);

  Future<void> markCompleted(String lessonId) async {
    if (_completed.add(lessonId)) {
      await prefs.setStringList(_completedKey, _completed.toList());
      notifyListeners();
      _push((s, uid) => s.addCompleted(uid, [lessonId]));
    }
  }

  void _onUserChanged(AccountUser? user) {
    _user = user;
    notifyListeners();
    if (user != null) syncing = _mergeWithCloud(user);
  }

  /// Combines device and cloud progress so neither side loses anything.
  Future<void> _mergeWithCloud(AccountUser user) async {
    final s = sync;
    if (s == null) return;
    try {
      final remote = await s.load(user.uid);

      final localOnly = _completed.difference(remote.completed);
      final remoteOnly = remote.completed.difference(_completed);
      if (remoteOnly.isNotEmpty) {
        _completed.addAll(remoteOnly);
        await prefs.setStringList(_completedKey, _completed.toList());
      }
      if (localOnly.isNotEmpty) await s.addCompleted(user.uid, localOnly);

      // The choice made on this device wins; a fresh device takes the cloud's.
      final local = _track;
      if (local == null && remote.track != null) {
        _track = remote.track;
        await prefs.setString(_trackKey, remote.track!.name);
      } else if (local != null && local != remote.track) {
        await s.setTrack(user.uid, local);
      }
      notifyListeners();
    } catch (e) {
      // Offline or misconfigured: keep working from the device copy.
      debugPrint('Progress sync failed: $e');
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

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
