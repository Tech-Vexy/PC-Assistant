import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
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

/// Client for Google's Gemini Multimodal Live API and Google Cloud Serverless
/// inference powered by Gemini 3.8 Flash.
class GeminiLiveClient {
  static const String liveHost = 'generativelanguage.googleapis.com';
  static const String defaultModel = 'models/gemini-3.8-flash';

  final String? apiKey;
  final String? accessToken;
  final Future<String> Function()? accessTokenProvider;
  final String? projectId;
  final String location;
  final String host;
  final String model;
  final List<Map<String, dynamic>> toolDeclarations;
  final String systemInstruction;
  final WebSocketChannel Function(Uri uri)? channelFactory;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Completer<void>? _setupCompleter;

  final _audioOutputController = StreamController<Uint8List>.broadcast();
  final _toolCallController = StreamController<GeminiToolCallEvent>.broadcast();
  final _transcriptController = StreamController<String>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  final _interruptionController = StreamController<void>.broadcast();

  bool _isConnected = false;

  GeminiLiveClient({
    this.apiKey,
    this.accessToken,
    this.accessTokenProvider,
    this.projectId,
    this.location = 'us-central1',
    String? host,
    String model = defaultModel,
    this.toolDeclarations = const [],
    this.systemInstruction =
        'You are Device Assistant, a helpful cross-platform companion.',
    this.channelFactory,
  })  : host = host ?? liveHost,
        model = model.startsWith('models/') ? model : 'models/$model';

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
  bool get isReady =>
      _isConnected && _setupCompleter != null && _setupCompleter!.isCompleted;

  /// Connects to the Gemini Live WebSocket endpoint and sends the setup payload.
  /// Awaits session confirmation (`setupComplete`) before returning.
  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    if (_isConnected) return;

    final token = accessTokenProvider != null
        ? await accessTokenProvider!()
        : accessToken;

    final Uri uri;
    if (token != null && token.isNotEmpty) {
      if (host.contains('aiplatform.googleapis.com')) {
        uri = Uri.parse(
          'wss://$host/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent',
        );
      } else {
        uri = Uri.parse(
          'wss://$host/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?access_token=$token',
        );
      }
    } else {
      uri = Uri.parse(
        'wss://$host/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey',
      );
    }

    _setupCompleter = Completer<void>();
    _channel = channelFactory != null
        ? channelFactory!(uri)
        : WebSocketChannel.connect(uri);

