import 'dart:async';
import 'dart:math';
import '../database/local_database.dart';
import '../../features/tools/tool_dispatcher.dart';

/// Service that automates recurring and scheduled procedural workflows,
/// periodically evaluating due routines and executing them through `ToolDispatcher`.
class WorkflowSchedulerService {
  final LocalDatabase _database;
  final ToolDispatcher _dispatcher;
  Timer? _ticker;
  bool _isRunning = false;

  final _executionController =
      StreamController<Map<String, dynamic>>.broadcast();

  WorkflowSchedulerService({
    required LocalDatabase database,
    required ToolDispatcher dispatcher,
  })  : _database = database,
        _dispatcher = dispatcher;

  bool get isRunning => _isRunning;
  Stream<Map<String, dynamic>> get executionStream =>
      _executionController.stream;

  /// Starts the scheduler tick loop (evaluates every 5 seconds)
  void start({Duration interval = const Duration(seconds: 5)}) {
    if (_isRunning) return;
    _isRunning = true;
    _ticker = Timer.periodic(interval, (_) => checkAndExecuteDueWorkflows());
  }

  /// Stops the scheduler tick loop
  void stop() {
    _ticker?.cancel();
    _ticker = null;
    _isRunning = false;
  }

  /// Schedules a saved workflow to run periodically every `intervalSeconds`
  String scheduleWorkflow({
    required String workflowName,
    required int intervalSeconds,
    String? customId,
    int? firstRunDelaySeconds,
  }) {
    final workflow = _database.getWorkflow(workflowName);
    if (workflow == null) {
      throw ArgumentError(
          'Workflow "$workflowName" does not exist in database.');
    }

    final id = customId ?? 'sched_${workflowName}_${Random().nextInt(999999)}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final delay = (firstRunDelaySeconds ?? intervalSeconds) * 1000;
    final nextRunAt = now + delay;

    _database.saveScheduledWorkflow(
      id: id,
      workflowName: workflowName,
      intervalSeconds: max(10, intervalSeconds),
      nextRunAt: nextRunAt,
    );

    return id;
  }

  /// Cancels an existing scheduled workflow
  bool cancelSchedule(String id) {
    return _database.deleteScheduledWorkflow(id);
  }

  /// Lists all active and scheduled workflows
  List<Map<String, dynamic>> listSchedules() {
    return _database.listScheduledWorkflows();
  }

  /// Evaluates all scheduled workflows and executes any that are due
  Future<List<Map<String, dynamic>>> checkAndExecuteDueWorkflows() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final schedules = _database.listScheduledWorkflows();
    final results = <Map<String, dynamic>>[];

    for (final sched in schedules) {
      final isActive = (sched['is_active'] as num?)?.toInt() == 1;
      final nextRunAt = (sched['next_run_at'] as num?)?.toInt() ?? 0;
      final id = sched['id'] as String;
      final workflowName = sched['workflow_name'] as String;
      final intervalSec = (sched['interval_seconds'] as num?)?.toInt() ?? 60;

      if (isActive && nextRunAt <= now) {
        // Execute workflow via dispatcher
        String status = 'success';
        Map<String, dynamic> execResult = {};
        try {
          execResult = await _dispatcher.dispatch(
            toolName: 'run_workflow',
            args: {'name': workflowName},
          );
          if (execResult['status'] == 'error' ||
              execResult['success'] == false) {
            status = 'failed';
          }
        } catch (e) {
          status = 'error';
          execResult = {'status': 'error', 'error': e.toString()};
        }

        final nextRun = now + (intervalSec * 1000);
        _database.updateScheduledWorkflowRun(
          id: id,
          lastRunAt: now,
          nextRunAt: nextRun,
          lastStatus: status,
        );

        final event = {
          'id': id,
          'workflow': workflowName,
          'status': status,
          'result': execResult,
          'executed_at': now,
          'next_run_at': nextRun,
        };

        _executionController.add(event);
        results.add(event);
      }
    }

    return results;
  }

  /// Manually triggers an immediate execution of a scheduled workflow
  Future<Map<String, dynamic>> triggerNow(String id) async {
    final sched = _database.getScheduledWorkflow(id);
    if (sched == null) {
      return {'status': 'error', 'error': 'Schedule "$id" not found'};
    }

    final workflowName = sched['workflow_name'] as String;
    final intervalSec = (sched['interval_seconds'] as num?)?.toInt() ?? 60;
    final now = DateTime.now().millisecondsSinceEpoch;

    final execResult = await _dispatcher.dispatch(
      toolName: 'run_workflow',
      args: {'name': workflowName},
    );

    final status = execResult['status'] == 'error' ? 'failed' : 'success';
    final nextRun = now + (intervalSec * 1000);

    _database.updateScheduledWorkflowRun(
      id: id,
      lastRunAt: now,
      nextRunAt: nextRun,
      lastStatus: status,
    );

    return {
      'status': 'success',
      'id': id,
      'workflow': workflowName,
      'result': execResult,
      'executed_at': now,
    };
  }

  void dispose() {
    stop();
    _executionController.close();
  }
}
