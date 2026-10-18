import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// Loads course content bundled under assets/content/.
class CourseRepository {
  CourseRepository({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  Future<Course> loadCourse() async {
    final raw = await _bundle.loadString('assets/content/course.json');
    return Course.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Returns null when the lesson hasn't been written yet.
  Future<Lesson?> loadLesson(String id) async {
    try {
      final raw = await _bundle.loadString('assets/content/lessons/$id.json');
      return Lesson.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FlutterError {
      return null;
    }
  }
}
