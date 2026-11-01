import 'dart:io';
import 'dart:typed_data';
import 'android/android_bridge.dart';
import 'desktop/desktop_driver.dart';

/// Unified device operations interface providing cross-platform consistency
/// for mouse, keyboard, app control, and telephony operations.
class DeviceOperations {
  final AndroidBridge? androidBridge;
  final DesktopDriver? desktopDriver;

  DeviceOperations({
    this.androidBridge,
    this.desktopDriver,
  });

  // --- PLATFORM DETECTION ---

  bool get isAndroid => Platform.isAndroid;
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // --- MOUSE / TOUCH OPERATIONS ---

  /// Move mouse cursor (desktop) or inject touch (Android)
  Future<Map<String, dynamic>> movePointer({
    required double x,
    required double y,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final success = await desktopDriver!.moveMouse(x, y);
      return {
        'status': success ? 'done' : 'error',
        'x': x,
        'y': y,
        'platform': 'desktop',
        'success': success,
      };
    } else if (isAndroid && androidBridge != null) {
      final success = await androidBridge!.injectTap(x, y);
      return {
        'status': success ? 'done' : 'error',
        'x': x,
        'y': y,
        'platform': 'android',
        'success': success,
      };
    }
    return {'error': 'Pointer operations not available on this platform'};
  }

  /// Click mouse button (desktop) or tap element (Android)
  Future<Map<String, dynamic>> click({
    String? text,
    String? viewId,
    double? x,
    double? y,
  }) async {
    if (isDesktop && desktopDriver != null) {
      if (x != null && y != null) {
        final success = await desktopDriver!.clickMouse();
        return {
          'status': success ? 'done' : 'error',
          'x': x,
          'y': y,
          'platform': 'desktop',
          'success': success,
        };
      }
    } else if (isAndroid && androidBridge != null) {
      if (text != null || viewId != null) {
        final success =
            await androidBridge!.clickByText(text ?? '', viewId: viewId);
        return {
          'status': success ? 'done' : 'error',
          'text': text,
          'viewId': viewId,
          'platform': 'android',
          'success': success,
        };
      } else if (x != null && y != null) {
        final success = await androidBridge!.injectTap(x, y);
        return {
          'status': success ? 'done' : 'error',
          'x': x,
          'y': y,
          'platform': 'android',
          'success': success,
        };
      }
    }
    return {
      'error': 'Click operation requires appropriate parameters for platform'
    };
  }

  /// Scroll operation
  Future<Map<String, dynamic>> scroll({
    bool forward = true,
    int deltaX = 0,
    int deltaY = 0,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final success =
          await desktopDriver!.scrollMouse(deltaX: deltaX, deltaY: deltaY);
      return {
        'status': success ? 'done' : 'error',
        'deltaX': deltaX,
        'deltaY': deltaY,
        'platform': 'desktop',
        'success': success,
      };
    } else if (isAndroid && androidBridge != null) {
      final success = await androidBridge!.scroll(forward: forward);
      return {
        'status': success ? 'done' : 'error',
        'forward': forward,
        'platform': 'android',
        'success': success,
      };
    }
    return {'error': 'Scroll not available on this platform'};
  }

  // --- KEYBOARD / TEXT INPUT ---

  /// Type text into input field
  Future<Map<String, dynamic>> typeText({
    required String text,
    String? viewId,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final success = await desktopDriver!.typeText(text);
      return {
        'status': success ? 'done' : 'error',
        'text': text,
        'platform': 'desktop',
        'success': success,
      };
    } else if (isAndroid && androidBridge != null) {
      final success = await androidBridge!.inputText(text, viewId: viewId);
      return {
        'status': success ? 'done' : 'error',
        'text': text,
        'viewId': viewId,
        'platform': 'android',
        'success': success,
      };
    }
    return {'error': 'Text input not available on this platform'};
  }

  /// Press a key (desktop only)
  Future<Map<String, dynamic>> pressKey({
    required String key,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final success = await desktopDriver!.pressKey(key);
      return {
        'status': success ? 'done' : 'error',
        'key': key,
        'platform': 'desktop',
        'success': success,
      };
    }
    return {'error': 'Key press not available on this platform'};
  }

  /// Execute hotkey combination (desktop only)
  Future<Map<String, dynamic>> hotkey({
    required String keys,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final success = await desktopDriver!.hotkey(keys);
      return {
        'status': success ? 'done' : 'error',
        'keys': keys,
        'platform': 'desktop',
        'success': success,
      };
    }
    return {'error': 'Hotkey not available on this platform'};
  }

  // --- APPLICATION CONTROL ---

  /// Launch an application
  Future<Map<String, dynamic>> launchApp({
    required String identifier,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final success = await desktopDriver!.launchApp(identifier);
      return {
        'status': success ? 'launched' : 'error',
        'identifier': identifier,
        'platform': 'desktop',
        'success': success,
      };
    } else if (isAndroid && androidBridge != null) {
      final success = await androidBridge!.launchApp(identifier);
      return {
        'status': success ? 'launched' : 'error',
        'identifier': identifier,
        'platform': 'android',
        'success': success,
      };
    }
    return {'error': 'App launch not available on this platform'};
  }

