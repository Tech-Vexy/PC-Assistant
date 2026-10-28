import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Local database manager with encrypted/protected storage for memories,
/// workflows, active plans, audit records, and the undo transaction journal.
class LocalDatabase {
  Database? _db;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  /// Initializes the SQLite database file in the application support directory (or custom directory)
  Future<void> initialize(
      {String? passphrase, Directory? baseDirectory}) async {
    if (_isInitialized) return;

    final dir = baseDirectory ?? await getApplicationSupportDirectory();
    final dbDir = Directory(p.join(dir.path, 'assistant_data'));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }

    final dbPath = p.join(dbDir.path, 'device_assistant.db');
    _db = sqlite3.open(dbPath);

    // If a passphrase is provided, apply SQLCipher key pragma if supported
    if (passphrase != null && passphrase.isNotEmpty) {
      try {
        _db!.execute("PRAGMA key = '${passphrase.replaceAll("'", "''")}';");
      } catch (_) {
        // Fallback for standard SQLite builds
      }
    }

    _db!.execute('PRAGMA foreign_keys = ON;');
    _createTables();
    _isInitialized = true;
  }

  void _createTables() {
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS memories (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'general',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS workflows (
        name TEXT PRIMARY KEY,
        description TEXT,
        steps_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_workflows (
        id TEXT PRIMARY KEY,
        workflow_name TEXT NOT NULL,
        interval_seconds INTEGER NOT NULL,
        next_run_at INTEGER NOT NULL,
        last_run_at INTEGER,
        last_status TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS plans (
        plan_id TEXT PRIMARY KEY,
        goal TEXT NOT NULL,
        steps_json TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS undo_journal (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT,
        tool_name TEXT NOT NULL,
        description TEXT,
        reversal_json TEXT NOT NULL,
        applied INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS audit_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tool_name TEXT NOT NULL,
        args_json TEXT,
        result_json TEXT,
        is_blocked INTEGER NOT NULL DEFAULT 0,
        block_reason TEXT,
        timestamp INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS sensitive_packages (
        package_name TEXT PRIMARY KEY,
        added_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS agents (
        agent_id TEXT PRIMARY KEY,
        parent_id TEXT,
        role TEXT NOT NULL,
        instructions TEXT NOT NULL,
        allowed_tools_json TEXT NOT NULL,
        isolation TEXT NOT NULL DEFAULT 'shared',
        status TEXT NOT NULL,
        depth INTEGER NOT NULL DEFAULT 1,
        steps_taken INTEGER NOT NULL DEFAULT 0,
        max_steps INTEGER NOT NULL DEFAULT 10,
        result_json TEXT,
        error TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS agent_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL
      );
    ''');
  }

  // --- MEMORY OPERATIONS ---

  void remember(String key, String value, {String category = 'general'}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO memories (key, value, category, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        category = excluded.category,
        updated_at = excluded.updated_at;
    ''');
    stmt.execute([key, value, category, now, now]);
    stmt.close();
  }

  String? recall(String key) {
    final stmt = _db!.prepare('SELECT value FROM memories WHERE key = ?');
    final result = stmt.select([key]);
    stmt.close();
    if (result.isNotEmpty) {
      return result.first['value'] as String?;
    }
    return null;
  }

  List<Map<String, dynamic>> listMemories({String? category}) {
    ResultSet result;
    if (category != null) {
      final stmt = _db!.prepare(
          'SELECT * FROM memories WHERE category = ? ORDER BY updated_at DESC');
      result = stmt.select([category]);
      stmt.close();
    } else {
      result = _db!.select('SELECT * FROM memories ORDER BY updated_at DESC');
    }
    return result.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  bool forget(String key) {
    final stmt = _db!.prepare('DELETE FROM memories WHERE key = ?');
    stmt.execute([key]);
    final changes = _db!.updatedRows;
    stmt.close();
    return changes > 0;
  }

  // --- AUDIT OPERATIONS ---

  void logAudit({
    required String toolName,
    Map<String, dynamic>? args,
    dynamic result,
    bool isBlocked = false,
    String? blockReason,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO audit_logs (tool_name, args_json, result_json, is_blocked, block_reason, timestamp)
      VALUES (?, ?, ?, ?, ?, ?);
    ''');
    stmt.execute([
      toolName,
      args != null ? jsonEncode(args) : null,
      result != null ? jsonEncode(result) : null,
      isBlocked ? 1 : 0,
      blockReason,
      now,
    ]);
    stmt.close();
  }

  List<Map<String, dynamic>> getRecentAudits({int limit = 50}) {
    final stmt = _db!
        .prepare('SELECT * FROM audit_logs ORDER BY timestamp DESC LIMIT ?');
    final result = stmt.select([limit]);
    stmt.close();
    return result.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  // --- UNDO JOURNAL OPERATIONS ---

  int recordUndo({
    String? sessionId,
    required String toolName,
    String? description,
    required Map<String, dynamic> reversalData,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO undo_journal (session_id, tool_name, description, reversal_json, applied, created_at)
      VALUES (?, ?, ?, ?, 0, ?);
    ''');
    stmt.execute(
        [sessionId, toolName, description, jsonEncode(reversalData), now]);
    final id = _db!.lastInsertRowId;
    stmt.close();
    return id;
  }

  Map<String, dynamic>? getLatestPendingUndo() {
    final result = _db!.select(
      'SELECT * FROM undo_journal WHERE applied = 0 ORDER BY id DESC LIMIT 1',
    );
    if (result.isNotEmpty) {
      return Map<String, dynamic>.from(result.first);
    }
    return null;
  }

  void markUndoApplied(int id) {
    final stmt =
        _db!.prepare('UPDATE undo_journal SET applied = 1 WHERE id = ?');
    stmt.execute([id]);
    stmt.close();
  }

  // --- WORKFLOW OPERATIONS ---

  void saveWorkflow(String name,
      {String? description, required List<Map<String, dynamic>> steps}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO workflows (name, description, steps_json, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(name) DO UPDATE SET
        description = excluded.description,
        steps_json = excluded.steps_json;
    ''');
    stmt.execute([name, description, jsonEncode(steps), now]);
    stmt.close();
  }

  Map<String, dynamic>? getWorkflow(String name) {
    final stmt = _db!.prepare('SELECT * FROM workflows WHERE name = ?');
    final result = stmt.select([name]);
    stmt.close();
    if (result.isNotEmpty) {
      final row = Map<String, dynamic>.from(result.first);
      try {
        row['steps'] = jsonDecode(row['steps_json'] as String);
      } catch (_) {
        row['steps'] = [];
      }
      return row;
    }
    return null;
  }

  List<Map<String, dynamic>> listWorkflows() {
    final result =
        _db!.select('SELECT * FROM workflows ORDER BY created_at DESC');
    return result.map((row) {
      final map = Map<String, dynamic>.from(row);
      try {
        map['steps'] = jsonDecode(map['steps_json'] as String);
      } catch (_) {
        map['steps'] = [];
      }
      return map;
    }).toList();
  }

  bool deleteWorkflow(String name) {
    final stmt = _db!.prepare('DELETE FROM workflows WHERE name = ?');
    stmt.execute([name]);
    final changes = _db!.updatedRows;
    stmt.close();
    return changes > 0;
  }

  // --- SCHEDULED WORKFLOW OPERATIONS ---

  void saveScheduledWorkflow({
    required String id,
    required String workflowName,
    required int intervalSeconds,
    required int nextRunAt,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO scheduled_workflows (id, workflow_name, interval_seconds, next_run_at, is_active, created_at)
      VALUES (?, ?, ?, ?, 1, ?)
      ON CONFLICT(id) DO UPDATE SET
        workflow_name = excluded.workflow_name,
        interval_seconds = excluded.interval_seconds,
        next_run_at = excluded.next_run_at,
        is_active = 1;
    ''');
    stmt.execute([id, workflowName, intervalSeconds, nextRunAt, now]);
    stmt.close();
  }

  List<Map<String, dynamic>> listScheduledWorkflows() {
    final result = _db!
        .select('SELECT * FROM scheduled_workflows ORDER BY next_run_at ASC');
    return result.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Map<String, dynamic>? getScheduledWorkflow(String id) {
    final stmt = _db!.prepare('SELECT * FROM scheduled_workflows WHERE id = ?');
    final result = stmt.select([id]);
    stmt.close();
    if (result.isNotEmpty) {
      return Map<String, dynamic>.from(result.first);
    }
    return null;
  }

  void updateScheduledWorkflowRun({
    required String id,
    required int lastRunAt,
    required int nextRunAt,
    required String lastStatus,
  }) {
    final stmt = _db!.prepare('''
      UPDATE scheduled_workflows
      SET last_run_at = ?, next_run_at = ?, last_status = ?
      WHERE id = ?
    ''');
    stmt.execute([lastRunAt, nextRunAt, lastStatus, id]);
    stmt.close();
  }

  bool deleteScheduledWorkflow(String id) {
    final stmt = _db!.prepare('DELETE FROM scheduled_workflows WHERE id = ?');
    stmt.execute([id]);
    final changes = _db!.updatedRows;
    stmt.close();
    return changes > 0;
  }

  // --- PLAN OPERATIONS ---

  void savePlan({
    required String planId,
    required String goal,
    required List<Map<String, dynamic>> steps,
    String status = 'planned',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO plans (plan_id, goal, steps_json, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(plan_id) DO UPDATE SET
        goal = excluded.goal,
        steps_json = excluded.steps_json,
        status = excluded.status,
        updated_at = excluded.updated_at;
    ''');
    stmt.execute([planId, goal, jsonEncode(steps), status, now, now]);
    stmt.close();
  }

  Map<String, dynamic>? getPlan(String planId) {
    final stmt = _db!.prepare('SELECT * FROM plans WHERE plan_id = ?');
    final result = stmt.select([planId]);
    stmt.close();
    if (result.isNotEmpty) {
      final row = Map<String, dynamic>.from(result.first);
      try {
        row['steps'] = jsonDecode(row['steps_json'] as String);
      } catch (_) {
        row['steps'] = [];
      }
      return row;
    }
    return null;
  }

  void updatePlanStatus(String planId, String status,
      {List<Map<String, dynamic>>? steps}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (steps != null) {
      final stmt = _db!.prepare('''
        UPDATE plans SET status = ?, steps_json = ?, updated_at = ? WHERE plan_id = ?
      ''');
      stmt.execute([status, jsonEncode(steps), now, planId]);
      stmt.close();
    } else {
      final stmt = _db!.prepare(
          'UPDATE plans SET status = ?, updated_at = ? WHERE plan_id = ?');
      stmt.execute([status, now, planId]);
      stmt.close();
    }
  }

  List<Map<String, dynamic>> listPlans() {
    final result = _db!.select('SELECT * FROM plans ORDER BY updated_at DESC');
    return result.map((row) {
      final map = Map<String, dynamic>.from(row);
      try {
        map['steps'] = jsonDecode(map['steps_json'] as String);
      } catch (_) {
        map['steps'] = [];
      }
      return map;
    }).toList();
  }

  // --- SENSITIVE PACKAGES ---

  Set<String> loadCustomProtectedPackages() {
    final result = _db!.select('SELECT package_name FROM sensitive_packages');
    return result
        .map((r) => (r['package_name'] as String).toLowerCase())
        .toSet();
  }

  void saveProtectedPackage(String packageName) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare(
        'INSERT OR IGNORE INTO sensitive_packages (package_name, added_at) VALUES (?, ?)');
    stmt.execute([packageName.toLowerCase(), now]);
    stmt.close();
  }

  void removeProtectedPackage(String packageName) {
    final stmt =
        _db!.prepare('DELETE FROM sensitive_packages WHERE package_name = ?');
    stmt.execute([packageName.toLowerCase()]);
    stmt.close();
  }

  // --- SUB-AGENT OPERATIONS ---

  void saveAgent({
    required String agentId,
    String? parentId,
    required String role,
    required String instructions,
    required List<String> allowedTools,
    String isolation = 'shared',
    String status = 'idle',
    int depth = 1,
    int maxSteps = 10,
    int stepsTaken = 0,
    Map<String, dynamic>? result,
    String? error,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO agents (
        agent_id, parent_id, role, instructions, allowed_tools_json,
        isolation, status, depth, steps_taken, max_steps, result_json, error,
        created_at, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(agent_id) DO UPDATE SET
        status = excluded.status,
        steps_taken = excluded.steps_taken,
        result_json = excluded.result_json,
        error = excluded.error,
        updated_at = excluded.updated_at;
    ''');
    stmt.execute([
      agentId,
      parentId,
      role,
      instructions,
      jsonEncode(allowedTools),
      isolation,
      status,
      depth,
      stepsTaken,
      maxSteps,
      result != null ? jsonEncode(result) : null,
      error,
      now,
      now,
    ]);
    stmt.close();
  }

  void updateAgentStatus(
    String agentId,
    String status, {
    int? stepsTaken,
    Map<String, dynamic>? result,
    String? error,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = getAgent(agentId);
    if (existing == null) return;

    final updatedSteps = stepsTaken ?? (existing['steps_taken'] as int? ?? 0);
    final resultJson =
        result != null ? jsonEncode(result) : existing['result_json'];
    final finalError = error ?? existing['error'];

    final stmt = _db!.prepare('''
      UPDATE agents
      SET status = ?, steps_taken = ?, result_json = ?, error = ?, updated_at = ?
      WHERE agent_id = ?;
    ''');
    stmt.execute([status, updatedSteps, resultJson, finalError, now, agentId]);
    stmt.close();
  }

  Map<String, dynamic>? getAgent(String agentId) {
    final stmt = _db!.prepare('SELECT * FROM agents WHERE agent_id = ?');
    final res = stmt.select([agentId]);
    stmt.close();
    if (res.isNotEmpty) {
      final row = Map<String, dynamic>.from(res.first);
      try {
        row['allowed_tools'] = jsonDecode(row['allowed_tools_json'] as String);
      } catch (_) {
        row['allowed_tools'] = [];
      }
      if (row['result_json'] != null) {
        try {
          row['result'] = jsonDecode(row['result_json'] as String);
        } catch (_) {}
      }
      return row;
    }
    return null;
  }

  List<Map<String, dynamic>> listAgents({String? status, int limit = 50}) {
    ResultSet res;
    if (status != null) {
      final stmt = _db!.prepare(
          'SELECT * FROM agents WHERE status = ? ORDER BY updated_at DESC LIMIT ?');
      res = stmt.select([status, limit]);
      stmt.close();
    } else {
      final stmt =
          _db!.prepare('SELECT * FROM agents ORDER BY updated_at DESC LIMIT ?');
      res = stmt.select([limit]);
      stmt.close();
    }

    return res.map((r) {
      final map = Map<String, dynamic>.from(r);
      try {
        map['allowed_tools'] = jsonDecode(map['allowed_tools_json'] as String);
      } catch (_) {
        map['allowed_tools'] = [];
      }
      if (map['result_json'] != null) {
        try {
          map['result'] = jsonDecode(map['result_json'] as String);
        } catch (_) {}
      }
      return map;
    }).toList();
  }

  bool cancelAgent(String agentId) {
    final stmt = _db!.prepare(
        "UPDATE agents SET status = 'cancelled', updated_at = ? WHERE agent_id = ?");
    stmt.execute([DateTime.now().millisecondsSinceEpoch, agentId]);
    final updated = _db!.updatedRows > 0;
    stmt.close();
    return updated;
  }

  void addAgentMessage(String agentId, String sender, String content) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO agent_messages (agent_id, sender, content, timestamp)
      VALUES (?, ?, ?, ?);
    ''');
    stmt.execute([agentId, sender, content, now]);
    stmt.close();
  }

  List<Map<String, dynamic>> getAgentMessages(String agentId) {
    final stmt = _db!.prepare(
        'SELECT * FROM agent_messages WHERE agent_id = ? ORDER BY timestamp ASC');
    final res = stmt.select([agentId]);
    stmt.close();
    return res.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  void close() {
    _db?.close();
    _db = null;
    _isInitialized = false;
  }
}
