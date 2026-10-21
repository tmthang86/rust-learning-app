import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'language.dart';
import 'models.dart';

/// Loads course content bundled under assets/content/.
///
/// English is the source: `assets/content/course.json` and
/// `assets/content/lessons/<id>.json`. Other languages mirror those files
/// under `assets/content/<code>/` (`course.json`, `lessons/<id>.json`) and
/// translate only the texts. A missing or unusable translated file falls
/// back to the English one, so the course never has holes and progress,
/// quiz scoring and exercise checks, which depend on ids and positions
/// only, don't change with the language.
class CourseRepository {
  CourseRepository({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  static final _codePattern = RegExp(r'^[a-z]{2,3}$');

  /// [language] is a language code such as 'vi'. Anything that isn't a
  /// plain code, and 'en', loads the English course.
  Future<Course> loadCourse({String language = defaultLanguageCode}) async {
    final raw = await _bundle.loadString('assets/content/course.json');
    final english = Course.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (!_isTranslation(language)) return english;
    final translated = await _tryLoadString(
      'assets/content/$language/course.json',
    );
    if (translated == null) return english;
    try {
      return english.withTextsFrom(
        Course.fromJson(jsonDecode(translated) as Map<String, dynamic>),
      );
    } catch (e) {
      debugPrint('The $language course titles are unusable: $e');
      return english;
    }
  }

  /// Returns null when the lesson hasn't been written yet. A lesson file
  /// that exists but can't be parsed throws, so screens can tell the two
  /// apart. (That is about the English file; a translation that is missing
  /// or doesn't fit it just gives the English lesson.)
  Future<Lesson?> loadLesson(
    String id, {
    String language = defaultLanguageCode,
  }) async {
    final raw = await _tryLoadString('assets/content/lessons/$id.json');
    if (raw == null) return null;
    final english = Lesson.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (!_isTranslation(language)) return english;
    final translated = await _tryLoadString(
      'assets/content/$language/lessons/$id.json',
    );
    if (translated == null) return english;
    try {
      final lesson = Lesson.fromJson(
        jsonDecode(translated) as Map<String, dynamic>,
      );
      if (lesson.hasSameStructureAs(english)) return lesson;
      debugPrint('The $language lesson $id does not match the English one.');
    } catch (e) {
      debugPrint('The $language lesson $id is unusable: $e');
    }
    return english;
  }

  static bool _isTranslation(String language) =>
      language != defaultLanguageCode && _codePattern.hasMatch(language);

  Future<String?> _tryLoadString(String key) async {
    try {
      return await _bundle.loadString(key);
    } on FlutterError {
      return null;
    }
  }
}
