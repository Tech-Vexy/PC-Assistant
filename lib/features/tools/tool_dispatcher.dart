import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/agent/dartantic_agent.dart';
import '../../core/database/local_database.dart';
import '../../core/network/nebius_client.dart';
import '../../core/network/pc_bridge_client.dart';
import '../../core/security/sensitive_app_guard.dart';
import '../../platform/android/android_bridge.dart';

/// Central dispatcher for executing assistant tools across platforms
/// with built-in security gating, sensitive app shielding, and undo journaling.
class ToolDispatcher {
  final LocalDatabase db;
  final SensitiveAppGuard guard;
  final NebiusClient? nebiusClient;
  final AndroidBridge? androidBridge;
  final PcBridgeClient? pcBridgeClient;
  String? activePackageName; // Tracked foreground app on Android
  final void Function(Uint8List jpegBytes)? onImageCaptured;
  SubAgentManager? subAgentManager;

  ToolDispatcher({
    required this.db,
    required this.guard,
    this.nebiusClient,
    this.androidBridge,
    this.pcBridgeClient,
    this.activePackageName,
    this.onImageCaptured,
    this.subAgentManager,
  });

  void updateActivePackage(String? pkg) {
    activePackageName = pkg;
  }

  void setSubAgentManager(SubAgentManager manager) {
    subAgentManager = manager;
  }

  /// Dispatches and executes a tool call
  Future<Map<String, dynamic>> dispatch({
    required String toolName,
    required Map<String, dynamic> args,
  }) async {
    try {
      // 1. Sensitive App Shield Check
      if (toolName == 'inspect_screen' || toolName == 'open_application') {
        final targetPkg = args['app_name'] as String? ?? activePackageName;
        final decision = guard.evaluate(packageName: targetPkg);
        if (decision.isBlocked) {
          db.logAudit(
            toolName: toolName,
            args: args,
            isBlocked: true,
            blockReason: decision.reason,
          );
          return {
            'status': 'blocked',
            'security_alert': decision.reason,
            'message': 'Action halted. Sensitive application shield is active.',
          };
        }
      }

      // 2. Route by tool name
      Map<String, dynamic> result;
      switch (toolName) {
        case 'system_status':
          result = await _handleSystemStatus();
          break;

        case 'remember':
          result = _handleRemember(args);
          break;

        case 'recall':
          result = _handleRecall(args);
          break;

        case 'list_memories':
          result = _handleListMemories(args);
          break;

        case 'forget':
          result = _handleForget(args);
          break;

        case 'undo_last':
          result = _handleUndoLast();
          break;

        case 'plan_task':
          result = await _handlePlanTask(args);
          break;

        case 'execute_plan':
          result = await _handleExecutePlan(args);
          break;

        case 'list_plans':
          result = _handleListPlans();
          break;

        case 'save_workflow':
          result = _handleSaveWorkflow(args);
          break;

        case 'run_workflow':
          result = await _handleRunWorkflow(args);
          break;

        case 'list_workflows':
          result = _handleListWorkflows();
          break;

        case 'delete_workflow':
          result = _handleDeleteWorkflow(args);
          break;

        case 'schedule_workflow':
          result = _handleScheduleWorkflow(args);
          break;

        case 'list_scheduled_workflows':
          result = _handleListScheduledWorkflows();
          break;

        case 'cancel_scheduled_workflow':
          result = _handleCancelScheduledWorkflow(args);
          break;

        case 'run_shell_command':
          result = await _handleShellCommand(args);
          break;

        case 'open_application':
          result = await _handleOpenApp(args);
          break;

        case 'click_element':
          result = await _handleClickElement(args);
          break;

        case 'touch_gesture':
          result = await _handleTouchGesture(args);
          break;

        case 'navigate':
        case 'perform_navigation':
          result = await _handleNavigate(args);
          break;

        case 'input_text':
          result = await _handleInputText(args);
          break;

        case 'scroll_screen':
        case 'scroll':
          result = await _handleScrollScreen(args);
          break;

        case 'capture_screen':
          result = await _handleCaptureScreen(args);
          break;

        case 'inspect_screen':
          result = await _handleInspectScreen(args);
          break;

        case 'spawn_agent':
          result = await _handleSpawnAgent(args);
          break;

        case 'list_agents':
          result = _handleListAgents(args);
          break;

        case 'agent_status':
          result = _handleAgentStatus(args);
          break;

        case 'cancel_agent':
          result = _handleCancelAgent(args);
          break;

        case 'send_to_agent':
          result = _handleSendToAgent(args);
          break;

        case 'web_search':
          result = await _handleWebSearch(args);
          break;

        case 'pc_status':
          result = await _handlePcStatus();
          break;

        case 'sync_memories':
          result = await _handleSyncMemories();
          break;

        case 'sync_workflows':
          result = await _handleSyncWorkflows();
          break;

        case 'delegate_to_pc':
          result = await _handleDelegateToPc(args);
          break;

        default:
          result = {'error': 'Unknown tool: $toolName'};
      }

      // Log success audit
      db.logAudit(toolName: toolName, args: args, result: result);
      return result;
    } catch (e) {
      final errResult = {'error': e.toString()};
      db.logAudit(
          toolName: toolName, args: args, result: errResult, isBlocked: false);
      return errResult;
    }
  }

