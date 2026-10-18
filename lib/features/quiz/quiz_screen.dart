import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';

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
    _lesson ??= AppScope.of(context).repository.loadLesson(widget.lessonId);
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
      AppScope.of(context).markCompleted(lesson.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lesson?>(
      future: _lesson,
      builder: (context, snapshot) {
        final lesson = snapshot.data;
        if (lesson == null || lesson.quiz.isEmpty) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return Scaffold(
          appBar: AppBar(title: Text('Quiz: ${lesson.title}')),
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

    return ListView(
      children: [
        LinearProgressIndicator(value: _index / lesson.quiz.length),
        const SizedBox(height: 24),
        Text(q.question, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        for (var i = 0; i < q.options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              color: !_checked
                  ? (_picked == i ? scheme.primaryContainer : null)
                  : i == q.answer
                      ? scheme.primaryContainer
                      : (_picked == i ? scheme.errorContainer : null),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                title: Text(q.options[i]),
                onTap: _checked ? null : () => setState(() => _picked = i),
              ),
            ),
          ),
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
        Text(
          '$_correct of $total correct',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(passed ? 'Lesson complete!' : 'Review the lesson and try again.'),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => context.go('/learn'),
          child: const Text('Back to lessons'),
        ),
      ],
    );
  }
}
