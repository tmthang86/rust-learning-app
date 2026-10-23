import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
      return RunResult.unavailableFor(const RunIssue(RunIssueKind.timeout));
    } catch (_) {
      return RunResult.unavailableFor(
        const RunIssue(RunIssueKind.unreachable),
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
      return RunResult.unavailableFor(errorIssue(response));
    }
    try {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) throw const FormatException();
      return RunResult.fromJson(body);
    } on FormatException {
      return RunResult.unavailableFor(
        const RunIssue(RunIssueKind.unreadable),
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
  /// to the real environment; tests pass them.
  static RunIssue errorIssue(
    http.Response response, {
    bool debug = kDebugMode,
    bool web = kIsWeb,
    TargetPlatform? platform,
  }) {
    final status = response.statusCode;
    final wait = _retryAfterSeconds(response);
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
      if (text.isEmpty || text.startsWith('<') || text.length > 200) return null;
      return text;
    }
  }
}

/// Used when no runner URL is configured.
class PlaceholderCodeRunner implements CodeRunner {
  const PlaceholderCodeRunner();

  @override
  Future<RunResult> run(String source) async => RunResult.unavailableFor(
    const RunIssue(RunIssueKind.notConfigured),
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