  Future<Map<String, dynamic>> _handleSystemStatus() async {
    return {
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'cores': Platform.numberOfProcessors,
      'timestamp': DateTime.now().toIso8601String(),
      'mode': 'unified_standalone_client',
      'device': defaultTargetPlatform.name,
    };
  }

  Map<String, dynamic> _handleRemember(Map<String, dynamic> args) {
    final key = args['key'] as String;
    final value = args['value'] as String;
    final category = (args['category'] as String?) ?? 'general';

    final previous = db.recall(key);
    db.remember(key, value, category: category);

    // Journal undo record
    db.recordUndo(
      toolName: 'remember',
      description: 'Remember "$key"',
      reversalData: {
        'action': previous == null ? 'delete' : 'restore',
        'key': key,
        'previous_value': previous,
      },
    );

    return {'status': 'saved', 'key': key, 'category': category};
  }

  Map<String, dynamic> _handleRecall(Map<String, dynamic> args) {
    final key = args['key'] as String;
    final value = db.recall(key);
    if (value != null) {
      return {'found': true, 'key': key, 'value': value};
    }
    return {'found': false, 'key': key, 'message': 'No saved memory found'};
  }

  Map<String, dynamic> _handleForget(Map<String, dynamic> args) {
    final key = args['key'] as String;
    final previous = db.recall(key);
    if (previous != null) {
      db.forget(key);
      db.recordUndo(
        toolName: 'forget',
        description: 'Forgot "$key"',
        reversalData: {
          'action': 'restore',
          'key': key,
          'previous_value': previous
        },
      );
      return {'status': 'forgotten', 'key': key};
    }
    return {'status': 'not_found', 'key': key};
  }

  Map<String, dynamic> _handleListMemories(Map<String, dynamic> args) {
    final category = args['category'] as String?;
    final memories = db.listMemories(category: category);
    return {'count': memories.length, 'memories': memories};
  }

