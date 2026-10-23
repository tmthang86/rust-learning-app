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
  /// [createChannel] is a seam for tests; the default asks the Android
  /// implementation of the plugin (nothing on iOS).
  LocalNotificationsScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    Future<void> Function(AndroidNotificationChannel channel)? createChannel,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin() {
    _createChannel = createChannel ?? _createAndroidChannel;
  }

  final FlutterLocalNotificationsPlugin _plugin;
  late final Future<void> Function(AndroidNotificationChannel channel)
  _createChannel;
  bool _ready = false;
  AppLocalizations? _l10n;

  static const _channelId = 'study_reminders';
  static const _importance = Importance.defaultImportance;

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

  /// The Android channel in the app's language. Its name and description
  /// are what Android's notification settings show.
  @visibleForTesting
  static AndroidNotificationChannel androidChannel(AppLocalizations l10n) =>
      AndroidNotificationChannel(
        _channelId,
        l10n.reminderChannelName,
        description: l10n.reminderChannelDescription,
        importance: _importance,
      );

  @override
  Future<void> initialize(AppLocalizations l10n) async {
    _l10n = l10n;
    if (!supported) return;
    if (!_ready) {
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
    // Before every schedule, so the channel name and description in
    // Android's settings follow the app language. Android's
    // NotificationManager.createNotificationChannel creates the channel
    // when it is missing and updates the name and description of an
    // existing one, leaving the user's own settings for it alone.
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _createChannel(androidChannel(l10n));
      } catch (e) {
        debugPrint('Updating the reminder channel failed: $e');
      }
    }
  }

  Future<void> _createAndroidChannel(AndroidNotificationChannel channel) async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
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
      // The channel itself is created in initialize(); these only name it.
      android: AndroidNotificationDetails(
        _channelId,
        _l10n?.reminderChannelName ?? 'Study reminders',
        channelDescription: _l10n?.reminderChannelDescription,
        importance: _importance,
        priority: Priority.defaultPriority,
      ),
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
