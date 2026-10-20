import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';
import '../../monetization/monetization.dart';
import '../lesson/lesson_screen.dart';

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
  int _index = 0;
  int _correct = 0;
  int? _picked;
  bool _checked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lesson ??= AppScope.read(context).repository.loadLesson(widget.lessonId);
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
      AppScope.read(context).markCompleted(lesson.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lesson?>(
      future: _lesson,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          debugPrint(
            'Quiz ${widget.lessonId} failed to load: ${snapshot.error}',
          );
          return const LessonMessage(
            "This quiz couldn't be opened. Please update the app or try again later.",
          );
        }
        final lesson = snapshot.data;
        if (lesson == null) {
          return const LessonMessage('This lesson is still being written.');
        }
        if (lesson.quiz.isEmpty) {
          return const LessonMessage("This lesson doesn't have a quiz.");
        }
        return Scaffold(
          appBar: lessonAppBar(context, title: Text('Quiz: ${lesson.title}')),
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
    final rightAnswer = _checked && _picked == q.answer;

    return ListView(
      children: [
        LinearProgressIndicator(
          value: _index / lesson.quiz.length,
          semanticsLabel: 'Question ${_index + 1} of ${lesson.quiz.length}',
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
                  ? 'Correct!'
                  : 'Not quite. The answer is: ${q.options[q.answer]}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: rightAnswer ? scheme.primary : scheme.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _picked == null
              ? null
              : _checked
              ? () => _next(lesson)
              : () => _check(q),
          child: Text(_checked ? 'Next' : 'Check'),
        ),
      ],
    );
  }

  Widget _summary(Lesson lesson) {
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
            '$_correct of $total correct',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 8),
        Text(passed ? 'Lesson complete!' : 'Review the lesson and try again.'),
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
          child: const Text('Back to lessons'),
        ),
      ],
    );
  }
}

enum _Verdict { correct, wrong }

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
    final (Color? color, String? status, IconData icon) = switch (verdict) {
      _Verdict.correct => (
        scheme.primaryContainer,
        picked ? 'Correct, your answer' : 'Correct answer',
        Icons.check_circle,
      ),
      _Verdict.wrong => (
        scheme.errorContainer,
        'Wrong, your answer',
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