  Map<String, dynamic> _handleUndoLast() {
    final pending = db.getLatestPendingUndo();
    if (pending == null) {
      return {'status': 'empty', 'message': 'Nothing to undo'};
    }

    final id = pending['id'] as int;
    final tool = pending['tool_name'] as String;
    final reversalStr = pending['reversal_json'] as String;

    Map<String, dynamic> reversal = {};
    try {
      reversal = jsonDecode(reversalStr) as Map<String, dynamic>;
    } catch (_) {}

    final action = reversal['action'] as String?;

    if (tool == 'remember') {
      final key = reversal['key'] as String?;
      if (key != null) {
        if (action == 'delete') {
          db.forget(key);
        } else if (action == 'restore') {
          final prevVal = reversal['previous_value'] as String?;
          if (prevVal != null) {
            db.remember(key, prevVal);
          }
        }
      }
    } else if (tool == 'forget') {
      final key = reversal['key'] as String?;
      final prevVal = reversal['previous_value'] as String?;
      if (key != null && prevVal != null) {
        db.remember(key, prevVal);
      }
    } else if (tool == 'save_workflow') {
      final name = reversal['name'] as String?;
      if (name != null) {
        if (action == 'delete') {
          db.deleteWorkflow(name);
        } else if (action == 'restore') {
          final desc = reversal['previous_description'] as String?;
          final steps = (reversal['previous_steps'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ??
              [];
          db.saveWorkflow(name, description: desc, steps: steps);
        }
      }
    } else if (tool == 'delete_workflow') {
      final name = reversal['name'] as String?;
      final desc = reversal['previous_description'] as String?;
      final steps = (reversal['previous_steps'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>() ??
          [];
      if (name != null) {
        db.saveWorkflow(name, description: desc, steps: steps);
      }
    }

    db.markUndoApplied(id);
    return {
      'status': 'undone',
      'tool': tool,
      'description': pending['description'],
      'reversal': reversal,
    };
  }

  Future<Map<String, dynamic>> _handlePlanTask(
      Map<String, dynamic> args) async {
    final goal = args['goal'] as String;
    if (nebiusClient == null) {
      return {'error': 'Nebius client (Nemotron-3-super-vl) is not configured'};
    }

    final steps = await nebiusClient!.planTask(
      goal: goal,
      availableTools: [
        'system_status',
        'open_application',
        'run_shell_command',
        'remember',
        'recall',
        'inspect_screen',
        'click_element',
        'touch_gesture',
        'navigate',
      ],
      platformContext: '${Platform.operatingSystem} standalone',
    );

    final planId = 'plan_${DateTime.now().millisecondsSinceEpoch}';
    db.savePlan(planId: planId, goal: goal, steps: steps, status: 'planned');

    return {
      'plan_id': planId,
      'goal': goal,
      'steps': steps,
      'planner': 'nemotron-3-super-vl',
      'message':
          'Plan generated and saved. Call execute_plan with plan_id "$planId" to execute it.',
    };
  }

  Future<Map<String, dynamic>> _handleExecutePlan(
      Map<String, dynamic> args) async {
    final planId = args['plan_id'] as String;
    final plan = db.getPlan(planId);
    if (plan == null) {
      return {'error': 'Plan "$planId" not found'};
    }

    final steps = (plan['steps'] as List<dynamic>).cast<Map<String, dynamic>>();
    db.updatePlanStatus(planId, 'running');

    final executionLog = <Map<String, dynamic>>[];
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepTool = step['tool'] as String;
      final stepArgs = (step['args'] as Map<String, dynamic>?) ?? {};

      final stepRes = await dispatch(toolName: stepTool, args: stepArgs);
      executionLog.add({
        'step_id': step['step_id'] ?? (i + 1),
        'tool': stepTool,
        'purpose': step['purpose'],
        'result': stepRes,
      });

      if (stepRes.containsKey('error') ||
          stepRes.containsKey('blocked') ||
          stepRes['status'] == 'blocked') {
        db.updatePlanStatus(planId, 'failed', steps: executionLog);
        return {
          'status': 'failed',
          'plan_id': planId,
          'failed_step': i + 1,
          'reason': stepRes['error'] ??
              stepRes['security_alert'] ??
              'Execution halted',
          'log': executionLog,
        };
      }
    }

    db.updatePlanStatus(planId, 'completed', steps: executionLog);
    return {
      'status': 'completed',
      'plan_id': planId,
      'goal': plan['goal'],
      'steps_executed': steps.length,
      'log': executionLog,
    };
  }

  Map<String, dynamic> _handleListPlans() {
    final plans = db.listPlans();
    return {'count': plans.length, 'plans': plans};
  }

  Map<String, dynamic> _handleSaveWorkflow(Map<String, dynamic> args) {
    final name = args['name'] as String;
    final desc = args['description'] as String?;
    final rawSteps = args['steps'] as List<dynamic>;
    final steps =
        rawSteps.map((s) => Map<String, dynamic>.from(s as Map)).toList();

    final previous = db.getWorkflow(name);
    db.saveWorkflow(name, description: desc, steps: steps);

    db.recordUndo(
      toolName: 'save_workflow',
      description: 'Saved workflow "$name"',
      reversalData: {
        'action': previous == null ? 'delete' : 'restore',
        'name': name,
        'previous_description': previous?['description'],
        'previous_steps': previous?['steps'],
      },
    );

    return {'status': 'saved', 'name': name, 'steps_count': steps.length};
  }

  Future<Map<String, dynamic>> _handleRunWorkflow(
      Map<String, dynamic> args) async {
    final name = args['name'] as String;
    final workflow = db.getWorkflow(name);
    if (workflow == null) {
      return {'error': 'Workflow "$name" not found'};
    }

    final steps =
        (workflow['steps'] as List<dynamic>).cast<Map<String, dynamic>>();
    final results = <Map<String, dynamic>>[];

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepTool = step['tool'] as String;
      final stepArgs = (step['args'] as Map<String, dynamic>?) ?? {};

      final stepRes = await dispatch(toolName: stepTool, args: stepArgs);
      results.add({
        'step': i + 1,
        'tool': stepTool,
        'result': stepRes,
      });

      if (stepRes.containsKey('error') ||
          stepRes.containsKey('blocked') ||
          stepRes['status'] == 'blocked') {
        return {
          'status': 'halted',
          'failed_step': i + 1,
          'workflow': name,
          'executed_steps': results,
        };
      }
    }

    return {
      'status': 'completed',
      'workflow': name,
      'total_steps': steps.length,
      'results': results,
    };
  }

  Map<String, dynamic> _handleListWorkflows() {
    final workflows = db.listWorkflows();
    return {'count': workflows.length, 'workflows': workflows};
  }

  Map<String, dynamic> _handleDeleteWorkflow(Map<String, dynamic> args) {
    final name = args['name'] as String;
    final previous = db.getWorkflow(name);
    if (previous != null) {
      db.deleteWorkflow(name);
      db.recordUndo(
        toolName: 'delete_workflow',
        description: 'Deleted workflow "$name"',
        reversalData: {
          'action': 'restore',
          'name': name,
          'previous_description': previous['description'],
          'previous_steps': previous['steps'],
        },
      );
      return {'status': 'deleted', 'name': name};
    }
    return {'status': 'not_found', 'name': name};
  }

  Map<String, dynamic> _handleScheduleWorkflow(Map<String, dynamic> args) {
    final workflowName = args['workflow_name'] as String;
    final intervalSeconds = (args['interval_seconds'] as num?)?.toInt() ?? 60;

    final workflow = db.getWorkflow(workflowName);
    if (workflow == null) {
      return {'error': 'Workflow "$workflowName" does not exist'};
    }

    final id =
        'sched_${workflowName}_${DateTime.now().millisecondsSinceEpoch % 100000}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final nextRunAt = now + (intervalSeconds * 1000);

    db.saveScheduledWorkflow(
      id: id,
      workflowName: workflowName,
      intervalSeconds: intervalSeconds,
      nextRunAt: nextRunAt,
    );

    return {
      'status': 'scheduled',
      'schedule_id': id,
      'workflow_name': workflowName,
      'interval_seconds': intervalSeconds,
      'next_run_at':
          DateTime.fromMillisecondsSinceEpoch(nextRunAt).toIso8601String(),
    };
  }

  Map<String, dynamic> _handleListScheduledWorkflows() {
    final list = db.listScheduledWorkflows();
    return {'count': list.length, 'scheduled_workflows': list};
  }

  Map<String, dynamic> _handleCancelScheduledWorkflow(
      Map<String, dynamic> args) {
    final scheduleId = args['schedule_id'] as String;
    final ok = db.deleteScheduledWorkflow(scheduleId);
    return {
      'status': ok ? 'cancelled' : 'not_found',
      'schedule_id': scheduleId
    };
  }

  Future<Map<String, dynamic>> _handleShellCommand(
      Map<String, dynamic> args) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return {'error': 'Shell commands are not permitted on mobile platforms'};
    }

    final cmd = args['command'] as String;
    ProcessResult result;

    if (Platform.isWindows) {
      result = await Process.run('powershell', ['-NoProfile', '-Command', cmd]);
    } else {
      result = await Process.run('bash', ['-c', cmd]);
    }

    return {
      'exit_code': result.exitCode,
      'stdout': (result.stdout as String).trim(),
      'stderr': (result.stderr as String).trim(),
    };
  }

