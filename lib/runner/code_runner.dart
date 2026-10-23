import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';

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

/// Why the runner couldn't be used. The UI shows it in the learner's
/// language with [message]; [RunResult.stderr] carries the English text too,
/// for logs and anything that has no localizations at hand.
enum RunIssueKind {
  timeout,
  unreachable,
  unreadable,
  forbidden,
  tooLong,
  rateLimited,
  busy,
  emptyCode,

  /// Text the runner itself sent ([RunIssue.text]); shown as is.
  serverText,
  problem,
  notConfigured,
  unverifiedDebug,
  unverifiedWeb,
  unverifiedIos,
  unverifiedAndroid,
  unverifiedOther,

  /// `/grade` answered 404: a runner from before exercise tests.
  runnerNeedsUpdate,

  /// `/grade` refused the tests (`tests_invalid`).
  testsInvalid,
}

class RunIssue {
  const RunIssue(this.kind, {this.seconds, this.status, this.text});

  final RunIssueKind kind;

  /// How long to wait ([RunIssueKind.rateLimited], [RunIssueKind.busy]);
  /// null when the runner didn't say.
  final int? seconds;

  /// HTTP status ([RunIssueKind.problem]).
  final int? status;

  /// The runner's own message ([RunIssueKind.serverText]).
  final String? text;

  String message(AppLocalizations l10n) => switch (kind) {
    RunIssueKind.timeout => l10n.runIssueTimeout,
    RunIssueKind.unreachable => l10n.runIssueUnreachable,
    RunIssueKind.unreadable => l10n.runIssueUnreadable,
    RunIssueKind.forbidden => l10n.runIssueForbidden,
    RunIssueKind.tooLong => l10n.runIssueTooLong,
    RunIssueKind.rateLimited =>
      seconds != null
          ? l10n.runIssueRateLimitedWait(seconds!)
          : l10n.runIssueRateLimited,
    RunIssueKind.busy =>
      seconds != null ? l10n.runIssueBusyWait(seconds!) : l10n.runIssueBusy,
    RunIssueKind.emptyCode => l10n.runIssueEmptyCode,
    RunIssueKind.serverText => text ?? '',
    RunIssueKind.problem => l10n.runIssueProblem(status ?? 0),
    RunIssueKind.notConfigured => l10n.runIssueNotConfigured,
    RunIssueKind.unverifiedDebug => l10n.runIssueUnverifiedDebug,
    RunIssueKind.unverifiedWeb => l10n.runIssueUnverifiedWeb,
    RunIssueKind.unverifiedIos => l10n.runIssueUnverifiedIos,
    RunIssueKind.unverifiedAndroid => l10n.runIssueUnverifiedAndroid,
    RunIssueKind.unverifiedOther => l10n.runIssueUnverifiedOther,
    RunIssueKind.runnerNeedsUpdate => l10n.runIssueRunnerNeedsUpdate,
    RunIssueKind.testsInvalid => l10n.runIssueTestsInvalid,
  };
}

/// Result of compiling and running a Rust program.
class RunResult {
  const RunResult({
    required this.success,
    required this.stage,
    this.stdout = '',
    this.stderr = '',
    this.warnings = '',
    this.issue,
  });

  final bool success;
  final RunStage stage;
  final String stdout;

  /// Compiler errors (compile stage), the program's own stderr and panics
  /// (run stage), or a problem reaching the runner (unavailable).
  final String stderr;

  /// Compiler warnings from a build that succeeded. The program still ran.
  final String warnings;

  /// For [RunStage.unavailable]: what went wrong, to show in the learner's
  /// language instead of [stderr].
  final RunIssue? issue;

  /// What to show for this result's [stderr]: the localized [issue] when
  /// there is one.
  String errorText(AppLocalizations l10n) => issue?.message(l10n) ?? stderr;

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

  factory RunResult.unavailable(String message, {RunIssue? issue}) => RunResult(
    success: false,
    stage: RunStage.unavailable,
    stderr: message,
    issue: issue,
  );

  /// The runner couldn't be used because of [issue]; [stderr] gets its
  /// English text.
  factory RunResult.unavailableFor(RunIssue issue) =>
      RunResult.unavailable(issue.message(AppLocalizationsEn()), issue: issue);
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
    super.issue,
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

  factory GradeResult.unavailable(String message, {RunIssue? issue}) =>
      GradeResult(
        success: false,
        stage: RunStage.unavailable,
        stderr: message,
        issue: issue,
      );

  /// The runner couldn't be used because of [issue]; [stderr] gets its
  /// English text.
  factory GradeResult.unavailableFor(RunIssue issue) => GradeResult.unavailable(
    issue.message(AppLocalizationsEn()),
    issue: issue,
  );

