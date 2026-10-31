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
    _migrateSchema();
    _isInitialized = true;
  }

  void _createTables() {
    // ── Memories (rich schema with FTS5 + vector support) ──────────────────
    // First-time creation uses the full new schema.
    // Existing DBs are migrated in _migrateSchema().
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS memories_v2 (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        content     TEXT NOT NULL,
        category    TEXT NOT NULL DEFAULT 'general',
        source      TEXT NOT NULL DEFAULT 'manual',
        importance  REAL NOT NULL DEFAULT 0.5,
        embedding   TEXT,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      );
    ''');

    // FTS5 virtual table for BM25 keyword search over memory content
    _db!.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
        USING fts5(content, content=memories_v2, content_rowid=id);
    ''');

    // Triggers to keep FTS5 index in sync with memories_v2
    _db!.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_v2_ai
        AFTER INSERT ON memories_v2 BEGIN
          INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
        END;
    ''');
    _db!.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_v2_au
        AFTER UPDATE ON memories_v2 BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, content) VALUES ('delete', old.id, old.content);
          INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
        END;
    ''');
    _db!.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_v2_ad
        AFTER DELETE ON memories_v2 BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, content) VALUES ('delete', old.id, old.content);
        END;
    ''');

    // ── Legacy memories table (kept for backward compat, migrated on open) ──
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

    // ── Hermes-Style Workflow Skills & Version Ledger ─────────────────────────
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS workflow_skills (
        name TEXT PRIMARY KEY,
        description TEXT,
        version TEXT NOT NULL DEFAULT '1.0.0',
        platforms_json TEXT NOT NULL DEFAULT '["android","linux","windows","macos"]',
        parameters_json TEXT NOT NULL DEFAULT '{}',
        content_markdown TEXT NOT NULL,
        steps_json TEXT NOT NULL DEFAULT '[]',
        tags_json TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS workflow_versions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_name TEXT NOT NULL,
        version TEXT NOT NULL,
        content_markdown TEXT NOT NULL,
        change_summary TEXT,
        author TEXT NOT NULL DEFAULT 'assistant',
        timestamp INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_workflow_versions_name
        ON workflow_versions(workflow_name);
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

    // ── Conversation sessions & messages (for context + repetition guard) ──
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS conversation_sessions (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        title      TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS conversation_messages (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id  INTEGER NOT NULL
                      REFERENCES conversation_sessions(id) ON DELETE CASCADE,
        role        TEXT NOT NULL,
        content     TEXT NOT NULL,
        created_at  INTEGER NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_conv_messages_session
        ON conversation_messages(session_id);
    ''');
  }

  /// Runs schema migrations for existing databases.
  void _migrateSchema() {
    // Migrate legacy flat memories → memories_v2 (run once)
    final hasMigrated = _db!
        .select("SELECT COUNT(*) AS c FROM memories_v2")
        .first['c'] as int;
    if (hasMigrated == 0) {
      try {
        final legacyRows = _db!.select('SELECT * FROM memories');
        if (legacyRows.isNotEmpty) {
          final now = DateTime.now().millisecondsSinceEpoch;
          for (final row in legacyRows) {
            final content = '${row["key"]}: ${row["value"]}';
            final stmt = _db!.prepare('''
              INSERT INTO memories_v2
                (content, category, source, importance, created_at, updated_at)
              VALUES (?, ?, 'manual', 0.5, ?, ?)
            ''');
            stmt.execute([content, row['category'] ?? 'general', now, now]);
            stmt.close();
          }
        }
      } catch (_) {
        // Legacy table may not exist in fresh installs — safe to skip
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // RAW QUERY HELPERS (used by MemoryRecallEngine)
  // ─────────────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> rawSelect(String sql, List<Object?> params) {
    final stmt = _db!.prepare(sql);
    final result = stmt.select(params);
    stmt.close();
    return result.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  void rawExecute(String sql, List<Object?> params) {
    final stmt = _db!.prepare(sql);
    stmt.execute(params);
    stmt.close();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // RICH MEMORY OPERATIONS (memories_v2 + FTS5 + vector)
  // ─────────────────────────────────────────────────────────────────────────

  /// Saves a distilled memory fact. Returns the new memory's id.
  ///
  /// Performs fuzzy deduplication before inserting:
  ///   - Exact match → skipped (returns -1)
  ///   - Jaccard similarity ≥ 0.82 → duplicate, skipped (returns -1)
  ///   - Jaccard similarity 0.55–0.82 → stale superseded, new record inserted
  int saveMemory({
    required String content,
    String category = 'general',
    String source = 'manual',
    double importance = 0.5,
    String? embedding,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final trimmed = content.trim().substring(0, content.length > 200 ? 200 : content.length);
    if (trimmed.isEmpty) return -1;

    // Fuzzy dedup check
    final existing = _db!.select(
      'SELECT id, content FROM memories_v2 ORDER BY id DESC LIMIT 80',
    );

    final newWords = _keywordSet(trimmed);
    int? supersededId;

    for (final row in existing) {
      final ex = row['content'] as String;
      if (ex == trimmed) return -1; // exact duplicate

      final exWords = _keywordSet(ex);
      if (exWords.isEmpty || newWords.isEmpty) continue;

      final overlap = newWords.intersection(exWords).length;
      final similarity = overlap / (exWords.length > newWords.length ? exWords.length : newWords.length);

      if (similarity >= 0.82) return -1; // near-duplicate
      if (similarity >= 0.55) {
        supersededId = row['id'] as int; // stale memory — supersede
        break;
      }
    }

    // Remove stale superseded record
    if (supersededId != null) {
      _db!.execute('DELETE FROM memories_v2 WHERE id = ?', [supersededId]);
    }

    final stmt = _db!.prepare('''
      INSERT INTO memories_v2
        (content, category, source, importance, embedding, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    ''');
    stmt.execute([trimmed, category, source, importance, embedding, now, now]);
    final id = _db!.lastInsertRowId;
    stmt.close();
    return id;
  }

  /// Retrieves a memory by id.
  Map<String, dynamic>? getMemoryById(int id) {
    final result = _db!.select(
      'SELECT * FROM memories_v2 WHERE id = ?',
      [id],
    );
    if (result.isEmpty) return null;
    return Map<String, dynamic>.from(result.first);
  }

  /// Updates the embedding of an existing memory.
  void updateMemoryEmbedding(int id, String embeddingJson) {
    final stmt = _db!.prepare(
      'UPDATE memories_v2 SET embedding = ? WHERE id = ?',
    );
    stmt.execute([embeddingJson, id]);
    stmt.close();
  }

  /// Deletes a memory and removes it from the FTS index.
  bool deleteMemory(int id) {
    _db!.execute('DELETE FROM memories_v2 WHERE id = ?', [id]);
    return _db!.updatedRows > 0;
  }

  /// Lists rich memories with optional category filter.
  List<Map<String, dynamic>> listRichMemories({String? category, int limit = 100}) {
    if (category != null) {
      final stmt = _db!.prepare(
        'SELECT * FROM memories_v2 WHERE category = ? ORDER BY importance DESC, updated_at DESC LIMIT ?',
      );
      final result = stmt.select([category, limit]);
      stmt.close();
      return result.map((r) => Map<String, dynamic>.from(r)).toList();
    }
    final stmt = _db!.prepare(
      'SELECT * FROM memories_v2 ORDER BY importance DESC, updated_at DESC LIMIT ?',
    );
    final result = stmt.select([limit]);
    stmt.close();
    return result.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Set<String> _keywordSet(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 3)
        .toSet();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONVERSATION SESSION & MESSAGE OPERATIONS
  // ─────────────────────────────────────────────────────────────────────────

  /// Creates a new conversation session and returns its id.
  int createConversationSession({String title = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO conversation_sessions (title, created_at, updated_at)
      VALUES (?, ?, ?)
    ''');
    stmt.execute([title, now, now]);
    final id = _db!.lastInsertRowId;
    stmt.close();
    return id;
  }

  /// Updates the title of a conversation session.
  void updateSessionTitle(int sessionId, String title) {
    final stmt = _db!.prepare(
      'UPDATE conversation_sessions SET title = ?, updated_at = ? WHERE id = ?',
    );
    stmt.execute([title, DateTime.now().millisecondsSinceEpoch, sessionId]);
    stmt.close();
  }

  /// Appends a message to a conversation session.
  int addConversationMessage({
    required int sessionId,
    required String role,
    required String content,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = _db!.prepare('''
      INSERT INTO conversation_messages (session_id, role, content, created_at)
      VALUES (?, ?, ?, ?)
    ''');
    stmt.execute([sessionId, role, content, now]);
    final id = _db!.lastInsertRowId;
    stmt.close();
    // Touch session updated_at
    _db!.execute(
      'UPDATE conversation_sessions SET updated_at = ? WHERE id = ?',
      [now, sessionId],
    );
    return id;
  }

  /// Returns messages for a session, oldest first.
  List<Map<String, dynamic>> getConversationMessages(int sessionId,
      {int limit = 50}) {
    final stmt = _db!.prepare('''
      SELECT * FROM conversation_messages
      WHERE session_id = ?
      ORDER BY created_at ASC
      LIMIT ?
    ''');
    final result = stmt.select([sessionId, limit]);
    stmt.close();
    return result.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Returns recent sessions, newest first.
  List<Map<String, dynamic>> listConversationSessions({int limit = 20}) {
    final stmt = _db!.prepare('''
      SELECT * FROM conversation_sessions
      ORDER BY updated_at DESC
      LIMIT ?
    ''');
    final result = stmt.select([limit]);
    stmt.close();
    return result.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LEGACY MEMORY OPERATIONS (backward compat — kept for ToolDispatcher)
  // ─────────────────────────────────────────────────────────────────────────

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

    // Also clean up skill tables if present
    _db!.execute('DELETE FROM workflow_skills WHERE name = ?', [name]);
    return changes > 0;
  }

  // ── Hermes-Style Workflow Skill CRUD & Version Ledger ──────────────────────

  /// Saves or updates a Hermes-format workflow skill with version ledger tracking.
  void saveWorkflowSkill({
    required String name,
    required String description,
    required String contentMarkdown,
    String version = '1.0.0',
    List<String> platforms = const ['android', 'linux', 'windows', 'macos'],
    Map<String, dynamic> parameters = const {},
    List<Map<String, dynamic>> steps = const [],
    List<String> tags = const [],
    String changeSummary = 'Initial skill creation',
    String author = 'assistant',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Upsert into main workflow_skills table
    final stmt = _db!.prepare('''
      INSERT INTO workflow_skills (
        name, description, version, platforms_json, parameters_json,
        content_markdown, steps_json, tags_json, created_at, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(name) DO UPDATE SET
        description = excluded.description,
        version = excluded.version,
        platforms_json = excluded.platforms_json,
        parameters_json = excluded.parameters_json,
        content_markdown = excluded.content_markdown,
        steps_json = excluded.steps_json,
        tags_json = excluded.tags_json,
        updated_at = excluded.updated_at;
    ''');
    stmt.execute([
      name,
      description,
      version,
      jsonEncode(platforms),
      jsonEncode(parameters),
      contentMarkdown,
      jsonEncode(steps),
      jsonEncode(tags),
      now,
      now,
    ]);
    stmt.close();

    // 2. Also sync to legacy `workflows` table for backward compatibility with executor
    saveWorkflow(name, description: description, steps: steps);

    // 3. Record in append-only version ledger
    final ledgerStmt = _db!.prepare('''
      INSERT INTO workflow_versions (
        workflow_name, version, content_markdown, change_summary, author, timestamp
      )
      VALUES (?, ?, ?, ?, ?, ?);
    ''');
    ledgerStmt.execute([
      name,
      version,
      contentMarkdown,
      changeSummary,
      author,
      now,
    ]);
    ledgerStmt.close();
  }

  /// Retrieves a workflow skill with metadata and full markdown instructions.
  Map<String, dynamic>? getWorkflowSkill(String name) {
    final stmt = _db!.prepare('SELECT * FROM workflow_skills WHERE name = ?');
    final result = stmt.select([name]);
    stmt.close();
    if (result.isNotEmpty) {
      final row = Map<String, dynamic>.from(result.first);
      try {
        row['platforms'] = jsonDecode(row['platforms_json'] as String? ?? '[]');
        row['parameters'] = jsonDecode(row['parameters_json'] as String? ?? '{}');
        row['steps'] = jsonDecode(row['steps_json'] as String? ?? '[]');
        row['tags'] = jsonDecode(row['tags_json'] as String? ?? '[]');
      } catch (_) {}
      return row;
    }
    return null;
  }

  /// Lists all skills in compact form for progressive disclosure (names + brief description).
  List<Map<String, dynamic>> listWorkflowSkillsSummary() {
    final result = _db!.select('''
      SELECT name, description, version, tags_json, updated_at
      FROM workflow_skills
      ORDER BY updated_at DESC
    ''');
    return result.map((r) {
      final map = Map<String, dynamic>.from(r);
      try {
        map['tags'] = jsonDecode(map['tags_json'] as String? ?? '[]');
      } catch (_) {
        map['tags'] = [];
      }
      return map;
    }).toList();
  }

  /// Retrieves version history from the audit ledger for a specific workflow.
  List<Map<String, dynamic>> getWorkflowVersions(String name) {
    final stmt = _db!.prepare('''
      SELECT * FROM workflow_versions
      WHERE workflow_name = ?
      ORDER BY id DESC
    ''');
    final result = stmt.select([name]);
    stmt.close();
    return result.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Rolls back a workflow skill to a specific historical version from the ledger.
  bool rollbackWorkflowSkill(String name, int versionId) {
    final stmt = _db!.prepare('''
      SELECT * FROM workflow_versions
      WHERE workflow_name = ? AND id = ?
    ''');
    final result = stmt.select([name, versionId]);
    stmt.close();
    if (result.isEmpty) return false;

    final targetVersion = result.first;
    final contentMarkdown = targetVersion['content_markdown'] as String;
    final ver = targetVersion['version'] as String;

    saveWorkflowSkill(
      name: name,
      description: 'Rolled back to version #$versionId ($ver)',
      contentMarkdown: contentMarkdown,
      version: '$ver-rollback',
      changeSummary: 'Rollback to ledger ID #$versionId',
      author: 'rollback',
    );
    return true;
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
