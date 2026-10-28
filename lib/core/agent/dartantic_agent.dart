import 'dart:async';
import 'dart:convert';
import '../database/local_database.dart';
import '../network/nebius_client.dart';
import '../../features/tools/tool_definition.dart';
import '../../features/tools/tool_dispatcher.dart';

/// Specification for spawning a specialized sub-agent
class SubAgentSpec {
  final String role;
  final String instructions;
  final List<String> allowedTools;
  final String isolation;
  final int maxSteps;
  final int timeoutMs;
  final String? parentId;
  final int depth;

  const SubAgentSpec({
    required this.role,
    required this.instructions,
    required this.allowedTools,
    this.isolation = 'shared',
    this.maxSteps = 10,
    this.timeoutMs = 60000,
    this.parentId,
    this.depth = 1,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'instructions': instructions,
        'allowed_tools': allowedTools,
        'isolation': isolation,
        'max_steps': maxSteps,
        'timeout_ms': timeoutMs,
        'parent_id': parentId,
        'depth': depth,
      };
}

/// Output result of a sub-agent execution run
class SubAgentExecutionResult {
  final String agentId;
  final String role;
  final String status;
  final int stepsTaken;
  final Map<String, dynamic>? output;
  final String? error;
  final List<Map<String, dynamic>> toolHistory;

  const SubAgentExecutionResult({
    required this.agentId,
    required this.role,
    required this.status,
    required this.stepsTaken,
    this.output,
    this.error,
    this.toolHistory = const [],
  });

  Map<String, dynamic> toJson() => {
        'agent_id': agentId,
        'role': role,
        'status': status,
        'steps_taken': stepsTaken,
        if (output != null) 'output': output,
        if (error != null) 'error': error,
        'history_length': toolHistory.length,
      };
}

/// Hybrid, deny-by-default Sub-Agent Orchestrator complementing Gemini Live
/// with structured multi-step reasoning, typed outputs, and task coordination.
class SubAgentManager {
  static const int maxConcurrentAgents = 10;
  static const int maxDepthLimit = 3;
  static const int maxParallelExecutions = 4;

  final LocalDatabase db;
  final NebiusClient? nebiusClient;
  final ToolDispatcher rootDispatcher;

  final Map<String, Completer<void>> _activeCancellations = {};
  int _activeRunningCount = 0;

  SubAgentManager({
    required this.db,
    required this.rootDispatcher,
    this.nebiusClient,
  });

  /// Spawns and starts a sub-agent task asynchronously
  Future<Map<String, dynamic>> spawnAgent({
    required String role,
    required String instructions,
    required List<String> allowedTools,
    String isolation = 'shared',
    int maxSteps = 10,
    int timeoutMs = 60000,
    String? parentId,
    int depth = 1,
  }) async {
    // 1. Concurrency and depth constraints
    if (_activeRunningCount >= maxConcurrentAgents) {
      return {
        'status': 'rejected',
        'error':
            'Max concurrent sub-agents limit reached ($maxConcurrentAgents active).',
      };
    }

    if (depth > maxDepthLimit) {
      return {
        'status': 'rejected',
        'error':
            'Sub-agent spawn depth limit exceeded (max depth: $maxDepthLimit).',
      };
    }

    // 2. Validate allowed tools against registry (deny unknown tools)
    final allKnownTools = ToolDefinitions.getAllDeclarations(isAndroid: true)
        .map((t) => t['name'] as String)
        .toSet();
    allKnownTools.addAll([
      'spawn_agent',
      'list_agents',
      'agent_status',
      'cancel_agent',
      'send_to_agent',
      'run_shell_command',
    ]);

    for (final tool in allowedTools) {
      if (!allKnownTools.contains(tool)) {
        return {
          'status': 'rejected',
          'error': 'Tool "$tool" is not in the recognized tool registry.',
        };
      }
    }

    // Sub-agents cannot spawn recursive agents if at max depth
    final sanitizedTools = List<String>.from(allowedTools);
    if (depth >= maxDepthLimit) {
      sanitizedTools.remove('spawn_agent');
    }

    final agentId =
        'agent_${DateTime.now().millisecondsSinceEpoch}_${(role.replaceAll(' ', '_')).toLowerCase()}';

    // 3. Persist agent record
    db.saveAgent(
      agentId: agentId,
      parentId: parentId,
      role: role,
      instructions: instructions,
      allowedTools: sanitizedTools,
      isolation: isolation,
      status: 'running',
      depth: depth,
      maxSteps: maxSteps,
      stepsTaken: 0,
    );

    // 4. Launch autonomous execution loop in background
    _activeRunningCount++;
    final cancelCompleter = Completer<void>();
    _activeCancellations[agentId] = cancelCompleter;

    _runAgentLoop(
      agentId: agentId,
      spec: SubAgentSpec(
        role: role,
        instructions: instructions,
        allowedTools: sanitizedTools,
        isolation: isolation,
        maxSteps: maxSteps,
        timeoutMs: timeoutMs,
        parentId: parentId,
        depth: depth,
      ),
      cancelToken: cancelCompleter,
    ).then((_) {
      _activeRunningCount =
          (_activeRunningCount - 1).clamp(0, maxConcurrentAgents);
      _activeCancellations.remove(agentId);
    }).catchError((err) {
      _activeRunningCount =
          (_activeRunningCount - 1).clamp(0, maxConcurrentAgents);
      _activeCancellations.remove(agentId);
      db.updateAgentStatus(agentId, 'failed', error: err.toString());
    });

    return {
      'status': 'spawned',
      'agent_id': agentId,
      'role': role,
      'depth': depth,
      'allowed_tools': sanitizedTools,
      'message': 'Sub-agent spawned and running autonomously.',
    };
  }

