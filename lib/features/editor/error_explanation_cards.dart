import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/app_state.dart';
import '../../data/error_explanations.dart';
import '../../data/models.dart';
import '../../l10n/help_strings.dart';

/// Tells the cards which lesson the learner is in, so they don't offer a
/// second copy of it.
class CurrentLesson extends InheritedWidget {
  const CurrentLesson({super.key, required this.id, required super.child});

  final String id;

  static String? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CurrentLesson>()?.id;

  @override
  bool updateShouldNotify(CurrentLesson old) => id != old.id;
}

/// "What this error means" cards for the errors in a failed build's
/// [stderr]. They sit next to the compiler output and never replace it.
/// Shows nothing while loading or when nothing is known.
class ErrorExplanationCards extends StatefulWidget {
  const ErrorExplanationCards({
    super.key,
    required this.stderr,
    this.languageCode = 'en',
  });

  final String stderr;
  final String languageCode;

  @override
  State<ErrorExplanationCards> createState() => _ErrorExplanationCardsState();
}

class _ErrorExplanationCardsState extends State<ErrorExplanationCards> {
  Future<List<ErrorHelp>>? _help;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _help ??= _load();
  }

  @override
  void didUpdateWidget(ErrorExplanationCards old) {
    super.didUpdateWidget(old);
    if (old.stderr != widget.stderr ||
        old.languageCode != widget.languageCode) {
      _help = _load();
    }
  }

  Future<List<ErrorHelp>> _load() =>
      AppScope.read(context).errors
          .explain(widget.stderr, lang: widget.languageCode);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ErrorHelp>>(
      // New output starts from nothing, so old cards don't flash.
      key: ValueKey(widget.stderr),
      future: _help,
      builder: (context, snapshot) {
        final help = snapshot.data;
        if (help == null || help.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final h in help)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ErrorExplanationCard(help: h),
              ),
          ],
        );
      },
    );
  }
}

/// One error: title, explanation, fixes, a lesson link and the official
/// page address.
class ErrorExplanationCard extends StatelessWidget {
  const ErrorExplanationCard({super.key, required this.help});

  final ErrorHelp help;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final text = help.text;
    final url = help.officialUrl;
    final state = AppScope.of(context);
    final current = CurrentLesson.of(context);
    // Only lessons this learner's track has, and not the one they are in.
    final track = state.track ?? Track.starter;
    final lessons = <(String, String)>[];
    for (final id in help.lessons) {
      final title = state.course?.lessonTitle(id, track: track);
      if (id != current && title != null) lessons.add((id, title));
    }

    return Semantics(
      container: true,
      child: Card(
        margin: EdgeInsets.zero,
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                HelpStrings.errorCardHeading,
                style: textTheme.labelLarge?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: 4),
              Semantics(
                header: true,
                child: Text(
                  text == null
                      ? help.key
                      : help.code == null
                      ? text.title
                      : HelpStrings.errorTitle(help.key, text.title),
                  style: textTheme.titleMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (text != null) ...[
                const SizedBox(height: 8),
                Text(
                  text.explanation,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                if (text.fixes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    HelpStrings.fixesHeading,
                    style: textTheme.labelLarge?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  for (final fix in text.fixes)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '• ',
                            style: TextStyle(
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              fix,
                              style: textTheme.bodyMedium?.copyWith(
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
              for (final (id, title) in lessons)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => context.push('/lesson/$id'),
                    child: Text(HelpStrings.reviewLesson(title)),
                  ),
                ),
              if (url != null) ...[
                const SizedBox(height: 8),
                Text(
                  HelpStrings.officialPage,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                // Selectable text, not a link: learners may be under 13 and
                // stay in the app.
                SelectableText(
                  url,
                  style: codeTextStyle.copyWith(
                    fontSize: (codeTextStyle.fontSize ?? 14) - 1,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
