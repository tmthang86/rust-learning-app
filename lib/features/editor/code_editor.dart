import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../data/app_state.dart';
import '../../data/models.dart';
import '../../runner/code_runner.dart';
import 'error_explanation_cards.dart';
import 'tests_panel.dart';

/// A Rust code editor with a Run button and an output panel.
///
/// When [tests] is set, Run grades the code with the runner's `/grade`: a
/// tests panel shows each test, and [onSolved] is called when every test
/// passes. With only the legacy [expectedOutput], Run is a plain run whose
/// output is compared here and shown as one test. Without either (the
/// playground), Run just runs the code.
///
/// A caller that needs to read or replace the code passes a [controller];
/// [onRunFinished] reports every finished run.
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.initialCode,
    this.expectedOutput,
    this.tests,
    this.onSolved,
    this.minLines = 8,
    this.controller,
    this.onRunFinished,
    this.belowRunRow,
  });

  final String initialCode;
  final String? expectedOutput;

  /// What grades the exercise, hidden tests included. Null: no grading.
  final List<ExerciseTest>? tests;
  final VoidCallback? onSolved;
  final int minLines;

  /// Holds the code. When null the editor makes its own, starting with
  /// [initialCode]. A given controller is not disposed here, and its text
  /// is used as it is (Reset still goes back to [initialCode]).
  final TextEditingController? controller;

  /// Called after each run with its result and whether it solved the
  /// exercise. Not called when the editor was closed during the run.
  final void Function(RunResult result, bool solved)? onRunFinished;

  /// Shown between the Run row and the output (hints, solution).
  final Widget? belowRunRow;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor>
    with AutomaticKeepAliveClientMixin {
  late TextEditingController _controller;
  late bool _ownsController;
  RunResult? _result;
  bool _running = false;

  /// Counts runs, so the fallback live region below changes every time.
  int _runCount = 0;

  /// Keeps the code and the last result when the lesson list scrolls the
  /// editor out of view (ListView disposes off-screen children otherwise).
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? TextEditingController(text: widget.initialCode);
  }

  @override
  void didUpdateWidget(CodeEditor old) {
    super.didUpdateWidget(old);
    if (widget.controller == old.controller) return;
    if (_ownsController) _controller.dispose();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? TextEditingController(text: widget.initialCode);
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  /// The tests that grade a run: [CodeEditor.tests], else the legacy
  /// expected output as one output test, else none.
  List<ExerciseTest>? get _tests =>
      widget.tests ??
      (widget.expectedOutput == null
          ? null
          : [ExerciseTest.legacy(widget.expectedOutput!)]);

  /// Solved means every test passed, hidden ones included; a runner that
  /// couldn't be reached never solves anything.
  static bool _matches(RunResult? r, List<ExerciseTest>? tests) =>
      tests != null && r is GradeResult && r.solves(tests);

  bool get _solved => _matches(_result, _tests);

  /// What a screen reader says when a run finishes.
  String _announcement(RunResult r, bool solved) {
    final tests = _tests;
    if (tests != null && r is GradeResult && showsTestsPanel(r)) {
      return gradeAnnouncement(r, tests, solved: solved);
    }
    return runAnnouncement(r, solved: tests == null ? null : solved);
  }

  Future<void> _run() async {
    if (_running) return;
    final state = AppScope.read(context);
    // Captured now: the result may arrive after the learner left the lesson,
    // and solving still counts then.
    final tests = _tests;
    final onSolved = widget.onSolved;
    // ...but only for the same person: not after a sign-out, a switch to
    // another account, or during account deletion.
    final epoch = state.accountEpoch;
    setState(() => _running = true);
    // Declared tests go to /grade. An exercise with only an expected output
    // is run as before (one run, no /grade needed) and shown as one test.
    final declared = widget.tests;
    final expected = widget.expectedOutput;
    final RunResult result;
    if (declared != null) {
      result = await state.runner.grade(_controller.text, declared);
    } else if (expected != null) {
      result = GradeResult.fromLegacyRun(
        await state.runner.run(_controller.text),
        expected,
      );
    } else {
      result = await state.runner.run(_controller.text);
    }
    final solved = _matches(result, tests);
    if (solved && state.accountEpoch == epoch) onSolved?.call();
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
      _runCount++;
    });
    widget.onRunFinished?.call(result, solved);
    // Screen readers hear every run, including repeats with the same text.
    // Where the platform doesn't support announcements (they are
    // deprecated on Android), the output's live region does the job.
    if (MediaQuery.supportsAnnounceOf(context)) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        _announcement(result, solved),
        Directionality.of(context),
      );
    }
  }

  void _indent() => _controller.value = indentLines(_controller.value);
  void _outdent() => _controller.value = outdentLines(_controller.value);

  void _reset() => setState(() {
    _controller.text = widget.initialCode;
    _result = null;
  });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final result = _result;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.tab): _IndentIntent(),
              SingleActivator(LogicalKeyboardKey.tab, shift: true):
                  _OutdentIntent(),
              SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _RunIntent(),
              SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _RunIntent(),
            },
            child: Actions(
              actions: {
                _IndentIntent: CallbackAction<_IndentIntent>(
                  onInvoke: (_) {
                    _indent();
                    return null;
                  },
                ),
                // Shift+Tab outdents selected lines; with no selection it is
                // left to the app, which moves focus out of the editor, so
                // keyboard users are never trapped here.
                _OutdentIntent: _OutdentAction(
                  enabled: () => !_controller.selection.isCollapsed,
                  outdent: _outdent,
                ),
                _RunIntent: CallbackAction<_RunIntent>(
                  onInvoke: (_) {
                    _run();
                    return null;
                  },
                ),
              },
              child: Semantics(
                label: 'Rust code',
                hint:
                    'Tab indents. Shift+Tab outdents selected lines, or '
                    'leaves the editor when nothing is selected. '
                    'Control+Enter runs the code.',
                child: TextField(
                  controller: _controller,
                  style: codeTextStyle,
                  minLines: widget.minLines,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  // Smart quotes and dashes would put characters in the
                  // code that rustc rejects.
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(16),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: const Text('Run'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _running ? null : _reset,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset'),
            ),
          ],
        ),
        ?widget.belowRunRow,
        if (result != null) ...[
          if (result is GradeResult && showsTestsPanel(result)) ...[
            const SizedBox(height: 8),
            TestsPanel(tests: _tests ?? const [], result: result),
          ],
          const SizedBox(height: 8),
          _RunOutput(
            result: result,
            // The tests' own message says why there are no compiler errors.
            showOutput: !testsCouldNotUseCode(result),
            // Fallback when announcements aren't supported: a live region
            // whose label changes on every run, so repeats are read too.
            liveLabel: MediaQuery.supportsAnnounceOf(context)
                ? null
                : 'Run $_runCount. ${_announcement(result, _solved)}',
          ),
          if (_tests != null && result.stage != RunStage.unavailable) ...[
            const SizedBox(height: 8),
            // Its own node, so it isn't read as part of the code field. The
            // verdict is also part of the run announcement.
            Semantics(
              container: true,
              child: Row(
                children: [
                  Icon(
                    _solved ? Icons.check_circle : Icons.info_outline,
                    color: _solved ? scheme.primary : scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _solved
                          ? 'Correct! Nice work.'
                          : 'Not quite yet. Keep trying.',
                      style: TextStyle(
                        color: _solved ? scheme.primary : scheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (result.stage == RunStage.compile && !testsCouldNotUseCode(result))
            ErrorExplanationCards(stderr: result.stderr),
        ],
      ],
    );
  }
}

class _IndentIntent extends Intent {
  const _IndentIntent();
}

class _OutdentIntent extends Intent {
  const _OutdentIntent();
}

class _RunIntent extends Intent {
  const _RunIntent();
}

class _OutdentAction extends Action<_OutdentIntent> {
  _OutdentAction({required this.enabled, required this.outdent});

  final bool Function() enabled;
  final VoidCallback outdent;

  // When disabled the key event goes on to the app's Shift+Tab handling.
  @override
  bool isEnabled(_OutdentIntent intent) => enabled();

  @override
  Object? invoke(_OutdentIntent intent) {
    outdent();
    return null;
  }
}

const _indentUnit = '    ';

/// The lines touched by [sel]: from the start of the first line to the end
/// of the last. A selection ending right at a line start leaves that line
/// out, as code editors do.
(int, int) _lineRange(String text, TextSelection sel) {
  final start = sel.start == 0 ? 0 : text.lastIndexOf('\n', sel.start - 1) + 1;
  var endPos = sel.end;
  if (endPos > sel.start && text[endPos - 1] == '\n') endPos--;
  final nl = text.indexOf('\n', endPos);
  return (start, nl == -1 ? text.length : nl);
}

/// Tab: four spaces at the cursor, or every selected line indented.
@visibleForTesting
TextEditingValue indentLines(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid) return value;
  final text = value.text;
  if (sel.isCollapsed) {
    return value.copyWith(
      text: text.replaceRange(sel.start, sel.end, _indentUnit),
      selection: TextSelection.collapsed(
        offset: sel.start + _indentUnit.length,
      ),
      composing: TextRange.empty,
    );
  }
  final (start, end) = _lineRange(text, sel);
  final lines = text.substring(start, end).split('\n');
  final indented = lines.map((l) => '$_indentUnit$l').join('\n');
  return value.copyWith(
    text: text.replaceRange(start, end, indented),
    selection: TextSelection(
      baseOffset: sel.start + _indentUnit.length,
      extentOffset: sel.end + _indentUnit.length * lines.length,
    ),
    composing: TextRange.empty,
  );
}

/// Shift+Tab with a selection: up to four leading spaces removed from every
/// selected line.
@visibleForTesting
TextEditingValue outdentLines(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid || sel.isCollapsed) return value;
  final text = value.text;
  final (start, end) = _lineRange(text, sel);
  final lines = text.substring(start, end).split('\n');
  var removedFirst = 0;
  var removedTotal = 0;
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    var n = 0;
    while (n < _indentUnit.length && n < line.length && line[n] == ' ') {
      n++;
    }
    if (i == 0) removedFirst = n;
    removedTotal += n;
    out.add(line.substring(n));
  }
  final newStart = (sel.start - removedFirst).clamp(start, sel.start);
  final newEnd = (sel.end - removedTotal).clamp(
    newStart,
    text.length - removedTotal,
  );
  return value.copyWith(
    text: text.replaceRange(start, end, out.join('\n')),
    selection: TextSelection(baseOffset: newStart, extentOffset: newEnd),
    composing: TextRange.empty,
  );
}

