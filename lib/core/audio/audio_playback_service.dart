import 'dart:io';
import 'dart:typed_data';
import '../../platform/android/android_bridge.dart';

/// Cross-platform low-latency streaming audio playback engine for 24kHz PCM16 audio.
/// On Android: Streams directly to hardware AudioTrack via AssistantForegroundService.
/// On Desktop: Streams to persistent ffplay stdin pipeline with instant barge-in cutoff.
class AudioPlaybackService {
  final AndroidBridge? androidBridge;
  Process? _desktopPlaybackProcess;
  bool _isPlaying = false;

  AudioPlaybackService({this.androidBridge});

  bool get isPlaying => _isPlaying;

  /// Plays a 24kHz 16-bit mono PCM chunk through the device speaker
  Future<void> playChunk(Uint8List pcmBytes) async {
    _isPlaying = true;

    if (Platform.isAndroid && androidBridge != null) {
      await androidBridge!.writeAudioChunk(pcmBytes);
      return;
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await _writeDesktopPcm(pcmBytes);
    }
  }

  Future<void> _writeDesktopPcm(Uint8List pcmBytes) async {
    try {
      if (_desktopPlaybackProcess == null) {
        await _startDesktopPipeline();
      }
      _desktopPlaybackProcess?.stdin.add(pcmBytes);
    } catch (_) {
      _desktopPlaybackProcess = null;
    }
  }

  Future<void> _startDesktopPipeline() async {
    try {
      _desktopPlaybackProcess = await Process.start(
        'ffplay',
        [
          '-f',
          's16le',
          '-ar',
          '24000',
          '-ac',
          '1',
          '-nodisp',
          '-autoexit',
          '-'
        ],
        mode: ProcessStartMode.normal,
      );
    } catch (_) {
      _desktopPlaybackProcess = null;
    }
  }

  /// Instantly halts playback and flushes hardware audio buffers (for user barge-in / interruption)
  Future<void> flush() async {
    _isPlaying = false;

    if (Platform.isAndroid && androidBridge != null) {
      await androidBridge!.flushAudio();
      return;
    }

    if (_desktopPlaybackProcess != null) {
      try {
        _desktopPlaybackProcess!.kill();
      } catch (_) {}
      _desktopPlaybackProcess = null;
    }
  }

  /// Releases resources
  Future<void> dispose() async {
    await flush();
  }
}
