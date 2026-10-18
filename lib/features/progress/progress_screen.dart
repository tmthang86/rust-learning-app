import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';

/// Overall progress and track setting.
class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final total = state.totalLessons;
    final done = state.completedCount;

    return Scaffold(
      appBar: AppBar(title: const Text('Progress')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$done of $total lessons done',
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: total == 0 ? 0 : done / total,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              for (final unit in state.visibleUnits.where((u) => !u.comingSoon))
                ListTile(
                  leading: CircleAvatar(child: Text('${unit.number}')),
                  title: Text(unit.title),
                  trailing: Text(
                    '${unit.lessons.where((l) => state.isCompleted(l.id)).length}'
                    '/${unit.lessons.length}',
                  ),
                ),
              const Divider(height: 32),
              Text('Learning track', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<Track>(
                segments: const [
                  ButtonSegment(value: Track.starter, label: Text('New to coding')),
                  ButtonSegment(value: Track.fast, label: Text('Experienced')),
                ],
                selected: {if (state.track != null) state.track!},
                emptySelectionAllowed: true,
                onSelectionChanged: (s) {
                  if (s.isNotEmpty) state.chooseTrack(s.first);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
