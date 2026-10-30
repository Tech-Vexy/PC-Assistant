import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:device_assistant/core/network/nebius_client.dart';
import 'package:device_assistant/core/security/key_vault.dart';

void main() {
  group('NebiusClient Smart Routing Tests', () {
    test(
        'chatCompletion with TaskComplexity.simple routes to Nemotron-3-Nano-30B',
        () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, endsWith('/chat/completions'));
        expect(request.headers['Authorization'], equals('Bearer test_key'));

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B'));

        final responseBody = {
          'choices': [
            {
              'message': {'content': 'Fast reply from Nemotron 3 nano 30b'}
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

      expect(reply, equals('Fast reply from Nemotron 3 nano 30b'));
    });

    test(
        'chatCompletion with TaskComplexity.complex routes to Nemotron-3.5-Super-VL',
        () async {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('nvidia/Nemotron-3.5-Super-VL'));

        final responseBody = {
          'choices': [
            {
              'message': {
                'content': 'Deep reasoning from Nemotron 3.5 super vl'
              }
            }
          ]
        };
        return http.Response(jsonEncode(responseBody), 200);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final reply = await client.chatCompletion(
        messages: [
          {
            'role': 'user',
            'content': 'Decompose and strategize an end-to-end multi-step plan'
          }
        ],
        complexity: TaskComplexity.complex,
      );

      expect(reply, equals('Deep reasoning from Nemotron 3.5 super vl'));
    });

    test('chatCompletion handles reasoning fallback when content is null',
        () async {
      final mockClient = MockClient((request) async {
        final responseBody = {
          'choices': [
            {
              'message': {
                'content': null,
                'reasoning': 'Extracted reasoning from thinking model',
              }
            }
          ]
        };
        return http.Response(jsonEncode(responseBody), 200);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final reply = await client.chatCompletion(
        messages: [
          {'role': 'user', 'content': 'Explain logic'}
        ],
      );

      expect(reply, equals('Extracted reasoning from thinking model'));
    });

    test('supports dedicated per-model endpoints for Super VL and Nano',
        () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == 'super-vl.tokenfactory.nebius.com') {
          return http.Response(
              '{"choices":[{"message":{"content":"from super endpoint"}}]}',
              200);
        } else if (request.url.host == 'nano.tokenfactory.nebius.com') {
          return http.Response(
              '{"choices":[{"message":{"content":"from nano endpoint"}}]}',
              200);
        }
        return http.Response('{"error":"unknown host"}', 404);
      });

      final client = NebiusClient(
        apiKey: 'test_key',
        superVlEndpoint: 'https://super-vl.tokenfactory.nebius.com/v1',
        nanoEndpoint: 'https://nano.tokenfactory.nebius.com/v1',
        httpClient: mockClient,
      );

      final superRes = await client.chatCompletion(
        messages: [
          {'role': 'user', 'content': 'plan'}
        ],
        complexity: TaskComplexity.complex,
      );
      expect(superRes, equals('from super endpoint'));

      final nanoRes = await client.chatCompletion(
        messages: [
          {'role': 'user', 'content': 'hello'}
        ],
        complexity: TaskComplexity.simple,
      );
      expect(nanoRes, equals('from nano endpoint'));
    });

    test('normalizes user model aliases to official identifiers', () {
      expect(NebiusClient.normalizeModel('Nemotron-3-Nano-30b'),
          equals('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B'));
      expect(NebiusClient.normalizeModel('nemotron-3-nano'),
          equals('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B'));
      expect(NebiusClient.normalizeModel('Nemotron 3.5 super vl'),
          equals('nvidia/Nemotron-3.5-Super-VL'));
      expect(NebiusClient.normalizeModel('nvidia/nemotron-3-super-vl'),
          equals('nvidia/Nemotron-3.5-Super-VL'));
      expect(NebiusClient.normalizeModel('Nemotron 3.5 Lightning'),
          equals('nvidia/Nemotron-3_5-Lightning'));
      expect(NebiusClient.normalizeModel('nvidia/nemotron-3-super-120b'),
          equals('nvidia/nemotron-3-super-120b-a12b'));
    });

    test('listModels and testConnection correctly evaluate Nebius endpoint',
        () async {
      final mockModelsResponse = {
        'object': 'list',
        'data': [
          {'id': 'nvidia/Nemotron-3.5-Super-VL'},
          {'id': 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B'},
          {'id': 'nvidia/Nemotron-3_5-Lightning'},
          {'id': 'meta/llama-3.3-70b-instruct'},
        ]
      };

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/models')) {
          expect(request.headers['Authorization'], equals('Bearer test_key'));
          return http.Response(jsonEncode(mockModelsResponse), 200);
        }
        if (request.url.path.endsWith('/chat/completions')) {
          return http.Response(
              '{"choices":[{"message":{"content":"OK Verified"}}]}', 200);
        }
        return http.Response('{"error":"not found"}', 404);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final models = await client.listModels();
      expect(models.length, equals(4));
      expect(models, contains('nvidia/Nemotron-3.5-Super-VL'));
      expect(models, contains('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B'));

      final health = await client.testConnection(
        model: 'nvidia/Nemotron-3.5-Super-VL',
      );
      expect(health['success'], isTrue);
      expect(health['modelCount'], equals(4));
      expect((health['nvidiaModels'] as List).length, equals(3));
      expect(health['hasTargetModel'], isTrue);
    });

    test(
        'planTask automatically routes request with model=nvidia/Nemotron-3.5-Super-VL',
        () async {
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
        expect(body['model'], equals('nvidia/Nemotron-3.5-Super-VL'));
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

    test(
        'extractMemory automatically routes request with model=nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B',
        () async {
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
        expect(body['model'], equals('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B'));
        return http.Response(jsonEncode(memoryResponse), 200);
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final mem = await client.extractMemory(
          'I always drink Earl Grey tea with honey in the morning');

      expect(mem, isNotNull);
      expect(mem!['should_remember'], isTrue);
      expect(mem['key'], equals('drink_preference'));
      expect(mem['category'], equals('preference'));
    });

    test('classifyTask correctly categorizes simple vs complex workloads', () {
      expect(
        NebiusClient.classifyTask(
            taskDescription: 'What is the capital of Kenya?'),
        equals(TaskComplexity.simple),
      );

      expect(
        NebiusClient.classifyTask(
            taskDescription: 'Plan a multi-step routine to back up files'),
        equals(TaskComplexity.complex),
      );

      expect(
        NebiusClient.classifyTask(
            taskDescription: 'Decompose goal into ordered steps'),
        equals(TaskComplexity.complex),
      );

      expect(
        NebiusClient.classifyTask(
            taskDescription: 'Quick note', requiresMultiStep: true),
        equals(TaskComplexity.complex),
      );

      expect(
        NebiusClient.classifyTask(
            taskDescription: 'Automate tasks', toolCount: 6),
        equals(TaskComplexity.complex),
      );
    });

    test('custom model identifiers override defaults in smart router',
        () async {
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

      expect(client.resolveModel(complexity: TaskComplexity.complex),
          equals('custom/super-model'));
      expect(client.resolveModel(complexity: TaskComplexity.simple),
          equals('custom/nano-model'));
      expect(client.resolveModel(explicitModel: 'explicit/override'),
          equals('explicit/override'));

      final res = await client.chatCompletion(
        messages: [
          {'role': 'user', 'content': 'test'}
        ],
        complexity: TaskComplexity.complex,
      );
      expect(res, equals('ok'));
    });

    test(
        'inspectVisualFrame performs multimodal vision reasoning independently with Nemotron 3.5 Super VL',
        () async {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], equals('nvidia/Nemotron-3.5-Super-VL'));

        final messages = body['messages'] as List<dynamic>;
        expect(messages.first['role'], equals('user'));
        final content = messages.first['content'] as List<dynamic>;
        expect(content[0]['type'], equals('text'));
        expect(content[0]['text'], equals('Describe this screenshot'));
        expect(content[1]['type'], equals('image_url'));
        expect(content[1]['image_url']['url'],
            startsWith('data:image/jpeg;base64,'));

        return http.Response(
          '{"choices":[{"message":{"content":"A login screen with user/password fields."}}]}',
          200,
        );
      });

      final client = NebiusClient(apiKey: 'test_key', httpClient: mockClient);
      final dummyBytes =
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
      final analysis = await client.inspectVisualFrame(
        imageBytes: dummyBytes,
        prompt: 'Describe this screenshot',
      );

      expect(analysis, equals('A login screen with user/password fields.'));
    });
  });

  group('KeyVault Model Provider Decoupling Tests', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('Defaults active provider to nebius and allows switching', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final vault = KeyVault();

      expect(await vault.getActiveProvider(), equals('nebius'));

      await vault.setActiveProvider('google');
      expect(await vault.getActiveProvider(), equals('google'));

      await vault.setActiveProvider('auto');
      expect(await vault.getActiveProvider(), equals('auto'));

      await vault.setActiveProvider('nebius');
      expect(await vault.getActiveProvider(), equals('nebius'));
    });

    test(
        'hasRequiredKeys is independent of Google when active provider is nebius',
        () async {
      FlutterSecureStorage.setMockInitialValues({});
      final vault = KeyVault();
      await vault.setActiveProvider('nebius');

      // No keys set
      expect(await vault.hasRequiredKeys(), isFalse);

      // Only Nebius key set (zero Google keys or ADC)
      await vault.setNebiusApiKey('v1.mock_nebius_key');
      expect(await vault.hasRequiredKeys(), isTrue);

      // Even if Google API key is completely null and ADC is not set, Nebius is valid
      expect(await vault.getGeminiApiKey(), isNull);
      expect(await vault.hasRequiredKeys(), isTrue);
    });
  });
}
