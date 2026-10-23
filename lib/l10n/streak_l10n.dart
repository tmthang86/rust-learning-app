import 'app_localizations.dart';

/// Messages of the streak, XP and daily goal features that are put together
/// from several ARB entries. The words are all in lib/l10n/app_*.arb.
extension StreakL10n on AppLocalizations {
  /// Screen-reader summary of the Home streak card.
  String homeSemantics({
    required int streak,
    required int todayXp,
    required int goal,
  }) {
    final streakText = streak == 0
        ? streakSemanticsNone
        : streakSemantics(streakDays(streak));
    final goalText = todayXp >= goal
        ? goalReachedSemantics(todayXp)
        : goalProgressSemantics(todayXp, goal);
    return homeSemanticsJoin(streakText, goalText);
  }

  /// Screen-reader summary of the Progress streak card.
  String statsSemanticsFor({
    required int totalXpValue,
    required int current,
    required int longest,
    required int freezes,
  }) => statsSemantics(
    totalXpValue,
    streakDays(current),
    streakDays(longest),
    freezes,
  );

  String xpEarnedWithGoal(int xp) =>
      xpEarnedWithGoalJoin(xpEarned(xp), dailyGoalReachedMessage);

  /// "Casual" for the 20 XP goal, "Regular" for 40, "Serious" for 60.
  String goalName(int xp) => switch (xp) {
    20 => goalCasual,
    40 => goalRegular,
    60 => goalSerious,
    _ => '$xp XP',
  };

  /// The text of one daily goal button: the name, a line break, the XP.
  String goalSegmentLabel(int xp) => '${goalName(xp)}\n$xp XP';
}
