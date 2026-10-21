import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/models.dart';
import '../l10n/exercise_test_strings.dart';

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

/// How one test ended, as the runner reports it.
enum TestStatus {
  pass,
  fail,
  panic,
  nopanic,
  error,
  timeout,
  crashed,
  notRun;

  static TestStatus? fromWire(Object? name) => switch (name) {
        'pass' => pass,
        'fail' => fail,
        'panic' => panic,
        'nopanic' => nopanic,
        'error' => error,
        'timeout' => timeout,
        'crashed' => crashed,
        'not_run' => notRun,
        _ => null,
      };
}

/// The result of one test of a graded run.
class TestResult {
  const TestResult({
    required this.id,
    required this.status,
    this.expr,
    this.expected,
    this.actual,
    this.output,
    this.message,
    this.line,
    this.reason,
  });

  final String id;
  final TestStatus status;

  /// A failed check: what was checked, what it should be, what it was.
  final String? expr;
  final String? expected;
  final String? actual;

  /// What the test printed.
  final String? output;

  /// A panic message, or a compiler diagnostic's one-line message.
  final String? message;

  /// The learner's source line of a panic.
  final int? line;

  /// A machine code (`mem_limit`, `exit:3`, `tests_dont_fit`, ...).
  final String? reason;

  /// Throws [FormatException] when [json] isn't a test result.
  factory TestResult.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final status = TestStatus.fromWire(json['status']);
    if (id is! String || status == null) {
      throw const FormatException('test result without an id or status');
    }
    String? text(String key) {
      final v = json[key];
      return v is String ? v : null;
    }

    final line = json['line'];
    return TestResult(
      id: id,
      status: status,
      expr: text('expr'),
      expected: text('expected'),
      actual: text('actual'),
      output: text('output'),
      message: text('message'),
      line: line is int ? line : null,
      reason: text('reason'),
    );
  }
}

/// The answer to a graded run: the run itself plus one [TestResult] per test
/// of the exercise.
class GradeResult extends RunResult {
  const GradeResult({
    required super.success,
    required super.stage,
    super.stdout,
    super.stderr,
    super.warnings,
    this.tests = const [],
    this.compileErrorsIn,
    this.reason,
  });

  /// In the order the tests were sent; empty when the runner was unavailable.
  final List<TestResult> tests;

  /// `code`: the learner's own code doesn't compile (the errors are in
  /// `stderr`). `tests`: it compiles, but the tests can't use it.
  final String? compileErrorsIn;

  /// A machine code for a problem that isn't about one test.
  final String? reason;

  /// Throws [FormatException] when [json] isn't a graded run.
  factory GradeResult.fromJson(Map<String, dynamic> json) {
    final base = RunResult.fromJson(json);
    final tests = json['tests'];
    if (tests is! List) {
      throw const FormatException('graded run without "tests"');
    }
    final where = json['compileErrorsIn'];
    final reason = json['reason'];
    return GradeResult(
      success: base.success,
      stage: base.stage,
      stdout: base.stdout,
      stderr: base.stderr,
      warnings: base.warnings,
      tests: tests
          .map((t) => TestResult.fromJson(t as Map<String, dynamic>))
          .toList(),
      compileErrorsIn: where is String ? where : null,
      reason: reason is String ? reason : null,
    );
  }

  factory GradeResult.unavailable(String message) => GradeResult(
        success: false,
        stage: RunStage.unavailable,
        stderr: message,
      );

  /// The result of the test with [id], if the runner sent one.
  TestResult? testById(String id) {
    for (final t in tests) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Whether every one of [exercise] passed, hidden tests included. Never
  /// true when the runner couldn't be reached or sent fewer results.
  bool solves(List<ExerciseTest> exercise) =>
      stage != RunStage.unavailable &&
      exercise.isNotEmpty &&
      exercise.every((t) => testById(t.id)?.status == TestStatus.pass);
}

/// Compiles and runs Rust source code outside the app.
abstract class CodeRunner {
  Future<RunResult> run(String source);

  /// Compiles [source] together with [tests] and reports each one. Unlike
  /// [run] the answer always has `tests`; a runner that can't be reached
  /// answers with [GradeResult.unavailable].
  Future<GradeResult> grade(String source, List<ExerciseTest> tests);
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
  Future<RunResult> run(String source) => _request(
        'run',
        {'code': source},
        parse: RunResult.fromJson,
        unavailable: RunResult.unavailable,
      );

