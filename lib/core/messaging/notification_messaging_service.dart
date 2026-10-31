import 'dart:io';
import 'package:telephony/telephony.dart';
import '../../platform/android/android_bridge.dart';
import '../database/local_database.dart';
import '../security/sensitive_app_guard.dart';

/// Structured notification item with classification metadata.
class NotificationItem {
  final String key;
  final String packageName;
  final String appName;
  final String title;
  final String content;
  final DateTime timestamp;
  final bool canReply;
  final String triageCategory; // 'urgent_message', 'important_info', 'low_priority'

  const NotificationItem({
    required this.key,
    required this.packageName,
    required this.appName,
    required this.title,
    required this.content,
    required this.timestamp,
    required this.canReply,
    required this.triageCategory,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'package_name': packageName,
        'app_name': appName,
        'title': title,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'can_reply': canReply,
        'triage_category': triageCategory,
      };
}

/// Triaged executive summary of device notifications.
class NotificationTriage {
  final List<NotificationItem> urgentMessages;
  final List<NotificationItem> informational;
  final List<NotificationItem> lowPriority;
  final String executiveSummary;

  const NotificationTriage({
    required this.urgentMessages,
    required this.informational,
    required this.lowPriority,
    required this.executiveSummary,
  });

  Map<String, dynamic> toJson() => {
        'urgent_messages': urgentMessages.map((m) => m.toJson()).toList(),
        'informational': informational.map((m) => m.toJson()).toList(),
        'low_priority': lowPriority.map((m) => m.toJson()).toList(),
        'executive_summary': executiveSummary,
      };
}

/// Core service for reading, triaging, and replying to device notifications & messages.
class NotificationMessagingService {
  final AndroidBridge? androidBridge;
  final LocalDatabase db;
  final SensitiveAppGuard guard;

  static const Map<String, String> _knownApps = {
    'com.whatsapp': 'WhatsApp',
    'org.thoughtcrime.securesms': 'Signal',
    'org.telegram.messenger': 'Telegram',
    'com.google.android.apps.messaging': 'Google Messages',
    'com.samsung.android.messaging': 'Samsung Messages',
    'com.slack': 'Slack',
    'com.google.android.gm': 'Gmail',
    'com.microsoft.office.outlook': 'Outlook',
    'com.discord': 'Discord',
    'com.instagram.android': 'Instagram',
    'com.twitter.android': 'X (Twitter)',
    'com.google.android.calendar': 'Calendar',
    'com.ubercab': 'Uber',
  };

  static const Set<String> _directMessagingPackages = {
    'com.whatsapp',
    'org.thoughtcrime.securesms',
    'org.telegram.messenger',
    'com.google.android.apps.messaging',
    'com.samsung.android.messaging',
    'com.slack',
    'com.discord',
  };

  const NotificationMessagingService({
    this.androidBridge,
    required this.db,
    required this.guard,
  });

