// ignore_for_file: deprecated_member_use, deprecated_member_use_from_same_package
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop platform integration managing system tray, global hotkeys,
/// and background window behavior on Windows and Linux.
class DesktopDriver with TrayListener, WindowListener {
  final VoidCallback onToggleVoice;

  HotKey? _summonHotKey;
  bool _isInitialized = false;

  DesktopDriver({required this.onToggleVoice});

  /// Initializes system tray, hotkeys, and window listeners
  Future<void> initialize() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    if (_isInitialized) return;

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
        await windowManager.show();
        await windowManager.focus();
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
}
