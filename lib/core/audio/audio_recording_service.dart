import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'voice_activity_detector.dart';

/// Audio recording service that streams microphone audio in raw PCM16 mono format
/// (24kHz native for Gemini Multimodal Live API), enhanced with on-device VAD
/// (Voice Activity Detection) and acoustic echo ducking.
class AudioRecordingService {
  final AudioRecorder _recorder;
  final VoiceActivityDetector _vad;
  StreamSubscription<List<int>>? _streamSubscription;
  bool _isRecording = false;
  bool _isAssistantSpeaking = false;

  AudioRecordingService({
    AudioRecorder? recorder,
    VoiceActivityDetector? vad,
  })  : _recorder = recorder ?? AudioRecorder(),
        _vad = vad ?? VoiceActivityDetector();

  bool get isRecording => _isRecording;
  VoiceActivityDetector get vad => _vad;
  bool get isSpeechActive => _vad.isSpeechActive;

  /// Requests microphone permission if not already granted
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Informs VAD that assistant audio playback has started (for echo ducking)
  void notifyPlaybackStarted() {
    _isAssistantSpeaking = true;
    _vad.onPlaybackStarted();
  }

  /// Informs VAD that assistant audio playback has ended
  void notifyPlaybackEnded() {
    _isAssistantSpeaking = false;
    _vad.onPlaybackEnded();
  }

  /// Starts streaming 24kHz 16-bit mono PCM chunks from the device microphone
  Future<bool> startStreaming({
    required void Function(Uint8List chunk) onAudioChunk,
    int sampleRate = 24000,
    bool enableVad = true,
    void Function()? onBargeIn,
    void Function(bool isSpeaking, double rms)? onSpeechStatusChanged,
  }) async {
    if (_isRecording) return true;

    final hasPerm = await hasPermission();
    if (!hasPerm) return false;

    try {
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 24000,
        numChannels: 1,
      );

      final stream = await _recorder.startStream(config);
      _streamSubscription = stream.listen(
        (data) {
          final chunk = data;

          if (!enableVad) {
            onAudioChunk(chunk);
            return;
          }

          final vadRes =
              _vad.process(chunk, isAssistantSpeaking: _isAssistantSpeaking);
          onSpeechStatusChanged?.call(vadRes.isSpeech, vadRes.rms);

          if (vadRes.shouldBargeIn) {
            onBargeIn?.call();
          }

          if (vadRes.shouldSend) {
            // If starting speech, transmit buffered pre-roll audio first
            for (final preRoll in vadRes.preRollFrames) {
              onAudioChunk(preRoll);
            }
            onAudioChunk(chunk);
          }
        },
        onError: (err) {
          stopStreaming();
        },
        cancelOnError: true,
      );

      _isRecording = true;
      return true;
    } catch (_) {
      _isRecording = false;
      return false;
    }
  }

  /// Halts the microphone audio stream
  Future<void> stopStreaming() async {
    if (!_isRecording) return;
    try {
      await _streamSubscription?.cancel();
      _streamSubscription = null;
      await _recorder.stop();
    } catch (_) {}
    _isRecording = false;
  }

  /// Releases resources
  Future<void> dispose() async {
    await stopStreaming();
    await _recorder.dispose();
  }
}
