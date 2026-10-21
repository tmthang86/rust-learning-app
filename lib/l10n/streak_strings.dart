/// Every user-facing string of the streak, XP, daily goal and reminder
/// features, in one place.
///
/// A parallel change adds Flutter gen-l10n (lib/l10n/app_en.arb). When that
/// lands, each member here becomes an ARB key (the methods with parameters
/// become ICU messages with placeholders) and this class can go away.
/// Until then no widget in these features has a hardcoded string.
///
/// The notification text is not read from the widget tree: the scheduler
/// runs outside it. [reminderText] turns a [StreakStrings] into the text of
/// a notification, so a localized instance gives a localized reminder.
class StreakStrings {
  const StreakStrings();

  /// The strings for widgets. One place to change when localizing.
  static const english = StreakStrings();

  // Home
  String get streakLabel => 'Streak';
  String streakDays(int days) => days == 1 ? '1 day' : '$days days';
  String get xpTodayLabel => 'XP today';
  String xpProgress(int today, int goal) => '$today / $goal XP';
  String get goalReachedToday => 'Daily goal reached';
  String get keepItGoing => 'Finish a lesson today to add to your streak.';
  String homeSemantics({
    required int streak,
    required int todayXp,
    required int goal,
  }) {
    final streakText = streak == 0
        ? 'No streak yet'
        : 'Streak: ${streakDays(streak)}';
    final goalText = todayXp >= goal
        ? 'Daily goal reached, $todayXp XP today'
        : 'Today: $todayXp of $goal XP';
    return '$streakText. $goalText.';
  }

  // Lesson feedback
  String xpEarned(int xp) => '+$xp XP';
  String get dailyGoalReachedMessage =>
      "Daily goal reached. Nice work, that's enough for today!";

  // Reminder prompt (shown once, never to under-13s)
  String get promptTitle => 'Want a daily reminder?';
  String get promptBody =>
      'We can send one gentle reminder a day. You can turn it off any time '
      'in Progress.';
  String get promptTurnOn => 'Turn on';
  String get promptNotNow => 'Not now';

  // Progress: stats
  String get statsTitle => 'Streak and XP';
  String get totalXp => 'Total XP';
  String get currentStreak => 'Current streak';
  String get longestStreak => 'Longest streak';
  String get freezesHeld => 'Streak freezes';
  String get freezesHelp =>
      'A freeze covers a day you miss, so your streak keeps going. You earn '
      'one for every 7 days in a row and can hold 2.';
  String statsSemantics({
    required int totalXp,
    required int current,
    required int longest,
    required int freezes,
  }) =>
      'Total XP $totalXp. Current streak ${streakDays(current)}. '
      'Longest streak ${streakDays(longest)}. '
      'Streak freezes held $freezes.';

  // Progress: daily goal
  String get dailyGoalTitle => 'Daily goal';
  String get goalCasual => 'Casual';
  String get goalRegular => 'Regular';
  String get goalSerious => 'Serious';
  String goalOption(String name, int xp) => '$name, $xp XP';
  String goalName(int xp) => switch (xp) {
    20 => goalCasual,
    40 => goalRegular,
    60 => goalSerious,
    _ => '$xp XP',
  };

  // Progress: reminders
  String get remindersTitle => 'Daily reminder';
  String get remindersSubtitle =>
      'One notification a day at the time you pick.';
  String get reminderTimeTitle => 'Reminder time';
  String get remindersDenied =>
      'Notifications are turned off for this app. To get reminders, turn '
      'them on in your device settings, then try again.';
  String get remindersSwitchedOffBySystem =>
      'Reminders were turned off because notifications are blocked in your '
      'device settings.';

  // Notification (see reminderText)
  String get reminderTitle => 'Time for a little Rust?';
  String get reminderBody => 'Your next lesson is ready.';
  String get reminderChannelName => 'Study reminders';
  String get reminderChannelDescription =>
      'A daily reminder to practise, if you turn it on.';
}

/// The text of one reminder notification.
typedef ReminderText = ({String title, String body});

/// The only place notification text is made. Neutral on purpose: no streak
/// counts, no loss or guilt wording, the same for every age.
ReminderText reminderText(StreakStrings strings) =>
    (title: strings.reminderTitle, body: strings.reminderBody);
