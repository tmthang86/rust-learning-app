/// Words for hints, solutions and error explanations. Kept in one place so
/// they can move to the translation files together.
abstract final class HelpStrings {
  // Hints and solution.
  static String showHintLeft(int left) => 'Show a hint ($left left)';
  static String hintLabel(int number, int total, String hint) =>
      'Hint $number of $total: $hint';
  static const showSolution = 'Show solution';
  static const solutionHeading = 'Solution';
  static const solutionNote =
      'Seeing the solution does not finish the lesson. '
      'Run your code to complete it.';
  static const copyToEditor = 'Copy to editor';
  static const copiedToEditor = 'Solution copied to the editor';
  static const putMyCodeBack = 'Put my code back';
  static const codeRestored = 'Your code is back in the editor';
  static const solutionShown = 'Solution shown below the Run button';

  // Error explanations.
  static const errorCardHeading = 'What this error means';
  static String errorTitle(String key, String title) => '$key: $title';
  static const fixesHeading = 'How to fix it';
  static String reviewLesson(String title) => 'Review lesson: $title';
  static const officialPage = 'More about this error (official Rust page):';
}
