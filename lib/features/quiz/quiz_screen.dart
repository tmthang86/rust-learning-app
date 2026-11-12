import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../data/streaks.dart';
import '../../monetization/monetization.dart';
import '../lesson/lesson_screen.dart';
import '../streak/streak_widgets.dart';

/// Multiple-choice quiz at the end of a lesson. Passing marks it done.
class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key, required this.lessonId});

  final String lessonId;

  /// Share of correct answers needed to pass.
  static const passMark = 0.5;

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  Future<Lesson?>? _lesson;
  String? _language;
  int _index = 0;
  int _correct = 0;
  int? _picked;
  bool _checked = false;

  /// What passing earned, shown on the summary.
  XpAward? _award;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Loaded again when the language changes; the quiz has the same
    // questions and answers in every language, so progress through it stays.
    final state = AppScope.of(context);
    if (_language != state.languageCode) {
      _language = state.languageCode;
      _lesson = state.repository.loadLesson(
        widget.lessonId,
        language: state.languageCode,
      );
    }
  }

  void _check(QuizQuestion q) => setState(() {
    _checked = true;
    if (_picked == q.answer) _correct++;
  });

  void _next(Lesson lesson) {
    setState(() {
      _index++;
      _picked = null;
      _checked = false;
    });
    if (_index == lesson.quiz.length &&
        _correct / lesson.quiz.length >= QuizScreen.passMark) {
      AppScope.read(context).markCompleted(lesson.id).then((award) {
        if (mounted) setState(() => _award = award);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lesson?>(
      future: _lesson,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            snapshot.data == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          debugPrint(
            'Quiz ${widget.lessonId} failed to load: ${snapshot.error}',
          );
          return LessonMessage(context.l10n.quizLoadError);
        }
        final lesson = snapshot.data;
        if (lesson == null) {
          return LessonMessage(context.l10n.lessonNotWritten);
        }
        if (lesson.quiz.isEmpty) {
          return LessonMessage(context.l10n.quizMissing);
        }
        return Scaffold(
          appBar: lessonAppBar(
            context,
            title: Text(
              context.l10n.quizTitle(
                AppScope.of(context).course?.lessonTitle(lesson.id) ??
                    lesson.title,
              ),
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _index < lesson.quiz.length
                    ? _question(lesson)
                    : _summary(lesson),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _question(Lesson lesson) {
    final q = lesson.quiz[_index];
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final rightAnswer = _checked && _picked == q.answer;

    return ListView(
      children: [
        LinearProgressIndicator(
          value: _index / lesson.quiz.length,
          semanticsLabel: l10n.quizQuestionOf(_index + 1, lesson.quiz.length),
        ),
        const SizedBox(height: 24),
        Text(q.question, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        for (var i = 0; i < q.options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _OptionTile(
              text: q.options[i],
              picked: _picked == i,
              // Right/wrong is only revealed after Check.
              verdict: !_checked
                  ? null
                  : i == q.answer
                  ? _Verdict.correct
                  : (_picked == i ? _Verdict.wrong : null),
              scheme: scheme,
              onTap: _checked ? null : () => setState(() => _picked = i),
            ),
          ),
        if (_checked) ...[
          const SizedBox(height: 8),
          // Read out by screen readers as soon as it appears.
          Semantics(
            liveRegion: true,
            child: Text(
              rightAnswer
                  ? l10n.quizCorrect
                  : l10n.quizNotQuite(q.options[q.answer]),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: rightAnswer ? scheme.primary : scheme.error,
              ),
            ),
          ),
          if (q.explanation.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ExplanationCard(text: q.explanation),
          ],
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _picked == null
              ? null
              : _checked
              ? () => _next(lesson)
              : () => _check(q),
          child: Text(_checked ? l10n.quizNext : l10n.quizCheck),
        ),
      ],
    );
  }

  Widget _summary(Lesson lesson) {
    final l10n = context.l10n;
    final total = lesson.quiz.length;
    final passed = _correct / total >= QuizScreen.passMark;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(passed ? Icons.celebration : Icons.refresh, size: 64),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            l10n.quizScore(_correct, total),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 8),
        Text(passed ? l10n.quizLessonComplete : l10n.quizTryAgain),
        if (passed) ...[
          const SizedBox(height: 16),
          XpEarnedNote(award: _award),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () {
            final monetization = MonetizationScope.read(context);
            context.go('/learn');
            // A natural break: the lesson is done and closed. Only the
            // first pass counts, even when solving the exercise already
            // completed the lesson (onLessonFinished ignores repeats).
            if (passed) monetization.onLessonFinished(lesson.id);
          },
          child: Text(l10n.backToLessons),
        ),
      ],
    );
  }
}

enum _Verdict { correct, wrong }

/// Why the right answer is right, shown after Check whether the learner got
/// it right or not. Read as one node: "Explanation", then the text.
class _ExplanationCard extends StatelessWidget {
  const _ExplanationCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Card(
      key: const Key('quiz-explanation'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: MergeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.lightbulb_outline,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.quizExplanationTitle,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(text, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

/// One answer. Selection and right/wrong are shown with an icon and words,
/// not only with colour, and are announced by screen readers.
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.text,
    required this.picked,
    required this.verdict,
    required this.scheme,
    required this.onTap,
  });

  final String text;
  final bool picked;
  final _Verdict? verdict;
  final ColorScheme scheme;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (Color? color, String? status, IconData icon) = switch (verdict) {
      _Verdict.correct => (
        scheme.primaryContainer,
        picked ? l10n.optionCorrectYours : l10n.optionCorrect,
        Icons.check_circle,
      ),
      _Verdict.wrong => (
        scheme.errorContainer,
        l10n.optionWrongYours,
        Icons.cancel,
      ),
      null => (
        picked ? scheme.primaryContainer : null,
        null,
        picked ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
    };

    // One node per answer: "A, checked, in group of 2, selected".
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: picked,
        child: Card(
          color: color,
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            selected: picked,
            leading: Icon(icon),
            title: Text(text),
            subtitle: status == null ? null : Text(status),
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}
