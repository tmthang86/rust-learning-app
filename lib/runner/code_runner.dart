import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// How far a run got.
enum RunStage {
  /// The code didn't compile; `stderr` holds the compiler errors.
  compile,

  /// The program compiled and ran (it may still have panicked).
  run,

  /// The program hit the time limit.
  timeout,

  /// The runner couldn't be reached or returned an error.
  unavailable,
}

/// Result of compiling and running a Rust program.
class RunResult {
  const RunResult({
    required this.success,
    required this.stage,
    this.stdout = '',
    this.stderr = '',
    this.warnings = '',
  });

  final bool success;
  final RunStage stage;
  final String stdout;

  /// Compiler errors (compile stage), the program's own stderr and panics
  /// (run stage), or a problem reaching the runner (unavailable).
  final String stderr;

  /// Compiler warnings from a build that succeeded. The program still ran.
  final String warnings;

  /// Throws [FormatException] when [json] isn't a run result.
  factory RunResult.fromJson(Map<String, dynamic> json) {
    final success = json['success'];
    if (success is! bool) {
      throw const FormatException('run result has no "success" flag');
    }
    String text(String key) {
      final v = json[key];
      return v is String ? v : '';
    }

    return RunResult(
      success: success,
      stage: RunStage.values.asNameMap()[json['stage']] ?? RunStage.run,
      stdout: text('stdout'),
      stderr: text('stderr'),
      warnings: text('warnings'),
    );
  }

  factory RunResult.unavailable(String message) =>
      RunResult(success: false, stage: RunStage.unavailable, stderr: message);
}

/// Compiles and runs Rust source code outside the app.
abstract class CodeRunner {
  Future<RunResult> run(String source);
}

/// Proves to the runner that a request comes from this app.
abstract class RunnerAuth {
  /// A Firebase App Check token, or null when none is available. With
  /// [refresh] set, a new token is requested instead of the cached one.
  Future<String?> appCheckToken({bool refresh = false});
}

/// Used when Firebase or App Check isn't set up in this build (and when
/// talking to a development runner). The request is sent without a token.
class NoRunnerAuth implements RunnerAuth {
  const NoRunnerAuth();

  @override
  Future<String?> appCheckToken({bool refresh = false}) async => null;
}

/// Sends code to the runner service in `runner/`.
class HttpCodeRunner implements CodeRunner {
  HttpCodeRunner(
    this.baseUrl, {
    http.Client? client,
    this.auth = const NoRunnerAuth(),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  /// Adds the App Check token to each request.
  final RunnerAuth auth;

  /// Header the runner reads the App Check token from.
  static const appCheckHeader = 'X-Firebase-AppCheck';

  /// Longer than the server's worst case (up to about 10 s waiting for a
  /// free slot plus 20 s for the job), so its own messages win. It covers
  /// everything in one run, including a retry with a fresh token.
  static const requestTimeout = Duration(seconds: 45);

  @override
  Future<RunResult> run(String source) async {
    try {
      return await _runWithRetry(source).timeout(requestTimeout);
    } on TimeoutException {
      return RunResult.unavailable('The code runner took too long to answer.');
    } catch (_) {
      return RunResult.unavailable(
        "Couldn't reach the code runner. Check your connection and try again.",
      );
    }
  }

  Future<RunResult> _runWithRetry(String source) async {
    var response = await _post(source, await auth.appCheckToken());

    // A token the runner rejected may just be stale, and a missing one may
    // be available by now. Ask for a fresh one, once, and send once more.
    if (response.statusCode == 401) {
      final code = _errorCode(response.body);
      if (code == 'app_check_invalid' || code == 'app_check_missing') {
        final fresh = await auth.appCheckToken(refresh: true);
        if (fresh != null) response = await _post(source, fresh);
      }
    }

    if (response.statusCode != 200) {
      return RunResult.unavailable(errorMessage(response));
    }
    try {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) throw const FormatException();
      return RunResult.fromJson(body);
    } on FormatException {
      return RunResult.unavailable(
        'The code runner sent an answer the app could not read. '
        'Please try again.',
      );
    }
  }

  Future<http.Response> _post(String source, String? appCheckToken) {
    return _client.post(
      baseUrl.resolve('run'),
      headers: {
        'content-type': 'application/json',
        appCheckHeader: ?appCheckToken,
      },
      body: jsonEncode({'code': source}),
    );
  }

  /// Turns an error response into a message for the learner. The runner
  /// answers errors with JSON `{"error": "...", "code": "..."}`, but
  /// proxies and load balancers in front of it may answer with plain text
  /// or HTML.
  static String errorMessage(http.Response response) {
    final status = response.statusCode;
    final wait = _retryAfterSeconds(response);
    switch (status) {
      case 401:
        return "This copy of the app couldn't be verified, so code can't run "
            'right now. Make sure the app is up to date (from the App Store '
            'or Google Play) and try again.';
      case 403:
        return "This version of the app can't run code. Please update the app.";
      case 413:
        return 'Your code is too long to run. Try making it shorter.';
      case 429:
        if (_errorCode(response.body) == 'rate_limited') {
          return wait != null
              ? "You're running code very quickly. Try again in $wait seconds."
              : "You're running code very quickly. Try again in a minute.";
        }
        return _busyMessage(wait);
      case 503:
        return _busyMessage(wait);
    }

    final fromServer = _serverError(response.body);
    if (fromServer == 'code is empty') {
      return 'There is no code to run yet. Write some code, then press Run.';
    }
    if (fromServer != null) return fromServer;
    if (status == 408) return 'The code runner took too long to answer.';
    return 'The code runner had a problem (error $status). Please try again.';
  }

  static String _busyMessage(int? wait) => wait != null
      ? 'The code runner is busy. Try again in $wait seconds.'
      : 'The code runner is busy. Try again shortly.';

  /// Seconds from a usable `Retry-After` header, else null.
  static int? _retryAfterSeconds(http.Response response) {
    final wait = int.tryParse(response.headers['retry-after']?.trim() ?? '');
    return wait != null && wait > 0 && wait <= 600 ? wait : null;
  }

  /// The `code` field of a JSON error body, or null.
  static String? _errorCode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['code'] is String) return json['code'] as String;
    } on FormatException {
      // Not JSON (a proxy's page): no code.
    }
    return null;
  }

  /// The `error` field of a JSON error body, or a short plain-text body.
  static String? _serverError(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is String) {
        final e = (json['error'] as String).trim();
        if (e.isNotEmpty) return e;
      }
      return null;
    } on FormatException {
      final text = body.trim();
      // Plain text is shown; an HTML error page is not.
      if (text.isEmpty || text.startsWith('<') || text.length > 200) return null;
      return text;
    }
  }
}

/// Used when no runner URL is configured.
class PlaceholderCodeRunner implements CodeRunner {
  const PlaceholderCodeRunner();

  @override
  Future<RunResult> run(String source) async => RunResult.unavailable(
        'Running code is not set up in this build. '
        'Build with --dart-define=RUNNER_URL=<runner address>.',
      );
}

/// Picks the runner from the RUNNER_URL build setting. [auth] adds the App
/// Check token; without it requests carry no token (fine for a development
/// runner, refused by a production one).
CodeRunner codeRunnerFromEnvironment({RunnerAuth auth = const NoRunnerAuth()}) {
  const url = String.fromEnvironment('RUNNER_URL');
  if (url.isEmpty) return const PlaceholderCodeRunner();
  return HttpCodeRunner(
    Uri.parse(url.endsWith('/') ? url : '$url/'),
    auth: auth,
  );
}
