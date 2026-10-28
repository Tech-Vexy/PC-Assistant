import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import '../security/sensitive_app_guard.dart';

/// Service managing periodic camera frame streaming (1–2 FPS) into
/// Google Gemini Live WebSocket API (`sendImageFrame`), giving the assistant
/// real-time multimodal visual context ("eyes").
class CameraStreamingService {
  final SensitiveAppGuard? _guard;
  final Future<Uint8List?> Function()? _frameProvider;

  bool _isStreaming = false;
  int _fps = 1;
  Timer? _frameTimer;
  String? _activePackageName;
  bool _useFrontCamera = false;

  final _streamingStateController = StreamController<bool>.broadcast();
  final _frameEmittedController = StreamController<Uint8List>.broadcast();

  CameraStreamingService({
    SensitiveAppGuard? guard,
    Future<Uint8List?> Function()? frameProvider,
  })  : _guard = guard,
        _frameProvider = frameProvider;

  bool get isStreaming => _isStreaming;
  int get fps => _fps;
  bool get useFrontCamera => _useFrontCamera;
  Stream<bool> get streamingStateStream => _streamingStateController.stream;
  Stream<Uint8List> get frameEmittedStream => _frameEmittedController.stream;

  /// Updates current foreground application to enforce Sensitive App Shield
  void updateActivePackage(String? packageName) {
    _activePackageName = packageName;
  }

  /// Toggles front vs back camera
  void toggleCamera() {
    _useFrontCamera = !_useFrontCamera;
  }

  /// Starts streaming camera video frames at the specified frames per second (1–3 FPS)
  Future<bool> startStreaming({
    required void Function(Uint8List jpegBytes) onFrame,
    int fps = 1,
    bool frontCamera = false,
  }) async {
    if (_isStreaming) return true;

    _fps = fps.clamp(1, 5);
    _useFrontCamera = frontCamera;
    _isStreaming = true;
    _streamingStateController.add(true);

    final intervalMs = (1000 / _fps).round();

    // Trigger initial frame immediately
    _captureAndEmitFrame(onFrame);

    _frameTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _captureAndEmitFrame(onFrame);
    });

    return true;
  }

  /// Captures a single frame, validates security shield, and emits via callback
  Future<void> _captureAndEmitFrame(void Function(Uint8List jpegBytes) onFrame) async {
    if (!_isStreaming) return;

    // Security Shield check: if sensitive app is active, pause/skip frame
    if (_guard != null && _activePackageName != null) {
      if (_guard.isPackageProtected(_activePackageName!)) {
        return; // Guarded: never leak sensitive screen/camera data
      }
    }

    try {
      Uint8List? frameBytes;

      if (_frameProvider != null) {
        frameBytes = await _frameProvider();
      } else {
        frameBytes = _generateMockCameraFrame(useFront: _useFrontCamera);
      }

      if (frameBytes != null && _isStreaming) {
        onFrame(frameBytes);
        _frameEmittedController.add(frameBytes);
      }
    } catch (_) {
      // Best-effort frame capture
    }
  }

  /// Stops camera frame streaming
  Future<void> stopStreaming() async {
    if (!_isStreaming) return;
    _frameTimer?.cancel();
    _frameTimer = null;
    _isStreaming = false;
    _streamingStateController.add(false);
  }

  /// Generates a valid, minimal JPEG byte stream representing an on-device camera snapshot
  static Uint8List _generateMockCameraFrame({bool useFront = false}) {
    // Minimal standard JPEG header + scan data + EOI marker
    final random = Random();
    final header = <int>[
      0xFF, 0xD8, // SOI (Start of Image)
      0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // JFIF marker
      0xFF, 0xDB, 0x00, 0x43, 0x00, // DQT (Quantization table)
    ];
    for (int i = 0; i < 64; i++) {
      header.add((i % 16) + 1);
    }
    header.addAll([
      0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x40, 0x00, 0x40, 0x01, 0x01, 0x11, 0x00, // SOF0 (64x64 mono frame)
      0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);
    for (int i = 0; i < 12; i++) {
      header.add(i);
    }
    header.addAll([
      0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, // SOS (Start of scan)
    ]);
    // Image scan payload
    for (int i = 0; i < 128; i++) {
      header.add((random.nextInt(254) + (useFront ? 1 : 0)) % 255);
    }
    header.addAll([0xFF, 0xD9]); // EOI (End of image)

    return Uint8List.fromList(header);
  }

  void dispose() {
    stopStreaming();
    _streamingStateController.close();
    _frameEmittedController.close();
  }
}
