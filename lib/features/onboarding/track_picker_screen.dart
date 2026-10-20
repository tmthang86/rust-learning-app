import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';

/// First-launch screen: the learner picks where to start.
class TrackPickerScreen extends StatelessWidget {
  const TrackPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Icon(Icons.memory, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Learn Rust',
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Where would you like to start?',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                _TrackCard(
                  track: Track.starter,
                  icon: Icons.emoji_objects_outlined,
                  title: "I'm new to programming",
                  subtitle: 'Start from the very basics. No experience needed.',
                ),
                const SizedBox(height: 12),
                _TrackCard(
                  track: Track.fast,
                  icon: Icons.rocket_launch_outlined,
                  title: 'I already know another language',
                  subtitle:
                      'Skip the basics and see how Rust compares to what you know.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required this.track,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final Track track;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        leading: Icon(icon, size: 32),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => AppScope.read(context).chooseTrack(track),
      ),
    );
  }
}