  /// A plain run of an exercise that only has `expectedOutput` (it costs
  /// one run, and works with a runner that has no `/grade`), as the one
  /// output test it is: compared here the way the app always has, ignoring
  /// whitespace around the whole output.
  factory GradeResult.fromLegacyRun(RunResult r, String expected) {
    if (r.stage == RunStage.unavailable) {
      return GradeResult.unavailable(r.stderr, issue: r.issue);
    }
    final TestResult test;
    switch (r.stage) {
      case RunStage.compile:
        test = const TestResult(
          id: ExerciseTest.legacyId,
          status: TestStatus.notRun,
        );
      case RunStage.timeout:
        test = const TestResult(
          id: ExerciseTest.legacyId,
          status: TestStatus.timeout,
        );
      default:
        final pass = r.success && r.stdout.trim() == expected.trim();
        test = TestResult(
          id: ExerciseTest.legacyId,
          status: pass ? TestStatus.pass : TestStatus.fail,
          expected: pass ? null : expected,
          actual: pass ? null : r.stdout,
        );
    }
    return GradeResult(
      success: r.success,
      stage: r.stage,
      stdout: r.stdout,
      stderr: r.stderr,
      warnings: r.warnings,
      tests: [test],
      compileErrorsIn: r.stage == RunStage.compile ? 'code' : null,
    );
  }

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
  /// answers with [GradeResult.unavailableFor].
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
    unavailable: RunResult.unavailableFor,
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
        unavailable: GradeResult.unavailableFor,
      );

  Future<T> _request<T extends RunResult>(
    String path,
    Map<String, Object?> body, {
    required T Function(Map<String, dynamic>) parse,
    required T Function(RunIssue) unavailable,
  }) async {
    try {
      return await _requestWithRetry(
        path,
        body,
        parse,
        unavailable,
      ).timeout(requestTimeout);
    } on TimeoutException {
      return unavailable(const RunIssue(RunIssueKind.timeout));
    } catch (_) {
      return unavailable(const RunIssue(RunIssueKind.unreachable));
    }
  }

  Future<T> _requestWithRetry<T extends RunResult>(
    String path,
    Map<String, Object?> body,
    T Function(Map<String, dynamic>) parse,
    T Function(RunIssue) unavailable,
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
      return unavailable(errorIssue(response, grade: path == 'grade'));
    }
    try {
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) throw const FormatException();
      return parse(json);
    } on FormatException {
      return unavailable(const RunIssue(RunIssueKind.unreadable));
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

  /// Turns an error response into a message for the learner, in English.
  /// See [errorIssue] for the version the UI shows in the learner's
  /// language.
  static String errorMessage(
    http.Response response, {
    bool debug = kDebugMode,
    bool web = kIsWeb,
    TargetPlatform? platform,
  }) => errorIssue(
    response,
    debug: debug,
    web: web,
    platform: platform,
  ).message(AppLocalizationsEn());

  /// Turns an error response into what went wrong. The runner answers
  /// errors with JSON `{"error": "...", "code": "..."}`, but proxies and
  /// load balancers in front of it may answer with plain text or HTML.
  ///
  /// The 401 text depends on where the app runs: a debug build, the web and
  /// each store need different advice. [debug], [web] and [platform] default
  /// to the real environment; tests pass them. With [grade] set, the answer
  /// came from `/grade`: a 404 means a runner that doesn't have it yet, and
  /// `tests_invalid` means an exercise this app version can't send.
  static RunIssue errorIssue(
    http.Response response, {
    bool debug = kDebugMode,
    bool web = kIsWeb,
    TargetPlatform? platform,
    bool grade = false,
  }) {
    final status = response.statusCode;
    final wait = _retryAfterSeconds(response);
    if (grade && status == 404) {
      return const RunIssue(RunIssueKind.runnerNeedsUpdate);
    }
    if (grade &&
        status == 400 &&
        _errorCode(response.body) == 'tests_invalid') {
      return const RunIssue(RunIssueKind.testsInvalid);
    }
    switch (status) {
      case 401:
        return _unverifiedIssue(
          debug: debug,
          web: web,
          platform: platform ?? defaultTargetPlatform,
        );
      case 403:
        return const RunIssue(RunIssueKind.forbidden);
      case 413:
        return const RunIssue(RunIssueKind.tooLong);
      case 429:
        if (_errorCode(response.body) == 'rate_limited') {
          return RunIssue(RunIssueKind.rateLimited, seconds: wait);
        }
        return RunIssue(RunIssueKind.busy, seconds: wait);
      case 503:
        return RunIssue(RunIssueKind.busy, seconds: wait);
    }

    final fromServer = _serverError(response.body);
    if (fromServer == 'code is empty') {
      return const RunIssue(RunIssueKind.emptyCode);
    }
    if (fromServer != null) {
      return RunIssue(RunIssueKind.serverText, text: fromServer);
    }
    if (status == 408) return const RunIssue(RunIssueKind.timeout);
    return RunIssue(RunIssueKind.problem, status: status);
  }

  static RunIssue _unverifiedIssue({
    required bool debug,
    required bool web,
    required TargetPlatform platform,
  }) {
    if (debug) return const RunIssue(RunIssueKind.unverifiedDebug);
    if (web) return const RunIssue(RunIssueKind.unverifiedWeb);
    return RunIssue(switch (platform) {
      TargetPlatform.iOS => RunIssueKind.unverifiedIos,
      TargetPlatform.android => RunIssueKind.unverifiedAndroid,
      _ => RunIssueKind.unverifiedOther,
    });
  }

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
      if (text.isEmpty || text.startsWith('<') || text.length > 200) {
        return null;
      }
      return text;
    }
  }
}

/// Used when no runner URL is configured.
class PlaceholderCodeRunner implements CodeRunner {
  const PlaceholderCodeRunner();

  @override
  Future<RunResult> run(String source) async =>
      RunResult.unavailableFor(const RunIssue(RunIssueKind.notConfigured));

  @override
  Future<GradeResult> grade(String source, List<ExerciseTest> tests) async =>
      GradeResult.unavailableFor(const RunIssue(RunIssueKind.notConfigured));
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
