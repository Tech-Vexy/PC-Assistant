import 'dart:io';
import 'package:flutter/services.dart';

/// Android telephony service for SMS and call management.
/// Uses native Android platform channels via MethodChannel for telephony features.
class TelephonyService {
  static TelephonyService? _instance;
  static const MethodChannel _channel =
      MethodChannel('com.veldrine.zen_ai/bridge');
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
      final available = await isTelephonyAvailable();
      _isInitialized = available;
      return _isInitialized;
    } catch (_) {
      return false;
    }
  }

  /// Send SMS message
  Future<Map<String, dynamic>> sendSms({
    required String phoneNumber,
    required String message,
  }) async {
    if (!Platform.isAndroid) {
      return {'status': 'error', 'error': 'SMS not supported on this platform'};
    }

    try {
      final res =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('sendSms', {
        'phoneNumber': phoneNumber,
        'message': message,
      });
      return res != null
          ? Map<String, dynamic>.from(res)
          : {'status': 'sent', 'phone_number': phoneNumber, 'message': message};
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
    if (!Platform.isAndroid) {
      return {
        'status': 'error',
        'error': 'SMS query not supported on this platform'
      };
    }

    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getSmsMessages', {'limit': limit});
      if (res != null) {
        return Map<String, dynamic>.from(res);
      }
      return {'status': 'done', 'count': 0, 'messages': []};
    } catch (e) {
      return {
        'status': 'error',
        'error': e.toString(),
      };
    }
  }

  /// Make a phone call
  Future<Map<String, dynamic>> makeCall(String phoneNumber) async {
    if (!Platform.isAndroid) {
      return {
        'status': 'error',
        'error': 'Calls not supported on this platform'
      };
    }

    try {
      final res =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('makeCall', {
        'phoneNumber': phoneNumber,
      });
      return res != null
          ? Map<String, dynamic>.from(res)
          : {'status': 'calling', 'phone_number': phoneNumber};
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
    if (!Platform.isAndroid) {
      return {
        'status': 'error',
        'error': 'Network info not supported on this platform'
      };
    }

    try {
      final res =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getNetworkInfo');
      if (res != null) {
        return Map<String, dynamic>.from(res);
      }
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
      final res = await _channel.invokeMethod<bool>('isTelephonyAvailable');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