    _subscription = _channel!.stream.listen(
      _handleServerMessage,
      onError: (error) {
        if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
          _setupCompleter!.completeError(error);
        }
        _handleDisconnect();
      },
      onDone: () {
        if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
          _setupCompleter!.completeError(
            StateError('WebSocket closed before setup completed.'),
          );
        }
        _handleDisconnect();
      },
    );

    _sendSetupMessage();

    try {
      await _setupCompleter!.future.timeout(timeout);
    } catch (e) {
      await disconnect();
      rethrow;
    }

    _isConnected = true;
    _connectionStateController.add(true);
  }

  void _sendSetupMessage() {
    final cleanModel =
        model.startsWith('models/') ? model.substring(7) : model;
    final effectiveModel = (host.contains('aiplatform.googleapis.com') &&
            projectId != null &&
            projectId!.isNotEmpty)
        ? 'projects/$projectId/locations/$location/publishers/google/models/$cleanModel'
        : model;

    final setupPayload = {
      'setup': {
        'model': effectiveModel,
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
    if (!_isConnected ||
        _channel == null ||
        !(_setupCompleter?.isCompleted ?? false)) {
      return;
    }

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
    if (!_isConnected ||
        _channel == null ||
        !(_setupCompleter?.isCompleted ?? false)) {
      return;
    }

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
    if (!_isConnected ||
        _channel == null ||
        !(_setupCompleter?.isCompleted ?? false)) {
      return;
    }

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
    String? name,
    required Map<String, dynamic> result,
  }) {
    if (!_isConnected ||
        _channel == null ||
        !(_setupCompleter?.isCompleted ?? false)) {
      return;
    }

    final payload = {
      'toolResponse': {
        'functionResponses': [
          {
            'id': callId,
            if (name != null) 'name': name,
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

      // 0. Handle setup completion
      if (data.containsKey('setupComplete')) {
        if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
          _setupCompleter!.complete();
        }
        return;
      }

      // Handle server error message
      if (data.containsKey('error')) {
        final err = data['error'];
        final errMsg = (err is Map && err['message'] != null)
            ? err['message'].toString()
            : err.toString();
        if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
          _setupCompleter!.completeError(StateError(errMsg));
        }
        if (!_transcriptController.isClosed) {
          _transcriptController.add('[Gemini Live Error: $errMsg]');
        }
        _handleDisconnect();
        return;
      }

      // Handle server goAway notice
      if (data.containsKey('goAway')) {
        _handleDisconnect();
        return;
      }

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
              final id = call['id'] as String? ??
                  'call_${DateTime.now().millisecondsSinceEpoch}';
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
    if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
      _setupCompleter!.completeError(
        StateError('Disconnected before setup completed.'),
      );
    }
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
    if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
      _setupCompleter!.completeError(StateError('Client disconnected.'));
    }
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(false);
    }
  }

  /// Direct Google Cloud Serverless inference call to Gemini 3.8 Flash using ADC or API key
  Future<String> generateContent({
    required String prompt,
    String? systemInstruction,
    List<Map<String, dynamic>>? toolDeclarations,
    double temperature = 0.7,
    http.Client? httpClient,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      final token = accessTokenProvider != null
          ? await accessTokenProvider!()
          : accessToken;

      final cleanModel =
          model.startsWith('models/') ? model.substring(7) : model;

      final Uri uri;
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      if (host.contains('aiplatform.googleapis.com') &&
          projectId != null &&
          projectId!.isNotEmpty) {
        uri = Uri.parse(
          'https://$host/v1beta1/projects/$projectId/locations/$location/publishers/google/models/$cleanModel:generateContent',
        );
      } else if (token != null && token.isNotEmpty) {
        uri = Uri.parse(
          'https://$host/v1beta/models/$cleanModel:generateContent',
        );
        headers['Authorization'] = 'Bearer $token';
        if (projectId != null && projectId!.isNotEmpty) {
          headers['x-goog-user-project'] = projectId!;
        }
      } else {
        uri = Uri.parse(
          'https://$host/v1beta/models/$cleanModel:generateContent?key=$apiKey',
        );
      }

      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final payload = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt}
            ]
          }
        ],
        if (systemInstruction != null && systemInstruction.isNotEmpty)
          'systemInstruction': {
            'parts': [
              {'text': systemInstruction}
            ]
          },
        'generationConfig': {
          'temperature': temperature,
        },
        if (toolDeclarations != null && toolDeclarations.isNotEmpty)
          'tools': [
            {'functionDeclarations': toolDeclarations}
          ]
      };

      final response = await client.post(
        uri,
        headers: headers,
        body: jsonEncode(payload),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final candidates = data['candidates'] as List<dynamic>?;
        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'] as Map<String, dynamic>?;
          final parts = content?['parts'] as List<dynamic>?;
          if (parts != null && parts.isNotEmpty) {
            for (final part in parts) {
              if (part is Map<String, dynamic>) {
                if (part.containsKey('functionCall')) {
                  final fn = part['functionCall'] as Map<String, dynamic>;
                  return jsonEncode({
                    'action': 'tool_call',
                    'tool': fn['name'],
                    'args': fn['args'] ?? {},
                  });
                }
                if (part.containsKey('text')) {
                  return part['text'] as String;
                }
              }
            }
          }
        }
        return '';
      } else {
        throw StateError(
          'Gemini 3.8 Flash inference failed (${response.statusCode}): ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  /// Tests Google Cloud Serverless inference connection with Gemini 3.8 Flash
  Future<Map<String, dynamic>> testConnection({http.Client? httpClient}) async {
    final client = httpClient ?? http.Client();
    final stopwatch = Stopwatch()..start();
    try {
      final token = accessTokenProvider != null
          ? await accessTokenProvider!()
          : accessToken;

      final cleanModel =
          model.startsWith('models/') ? model.substring(7) : model;

      final Uri uri;
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      if (host.contains('aiplatform.googleapis.com') &&
          projectId != null &&
          projectId!.isNotEmpty) {
        uri = Uri.parse(
          'https://$host/v1beta1/projects/$projectId/locations/$location/publishers/google/models/$cleanModel:generateContent',
        );
      } else if (token != null && token.isNotEmpty) {
        uri = Uri.parse(
          'https://$host/v1beta/models/$cleanModel:generateContent',
        );
        headers['Authorization'] = 'Bearer $token';
        if (projectId != null && projectId!.isNotEmpty) {
          headers['x-goog-user-project'] = projectId!;
        }
      } else {
        uri = Uri.parse(
          'https://$host/v1beta/models/$cleanModel:generateContent?key=$apiKey',
        );
      }

      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final payload = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': 'Ping test. Reply with: OK'}
            ]
          }
        ],
        'generationConfig': {'maxOutputTokens': 10}
      };

      final response = await client
          .post(
            uri,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      stopwatch.stop();

      if (response.statusCode == 200) {
        return {
          'success': true,
          'latencyMs': stopwatch.elapsedMilliseconds,
          'model': model,
          'endpoint': host,
          'auth': token != null ? 'ADC (Bearer Token)' : 'API Key',
          if (projectId != null) 'projectId': projectId,
        };
      } else {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': response.body,
          'latencyMs': stopwatch.elapsedMilliseconds,
          'auth': token != null ? 'ADC (Bearer Token)' : 'API Key',
        };
      }
    } catch (e) {
      stopwatch.stop();
      return {
        'success': false,
        'error': e.toString(),
        'latencyMs': stopwatch.elapsedMilliseconds,
      };
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  void dispose() {
    disconnect();
    if (!_audioOutputController.isClosed) {
      _audioOutputController.close();
    }
    if (!_toolCallController.isClosed) {
      _toolCallController.close();
    }
    if (!_transcriptController.isClosed) {
      _transcriptController.close();
    }
    if (!_connectionStateController.isClosed) {
      _connectionStateController.close();
    }
    if (!_interruptionController.isClosed) {
      _interruptionController.close();
    }
  }
}
