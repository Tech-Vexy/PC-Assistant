import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/core/workflow/workflow_scheduler_service.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';

void main() {
  late Directory tempDir;
  late LocalDatabase db;
  late SensitiveAppGuard guard;
  late ToolDispatcher dispatcher;
  late WorkflowSchedulerService scheduler;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sched_test_');
    db = LocalDatabase();
    await db.initialize(baseDirectory: tempDir);
    guard = SensitiveAppGuard();
    dispatcher = ToolDispatcher(db: db, guard: guard);
    scheduler = WorkflowSchedulerService(database: db, dispatcher: dispatcher);
  });

  tearDown(() async {
    scheduler.dispose();
    db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('WorkflowSchedulerService Tests', () {
    test('schedules workflow, lists schedules, and cancels schedule', () {
      // Save a sample workflow first
      db.saveWorkflow(
        'morning_check',
        description: 'Check battery and storage',
        steps: [
          {'tool': 'system_status', 'args': {}},
        ],
      );

      final schedId = scheduler.scheduleWorkflow(
        workflowName: 'morning_check',
        intervalSeconds: 300,
        customId: 'test_sched_1',
      );

      expect(schedId, equals('test_sched_1'));

      final list = scheduler.listSchedules();
      expect(list.length, equals(1));
      expect(list.first['id'], equals('test_sched_1'));
      expect(list.first['workflow_name'], equals('morning_check'));
      expect(list.first['interval_seconds'], equals(300));

      final cancelled = scheduler.cancelSchedule('test_sched_1');
      expect(cancelled, isTrue);
      expect(scheduler.listSchedules().isEmpty, isTrue);
    });

    test(
        'checkAndExecuteDueWorkflows executes due workflows and updates next_run_at',
        () async {
      db.saveWorkflow(
        'test_routine',
        description: 'Test routine',
        steps: [
          {'tool': 'system_status', 'args': {}},
        ],
      );

      // Schedule with 0 delay (immediately due)
      scheduler.scheduleWorkflow(
        workflowName: 'test_routine',
        intervalSeconds: 60,
        customId: 'due_sched',
        firstRunDelaySeconds: 0,
      );

      final executed = await scheduler.checkAndExecuteDueWorkflows();
      expect(executed.length, equals(1));
      expect(executed.first['workflow'], equals('test_routine'));
      expect(executed.first['status'], equals('success'));

      // Check updated schedule
      final updated = db.getScheduledWorkflow('due_sched');
      expect(updated, isNotNull);
      expect(updated!['last_status'], equals('success'));
      expect(updated['last_run_at'], isNotNull);
      expect(updated['next_run_at'], greaterThan(updated['last_run_at']));
    });

    test(
        'ToolDispatcher dispatches schedule_workflow, list_scheduled_workflows, cancel_scheduled_workflow',
        () async {
      db.saveWorkflow(
        'auto_backup',
        description: 'Backup routine',
        steps: [
          {'tool': 'system_status', 'args': {}},
        ],
      );

      final schedRes = await dispatcher.dispatch(
        toolName: 'schedule_workflow',
        args: {
          'workflow_name': 'auto_backup',
          'interval_seconds': 120,
        },
      );

      expect(schedRes['status'], equals('scheduled'));
      final scheduleId = schedRes['schedule_id'] as String;

      final listRes = await dispatcher.dispatch(
        toolName: 'list_scheduled_workflows',
        args: {},
      );

      expect(listRes['count'], equals(1));

      final cancelRes = await dispatcher.dispatch(
        toolName: 'cancel_scheduled_workflow',
        args: {'schedule_id': scheduleId},
      );

      expect(cancelRes['status'], equals('cancelled'));
    });
  });
}