  /// Fetches and sanitizes active device notifications.
  Future<List<NotificationItem>> getNotifications({
    bool unreadOnly = false,
    String? appFilter,
    int limit = 25,
  }) async {
    final items = <NotificationItem>[];

    // If on Android and listener is active, grab live status bar notifications
    if (Platform.isAndroid && androidBridge != null) {
      final rawList = await androidBridge!.getActiveNotifications();
      for (final raw in rawList) {
        final pkg = raw['packageName']?.toString() ?? '';

        // Privacy Shield: Skip sensitive packages (banking, authenticators)
        if (guard.isPackageSensitive(pkg)) continue;

        final title = raw['title']?.toString() ?? '';
        final text = raw['text']?.toString() ?? '';
        final key = raw['key']?.toString() ?? '';
        final ts = raw['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        final canReply = raw['canReply'] == true;

        if (title.isEmpty && text.isEmpty) continue;

        // Archive into local database for search & offline recall
        final appName = _knownApps[pkg] ?? _formatPackageName(pkg);
        db.archiveNotification(
          key: key,
          packageName: pkg,
          appName: appName,
          title: title,
          content: text,
          timestamp: ts,
        );

        final category = _classifyCategory(pkg, title, text);

        items.add(NotificationItem(
          key: key,
          packageName: pkg,
          appName: appName,
          title: title,
          content: text,
          timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
          canReply: canReply,
          triageCategory: category,
        ));
      }
    }

    // Also blend with recent archived notifications
    final archived = db.getArchivedNotifications(
      limit: limit,
      unreadOnly: unreadOnly,
      appFilter: appFilter,
    );

    for (final row in archived) {
      final key = row['key']?.toString() ?? '';
      if (items.any((i) => i.key == key)) continue; // Already present from live

      final pkg = row['package_name']?.toString() ?? '';
      if (guard.isPackageSensitive(pkg)) continue;

      final title = row['title']?.toString() ?? '';
      final content = row['content']?.toString() ?? '';
      final ts = row['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

      items.add(NotificationItem(
        key: key,
        packageName: pkg,
        appName: row['app_name']?.toString() ?? _formatPackageName(pkg),
        title: title,
        content: content,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
        canReply: false,
        triageCategory: _classifyCategory(pkg, title, content),
      ));
    }

    // Filter by app if requested
    var filtered = items;
    if (appFilter != null && appFilter.trim().isNotEmpty) {
      final f = appFilter.toLowerCase().trim();
      filtered = filtered
          .where((i) =>
              i.appName.toLowerCase().contains(f) ||
              i.packageName.toLowerCase().contains(f))
          .toList();
    }

    filtered.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return filtered.take(limit).toList();
  }

  /// Categorizes active notifications into urgent, informational, and low-priority triage.
  Future<NotificationTriage> triageNotifications({int limit = 30}) async {
    final all = await getNotifications(limit: limit);

    final urgent = <NotificationItem>[];
    final informational = <NotificationItem>[];
    final lowPriority = <NotificationItem>[];

    for (final item in all) {
      switch (item.triageCategory) {
        case 'urgent_message':
          urgent.add(item);
          break;
        case 'important_info':
          informational.add(item);
          break;
        default:
          lowPriority.add(item);
          break;
      }
    }

    final summary = _generateSummary(urgent, informational, lowPriority);

    return NotificationTriage(
      urgentMessages: urgent,
      informational: informational,
      lowPriority: lowPriority,
      executiveSummary: summary,
    );
  }

  /// Sends a direct inline reply to a notification without opening the app.
  Future<bool> replyToNotification(String key, String replyText) async {
    if (!Platform.isAndroid || androidBridge == null) return false;
    final success = await androidBridge!.replyToNotification(key, replyText);
    if (success) {
      db.markNotificationRead(key);
    }
    return success;
  }

  /// Sends an SMS message to a phone number.
  Future<Map<String, dynamic>> sendSms({
    required String phoneNumber,
    required String message,
  }) async {
    if (!Platform.isAndroid) {
      return {'status': 'error', 'error': 'SMS sending is only supported on Android devices.'};
    }

    try {
      final telephony = Telephony.instance;
      final perm = await telephony.isSmsCapable;
      if (perm != true) {
        return {'status': 'error', 'error': 'Device is not capable of sending SMS.'};
      }

      await telephony.sendSms(
        to: phoneNumber,
        message: message,
      );

      return {
        'status': 'sent',
        'recipient': phoneNumber,
        'message': message,
      };
    } catch (e) {
      return {'status': 'error', 'error': 'Failed to send SMS: $e'};
    }
  }

  String _classifyCategory(String packageName, String title, String content) {
    if (_directMessagingPackages.contains(packageName)) {
      return 'urgent_message';
    }

    final lower = '$title $content'.toLowerCase();

    // Urgent cues
    if (lower.contains('urgent') ||
        lower.contains('emergency') ||
        lower.contains('call me') ||
        lower.contains('asap')) {
      return 'urgent_message';
    }

    // Informational cues
    if (packageName.contains('calendar') ||
        packageName.contains('gmail') ||
        packageName.contains('outlook') ||
        packageName.contains('uber') ||
        lower.contains('meeting') ||
        lower.contains('flight') ||
        lower.contains('delivered')) {
      return 'important_info';
    }

    return 'low_priority';
  }

  String _generateSummary(
    List<NotificationItem> urgent,
    List<NotificationItem> informational,
    List<NotificationItem> lowPriority,
  ) {
    if (urgent.isEmpty && informational.isEmpty && lowPriority.isEmpty) {
      return 'You are all caught up! No active notifications or messages.';
    }

    final parts = <String>[];
    if (urgent.isNotEmpty) {
      final count = urgent.length;
      final senders = urgent.map((m) => m.title).toSet().take(3).join(', ');
      parts.add('$count direct message${count > 1 ? 's' : ''} from $senders');
    }

    if (informational.isNotEmpty) {
      final count = informational.length;
      parts.add('$count update${count > 1 ? 's' : ''} (including ${informational.first.appName})');
    }

    if (lowPriority.isNotEmpty) {
      parts.add('${lowPriority.length} low-priority alert${lowPriority.length > 1 ? 's' : ''}');
    }

    return 'Summary: ${parts.join('; ')}.';
  }

  String _formatPackageName(String pkg) {
    final segments = pkg.split('.');
    if (segments.length > 1) {
      return segments.last.toUpperCase();
    }
    return pkg;
  }
}
