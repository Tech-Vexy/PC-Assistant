import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/network/nebius_client.dart';
import 'package:device_assistant/core/network/pc_bridge_client.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';

void main() {
  group('PcBridgeClient Tests', () {
    test('checkHealth returns connected=true on 200 response', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/health'));
        expect(
            request.headers['X-Requested-With'], equals('pc-assistant-agent'));
        return http.Response(jsonEncode({'status': 'ok', 'uptime': 1234}), 200);
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final health = await bridge.checkHealth();

      expect(health['connected'], isTrue);
      expect(health['status'], equals('ok'));
      expect(health['data']['uptime'], equals(1234));
    });

    test('checkHealth returns connected=false on server error', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final health = await bridge.checkHealth();

      expect(health['connected'], isFalse);
      expect(health['status'], equals('http_500'));
    });

    test('delegateTool posts to /test-tool and returns result', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/test-tool'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['tool'], equals('media_control'));
        expect(body['args']['action'], equals('play'));

        return http.Response(
            jsonEncode({'status': 'success', 'executed': true}), 200);
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final res = await bridge.delegateTool(
        tool: 'media_control',
        args: {'action': 'play'},
      );

      expect(res['status'], equals('success'));
      expect(res['executed'], isTrue);
    });

    test('resolveApproval posts decision to endpoint', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/approvals/appr_123/decision'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['approved'], isTrue);
        return http.Response('{"ok":true}', 200);
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final success =
          await bridge.resolveApproval(approvalId: 'appr_123', approved: true);
      expect(success, isTrue);
    });

    test('fetchPendingApprovals returns list of approvals from /api/approvals',
        () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/approvals'));
        return http.Response(
          jsonEncode({
            'pending': [
              {
                'id': 'appr_abc123',
                'tool': 'terminal_execute',
                'args': {'command': 'reboot'},
                'createdAt': 123456789,
              }
            ]
          }),
          200,
        );
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final pending = await bridge.fetchPendingApprovals();
      expect(pending.length, equals(1));
      expect(pending.first['id'], equals('appr_abc123'));
      expect(pending.first['tool'], equals('terminal_execute'));
    });

    test('syncMemories pulls remote memories and stores in local database',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('sync_mem_test_');
      final db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);

      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/store/memory'));
        return http.Response(
          jsonEncode({
            'memories': [
              {
                'key': 'work_laptop',
                'value': 'ThinkPad X1',
                'category': 'hardware'
              },
              {
                'key': 'preferred_shell',
                'value': 'zsh',
                'category': 'preference'
              },
            ]
          }),
          200,
        );
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final syncRes = await bridge.syncMemories(db);

      expect(syncRes['status'], equals('success'));
      expect(syncRes['synced_count'], equals(2));

      // Verify stored in local database
      expect(db.recall('work_laptop'), equals('ThinkPad X1'));
      expect(db.recall('preferred_shell'), equals('zsh'));

      db.close();
      await tempDir.delete(recursive: true);
    });

    test('syncWorkflows pulls remote workflows and stores in local database',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('sync_wf_test_');
      final db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);

      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/store/workflows'));
        return http.Response(
          jsonEncode({
            'workflows': [
              {
                'name': 'daily_standup',
                'description': 'Opens notes and status',
                'steps': [
                  {'tool': 'system_status', 'args': {}}
                ]
              }
            ]
          }),
          200,
        );
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final syncRes = await bridge.syncWorkflows(db);

      expect(syncRes['status'], equals('success'));
      expect(syncRes['synced_count'], equals(1));

      final wf = db.getWorkflow('daily_standup');
      expect(wf, isNotNull);
      expect(wf!['name'], equals('daily_standup'));

      db.close();
      await tempDir.delete(recursive: true);
    });
  });

  group('ToolDispatcher PC Bridge & Web Search Integration Tests', () {
    late LocalDatabase db;
    late SensitiveAppGuard guard;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dispatcher_pc_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      guard = SensitiveAppGuard();
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'pc_status, sync_memories, sync_workflows, delegate_to_pc return not_configured when no bridge',
        () async {
      final dispatcher = ToolDispatcher(db: db, guard: guard);

      final statusRes =
          await dispatcher.dispatch(toolName: 'pc_status', args: {});
      expect(statusRes['status'], equals('not_configured'));

      final syncMemRes =
          await dispatcher.dispatch(toolName: 'sync_memories', args: {});
      expect(syncMemRes['status'], equals('error'));

      final syncWfRes =
          await dispatcher.dispatch(toolName: 'sync_workflows', args: {});
      expect(syncWfRes['status'], equals('error'));

      final delegRes = await dispatcher
          .dispatch(toolName: 'delegate_to_pc', args: {'tool': 'test'});
      expect(delegRes['status'], equals('error'));
    });

    test(
        'pc_status and delegate_to_pc execute through configured PcBridgeClient',
        () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/health') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.url.path == '/test-tool') {
          return http.Response('{"executed":true}', 200);
        }
        return http.Response('Not Found', 404);
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final dispatcher =
          ToolDispatcher(db: db, guard: guard, pcBridgeClient: bridge);

      final statusRes =
          await dispatcher.dispatch(toolName: 'pc_status', args: {});
      expect(statusRes['connected'], isTrue);

      final delegRes = await dispatcher.dispatch(
        toolName: 'delegate_to_pc',
        args: {
          'tool': 'open_app',
          'args': {'app': 'notepad'}
        },
      );
      expect(delegRes['executed'], isTrue);
    });

    test('web_search performs knowledge synthesis using NebiusClient',
        () async {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List;
        expect(messages.last['content'], equals('What is Flutter?'));

        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content':
                      'Flutter is an open-source UI software development kit created by Google.',
                }
              }
            ]
          }),
          200,
        );
      });

      final nebius = NebiusClient(apiKey: 'test-key', httpClient: mockClient);
      final dispatcher =
          ToolDispatcher(db: db, guard: guard, nebiusClient: nebius);

      final res = await dispatcher.dispatch(
        toolName: 'web_search',
        args: {'query': 'What is Flutter?'},
      );

      expect(res['status'], equals('success'));
      expect(res['answer'], contains('Flutter is an open-source UI'));
      expect(res['complexity'], equals('simple'));
      expect(res['model_used'], equals('nvidia/nemotron-3-nano'));
      expect(res['source'], contains('nemotron smart routing'));
    });
  });
}
