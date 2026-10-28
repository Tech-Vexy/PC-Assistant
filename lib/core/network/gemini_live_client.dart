import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Event representing a tool call request from Gemini Live
class GeminiToolCallEvent {
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;

  const GeminiToolCallEvent({
    required this.callId,
    required this.name,
    required this.arguments,
  });
}

/// Client for Google's Gemini Multimodal Live API over bidirectional WebSocket.
class GeminiLiveClient {
  static const String liveHost = 'generativelanguage.googleapis.com';
  static const String defaultModel = 'models/gemini-2.0-flash-exp';

  final String apiKey;
  final String model;
  final List<Map<String, dynamic>> toolDeclarations;
  final String systemInstruction;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final _audioOutputController = StreamController<Uint8List>.broadcast();
  final _toolCallController = StreamController<GeminiToolCallEvent>.broadcast();
  final _transcriptController = StreamController<String>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  final _interruptionController = StreamController<void>.broadcast();

  bool _isConnected = false;

  GeminiLiveClient({
    required this.apiKey,
    this.model = defaultModel,
    this.toolDeclarations = const [],
    this.systemInstruction = 'You are Device Assistant, a helpful cross-platform companion.',
  });

  /// Stream of raw 24kHz PCM16 audio chunks returned by Gemini
  Stream<Uint8List> get audioOutputStream => _audioOutputController.stream;

  /// Stream of tool call requests initiated by Gemini
  Stream<GeminiToolCallEvent> get toolCallStream => _toolCallController.stream;

  /// Stream of text transcripts or assistant utterances
  Stream<String> get transcriptStream => _transcriptController.stream;

  /// Stream emitting when user barge-in / interruption is detected
  Stream<void> get interruptionStream => _interruptionController.stream;

  /// Stream indicating whether the live socket is active
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  bool get isConnected => _isConnected;

  /// Connects to the Gemini Live WebSocket endpoint and sends the setup payload
  Future<void> connect() async {
    if (_isConnected) return;

    final uri = Uri.parse(
      'wss://$liveHost/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=$apiKey',
    );

    _channel = WebSocketChannel.connect(uri);

    _subscription = _channel!.stream.listen(
      _handleServerMessage,
      onError: (error) {
        _handleDisconnect();
      },
      onDone: () {
        _handleDisconnect();
      },
    );

    _sendSetupMessage();
    _isConnected = true;
    _connectionStateController.add(true);
  }

  void _sendSetupMessage() {
    final setupPayload = {
      'setup': {
        'model': model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {
                'voiceName': 'Puck', // Fast, natural voice
              }
            }
          }
        },
        if (toolDeclarations.isNotEmpty)
          'tools': [
            {'functionDeclarations': toolDeclarations}
          ],
        'systemInstruction': {
          'parts': [
            {'text': systemInstruction}
          ]
        }
      }
    };

    _channel?.sink.add(jsonEncode(setupPayload));
  }

  /// Sends a real-time chunk of 24kHz or 16kHz PCM audio bytes
  void sendAudioChunk(Uint8List pcmBytes, {int sampleRate = 24000}) {
    if (!_isConnected || _channel == null) return;

    final payload = {
      'realtimeInput': {
        'mediaChunks': [
          {
            'mimeType': 'audio/pcm;rate=$sampleRate',
            'data': base64Encode(pcmBytes),
          }
        ]
      }
    };

    _channel?.sink.add(jsonEncode(payload));
  }

  /// Sends a text message / user prompt turn over the live bidirectional session
  void sendTextMessage(String text) {
    if (!_isConnected || _channel == null) return;

    final payload = {
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ]
          }
        ],
        'turnComplete': true
      }
    };

    _channel?.sink.add(jsonEncode(payload));
  }

  /// Sends a JPEG screen capture or camera frame
  void sendImageFrame(Uint8List jpegBytes) {
    if (!_isConnected || _channel == null) return;

    final payload = {
      'realtimeInput': {
        'mediaChunks': [
          {
            'mimeType': 'image/jpeg',
            'data': base64Encode(jpegBytes),
          }
        ]
      }
    };

    _channel?.sink.add(jsonEncode(payload));
  }

  /// Responds to a tool call request with execution results
  void sendToolResponse({
    required String callId,
    required Map<String, dynamic> result,
  }) {
    if (!_isConnected || _channel == null) return;

    final payload = {
      'toolResponse': {
        'functionResponses': [
          {
            'id': callId,
            'response': {'output': result},
          }
        ]
      }
    };

    _channel?.sink.add(jsonEncode(payload));
  }

  void _handleServerMessage(dynamic rawMessage) {
    try {
      final data = jsonDecode(rawMessage as String) as Map<String, dynamic>;

      // 1. Process Server Content (Audio / Text / Interruption)
      if (data.containsKey('serverContent')) {
        final content = data['serverContent'] as Map<String, dynamic>;

        if (content['interrupted'] == true) {
          // Barge-in detected: emit signal to halt audio playback immediately
          if (!_interruptionController.isClosed) {
            _interruptionController.add(null);
          }
          if (!_transcriptController.isClosed) {
            _transcriptController.add('[Interrupted by user]');
          }
        }

        if (content.containsKey('modelTurn')) {
          final modelTurn = content['modelTurn'] as Map<String, dynamic>;
          final parts = modelTurn['parts'] as List<dynamic>?;

          if (parts != null) {
            for (final part in parts) {
              if (part is Map<String, dynamic>) {
                // Audio chunk
                if (part.containsKey('inlineData')) {
                  final inline = part['inlineData'] as Map<String, dynamic>;
                  final base64Audio = inline['data'] as String?;
                  if (base64Audio != null) {
                    final bytes = base64Decode(base64Audio);
                    if (!_audioOutputController.isClosed) {
                      _audioOutputController.add(bytes);
                    }
                  }
                }
                // Text transcript
                if (part.containsKey('text')) {
                  if (!_transcriptController.isClosed) {
                    _transcriptController.add(part['text'] as String);
                  }
                }
              }
            }
          }
        }
      }

      // 2. Process Tool Calls from Gemini
      if (data.containsKey('toolCall')) {
        final toolCall = data['toolCall'] as Map<String, dynamic>;
        final functionCalls = toolCall['functionCalls'] as List<dynamic>?;

        if (functionCalls != null) {
          for (final call in functionCalls) {
            if (call is Map<String, dynamic>) {
              final id = call['id'] as String? ?? 'call_${DateTime.now().millisecondsSinceEpoch}';
              final name = call['name'] as String;
              final args = (call['args'] as Map<String, dynamic>?) ?? {};

              if (!_toolCallController.isClosed) {
                _toolCallController.add(
                  GeminiToolCallEvent(
                    callId: id,
                    name: name,
                    arguments: args,
                  ),
                );
              }
            }
          }
        }
      }
    } catch (_) {
      // Discard or log malformed packet
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(false);
    }
  }

  Future<void> disconnect() async {
    _isConnected = false;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(false);
    }
  }

  void dispose() {
    disconnect();
    if (!_audioOutputController.isClosed) _audioOutputController.close();
    if (!_toolCallController.isClosed) _toolCallController.close();
    if (!_transcriptController.isClosed) _transcriptController.close();
    if (!_connectionStateController.isClosed) _connectionStateController.close();
    if (!_interruptionController.isClosed) _interruptionController.close();
  }
}
