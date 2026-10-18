import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../data/app_state.dart';
import '../../runner/code_runner.dart';

/// A Rust code editor with a Run button and an output panel.
///
/// When [expectedOutput] is set, the output is checked against it and
/// [onSolved] is called on a match.
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.initialCode,
    this.expectedOutput,
    this.onSolved,
    this.minLines = 8,
  });

  final String initialCode;
  final String? expectedOutput;
  final VoidCallback? onSolved;
  final int minLines;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialCode);
  RunResult? _result;
  bool _running = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _solved =>
      widget.expectedOutput != null &&
      _result != null &&
      _result!.success &&
      _result!.stdout.trim() == widget.expectedOutput!.trim();

  Future<void> _run() async {
    setState(() => _running = true);
    final result = await AppScope.read(context).runner.run(_controller.text);
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
    if (_solved) widget.onSolved?.call();
  }

  /// Tab indents with four spaces, as in a code editor, instead of moving
  /// focus. Shift+Tab still moves focus out of the editor.
  void _indent() {
    final value = _controller.value;
    final sel = value.selection;
    if (!sel.isValid) return;
    const spaces = '    ';
    _controller.value = value.copyWith(
      text: value.text.replaceRange(sel.start, sel.end, spaces),
      selection: TextSelection.collapsed(offset: sel.start + spaces.length),
      composing: TextRange.empty,
    );
  }

  void _reset() => setState(() {
        _controller.text = widget.initialCode;
        _result = null;
      });

  @override
  Widget build(BuildContext context) {
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
            },
            child: Actions(
              actions: {
                _IndentIntent: CallbackAction<_IndentIntent>(
                  onInvoke: (_) {
                    _indent();
                    return null;
                  },
                ),
              },
              child: Semantics(
                label: 'Rust code',
                hint: 'Tab inserts spaces. Shift+Tab leaves the editor.',
                child: TextField(
                  controller: _controller,
                  style: codeTextStyle,
                  minLines: widget.minLines,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
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
        if (result != null) ...[
          const SizedBox(height: 8),
          _RunOutput(result: result),
          if (widget.expectedOutput != null &&
              result.stage != RunStage.unavailable) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Icon(
                    _solved ? Icons.check_circle : Icons.info_outline,
                    color: _solved ? scheme.primary : scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _solved ? 'Correct! Nice work.' : 'Not quite yet. Keep trying.',
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
        ],
      ],
    );
  }
}

class _IndentIntent extends Intent {
  const _IndentIntent();
}

/// What a run produced: program output (or compiler errors, or why the
/// runner couldn't be used), then any compiler warnings, kept apart and
/// folded away because the program ran anyway.
class _RunOutput extends StatelessWidget {
  const _RunOutput({required this.result});

  final RunResult result;

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
        // Announced when a run finishes, so screen reader users hear it.
        Semantics(
          liveRegion: true,
          container: true,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.inverseSurface,
              borderRadius: BorderRadius.circular(12),
              border: isError ? Border.all(color: scheme.error, width: 2) : null,
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
                  style: codeTextStyle.copyWith(color: scheme.onInverseSurface),
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
              leading: Icon(Icons.warning_amber_outlined, color: scheme.onSurfaceVariant),
              title: Text(
                'Compiler warnings (your program still ran)',
                style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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