  /// List installed/running applications
  Future<Map<String, dynamic>> listApps({
    String? filter,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final apps = await desktopDriver!.getRunningApps();
      final filtered = filter == null
          ? apps
          : apps
              .where((app) =>
                  app['name']
                      ?.toString()
                      .toLowerCase()
                      .contains(filter.toLowerCase()) ??
                  false)
              .toList();
      return {
        'status': 'done',
        'count': filtered.length,
        'apps': filtered,
        'platform': 'desktop',
      };
    } else if (isAndroid && androidBridge != null) {
      final apps = await androidBridge!.getInstalledApps();
      final filtered = filter == null
          ? apps
          : apps
              .where((app) =>
                  (app['appName']
                          ?.toString()
                          .toLowerCase()
                          .contains(filter.toLowerCase()) ??
                      false) ||
                  (app['packageName']
                          ?.toString()
                          .toLowerCase()
                          .contains(filter.toLowerCase()) ??
                      false))
              .toList();
      return {
        'status': 'done',
        'count': filtered.length,
        'apps': filtered,
        'platform': 'android',
      };
    }
    return {'error': 'App listing not available on this platform'};
  }

  /// Close an application
  Future<Map<String, dynamic>> closeApp({
    required String identifier,
  }) async {
    if (isDesktop && desktopDriver != null) {
      final success = await desktopDriver!.closeApp(identifier);
      return {
        'status': success ? 'closed' : 'error',
        'identifier': identifier,
        'platform': 'desktop',
        'success': success,
      };
    }
    return {'error': 'App close not available on this platform'};
  }

  // --- SCREEN OPERATIONS ---

  /// Capture screenshot
  Future<Uint8List?> captureScreen() async {
    if (isDesktop && desktopDriver != null) {
      return await desktopDriver!.captureScreen();
    } else if (isAndroid && androidBridge != null) {
      return await androidBridge!.takeScreenCapture();
    }
    return null;
  }

  /// Get screen size
  Future<Map<String, int>?> getScreenSize() async {
    if (isDesktop && desktopDriver != null) {
      return await desktopDriver!.getScreenSize();
    }
    return null;
  }

  /// Inspect screen hierarchy (Android only)
  Future<List<Map<String, dynamic>>> inspectScreen() async {
    if (isAndroid && androidBridge != null) {
      return await androidBridge!.dumpWindowHierarchy();
    }
    return [];
  }

  // --- NAVIGATION ---

  /// Perform system navigation (Android only)
  Future<Map<String, dynamic>> navigate({
    required int action,
  }) async {
    if (isAndroid && androidBridge != null) {
      final success = await androidBridge!.performNavigation(action);
      return {
        'status': success ? 'done' : 'error',
        'action': action,
        'platform': 'android',
        'success': success,
      };
    }
    return {'error': 'Navigation not available on this platform'};
  }

  // --- TELEPHONY (Android only) ---

  /// Send SMS message
  Future<Map<String, dynamic>> sendSms({
    required String phoneNumber,
    required String message,
  }) async {
    if (isAndroid && androidBridge != null) {
      return await androidBridge!.sendSms(
        phoneNumber: phoneNumber,
        message: message,
      );
    }
    return {'error': 'SMS not available on this platform'};
  }

  /// Get SMS messages
  Future<Map<String, dynamic>> getSmsMessages({
    String kind = 'inbox',
    int limit = 50,
  }) async {
    if (isAndroid && androidBridge != null) {
      return await androidBridge!.getSmsMessages(kind: kind, limit: limit);
    }
    return {'error': 'SMS not available on this platform'};
  }

  /// Make phone call
  Future<Map<String, dynamic>> makeCall({
    required String phoneNumber,
  }) async {
    if (isAndroid && androidBridge != null) {
      return await androidBridge!.makeCall(phoneNumber);
    }
    return {'error': 'Phone calls not available on this platform'};
  }

  /// Get network information
  Future<Map<String, dynamic>> getNetworkInfo() async {
    if (isAndroid && androidBridge != null) {
      return await androidBridge!.getNetworkInfo();
    }
    return {'error': 'Network info not available on this platform'};
  }

  // --- CAPABILITY QUERIES ---

  /// Get available capabilities for current platform
  Map<String, bool> getCapabilities() {
    return {
      'mouse': isDesktop,
      'keyboard': isDesktop,
      'touch': isAndroid,
      'app_launch': isDesktop || isAndroid,
      'app_list': isDesktop || isAndroid,
      'app_close': isDesktop,
      'screenshot': isDesktop || isAndroid,
      'screen_inspect': isAndroid,
      'navigation': isAndroid,
      'sms': isAndroid,
      'calls': isAndroid,
      'network_info': isAndroid,
    };
  }
}