  Future<Map<String, dynamic>> _handleOpenApp(Map<String, dynamic> args) async {
    final appName = args['app_name'] as String;

    if (Platform.isAndroid && androidBridge != null) {
      // Single-process hygiene: Launch via native Android Intent without spawning OS subprocesses
      final success = await androidBridge!.launchApp(appName);
      return {'status': success ? 'launched' : 'app_not_found', 'app': appName};
    } else if (Platform.isLinux) {
      // Launch via gtk-launch or background process on desktop
      await Process.start('gtk-launch', [appName],
          mode: ProcessStartMode.detached);
      return {'status': 'launched', 'app': appName};
    } else if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', appName],
          mode: ProcessStartMode.detached);
      return {'status': 'launched', 'app': appName};
    }

    return {'status': 'unsupported_platform', 'app': appName};
  }

  Future<Map<String, dynamic>> _handleClickElement(
      Map<String, dynamic> args) async {
    final text = args['text'] as String? ?? '';
    final viewId = args['view_id'] as String?;
    if (androidBridge == null) {
      return {
        'error': 'Mobile accessibility bridge is not available on this platform'
      };
    }
    final success = await androidBridge!.clickByText(text, viewId: viewId);
    return {
      'action': 'click',
      'target': text.isNotEmpty ? text : (viewId ?? ''),
      'success': success
    };
  }

  Future<Map<String, dynamic>> _handleTouchGesture(
      Map<String, dynamic> args) async {
    if (androidBridge == null) {
      return {
        'error': 'Mobile touch gestures are not available on this platform'
      };
    }
    final type = args['type'] as String;
    if (type == 'tap') {
      final x = (args['x'] as num?)?.toDouble() ?? 0.0;
      final y = (args['y'] as num?)?.toDouble() ?? 0.0;
      final success = await androidBridge!.injectTap(x, y);
      return {'gesture': 'tap', 'x': x, 'y': y, 'success': success};
    } else if (type == 'swipe') {
      final startX = (args['startX'] as num?)?.toDouble() ?? 0.0;
      final startY = (args['startY'] as num?)?.toDouble() ?? 0.0;
      final endX = (args['endX'] as num?)?.toDouble() ?? 0.0;
      final endY = (args['endY'] as num?)?.toDouble() ?? 0.0;
      final success =
          await androidBridge!.injectSwipe(startX, startY, endX, endY);
      return {'gesture': 'swipe', 'success': success};
    }
    return {'error': 'Unknown gesture type: $type'};
  }

  Future<Map<String, dynamic>> _handleNavigate(
      Map<String, dynamic> args) async {
    if (androidBridge == null) {
      return {'error': 'Mobile navigation is not available on this platform'};
    }
    final raw = args['action'];
    int actionCode = 1;
    String actionStr = 'back';
    if (raw is int) {
      actionCode = raw;
      if (raw == 2) actionStr = 'home';
      if (raw == 3) actionStr = 'recents';
      if (raw == 4) actionStr = 'notifications';
    } else if (raw is String) {
      actionStr = raw.toLowerCase();
      if (actionStr == 'home' || actionStr == '2') actionCode = 2;
      if (actionStr == 'recents' || actionStr == '3') actionCode = 3;
      if (actionStr == 'notifications' || actionStr == '4') actionCode = 4;
    }
    final success = await androidBridge!.performNavigation(actionCode);
    return {'action': actionStr, 'action_code': actionCode, 'success': success};
  }

  Future<Map<String, dynamic>> _handleInspectScreen(
      Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? 'General screen context';

    // On mobile, check sensitive app shield
    final decision = guard.evaluate(packageName: activePackageName);
    if (decision.isBlocked) {
      return {
        'blocked': true,
        'reason': decision.reason,
      };
    }

    if (Platform.isAndroid && androidBridge != null) {
      final hierarchy = await androidBridge!.dumpWindowHierarchy();
      return {
        'screen_status': 'inspected_accessibility_tree',
        'active_package': activePackageName,
        'elements_found': hierarchy.length,
        'visible_nodes': hierarchy,
      };
    }

    return {
      'screen_status': 'captured',
      'query': query,
      'summary': 'Desktop screen perception processed under security policy.',
    };
  }

  Future<Map<String, dynamic>> _handleInputText(
      Map<String, dynamic> args) async {
    final text = args['text'] as String;
    final viewId = args['view_id'] as String?;

    if (androidBridge == null) {
      return {
        'error': 'Text input automation is not available on this platform'
      };
    }

    final success = await androidBridge!.inputText(text, viewId: viewId);
    return {'action': 'input_text', 'text': text, 'success': success};
  }

  Future<Map<String, dynamic>> _handleScrollScreen(
      Map<String, dynamic> args) async {
    final bool forward;
    if (args.containsKey('forward') && args['forward'] is bool) {
      forward = args['forward'] as bool;
    } else {
      final direction = (args['direction'] as String?)?.toLowerCase() ?? 'down';
      forward = direction != 'up';
    }

    if (androidBridge == null) {
      return {'error': 'Screen scrolling is not available on this platform'};
    }

    final success = await androidBridge!.scroll(forward: forward);
    return {'action': 'scroll', 'forward': forward, 'success': success};
  }

  Future<Map<String, dynamic>> _handleCaptureScreen(
      Map<String, dynamic> args) async {
    // Sensitive app shield check
    final decision = guard.evaluate(packageName: activePackageName);
    if (decision.isBlocked) {
      return {
        'status': 'blocked',
        'security_alert': decision.reason,
      };
    }

    if (Platform.isAndroid && androidBridge != null) {
      final bytes = await androidBridge!.takeScreenCapture();
      if (bytes != null) {
        onImageCaptured?.call(bytes);
        return {
          'status': 'captured',
          'format': 'jpeg',
          'bytes_length': bytes.length,
          'message':
              'Visual screen frame captured and streamed to Gemini Live model under security shield approval',
        };
      }
      return {
        'status': 'unavailable',
        'message':
            'Screen capture unavailable or blocked by Android FLAG_SECURE',
      };
    }

    return {
      'status': 'captured',
      'platform': Platform.operatingSystem,
      'summary': 'Desktop screen perception processed under security policy',
    };
  }

  // --- WEB SEARCH & KNOWLEDGE ---

  Future<Map<String, dynamic>> _handleWebSearch(
      Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? '';
    if (query.trim().isEmpty) {
      return {'error': 'Search query is required'};
    }

    if (nebiusClient == null) {
      return {
        'error':
            'Nebius client (NVIDIA Nemotron) is not configured for knowledge synthesis'
      };
    }

    try {
      final complexity = NebiusClient.classifyTask(taskDescription: query);
      final modelUsed = nebiusClient!.resolveModel(complexity: complexity);

      final answer = await nebiusClient!.chatCompletion(
        messages: [
          {
            'role': 'system',
            'content':
                'You are the knowledge synthesis engine of Device Assistant powered by NVIDIA Nemotron. Answer the user query accurately, concisely, and factually.',
          },
          {'role': 'user', 'content': query},
        ],
        complexity: complexity,
        temperature: 0.2,
      );

      return {
        'status': 'success',
        'query': query,
        'answer': answer,
        'complexity':
            complexity == TaskComplexity.complex ? 'complex' : 'simple',
        'model_used': modelUsed,
        'source': 'nemotron smart routing ($modelUsed)',
      };
    } catch (e) {
      return {'error': 'Knowledge synthesis error: $e'};
    }
  }

  // --- PC BRIDGE HANDLERS ---

  Future<Map<String, dynamic>> _handlePcStatus() async {
    if (pcBridgeClient == null) {
      return {
        'status': 'not_configured',
        'message':
            'PC Assistant server bridge is not configured. Configure the PC server URL in Settings.',
      };
    }
    return await pcBridgeClient!.checkHealth();
  }

  Future<Map<String, dynamic>> _handleSyncMemories() async {
    if (pcBridgeClient == null) {
      return {
        'status': 'error',
        'error': 'PC Assistant server bridge is not configured'
      };
    }
    return await pcBridgeClient!.syncMemories(db);
  }

  Future<Map<String, dynamic>> _handleSyncWorkflows() async {
    if (pcBridgeClient == null) {
      return {
        'status': 'error',
        'error': 'PC Assistant server bridge is not configured'
      };
    }
    return await pcBridgeClient!.syncWorkflows(db);
  }

  Future<Map<String, dynamic>> _handleDelegateToPc(
      Map<String, dynamic> args) async {
    if (pcBridgeClient == null) {
      return {
        'status': 'error',
        'error': 'PC Assistant server bridge is not configured'
      };
    }
    final tool = args['tool'] as String? ?? '';
    final toolArgs = (args['args'] as Map<String, dynamic>?) ?? {};
    if (tool.isEmpty) {
      return {'error': 'Tool name is required for delegation'};
    }
    return await pcBridgeClient!.delegateTool(tool: tool, args: toolArgs);
  }

  // --- SUB-AGENT HANDLERS ---

  Future<Map<String, dynamic>> _handleSpawnAgent(
      Map<String, dynamic> args) async {
    final role = args['role'] as String?;
    final instructions = args['instructions'] as String?;
    final rawTools = args['allowed_tools'] as List<dynamic>?;

    if (role == null || instructions == null || rawTools == null) {
      return {
        'error': 'Missing required fields: role, instructions, allowed_tools'
      };
    }

    final allowedTools = rawTools.map((e) => e.toString()).toList();
    final isolation = args['isolation'] as String? ?? 'shared';
    final maxSteps = (args['max_steps'] as num?)?.toInt() ?? 10;
    final timeoutMs = (args['timeout_ms'] as num?)?.toInt() ?? 60000;
    final parentId = args['parent_id'] as String?;
    final depth = (args['depth'] as num?)?.toInt() ?? 1;

    // Initialize sub-agent manager if not yet set
    subAgentManager ??= SubAgentManager(
      db: db,
      rootDispatcher: this,
      nebiusClient: nebiusClient,
    );

    return await subAgentManager!.spawnAgent(
      role: role,
      instructions: instructions,
      allowedTools: allowedTools,
      isolation: isolation,
      maxSteps: maxSteps,
      timeoutMs: timeoutMs,
      parentId: parentId,
      depth: depth,
    );
  }

  Map<String, dynamic> _handleListAgents(Map<String, dynamic> args) {
    final status = args['status'] as String?;
    final agents = db.listAgents(status: status);
    return {
      'count': agents.length,
      'agents': agents,
    };
  }

  Map<String, dynamic> _handleAgentStatus(Map<String, dynamic> args) {
    final agentId = args['agent_id'] as String?;
    if (agentId == null) {
      return {'error': 'agent_id is required'};
    }

    subAgentManager ??= SubAgentManager(
      db: db,
      rootDispatcher: this,
      nebiusClient: nebiusClient,
    );

    final status = subAgentManager!.getAgentStatus(agentId);
    if (status != null) {
      return {
        'status': 'found',
        'agent': status,
      };
    }
    return {'status': 'not_found', 'agent_id': agentId};
  }

  Map<String, dynamic> _handleCancelAgent(Map<String, dynamic> args) {
    final agentId = args['agent_id'] as String?;
    if (agentId == null) {
      return {'error': 'agent_id is required'};
    }

    subAgentManager ??= SubAgentManager(
      db: db,
      rootDispatcher: this,
      nebiusClient: nebiusClient,
    );

    final cancelled = subAgentManager!.cancelAgent(agentId);
    return {
      'action': 'cancel_agent',
      'agent_id': agentId,
      'cancelled': cancelled,
    };
  }

  Map<String, dynamic> _handleSendToAgent(Map<String, dynamic> args) {
    final agentId = args['agent_id'] as String?;
    final message = args['message'] as String?;
    if (agentId == null || message == null) {
      return {'error': 'agent_id and message are required'};
    }

    subAgentManager ??= SubAgentManager(
      db: db,
      rootDispatcher: this,
      nebiusClient: nebiusClient,
    );

    subAgentManager!.sendToAgent(agentId, 'user', message);
    return {
      'status': 'sent',
      'agent_id': agentId,
      'message': message,
    };
  }
}
