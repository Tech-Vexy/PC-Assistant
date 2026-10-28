import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../core/database/local_database.dart';
import '../../tools/tool_dispatcher.dart';

class PlansWorkflowsTab extends StatefulWidget {
  final LocalDatabase database;
  final ToolDispatcher dispatcher;

  const PlansWorkflowsTab({
    super.key,
    required this.database,
    required this.dispatcher,
  });

  @override
  State<PlansWorkflowsTab> createState() => _PlansWorkflowsTabState();
}

class _PlansWorkflowsTabState extends State<PlansWorkflowsTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _plans = [];
  List<Map<String, dynamic>> _workflows = [];
  List<Map<String, dynamic>> _scheduledWorkflows = [];
  List<Map<String, dynamic>> _agents = [];
  bool _isExecuting = false;
  String? _executingId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadData();
  }

  void _loadData() {
    setState(() {
      _plans = widget.database.listPlans();
      _workflows = widget.database.listWorkflows();
      _scheduledWorkflows = widget.database.listScheduledWorkflows();
      _agents = widget.database.listAgents();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _runPlan(String planId) async {
    setState(() {
      _isExecuting = true;
      _executingId = planId;
    });

    final res = await widget.dispatcher.dispatch(
      toolName: 'execute_plan',
      args: {'plan_id': planId},
    );

    if (mounted) {
      _loadData();
      setState(() {
        _isExecuting = false;
        _executingId = null;
      });

      final success = res['status'] == 'completed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              success ? Colors.green.shade800 : Colors.red.shade800,
          content: Text(
            success
                ? 'Plan $planId completed successfully!'
                : 'Plan $planId failed: ${res['reason'] ?? res['error']}',
          ),
        ),
      );
    }
  }

  Future<void> _runWorkflow(String name) async {
    setState(() {
      _isExecuting = true;
      _executingId = name;
    });

    final res = await widget.dispatcher.dispatch(
      toolName: 'run_workflow',
      args: {'name': name},
    );

    if (mounted) {
      _loadData();
      setState(() {
        _isExecuting = false;
        _executingId = null;
      });

      final success = res['status'] == 'completed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              success ? Colors.green.shade800 : Colors.red.shade800,
          content: Text(
            success
                ? 'Workflow "$name" executed.'
                : 'Workflow "$name" stopped: ${res['error'] ?? 'Execution halted'}',
          ),
        ),
      );
    }
  }

  void _deleteWorkflow(String name) {
    widget.database.deleteWorkflow(name);
    _loadData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Workflow "$name" deleted.')),
    );
  }

  Future<void> _syncWorkflowsFromPc() async {
    setState(() => _isExecuting = true);
    final res = await widget.dispatcher.dispatch(
      toolName: 'sync_workflows',
      args: {},
    );
    _loadData();
    if (mounted) {
      setState(() => _isExecuting = false);
      final success = res['status'] == 'success';
      final count = res['synced_count'] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              success ? Colors.green.shade800 : Colors.red.shade800,
          content: Text(
            success
                ? 'Synced $count workflows from PC Assistant.'
                : 'Sync failed: ${res['error'] ?? res['message'] ?? 'Unable to reach PC server'}',
          ),
        ),
      );
    }
  }

  Future<void> _cancelAgent(String agentId) async {
    await widget.dispatcher.dispatch(
      toolName: 'cancel_agent',
      args: {'agent_id': agentId},
    );
    _loadData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sub-agent $agentId cancelled.')),
      );
    }
  }

  void _showScheduleDialog(String workflowName) {
    final existing = _scheduledWorkflows.firstWhere(
      (s) => s['workflow_name'] == workflowName,
      orElse: () => {},
    );
    final hasExisting = existing.isNotEmpty;
    final intervalCtrl = TextEditingController(
      text: hasExisting ? existing['interval_seconds'].toString() : '3600',
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Schedule "$workflowName"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set recurring execution interval in seconds:',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: intervalCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Interval (seconds)',
                helperText: '60 = 1 min, 3600 = 1 hour, 86400 = 1 day',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          if (hasExisting)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () {
                widget.database
                    .deleteScheduledWorkflow(existing['id'] as String);
                Navigator.pop(ctx);
                _loadData();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('Cancelled schedule for "$workflowName"')),
                );
              },
              child: const Text('Cancel Schedule'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              final seconds = int.tryParse(intervalCtrl.text.trim()) ?? 3600;
              final now = DateTime.now().millisecondsSinceEpoch;
              final id = existing['id'] as String? ??
                  'sched_${workflowName}_${now % 100000}';
              widget.database.saveScheduledWorkflow(
                id: id,
                workflowName: workflowName,
                intervalSeconds: seconds.clamp(10, 86400 * 30),
                nextRunAt: now + (seconds * 1000),
              );
              Navigator.pop(ctx);
              _loadData();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: Colors.teal,
                  content: Text(
                      'Workflow "$workflowName" scheduled every $seconds seconds.'),
                ),
              );
            },
            child: const Text('Save Schedule'),
          ),
        ],
      ),
    );
  }

  void _showAddWorkflowDialog() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final stepsCtrl = TextEditingController(
        text: '[\n  {\n    "tool": "system_status",\n    "args": {}\n  }\n]');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Automated Workflow'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                    labelText: 'Workflow Name',
                    hintText: 'e.g. morning_routine'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Checks status and summarizes context'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: stepsCtrl,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Steps (JSON array)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              try {
                final steps = (jsonDecode(stepsCtrl.text) as List)
                    .cast<Map<String, dynamic>>();
                widget.database.saveWorkflow(
                  nameCtrl.text.trim(),
                  description: descCtrl.text.trim(),
                  steps: steps,
                );
                Navigator.pop(ctx);
                _loadData();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      backgroundColor: Colors.red,
                      content: Text('Invalid JSON steps: $e')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showAddSubAgentDialog() {
    final roleCtrl = TextEditingController(text: 'Device Automator');
    final instructionsCtrl =
        TextEditingController(text: 'Check system status and report health');
    final toolsCtrl =
        TextEditingController(text: 'system_status, remember, recall');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spawn Dynamic Sub-Agent'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: roleCtrl,
                decoration: const InputDecoration(
                    labelText: 'Sub-Agent Role',
                    hintText: 'e.g. Research Assistant'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: instructionsCtrl,
                maxLines: 3,
                decoration:
                    const InputDecoration(labelText: 'Actionable Instructions'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: toolsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Allowed Tools (comma-separated)',
                  hintText: 'system_status, remember, inspect_screen',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final role = roleCtrl.text.trim();
              final instructions = instructionsCtrl.text.trim();
              final tools = toolsCtrl.text
                  .split(',')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList();

              if (role.isEmpty || instructions.isEmpty) return;

              Navigator.pop(ctx);
              final res = await widget.dispatcher.dispatch(
                toolName: 'spawn_agent',
                args: {
                  'role': role,
                  'instructions': instructions,
                  'allowed_tools': tools,
                },
              );

              _loadData();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: res.containsKey('error')
                        ? Colors.red.shade800
                        : Colors.indigo,
                    content: Text(res.containsKey('error')
                        ? 'Failed to spawn sub-agent: ${res['error']}'
                        : 'Sub-agent "${res['agent_id']}" spawned.'),
                  ),
                );
              }
            },
            child: const Text('Spawn'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Material(
          color: const Color(0xFF181B22),
          child: TabBar(
            controller: _tabController,
            indicatorColor: Colors.indigoAccent,
            tabs: const [
              Tab(icon: Icon(Icons.alt_route, size: 18), text: 'Task Plans'),
              Tab(
                  icon: Icon(Icons.account_tree_outlined, size: 18),
                  text: 'Workflows'),
              Tab(
                  icon: Icon(Icons.smart_toy_outlined, size: 18),
                  text: 'Sub-Agents'),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // 1. Task Plans Tab
          _plans.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.alt_route, size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      const Text('No Task Plans Generated Yet',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        'Voice queries requiring multi-step reasoning are planned by Nemotron.',
                        style: TextStyle(
                            color: Colors.grey.shade400, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _plans.length,
                  itemBuilder: (ctx, idx) {
                    final plan = _plans[idx];
                    final planId = plan['plan_id'] as String;
                    final goal = plan['goal'] as String;
                    final status = plan['status'] as String;
                    final steps = (plan['steps'] as List<dynamic>?) ?? [];
                    final isBusy = _isExecuting && _executingId == planId;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ExpansionTile(
                        leading: CircleAvatar(
                          backgroundColor: status == 'completed'
                              ? Colors.green.shade900
                              : (status == 'failed'
                                  ? Colors.red.shade900
                                  : Colors.indigo.shade900),
                          child: Icon(
                            status == 'completed'
                                ? Icons.check
                                : (status == 'failed'
                                    ? Icons.close
                                    : Icons.schedule),
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        title: Text(goal,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: Text(
                            'Status: $status | ${steps.length} steps | ID: $planId',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                        trailing: ElevatedButton.icon(
                          icon: isBusy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.play_arrow, size: 16),
                          label:
                              Text(status == 'completed' ? 'Rerun' : 'Execute'),
                          onPressed:
                              _isExecuting ? null : () => _runPlan(planId),
                        ),
                        children: [
                          const Divider(height: 1),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: steps.length,
                            itemBuilder: (c, sIdx) {
                              final step = steps[sIdx] as Map<String, dynamic>;
                              final tool = step['tool'] ?? 'unknown';
                              final purpose = step['purpose'] ?? '';
                              final stepStatus = step['status'] ?? 'pending';

                              return ListTile(
                                dense: true,
                                leading: Text('${sIdx + 1}.',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                                title: Text(tool,
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 12)),
                                subtitle:
                                    purpose.isNotEmpty ? Text(purpose) : null,
                                trailing: Chip(
                                  label: Text(stepStatus,
                                      style: const TextStyle(fontSize: 10)),
                                  padding: EdgeInsets.zero,
                                  backgroundColor: stepStatus == 'success'
                                      ? Colors.green.withValues(alpha: 0.2)
                                      : Colors.grey.withValues(alpha: 0.2),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),

          // 2. Workflows Tab
          _workflows.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.account_tree_outlined,
                          size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      const Text('No Saved Workflows',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        'Create automated multi-step procedures or tell the assistant: "Save workflow..."',
                        style: TextStyle(
                            color: Colors.grey.shade400, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _workflows.length,
                  itemBuilder: (ctx, idx) {
                    final wf = _workflows[idx];
                    final name = wf['name'] as String;
                    final desc = (wf['description'] as String?) ?? '';
                    final steps = (wf['steps'] as List<dynamic>?) ?? [];
                    final isBusy = _isExecuting && _executingId == name;

                    final sched = _scheduledWorkflows.firstWhere(
                      (s) => s['workflow_name'] == name,
                      orElse: () => {},
                    );
                    final isScheduled = sched.isNotEmpty;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.indigoAccent,
                          child: Icon(Icons.flash_on,
                              color: Colors.white, size: 20),
                        ),
                        title: Text(name,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(desc.isNotEmpty
                                ? desc
                                : '${steps.length} automated steps'),
                            if (isScheduled) ...[
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.amberAccent
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: Colors.amberAccent, width: 0.5),
                                ),
                                child: Text(
                                  '⏰ Scheduled: Every ${sched['interval_seconds']}s',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.amberAccent,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                Icons.schedule,
                                color: isScheduled
                                    ? Colors.amberAccent
                                    : Colors.grey,
                                size: 20,
                              ),
                              tooltip: isScheduled
                                  ? 'Edit Schedule'
                                  : 'Schedule Recurring',
                              onPressed: () => _showScheduleDialog(name),
                            ),
                            IconButton(
                              icon: isBusy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.play_circle_fill,
                                      color: Colors.greenAccent, size: 28),
                              onPressed: _isExecuting
                                  ? null
                                  : () => _runWorkflow(name),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.redAccent, size: 20),
                              onPressed: () => _deleteWorkflow(name),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

          // 3. Sub-Agents Tab
          _agents.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.smart_toy_outlined,
                          size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      const Text('No Sub-Agents Active',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        'Autonomous sub-agents spawned for background reasoning appear here.',
                        style: TextStyle(
                            color: Colors.grey.shade400, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _agents.length,
                  itemBuilder: (ctx, idx) {
                    final agent = _agents[idx];
                    final agentId = agent['agent_id'] as String;
                    final role = agent['role'] as String;
                    final instructions = agent['instructions'] as String;
                    final status = agent['status'] as String;
                    final depth = agent['depth'] as int? ?? 1;
                    final stepsTaken = agent['steps_taken'] as int? ?? 0;
                    final maxSteps = agent['max_steps'] as int? ?? 10;
                    final allowedTools =
                        (agent['allowed_tools'] as List<dynamic>?) ?? [];
                    final result = agent['result'] as Map<String, dynamic>?;

                    final isRunning = status == 'running';

                    Color statusColor = Colors.grey;
                    if (status == 'completed') statusColor = Colors.green;
                    if (status == 'failed') statusColor = Colors.red;
                    if (status == 'running') statusColor = Colors.blueAccent;
                    if (status == 'cancelled') statusColor = Colors.amber;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor:
                                      statusColor.withValues(alpha: 0.2),
                                  child: Icon(
                                    isRunning
                                        ? Icons.autorenew
                                        : Icons.smart_toy,
                                    color: statusColor,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(role,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14)),
                                      Text('ID: $agentId (Depth: $depth)',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey)),
                                    ],
                                  ),
                                ),
                                Chip(
                                  label: Text(status.toUpperCase(),
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: statusColor)),
                                  backgroundColor:
                                      statusColor.withValues(alpha: 0.15),
                                  padding: EdgeInsets.zero,
                                ),
                                if (isRunning) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(Icons.cancel_outlined,
                                        color: Colors.redAccent, size: 20),
                                    onPressed: () => _cancelAgent(agentId),
                                    tooltip: 'Cancel Sub-Agent',
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(instructions,
                                style: const TextStyle(fontSize: 12)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text('Steps: $stepsTaken / $maxSteps',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.grey)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value:
                                        (stepsTaken / maxSteps).clamp(0.0, 1.0),
                                    backgroundColor: Colors.grey.shade800,
                                    color: statusColor,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              children: allowedTools
                                  .map((t) => Chip(
                                        label: Text(t.toString(),
                                            style:
                                                const TextStyle(fontSize: 10)),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                      ))
                                  .toList(),
                            ),
                            if (result != null) ...[
                              const Divider(height: 12),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'Result: ${result['summary'] ?? result.toString()}',
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: Colors.greenAccent),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ],
      ),
      floatingActionButton: _tabController.index == 1
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FloatingActionButton(
                    heroTag: 'sync_workflows',
                    onPressed: _isExecuting ? null : _syncWorkflowsFromPc,
                    tooltip: 'Sync Workflows from PC',
                    child: _isExecuting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.sync),
                  ),
                ),
                FloatingActionButton(
                  heroTag: 'add_workflow',
                  onPressed: _showAddWorkflowDialog,
                  tooltip: 'New Workflow',
                  child: const Icon(Icons.add),
                ),
              ],
            )
          : (_tabController.index == 2
              ? FloatingActionButton(
                  heroTag: 'spawn_subagent',
                  onPressed: _showAddSubAgentDialog,
                  tooltip: 'Spawn Sub-Agent',
                  child: const Icon(Icons.smart_toy_outlined),
                )
              : null),
    );
  }
}