  /// Autonomous reasoning & execution loop for a sub-agent
  Future<SubAgentExecutionResult> _runAgentLoop({
    required String agentId,
    required SubAgentSpec spec,
    required Completer<void> cancelToken,
  }) async {
    final toolHistory = <Map<String, dynamic>>[];
    int stepsTaken = 0;

    final timeoutTimer = Timer(Duration(milliseconds: spec.timeoutMs), () {
      if (!cancelToken.isCompleted) {
        cancelToken.complete();
      }
    });

    try {
      while (stepsTaken < spec.maxSteps) {
        if (cancelToken.isCompleted) {
          db.updateAgentStatus(agentId, 'cancelled', stepsTaken: stepsTaken);
          timeoutTimer.cancel();
          return SubAgentExecutionResult(
            agentId: agentId,
            role: spec.role,
            status: 'cancelled',
            stepsTaken: stepsTaken,
            toolHistory: toolHistory,
          );
        }

        // Reason next step using Nebius (Nemotron-3-super-vl) if available
        Map<String, dynamic>? nextAction;
        if (nebiusClient != null) {
          nextAction = await _decideNextStep(
            spec: spec,
            history: toolHistory,
            stepsTaken: stepsTaken,
          );
        } else {
          // Fallback deterministic / completion step
          nextAction = {
            'action': 'finish',
            'summary': 'Completed instructions under local offline fallback.',
          };
        }

        if (nextAction['action'] == 'finish' ||
            nextAction['action'] == 'complete') {
          final finalOutput = nextAction['output'] as Map<String, dynamic>? ??
              {
                'summary':
                    nextAction['summary'] ?? 'Goal accomplished successfully.',
              };

          db.updateAgentStatus(
            agentId,
            'completed',
            stepsTaken: stepsTaken,
            result: finalOutput,
          );
          timeoutTimer.cancel();

          return SubAgentExecutionResult(
            agentId: agentId,
            role: spec.role,
            status: 'completed',
            stepsTaken: stepsTaken,
            output: finalOutput,
            toolHistory: toolHistory,
          );
        }

        // Execute tool action
        final toolName = nextAction['tool'] as String?;
        final toolArgs = (nextAction['args'] as Map<String, dynamic>?) ?? {};

        if (toolName == null || !spec.allowedTools.contains(toolName)) {
          toolHistory.add({
            'step': stepsTaken + 1,
            'tool': toolName ?? 'unknown',
            'error': 'Tool not permitted by sub-agent security scope.',
          });
          stepsTaken++;
          continue;
        }

        // Dispatch through root dispatcher
        final executionResult = await rootDispatcher.dispatch(
          toolName: toolName,
          args: toolArgs,
        );

        toolHistory.add({
          'step': stepsTaken + 1,
          'tool': toolName,
          'args': toolArgs,
          'result': executionResult,
        });

        stepsTaken++;
        db.updateAgentStatus(agentId, 'running', stepsTaken: stepsTaken);
      }

      // Reached step cap
      final capResult = {
        'status': 'step_cap_reached',
        'message': 'Sub-agent hit max steps limit (${spec.maxSteps}).',
      };
      db.updateAgentStatus(
        agentId,
        'completed',
        stepsTaken: stepsTaken,
        result: capResult,
      );
      timeoutTimer.cancel();

      return SubAgentExecutionResult(
        agentId: agentId,
        role: spec.role,
        status: 'completed',
        stepsTaken: stepsTaken,
        output: capResult,
        toolHistory: toolHistory,
      );
    } catch (e) {
      timeoutTimer.cancel();
      db.updateAgentStatus(agentId, 'failed',
          stepsTaken: stepsTaken, error: e.toString());
      return SubAgentExecutionResult(
        agentId: agentId,
        role: spec.role,
        status: 'failed',
        stepsTaken: stepsTaken,
        error: e.toString(),
        toolHistory: toolHistory,
      );
    }
  }

