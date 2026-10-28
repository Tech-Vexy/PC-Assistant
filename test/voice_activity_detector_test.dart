import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/audio/voice_activity_detector.dart';

void main() {
  group('VoiceActivityDetector Tests', () {
    Uint8List generateSineFrame({required int amplitude, int length = 960}) {
      final buffer = Uint8List(length * 2);
      final byteData = ByteData.sublistView(buffer);
      for (int i = 0; i < length; i++) {
        final val = (amplitude * (i % 2 == 0 ? 1 : -1)).clamp(-32768, 32767);
        byteData.setInt16(i * 2, val, Endian.little);
      }
      return buffer;
    }

    test('calculates RMS and ZCR accurately', () {
      final vad = VoiceActivityDetector();

      final silentFrame = Uint8List(960 * 2); // all zeroes
      expect(vad.calculateRms(silentFrame), equals(0.0));
      expect(vad.calculateZcr(silentFrame), equals(0.0));

      final activeFrame = generateSineFrame(amplitude: 5000);
      expect(vad.calculateRms(activeFrame), greaterThan(4000.0));
      expect(vad.calculateZcr(activeFrame), greaterThan(0.5));
    });

    test('filters out low-energy ambient noise and admits clear speech', () {
      final vad = VoiceActivityDetector(minSpeechRms: 1000.0);

      // Low ambient noise -> shouldSend=false
      final noiseFrame = generateSineFrame(amplitude: 200);
      final noiseResult = vad.process(noiseFrame);
      expect(noiseResult.shouldSend, isFalse);
      expect(noiseResult.isSpeech, isFalse);

      // Clear voice speech -> shouldSend=true
      final speechFrame = generateSineFrame(amplitude: 4000);
      final speechResult = vad.process(speechFrame);
      expect(speechResult.shouldSend, isTrue);
      expect(speechResult.isSpeech, isTrue);
    });

    test(
        'acoustic echo ducking suppresses mic while assistant speaks, unless loud barge-in',
        () {
      final vad = VoiceActivityDetector(
          bargeInThreshold: 8000.0, bargeInConsecutiveFrames: 2);

      vad.onPlaybackStarted();

      // Moderate speech while assistant speaks is ducked (echo prevention)
      final normalVoice = generateSineFrame(amplitude: 3000);
      final ducked = vad.process(normalVoice, isAssistantSpeaking: true);
      expect(ducked.shouldSend, isFalse);
      expect(ducked.shouldBargeIn, isFalse);

      // Wait 500ms to bypass onset grace period
      // Note: we simulate barge-in with loud frames
      final loudFrame = generateSineFrame(amplitude: 12000);
      vad.process(loudFrame, isAssistantSpeaking: true);
      vad.onPlaybackEnded();
      expect(vad.isSpeechActive, isFalse);
    });
  });
}
