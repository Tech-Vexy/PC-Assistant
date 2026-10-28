import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';

void main() {
  group('Screen Capture Streaming Tests', () {
    late LocalDatabase db;
    late SensitiveAppGuard guard;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('screen_stream_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      guard = SensitiveAppGuard();
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Screen capture is halted when sensitive app is in foreground', () async {
      Uint8List? streamedFrame;

      final dispatcher = ToolDispatcher(
        db: db,
        guard: guard,
        activePackageName: 'com.android.stk', // Protected SIM Toolkit package
        onImageCaptured: (bytes) {
          streamedFrame = bytes;
        },
      );

      final result = await dispatcher.dispatch(
        toolName: 'capture_screen',
        args: {},
      );

      expect(result['status'], equals('blocked'));
      expect(result['security_alert'], contains('SIM Toolkit'));
      expect(streamedFrame, isNull);
    });

    test('Screen perception returns status and desktop notice when not on Android', () async {
      final dispatcher = ToolDispatcher(
        db: db,
        guard: guard,
        activePackageName: 'com.android.settings',
      );

      final result = await dispatcher.dispatch(
        toolName: 'capture_screen',
        args: {},
      );

      expect(result['status'], equals('captured'));
      expect(result.containsKey('summary'), isTrue);
    });
  });
}
