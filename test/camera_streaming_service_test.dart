import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/core/video/camera_streaming_service.dart';

void main() {
  group('CameraStreamingService Tests', () {
    test('starts and stops camera streaming', () async {
      final service = CameraStreamingService();
      expect(service.isStreaming, isFalse);

      final receivedFrames = <Uint8List>[];
      final started = await service.startStreaming(
        onFrame: (frame) => receivedFrames.add(frame),
        fps: 2,
      );

      expect(started, isTrue);
      expect(service.isStreaming, isTrue);
      expect(service.fps, equals(2));

      // Wait for at least one frame
      await Future.delayed(const Duration(milliseconds: 600));
      expect(receivedFrames.isNotEmpty, isTrue);

      await service.stopStreaming();
      expect(service.isStreaming, isFalse);
      service.dispose();
    });

    test('suppresses frames when SensitiveAppGuard detects sensitive package', () async {
      final guard = SensitiveAppGuard();
      final service = CameraStreamingService(guard: guard);

      final frames = <Uint8List>[];
      await service.startStreaming(
        onFrame: (f) => frames.add(f),
        fps: 2,
      );

      // Normal package -> frames emitted
      service.updateActivePackage('com.android.calculator2');
      await Future.delayed(const Duration(milliseconds: 550));
      final countBefore = frames.length;
      expect(countBefore > 0, isTrue);

      // Sensitive banking package -> frames suppressed
      service.updateActivePackage('com.chase.sig.android');
      await Future.delayed(const Duration(milliseconds: 600));
      final countAfter = frames.length;
      // Should not have received new frames while shielded
      expect(countAfter, equals(countBefore));

      await service.stopStreaming();
      service.dispose();
    });

    test('toggleCamera switches front and back camera', () {
      final service = CameraStreamingService();
      expect(service.useFrontCamera, isFalse);
      service.toggleCamera();
      expect(service.useFrontCamera, isTrue);
      service.toggleCamera();
      expect(service.useFrontCamera, isFalse);
      service.dispose();
    });
  });
}
