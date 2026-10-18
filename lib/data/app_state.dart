import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runner/code_runner.dart';
import 'course_repository.dart';
import 'models.dart';

/// App-wide state: the course, the learner's track and their progress.
///
/// Progress is stored on the device for now. Account sync comes in step 3.
class AppState extends ChangeNotifier {
  AppState({
    required this.repository,
    required this.runner,
    required this.prefs,
  }) {
    _track = Track.fromName(prefs.getString(_trackKey));
    _completed = (prefs.getStringList(_completedKey) ?? const []).toSet();
  }

  static const _trackKey = 'track';
  static const _completedKey = 'completedLessons';

  final CourseRepository repository;
  final CodeRunner runner;
  final SharedPreferences prefs;

  Course? _course;
  Track? _track;
  Set<String> _completed = {};

  Course? get course => _course;
  Track? get track => _track;
  Set<String> get completedLessons => Set.unmodifiable(_completed);

  Future<void> load() async {
    _course = await repository.loadCourse();
    notifyListeners();
  }

  Future<void> chooseTrack(Track track) async {
    _track = track;
    await prefs.setString(_trackKey, track.name);
    notifyListeners();
  }

  bool isCompleted(String lessonId) => _completed.contains(lessonId);

  Future<void> markCompleted(String lessonId) async {
    if (_completed.add(lessonId)) {
      await prefs.setStringList(_completedKey, _completed.toList());
      notifyListeners();
    }
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
}

/// Makes [AppState] available to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
