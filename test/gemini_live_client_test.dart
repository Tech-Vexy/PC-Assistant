import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/network/gemini_live_client.dart';

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

    test('GeminiLiveClient initializes with default config', () {
      final client = GeminiLiveClient(apiKey: 'dummy_key');
      expect(client.isConnected, isFalse);
      expect(client.model, equals(GeminiLiveClient.defaultModel));
      // Verify client safely handles message sends when disconnected
      expect(() => client.sendTextMessage('Hello world'), returnsNormally);
      client.dispose();
    });
  });
}
