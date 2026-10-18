/// Result of compiling and running a Rust program.
class RunResult {
  const RunResult({
    required this.success,
    this.stdout = '',
    this.stderr = '',
  });

  final bool success;
  final String stdout;

  /// Compiler errors and warnings, or runtime panics.
  final String stderr;
}

/// Compiles and runs Rust source code somewhere outside the app.
///
/// Step 2 of the plan adds the real implementation: a sandboxed server
/// that runs `rustc` and returns the output.
abstract class CodeRunner {
  Future<RunResult> run(String source);
}

/// Placeholder used until the runner backend exists.
class PlaceholderCodeRunner implements CodeRunner {
  const PlaceholderCodeRunner();

  @override
  Future<RunResult> run(String source) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const RunResult(
      success: false,
      stderr: 'Running code is not connected yet. '
          'The code runner arrives in the next step.',
    );
  }
}