/// What a screen reader says when a run finishes.
@visibleForTesting
String runAnnouncement(RunResult r, {bool? solved}) {
  String clip(String s) {
    final t = s.trim();
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }

  final output = [
    r.stdout,
    r.stderr,
  ].where((s) => s.trim().isNotEmpty).join('\n');
  final base = switch (r.stage) {
    RunStage.compile => "Your code didn't compile. ${clip(r.stderr)}",
    RunStage.unavailable => "Couldn't run your code. ${clip(r.stderr)}",
    RunStage.timeout => 'Your program took too long.',
    RunStage.run =>
      output.isEmpty
          ? 'Your program ran with no output.'
          : 'Output: ${clip(output)}',
  };
  final verdict = switch (solved) {
    true => ' Correct! Nice work.',
    false => ' Not quite yet. Keep trying.',
    null => '',
  };
  final warn = r.warnings.trim().isEmpty ? '' : ' There are compiler warnings.';
  return '$base$verdict$warn';
}

/// What a run produced: program output (or compiler errors, or why the
/// runner couldn't be used), then any compiler warnings, kept apart and
/// folded away because the program ran anyway.
class _RunOutput extends StatelessWidget {
  const _RunOutput({
    required this.result,
    this.liveLabel,
    this.showOutput = true,
  });

