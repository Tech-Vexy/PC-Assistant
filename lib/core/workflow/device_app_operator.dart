import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../platform/android/android_bridge.dart';
import '../database/local_database.dart';
import '../network/gemini_live_client.dart';
import '../network/nebius_client.dart';
import 'workflow_manager.dart';

/// Operates device applications using a unified workflow-first architecture:
/// 1. Checks if a previously learned workflow exists for the app & goal.
/// 2. If found, applies dynamic parameters and replays the validated workflow.
/// 3. If not found or layout changed, takes a screenshot/hierarchy inspection to determine layout,
///    synthesizes the atomic UI action steps, executes them, and saves the new workflow
///    into LocalDatabase so next time it references the cached workflow directly.
///
/// Generally, operate dialer is just operate device:
/// It captures a screenshot and hierarchy to determine layout, executes the actions,
/// and saves the resulting steps as a reusable workflow for subsequent calls.
class DeviceAppOperator {
  final AndroidBridge? androidBridge;
  final LocalDatabase db;
  final HermesWorkflowManager? hermesManager;
  final NebiusClient? nebiusClient;
  final GeminiLiveClient? geminiClient;
  final Future<Map<String, dynamic>> Function(
      String toolName, Map<String, dynamic> args) dispatchStep;

  DeviceAppOperator({
    this.androidBridge,
    required this.db,
    this.hermesManager,
    this.nebiusClient,
    this.geminiClient,
    required this.dispatchStep,
  });

