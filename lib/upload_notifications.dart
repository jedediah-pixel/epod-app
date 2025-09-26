import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

class UploadNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'upload_status';
  static const _channelName = 'Upload status';
  static const _channelDesc = 'Shows ongoing POD uploads';
  static const _notifId = 1001;
  static const _retryActionId = 'retry_now';

  static Future<void> init() async {
    // Android init (no-op on iOS for our use case)
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    
    // Add this iOS init just above initSettings
    const DarwinInitializationSettings darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Replace your current initSettings with this:
    const InitializationSettings initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (resp) async {
        if (resp.actionId == _retryActionId || resp.notificationResponseType == NotificationResponseType.selectedNotification) {
          // Re-kick WorkManager immediately
          if (Platform.isAndroid) {
            await Workmanager().registerOneOffTask(
              'drain-upload-queue',
              'drain_uploads',
              constraints: Constraints(
                networkType: NetworkType.connected,
                requiresBatteryNotLow: true,
                requiresStorageNotLow: true,
              ),
              existingWorkPolicy: ExistingWorkPolicy.keep,
            );
          }
        }
      },
    );

    // Create the Android channel
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.low, // silent, no heads-up
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ));

      // Android 13+ permission (best effort; safe if already granted)
      await androidImpl.requestNotificationsPermission();
    }
  }

  /// Show or hide the sticky "Uploading…" notification based on queue status.
  static Future<void> update({required bool hasJobs, int jobCount = 0}) async {
    if (!Platform.isAndroid) return;

    if (hasJobs) {
      final details = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        category: AndroidNotificationCategory.service,
        onlyAlertOnce: true,
        ongoing: true,
        autoCancel: false,
        // Add a "Retry now" action button
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            _retryActionId,
            'Retry now',
            showsUserInterface: false,
          ),
        ],
        styleInformation: const DefaultStyleInformation(true, false),
      );

      await _plugin.show(
        _notifId,
        'Uploading POD…',
        jobCount > 0 ? '$jobCount item(s) in queue' : null,
        NotificationDetails(android: details),
      );
    } else {
      await _plugin.cancel(_notifId);
    }
  }
}
