import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/data/streaks.dart';

/// The streak, freeze and XP numbers are derived from a map of day -> XP.
void main() {
  // A fixed "today" in the middle of the week; days are written as offsets.
  final today = DateTime(2026, 3, 18, 14, 30);

  String day(int daysAgo) =>
      dayKey(DateTime(today.year, today.month, today.day - daysAgo));

  Map<String, int> log(Iterable<int> daysAgo, {int xp = 20}) => {
    for (final d in daysAgo) day(d): xp,
  };

  StreakSummary run(Map<String, int> m, [DateTime? now]) =>
      summarizeStreak(m, now ?? today);

  group('day keys', () {
    test('format with zero padding, from the date parts only', () {
      expect(dayKey(DateTime(2026, 3, 8, 23, 59)), '2026-03-08');
      expect(dayKey(DateTime.utc(2026, 12, 31)), '2026-12-31');
      expect(dayKey(DateTime(987, 1, 2)), '0987-01-02');
    });

    test('parse valid keys and reject everything else', () {
      expect(parseDayKey('2026-03-08'), isNotNull);
      expect(parseDayKey('2024-02-29'), isNotNull); // leap day
      for (final bad in [
        '',
        '2026-3-8',
        '2026-03-8',
        '26-03-08',
        '2026-13-01',
        '2026-00-10',
        '2026-02-30',
        '2025-02-29', // not a leap year
        '2026-04-31',
        '2026-03-08 ',
        ' 2026-03-08',
        '2026/03/08',
        'tomorrow',
        '2026-03-08T00:00:00',
      ]) {
        expect(parseDayKey(bad), isNull, reason: bad);
      }
    });

    test('consecutive dates are one day number apart across month and year '
        'ends', () {
      int n(String k) => parseDayKey(k)!;
      expect(n('2026-03-01') - n('2026-02-28'), 1);
      expect(n('2024-03-01') - n('2024-02-29'), 1);
      expect(n('2024-02-29') - n('2024-02-28'), 1);
      expect(n('2027-01-01') - n('2026-12-31'), 1);
      expect(n('2027-01-01') - n('2026-01-01'), 365);
    });

    test('day arithmetic ignores daylight saving changes', () {
      // Whatever zone the tests run in, these are plain calendar dates.
      expect(
        dayNumber(2026, 3, 9) - dayNumber(2026, 3, 8),
        1,
        reason: 'US spring forward',
      );
      expect(dayNumber(2026, 3, 30) - dayNumber(2026, 3, 29), 1);
      expect(dayNumber(2026, 11, 2) - dayNumber(2026, 11, 1), 1);
      expect(dayNumber(2026, 10, 26) - dayNumber(2026, 10, 25), 1);
    });
  });

  group('cleaning stored data', () {
    test('keeps good days, drops bad keys and bad values', () {
      expect(
        cleanDailyXp({
          '2026-03-08': 25,
          '2026-03-09': 10.0, // a whole double is fine
          '2026-03-10': 10.5,
          '2026-03-11': '20',
          '2026-03-12': 0,
          '2026-03-13': -5,
          '2026-03-14': null,
          '2026-03-15': maxDailyXpValue + 1,
          '2026-02-30': 20,
          'junk': 20,
          7: 20,
        }),
        {'2026-03-08': 25, '2026-03-09': 10},
      );
    });

    test('anything that is not a map becomes empty', () {
      expect(cleanDailyXp(null), isEmpty);
      expect(cleanDailyXp('x'), isEmpty);
      expect(cleanDailyXp([1, 2]), isEmpty);
    });

    test('merging takes the larger value per day and never sums', () {
      final a = {'2026-03-08': 20, '2026-03-09': 5};
      final b = {'2026-03-08': 25, '2026-03-10': 40};
      expect(mergeDailyXp(a, b), {
        '2026-03-08': 25,
        '2026-03-09': 5,
        '2026-03-10': 40,
      });
      // The same data merged twice is the same data.
      final once = mergeDailyXp(a, b);
      expect(mergeDailyXp(once, b), once);
      expect(mergeDailyXp(b, a), once);
    });

    test('daysAhead lists only days where the first map is larger', () {
      expect(
        daysAhead(
          {'2026-03-08': 20, '2026-03-09': 5, '2026-03-10': 40},
          {'2026-03-08': 20, '2026-03-09': 9},
        ),
        {'2026-03-10': 40},
      );
    });
  });

  group('basics', () {
    test('an empty log has nothing', () {
      expect(run({}), StreakSummary.empty);
    });

    test('total and today XP', () {
      final s = run({day(0): 25, day(1): 20, day(5): 5});
      expect(s.totalXp, 50);
      expect(s.todayXp, 25);
      expect(s.goalMet(20), isTrue);
      expect(s.goalMet(40), isFalse);
    });

    test('three days in a row ending today', () {
      final s = run(log([0, 1, 2]));
      expect(s.currentStreak, 3);
      expect(s.longestStreak, 3);
      expect(s.freezesHeld, 0);
    });

    test('today not done yet does not break the streak', () {
      final s = run(log([1, 2, 3]));
      expect(s.currentStreak, 3);
      expect(s.todayXp, 0);
    });

    test('a missed day with no freeze ends the streak', () {
      final s = run(log([2, 3, 4]));
      expect(s.currentStreak, 0);
      expect(s.longestStreak, 3);
    });

    test('a gap in the middle restarts the streak', () {
      final s = run(log([0, 1, 4, 5, 6, 7]));
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 4);
    });

    test('a single day', () {
      final s = run(log([0]));
      expect(s.currentStreak, 1);
      expect(s.longestStreak, 1);
    });

    test('days with 0 or negative XP are not active', () {
      final s = run({day(0): 0, day(1): -3, day(2): 20});
      expect(s.currentStreak, 0);
      expect(s.longestStreak, 1);
    });

    test('only the date of today counts, not the time', () {
      final late = DateTime(2026, 3, 18, 23, 59, 59);
      final early = DateTime(2026, 3, 18, 0, 0, 1);
      final m = log([0, 1]);
      expect(run(m, late), run(m, early));
    });
  });

  group('freezes', () {
    test('one is earned at 7 active days in a row', () {
      expect(run(log(List.generate(6, (i) => i))).freezesHeld, 0);
      expect(run(log(List.generate(7, (i) => i))).freezesHeld, 1);
      expect(run(log(List.generate(13, (i) => i))).freezesHeld, 1);
    });

    test('at most 2 are held', () {
      expect(run(log(List.generate(14, (i) => i))).freezesHeld, 2);
      expect(run(log(List.generate(21, (i) => i))).freezesHeld, 2);
      expect(run(log(List.generate(60, (i) => i))).freezesHeld, 2);
    });

    test('a freeze covers one missed day: the streak goes on, the frozen '
        'day is not counted', () {
      // 7 active days, one missed day, then 2 more active days.
      final s = run(log([0, 1, 3, 4, 5, 6, 7, 8, 9]));
      // days 9..3 are 7 active days (freeze earned), day 2 missed (freeze
      // used), days 1 and 0 active again.
      expect(s.currentStreak, 9);
      expect(s.longestStreak, 9);
      expect(s.freezesHeld, 0);
    });

    test('the freeze is used for the day missed, and a second miss then '
        'ends the streak', () {
      // 7 active days (days 11..5), freeze earned. Day 4 missed (freeze
      // used), day 3 active, days 2 and 1 missed, today (0) not done.
      final s = run(log([11, 10, 9, 8, 7, 6, 5, 3]));
      expect(s.currentStreak, 0);
      expect(s.longestStreak, 8);
      expect(s.freezesHeld, 0);
    });

    test('two freezes cover two missed days in a row', () {
      // 14 active days -> 2 freezes. Then 2 missed days, then active.
      final active = [
        0,
        1,
        ...List.generate(14, (i) => i + 4), // days 17..4
      ];
      final s = run(log(active));
      // 14 + 2 active days = 16, the 2 missed days (3 and 2) are frozen.
      expect(s.currentStreak, 16);
      expect(s.freezesHeld, 0);
    });

    test('three missed days with two freezes ends the streak and the '
        'freezes are gone', () {
      final active = [...List.generate(14, (i) => i + 5), 0]; // 18..5, 0
      final s = run(log(active));
      expect(s.currentStreak, 1);
      expect(s.longestStreak, 14);
      expect(s.freezesHeld, 0);
    });

    test('freezes earned again after one was used', () {
      // 7 days (freeze), a missed day (used), then 7 more days (one more).
      final s = run(
        log([...List.generate(7, (i) => i), ...List.generate(7, (i) => i + 8)]),
      );
      expect(s.currentStreak, 14);
      // The 14th active day earned a freeze: 1 earned at 7, used on the
      // gap, 1 earned at 14.
      expect(s.freezesHeld, 1);
    });

    test('the days since the last active day are covered by a held freeze '
        'the same way, so the streak shown is the one that continues', () {
      // 7 days ending 3 days ago, freeze earned. Days 2 and 1 missed.
      final active = List.generate(7, (i) => i + 3); // 9..3
      var s = run(log(active));
      // Two missed days (2, 1) but only one freeze: ended.
      expect(s.currentStreak, 0);
      expect(s.longestStreak, 7);
      expect(s.freezesHeld, 0);

      // 7 days ending 2 days ago: only yesterday missed, one freeze.
      s = run(log(List.generate(7, (i) => i + 2)));
      expect(s.currentStreak, 7);
      expect(s.freezesHeld, 0);

      // Doing a lesson today then continues that same streak.
      s = run(log([0, ...List.generate(7, (i) => i + 2)]));
      expect(s.currentStreak, 8);
      expect(s.freezesHeld, 0);
    });

    test('freezes left over from a streak that ended do not carry into the '
        'next one', () {
      // Days 15..9 earn a freeze (7 in a row). Seven missed days end that
      // streak; the freeze is gone, and a new streak starts on day 1.
      final s = run(log([...List.generate(7, (i) => i + 9), 1, 0]));
      expect(s.longestStreak, 7);
      expect(s.currentStreak, 2);
      expect(s.freezesHeld, 0);
    });
  });

  group('boundaries', () {
    test('across a month end', () {
      final now = DateTime(2026, 3, 2);
      final s = run({
        '2026-02-27': 20,
        '2026-02-28': 20,
        '2026-03-01': 20,
      }, now);
      expect(s.currentStreak, 3);
    });

    test('across a leap day', () {
      final now = DateTime(2024, 3, 1);
      final s = run({
        '2024-02-28': 20,
        '2024-02-29': 20,
        '2024-03-01': 20,
      }, now);
      expect(s.currentStreak, 3);
    });

    test('across a year end', () {
      final now = DateTime(2027, 1, 1);
      final s = run({
        '2026-12-30': 20,
        '2026-12-31': 20,
        '2027-01-01': 20,
      }, now);
      expect(s.currentStreak, 3);
      expect(s.todayXp, 20);
    });

    test('across daylight saving days', () {
      for (final start in [
        DateTime(2026, 3, 7), // US spring forward on the 8th
        DateTime(2026, 3, 28), // EU spring forward on the 29th
        DateTime(2026, 10, 24), // EU fall back on the 25th
        DateTime(2026, 10, 31), // US fall back on Nov 1st
      ]) {
        final days = [
          for (var i = 0; i < 4; i++)
            dayKey(DateTime(start.year, start.month, start.day + i)),
        ];
        final now = DateTime(start.year, start.month, start.day + 3, 12);
        final s = summarizeStreak({for (final d in days) d: 20}, now);
        expect(s.currentStreak, 4, reason: '$start');
      }
    });

    test('a streak over a long span of days stays right', () {
      final start = DateTime(2025, 1, 1);
      final days = {
        for (var i = 0; i < 400; i++)
          dayKey(DateTime(start.year, start.month, start.day + i)): 20,
      };
      final s = summarizeStreak(days, DateTime(2026, 2, 5)); // day 400
      expect(s.currentStreak, 400);
      expect(s.freezesHeld, 2);
    });
  });

  group('bad data', () {
    test('future-dated days are ignored for the streak', () {
      final s = run({
        ...log([0, 1]),
        '2099-01-01': 20,
        day(-1): 20, // tomorrow, from a clock that was ahead
        day(-2): 20,
      });
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);
      expect(s.todayXp, 20);
    });

    test('a log with only future days has no streak', () {
      final s = run({day(-1): 20, day(-2): 20});
      expect(s.currentStreak, 0);
      expect(s.longestStreak, 0);
      expect(s.todayXp, 0);
    });

    test('malformed keys are ignored', () {
      final s = run({
        ...log([0, 1]),
        'garbage': 99,
        '2026-02-30': 99,
        '': 99,
        '2026-3-17': 99,
      });
      expect(s.currentStreak, 2);
      expect(s.totalXp, 40);
    });
  });
}
