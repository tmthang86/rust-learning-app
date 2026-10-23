import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../settings/language_picker.dart';

/// First-launch screen: the learner picks where to start.
class TrackPickerScreen extends StatelessWidget {
  const TrackPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
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
                  l10n.appTitle,
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.trackPickerPrompt,
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                _TrackCard(
                  track: Track.starter,
                  icon: Icons.emoji_objects_outlined,
                  title: l10n.trackStarterTitle,
                  subtitle: l10n.trackStarterSubtitle,
                ),
                const SizedBox(height: 12),
                _TrackCard(
                  track: Track.fast,
                  icon: Icons.rocket_launch_outlined,
                  title: l10n.trackFastTitle,
                  subtitle: l10n.trackFastSubtitle,
                ),
                const SizedBox(height: 32),
                const LanguageSetting(),
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