  @override
  Future<GradeResult> grade(String source, List<ExerciseTest> tests) =>
      _request(
        'grade',
        {
          'code': source,
          'tests': [for (final t in tests) t.toRequestJson()],
        },
        parse: GradeResult.fromJson,
        unavailable: GradeResult.unavailable,
      );

  Future<T> _request<T extends RunResult>(
    String path,
    Map<String, Object?> body, {
    required T Function(Map<String, dynamic>) parse,
    required T Function(String) unavailable,
  }) async {
    try {
      return await _requestWithRetry(
        path,
        body,
        parse,
        unavailable,
      ).timeout(requestTimeout);
    } on TimeoutException {
      return unavailable('The code runner took too long to answer.');
    } catch (_) {
      return unavailable(
        "Couldn't reach the code runner. Check your connection and try again.",
      );
    }
  }

  Future<T> _requestWithRetry<T extends RunResult>(
    String path,
    Map<String, Object?> body,
    T Function(Map<String, dynamic>) parse,
    T Function(String) unavailable,
  ) async {
    var response = await _post(path, body, await auth.appCheckToken());

    // A token the runner rejected may just be stale, and a missing one may
    // be available by now. Ask for a fresh one, once, and send once more.
    if (response.statusCode == 401) {
      final code = _errorCode(response.body);
      if (code == 'app_check_invalid' || code == 'app_check_missing') {
        final fresh = await auth.appCheckToken(refresh: true);
        if (fresh != null) response = await _post(path, body, fresh);
      }
    }

    if (response.statusCode != 200) {
      return unavailable(errorMessage(response, grade: path == 'grade'));
    }
    try {
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) throw const FormatException();
      return parse(json);
    } on FormatException {
      return unavailable(
        'The code runner sent an answer the app could not read. '
        'Please try again.',
      );
    }
  }

  Future<http.Response> _post(
    String path,
    Map<String, Object?> body,
    String? appCheckToken,
  ) {
    return _client.post(
      baseUrl.resolve(path),
      headers: {
        'content-type': 'application/json',
        appCheckHeader: ?appCheckToken,
      },
      body: jsonEncode(body),
    );
  }

  /// Turns an error response into a message for the learner. The runner
  /// answers errors with JSON `{"error": "...", "code": "..."}`, but
  /// proxies and load balancers in front of it may answer with plain text
  /// or HTML.
  ///
  /// The 401 text depends on where the app runs: a debug build, the web and
  /// each store need different advice. [debug], [web] and [platform] default
  /// to the real environment; tests pass them. With [grade] set, the answer
  /// came from `/grade`: a 404 means a runner that doesn't have it yet, and
  /// `tests_invalid` means an exercise this app version can't send.
  static String errorMessage(
    http.Response response, {
    bool debug = kDebugMode,
    bool web = kIsWeb,
    TargetPlatform? platform,
    bool grade = false,
  }) {
    final status = response.statusCode;
    final wait = _retryAfterSeconds(response);
    if (grade && status == 404) return ExerciseTestStrings.runnerNeedsUpdate;
    if (grade && status == 400 && _errorCode(response.body) == 'tests_invalid') {
      return ExerciseTestStrings.testsInvalid;
    }
    switch (status) {
      case 401:
        return _unverifiedMessage(
          debug: debug,
          web: web,
          platform: platform ?? defaultTargetPlatform,
        );
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

  static String _unverifiedMessage({
    required bool debug,
    required bool web,
    required TargetPlatform platform,
  }) {
    const start = "This copy of the app couldn't be verified, so code can't "
        'run right now. ';
    if (debug) {
      return '${start}This is a debug build: add its App Check debug token in '
          'the Firebase console (App Check, Apps, Manage debug tokens) and '
          'try again.';
    }
    if (web) return '${start}Reload the page and try again.';
    switch (platform) {
      case TargetPlatform.iOS:
        return '${start}Make sure the app is up to date (from the App Store) '
            'and try again.';
      case TargetPlatform.android:
        return '${start}Make sure the app is up to date (from Google Play) '
            'and try again.';
      default:
        return '${start}Make sure the app is up to date and try again.';
    }
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

  static const _notSetUp = 'Running code is not set up in this build. '
      'Build with --dart-define=RUNNER_URL=<runner address>.';

  @override
  Future<RunResult> run(String source) async =>
      RunResult.unavailable(_notSetUp);

  @override
  Future<GradeResult> grade(String source, List<ExerciseTest> tests) async =>
      GradeResult.unavailable(_notSetUp);
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
