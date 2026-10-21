import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/app_state.dart';
import '../../data/models.dart';
import '../../monetization/ad_banner.dart';
import '../../monetization/ads_service.dart';
import '../../monetization/monetization.dart';
import '../editor/code_editor.dart';
import '../streak/streak_widgets.dart';

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
    _lesson ??= AppScope.read(context).repository.loadLesson(widget.lessonId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lesson?>(
      future: _lesson,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasError) {
          debugPrint('Lesson ${widget.lessonId} failed to load: ${snapshot.error}');
          return const LessonMessage(
              "This lesson couldn't be opened. Please update the app or try again later.");
        }
        final lesson = snapshot.data;
        if (lesson == null) {
          return const LessonMessage('This lesson is still being written.');
        }
        return _LessonBody(lesson: lesson);
      },
    );
  }
}

/// A full-screen note shown instead of a lesson or quiz, with a way back.
class LessonMessage extends StatelessWidget {
  const LessonMessage(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DeepLinkScope(
      child: Scaffold(
      appBar: lessonAppBar(context),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/learn'),
                child: const Text('Back to lessons'),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// App bar for lesson pages. Opened from a deep link there is nothing to go
/// back to, so it shows a way to the course map instead.
PreferredSizeWidget lessonAppBar(BuildContext context, {Widget? title}) => AppBar(
      title: title,
      leading: context.canPop()
          ? null
          : IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to lessons',
              onPressed: () => context.go('/learn'),
            ),
    );

/// Makes the system back button (Android, browser) open the course map
/// instead of leaving the app when a lesson was opened from a deep link.
class DeepLinkScope extends StatelessWidget {
  const DeepLinkScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: context.canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/learn');
      },
      child: child,
    );
  }
}

/// Goes back, or to the course map when the screen was opened directly
/// (a deep link or a web address) and there is nothing to go back to.
void leaveLesson(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/learn');
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
    final sections = lesson.sections.where((s) => s.visibleTo(track)).toList();
    // Taken now: the snackbar for a finished lesson must outlive the screen.
    final messenger = ScaffoldMessenger.of(context);
    // The banner goes after the first section, and only when at least one
    // more section follows, so reading text always separates it from the
    // exercise's editor and Run output further down.
    final bannerAfter = sections.length >= 2 ? 0 : -1;

    return DeepLinkScope(
      child: Scaffold(
      appBar: lessonAppBar(context, title: Text(lesson.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final (i, section) in sections.indexed) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _Section(section: section),
                ),
                if (i == bannerAfter)
                  const AdBannerSlot(placement: AdPlacement.lessonReading),
              ],
              if (exercise != null) ...[
                Text('Try it', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(exercise.prompt),
                const SizedBox(height: 12),
                CodeEditor(
                  initialCode: exercise.starter,
                  expectedOutput: exercise.expectedOutput,
                  // Solving the exercise completes the lesson, as does
                  // passing the quiz.
                  onSolved: () => state
                      .markCompleted(lesson.id)
                      .then((award) => showXpSnackBar(messenger, award)),
                ),
                const SizedBox(height: 24),
              ],
              if (state.isCompleted(lesson.id)) ...[
                Row(
                  children: [
                    Icon(Icons.check_circle, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    const Text('Lesson complete'),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (lesson.quiz.isNotEmpty)
                FilledButton(
                  onPressed: () => context.push('/lesson/${lesson.id}/quiz'),
                  child: const Text('Take the quiz'),
                )
              else if (exercise == null)
                FilledButton(
                  onPressed: () {
                    state
                        .markCompleted(lesson.id)
                        .then((award) => showXpSnackBar(messenger, award));
                    final monetization = MonetizationScope.read(context);
                    leaveLesson(context);
                    // A natural break: the lesson is done and closed.
                    // Repeat finishes are ignored there.
                    monetization.onLessonFinished(lesson.id);
                  },
                  child: const Text('Mark as done'),
                ),
            ],
          ),
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
