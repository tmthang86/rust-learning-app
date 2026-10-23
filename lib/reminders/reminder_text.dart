import '../l10n/app_localizations.dart';

/// The text of one reminder notification.
typedef ReminderText = ({String title, String body});

/// The only place notification text is made. Neutral on purpose: no streak
/// counts, no loss or guilt wording, the same for every age.
///
/// The scheduler runs outside the widget tree, so the caller passes the
/// localizations of the app's language at the time of scheduling (see
/// `StudyReminders.l10n`); a language change plans the reminders again.
ReminderText reminderText(AppLocalizations l10n) =>
    (title: l10n.reminderTitle, body: l10n.reminderBody);