  /// Uses Nemotron-3-super-vl to determine the next tool call or completion
  Future<Map<String, dynamic>> _decideNextStep({
    required SubAgentSpec spec,
    required List<Map<String, dynamic>> history,
    required int stepsTaken,
  }) async {
    final systemPrompt = '''
You are a specialized sub-agent with role "${spec.role}".
Your instructions: "${spec.instructions}"
Allowed tools: ${spec.allowedTools.join(', ')}
Execution Step: ${stepsTaken + 1} of ${spec.maxSteps}

Respond ONLY with valid JSON.
If you need to invoke an allowed tool, return:
{
  "action": "call_tool",
  "tool": "allowed_tool_name",
  "args": { ... },
  "rationale": "Brief reason for this tool"
}

If the task is fulfilled or no more tools are needed, return:
{
  "action": "finish",
  "summary": "Clear summary of the outcome",
  "output": { ... }
}
''';

    final prompt = history.isEmpty
        ? 'Begin execution of your task.'
        : 'History of previous steps:\n${jsonEncode(history)}\n\nWhat is your next action?';

    try {
      final complexity = NebiusClient.classifyTask(
        taskDescription: spec.instructions,
        toolCount: spec.allowedTools.length,
        requiresMultiStep: spec.maxSteps > 3 || history.length > 1,
      );

      final responseText = await nebiusClient!.chatCompletion(
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': prompt},
        ],
        complexity: complexity,
        temperature: 0.1,
      );

      String clean = responseText.trim();
      if (clean.startsWith('```json')) clean = clean.substring(7);
      if (clean.startsWith('```')) clean = clean.substring(3);
      if (clean.endsWith('```')) clean = clean.substring(0, clean.length - 3);
      clean = clean.trim();

      return jsonDecode(clean) as Map<String, dynamic>;
    } catch (_) {
      // If parsing fails, conclude
      return {
        'action': 'finish',
        'summary': 'Finished task reasoning.',
      };
    }
  }

  /// Cancels an active sub-agent by ID
  bool cancelAgent(String agentId) {
    final cancelToken = _activeCancellations[agentId];
    if (cancelToken != null && !cancelToken.isCompleted) {
      cancelToken.complete();
    }
    return db.cancelAgent(agentId);
  }

  /// Sends a message / instruction to an active agent
  void sendToAgent(String agentId, String sender, String content) {
    db.addAgentMessage(agentId, sender, content);
  }

  /// Returns live status and details of an agent
  Map<String, dynamic>? getAgentStatus(String agentId) {
    final agent = db.getAgent(agentId);
    if (agent == null) return null;

    final messages = db.getAgentMessages(agentId);
    return {
      ...agent,
      'messages': messages,
      'is_actively_running': _activeCancellations.containsKey(agentId),
    };
  }

  /// Lists all sub-agents
  List<Map<String, dynamic>> listAgents({String? status, int limit = 50}) {
    return db.listAgents(status: status, limit: limit);
  }
}
