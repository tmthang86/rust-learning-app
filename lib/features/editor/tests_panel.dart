import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models.dart';
import '../../l10n/exercise_test_strings.dart';
import '../../runner/code_runner.dart';

/// Whether a run shows the tests panel: the runner graded the tests and the
/// learner's own code compiled (when it did not, the compiler errors are the
/// whole story, as with a plain Run).
bool showsTestsPanel(RunResult r) =>
    r is GradeResult &&
    r.stage != RunStage.unavailable &&
    r.compileErrorsIn != 'code' &&
    r.tests.isNotEmpty;

/// Whether a run is a graded one whose tests could not use the learner's
/// code: the compile stage with nothing in `stderr` to show as output.
bool testsCouldNotUseCode(RunResult r) =>
    r is GradeResult && r.compileErrorsIn == 'tests';

TestStatus _statusOf(GradeResult r, ExerciseTest t) =>
    r.testById(t.id)?.status ?? TestStatus.notRun;

/// The sentence a screen reader says after a graded run, e.g. "3 of 5 tests
/// passed. Failed: 15 is too young. Expected Err("too young"), got Ok(15). 1
/// hidden test failed." It names the first visible failure only, is clipped
/// at 200 characters, and ends with the verdict when solved.
String gradeAnnouncement(
  GradeResult r,
  List<ExerciseTest> tests, {
  required bool solved,
}) {
  if (r.compileErrorsIn == 'tests') {
    return ExerciseTestStrings.testsCantUseYourCode;
  }
  final passed = tests.where((t) => _statusOf(r, t) == TestStatus.pass).length;
  final parts = [ExerciseTestStrings.announceSummary(passed, tests.length)];
  for (final t in tests.where((t) => !t.hidden)) {
    final status = _statusOf(r, t);
    if (status == TestStatus.pass) continue;
    parts.add(ExerciseTestStrings.announceFailed(_labelOf(t)));
    final detail = _detailSentence(t, r.testById(t.id));
    if (detail != null) parts.add(detail);
    break;
  }
  final hiddenFailed = tests
      .where((t) => t.hidden && _statusOf(r, t) != TestStatus.pass)
      .length;
  if (hiddenFailed > 0) {
    parts.add(ExerciseTestStrings.announceHiddenFailed(hiddenFailed));
  }
  var text = parts.join(' ');
  if (text.length > 200) text = '${text.substring(0, 200)}…';
  return solved ? '$text ${ExerciseTestStrings.allTestsPassed}' : text;
}

String? _detailSentence(ExerciseTest t, TestResult? r) {
  if (r == null) return null;
  switch (r.status) {
    case TestStatus.fail:
      final expected = r.expected ?? t.output;
      final got = r.actual;
      if (expected == null || got == null) return null;
      return '${ExerciseTestStrings.testExpected} $expected, '
          '${ExerciseTestStrings.testGot.toLowerCase()} $got.';
    case TestStatus.panic:
      return ExerciseTestStrings.testPanicked(r.message ?? '');
    case TestStatus.nopanic:
      return ExerciseTestStrings.testDidNotPanic;
    case TestStatus.timeout:
      return ExerciseTestStrings.testTimedOut;
    default:
      return null;
  }
}

String _labelOf(ExerciseTest t) {
  final label = t.label;
  if (label != null && label.trim().isNotEmpty) return label;
  return t.id == ExerciseTest.legacyId
      ? ExerciseTestStrings.legacyOutputLabel
      : t.id;
}

String _statusWord(TestStatus s) => switch (s) {
  TestStatus.pass => ExerciseTestStrings.statusPassed,
  TestStatus.fail ||
  TestStatus.panic ||
  TestStatus.nopanic => ExerciseTestStrings.statusFailed,
  TestStatus.timeout => ExerciseTestStrings.statusTookTooLong,
  TestStatus.notRun => ExerciseTestStrings.statusDidNotRun,
  TestStatus.crashed => ExerciseTestStrings.statusCrashed,
  TestStatus.error => ExerciseTestStrings.statusCouldNotRun,
};

/// Output comparison as the runner does it: `\r\n` is `\n`, trailing
/// whitespace goes from each line, blank lines at the start and end go.
@visibleForTesting
List<String> normalizedLines(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((l) => l.trimRight())
      .toList();
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// The index of the first line where [a] and [b] differ, or null.
@visibleForTesting
int? firstDifferingLine(List<String> a, List<String> b) {
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : null;
    final y = i < b.length ? b[i] : null;
    if (x != y) return i;
  }
  return null;
}

/// What a graded run says about each test: a summary with a progress bar,
/// one row per visible test (the first failure open), and a single row for
/// the hidden ones that gives a count and nothing else.
class TestsPanel extends StatefulWidget {
  const TestsPanel({super.key, required this.tests, required this.result});

