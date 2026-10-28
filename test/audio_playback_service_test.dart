import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/audio/audio_playback_service.dart';

void main() {
  group('AudioPlaybackService Tests', () {
    test('initializes with inactive playback state', () {
      final service = AudioPlaybackService();
      expect(service.isPlaying, isFalse);
    });

    test('flush safely resets playback state without throwing', () async {
      final service = AudioPlaybackService();
      await service.flush();
      expect(service.isPlaying, isFalse);
    });

    test('dispose cleanly shuts down playback', () async {
      final service = AudioPlaybackService();
      await service.dispose();
      expect(service.isPlaying, isFalse);
    });
  });
}
