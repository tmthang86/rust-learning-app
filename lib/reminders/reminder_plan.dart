import '../l10n/streak_strings.dart';
import 'reminder_scheduler.dart';

/// Reminders are scheduled for this many days from today, as one-shot
/// notifications. The app plans them again every time it opens, so a learner
/// who stops opening the app gets at most a week of reminders and then none.
const reminderDays = 7;

/// 19:00, in minutes after midnight.
const defaultReminderMinutes = 19 * 60;

/// The reminders to schedule, as local date times: one at [minutesOfDay]
/// on each of the [reminderDays] days starting with today's date.
///
/// Today is skipped when [goalMetToday] (nothing to remind about) or when
/// its time is not after [now]. So there are 7 reminders normally and 6
/// when today is skipped.
///
/// Dates are built from the calendar date and the time of day, so a daylight
/// saving change moves nothing off the chosen wall-clock time.
List<ScheduledReminder> planReminders({
  required DateTime now,
  required int minutesOfDay,
  required bool goalMetToday,
  required ReminderText text,
}) {
  final minutes = minutesOfDay.clamp(0, 24 * 60 - 1);
  final hour = minutes ~/ 60;
  final minute = minutes % 60;
  final out = <ScheduledReminder>[];
  for (var offset = 0; offset < reminderDays; offset++) {
    // DateTime() rolls the day over month and year ends.
    final when = DateTime(now.year, now.month, now.day + offset, hour, minute);
    if (offset == 0 && (goalMetToday || !when.isAfter(now))) continue;
    out.add(ScheduledReminder(id: offset + 1, when: when, text: text));
  }
  return out;
}
