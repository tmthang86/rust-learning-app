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
  });

  final bool success;
  final RunStage stage;
  final String stdout;

  /// Compiler errors, runtime panics or a problem reaching the runner.
  final String stderr;

  factory RunResult.fromJson(Map<String, dynamic> json) => RunResult(
        success: json['success'] as bool,
        stage: RunStage.values.asNameMap()[json['stage']] ?? RunStage.run,
        stdout: json['stdout'] as String? ?? '',
        stderr: json['stderr'] as String? ?? '',
      );

  factory RunResult.unavailable(String message) =>
      RunResult(success: false, stage: RunStage.unavailable, stderr: message);
}

/// Compiles and runs Rust source code outside the app.
abstract class CodeRunner {
  Future<RunResult> run(String source);
}

/// Sends code to the runner service in `runner/`.
class HttpCodeRunner implements CodeRunner {
  HttpCodeRunner(this.baseUrl, {http.Client? client})
      : _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  /// Longer than the server's own job limit so its timeout message wins.
  static const requestTimeout = Duration(seconds: 30);

  @override
  Future<RunResult> run(String source) async {
    try {
      final response = await _client
          .post(
            baseUrl.resolve('run'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'code': source}),
          )
          .timeout(requestTimeout);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        return RunResult.unavailable(
            body['error'] as String? ?? 'The code runner returned an error.');
      }
      return RunResult.fromJson(body);
    } on TimeoutException {
      return RunResult.unavailable('The code runner took too long to answer.');
    } catch (_) {
      return RunResult.unavailable(
          "Couldn't reach the code runner. Check your connection and try again.");
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

/// Picks the runner from the RUNNER_URL build setting.
CodeRunner codeRunnerFromEnvironment() {
  const url = String.fromEnvironment('RUNNER_URL');
  if (url.isEmpty) return const PlaceholderCodeRunner();
  return HttpCodeRunner(Uri.parse(url.endsWith('/') ? url : '$url/'));
}