  /// Operates an application on the device to achieve a user goal.
  Future<Map<String, dynamic>> operateApp({
    required String appName,
    required String goal,
    Map<String, dynamic>? parameters,
  }) async {
    final params = parameters ?? {};
    final workflowKey = _generateWorkflowKey(appName, goal);

    // ── STEP 1: Check Cached / Learned Workflow First ─────────────────────────
    final cached = db.getWorkflow(workflowKey);
    if (cached != null) {
      final cachedSteps =
          (cached['steps'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
              [];
      if (cachedSteps.isNotEmpty) {
        final replayResult =
            await _executeParameterizedWorkflow(cachedSteps, params);
        if (replayResult['success'] == true) {
          return {
            'status': 'success',
            'mode': 'replayed_workflow',
            'workflow_name': workflowKey,
            'goal': goal,
            'app_name': appName,
            'execution_log': replayResult['log'],
          };
        }
        // If cached workflow failed (e.g. layout updated or view moved), fall through to re-ground
      }
    }

    final isAndroid = androidBridge?.isAndroid ?? Platform.isAndroid;
    if (!isAndroid || androidBridge == null) {
      return {
        'status': 'error',
        'error': 'Device application operation is only available on Android.',
      };
    }

    // ── STEP 2: Visual Layout Grounding (Screenshot + Hierarchy) ──────────────
    // 1. Launch target app
    await androidBridge!.launchApp(appName);
    await Future.delayed(const Duration(milliseconds: 900));

    // 2. Capture visual screenshot and semantic view tree to determine layout
    final screenshotBytes = await androidBridge!.takeScreenCapture();
    final hierarchy = await androidBridge!.dumpWindowHierarchy();

    // 3. Synthesize action plan from layout
    final synthesizedSteps = await _synthesizeActionSteps(
      appName: appName,
      goal: goal,
      hierarchy: hierarchy,
      screenshotBytes: screenshotBytes,
      parameters: params,
    );

    if (synthesizedSteps.isEmpty) {
      // Fallback: If specialized layout heuristic didn't match, run direct dialer/app execution
      if (_isDialerGoal(goal, appName)) {
        final directRes = await androidBridge!.operateDialerCall(
          contactName: params['contact_name']?.toString(),
          phoneNumber: params['phone_number']?.toString(),
          simSlot: (params['sim_slot'] as num?)?.toInt() ?? 1,
          simName: params['sim_name']?.toString(),
        );

        // Record standard dialer workflow
        final standardSteps = _buildStandardDialerSteps(parameters: params);
        _saveLearnedWorkflow(workflowKey, appName, goal, standardSteps);

        return {
          'status': 'success',
          'mode': 'learned_and_saved_workflow',
          'workflow_name': workflowKey,
          'result': directRes,
          'screenshot_taken': screenshotBytes != null,
        };
      }

      return {
        'status': 'error',
        'error':
            'Could not determine UI layout elements for "$appName" to achieve "$goal".',
        'screenshot_taken': screenshotBytes != null,
      };
    }

    // 4. Execute synthesized action steps live
    final executionLog = <Map<String, dynamic>>[];
    bool allSucceeded = true;

    for (final step in synthesizedSteps) {
      final tool = step['tool']?.toString() ?? '';
      final rawArgs = (step['args'] as Map<String, dynamic>?) ?? {};
      final resolvedArgs = _substituteArgs(rawArgs, params);

      final res = await dispatchStep(tool, resolvedArgs);
      executionLog.add({
        'tool': tool,
        'args': resolvedArgs,
        'result': res,
      });

      if (res.containsKey('error') || res['status'] == 'error') {
        allSucceeded = false;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 600));
    }

    // ── STEP 3: Save as Reusable Workflow for Next Time ───────────────────────
    if (allSucceeded) {
      _saveLearnedWorkflow(workflowKey, appName, goal, synthesizedSteps);
    }

    return {
      'status': allSucceeded ? 'success' : 'partial_failure',
      'mode': 'learned_and_saved_workflow',
      'workflow_name': workflowKey,
      'app_name': appName,
      'goal': goal,
      'screenshot_taken': screenshotBytes != null,
      'execution_log': executionLog,
    };
  }

  // ── Helper: Workflow Replay ────────────────────────────────────────────────

  Future<Map<String, dynamic>> _executeParameterizedWorkflow(
    List<Map<String, dynamic>> steps,
    Map<String, dynamic> params,
  ) async {
    final log = <Map<String, dynamic>>[];
    for (final step in steps) {
      final tool = step['tool']?.toString() ?? '';
      final rawArgs = (step['args'] as Map<String, dynamic>?) ?? {};
      final resolvedArgs = _substituteArgs(rawArgs, params);

      final res = await dispatchStep(tool, resolvedArgs);
      log.add({'tool': tool, 'args': resolvedArgs, 'result': res});

      if (res.containsKey('error') || res['status'] == 'error') {
        return {'success': false, 'log': log};
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return {'success': true, 'log': log};
  }

  void _saveLearnedWorkflow(
    String workflowKey,
    String appName,
    String goal,
    List<Map<String, dynamic>> steps,
  ) {
    db.saveWorkflow(
      workflowKey,
      description: 'Learned device automation workflow for $appName: $goal',
      steps: steps,
    );

    if (hermesManager != null) {
      hermesManager!.saveSkill(
        name: workflowKey,
        description: 'Operates $appName to $goal',
        markdownContent: '# $appName $goal\nAutomated device workflow.',
        steps: steps,
        platforms: ['android'],
        tags: [appName.toLowerCase(), 'device_automation'],
      );
    }
  }

  // ── Helper: Layout Analysis & Step Synthesis ───────────────────────────────

  Future<List<Map<String, dynamic>>> _synthesizeActionSteps({
    required String appName,
    required String goal,
    required List<Map<String, dynamic>> hierarchy,
    Uint8List? screenshotBytes,
    required Map<String, dynamic> parameters,
  }) async {
    if (_isDialerGoal(goal, appName)) {
      return _synthesizeDialerSteps(
        appName: appName,
        goal: goal,
        hierarchy: hierarchy,
        parameters: parameters,
      );
    }

    // Generic device application step synthesis based on screen layout
    return _synthesizeGenericAppSteps(
      appName: appName,
      goal: goal,
      hierarchy: hierarchy,
      parameters: parameters,
    );
  }

  List<Map<String, dynamic>> _synthesizeDialerSteps({
    required String appName,
    required String goal,
    required List<Map<String, dynamic>> hierarchy,
    required Map<String, dynamic> parameters,
  }) {
    final steps = <Map<String, dynamic>>[];
    final isContactCall = parameters.containsKey('contact_name') ||
        goal.toLowerCase().contains('contact');
    final hasPhoneNumber = parameters.containsKey('phone_number');

    // Step 1: Open Phone/Dialer application
    steps.add({
      'tool': 'open_application',
      'args': {'app_name': appName},
      'purpose': 'Open $appName',
    });

    if (isContactCall && !hasPhoneNumber) {
      // ── Contact Search Flow ────────────────────────────────────────────────
      // Determine search box from layout hierarchy
      final searchNode = hierarchy.firstWhere(
        (n) {
          final text = (n['text']?.toString() ?? '').toLowerCase();
          final desc =
              (n['contentDescription']?.toString() ?? '').toLowerCase();
          final id = (n['id']?.toString() ?? '').toLowerCase();
          return text.contains('search') ||
              desc.contains('search') ||
              id.contains('search') ||
              n['className']?.toString().contains('EditText') == true;
        },
        orElse: () => {},
      );

      if (searchNode.isNotEmpty && searchNode.containsKey('id')) {
        steps.add({
          'tool': 'input_text',
          'args': {
            'text': '{{contact_name}}',
            'view_id': searchNode['id'],
          },
          'purpose': 'Type contact name into dialer search',
        });
      } else {
        steps.add({
          'tool': 'input_text',
          'args': {'text': '{{contact_name}}'},
          'purpose': 'Type contact name into active field',
        });
      }

      // Step: Click contact item in results
      steps.add({
        'tool': 'click_element',
        'args': {'text': '{{contact_name}}'},
        'purpose': 'Click contact item from results',
      });
    } else {
      // ── Direct Number Dial Flow ────────────────────────────────────────────
      // Look for dialpad toggle button in layout if dialpad is not active
      final dialpadToggle = hierarchy.firstWhere(
        (n) {
          final desc =
              (n['contentDescription']?.toString() ?? '').toLowerCase();
          final id = (n['id']?.toString() ?? '').toLowerCase();
          final text = (n['text']?.toString() ?? '').toLowerCase();
          return desc.contains('dial pad') ||
              desc.contains('dialpad') ||
              desc.contains('keypad') ||
              id.contains('dialpad_floating_action_button') ||
              id.contains('fab') ||
              text.contains('keypad');
        },
        orElse: () => {},
      );

      if (dialpadToggle.isNotEmpty) {
        final toggleLabel = dialpadToggle['contentDescription']?.toString() ??
            dialpadToggle['text']?.toString() ??
            '';
        steps.add({
          'tool': 'click_element',
          'args': {
            if (toggleLabel.isNotEmpty) 'text': toggleLabel,
            if (dialpadToggle['id'] != null) 'view_id': dialpadToggle['id'],
          },
          'purpose': 'Open dialpad keypad',
        });
      }

      // Find digits entry field
      final digitsNode = hierarchy.firstWhere(
        (n) {
          final id = (n['id']?.toString() ?? '').toLowerCase();
          final cls = (n['className']?.toString() ?? '');
          return id.contains('digits') ||
              id.contains('phone_number') ||
              cls.contains('EditText');
        },
        orElse: () => {},
      );

      if (digitsNode.isNotEmpty && digitsNode.containsKey('id')) {
        steps.add({
          'tool': 'input_text',
          'args': {
            'text': '{{phone_number}}',
            'view_id': digitsNode['id'],
          },
          'purpose': 'Input phone number into dialer',
        });
      } else {
        steps.add({
          'tool': 'input_text',
          'args': {'text': '{{phone_number}}'},
          'purpose': 'Input phone number into dialpad',
        });
      }
    }

    // Determine Call button from layout
    final callNode = hierarchy.firstWhere(
      (n) {
        final desc = (n['contentDescription']?.toString() ?? '').toLowerCase();
        final text = (n['text']?.toString() ?? '').toLowerCase();
        final id = (n['id']?.toString() ?? '').toLowerCase();
        return desc.contains('call') ||
            desc.contains('dial') ||
            text == 'call' ||
            id.contains('call_button') ||
            id.contains('dialpad_floating_action_button') ||
            id.contains('incall');
      },
      orElse: () => {},
    );

    final callLabel = callNode['text']?.toString() ??
        callNode['contentDescription']?.toString() ??
        'Call';

    steps.add({
      'tool': 'click_element',
      'args': {
        'text': callLabel,
        if (callNode['id'] != null) 'view_id': callNode['id'],
      },
      'purpose': 'Click Call button in dialer',
    });

    // SIM card slot selector step (if dual SIM)
    if (parameters.containsKey('sim_slot') ||
        parameters.containsKey('sim_name')) {
      steps.add({
        'tool': 'click_element',
        'args': {'text': 'SIM {{sim_slot}}'},
        'purpose': 'Select requested SIM card slot',
      });
    }

    return steps;
  }

  List<Map<String, dynamic>> _synthesizeGenericAppSteps({
    required String appName,
    required String goal,
    required List<Map<String, dynamic>> hierarchy,
    required Map<String, dynamic> parameters,
  }) {
    final steps = <Map<String, dynamic>>[];

    // Step 1: Open app
    steps.add({
      'tool': 'open_application',
      'args': {'app_name': appName},
      'purpose': 'Open $appName',
    });

    // Step 2: Look for primary action button or input based on parameters
    for (final entry in parameters.entries) {
      final key = entry.key;

      if (key.contains('text') ||
          key.contains('message') ||
          key.contains('search') ||
          key.contains('query')) {
        // Find input node in layout
        final inputNode = hierarchy.firstWhere(
          (n) => n['className']?.toString().contains('EditText') == true,
          orElse: () => {},
        );

        steps.add({
          'tool': 'input_text',
          'args': {
            'text': '{{$key}}',
            if (inputNode.containsKey('id')) 'view_id': inputNode['id'],
          },
          'purpose': 'Input $key into $appName',
        });
      }
    }

    // Step 3: Find any confirmation/send/save button in layout matching goal
    final actionNode = hierarchy.firstWhere(
      (n) {
        final text = (n['text']?.toString() ?? '').toLowerCase();
        final desc = (n['contentDescription']?.toString() ?? '').toLowerCase();
        final g = goal.toLowerCase();
        return (text.isNotEmpty && g.contains(text)) ||
            (desc.isNotEmpty && g.contains(desc)) ||
            text == 'send' ||
            text == 'save' ||
            text == 'ok' ||
            text == 'done';
      },
      orElse: () => {},
    );

    if (actionNode.isNotEmpty) {
      final label = actionNode['text']?.toString() ??
          actionNode['contentDescription']?.toString() ??
          '';
      if (label.isNotEmpty) {
        steps.add({
          'tool': 'click_element',
          'args': {'text': label},
          'purpose': 'Confirm action "$label"',
        });
      }
    }

    return steps;
  }

  List<Map<String, dynamic>> _buildStandardDialerSteps({
    Map<String, dynamic>? parameters,
  }) {
    final hasNumber = parameters?.containsKey('phone_number') == true;

    return [
      {
        'tool': 'open_application',
        'args': {'app_name': 'Phone'},
        'purpose': 'Open dialer app',
      },
      if (!hasNumber) ...[
        {
          'tool': 'input_text',
          'args': {'text': '{{contact_name}}'},
          'purpose': 'Search contact',
        },
        {
          'tool': 'click_element',
          'args': {'text': '{{contact_name}}'},
          'purpose': 'Click contact item',
        },
      ] else ...[
        {
          'tool': 'input_text',
          'args': {'text': '{{phone_number}}'},
          'purpose': 'Enter phone number',
        },
      ],
      {
        'tool': 'click_element',
        'args': {'text': 'Call'},
        'purpose': 'Click Call button',
      },
      {
        'tool': 'click_element',
        'args': {'text': 'SIM {{sim_slot}}'},
        'purpose': 'Select SIM card slot',
      },
    ];
  }

  bool _isDialerGoal(String goal, String appName) {
    final g = goal.toLowerCase();
    final a = appName.toLowerCase();
    return g.contains('call') ||
        g.contains('dial') ||
        a.contains('dialer') ||
        a.contains('phone');
  }

  String _generateWorkflowKey(String appName, String goal) {
    final cleanApp =
        appName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_').toLowerCase();
    final cleanGoal = goal
        .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '')
        .split(RegExp(r'\s+'))
        .take(3)
        .join('_')
        .toLowerCase();
    return 'workflow_${cleanApp}_$cleanGoal';
  }

  Map<String, dynamic> _substituteArgs(
    Map<String, dynamic> rawArgs,
    Map<String, dynamic> params,
  ) {
    final result = <String, dynamic>{};
    for (final entry in rawArgs.entries) {
      var val = entry.value;
      if (val is String) {
        for (final p in params.entries) {
          val = (val as String).replaceAll('{{${p.key}}}', p.value.toString());
        }
      }
      result[entry.key] = val;
    }
    return result;
  }
}
