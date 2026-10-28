import 'dart:math';
import 'dart:typed_data';

/// Result from processing an audio frame through the Voice Activity Detector.
class VadProcessResult {
  final bool shouldSend;
  final bool isSpeech;
  final bool shouldBargeIn;
  final double rms;
  final double noiseFloor;
  final List<Uint8List> preRollFrames;

  const VadProcessResult({
    required this.shouldSend,
    required this.isSpeech,
    required this.shouldBargeIn,
    required this.rms,
    required this.noiseFloor,
    this.preRollFrames = const [],
  });
}

/// On-device Voice Activity Detector (VAD) and Acoustic Echo Ducking for Voice Assistant.
/// Protects against self-interruption (assistant hearing itself), background room noise,
/// and saves mobile battery & cloud tokens by transmitting audio only during genuine speech.
class VoiceActivityDetector {
  final int sampleRate;
  final double minSpeechRms;
  final double snrMultiplier;
  final double bargeInThreshold;
  final int bargeInConsecutiveFrames;
  final int preRollMaxFrames;
  final int hangoverMaxFrames;

  double _noiseFloor;
  bool _isSpeechActive = false;
  int _hangoverCount = 0;
  int _bargeInCount = 0;
  int _playbackStartTime = 0;
  final List<Uint8List> _preRollBuffer = [];

  VoiceActivityDetector({
    this.sampleRate = 24000,
    this.minSpeechRms = 1200.0,
    this.snrMultiplier = 2.2,
    this.bargeInThreshold = 8000.0,
    this.bargeInConsecutiveFrames = 3,
    this.preRollMaxFrames = 3,
    this.hangoverMaxFrames = 5,
    double initialNoiseFloor = 400.0,
  }) : _noiseFloor = initialNoiseFloor;

  bool get isSpeechActive => _isSpeechActive;
  double get noiseFloor => _noiseFloor;

  /// Calculate Root Mean Square (RMS) energy of 16-bit linear PCM buffer
  double calculateRms(Uint8List buffer) {
    if (buffer.length < 2) return 0.0;
    final int numSamples = buffer.length ~/ 2;
    final byteData = ByteData.sublistView(buffer);
    double sum = 0.0;

    for (int i = 0; i < numSamples; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      sum += sample * sample;
    }

    return sqrt(sum / max(1, numSamples));
  }

  /// Calculate Zero-Crossing Rate (ZCR) of 16-bit linear PCM buffer
  double calculateZcr(Uint8List buffer) {
    if (buffer.length < 4) return 0.0;
    final int numSamples = buffer.length ~/ 2;
    final byteData = ByteData.sublistView(buffer);

    int crossings = 0;
    bool prevSign = byteData.getInt16(0, Endian.little) >= 0;

    for (int i = 1; i < numSamples; i++) {
      final currentSign = byteData.getInt16(i * 2, Endian.little) >= 0;
      if (currentSign != prevSign) {
        crossings++;
        prevSign = currentSign;
      }
    }

    return crossings / max(1, numSamples);
  }

  /// Notify VAD that assistant audio playback has started (for echo ducking)
  void onPlaybackStarted() {
    _playbackStartTime = DateTime.now().millisecondsSinceEpoch;
    _bargeInCount = 0;
    _isSpeechActive = false;
    _hangoverCount = 0;
    _preRollBuffer.clear();
  }

  /// Notify VAD that assistant audio playback has finished
  void onPlaybackEnded() {
    _playbackStartTime = 0;
    _bargeInCount = 0;
  }

  /// Resets VAD internal state
  void reset() {
    _isSpeechActive = false;
    _hangoverCount = 0;
    _bargeInCount = 0;
    _preRollBuffer.clear();
  }

  /// Process an incoming PCM16 audio frame
  VadProcessResult process(Uint8List frameBuffer, {bool isAssistantSpeaking = false}) {
    final rms = calculateRms(frameBuffer);
    final zcr = calculateZcr(frameBuffer);

    // Case 1: Assistant is speaking (Acoustic Echo Ducking)
    if (isAssistantSpeaking) {
      _isSpeechActive = false;
      _hangoverCount = 0;

      // Check for intentional barge-in (sustained loud speech exceeding bargeInThreshold)
      final now = DateTime.now().millisecondsSinceEpoch;
      final playbackDuration = now - _playbackStartTime;

      // Allow 400ms grace period after playback starts to avoid false onset triggers
      if (bargeInThreshold > 0 && playbackDuration > 400 && rms >= bargeInThreshold) {
        _bargeInCount++;
        if (_bargeInCount >= bargeInConsecutiveFrames) {
          _bargeInCount = 0;
          _isSpeechActive = true;
          return VadProcessResult(
            shouldSend: true,
            isSpeech: true,
            shouldBargeIn: true,
            rms: rms,
            noiseFloor: _noiseFloor,
          );
        }
      } else {
        _bargeInCount = 0;
      }

      // Suppress mic capture during speaker output to prevent self-interruption
      return VadProcessResult(
        shouldSend: false,
        isSpeech: false,
        shouldBargeIn: false,
        rms: rms,
        noiseFloor: _noiseFloor,
      );
    }

    // Case 2: User turn (Mic Active, Speaker Silent)
    // Dynamic speech threshold based on ambient noise floor
    final speechThreshold = max(minSpeechRms, _noiseFloor * snrMultiplier);
    final bool rawSpeech = rms >= speechThreshold;

    if (rawSpeech) {
      final wasInactive = !_isSpeechActive;
      _isSpeechActive = true;
      _hangoverCount = hangoverMaxFrames;

      List<Uint8List> preRollToSend = const [];
      if (wasInactive && _preRollBuffer.isNotEmpty) {
        preRollToSend = List.from(_preRollBuffer);
        _preRollBuffer.clear();
      }

      return VadProcessResult(
        shouldSend: true,
        isSpeech: true,
        shouldBargeIn: false,
        rms: rms,
        noiseFloor: _noiseFloor,
        preRollFrames: preRollToSend,
      );
    }

    // Hangover period: keep transmitting briefly after speech ends to avoid clipping word ends
    if (_isSpeechActive && _hangoverCount > 0) {
      _hangoverCount--;
      return VadProcessResult(
        shouldSend: true,
        isSpeech: true,
        shouldBargeIn: false,
        rms: rms,
        noiseFloor: _noiseFloor,
      );
    }

    // Speech has ended: update background noise floor estimate
    _isSpeechActive = false;

    // Adapt noise floor slowly during confirmed silence
    if (rms < _noiseFloor * 1.5 && zcr < 0.6) {
      _noiseFloor = (_noiseFloor * 0.95) + (rms * 0.05);
    }

    // Keep recent silence in pre-roll ring buffer so start of next word isn't clipped
    _preRollBuffer.add(frameBuffer);
    if (_preRollBuffer.length > preRollMaxFrames) {
      _preRollBuffer.removeAt(0);
    }

    return VadProcessResult(
      shouldSend: false,
      isSpeech: false,
      shouldBargeIn: false,
      rms: rms,
      noiseFloor: _noiseFloor,
    );
  }
}