  final RunResult result;
  final String? liveLabel;

  /// False when there is nothing to show but the live region.
  final bool showOutput;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (String heading, String body) = switch (result.stage) {
      RunStage.compile => ("Your code didn't compile", result.stderr),
      RunStage.unavailable => ("Couldn't run your code", result.stderr),
      RunStage.timeout => (
        'Your program took too long',
        [result.stdout, result.stderr].where((s) => s.isNotEmpty).join('\n'),
      ),
      RunStage.run => (
        'Output',
        [result.stdout, result.stderr].where((s) => s.isNotEmpty).join('\n'),
      ),
    };
    final isError = result.stage != RunStage.run;
    final warnings = result.warnings.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Announced through SemanticsService when a run finishes, or, where
        // that isn't supported, through the live region below.
        if (liveLabel != null)
          // Its own node carrying only the short summary, so the output
          // isn't read twice. 1×1 because nodes without size are dropped
          // from the semantics tree.
          Semantics(
            container: true,
            liveRegion: true,
            label: liveLabel,
            child: const SizedBox(width: 1, height: 1),
          ),
        if (showOutput)
          Semantics(
            container: true,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.inverseSurface,
                borderRadius: BorderRadius.circular(12),
                border: isError
                    ? Border.all(color: scheme.error, width: 2)
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    heading,
                    style: textTheme.labelLarge?.copyWith(
                      color: scheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    body.isEmpty ? '(no output)' : body,
                    style: codeTextStyle.copyWith(
                      color: scheme.onInverseSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          Theme(
            // No divider lines around the folded section.
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              leading: Icon(
                Icons.warning_amber_outlined,
                color: scheme.onSurfaceVariant,
              ),
              title: Text(
                'Compiler warnings (your program still ran)',
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    warnings,
                    style: codeTextStyle.copyWith(
                      fontSize: (codeTextStyle.fontSize ?? 14) - 1,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
