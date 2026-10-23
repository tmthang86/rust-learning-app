import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/age.dart';
import '../../data/app_state.dart';
import '../../data/streaks.dart';
import '../../l10n/l10n.dart';
import '../../l10n/streak_l10n.dart';

/// Home: the streak and today's XP against the daily goal, in one compact
/// card read out as one sentence by screen readers.
///
/// Nothing here warns about losing a streak. The only hint about today is a
/// calm line for people 13 and over; for a possible under-13 it is left
/// out, so the card only ever shows what they have.
class StreakCard extends StatelessWidget {
  const StreakCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final summary = state.summary;
    final goal = state.dailyGoal;
    final met = summary.goalMet(goal);
    // Only for people known to be 13 or older: not for a possible under-13
    // (which includes an age not given yet).
    final group = state.age.group;
    final showHint =
        (group == AgeGroup.teen || group == AgeGroup.adult) &&
        !met &&
        summary.todayXp == 0 &&
        summary.currentStreak > 0;
    final progress = (summary.todayXp / goal).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Semantics(
          container: true,
          label: s.homeSemantics(
            streak: summary.currentStreak,
            todayXp: summary.todayXp,
            goal: goal,
          ),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.local_fire_department,
                      size: 36,
                      color: summary.currentStreak > 0
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.streakDays(summary.currentStreak),
                            style: theme.textTheme.titleLarge,
                          ),
                          Text(s.streakLabel, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Flexible(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (met) ...[
                                Icon(
                                  Icons.check_circle,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  s.xpProgress(summary.todayXp, goal),
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (met) ...[
                  const SizedBox(height: 8),
                  Text(s.goalReachedToday, style: theme.textTheme.bodySmall),
                ] else if (showHint) ...[
                  const SizedBox(height: 8),
                  Text(s.keepItGoing, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Home: the one-time offer of a daily reminder. Shown only when
/// [AppState.showReminderPrompt] says so, which is never for a possible
/// under-13 and never while the age is unknown. Either button ends it for
/// good.
class ReminderPromptCard extends StatelessWidget {
  const ReminderPromptCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    final state = AppScope.of(context);
    if (kIsWeb || !state.showReminderPrompt) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.promptTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(s.promptBody),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _turnOn(context),
                  child: Text(s.promptTurnOn),
                ),
                TextButton(
                  onPressed: state.reminders.dismissPrompt,
                  child: Text(s.promptNotNow),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _turnOn(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final denied = context.l10n.remindersDenied;
    final on = await AppScope.read(context).reminders.setEnabled(true);
    if (!on) {
      messenger.showSnackBar(SnackBar(content: Text(denied)));
    }
  }
}

/// Progress: totals and streaks.
class StreakStatsCard extends StatelessWidget {
  const StreakStatsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    final summary = AppScope.of(context).summary;
    final theme = Theme.of(context);

    Widget stat(IconData icon, String label, String value) => Expanded(
      child: Column(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(height: 4),
          Text(value, style: theme.textTheme.titleLarge),
          Text(
            label,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.statsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Semantics(
              container: true,
              label: s.statsSemanticsFor(
                totalXpValue: summary.totalXp,
                current: summary.currentStreak,
                longest: summary.longestStreak,
                freezes: summary.freezesHeld,
              ),
              child: ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    stat(Icons.bolt, s.totalXp, '${summary.totalXp}'),
                    stat(
                      Icons.local_fire_department,
                      s.currentStreak,
                      '${summary.currentStreak}',
                    ),
                    stat(
                      Icons.emoji_events_outlined,
                      s.longestStreak,
                      '${summary.longestStreak}',
                    ),
                    stat(
                      Icons.ac_unit,
                      s.freezesHeld,
                      '${summary.freezesHeld}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(s.freezesHelp, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Progress: pick the daily goal (20, 40 or 60 XP).
class DailyGoalPicker extends StatelessWidget {
  const DailyGoalPicker({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.dailyGoalTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            for (final xp in dailyGoalChoices)
              ButtonSegment(
                value: xp,
                label: Text(
                  s.goalSegmentLabel(xp),
                  textAlign: TextAlign.center,
                ),
                tooltip: s.goalOption(s.goalName(xp), xp),
              ),
          ],
          selected: {state.dailyGoal},
          onSelectionChanged: (v) => state.setDailyGoal(v.first),
        ),
      ],
    );
  }
}

/// Progress: the daily reminder switch and time. Not shown on the web or
/// anywhere reminders can't work. The system's permission prompt appears
/// only when this switch is turned on.
class ReminderSettings extends StatelessWidget {
  const ReminderSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    final state = AppScope.of(context);
    final reminders = state.reminders;
    if (kIsWeb || !reminders.supported) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final time = TimeOfDay(
      hour: reminders.minutesOfDay ~/ 60,
      minute: reminders.minutesOfDay % 60,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s.remindersTitle),
          subtitle: Text(s.remindersSubtitle),
          value: reminders.enabled,
          onChanged: (on) => reminders.setEnabled(on),
        ),
        if (reminders.enabled)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.reminderTimeTitle),
            trailing: Text(
              MaterialLocalizations.of(context).formatTimeOfDay(time),
              style: theme.textTheme.titleMedium,
            ),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: time,
              );
              if (picked != null) {
                await reminders.setMinutes(picked.hour * 60 + picked.minute);
              }
            },
          ),
        if (reminders.permissionDenied)
          Semantics(
            liveRegion: true,
            child: Text(
              s.remindersDenied,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (reminders.revokedBySystem)
          Semantics(
            liveRegion: true,
            child: Text(s.remindersSwitchedOffBySystem),
          ),
      ],
    );
  }
}

/// What a finished lesson earned, as a short line: "+20 XP", plus a
/// positive note the first time today's goal is reached. Empty when the
/// lesson earned nothing (it already counted today).
class XpEarnedNote extends StatelessWidget {
  const XpEarnedNote({super.key, required this.award});

  final XpAward? award;

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    final a = award;
    if (a == null || a.xp == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        children: [
          Chip(
            avatar: Icon(Icons.bolt, color: theme.colorScheme.primary),
            label: Text(s.xpEarned(a.xp)),
          ),
          if (a.goalReached) ...[
            const SizedBox(height: 8),
            Text(
              s.dailyGoalReachedMessage,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }
}

/// The same feedback as a snackbar, for places that have no room for the
/// note (lessons that end the moment they are marked done, or solved
/// exercises). Pass a messenger taken before the screen can close.
void showXpSnackBar(
  ScaffoldMessengerState messenger,
  XpAward award,
  AppLocalizations s,
) {
  if (award.xp == 0) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        award.goalReached ? s.xpEarnedWithGoal(award.xp) : s.xpEarned(award.xp),
      ),
    ),
  );
}