  /// The exercise's tests, in order, with their labels.
  final List<ExerciseTest> tests;
  final GradeResult result;

  @override
  State<TestsPanel> createState() => _TestsPanelState();
}

class _TestsPanelState extends State<TestsPanel> {
  /// Rows the learner opened or closed; the rest follow the default (only
  /// the first failure is open).
  final Map<String, bool> _open = {};

  @override
  void didUpdateWidget(TestsPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.result, widget.result)) _open.clear();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final tests = widget.tests;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final visible = tests.where((t) => !t.hidden).toList();
    final hidden = tests.where((t) => t.hidden).toList();
    final passed = tests
        .where((t) => _statusOf(r, t) == TestStatus.pass)
        .length;
    final hiddenPassed = hidden
        .where((t) => _statusOf(r, t) == TestStatus.pass)
        .length;
    final cantUse = r.compileErrorsIn == 'tests';
    // In the "tests can't use your code" case only the affected tests show.
    final rows = cantUse
        ? visible.where((t) => _statusOf(r, t) == TestStatus.error).toList()
        : visible;
    final firstFailure = rows
        .where((t) => _statusOf(r, t) != TestStatus.pass)
        .map((t) => t.id)
        .firstOrNull;
    final visiblePass =
        visible.isNotEmpty &&
        visible.every((t) => _statusOf(r, t) == TestStatus.pass);
    final hiddenFailing = hidden
        .where(
          (t) => const {
            TestStatus.fail,
            TestStatus.panic,
            TestStatus.nopanic,
            TestStatus.timeout,
            TestStatus.crashed,
          }.contains(_statusOf(r, t)),
        )
        .isNotEmpty;

    // A Material, not a decorated box: the folded sections are list tiles,
    // which paint their ink on the nearest Material.
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                ExerciseTestStrings.testsSummary(passed, tests.length),
                style: textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 8),
            ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: tests.isEmpty ? 0 : passed / tests.length,
                  minHeight: 8,
                ),
              ),
            ),
            if (cantUse) ...[
              const SizedBox(height: 12),
              Semantics(
                container: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.reason == null || r.reason == 'tests_dont_fit'
                            ? ExerciseTestStrings.testsCantUseYourCode
                            : '${ExerciseTestStrings.testsCantUseYourCode} '
                                  '${ExerciseTestStrings.reason(r.reason!)}',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            for (final t in rows)
              _TestRow(
                test: t,
                result: r.testById(t.id),
                status: _statusOf(r, t),
                open: _open[t.id] ?? (t.id == firstFailure),
                onToggle: () => setState(
                  () => _open[t.id] = !(_open[t.id] ?? (t.id == firstFailure)),
                ),
              ),
            if (hidden.isNotEmpty) ...[
              const SizedBox(height: 8),
              Semantics(
                container: true,
                child: Row(
                  children: [
                    Icon(
                      hiddenPassed == hidden.length
                          ? Icons.check_circle
                          : Icons.visibility_off_outlined,
                      color: hiddenPassed == hidden.length
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ExerciseTestStrings.hiddenSummary(
                          hiddenPassed,
                          hidden.length,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (visiblePass && hiddenFailing)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(ExerciseTestStrings.hiddenOnlyFailing),
                ),
              for (final t in hidden)
                if (_statusOf(r, t) == TestStatus.error)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      ExerciseTestStrings.hiddenTestCantUseYourCode(
                        r.testById(t.id)?.message ?? '',
                      ),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TestRow extends StatelessWidget {
  const _TestRow({
    required this.test,
    required this.result,
    required this.status,
    required this.open,
    required this.onToggle,
  });

  final ExerciseTest test;
  final TestResult? result;
  final TestStatus status;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final word = _statusWord(status);
    final label = _labelOf(test);
    final (IconData icon, Color color) = switch (status) {
      TestStatus.pass => (Icons.check_circle, scheme.primary),
      TestStatus.fail ||
      TestStatus.panic ||
      TestStatus.nopanic => (Icons.cancel, scheme.error),
      TestStatus.timeout => (Icons.schedule, scheme.error),
      TestStatus.crashed ||
      TestStatus.error => (Icons.error_outline, scheme.error),
      TestStatus.notRun => (
        Icons.remove_circle_outline,
        scheme.onSurfaceVariant,
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One node for the whole row: "Failed: 15 is too young", a button
        // that opens its details. Status is the word, not just the colour.
        MergeSemantics(
          child: Semantics(
            button: true,
            expanded: open,
            label: ExerciseTestStrings.rowLabel(word, label),
            hint: open
                ? ExerciseTestStrings.rowHintHide
                : ExerciseTestStrings.rowHintShow,
            onTap: onToggle,
            child: ExcludeSemantics(
              child: InkWell(
                onTap: onToggle,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, color: color),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '$word: ',
                                  style: TextStyle(
                                    color: color,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(text: label),
                              ],
                            ),
                          ),
                        ),
                        Icon(open ? Icons.expand_less : Icons.expand_more),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (open) _Details(test: test, result: result, status: status),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.test,
    required this.result,
    required this.status,
  });

  final ExerciseTest test;
  final TestResult? result;
  final TestStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = result;
    final children = <Widget>[];

    Widget field(String name, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$name: ', style: const TextStyle(fontWeight: FontWeight.w700)),
          Expanded(child: SelectableText(value, style: codeTextStyle)),
        ],
      ),
    );
    Widget note(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectableText(text),
    );

    switch (status) {
      case TestStatus.fail:
        if (test.isOutput) {
          children.add(
            _OutputDiff(
              expected: r?.expected ?? test.output ?? '',
              got: r?.actual ?? '',
            ),
          );
        } else {
          if (r?.expr != null && r!.expr!.isNotEmpty) {
            children.add(field(ExerciseTestStrings.testChecked, r.expr!));
          }
          if (r?.expected != null) {
            children.add(field(ExerciseTestStrings.testExpected, r!.expected!));
          }
          if (r?.actual != null) {
            children.add(field(ExerciseTestStrings.testGot, r!.actual!));
          }
        }
      case TestStatus.panic:
        final line = r?.line;
        children.add(
          note(
            line == null
                ? ExerciseTestStrings.testPanicked(r?.message ?? '')
                : ExerciseTestStrings.testPanickedAt(r?.message ?? '', line),
          ),
        );
      case TestStatus.nopanic:
        children.add(note(ExerciseTestStrings.testDidNotPanic));
      case TestStatus.timeout:
        children.add(note(ExerciseTestStrings.testTimedOut));
      case TestStatus.crashed:
        children.add(note(ExerciseTestStrings.reason(r?.reason ?? 'unknown')));
      case TestStatus.error:
        children.add(
          note(ExerciseTestStrings.reason(r?.reason ?? 'tests_dont_fit')),
        );
        if (r?.message != null) children.add(note(r!.message!));
      case TestStatus.notRun:
        children.add(note(ExerciseTestStrings.testNotRun));
      case TestStatus.pass:
        break;
    }

    final printed = r?.output;
    if (printed != null && printed.trim().isNotEmpty) {
      children.add(
        _Folded(
          title: ExerciseTestStrings.testPrinted,
          child: SelectableText(printed, style: codeTextStyle),
        ),
      );
    }
    final code = test.code;
    if (code != null && !test.hidden) {
      children.add(
        _Folded(
          title: ExerciseTestStrings.testShowCode,
          child: SelectableText(code, style: codeTextStyle),
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 32, bottom: 8),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: scheme.onSurface),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// A folded section (no divider lines around it).
class _Folded extends StatelessWidget {
  const _Folded({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        dense: true,
        title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
        expandedAlignment: Alignment.centerLeft,
        children: [Align(alignment: Alignment.centerLeft, child: child)],
      ),
    );
  }
}

/// Expected and Got, line by line, with the first differing line marked.
class _OutputDiff extends StatelessWidget {
  const _OutputDiff({required this.expected, required this.got});

  final String expected;
  final String got;

  @override
  Widget build(BuildContext context) {
    final want = normalizedLines(expected);
    final have = normalizedLines(got);
    final diff = firstDifferingLine(want, have);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Lines(
          title: ExerciseTestStrings.testExpected,
          lines: want,
          mark: diff,
        ),
        const SizedBox(height: 8),
        _Lines(title: ExerciseTestStrings.testGot, lines: have, mark: diff),
        if (diff != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(ExerciseTestStrings.firstDifference(diff + 1)),
          ),
      ],
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({required this.title, required this.lines, required this.mark});

  final String title;
  final List<String> lines;

  /// The line to highlight (also shown past the end, as "nothing").
  final int? mark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = lines.isEmpty && mark == 0 ? [''] : lines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        for (var i = 0; i < shown.length; i++)
          Container(
            color: i == mark ? scheme.errorContainer : null,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SelectableText(
              shown[i].isEmpty ? ' ' : shown[i],
              style: codeTextStyle.copyWith(
                color: i == mark ? scheme.onErrorContainer : null,
              ),
            ),
          ),
        if (mark != null && mark! >= shown.length)
          Container(
            color: scheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              ExerciseTestStrings.missingLine,
              style: codeTextStyle.copyWith(color: scheme.onErrorContainer),
            ),
          ),
      ],
    );
  }
}
