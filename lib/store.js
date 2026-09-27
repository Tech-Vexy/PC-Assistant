// Central DuckDB store: config/credentials, OAuth tokens, voice sessions,
// tool + security audit logs. Replaces .env (runtime), tokens.json,
// .session-state.json, tool-audit.log, and security-audit.log.
//
// Single-writer architecture: DuckDB does not allow concurrent read-write
// opens of one file from multiple processes, so ONLY the server process
// opens the DB. The voice-agent process uses REMOTE mode (HTTP delegation to
// the server — same X-Requested-With pattern as approval delegation).
//
//   server / scripts / tests:  await initStore();            // local RW
//   voice agent:               await initStore({ remote });  // via server
//
// Config precedence (highest first): process.env > DB > built-in default.
// The legacy .env file is only a first-run SEED (migrated once); the /setup
// UI reads/writes the DB (mirroring bootstrap keys PORT/AUDIO_*/WAKEWORD_*
// back to the file, since those are needed before the DB can be reached).
//
// DB path: process.env.STORE_PATH || <cwd>/data/assistant.db (gitignored).
// All audit writes are best-effort and never throw (logging must not break
// tool execution). If the DB cannot be opened, the store degrades to
// memory-empty + console-only auditing.

import fs from 'fs/promises';
import path from 'path';

const REMOTE_HEADER = 'pc-assistant-agent';
const REMOTE_TIMEOUT_MS = 8000;

function storePath() {
  return process.env.STORE_PATH || path.join(process.cwd(), 'data', 'assistant.db');
}

// ---------- mode state ----------
let mode = null; // 'local' | 'remote' | 'degraded'
let instance = null;
let conn = null;
let remoteBase = null;
let remoteConfigCache = {};
let configCache = {}; // local memory copy of the config table
let initPromise = null;
let degradedWarned = false;

export function storeMode() {
  return mode;
}

function degrade(reason) {
  if (!degradedWarned) {
    degradedWarned = true;
    console.warn(`⚠️  Store unavailable (${reason}) — running degraded (env-only config, console-only audit).`);
  }
  mode = 'degraded';
}

export async function initStore(opts = {}) {
  if (mode && (opts.remote === undefined || (opts.remote && mode === 'remote') || (!opts.remote && mode === 'local'))) {
    return mode;
  }
  if (initPromise) {
    await initPromise;
    return mode;
  }
  initPromise = (async () => {
    if (opts.remote) {
      remoteBase = String(opts.remote).replace(/\/+$/, '');
      mode = 'remote';
      try {
        remoteConfigCache = await remoteGet('/api/store/config').then((r) => r.config || {});
      } catch (err) {
        degrade(`remote config unreachable: ${err.message}`);
      }
      return mode;
    }
    // Local read-write open (server, scripts, tests).
    try {
      const { DuckDBInstance } = await import('@duckdb/node-api');
      const dbFile = storePath();
      await fs.mkdir(path.dirname(dbFile), { recursive: true });
      instance = await DuckDBInstance.create(dbFile);
      conn = await instance.connect();
      await createSchema();
      await migrateFromFiles();
      await refreshConfigCache();
      mode = 'local';
    } catch (err) {
      try {
        await closeHandles();
      } catch {
        /* noop */
      }
      instance = null;
      conn = null;
      degrade(err.message);
    }
    return mode;
  })();
  const m = await initPromise;
  initPromise = null;
  return m;
}

export async function ensureStore(opts = {}) {
  if (!mode) await initStore(opts);
  return mode;
}

async function closeHandles() {
  if (conn) {
    try {
      if (typeof conn.close === 'function') await conn.close();
      else if (typeof conn.closeSync === 'function') conn.closeSync();
    } catch {
      /* noop */
    }
    conn = null;
  }
  if (instance) {
    try {
      if (typeof instance.close === 'function') await instance.close();
      else if (typeof instance.closeSync === 'function') instance.closeSync();
    } catch {
      /* noop */
    }
    instance = null;
  }
}

