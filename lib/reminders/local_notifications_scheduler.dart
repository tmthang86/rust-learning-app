import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../l10n/app_localizations.dart';
import 'reminder_scheduler.dart';

/// Study reminders through flutter_local_notifications, on Android and iOS.
///
/// - One-shot notifications only, at absolute moments: the local date and
///   time is converted to a UTC [tz.TZDateTime], so no time zone database
///   or "current zone" lookup is needed.
/// - Android uses inexact scheduling (a reminder doesn't need to arrive at
///   the exact second), so no exact-alarm permission is declared.
/// - Nothing asks for permission until [requestPermission]. On iOS the
///   prompt is deferred by turning every request flag off at initialization.
class LocalNotificationsScheduler implements ReminderScheduler {
  LocalNotificationsScheduler([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;
  AppLocalizations? _l10n;

  static const _channelId = 'study_reminders';

  /// A white, transparent-background drawable (Android draws the small
  /// notification icon as a silhouette; a coloured launcher icon would show
  /// as a plain blob). Kept from resource shrinking by
  /// android/app/src/main/res/raw/keep.xml.
  static const _androidIcon = 'ic_stat_reminder';

  static bool get _platformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  bool get supported => _platformSupported;

  /// The Android details for a notification. The channel name and
  /// description are shown in the system settings; with `update` the plugin
  /// renames an existing channel, so they follow a language change (the
  /// default, `createIfNotExists`, would keep the first language forever).
  @visibleForTesting
  static AndroidNotificationDetails androidDetails(AppLocalizations? l10n) =>
      AndroidNotificationDetails(
        _channelId,
        l10n?.reminderChannelName ?? 'Study reminders',
        channelDescription: l10n?.reminderChannelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        channelAction: AndroidNotificationChannelAction.update,
      );

  @override
  Future<void> initialize(AppLocalizations l10n) async {
    _l10n = l10n;
    if (!supported || _ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_androidIcon),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _ready = true;
  }

  @override
  Future<bool> hasPermission() async {
    if (!supported) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        return await android?.areNotificationsEnabled() ?? false;
      case TargetPlatform.iOS:
        final ios = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final options = await ios?.checkPermissions();
        return options?.isEnabled ?? false;
      default:
        return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!supported) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        // Below Android 13 there is no prompt and this returns true.
        return await android?.requestNotificationsPermission() ?? false;
      case TargetPlatform.iOS:
        final ios = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        return await ios?.requestPermissions(alert: true, sound: true) ?? false;
      default:
        return false;
    }
  }

  @override
  Future<void> replaceAll(List<ScheduledReminder> reminders) async {
    if (!supported) return;
    await _plugin.cancelAll();
    final details = NotificationDetails(
      android: androidDetails(_l10n),
      iOS: const DarwinNotificationDetails(presentBadge: false),
    );
    for (final r in reminders) {
      try {
        await _plugin.zonedSchedule(
          id: r.id,
          title: r.text.title,
          body: r.text.body,
          // The same moment as the local time, expressed in UTC.
          scheduledDate: tz.TZDateTime.from(r.when, tz.UTC),
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e) {
        // One refused reminder (e.g. its time just passed) must not stop
        // the others.
        debugPrint('Scheduling reminder ${r.id} failed: $e');
      }
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!supported) return;
    await _plugin.cancelAll();
  }
}
