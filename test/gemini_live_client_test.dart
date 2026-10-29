import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:device_assistant/core/network/gemini_live_client.dart';

class _MockWebSocketSink implements WebSocketSink {
  final StreamSink<dynamic> _inner;
  _MockWebSocketSink(this._inner);

  @override
  void add(dynamic data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<dynamic> stream) => _inner.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

class MockWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> serverToClient =
      StreamController<dynamic>.broadcast();
  final StreamController<dynamic> clientToServer =
      StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get stream => serverToClient.stream;

  @override
  WebSocketSink get sink => _MockWebSocketSink(clientToServer.sink);

  @override
  String? get closeReason => null;

  @override
  int? get closeCode => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();

  void dispose() {
    serverToClient.close();
    clientToServer.close();
  }
}

void main() {
  group('GeminiLiveClient Models & Events', () {
    test('GeminiToolCallEvent constructs correctly', () {
      const event = GeminiToolCallEvent(
        callId: 'call_999',
        name: 'remember',
        arguments: {'key': 'test', 'value': '123'},
      );

      expect(event.callId, equals('call_999'));
      expect(event.name, equals('remember'));
      expect(event.arguments['key'], equals('test'));
    });

    test('GeminiLiveClient initializes with default config (gemini-3.8-live)',
        () {
      final client = GeminiLiveClient(apiKey: 'dummy_key');
      expect(client.isConnected, isFalse);
      expect(client.model, equals('models/gemini-3.8-live'));
      expect(() => client.sendTextMessage('Hello world'), returnsNormally);
      client.dispose();
    });

    test('GeminiLiveClient normalizes model without models/ prefix', () {
      final client =
          GeminiLiveClient(apiKey: 'dummy_key', model: 'gemini-3.8-live');
      expect(client.model, equals('models/gemini-3.8-live'));
      client.dispose();
    });

    test(
        'Full handshake, setupComplete, audio streaming, tool calling, and barge-in',
        () async {
      final mockChannel = MockWebSocketChannel();
      final client = GeminiLiveClient(
        apiKey: 'test_key',
        channelFactory: (_) => mockChannel,
      );

      final connectionFuture =
          client.connect(timeout: const Duration(seconds: 2));

      // Simulate server receiving setup and replying setupComplete
      mockChannel.serverToClient.add(jsonEncode({'setupComplete': {}}));

      await connectionFuture;
      expect(client.isConnected, isTrue);
      expect(client.isReady, isTrue);

      // Verify audio and transcript streaming
      final transcripts = <String>[];
      final audioChunks = <Uint8List>[];
      bool interrupted = false;
      GeminiToolCallEvent? receivedToolCall;

      client.transcriptStream.listen(transcripts.add);
      client.audioOutputStream.listen(audioChunks.add);
      client.interruptionStream.listen((_) => interrupted = true);
      client.toolCallStream.listen((call) => receivedToolCall = call);

      final dummyAudioBytes = Uint8List.fromList([1, 2, 3, 4]);
      final base64Audio = base64Encode(dummyAudioBytes);

      // 1. Deliver server content with speech audio and text
      mockChannel.serverToClient.add(jsonEncode({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/pcm;rate=24000',
                  'data': base64Audio,
                }
              },
              {'text': 'Hello! How can I assist you on your device?'}
            ]
          }
        }
      }));

      await pumpEventQueue();
      expect(
          transcripts, contains('Hello! How can I assist you on your device?'));
      expect(audioChunks.length, equals(1));
      expect(audioChunks.first, equals(dummyAudioBytes));

      // 2. Deliver tool call event from model
      mockChannel.serverToClient.add(jsonEncode({
        'toolCall': {
          'functionCalls': [
            {
              'id': 'call_123',
              'name': 'open_application',
              'args': {'app_name': 'Settings'}
            }
          ]
        }
      }));

      await pumpEventQueue();
      expect(receivedToolCall, isNotNull);
      expect(receivedToolCall!.callId, equals('call_123'));
      expect(receivedToolCall!.name, equals('open_application'));
      expect(receivedToolCall!.arguments['app_name'], equals('Settings'));

      // 3. Deliver user interruption
      mockChannel.serverToClient.add(jsonEncode({
        'serverContent': {'interrupted': true}
      }));

      await pumpEventQueue();
      expect(interrupted, isTrue);

      await client.disconnect();
      mockChannel.dispose();
      client.dispose();
    });
  });
}
