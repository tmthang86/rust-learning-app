/// XP, daily goal and streak rules. Everything here is pure: the learner's
/// activity is one map from a local day (`yyyy-MM-dd`) to the XP earned that
/// day, and every number shown (streak, longest streak, freezes, totals) is
/// derived from it by [summarizeStreak], with "today" passed in. Nothing
/// derived is stored, so two devices that merge their maps always agree.
///
/// See docs/streaks-and-reminders.md for the rules and the reasons behind
/// them.
library;

import 'dart:math' as math;

/// XP for finishing a lesson the first time.
const xpFirstCompletion = 20;

/// XP for finishing a lesson that was already done (a review).
const xpReview = 5;

/// The daily goal choices in XP (Casual, Regular, Serious).
const dailyGoalChoices = [20, 40, 60];

/// The daily goal until the learner picks another.
const defaultDailyGoal = 20;

/// One streak freeze is earned for every this many active days in a row.
const activeDaysPerFreeze = 7;

/// Most freezes that can be held at once.
const maxFreezes = 2;

/// Firestore.rules allows at most this many days in the synced map.
const maxSyncedDays = 4000;

/// A single day above this is not believable (an edited document) and is
/// ignored when reading.
const maxDailyXpValue = 100000;

/// What one finished lesson earned.
class XpAward {
  const XpAward({required this.xp, this.goalReached = false});

  /// Nothing earned (the lesson already counted today).
  static const none = XpAward(xp: 0);

  final int xp;

  /// This award is what first took today's XP to the daily goal.
  final bool goalReached;

  @override
  bool operator ==(Object other) =>
      other is XpAward && other.xp == xp && other.goalReached == goalReached;

  @override
  int get hashCode => Object.hash(xp, goalReached);

  @override
  String toString() => 'XpAward($xp, goalReached: $goalReached)';
}

/// The key for a local calendar day: `2026-03-08`. Uses only the date parts
/// of [day], whatever time zone it is in.
String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

