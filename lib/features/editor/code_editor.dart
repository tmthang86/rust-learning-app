import 'package:flutter/material.dart';

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
    final result = await AppScope.of(context).runner.run(_controller.text);
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
    if (_solved) widget.onSolved?.call();
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
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.inverseSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              [result.stdout, result.stderr]
                  .where((s) => s.isNotEmpty)
                  .join('\n'),
              style: codeTextStyle.copyWith(color: scheme.onInverseSurface),
            ),
          ),
          if (widget.expectedOutput != null) ...[
            const SizedBox(height: 8),
            Text(
              _solved ? 'Correct! Nice work.' : 'Not quite yet. Keep trying.',
              style: TextStyle(
                color: _solved ? scheme.primary : scheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ],
    );
  }
}
