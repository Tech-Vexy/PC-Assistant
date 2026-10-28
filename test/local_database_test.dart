import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/database/local_database.dart';

void main() {
  group('LocalDatabase Tests', () {
    late LocalDatabase db;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('assistant_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Memory CRUD operations work properly', () {
      expect(db.recall('fav_color'), isNull);

      db.remember('fav_color', 'blue', category: 'preference');
      expect(db.recall('fav_color'), equals('blue'));

      final list = db.listMemories();
      expect(list.length, equals(1));
      expect(list.first['key'], equals('fav_color'));
      expect(list.first['category'], equals('preference'));

      // Update
      db.remember('fav_color', 'dark_indigo', category: 'preference');
      expect(db.recall('fav_color'), equals('dark_indigo'));

      // Delete
      final deleted = db.forget('fav_color');
      expect(deleted, isTrue);
      expect(db.recall('fav_color'), isNull);
    });

    test('Workflow CRUD operations work properly', () {
      final steps = [
        {'tool': 'system_status', 'args': <String, dynamic>{}},
        {'tool': 'recall', 'args': {'key': 'test_key'}},
      ];

      db.saveWorkflow('test_wf', description: 'Test Routine', steps: steps);

      final wf = db.getWorkflow('test_wf');
      expect(wf, isNotNull);
      expect(wf!['name'], equals('test_wf'));
      expect(wf['description'], equals('Test Routine'));
      expect((wf['steps'] as List).length, equals(2));

      final all = db.listWorkflows();
      expect(all.length, equals(1));

      final deleted = db.deleteWorkflow('test_wf');
      expect(deleted, isTrue);
      expect(db.getWorkflow('test_wf'), isNull);
    });

    test('Plan CRUD operations work properly', () {
      final steps = [
        {
          'step_id': 1,
          'tool': 'open_application',
          'args': {'app_name': 'Settings'},
          'purpose': 'Open settings',
        }
      ];

      db.savePlan(
        planId: 'plan_123',
        goal: 'Open settings and inspect',
        steps: steps,
        status: 'planned',
      );

      var plan = db.getPlan('plan_123');
      expect(plan, isNotNull);
      expect(plan!['status'], equals('planned'));
      expect((plan['steps'] as List).length, equals(1));

      db.updatePlanStatus('plan_123', 'completed');
      plan = db.getPlan('plan_123');
      expect(plan!['status'], equals('completed'));

      final plans = db.listPlans();
      expect(plans.length, equals(1));
    });

    test('Undo journal records and marks applied properly', () {
      final undoId = db.recordUndo(
        toolName: 'remember',
        description: 'Test Remember',
        reversalData: {'action': 'delete', 'key': 'test_key'},
      );
      expect(undoId, isNonZero);

      final pending = db.getLatestPendingUndo();
      expect(pending, isNotNull);
      expect(pending!['id'], equals(undoId));
      expect(pending['applied'], equals(0));

      db.markUndoApplied(undoId);
      final nextPending = db.getLatestPendingUndo();
      expect(nextPending, isNull);
    });

    test('Audit logs capture execution and blocked events', () {
      db.logAudit(
        toolName: 'system_status',
        args: {'test': true},
        result: {'status': 'ok'},
      );

      db.logAudit(
        toolName: 'open_application',
        args: {'app_name': 'com.android.stk'},
        isBlocked: true,
        blockReason: 'SIM Toolkit protected',
      );

      final audits = db.getRecentAudits();
      expect(audits.length, equals(2));
      expect(audits.first['is_blocked'], equals(1));
      expect(audits.first['block_reason'], contains('SIM Toolkit'));
    });

    test('Custom protected packages persist correctly', () {
      expect(db.loadCustomProtectedPackages(), isEmpty);

      db.saveProtectedPackage('com.mycustom.vault');
      expect(db.loadCustomProtectedPackages(), contains('com.mycustom.vault'));

      db.removeProtectedPackage('com.mycustom.vault');
      expect(db.loadCustomProtectedPackages(), isEmpty);
    });

    test('Sub-agent CRUD and message operations persist properly', () {
      db.saveAgent(
        agentId: 'agent_db_test_1',
        role: 'Test Agent',
        instructions: 'Test Instructions',
        allowedTools: ['system_status', 'remember'],
        depth: 1,
        maxSteps: 8,
      );

      var agent = db.getAgent('agent_db_test_1');
      expect(agent, isNotNull);
      expect(agent!['role'], equals('Test Agent'));
      expect(agent['status'], equals('idle'));
      expect((agent['allowed_tools'] as List).length, equals(2));

      db.updateAgentStatus('agent_db_test_1', 'running', stepsTaken: 3);
      agent = db.getAgent('agent_db_test_1');
      expect(agent!['status'], equals('running'));
      expect(agent['steps_taken'], equals(3));

      db.addAgentMessage('agent_db_test_1', 'user', 'Check status');
      final msgs = db.getAgentMessages('agent_db_test_1');
      expect(msgs.length, equals(1));
      expect(msgs.first['content'], equals('Check status'));

      final list = db.listAgents();
      expect(list.length, equals(1));

      final cancelled = db.cancelAgent('agent_db_test_1');
      expect(cancelled, isTrue);
      agent = db.getAgent('agent_db_test_1');
      expect(agent!['status'], equals('cancelled'));
    });
  });
}
