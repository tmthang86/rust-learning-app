import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';
import '../../monetization/ad_banner.dart';
import '../../monetization/ads_service.dart';

/// The course map: units for the learner's track, each with its lessons.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final units = state.visibleUnits;

    return Scaffold(
      appBar: AppBar(title: const Text('Learn Rust')),
      body: state.course == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final (i, unit) in units.indexed) ...[
                      if (i > 0) const SizedBox(height: 12),
                      _UnitCard(unit: unit),
                      // One small banner after the first unit, inside the
                      // list (not over the navigation bar). It brings its
                      // own space when shown.
                      if (i == 0)
                        const AdBannerSlot(placement: AdPlacement.courseMap),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class _UnitCard extends StatelessWidget {
  const _UnitCard({required this.unit});

  final Unit unit;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final done = unit.lessons.where((l) => state.isCompleted(l.id)).length;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        enabled: !unit.comingSoon,
        leading: CircleAvatar(child: Text('${unit.number}')),
        title: Text(unit.title),
        subtitle: Text(
          unit.comingSoon
              ? 'Coming soon'
              : '${unit.summary}\n$done of ${unit.lessons.length} lessons done',
        ),
        children: [
          for (final lesson in unit.lessons)
            ListTile(
              leading: Icon(
                state.isCompleted(lesson.id)
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color: state.isCompleted(lesson.id)
                    ? theme.colorScheme.primary
                    : null,
              ),
              title: Text(lesson.title),
              onTap: () => context.push('/lesson/${lesson.id}'),
            ),
        ],
      ),
    );
  }
}
