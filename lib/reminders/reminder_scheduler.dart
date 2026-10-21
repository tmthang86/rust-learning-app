import '../l10n/app_localizations.dart';
import 'reminder_text.dart';

/// One notification to show at one moment.
class ScheduledReminder {
  const ScheduledReminder({
    required this.id,
    required this.when,
    required this.text,
  });

  /// A small number, unique within one schedule.
  final int id;

  /// A local date and time (the device's time zone when it was planned).
  final DateTime when;

  final ReminderText text;

  @override
  bool operator ==(Object other) =>
      other is ScheduledReminder &&
      other.id == id &&
      other.when == when &&
      other.text == text;

  @override
  int get hashCode => Object.hash(id, when, text);

  @override
  String toString() => 'ScheduledReminder($id, $when, ${text.title})';
}

/// Shows notifications for the study reminders. The real one wraps
/// flutter_local_notifications; tests use a fake. Kept apart from the
/// plugin so the scheduling rules can be tested without it.
abstract class ReminderScheduler {
  /// False where reminders can't work (the web): the UI hides them.
  bool get supported;

  /// Prepares the plugin and takes the app's language. The Android channel
  /// name and description are written with each schedule (the channel is
  /// updated, so a language change renames it).
  /// Never asks for permission. Safe to call again.
  Future<void> initialize(AppLocalizations l10n);

  /// Whether the system lets the app show notifications right now.
  Future<bool> hasPermission();

  /// Asks the system for permission (a prompt). Call only because the
  /// learner just turned reminders on. Returns whether it is granted.
  Future<bool> requestPermission();

  /// Cancels every reminder that is waiting, then schedules [reminders].
  Future<void> replaceAll(List<ScheduledReminder> reminders);

  /// Cancels every reminder that is waiting.
  Future<void> cancelAll();
}

/// For the web and for tests that don't care: nothing is ever shown.
class NoopReminderScheduler implements ReminderScheduler {
  const NoopReminderScheduler();

  @override
  bool get supported => false;
  @override
  Future<void> initialize(AppLocalizations l10n) async {}
  @override
  Future<bool> hasPermission() async => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<void> replaceAll(List<ScheduledReminder> reminders) async {}
  @override
  Future<void> cancelAll() async {}
}
