/// Words for the tests panel. Kept in one place, like [HelpStrings], so they
/// can move to the translation files together once those land. The keys are
/// the ones the design names (`testsSummary`, `hiddenSummary`, ...).
abstract final class ExerciseTestStrings {
  static String testsSummary(int passed, int total) =>
      'Tests: $passed of $total passed';
  static String hiddenSummary(int passed, int total) =>
      'Hidden tests: $passed of $total passed';
  static const testsHeading = 'Tests';

  // What a row says besides the test's label. Never colour alone.
  static const statusPassed = 'Passed';
  static const statusFailed = 'Failed';
  static const statusTookTooLong = 'Took too long';
  static const statusDidNotRun = "Didn't run";
  static const statusCrashed = 'Stopped';
  static const statusCouldNotRun = "Couldn't run";

  static const rowHintShow = 'Double tap to show details';
  static const rowHintHide = 'Double tap to hide details';

  // Inside an expanded row.
  static const testChecked = 'Checked';
  static const testExpected = 'Expected';
  static const testGot = 'Got';
  static const testPrinted = 'Printed during this test';
  static const testShowCode = 'See the test code';
  static String testPanicked(String message) => 'The code panicked: $message';
  static String testPanickedAt(String message, int line) =>
      'The code panicked at line $line: $message';
  static const testDidNotPanic =
      'This test expects the code to panic, but it did not.';
  static const testTimedOut = 'The code took too long to finish.';
  static const testNotRun = "This test didn't run.";
  static String firstDifference(int line) => 'First difference: line $line';
  static const missingLine = '(nothing)';

  static const testsCantUseYourCode =
      'Your code compiles, but the tests can\'t use it. Keep the names and '
      'types from the starter.';
  static String hiddenTestCantUseYourCode(String message) =>
      "A hidden test couldn't use your code: $message";
  static const hiddenOnlyFailing =
      'Your code passes the examples but not every hidden test. Try other '
      'inputs, like edge cases.';

  /// The label of the legacy output test (a lesson with `expectedOutput`).
  static const legacyOutputLabel = 'The program prints the expected output';

  static const allTestsPassed = 'Correct! Nice work.';
  static const notQuiteYet = 'Not quite yet. Keep trying.';

  // Screen reader announcement after a run.
  static String announceSummary(int passed, int total) =>
      '$passed of $total ${total == 1 ? 'test' : 'tests'} passed.';
  static String announceFailed(String label) => 'Failed: $label.';
  static String announceHiddenFailed(int count) =>
      count == 1 ? '1 hidden test failed.' : '$count hidden tests failed.';
  static String rowLabel(String status, String label) => '$status: $label';

  // Why a test stopped, one per machine code the runner sends.
  static const reasonMemLimit = 'The program used too much memory.';
  static const reasonOutputLimit = 'The program printed too much output.';
  static const reasonStackOverflow =
      'The program overflowed its stack (a function calling itself too deeply).';
  static String reasonExit(String code) =>
      'The program stopped with exit code $code.';
  static const reasonNoMain = 'The tests could not find your main function.';
  static const reasonTestsDontFit =
      "This test couldn't use your code. Keep the names and types from the starter.";
  static const reasonHarness =
      'The tests could not be built with your code. Please try again, or '
      'start from the starter.';
  static const reasonUnknown = 'The program stopped unexpectedly.';

  /// The sentence for a runner `reason` code (`exit:3` and the like).
  static String reason(String code) {
    if (code.startsWith('exit:')) return reasonExit(code.substring(5));
    return switch (code) {
      'mem_limit' => reasonMemLimit,
      'output_limit' => reasonOutputLimit,
      'stack_overflow' => reasonStackOverflow,
      'no_main' => reasonNoMain,
      'tests_dont_fit' => reasonTestsDontFit,
      'harness' => reasonHarness,
      _ => reasonUnknown,
    };
  }

  // Problems reaching the grader.
  static const runnerNeedsUpdate =
      'The code runner needs an update. Try again later.';
  static const testsInvalid =
      "This exercise couldn't be checked. Please update the app.";
}
