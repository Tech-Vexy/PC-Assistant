// ignore_for_file: deprecated_member_use, deprecated_member_use_from_same_package
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';
import 'desktop_automation_service.dart';

// Re-export MouseButton for convenience
export 'desktop_automation_service.dart' show MouseButton;

/// Desktop platform integration managing system tray, global hotkeys,
/// and background window behavior on Windows and Linux.
class DesktopDriver with TrayListener, WindowListener {
  final VoidCallback onToggleVoice;

  HotKey? _summonHotKey;
  bool _isInitialized = false;
  DesktopAutomationService? _automationService;

  DesktopDriver({required this.onToggleVoice});

  /// Initializes system tray, hotkeys, and window listeners
  Future<void> initialize() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    if (_isInitialized) return;

    // Initialize desktop automation service
    _automationService = DesktopAutomationService.instance;
    await _automationService!.initialize();

    windowManager.addListener(this);
    trayManager.addListener(this);

    // Initialize global hotkey (Control + Alt + Space)
    await hotKeyManager.unregisterAll();
    _summonHotKey = HotKey(
      key: PhysicalKeyboardKey.space,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );

    await hotKeyManager.register(
      _summonHotKey!,
      keyDownHandler: (hotKey) async {
        await _toggleWindowVisibility();
        onToggleVoice();
      },
    );

    // Initialize System Tray
    await _initSystemTray();
    _isInitialized = true;
  }

  Future<void> _initSystemTray() async {
    try {
      // Set tooltip
      await trayManager.setToolTip('Device Assistant');

      // Create context menu
      final menu = Menu(
        items: [
          MenuItem(
            key: 'show_window',
            label: 'Show Assistant',
          ),
          MenuItem(
            key: 'toggle_voice',
            label: 'Toggle Gemini Live',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit_app',
            label: 'Exit',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (_) {
      // Tray setup fallback
    }
  }

  Future<void> _toggleWindowVisibility() async {
    final isVisible = await windowManager.isVisible();
    if (isVisible) {
      final isFocused = await windowManager.isFocused();
      if (isFocused) {
        await windowManager.hide();
      } else {
        await windowManager.focus();
      }
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show_window':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'toggle_voice':
        // Activate voice assistant in background without forcing main window to foreground
        onToggleVoice();
        break;
      case 'exit_app':
        await dispose();
        exit(0);
    }
  }

  @override
  void onTrayIconMouseDown() async {
    await _toggleWindowVisibility();
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onWindowClose() async {
    // Minimize to tray instead of quitting
    await windowManager.hide();
  }

  Future<void> dispose() async {
    if (!_isInitialized) return;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await hotKeyManager.unregisterAll();
    await trayManager.destroy();
    _isInitialized = false;
  }

  // Device Operation Methods

  /// Get the desktop automation service instance
  DesktopAutomationService? get automationService => _automationService;

  /// Move mouse to absolute screen coordinates
  Future<bool> moveMouse(double x, double y) async {
    if (_automationService == null) return false;
    return await _automationService!.moveMouse(x, y);
  }

  /// Get current mouse position
  Future<Map<String, int>?> getMousePosition() async {
    if (_automationService == null) return null;
    return await _automationService!.getMousePosition();
  }

  /// Click mouse button
  Future<bool> clickMouse({MouseButton button = MouseButton.left}) async {
    if (_automationService == null) return false;
    return await _automationService!.clickMouse(button: button);
  }

  /// Double click mouse button
  Future<bool> doubleClick({MouseButton button = MouseButton.left}) async {
    if (_automationService == null) return false;
    return await _automationService!.doubleClick(button: button);
  }

  /// Press and hold mouse button
  Future<bool> pressMouse({MouseButton button = MouseButton.left}) async {
    if (_automationService == null) return false;
    return await _automationService!.pressMouse(button: button);
  }

  /// Release mouse button
  Future<bool> releaseMouse({MouseButton button = MouseButton.left}) async {
    if (_automationService == null) return false;
    return await _automationService!.releaseMouse(button: button);
  }

  /// Scroll mouse wheel
  Future<bool> scrollMouse({required int deltaX, required int deltaY}) async {
    if (_automationService == null) return false;
    return await _automationService!.scrollMouse(deltaX: deltaX, deltaY: deltaY);
  }

  /// Drag mouse from start to end coordinates
  Future<bool> dragMouse(
      {required double startX,
      required double startY,
      required double endX,
      required double endY}) async {
    if (_automationService == null) return false;
    return await _automationService!.dragMouse(
        startX: startX, startY: startY, endX: endX, endY: endY);
  }

  /// Type a string of text
  Future<bool> typeText(String text) async {
    if (_automationService == null) return false;
    return await _automationService!.typeText(text);
  }

  /// Press a single key
  Future<bool> pressKey(String key) async {
    if (_automationService == null) return false;
    return await _automationService!.pressKey(key);
  }

  /// Press key combination (e.g., "ctrl+c", "cmd+v")
  Future<bool> hotkey(String keys) async {
    if (_automationService == null) return false;
    return await _automationService!.hotkey(keys);
  }

  /// Press and hold a key
  Future<bool> pressKeyDown(String key) async {
    if (_automationService == null) return false;
    return await _automationService!.pressKeyDown(key);
  }

  /// Release a held key
  Future<bool> releaseKey(String key) async {
    if (_automationService == null) return false;
    return await _automationService!.releaseKey(key);
  }

  /// Get screen size
  Future<Map<String, int>?> getScreenSize() async {
    if (_automationService == null) return null;
    return await _automationService!.getScreenSize();
  }

  /// Capture screenshot
  Future<Uint8List?> captureScreen() async {
    if (_automationService == null) return null;
    return await _automationService!.captureScreen();
  }

  /// Launch an application by path or command
  Future<bool> launchApp(String pathOrCommand) async {
    if (_automationService == null) return false;
    return await _automationService!.launchApp(pathOrCommand);
  }

  /// Get list of running applications
  Future<List<Map<String, String>>> getRunningApps() async {
    if (_automationService == null) return [];
    return await _automationService!.getRunningApps();
  }

  /// Close application by name or PID
  Future<bool> closeApp(String identifier) async {
    if (_automationService == null) return false;
    return await _automationService!.closeApp(identifier);
  }
}
