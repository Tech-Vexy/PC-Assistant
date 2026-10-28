import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/audio/audio_recording_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (MethodCall methodCall) async {
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      null,
    );
  });

  group('AudioRecordingService Tests', () {
    test('initializes with inactive recording state', () {
      final service = AudioRecordingService();
      expect(service.isRecording, isFalse);
    });

    test('stopStreaming safely executes when already stopped', () async {
      final service = AudioRecordingService();
      await service.stopStreaming();
      expect(service.isRecording, isFalse);
    });
  });
}
