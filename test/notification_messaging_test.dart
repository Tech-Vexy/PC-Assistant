import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/messaging/notification_messaging_service.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';

void main() {
  group('Notification & Messaging Subsystem Tests', () {
    late LocalDatabase db;
    late SensitiveAppGuard guard;
    late NotificationMessagingService notifService;
    late ToolDispatcher dispatcher;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('notif_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      guard = SensitiveAppGuard();
      notifService = NotificationMessagingService(
        db: db,
        guard: guard,
      );
      dispatcher = ToolDispatcher(
        db: db,
        guard: guard,
      );
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('LocalDatabase archives, filters, and marks notifications read', () {
      db.archiveNotification(
        key: 'notif_1',
        packageName: 'com.whatsapp',
        appName: 'WhatsApp',
        title: 'Alice',
        content: 'Hey, are you free for lunch?',
        timestamp: 1000,
      );

      db.archiveNotification(
        key: 'notif_2',
        packageName: 'com.slack',
        appName: 'Slack',
        title: 'Bob in #general',
        content: 'PR is ready for review',
        timestamp: 2000,
      );

      db.archiveNotification(
        key: 'notif_3',
        packageName: 'com.google.android.gm',
        appName: 'Gmail',
        title: 'Flight Confirmation',
        content: 'Your flight to Zurich is confirmed',
        timestamp: 3000,
      );

      // Fetch all unread
      final unread = db.getArchivedNotifications(unreadOnly: true);
      expect(unread.length, equals(3));
      // Ordered by timestamp DESC
      expect(unread.first['key'], equals('notif_3'));

      // Filter by app
      final slackOnly = db.getArchivedNotifications(appFilter: 'slack');
      expect(slackOnly.length, equals(1));
      expect(slackOnly.first['app_name'], equals('Slack'));

      // Mark as read
      db.markNotificationRead('notif_1');

      final unreadAfter = db.getArchivedNotifications(unreadOnly: true);
      expect(unreadAfter.length, equals(2));
      expect(unreadAfter.any((n) => n['key'] == 'notif_1'), isFalse);

      // Clear all
      db.clearArchivedNotifications();
      expect(db.getArchivedNotifications().isEmpty, isTrue);
    });

    test('NotificationMessagingService triages into urgent, informational, and low priority', () async {
      // 1. WhatsApp direct message -> urgent_message
      db.archiveNotification(
        key: 'msg_1',
        packageName: 'com.whatsapp',
        appName: 'WhatsApp',
        title: 'Mom',
        content: 'Please call me ASAP!',
        timestamp: 1000,
      );

      // 2. Calendar notification -> important_info
      db.archiveNotification(
        key: 'cal_1',
        packageName: 'com.google.android.calendar',
        appName: 'Calendar',
        title: 'Team Standup',
        content: 'Meeting starts in 10 minutes',
        timestamp: 2000,
      );

      // 3. Generic system/app notification -> low_priority
      db.archiveNotification(
        key: 'sys_1',
        packageName: 'com.example.store',
        appName: 'Store',
        title: 'Summer Sale',
        content: 'Get 20% off all shoes today',
        timestamp: 3000,
      );

      final triage = await notifService.triageNotifications();

      expect(triage.urgentMessages.length, equals(1));
      expect(triage.urgentMessages.first.title, equals('Mom'));
      expect(triage.urgentMessages.first.triageCategory, equals('urgent_message'));

      expect(triage.informational.length, equals(1));
      expect(triage.informational.first.appName, equals('Calendar'));
      expect(triage.informational.first.triageCategory, equals('important_info'));

      expect(triage.lowPriority.length, equals(1));
      expect(triage.lowPriority.first.title, equals('Summer Sale'));

      expect(triage.executiveSummary, contains('1 direct message from Mom'));
      expect(triage.executiveSummary, contains('1 update'));
      expect(triage.executiveSummary, contains('1 low-priority alert'));
    });

    test('SensitiveAppGuard suppresses protected app notifications', () async {
      // Add sensitive banking notification
      db.archiveNotification(
        key: 'bank_1',
        packageName: 'com.chase.sig.android',
        appName: 'Chase Bank',
        title: 'Security Alert',
        content: 'One-time passcode is 987654',
        timestamp: 5000,
      );

      // Add 2FA authenticator notification
      db.archiveNotification(
        key: 'auth_1',
        packageName: 'com.google.android.apps.authenticator2',
        appName: 'Authenticator',
        title: 'Verification Code',
        content: '123 456',
        timestamp: 5001,
      );

      // Add normal app notification
      db.archiveNotification(
        key: 'normal_1',
        packageName: 'com.slack',
        appName: 'Slack',
        title: 'Team Lead',
        content: 'Sprint review tomorrow',
        timestamp: 5002,
      );

      final notifs = await notifService.getNotifications();
      expect(notifs.length, equals(1));
      expect(notifs.first.packageName, equals('com.slack'));
      expect(notifs.any((n) => n.packageName == 'com.chase.sig.android'), isFalse);
      expect(notifs.any((n) => n.packageName == 'com.google.android.apps.authenticator2'), isFalse);
    });

    test('ToolDispatcher dispatches list_notifications, triage_notifications, and read_notifications_summary', () async {
      db.archiveNotification(
        key: 'n_telegram',
        packageName: 'org.telegram.messenger',
        appName: 'Telegram',
        title: 'Sarah',
        content: 'Documents sent over Telegram',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      // 1. list_notifications
      final listRes = await dispatcher.dispatch(
        toolName: 'list_notifications',
        args: {'unread_only': true},
      );
      expect(listRes.containsKey('notifications'), isTrue);
      final items = listRes['notifications'] as List;
      expect(items.isNotEmpty, isTrue);
      expect(items.first['app_name'], equals('Telegram'));

      // 2. triage_notifications
      final triageRes = await dispatcher.dispatch(
        toolName: 'triage_notifications',
        args: {},
      );
      expect(triageRes.containsKey('urgent_messages'), isTrue);
      expect(triageRes.containsKey('informational'), isTrue);
      expect(triageRes.containsKey('executive_summary'), isTrue);

      // 3. read_notifications_summary
      final summaryRes = await dispatcher.dispatch(
        toolName: 'read_notifications_summary',
        args: {},
      );
      expect(summaryRes.containsKey('summary'), isTrue);
      expect(summaryRes['urgent_count'], equals(1));
      expect((summaryRes['summary'] as String).contains('direct message'), isTrue);
    });

    test('Empty notification inbox returns peaceful all caught up message', () async {
      final triage = await notifService.triageNotifications();
      expect(triage.urgentMessages.isEmpty, isTrue);
      expect(triage.informational.isEmpty, isTrue);
      expect(triage.lowPriority.isEmpty, isTrue);
      expect(triage.executiveSummary, equals('You are all caught up! No active notifications or messages.'));
    });
  });
}