final _dayKeyPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Days since 1970-01-01 for a calendar date. Computed in UTC, so a daylight
/// saving change (a 23 or 25 hour day) never makes two dates look 0 or 2
/// days apart.
int dayNumber(int year, int month, int day) =>
    DateTime.utc(year, month, day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// The [dayNumber] of a valid `yyyy-MM-dd` key, or null for anything else
/// (wrong shape, or a date that doesn't exist like `2026-02-30`).
int? parseDayKey(String key) {
  final m = _dayKeyPattern.firstMatch(key);
  if (m == null) return null;
  final y = int.parse(m[1]!);
  final mo = int.parse(m[2]!);
  final d = int.parse(m[3]!);
  final check = DateTime.utc(y, mo, d);
  if (check.year != y || check.month != mo || check.day != d) return null;
  return check.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
}

/// Keeps the entries of a stored or downloaded map that make sense: a valid
/// day key and a whole number of XP between 1 and [maxDailyXpValue]. Anything
/// else (wrong types, bad keys, zero or negative XP) is dropped.
Map<String, int> cleanDailyXp(Object? raw) {
  if (raw is! Map) return {};
  final out = <String, int>{};
  raw.forEach((key, value) {
    if (key is! String || parseDayKey(key) == null) return;
    final int xp;
    if (value is int) {
      xp = value;
    } else if (value is double && value == value.roundToDouble()) {
      xp = value.toInt();
    } else {
      return;
    }
    if (xp < 1 || xp > maxDailyXpValue) return;
    out[key] = xp;
  });
  return out;
}

/// Per day, the larger of the two. Never a sum: a day already counted on
/// one device must not be counted again when another device merges it. The
/// price is that XP earned on the same day on two devices that didn't sync
/// in between is undercounted (only the larger device's share survives).
Map<String, int> mergeDailyXp(Map<String, int> a, Map<String, int> b) {
  final out = {...a};
  b.forEach((day, xp) {
    final have = out[day];
    if (have == null || xp > have) out[day] = xp;
  });
  return out;
}

/// The days where [merged] holds more than [base] does.
Map<String, int> daysAhead(Map<String, int> merged, Map<String, int> base) => {
  for (final e in merged.entries)
    if (e.value > (base[e.key] ?? 0)) e.key: e.value,
};

/// The numbers shown for a learner on one day.
class StreakSummary {
  const StreakSummary({
    required this.currentStreak,
    required this.longestStreak,
    required this.freezesHeld,
    required this.totalXp,
    required this.todayXp,
  });

  /// Nothing earned yet.
  static const empty = StreakSummary(
    currentStreak: 0,
    longestStreak: 0,
    freezesHeld: 0,
    totalXp: 0,
    todayXp: 0,
  );

  /// Active days in the running streak. Days a freeze covered keep the
  /// streak going but are not counted. Zero once the streak ended.
  final int currentStreak;

  /// The most active days any streak ever had, including the current one.
  final int longestStreak;

  /// Freezes held after covering any missed days up to yesterday.
  final int freezesHeld;

  /// Every XP in the log (future-dated days included: XP is XP).
  final int totalXp;

  /// XP earned on the given day.
  final int todayXp;

  /// Whether the daily goal is reached today.
  bool goalMet(int goal) => todayXp >= goal;

  @override
  bool operator ==(Object other) =>
      other is StreakSummary &&
      other.currentStreak == currentStreak &&
      other.longestStreak == longestStreak &&
      other.freezesHeld == freezesHeld &&
      other.totalXp == totalXp &&
      other.todayXp == todayXp;

  @override
  int get hashCode =>
      Object.hash(currentStreak, longestStreak, freezesHeld, totalXp, todayXp);

  @override
  String toString() =>
      'StreakSummary(streak: $currentStreak, longest: $longestStreak, '
      'freezes: $freezesHeld, total: $totalXp, today: $todayXp)';
}

/// Derives the streak numbers from the activity log [log] as of [today]
/// (only its year, month and day are used).
///
/// A day is active when it has more than 0 XP. Walking the active days from
/// the oldest:
/// - the next active day follows directly, or after missed days that held
///   freezes cover one for one: the streak goes on, and the covered days are
///   not counted;
/// - with fewer freezes than missed days the streak ends (the freezes are
///   gone too) and the next active day starts a new streak of 1;
/// - every [activeDaysPerFreeze]th active day of a streak earns a freeze,
///   at most [maxFreezes] held.
///
/// Today not being done yet breaks nothing. The days since the last active
/// day, up to yesterday, are covered by freezes the same way as in the
/// middle of the history, so the streak shown today is the one that
/// continues when the learner finishes a lesson. Without enough freezes the
/// current streak is 0.
///
/// Days after [today] (a wrong clock earlier) and keys that are not valid
/// dates are ignored for the streak; XP of days with an invalid key is not
/// counted at all.
StreakSummary summarizeStreak(Map<String, int> log, DateTime today) {
  final todayNumber = dayNumber(today.year, today.month, today.day);
  var total = 0;
  var todayXp = 0;
  final active = <int>[];
  log.forEach((key, xp) {
    final n = parseDayKey(key);
    if (n == null || xp < 1) return;
    total += xp;
    if (n > todayNumber) return;
    if (n == todayNumber) todayXp = xp;
    active.add(n);
  });
  if (active.isEmpty) {
    return StreakSummary(
      currentStreak: 0,
      longestStreak: 0,
      freezesHeld: 0,
      totalXp: total,
      todayXp: todayXp,
    );
  }
  active.sort();

  var run = 0;
  var freezes = 0;
  var longest = 0;
  int? last;
  for (final day in active) {
    if (last == null) {
      run = 1;
    } else {
      final missed = day - last - 1;
      if (missed <= freezes) {
        freezes -= missed;
        run++;
        if (run % activeDaysPerFreeze == 0) {
          freezes = math.min(maxFreezes, freezes + 1);
        }
      } else {
        run = 1;
        freezes = 0;
      }
    }
    longest = math.max(longest, run);
    last = day;
  }

  // Days between the last active day and today (not counting today).
  final missed = math.max(0, todayNumber - last! - 1);
  final int current;
  if (missed <= freezes) {
    current = run;
    freezes -= missed;
  } else {
    current = 0;
    freezes = 0;
  }
  return StreakSummary(
    currentStreak: current,
    longestStreak: longest,
    freezesHeld: freezes,
    totalXp: total,
    todayXp: todayXp,
  );
}
