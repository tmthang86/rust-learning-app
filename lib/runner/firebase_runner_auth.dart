import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

import 'code_runner.dart';

/// Gets App Check tokens from Firebase. Only use it after
/// `FirebaseAppCheck.instance.activate` succeeded (see `lib/main.dart`).
///
/// It lives apart from `code_runner.dart` so that code and its tests don't
/// need the Firebase plugins.
class FirebaseRunnerAuth implements RunnerAuth {
  /// [fetch] replaces the call to Firebase in tests.
  FirebaseRunnerAuth({
    Future<String?> Function(bool forceRefresh)? fetch,
    this.timeout = const Duration(seconds: 10),
  }) : _fetch =
           fetch ?? ((refresh) => FirebaseAppCheck.instance.getToken(refresh));

  final Future<String?> Function(bool forceRefresh) _fetch;

  /// How long to wait for a token before sending the request without one.
  final Duration timeout;

  @override
  Future<String?> appCheckToken({bool refresh = false}) async {
    try {
      final token = await _fetch(refresh).timeout(timeout);
      return token == null || token.isEmpty ? null : token;
    } catch (e) {
      // The runner answers a missing token with its own message. Never log
      // the token itself.
      debugPrint('No App Check token: $e');
      return null;
    }
  }
}
