import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';

void main() {
  group('ToolDispatcher Tests', () {
    late LocalDatabase db;
    late SensitiveAppGuard guard;
    late ToolDispatcher dispatcher;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dispatcher_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      guard = SensitiveAppGuard();
      dispatcher = ToolDispatcher(
        db: db,
        guard: guard,
      );
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('system_status returns operating system metrics', () async {
      final res = await dispatcher.dispatch(
        toolName: 'system_status',
        args: {},
      );

      expect(res.containsKey('os'), isTrue);
      expect(res.containsKey('cores'), isTrue);
      expect(res['mode'], equals('unified_standalone_client'));
    });

    test(
        'Memory tools (remember, recall, list, forget, undo_last) work end-to-end',
        () async {
      // 1. Remember
      final remRes = await dispatcher.dispatch(
        toolName: 'remember',
        args: {
          'key': 'office_address',
          'value': '456 Tech Ave',
          'category': 'location'
        },
      );
      expect(remRes['status'], equals('saved'));

      // 2. Recall
      final recallRes = await dispatcher.dispatch(
        toolName: 'recall',
        args: {'key': 'office_address'},
      );
      expect(recallRes['found'], isTrue);
      expect(recallRes['value'], equals('456 Tech Ave'));

      // 3. List
      final listRes = await dispatcher.dispatch(
        toolName: 'list_memories',
        args: {'category': 'location'},
      );
      expect(listRes['count'], equals(1));

      // 4. Undo Last (reverts remember)
      final undoRes = await dispatcher.dispatch(
        toolName: 'undo_last',
        args: {},
      );
      expect(undoRes['status'], equals('undone'));
      expect(undoRes['tool'], equals('remember'));

      // Verify forgotten
      final afterUndo = await dispatcher.dispatch(
        toolName: 'recall',
        args: {'key': 'office_address'},
      );
      expect(afterUndo['found'], isFalse);
    });

    test('Workflow tools (save, list, run, delete) execute properly', () async {
      // Save workflow
      final saveRes = await dispatcher.dispatch(
        toolName: 'save_workflow',
        args: {
          'name': 'quick_health_check',
          'description': 'Performs system status check',
          'steps': [
            {'tool': 'system_status', 'args': <String, dynamic>{}},
          ],
        },
      );
      expect(saveRes['status'], equals('saved'));

      // List workflows
      final listRes = await dispatcher.dispatch(
        toolName: 'list_workflows',
        args: {},
      );
      expect(listRes['count'], equals(1));

      // Run workflow
      final runRes = await dispatcher.dispatch(
        toolName: 'run_workflow',
        args: {'name': 'quick_health_check'},
      );
      expect(runRes['status'], equals('completed'));
      expect((runRes['results'] as List).length, equals(1));

      // Delete workflow
      final delRes = await dispatcher.dispatch(
        toolName: 'delete_workflow',
        args: {'name': 'quick_health_check'},
      );
      expect(delRes['status'], equals('deleted'));
    });

    test('Plan execution runs steps and updates plan status', () async {
      // Create plan directly in DB
      db.savePlan(
        planId: 'plan_test_1',
        goal: 'Run health check',
        steps: [
          {
            'step_id': 1,
            'tool': 'system_status',
            'args': <String, dynamic>{},
            'purpose': 'Check OS health',
          }
        ],
        status: 'planned',
      );

      final execRes = await dispatcher.dispatch(
        toolName: 'execute_plan',
        args: {'plan_id': 'plan_test_1'},
      );

      expect(execRes['status'], equals('completed'));
      expect(execRes['steps_executed'], equals(1));

      final plan = db.getPlan('plan_test_1');
      expect(plan!['status'], equals('completed'));
    });

    test('SensitiveAppGuard blocks access to sensitive packages', () async {
      // SIM Toolkit app open
      final stkRes = await dispatcher.dispatch(
        toolName: 'open_application',
        args: {'app_name': 'com.android.stk'},
      );
      expect(stkRes['status'], equals('blocked'));
      expect(stkRes['security_alert'], contains('SIM Toolkit'));

      // FinTech app open
      final bankRes = await dispatcher.dispatch(
        toolName: 'open_application',
        args: {'app_name': 'com.revolut.revolut'},
      );
      expect(bankRes['status'], equals('blocked'));
      expect(bankRes['security_alert'], contains('blacklist'));

      // Sensitive app check using package_name parameter
      final pkgRes = await dispatcher.dispatch(
        toolName: 'open_application',
        args: {'package_name': 'com.android.stk'},
      );
      expect(pkgRes['status'], equals('blocked'));
      expect(pkgRes['security_alert'], contains('SIM Toolkit'));
    });

    test('list_installed_apps handles non-Android platform gracefully',
        () async {
      final res = await dispatcher.dispatch(
        toolName: 'list_installed_apps',
        args: {'filter': 'chrome'},
      );
      if (!Platform.isAndroid) {
        expect(res['status'], equals('error'));
        expect(res['error'], contains('only available on Android'));
      }
    });

    test('capture_screen respects SensitiveAppGuard', () async {
      final guardedDispatcher = ToolDispatcher(
        db: db,
        guard: guard,
        activePackageName: 'com.android.stk',
      );

      final blockedRes = await guardedDispatcher.dispatch(
        toolName: 'capture_screen',
        args: {},
      );

      expect(blockedRes['status'], equals('blocked'));
      expect(blockedRes['security_alert'], contains('SIM Toolkit'));
    });
  });
}
