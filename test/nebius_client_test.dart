import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:device_assistant/core/network/nebius_client.dart';

void main() {
  group('NebiusClient Smart Routing Tests', () {
    test('chatCompletion with TaskComplexity.simple routes to Nemotron-3-nano', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, endsWith('/chat/completions'));
        expect(request.headers['Authorization'], equals('Bearer test_key'));

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('nvidia/nemotron-3-nano'));

        final responseBody = {
          'choices': [
            {
              'message': {'content': 'Fast reply from Nemotron 3 nano'}
            }
          ]
        };
        return http.Response(jsonEncode(responseBody), 200);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final reply = await client.chatCompletion(
        messages: [
          {'role': 'user', 'content': 'What is 2+2?'}
        ],
        complexity: TaskComplexity.simple,
      );

      expect(reply, equals('Fast reply from Nemotron 3 nano'));
    });

    test('chatCompletion with TaskComplexity.complex routes to Nemotron-3-super-vl', () async {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('nvidia/nemotron-3-super-vl'));

        final responseBody = {
          'choices': [
            {
              'message': {'content': 'Deep reasoning from Nemotron 3 super vl'}
            }
          ]
        };
        return http.Response(jsonEncode(responseBody), 200);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final reply = await client.chatCompletion(
        messages: [
          {'role': 'user', 'content': 'Decompose and strategize an end-to-end multi-step plan'}
        ],
        complexity: TaskComplexity.complex,
      );

      expect(reply, equals('Deep reasoning from Nemotron 3 super vl'));
    });

    test('planTask automatically routes request with model=nvidia/nemotron-3-super-vl', () async {
      final planResponse = {
        'choices': [
          {
            'message': {
              'content': '''```json
{
  "goal": "Check system and remind me",
  "steps": [
    {
      "step_id": 1,
      "tool": "system_status",
      "args": {},
      "purpose": "Verify OS"
    },
    {
      "step_id": 2,
      "tool": "remember",
      "args": {"key": "last_check", "value": "healthy"},
      "purpose": "Save health memory"
    }
  ]
}
```'''
            }
          }
        ]
      };

      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('nvidia/nemotron-3-super-vl'));
        return http.Response(jsonEncode(planResponse), 200);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final steps = await client.planTask(
        goal: 'Check system and remind me',
        availableTools: ['system_status', 'remember'],
      );

      expect(steps.length, equals(2));
      expect(steps.first['tool'], equals('system_status'));
      expect(steps.last['tool'], equals('remember'));
    });

    test('extractMemory automatically routes request with model=nvidia/nemotron-3-nano', () async {
      final memoryResponse = {
        'choices': [
          {
            'message': {
              'content': '''
{
  "should_remember": true,
  "key": "drink_preference",
  "value": "Earl Grey tea with honey",
  "category": "preference"
}
'''
            }
          }
        ]
      };

      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('nvidia/nemotron-3-nano'));
        return http.Response(jsonEncode(memoryResponse), 200);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final mem = await client.extractMemory('I always drink Earl Grey tea with honey in the morning');

      expect(mem, isNotNull);
      expect(mem!['should_remember'], isTrue);
      expect(mem['key'], equals('drink_preference'));
      expect(mem['category'], equals('preference'));
    });

    test('classifyTask correctly categorizes simple vs complex workloads', () {
      expect(
        NebiusClient.classifyTask(taskDescription: 'What is the capital of Kenya?'),
        equals(TaskComplexity.simple),
      );

      expect(
        NebiusClient.classifyTask(taskDescription: 'Plan a multi-step routine to back up files'),
        equals(TaskComplexity.complex),
      );

      expect(
        NebiusClient.classifyTask(taskDescription: 'Decompose goal into ordered steps'),
        equals(TaskComplexity.complex),
      );

      expect(
        NebiusClient.classifyTask(taskDescription: 'Quick note', requiresMultiStep: true),
        equals(TaskComplexity.complex),
      );

      expect(
        NebiusClient.classifyTask(taskDescription: 'Automate tasks', toolCount: 6),
        equals(TaskComplexity.complex),
      );
    });

    test('custom model identifiers override defaults in smart router', () async {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('custom/super-model'));
        return http.Response('{"choices":[{"message":{"content":"ok"}}]}', 200);
      });

      final client = NebiusClient(
        apiKey: 'test_key',
        superVlModel: 'custom/super-model',
        nanoModel: 'custom/nano-model',
        httpClient: mockClient,
      );

      expect(client.resolveModel(complexity: TaskComplexity.complex), equals('custom/super-model'));
      expect(client.resolveModel(complexity: TaskComplexity.simple), equals('custom/nano-model'));
      expect(client.resolveModel(explicitModel: 'explicit/override'), equals('explicit/override'));

      final res = await client.chatCompletion(
        messages: [{'role': 'user', 'content': 'test'}],
        complexity: TaskComplexity.complex,
      );
      expect(res, equals('ok'));
    });
  });
}
