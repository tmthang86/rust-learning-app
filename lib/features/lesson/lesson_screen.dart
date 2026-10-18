import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/app_state.dart';
import '../../data/models.dart';
import '../editor/code_editor.dart';

/// One lesson: explanation, examples, an exercise and a link to the quiz.
class LessonScreen extends StatefulWidget {
  const LessonScreen({super.key, required this.lessonId});

  final String lessonId;

  @override
  State<LessonScreen> createState() => _LessonScreenState();
}

class _LessonScreenState extends State<LessonScreen> {
  Future<Lesson?>? _lesson;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lesson ??= AppScope.of(context).repository.loadLesson(widget.lessonId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lesson?>(
      future: _lesson,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final lesson = snapshot.data;
        if (lesson == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This lesson is still being written.')),
          );
        }
        return _LessonBody(lesson: lesson);
      },
    );
  }
}

class _LessonBody extends StatelessWidget {
  const _LessonBody({required this.lesson});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final track = state.track ?? Track.starter;
    final theme = Theme.of(context);
    final exercise = lesson.exercise;

    return Scaffold(
      appBar: AppBar(title: Text(lesson.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final section in lesson.sections.where((s) => s.visibleTo(track)))
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _Section(section: section),
                ),
              if (exercise != null) ...[
                Text('Try it', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(exercise.prompt),
                const SizedBox(height: 12),
                CodeEditor(
                  initialCode: exercise.starter,
                  expectedOutput: exercise.expectedOutput,
                ),
                const SizedBox(height: 24),
              ],
              if (lesson.quiz.isNotEmpty)
                FilledButton(
                  onPressed: () => context.push('/lesson/${lesson.id}/quiz'),
                  child: const Text('Take the quiz'),
                )
              else
                FilledButton(
                  onPressed: () {
                    state.markCompleted(lesson.id);
                    context.pop();
                  },
                  child: const Text('Mark as done'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final LessonSection section;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    switch (section.type) {
      case SectionType.text:
        return Text(section.body, style: textTheme.bodyLarge);
      case SectionType.note:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            section.body,
            style: textTheme.bodyMedium
                ?.copyWith(color: scheme.onSecondaryContainer),
          ),
        );
      case SectionType.code:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(section.body, style: codeTextStyle),
        );
    }
  }
}
