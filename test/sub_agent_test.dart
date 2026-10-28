import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/agent/dartantic_agent.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';

void main() {
  group('SubAgent Tests', () {
    late LocalDatabase db;
    late SensitiveAppGuard guard;
    late ToolDispatcher dispatcher;
    late SubAgentManager manager;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sub_agent_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      guard = SensitiveAppGuard();
      dispatcher = ToolDispatcher(
        db: db,
        guard: guard,
      );
      manager = SubAgentManager(
        db: db,
        rootDispatcher: dispatcher,
      );
      dispatcher.setSubAgentManager(manager);
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Spawning sub-agent saves record and runs within constraints', () async {
      final res = await dispatcher.dispatch(
        toolName: 'spawn_agent',
        args: {
          'role': 'Health Inspector',
          'instructions': 'Check operating system health',
          'allowed_tools': ['system_status', 'remember', 'recall'],
          'max_steps': 5,
        },
      );

      expect(res['status'], equals('spawned'));
      expect(res.containsKey('agent_id'), isTrue);
      final agentId = res['agent_id'] as String;

      // Status check via dispatcher
      final statusRes = await dispatcher.dispatch(
        toolName: 'agent_status',
        args: {'agent_id': agentId},
      );
      expect(statusRes['status'], equals('found'));
      final agentData = statusRes['agent'] as Map<String, dynamic>;
      expect(agentData['role'], equals('Health Inspector'));
      expect(agentData['depth'], equals(1));
    });

    test('Rejects unrecognized tool names (deny-by-default)', () async {
      final res = await dispatcher.dispatch(
        toolName: 'spawn_agent',
        args: {
          'role': 'Malicious Agent',
          'instructions': 'Run untrusted exploits',
          'allowed_tools': ['non_existent_exploit_tool', 'system_status'],
        },
      );

      expect(res['status'], equals('rejected'));
      expect(res['error'], contains('not in the recognized tool registry'));
    });

    test('Enforces recursion depth limit <= 3', () async {
      final res = await dispatcher.dispatch(
        toolName: 'spawn_agent',
        args: {
          'role': 'Deep Agent',
          'instructions': 'Recurse beyond max depth',
          'allowed_tools': ['system_status'],
          'depth': 4,
        },
      );

      expect(res['status'], equals('rejected'));
      expect(res['error'], contains('depth limit exceeded'));
    });

    test('Listing, messaging, and cancelling sub-agents works as expected', () async {
      final spawnRes = await dispatcher.dispatch(
        toolName: 'spawn_agent',
        args: {
          'role': 'Data Analyzer',
          'instructions': 'Analyze state',
          'allowed_tools': ['system_status'],
        },
      );
      final agentId = spawnRes['agent_id'] as String;

      // List agents
      final listRes = await dispatcher.dispatch(
        toolName: 'list_agents',
        args: {},
      );
      expect(listRes['count'], greaterThanOrEqualTo(1));

      // Send message to agent
      final sendRes = await dispatcher.dispatch(
        toolName: 'send_to_agent',
        args: {'agent_id': agentId, 'message': 'Proceed with step 2'},
      );
      expect(sendRes['status'], equals('sent'));

      // Verify message in agent status
      final statusRes = await dispatcher.dispatch(
        toolName: 'agent_status',
        args: {'agent_id': agentId},
      );
      final messages = (statusRes['agent']['messages'] as List);
      expect(messages.length, equals(1));
      expect(messages.first['content'], equals('Proceed with step 2'));

      // Cancel agent
      final cancelRes = await dispatcher.dispatch(
        toolName: 'cancel_agent',
        args: {'agent_id': agentId},
      );
      expect(cancelRes['cancelled'], isTrue);

      final postCancel = db.getAgent(agentId);
      expect(postCancel!['status'], equals('cancelled'));
    });
  });
}
