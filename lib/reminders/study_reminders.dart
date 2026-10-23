import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';
import 'reminder_plan.dart';
import 'reminder_scheduler.dart';
import 'reminder_text.dart';

/// The learner's reminder settings and the schedule that follows from them.
///
/// Everything is on this device only (never synced). Reminders start OFF for
/// everyone. They are switched on only by the learner, through
/// [setEnabled], which is the one place the system permission is asked for.
/// The one-time soft prompt (see [promptSeen]) is offered by the UI only
/// to people 13 and over.
class StudyReminders extends ChangeNotifier {
  StudyReminders({
    required this.prefs,
    required this.scheduler,
    required this.clock,
    required this.goalMetToday,
    AppLocalizations Function()? l10n,
  }) : l10n = l10n ?? AppLocalizationsEn.new,
       _enabled = prefs.getBool(enabledKey) ?? false,
       _minutes = _readMinutes(prefs),
       _promptSeen = prefs.getBool(promptSeenKey) ?? false;

  static const enabledKey = 'reminderEnabled';
  static const minutesKey = 'reminderMinutes';
  static const promptSeenKey = 'reminderPromptSeen';

  final SharedPreferences prefs;
  final ReminderScheduler scheduler;
  final DateTime Function() clock;

  /// Whether today's XP already reached the daily goal.
  final bool Function() goalMetToday;

  /// The words of the notification and its channel, in the app's language
  /// at the moment of scheduling (asked every time, not stored).
  final AppLocalizations Function() l10n;

  bool _enabled;
  int _minutes;
  bool _promptSeen;
  bool _permissionDenied = false;
  bool _revokedBySystem = false;
  bool _disposed = false;

  /// Counts resets. A job that was waiting for the system (the permission
  /// dialog) gives up if the device was reset meanwhile: sign-out wins.
  int _resetEpoch = 0;

  /// Work on the scheduler runs one job at a time, so a cancel never runs
  /// between two steps of another schedule.
  final List<(Future<void> Function(), Completer<void>)> _jobs = [];
  bool _draining = false;

  static int _readMinutes(SharedPreferences prefs) {
    final m = prefs.getInt(minutesKey);
    return m != null && m >= 0 && m < 24 * 60 ? m : defaultReminderMinutes;
  }

  /// False on the web: the UI hides everything about reminders.
  bool get supported => scheduler.supported;

  /// The learner switched reminders on (and the system allowed it).
  bool get enabled => _enabled;

  /// Time of day, in minutes after midnight.
  int get minutesOfDay => _minutes;

  /// The one-time card was answered (or reminders were switched on some
  /// other way). It is never offered again.
  bool get promptSeen => _promptSeen;

  /// The last attempt to turn reminders on was refused by the system. The
  /// UI explains how to allow notifications.
  bool get permissionDenied => _permissionDenied;

  /// Reminders were switched off because the system blocks notifications.
  bool get revokedBySystem => _revokedBySystem;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Plans the reminders again from the current state. Call on app start,
  /// on resume, after earning XP and after any setting changed. Cancels
  /// the old ones first, so nothing is ever scheduled twice. Safe to call
  /// often and never throws.
  Future<void> refresh() => _enqueue(_refresh);

  Future<void> _refresh() async {
    if (!supported || !_enabled) return;
    await scheduler.initialize(l10n());
    if (!await scheduler.hasPermission()) {
      // The learner blocked notifications in the system settings.
      _enabled = false;
      _revokedBySystem = true;
      await prefs.setBool(enabledKey, false);
      await scheduler.cancelAll();
      _changed();
      return;
    }
    // Switched off (or reset) while waiting for the plugin.
    if (!_enabled) return;
    await scheduler.replaceAll(
      planReminders(
        now: clock(),
        minutesOfDay: _minutes,
        goalMetToday: goalMetToday(),
        text: reminderText(l10n()),
      ),
    );
  }

  /// Turns reminders on or off. Turning on asks the system for permission
  /// (so call it only from the learner's own action). If permission is not
  /// given the setting stays off and [permissionDenied] is set. Returns the
  /// resulting [enabled].
  Future<bool> setEnabled(bool on) async {
    await _enqueue(() async {
      _permissionDenied = false;
      _revokedBySystem = false;
      if (!on) {
        _enabled = false;
        await prefs.setBool(enabledKey, false);
        _changed();
        if (supported) await scheduler.cancelAll();
        return;
      }
      if (!supported) return;
      final epoch = _resetEpoch;
      await scheduler.initialize(l10n());
      final granted =
          await scheduler.hasPermission() ||
          await scheduler.requestPermission();
      if (epoch != _resetEpoch) return;
      if (!granted) {
        _enabled = false;
        _permissionDenied = true;
        // They chose; don't offer the card on top of the explanation.
        await _markPromptSeen();
        _changed();
        return;
      }
      _enabled = true;
      await prefs.setBool(enabledKey, true);
      await _markPromptSeen();
      _changed();
      await _refresh();
    });
    return _enabled;
  }

  /// Changes the time of day (minutes after midnight) and reschedules.
  Future<void> setMinutes(int minutes) async {
    final m = minutes.clamp(0, 24 * 60 - 1);
    if (m == _minutes) return;
    _minutes = m;
    await prefs.setInt(minutesKey, m);
    _changed();
    await refresh();
  }

  /// The learner answered the one-time card. It never comes back.
  Future<void> dismissPrompt() async {
    await _markPromptSeen();
    _changed();
  }

  Future<void> _markPromptSeen() async {
    if (_promptSeen) return;
    _promptSeen = true;
    await prefs.setBool(promptSeenKey, true);
  }

  /// Back to a fresh device (sign-out clears the device): reminders off and
  /// cancelled, default time. Whether the one-time card was answered is kept:
  /// it is about this device's offer, and "never again" means never.
  ///
  /// The settings are reset first and do not depend on the notification
  /// plugin; only the cancelling is queued (and not awaited), so a plugin
  /// call that hangs cannot hold anything up.
  Future<void> reset() async {
    _resetEpoch++;
    _enabled = false;
    _minutes = defaultReminderMinutes;
    _permissionDenied = false;
    _revokedBySystem = false;
    _changed();
    await prefs.remove(enabledKey);
    await prefs.remove(minutesKey);
    if (supported) unawaited(_enqueue(scheduler.cancelAll));
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final done = Completer<void>();
    _jobs.add((job, done));
    if (!_draining) unawaited(_drain());
    return done.future;
  }

  /// Runs the queued jobs one after another. The first job starts at once
  /// (nothing is awaited before it), in the caller's zone.
  Future<void> _drain() async {
    _draining = true;
    while (_jobs.isNotEmpty) {
      final (job, done) = _jobs.removeAt(0);
      try {
        await job();
      } catch (e) {
        // A failed notification must never break learning.
        debugPrint('Reminders: $e');
      }
      done.complete();
    }
    _draining = false;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
