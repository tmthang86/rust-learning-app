import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../app/theme.dart';
import '../../data/models.dart';
import '../../l10n/help_strings.dart';
import '../../runner/code_runner.dart';
import '../editor/code_editor.dart';
import '../editor/error_explanation_cards.dart';

/// An exercise's editor with its hints and its solution.
///
/// Hints appear one at a time under the Run row. The solution is offered
/// after a run that reached the compiler without solving the exercise.
/// Showing or copying it never completes the lesson: only a run that prints
/// the expected output does, through [onSolved].
class ExercisePanel extends StatefulWidget {
  const ExercisePanel({
    super.key,
    required this.lessonId,
    required this.exercise,
    this.onSolved,
  });

  final String lessonId;
  final Exercise exercise;
  final VoidCallback? onSolved;

  @override
  State<ExercisePanel> createState() => _ExercisePanelState();
}

class _ExercisePanelState extends State<ExercisePanel> {
  late final TextEditingController _code = TextEditingController(
    text: widget.exercise.starter,
  );

  /// One per hint, so focus can move to a hint that has just appeared.
  late final List<FocusNode> _hintFocus = [
    for (final _ in widget.exercise.hints) FocusNode(),
  ];
  final FocusNode _solutionFocus = FocusNode();
  final FocusNode _copyFocus = FocusNode();

  int _hintsShown = 0;
  bool _ranWithoutSolving = false;
  bool _solutionShown = false;

  /// The learner's code from before "Copy to editor", for "Put my code back".
  String? _backup;

  /// What a screen reader should say where announcements aren't supported
  /// (a live region); [_sayCount] makes repeats of the same text count as
  /// changes.
  String _live = '';
  int _sayCount = 0;

  @override
  void dispose() {
    _code.dispose();
    for (final n in _hintFocus) {
      n.dispose();
    }
    _solutionFocus.dispose();
    _copyFocus.dispose();
    super.dispose();
  }

  void _onRunFinished(RunResult result, bool solved) {
    // A run that never reached the compiler says nothing about the code.
    if (!solved &&
        result.stage != RunStage.unavailable &&
        !_ranWithoutSolving) {
      setState(() => _ranWithoutSolving = true);
    }
  }

  /// Tells screen readers [message]: an announcement where the platform
  /// supports them, else the live region. Call inside setState or follow
  /// with one.
  void _say(String message) {
    if (MediaQuery.supportsAnnounceOf(context)) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );
    } else {
      _live = message;
      _sayCount++;
    }
  }

  /// A button that disappears would drop keyboard and switch focus, so
  /// focus moves to what it revealed.
  void _focusAfterBuild(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) node.requestFocus();
    });
  }

  void _showHint() {
    final hints = widget.exercise.hints;
    setState(() {
      _hintsShown++;
      _say(
        HelpStrings.hintLabel(
          _hintsShown,
          hints.length,
          hints[_hintsShown - 1],
        ),
      );
    });
    if (_hintsShown == hints.length) {
      _focusAfterBuild(_hintFocus[_hintsShown - 1]);
    }
  }

  void _showSolution() {
    setState(() {
      _solutionShown = true;
      _say(HelpStrings.solutionShown);
    });
    _focusAfterBuild(_solutionFocus);
  }

  void _copySolution(String solution) {
    setState(() {
      // The first backup stays until used, so copying again keeps the
      // learner's own code.
      if (_backup == null && _code.text != solution) _backup = _code.text;
      _code.text = solution;
      _say(HelpStrings.copiedToEditor);
    });
  }

  void _putBack() {
    setState(() {
      _code.text = _backup ?? _code.text;
      _backup = null;
      _say(HelpStrings.codeRestored);
    });
    _focusAfterBuild(_copyFocus);
  }

  @override
  Widget build(BuildContext context) {
    final exercise = widget.exercise;
    final hints = exercise.hints;
    final solution = exercise.solution;
    final left = hints.length - _hintsShown;
    final canShowSolution =
        solution != null && _ranWithoutSolving && !_solutionShown;

    return CurrentLesson(
      id: widget.lessonId,
      child: CodeEditor(
        initialCode: exercise.starter,
        controller: _code,
        expectedOutput: exercise.expectedOutput,
        onSolved: widget.onSolved,
        onRunFinished: _onRunFinished,
        belowRunRow: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!MediaQuery.supportsAnnounceOf(context) && _live.isNotEmpty)
              // Its own node with just the message. 1×1 because nodes
              // without size are dropped from the semantics tree.
              Semantics(
                container: true,
                liveRegion: true,
                label: '$_live${'​' * (_sayCount % 2)}',
                child: const SizedBox(width: 1, height: 1),
              ),
            if (left > 0 || canShowSolution)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (left > 0)
                      OutlinedButton.icon(
                        onPressed: _showHint,
                        icon: const Icon(Icons.lightbulb_outline),
                        label: Text(HelpStrings.showHintLeft(left)),
                      ),
                    if (canShowSolution)
                      OutlinedButton.icon(
                        onPressed: _showSolution,
                        icon: const Icon(Icons.visibility_outlined),
                        label: const Text(HelpStrings.showSolution),
                      ),
                  ],
                ),
              ),
            for (var i = 0; i < _hintsShown; i++)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _HintCard(
                  focusNode: _hintFocus[i],
                  text: HelpStrings.hintLabel(i + 1, hints.length, hints[i]),
                ),
              ),
            if (_solutionShown && solution != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _SolutionCard(
                  solution: solution,
                  focusNode: _solutionFocus,
                  copyFocus: _copyFocus,
                  onCopy: () => _copySolution(solution),
                  // Disabled, not hidden, until there is something to undo.
                  onPutBack: _backup == null ? null : _putBack,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({required this.text, required this.focusNode});

  final String text;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: focusNode,
      skipTraversal: true,
      child: Semantics(
        container: true,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  Icons.lightbulb_outline,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SolutionCard extends StatelessWidget {
  const _SolutionCard({
    required this.solution,
    required this.focusNode,
    required this.copyFocus,
    required this.onCopy,
    required this.onPutBack,
  });

  final String solution;
  final FocusNode focusNode;
  final FocusNode copyFocus;
  final VoidCallback onCopy;
  final VoidCallback? onPutBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Focus(
      focusNode: focusNode,
      skipTraversal: true,
      child: Semantics(
        container: true,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  HelpStrings.solutionHeading,
                  style: textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(HelpStrings.solutionNote, style: textTheme.bodySmall),
              const SizedBox(height: 8),
              SelectableText(solution, style: codeTextStyle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    focusNode: copyFocus,
                    onPressed: onCopy,
                    icon: const Icon(Icons.content_paste_go),
                    label: const Text(HelpStrings.copyToEditor),
                  ),
                  OutlinedButton.icon(
                    onPressed: onPutBack,
                    icon: const Icon(Icons.undo),
                    label: const Text(HelpStrings.putMyCodeBack),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
