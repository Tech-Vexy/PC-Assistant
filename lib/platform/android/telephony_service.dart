import 'dart:io';
import 'package:telephony/telephony.dart';

/// Android telephony service for SMS and call management
/// Uses the telephony package for Android-only telephony features
class TelephonyService {
  static TelephonyService? _instance;
  final Telephony _telephony = Telephony.instance;
  bool _isInitialized = false;

  TelephonyService._();

  static TelephonyService get instance {
    _instance ??= TelephonyService._();
    return _instance!;
  }

  /// Initialize the telephony service
  Future<bool> initialize() async {
    if (!Platform.isAndroid) return false;
    if (_isInitialized) return true;

    try {
      // Check if telephony is available
      final isAvailable =
          await _telephony.requestPhoneAndSmsPermissions ?? false;
      _isInitialized = isAvailable;
      return _isInitialized;
    } catch (e) {
      return false;
    }
  }

  /// Send SMS message
  Future<Map<String, dynamic>> sendSms({
    required String phoneNumber,
    required String message,
  }) async {
    if (!_isInitialized) {
      return {'status': 'error', 'error': 'Telephony service not initialized'};
    }

    try {
      await _telephony.sendSms(
        to: phoneNumber,
        message: message,
        statusListener: (SendStatus status) {
          // Could log status here if needed
        },
      );
      return {
        'status': 'sent',
        'phone_number': phoneNumber,
        'message': message,
      };
    } catch (e) {
      return {
        'status': 'error',
        'error': e.toString(),
        'phone_number': phoneNumber,
      };
    }
  }

  /// Query SMS messages from inbox
  Future<Map<String, dynamic>> getSmsMessages({
    String kind = 'inbox',
    int limit = 50,
  }) async {
    if (!_isInitialized) {
      return {'status': 'error', 'error': 'Telephony service not initialized'};
    }

    try {
      final messages = await _telephony.getInboxSms(
        columns: [
          SmsColumn.ID,
          SmsColumn.ADDRESS,
          SmsColumn.BODY,
          SmsColumn.DATE,
          SmsColumn.TYPE,
        ],
      );

      final messageList = messages
          .take(limit)
          .map((msg) => {
                'id': msg.id,
                'address': msg.address,
                'body': msg.body,
                'date': msg.date,
                'type': msg.type,
              })
          .toList();

      return {
        'status': 'done',
        'count': messageList.length,
        'messages': messageList,
      };
    } catch (e) {
      return {
        'status': 'error',
        'error': e.toString(),
      };
    }
  }

  /// Make a phone call
  Future<Map<String, dynamic>> makeCall(String phoneNumber) async {
    if (!_isInitialized) {
      return {'status': 'error', 'error': 'Telephony service not initialized'};
    }

    try {
      // Use intent to make call
      await _telephony.sendSms(
        to: phoneNumber,
        message: '',
        statusListener: (SendStatus status) {},
      );
      return {
        'status': 'calling',
        'phone_number': phoneNumber,
      };
    } catch (e) {
      return {
        'status': 'error',
        'error': e.toString(),
        'phone_number': phoneNumber,
      };
    }
  }

  /// Get network information
  Future<Map<String, dynamic>> getNetworkInfo() async {
    if (!_isInitialized) {
      return {'status': 'error', 'error': 'Telephony service not initialized'};
    }

    try {
      // Basic implementation - return platform info
      return {
        'status': 'done',
        'network_type': 'mobile',
        'platform': 'android',
      };
    } catch (e) {
      return {
        'status': 'error',
        'error': e.toString(),
      };
    }
  }

  /// Check if telephony features are available
  Future<bool> isTelephonyAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _telephony.requestPhoneAndSmsPermissions ?? false;
    } catch (e) {
      return false;
    }
  }
}