export async function closeStore() {
  await closeHandles();
  mode = null;
  remoteBase = null;
  remoteConfigCache = {};
  configCache = {};
}

// ---------- schema ----------
async function createSchema() {
  await conn.run(`CREATE TABLE IF NOT EXISTS config(
    key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '', updated_at TIMESTAMPTZ DEFAULT now())`);
  await conn.run(`CREATE TABLE IF NOT EXISTS oauth_tokens(
    provider TEXT PRIMARY KEY, tokens TEXT NOT NULL, updated_at TIMESTAMPTZ DEFAULT now())`);
  await conn.run(`CREATE TABLE IF NOT EXISTS sessions(
    id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at TIMESTAMPTZ DEFAULT now())`);
  await conn.run(`CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
  await conn.run(`CREATE SEQUENCE IF NOT EXISTS seq_tool_audit`);
  await conn.run(`CREATE SEQUENCE IF NOT EXISTS seq_security_audit`);
  await conn.run(`CREATE TABLE IF NOT EXISTS tool_audit(
    id BIGINT PRIMARY KEY DEFAULT nextval('seq_tool_audit'),
    ts TIMESTAMPTZ, tool TEXT, args TEXT, result TEXT, error TEXT, extra TEXT)`);
  await conn.run(`CREATE TABLE IF NOT EXISTS security_audit(
    id BIGINT PRIMARY KEY DEFAULT nextval('seq_security_audit'),
    ts TIMESTAMPTZ, event TEXT, details TEXT, severity TEXT)`);
  // Phase 1 memory: semantic facts (preferences, locations, projects, facts)
  // + procedural workflows (named multi-step tool sequences).
  await conn.run(`CREATE TABLE IF NOT EXISTS memories(
    key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'fact', updated_at TIMESTAMPTZ DEFAULT now())`);
  await conn.run(`CREATE TABLE IF NOT EXISTS workflows(
    name TEXT PRIMARY KEY, steps TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
    use_count INTEGER NOT NULL DEFAULT 0, success_count INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT now())`);
  // Phase 3 planner: task plans with checkpoints (goal, steps, per-step
  // results, status, resume cursor).
  await conn.run(`CREATE TABLE IF NOT EXISTS plans(
    id TEXT PRIMARY KEY, goal TEXT NOT NULL, steps TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'planned', current_step INTEGER NOT NULL DEFAULT 0,
    results TEXT NOT NULL DEFAULT '[]', error TEXT,
    created_at TIMESTAMPTZ DEFAULT now(), updated_at TIMESTAMPTZ DEFAULT now())`);
  // Phase 4 sub-agents: spawned specialists with role, tool allowlist,
  // budget, lifecycle status, parent linkage, and message inbox.
  await conn.run(`CREATE TABLE IF NOT EXISTS agents(
    id TEXT PRIMARY KEY, parent_id TEXT, role TEXT NOT NULL,
    instructions TEXT NOT NULL DEFAULT '', allowed_tools TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'spawned', budget TEXT NOT NULL DEFAULT '{}',
    depth INTEGER NOT NULL DEFAULT 0, result TEXT, error TEXT,
    messages TEXT NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ DEFAULT now(), updated_at TIMESTAMPTZ DEFAULT now())`);
}

async function metaGet(k) {
  try {
    const r = await conn.runAndReadAll('SELECT v FROM meta WHERE k = ?', [k]);
    const rows = r.getRowObjects();
    return rows.length ? rows[0].v : null;
  } catch {
    return null;
  }
}

async function metaSet(k, v) {
  await conn.run('INSERT INTO meta(k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', [k, v]);
}

// ---------- JSON-safe row mapping ----------
// @duckdb/node-api returns BIGINT as BigInt and TIMESTAMPTZ as a
// DuckDBTimestampTZValue (micros: BigInt) — both crash JSON.stringify,
// which in Express 4 async handlers hangs the request instead of failing.
// Every row crossing an HTTP boundary goes through here.
function jsonSafe(value) {
  if (typeof value === 'bigint') return Number(value);
  if (value instanceof Date) return value.toISOString();
  if (value && typeof value === 'object') {
    const name = Object.getPrototypeOf(value)?.constructor?.name || '';
    if (name.includes('Timestamp') && typeof value.micros === 'bigint') {
      return new Date(Number(value.micros) / 1000).toISOString();
    }
  }
  return value;
}

function jsonSafeRow(row) {
  const out = {};
  for (const [k, v] of Object.entries(row || {})) out[k] = jsonSafe(v);
  return out;
}

// ---------- config ----------
// Sync read: process.env wins when set (12-factor + tests), else DB cache.
export function cfg(key, def = '') {
  if (process.env[key] !== undefined) return process.env[key];
  if (mode === 'remote') return remoteConfigCache[key] ?? def;
  return configCache[key] ?? def;
}

export async function getConfig(key, def = '') {
  await ensureStore();
  if (mode === 'remote') return remoteConfigCache[key] ?? def;
  if (mode !== 'local') return process.env[key] ?? def;
  try {
    const r = await conn.runAndReadAll('SELECT value FROM config WHERE key = ?', [key]);
    const rows = r.getRowObjects();
    return rows.length ? rows[0].value : def;
  } catch {
    return def;
  }
}

export async function setConfig(key, value) {
  await ensureStore();
  if (mode === 'remote') {
    await remotePost('/api/store/config', { key, value });
    remoteConfigCache[key] = String(value);
    return;
  }
  if (mode !== 'local') return;
  await conn.run(
    'INSERT INTO config(key, value, updated_at) VALUES (?, ?, now()) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = now()',
    [key, String(value)]
  );
  configCache[key] = String(value);
}

export async function allConfig() {
  await ensureStore();
  if (mode === 'remote') return { ...remoteConfigCache };
  if (mode !== 'local') return {};
  return { ...configCache };
}

async function refreshConfigCache() {
  const r = await conn.runAndReadAll('SELECT key, value FROM config');
  configCache = {};
  for (const row of r.getRowObjects()) configCache[row.key] = row.value;
}

// ---------- OAuth tokens (Google) ----------
export async function getTokens(provider = 'google') {
  await ensureStore();
  if (mode === 'remote') {
    // Served by the server process from its local store.
    const res = await remoteGet('/api/google-tokens');
    return res && !res.error ? res : null;
  }
  if (mode !== 'local') return null;
  try {
    const r = await conn.runAndReadAll('SELECT tokens FROM oauth_tokens WHERE provider = ?', [provider]);
    const rows = r.getRowObjects();
    return rows.length ? JSON.parse(rows[0].tokens) : null;
  } catch {
    return null;
  }
}

export async function saveTokens(tokens, provider = 'google') {
  await ensureStore();
  if (mode !== 'local') return; // tokens are minted in the server process
  await conn.run(
    'INSERT INTO oauth_tokens(provider, tokens, updated_at) VALUES (?, ?, now()) ON CONFLICT(provider) DO UPDATE SET tokens = excluded.tokens, updated_at = now()',
    [provider, JSON.stringify(tokens)]
  );
}

// ---------- voice sessions ----------
export async function loadSession(id = 'default') {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet('/api/store/session');
      return res?.session || null;
    } catch {
      return null;
    }
  }
  if (mode !== 'local') return null;
  try {
    const r = await conn.runAndReadAll('SELECT data FROM sessions WHERE id = ?', [id]);
    const rows = r.getRowObjects();
    return rows.length ? JSON.parse(rows[0].data) : null;
  } catch {
    return null;
  }
}

export async function saveSession(obj, id = 'default') {
  await ensureStore();
  if (mode === 'remote') {
    try {
      await remotePost('/api/store/session', { session: obj });
    } catch {
      /* best-effort */
    }
    return;
  }
  if (mode !== 'local') return;
  try {
    await conn.run(
      'INSERT INTO sessions(id, data, updated_at) VALUES (?, ?, now()) ON CONFLICT(id) DO UPDATE SET data = excluded.data, updated_at = now()',
      [id, JSON.stringify(obj ?? {})]
    );
  } catch {
    /* best-effort */
  }
}

// ---------- memory: semantic facts (preferences, locations, projects) ----------
// Categories are free-form; tools use preference|location|project|workflow|fact.
export const MEMORY_CATEGORIES = ['preference', 'location', 'project', 'workflow', 'fact'];

export async function memGet(key) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet(`/api/store/memory?key=${encodeURIComponent(key)}`);
      return res?.value ?? null;
    } catch {
      return null;
    }
  }
  if (mode !== 'local') return null;
  try {
    const r = await conn.runAndReadAll('SELECT value FROM memories WHERE key = ?', [key]);
    const rows = r.getRowObjects();
    return rows.length ? rows[0].value : null;
  } catch {
    return null;
  }
}

export async function memSet(key, value, category = 'fact') {
  await ensureStore();
  const cat = MEMORY_CATEGORIES.includes(category) ? category : 'fact';
  if (mode === 'remote') {
    try {
      await remotePost('/api/store/memory', { op: 'set', key, value, category: cat });
    } catch {
      /* best-effort */
    }
    return;
  }
  if (mode !== 'local') return;
  try {
    await conn.run(
      'INSERT INTO memories(key, value, category, updated_at) VALUES (?, ?, ?, now()) ON CONFLICT(key) DO UPDATE SET value = excluded.value, category = excluded.category, updated_at = now()',
      [key, String(value ?? ''), cat]
    );
  } catch {
    /* best-effort */
  }
}

export async function memDelete(key) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      await remotePost('/api/store/memory', { op: 'delete', key });
    } catch {
      /* best-effort */
    }
    return false;
  }
  if (mode !== 'local') return false;
  try {
    const r = await conn.runAndReadAll('DELETE FROM memories WHERE key = ? RETURNING key', [key]);
    return r.getRowObjects().length > 0;
  } catch {
    return false;
  }
}

// Substring search over keys + values (case-insensitive), newest first.
export async function memSearch(query = '', { category = null, limit = 20 } = {}) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const q = new URLSearchParams({ q: query, ...(category ? { category } : {}) });
      const res = await remoteGet(`/api/store/memory?${q}`);
      return res?.memories || [];
    } catch {
      return [];
    }
  }
  if (mode !== 'local') return [];
  try {
    const like = `%${query}%`;
    const r = category
      ? await conn.runAndReadAll(
          'SELECT key, value, category FROM memories WHERE category = ? AND (key ILIKE ? OR value ILIKE ?) ORDER BY updated_at DESC LIMIT ?',
          [category, like, like, Math.min(Math.max(Number(limit) || 20, 1), 100)]
        )
      : await conn.runAndReadAll(
          'SELECT key, value, category FROM memories WHERE key ILIKE ? OR value ILIKE ? ORDER BY updated_at DESC LIMIT ?',
          [like, like, Math.min(Math.max(Number(limit) || 20, 1), 100)]
        );
    return r.getRowObjects().map(jsonSafeRow);
  } catch {
    return [];
  }
}

// Resolve a location/project alias ("tafiti" matches key "project:tafiti").
export async function resolveLocation(name) {
  const q = String(name || '').trim().toLowerCase();
  if (!q) return null;
  const hits = await memSearch(q, { limit: 10 });
  const exact =
    hits.find((h) => h.key.toLowerCase() === q || h.key.toLowerCase() === `location:${q}` || h.key.toLowerCase() === `project:${q}`) ||
    hits.find((h) => h.category === 'location' || h.category === 'project') ||
    hits[0];
  return exact ? { key: exact.key, value: exact.value, category: exact.category } : null;
}

// ---------- memory: procedural workflows (named tool sequences) ----------
export async function wfSave(name, steps, description = '') {
  await ensureStore();
  const payload = JSON.stringify(steps);
  if (mode === 'remote') {
    try {
      await remotePost('/api/store/workflows', { op: 'save', name, steps: payload, description });
    } catch {
      /* best-effort */
    }
    return;
  }
  if (mode !== 'local') return;
  try {
    await conn.run(
      'INSERT INTO workflows(name, steps, description, updated_at) VALUES (?, ?, ?, now()) ON CONFLICT(name) DO UPDATE SET steps = excluded.steps, description = excluded.description, updated_at = now()',
      [name, payload, String(description || '')]
    );
  } catch {
    /* best-effort */
  }
}

export async function wfGet(name) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet(`/api/store/workflows?name=${encodeURIComponent(name)}`);
      return res?.workflow || null;
    } catch {
      return null;
    }
  }
  if (mode !== 'local') return null;
  try {
    const r = await conn.runAndReadAll('SELECT name, steps, description, use_count, success_count FROM workflows WHERE name = ?', [name]);
    const rows = r.getRowObjects();
    if (!rows.length) return null;
    const wf = jsonSafeRow(rows[0]);
    return { ...wf, steps: JSON.parse(wf.steps) };
  } catch {
    return null;
  }
}

export async function wfList() {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet('/api/store/workflows');
      return res?.workflows || [];
    } catch {
      return [];
    }
  }
  if (mode !== 'local') return [];
  try {
    const r = await conn.runAndReadAll(
      'SELECT name, description, use_count, success_count, updated_at FROM workflows ORDER BY updated_at DESC'
    );
    return r.getRowObjects().map((w) => {
      const safe = jsonSafeRow(w);
      return {
        ...safe,
        use_count: Number(safe.use_count),
        success_count: Number(safe.success_count),
      };
    });
  } catch {
    return [];
  }
}

export async function wfDelete(name) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      await remotePost('/api/store/workflows', { op: 'delete', name });
    } catch {
      /* best-effort */
    }
    return false;
  }
  if (mode !== 'local') return false;
  try {
    const r = await conn.runAndReadAll('DELETE FROM workflows WHERE name = ? RETURNING name', [name]);
    return r.getRowObjects().length > 0;
  } catch {
    return false;
  }
}

export async function wfRecordUse(name, success) {
  await ensureStore();
  if (mode !== 'local') return; // server-owned stats; remote runs report via audit log
  try {
    await conn.run(
      'UPDATE workflows SET use_count = use_count + 1, success_count = success_count + ?, updated_at = now() WHERE name = ?',
      [success ? 1 : 0, name]
    );
  } catch {
    /* best-effort */
  }
}

// ---------- planner: task plans with checkpoints ----------
export function newPlanId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return `plan-${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}`;
  }
  return `plan-${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}`;
}

function planRow(row) {
  const safe = jsonSafeRow(row);
  return {
    ...safe,
    steps: JSON.parse(safe.steps || '[]'),
    results: JSON.parse(safe.results || '[]'),
    current_step: Number(safe.current_step || 0),
  };
}

export async function planSave(plan) {
  await ensureStore();
  const payload = {
    id: plan.id,
    goal: plan.goal,
    steps: JSON.stringify(plan.steps || []),
    status: plan.status || 'planned',
    current_step: plan.current_step || 0,
    results: JSON.stringify(plan.results || []),
    error: plan.error ?? null,
  };
  if (mode === 'remote') {
    try {
      await remotePost('/api/store/plans', { op: 'save', plan: payload });
    } catch {
      /* best-effort */
    }
    return payload.id;
  }
  if (mode !== 'local') return payload.id;
  try {
    await conn.run(
      `INSERT INTO plans(id, goal, steps, status, current_step, results, error, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, now())
       ON CONFLICT(id) DO UPDATE SET goal = excluded.goal, steps = excluded.steps,
         status = excluded.status, current_step = excluded.current_step,
         results = excluded.results, error = excluded.error, updated_at = now()`,
      [payload.id, payload.goal, payload.steps, payload.status, payload.current_step, payload.results, payload.error]
    );
  } catch {
    /* best-effort */
  }
  return payload.id;
}

export async function planGet(id) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet(`/api/store/plans?id=${encodeURIComponent(id)}`);
      return res?.plan || null;
    } catch {
      return null;
    }
  }
  if (mode !== 'local') return null;
  try {
    const r = await conn.runAndReadAll('SELECT * FROM plans WHERE id = ?', [id]);
    const rows = r.getRowObjects();
    return rows.length ? planRow(rows[0]) : null;
  } catch {
    return null;
  }
}

export async function planList(limit = 20) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet('/api/store/plans');
      return res?.plans || [];
    } catch {
      return [];
    }
  }
  if (mode !== 'local') return [];
  try {
    const r = await conn.runAndReadAll(
      'SELECT id, goal, status, current_step, json_array_length(steps) AS total_steps, error, updated_at FROM plans ORDER BY updated_at DESC LIMIT ?',
      [Math.min(Math.max(Number(limit) || 20, 1), 100)]
    );
    return r.getRowObjects().map((p) => {
      const safe = jsonSafeRow(p);
      return { ...safe, current_step: Number(safe.current_step || 0), total_steps: Number(safe.total_steps || 0) };
    });
  } catch {
    return [];
  }
}

export async function planUpdate(id, patch) {
  const current = await planGet(id);
  if (!current) return null;
  const next = {
    ...current,
    ...patch,
    id: current.id, // id immutable
  };
  await planSave(next);
  return next;
}

// ---------- sub-agents (Phase 4) ----------
export const AGENT_STATUSES = ['spawned', 'running', 'waiting', 'completed', 'failed', 'cancelled', 'timed_out'];

export function newAgentId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return `agent-${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`;
  }
  return `agent-${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}`;
}

function agentRow(row) {
  const safe = jsonSafeRow(row);
  let allowed = [];
  let budget = {};
  let messages = [];
  try {
    allowed = JSON.parse(safe.allowed_tools || '[]');
  } catch {
    allowed = [];
  }
  try {
    budget = JSON.parse(safe.budget || '{}');
  } catch {
    budget = {};
  }
  try {
    messages = JSON.parse(safe.messages || '[]');
  } catch {
    messages = [];
  }
  return {
    ...safe,
    allowed_tools: Array.isArray(allowed) ? allowed : [],
    budget: budget && typeof budget === 'object' ? budget : {},
    messages: Array.isArray(messages) ? messages : [],
    depth: Number(safe.depth || 0),
    result: safe.result ? JSON.parse(safe.result) : null,
  };
}

export async function agentSpawn(record) {
  await ensureStore();
  // Idempotent: accepts parsed values or already-stringified payloads
  // (remote delegation posts the stringified form back through here).
  const str = (v, fallback) => (typeof v === 'string' ? v : JSON.stringify(v ?? fallback));
  const payload = {
    id: record.id,
    parent_id: record.parent_id || null,
    role: record.role,
    instructions: record.instructions || '',
    allowed_tools: str(record.allowed_tools, []),
    status: record.status || 'spawned',
    budget: str(record.budget, {}),
    depth: record.depth || 0,
    result: record.result === undefined || record.result === null ? null : str(record.result, null),
    error: record.error ?? null,
    messages: str(record.messages, []),
  };
  if (mode === 'remote') {
    try {
      await remotePost('/api/store/agents', { op: 'save', agent: payload });
    } catch {
      /* best-effort */
    }
    return payload.id;
  }
  if (mode !== 'local') return payload.id;
  try {
    await conn.run(
      `INSERT INTO agents(id, parent_id, role, instructions, allowed_tools, status, budget, depth, result, error, messages, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, now())
       ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, role = excluded.role,
         instructions = excluded.instructions, allowed_tools = excluded.allowed_tools,
         status = excluded.status, budget = excluded.budget, depth = excluded.depth,
         result = excluded.result, error = excluded.error, messages = excluded.messages,
         updated_at = now()`,
      [payload.id, payload.parent_id, payload.role, payload.instructions, payload.allowed_tools,
        payload.status, payload.budget, payload.depth, payload.result, payload.error, payload.messages]
    );
  } catch {
    /* best-effort */
  }
  return payload.id;
}

export async function agentGet(id) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet(`/api/store/agents?id=${encodeURIComponent(id)}`);
      return res?.agent || null;
    } catch {
      return null;
    }
  }
  if (mode !== 'local') return null;
  try {
    const r = await conn.runAndReadAll('SELECT * FROM agents WHERE id = ?', [id]);
    const rows = r.getRowObjects();
    return rows.length ? agentRow(rows[0]) : null;
  } catch {
    return null;
  }
}

export async function agentList(limit = 20, onlyActive = false) {
  await ensureStore();
  if (mode === 'remote') {
    try {
      const res = await remoteGet(`/api/store/agents?limit=${Math.min(Math.max(Number(limit) || 20, 1), 100)}${onlyActive ? '&active=1' : ''}`);
      return res?.agents || [];
    } catch {
      return [];
    }
  }
  if (mode !== 'local') return [];
  try {
    const where = onlyActive ? "WHERE status IN ('spawned','running','waiting')" : '';
    const r = await conn.runAndReadAll(
      `SELECT id, parent_id, role, status, depth, error, updated_at FROM agents ${where} ORDER BY updated_at DESC LIMIT ?`,
      [Math.min(Math.max(Number(limit) || 20, 1), 100)]
    );
    return r.getRowObjects().map((a) => {
      const safe = jsonSafeRow(a);
      return { ...safe, depth: Number(safe.depth || 0) };
    });
  } catch {
    return [];
  }
}

export async function agentUpdate(id, patch) {
  const current = await agentGet(id);
  if (!current) return null;
  const next = { ...current, ...patch, id: current.id };
  await agentSpawn(next);
  return next;
}

// ---------- audit logs (never throw) ----------
export async function appendToolAudit(entry) {
  try {
    await ensureStore();
    const { approval, screenVerification, screenshot } = entry || {};
    const extra = { approval, screenVerification, screenshot };
    if (mode === 'remote') {
      await remotePost('/api/store/audit', { kind: 'tool', entry });
      return;
    }
    if (mode !== 'local') return;
    await conn.run('INSERT INTO tool_audit(ts, tool, args, result, error, extra) VALUES (?, ?, ?, ?, ?, ?)', [
      entry?.timestamp || new Date().toISOString(),
      entry?.tool || 'unknown',
      JSON.stringify(entry?.arguments ?? null),
      entry?.result !== undefined ? JSON.stringify(entry.result) : null,
      entry?.error ?? null,
      JSON.stringify(extra),
    ]);
  } catch {
    /* logging must never break tool execution */
  }
}

export async function appendSecurityAudit(entry) {
  try {
    await ensureStore();
    if (mode === 'remote') {
      await remotePost('/api/store/audit', { kind: 'security', entry });
      return;
    }
    if (mode !== 'local') return;
    await conn.run('INSERT INTO security_audit(ts, event, details, severity) VALUES (?, ?, ?, ?)', [
      entry?.timestamp || new Date().toISOString(),
      entry?.event || 'UNKNOWN',
      JSON.stringify(entry?.details ?? null),
      entry?.severity || 'LOW',
    ]);
  } catch {
    /* logging must never break tool execution */
  }
}

export async function recentToolAudits(limit = 100) {
  await ensureStore();
  if (mode !== 'local') return [];
  const r = await conn.runAndReadAll('SELECT ts, tool, args, result, error FROM tool_audit ORDER BY id DESC LIMIT ?', [
    Math.min(Math.max(Number(limit) || 100, 1), 1000),
  ]);
  return r.getRowObjects().map(jsonSafeRow);
}

export async function recentSecurityAudits(limit = 100) {
  await ensureStore();
  if (mode !== 'local') return [];
  const r = await conn.runAndReadAll('SELECT ts, event, details, severity FROM security_audit ORDER BY id DESC LIMIT ?', [
    Math.min(Math.max(Number(limit) || 100, 1), 1000),
  ]);
  return r.getRowObjects().map(jsonSafeRow);
}

// ---------- remote helpers ----------
async function remoteGet(p) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), REMOTE_TIMEOUT_MS);
  try {
    const res = await fetch(`${remoteBase}${p}`, {
      headers: { 'X-Requested-With': REMOTE_HEADER },
      signal: c.signal,
    });
    if (!res.ok) throw new Error(`store endpoint ${p} returned ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

async function remotePost(p, body) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), REMOTE_TIMEOUT_MS);
  try {
    const res = await fetch(`${remoteBase}${p}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': REMOTE_HEADER },
      signal: c.signal,
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`store endpoint ${p} returned ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

// ---------- one-time migration from legacy files ----------
// Seeds only MISSING keys/rows; records file fingerprints in meta so log
// files are never imported twice.
export async function migrateFromFiles(opts = {}) {
  const root = opts.root || process.cwd();
  const migrated = [];
  try {
    // 1) .env -> config (missing keys only)
    const envPath = process.env.DOTENV_PATH || path.join(root, '.env');
    try {
      const text = await fs.readFile(envPath, 'utf8');
      let count = 0;
      for (const line of text.split(/\r?\n/)) {
        const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
        if (!m) continue;
        let v = m[2].trim();
        if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
          v = v.slice(1, -1);
        }
        if (!v) continue;
        await conn.run(
          'INSERT INTO config(key, value) VALUES (?, ?) ON CONFLICT(key) DO NOTHING', [m[1], v]);
        count++;
      }
      if (count) migrated.push(`.env (${count} entries)`);
    } catch {
      /* no .env — fresh start */
    }

    // 2) tokens.json -> oauth_tokens
    try {
      const raw = await fs.readFile(path.join(root, 'tokens.json'), 'utf8');
      JSON.parse(raw); // validate
      await conn.run('INSERT INTO oauth_tokens(provider, tokens) VALUES (?, ?) ON CONFLICT(provider) DO NOTHING', [
        'google',
        raw,
      ]);
      migrated.push('tokens.json');
    } catch {
      /* none stored yet */
    }

    // 3) .session-state.json -> sessions
    try {
      const raw = await fs.readFile(path.join(root, '.session-state.json'), 'utf8');
      JSON.parse(raw);
      await conn.run('INSERT INTO sessions(id, data) VALUES (?, ?) ON CONFLICT(id) DO NOTHING', ['default', raw]);
      migrated.push('.session-state.json');
    } catch {
      /* none yet */
    }

    // 4) JSONL audit logs (fingerprint-guarded against double import)
    for (const [file, table] of [
      ['tool-audit.log', 'tool_audit'],
      ['security-audit.log', 'security_audit'],
    ]) {
      const fp = path.join(root, file);
      try {
        const st = await fs.stat(fp);
        const fingerprint = `${st.size}:${st.mtimeMs}`;
        if ((await metaGet(`migrated:${file}`)) === fingerprint) continue;
        const text = await fs.readFile(fp, 'utf8');
        let n = 0;
        for (const line of text.split('\n')) {
          const t = line.trim();
          if (!t.startsWith('{')) continue;
          try {
            const e = JSON.parse(t);
            if (table === 'tool_audit') {
              await conn.run('INSERT INTO tool_audit(ts, tool, args, result, error, extra) VALUES (?, ?, ?, ?, ?, ?)', [
                e.timestamp || new Date().toISOString(),
                e.tool || 'unknown',
                JSON.stringify(e.arguments ?? null),
                e.result !== undefined ? JSON.stringify(e.result) : null,
                e.error ?? null,
                JSON.stringify({ approval: e.approval, screenVerification: e.screenVerification, screenshot: e.screenshot }),
              ]);
            } else {
              await conn.run('INSERT INTO security_audit(ts, event, details, severity) VALUES (?, ?, ?, ?)', [
                e.timestamp || new Date().toISOString(),
                e.event || 'UNKNOWN',
                JSON.stringify(e.details ?? null),
                e.severity || 'LOW',
              ]);
            }
            n++;
          } catch {
            /* skip malformed lines */
          }
        }
        await metaSet(`migrated:${file}`, fingerprint);
        if (n) migrated.push(`${file} (${n} rows)`);
      } catch {
        /* no such log */
      }
    }
  } catch (err) {
    console.warn(`Store migration warning: ${err.message}`);
  }
  return migrated;
}
