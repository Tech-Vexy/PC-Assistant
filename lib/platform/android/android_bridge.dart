import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Dart interface to the native Android Accessibility & Foreground services
class AndroidBridge {
  static const MethodChannel _channel =
      MethodChannel('com.deviceassistant/bridge');

  static final _activePackageController = StreamController<String>.broadcast();
  static final _shieldAlertController = StreamController<String>.broadcast();
  static final _trayActionController = StreamController<String>.broadcast();
  static final _hotwordController =
      StreamController<Map<String, String?>>.broadcast();

  static bool _handlerInitialized = false;

  final bool _isAndroid;

  AndroidBridge({bool? isAndroid})
      : _isAndroid = isAndroid ?? Platform.isAndroid {
    _initHandler();
  }

  void _initHandler() {
    if (_handlerInitialized || !_isAndroid) return;
    _handlerInitialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onActivePackageChanged') {
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (args != null) {
          final pkg = args['packageName'] as String?;
          final isProtected = args['isProtected'] as bool? ?? false;

          if (pkg != null) {
            _activePackageController.add(pkg);
            if (isProtected) {
              _shieldAlertController.add(pkg);
            }
          }
        }
      } else if (call.method == 'onTrayAction') {
        final args = call.arguments as Map<dynamic, dynamic>?;
        final action = args?['action'] as String?;
        if (action != null) {
          _trayActionController.add(action);
        }
      } else if (call.method == 'onHotwordDetected') {
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (args != null) {
          final hotword = args['hotword'] as String? ?? 'hey assistant';
          final command = args['command'] as String?;
          _hotwordController.add({'hotword': hotword, 'command': command});
        }
      }
    });
  }

  /// Stream of active foreground package names reported by AccessibilityService
  Stream<String> get activePackageStream => _activePackageController.stream;

  /// Stream emitting when a protected package (SIM Toolkit, Banking) enters the foreground
  Stream<String> get shieldAlertStream => _shieldAlertController.stream;

  /// Stream of top bar tray actions (toggle_voice, exit)
  Stream<String> get trayActionStream => _trayActionController.stream;

  /// Stream emitting when an on-device hotword ("Hey Assistant", "OK Google") is spotted
  Stream<Map<String, String?>> get hotwordStream => _hotwordController.stream;

  /// Checks if the AssistantAccessibilityService has been enabled by the user in Android Settings
  Future<bool> isAccessibilityEnabled() async {
    if (!_isAndroid) return false;
    try {
      final bool? enabled =
          await _channel.invokeMethod<bool>('isAccessibilityEnabled');
      return enabled ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system Accessibility Settings page
  Future<void> openAccessibilitySettings() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('openAccessibilitySettings');
  }

  /// Clicks a UI node matching the given visible text or viewId
  Future<bool> clickByText(String text, {String? viewId}) async {
    if (!_isAndroid) return false;
    final bool? result = await _channel.invokeMethod<bool>('clickByText', {
      'text': text,
      'viewId': viewId,
    });
    return result ?? false;
  }

  /// Synchronizes custom blacklisted packages to the native AssistantAccessibilityService
  Future<void> updateProtectedPackages(List<String> packages) async {
    if (!_isAndroid) return;
    try {
      await _channel
          .invokeMethod('updateProtectedPackages', {'packages': packages});
    } catch (_) {}
  }

  /// Injects a touch tap at screen coordinates (x, y)
  Future<bool> injectTap(double x, double y) async {
    if (!_isAndroid) return false;
    final bool? result =
        await _channel.invokeMethod<bool>('injectTap', {'x': x, 'y': y});
    return result ?? false;
  }

  /// Injects a touch swipe gesture from (startX, startY) to (endX, endY)
  Future<bool> injectSwipe(
    double startX,
    double startY,
    double endX,
    double endY, {
    int durationMs = 300,
  }) async {
    if (!_isAndroid) return false;
    final bool? result = await _channel.invokeMethod<bool>('injectSwipe', {
      'startX': startX,
      'startY': startY,
      'endX': endX,
      'endY': endY,
      'durationMs': durationMs,
    });
    return result ?? false;
  }

  /// Performs global system navigation
  /// Actions: 1 = BACK, 2 = HOME, 3 = RECENTS, 4 = NOTIFICATIONS
  Future<bool> performNavigation(int action) async {
    if (!_isAndroid) return false;
    final bool? result = await _channel
        .invokeMethod<bool>('performNavigation', {'action': action});
    return result ?? false;
  }

  /// Dumps non-sensitive semantic view hierarchy of the active window
  Future<List<Map<String, dynamic>>> dumpWindowHierarchy() async {
    if (!_isAndroid) return [];
    try {
      final List<dynamic>? raw =
          await _channel.invokeMethod<List<dynamic>>('dumpWindowHierarchy');
      if (raw == null) return [];
      return raw.map((item) => Map<String, dynamic>.from(item as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Retrieves the currently active foreground package name
  Future<String?> getActivePackageName() async {
    if (!_isAndroid) return null;
    return await _channel.invokeMethod<String?>('getActivePackageName');
  }

  /// Starts the persistent background foreground service with ongoing notification
  Future<void> startForegroundService() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('startForegroundService');
  }

  /// Stops the background foreground service
  Future<void> stopForegroundService() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('stopForegroundService');
  }

  /// Checks if the application is exempt from Android battery optimization / Doze mode
  Future<bool> isBatteryOptimizationIgnored() async {
    if (!_isAndroid) return true;
    try {
      final bool? isIgnored =
          await _channel.invokeMethod<bool>('isBatteryOptimizationIgnored');
      return isIgnored ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Requests exemption from Android battery optimization to ensure always-on background operation
  Future<void> requestIgnoreBatteryOptimization() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimization');
    } catch (_) {}
  }

  /// Minimizes the app to the background without destroying the activity (moveTaskToBack)
  Future<void> minimizeApp() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('minimizeApp');
    } catch (_) {}
  }

  /// Checks if POST_NOTIFICATIONS permission is granted (Android 13+)
  Future<bool> isNotificationPermissionGranted() async {
    if (!_isAndroid) return true;
    try {
      final bool? granted =
          await _channel.invokeMethod<bool>('isNotificationPermissionGranted');
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Prompts the user for POST_NOTIFICATIONS permission on Android 13+
  Future<void> requestNotificationPermission() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestNotificationPermission');
    } catch (_) {}
  }

  /// Checks if RECORD_AUDIO microphone permission is granted
  Future<bool> isMicrophonePermissionGranted() async {
    if (!_isAndroid) return true;
    try {
      final bool? granted =
          await _channel.invokeMethod<bool>('isMicrophonePermissionGranted');
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Prompts the user for microphone runtime permission
  Future<void> requestMicrophonePermission() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestMicrophonePermission');
    } catch (_) {}
  }

  /// Launches an application via native Android Intent without spawning child OS processes
  Future<bool> launchApp(String packageName) async {
    if (!_isAndroid) return false;
    try {
      final bool? success = await _channel
          .invokeMethod<bool>('launchApp', {'packageName': packageName});
      return success ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Updates the top bar tray notification and Quick Settings tile status
  Future<void> updateTrayStatus(
      {required bool isActive, String? statusText}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('updateTrayStatus', {
        'isActive': isActive,
        'statusText': statusText,
      });
    } catch (_) {}
  }

  /// Streams raw 24kHz PCM16 audio bytes to native AudioTrack in AssistantForegroundService
  Future<void> writeAudioChunk(Uint8List bytes) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('writeAudioChunk', {'bytes': bytes});
    } catch (_) {}
  }

  /// Flushes native AudioTrack playback immediately upon interruption/barge-in
  Future<void> flushAudio() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('flushAudio');
    } catch (_) {}
  }

  /// Captures a JPEG screenshot via AccessibilityService (Android 11+)
  /// Returns null if the foreground application is protected by SensitiveAppGuard.
  Future<Uint8List?> takeScreenCapture() async {
    if (!_isAndroid) return null;
    try {
      final dynamic raw =
          await _channel.invokeMethod<dynamic>('takeScreenCapture');
      if (raw is Uint8List) {
        return raw;
      } else if (raw is List) {
        return Uint8List.fromList(raw.cast<int>());
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Injects text into an editable input field
  Future<bool> inputText(String text, {String? viewId}) async {
    if (!_isAndroid) return false;
    try {
      final bool? success = await _channel.invokeMethod<bool>('inputText', {
        'text': text,
        'viewId': viewId,
      });
      return success ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Performs a scroll action (forward = down, backward = up)
  Future<bool> scroll({bool forward = true}) async {
    if (!_isAndroid) return false;
    try {
      final bool? success =
          await _channel.invokeMethod<bool>('scroll', {'forward': forward});
      return success ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts on-device continuous hotword listening ("Hey Assistant", "OK Google")
  Future<bool> startHotwordListening({List<String>? hotwords}) async {
    if (!_isAndroid) return false;
    try {
      final bool? result =
          await _channel.invokeMethod<bool>('startHotwordListening', {
        if (hotwords != null) 'hotwords': hotwords,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Stops on-device hotword listening
  Future<void> stopHotwordListening() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopHotwordListening');
    } catch (_) {}
  }

  /// Checks if continuous hotword listening is active
  Future<bool> isHotwordListening() async {
    if (!_isAndroid) return false;
    try {
      final bool? result =
          await _channel.invokeMethod<bool>('isHotwordListening');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
