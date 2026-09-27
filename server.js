import express from 'express';
import dotenv from 'dotenv';
import crypto from 'crypto';
import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';
import { listPendingApprovals, resolveApproval } from './lib/security-extras.js';
import * as _securityExtras from './lib/security-extras.js';
import {
  initStore,
  cfg,
  allConfig,
  setConfig,
  loadSession as storeLoadSession,
  saveSession as storeSaveSession,
  appendToolAudit,
  appendSecurityAudit,
} from './lib/store.js';
import { getHealthChecker, getMonitoringMetrics, createLogger } from './lib/monitor.js';

const logger = createLogger('server');
const healthChecker = getHealthChecker();

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
// PORT is resolved after the store boots (DB value, env override); the
// listener in the main block below uses it. Default 3000 until then.

// Middleware
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Routes

// Mint AssemblyAI temporary token
app.get('/api/voice-token', async (req, res) => {
  try {
    const url = new URL('https://agents.assemblyai.com/v1/token');
    url.searchParams.set('expires_in_seconds', '300'); // 5 minutes
    
    const response = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${cfg('ASSEMBLYAI_API_KEY')}`
      }
    });

    if (!response.ok) {
      throw new Error(`AssemblyAI API error: ${response.status}`);
    }

    const data = await response.json();
    res.json({ token: data.token });
  } catch (error) {
    console.error('Error minting AssemblyAI token:', error);
    res.status(500).json({ error: 'Failed to mint voice token' });
  }
});

// Enhanced health check with monitoring
app.get('/health', async (req, res) => {
  try {
    const healthResult = await healthChecker.runChecks();
    const systemResources = healthChecker.getSystemResources();
    const monitoringMetrics = getMonitoringMetrics();
    
    res.json({
      status: healthResult.healthy ? 'ok' : 'degraded',
      timestamp: new Date().toISOString(),
      health: healthResult,
      system: systemResources,
      metrics: {
        toolExecutions: Object.keys(monitoringMetrics.performance).length,
        recentErrors: monitoringMetrics.errors.total,
        uptime: process.uptime()
      }
    });
  } catch (error) {
    logger.error('Health check failed', { error: error.message });
    res.status(500).json({ 
      status: 'error', 
      timestamp: new Date().toISOString(),
      error: error.message 
    });
  }
});

// Detailed monitoring metrics endpoint
app.get('/api/metrics', (req, res) => {
  try {
    const metrics = getMonitoringMetrics();
    res.json(metrics);
  } catch (error) {
    logger.error('Metrics collection failed', { error: error.message });
    res.status(500).json({ error: 'Failed to collect metrics' });
  }
});

// Human-in-the-loop confirmation UI for dangerous tools.
// GET /api/confirm -> HTML page listing pending approvals with Approve/Deny buttons.
// GET /api/approvals -> JSON list (for tray icon / polling).
// POST /api/approvals/:id -> { approved: true|false } resolves the pending tool call.
app.get('/api/approvals', (req, res) => {
  res.json({ pending: listPendingApprovals() });
});

app.get('/api/confirm', (req, res) => {
  const pending = listPendingApprovals();
  const rows = pending.map((p) => `
    <tr>
      <td><code>${p.id}</code></td>
      <td><b>${p.tool}</b></td>
      <td><pre>${escapeHtml(JSON.stringify(p.args, null, 2))}</pre></td>
      <td>${new Date(p.createdAt).toLocaleTimeString()}</td>
      <td>
        <form method="POST" action="/api/approvals/${p.id}" style="display:inline">
          <input type="hidden" name="approved" value="true" />
          <button type="submit">Approve</button>
        </form>
        <form method="POST" action="/api/approvals/${p.id}" style="display:inline">
          <input type="hidden" name="approved" value="false" />
          <button type="submit">Deny</button>
        </form>
      </td>
    </tr>`).join('') || '<tr><td colspan="5">No pending approvals 🎉</td></tr>';
  res.send(`<html><head><meta http-equiv="refresh" content="5"><title>Tool approvals</title></head>
    <body><h1>Pending tool approvals</h1>
    <p>Auto-refreshes every 5s. Approve dangerous tool calls from the voice agent here.</p>
    <table border="1" cellpadding="8"><tr><th>ID</th><th>Tool</th><th>Args</th><th>Requested</th><th>Action</th></tr>${rows}</table>
    </body></html>`);
});

// CSRF guard: the approval UI is a same-origin HTML form, so browsers never attach
// this header cross-site (form posts cannot set custom headers). Anything without it
// that looks like a browser navigation/form post is rejected.
function isSameOriginRequest(req) {
  const origin = req.headers.origin;
  if (!origin) return true; // curl / server-to-server / tests
  try {
    return new URL(origin).host === req.headers.host;
  } catch {
    return false;
  }
}

// ---- Remote approval flow (agent/other-process clients) ----
// NOTE: security-extras must already be imported above; the namespace import
// (_securityExtras) reuses that same module instance (ESM cache).

// A client (e.g. the voice-agent process) POSTs here to enqueue a dangerous-tool
// approval; the decision is long-polled so the /api/confirm UI stays the single
// source of truth. Requests without a browser Origin skip the CSRF form guard,
// but must carry X-Requested-With (matches the delegation client below).
import { __addRemoteWaiter, __resolveRemoteDecision } from './lib/security-extras.js';

function validRemoteClient(req) {
  return req.headers['x-requested-with'] === 'pc-assistant-agent';
}

app.post('/api/approvals/request', (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { tool, args, ttlMs } = req.body || {};
  if (!tool || typeof tool !== 'string') {
    return res.status(400).json({ error: 'Missing "tool" in body' });
  }
  const ttl = Math.min(Math.max(Number(ttlMs) || 120_000, 1_000), 600_000);
  const { requestApproval } = _securityExtras;
  const id = `appr-${crypto.randomBytes(16).toString('hex')}`;
  const decisionPromise = new Promise((resolve) => {
    __addRemoteWaiter(id, resolve, ttl);
  });
  // Create the queue entry in this process so the /api/confirm UI lists it.
  _securityExtras.__createQueuedApproval(id, tool, args || {}, ttl);
  decisionPromise
    .then((decision) => res.json(decision))
    .catch(() => res.status(500).json({ approved: false, reason: 'internal error' }));
});

app.post('/api/approvals/:id/decision', (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const raw = req.body?.approved;
  const approved = raw === true || raw === 'true';
  const note = typeof req.body?.note === 'string' ? req.body.note : 'via delegation API';
  __resolveRemoteDecision(req.params.id, { approved, note });
  res.json({ ok: true });
});

app.post('/api/approvals/:id', (req, res) => {
  if (!isSameOriginRequest(req)) {
    return res.status(403).json({ error: 'Cross-origin approval requests are not allowed' });
  }
  const raw = req.body?.approved;
  const approved = raw === true || raw === 'true';
  const ok = resolveApproval(req.params.id, approved, 'via /api/confirm');
  if (!ok) return res.status(404).json({ error: 'Approval not found or expired' });
  // Support both HTML form posts and JSON fetch
  if ((req.headers['content-type'] || '').includes('application/json')) {
    return res.json({ ok: true, approved });
  }
  res.redirect('/api/confirm');
});

function escapeHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Tool-manifest integrity check: warn if tool definitions changed since signing
// (re-sign with `npm run sign-manifest` after intentional tool changes).
async function verifyManifestAtStartup() {
  try {
    const { buildAllTools } = await import('./tools.js');
    const { verifyToolManifest } = await import('./lib/security-extras.js');
    const v = await verifyToolManifest(buildAllTools());
    if (!v.ok) {
      console.warn(`⚠️  Tool manifest verification failed: ${v.reason}`);
      console.warn('   If tool changes were intentional, re-sign: npm run sign-manifest');
    } else {
      console.log('✅ Tool manifest verified');
    }
  } catch (err) {
    console.warn(`⚠️  Could not verify tool manifest: ${err.message}`);
  }
}

// Safe test-tool endpoint (AGENTS.md verification): POST { tool, args }.
// Dangerous tools still go through the approval queue.
app.post('/test-tool', async (req, res) => {
  try {
    const { dispatchTool } = await import('./tools.js');
    const { tool, args } = req.body || {};
    if (!tool) return res.status(400).json({ error: 'Missing "tool" in body' });
    const result = await dispatchTool(tool, args || {});
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---- Browser setup UI: most configuration client-side ----
// GET /setup renders a form backed by the DuckDB config table so users don't
// hand-edit files. POST /setup validates + persists it. Secrets are
// write-only (never rendered back; blank keeps the stored value) and
// cross-origin POSTs are rejected. Bootstrap keys needed before the DB can
// be reached (PORT, AUDIO_*, WAKEWORD_*) are mirrored back to the .env file.

// Keys mirrored to the .env bootstrap file (the file is otherwise legacy seed only).
const BOOTSTRAP_KEYS = new Set(['PORT', 'AUDIO_DEVICE', 'WAKEWORD_ENGINE', 'WAKEWORD', 'WAKEWORD_THRESHOLD']);

function bootstrapEnvPath() {
  return process.env.DOTENV_PATH || path.join(__dirname, '.env');
}

async function mirrorBootstrapToFile(map) {
  try {
    let text = '';
    try {
      text = await fs.readFile(bootstrapEnvPath(), 'utf8');
    } catch {
      text = '';
    }
    for (const k of BOOTSTRAP_KEYS) {
      if (!(k in map)) continue;
      const line = `${k}=${map[k]}`;
      const re = new RegExp(`^${k}=.*$`, 'm');
      text = re.test(text) ? text.replace(re, line) : `${text.replace(/\s+$/, '')}\n${line}\n`;
    }
    await fs.writeFile(bootstrapEnvPath(), text, { mode: 0o600 });
  } catch {
    /* best-effort mirror */
  }
}

const SETUP_FIELDS = [
  { key: 'ASSEMBLYAI_API_KEY', label: 'AssemblyAI API key', kind: 'password', secret: true, section: 'Voice', required: true, placeholder: 'aai-...' },
  { key: 'AGENT_ID', label: 'Stored agent ID', section: 'Voice', hint: 'Filled automatically by `npm run up` / `npm run publish`.' },
  { key: 'LLM_API_KEY', label: 'OpenRouter API key', kind: 'password', secret: true, section: 'Voice LLM (free model by default)', required: true, hint: 'The only LLM key you need. Defaults to OpenRouter + the free openrouter/free model.' },
  { key: 'GEMINI_API_KEY', label: 'Gemini API key (Google AI Studio)', kind: 'password', secret: true, section: 'Computer Use (on by default)', hint: 'Powers the computer_use vision loop and search grounding.' },
  { key: 'COMPUTER_USE_ENABLED', label: 'Enable computer_use tool', kind: 'checkbox', section: 'Computer Use (on by default)', def: 'true', hint: 'Every consequential UI action still needs approval in /api/confirm.' },
  { key: 'PORT', label: 'Server port', kind: 'number', section: 'Server', placeholder: '3000' },
];
// Display map: DB config overlaid with real process env (env wins, like cfg()).
async function setupDisplayMap() {
  const map = await allConfig();
  for (const f of SETUP_FIELDS) {
    if (process.env[f.key] !== undefined) map[f.key] = process.env[f.key];
  }
  return map;
}

function setupStatus(map) {
  const missing = [];
  if (!map.ASSEMBLYAI_API_KEY) missing.push('ASSEMBLYAI_API_KEY');
  if (!map.LLM_API_KEY && !/localhost|127\.0\.0\.1|0\.0\.0\.0/i.test(map.LLM_BASE_URL || map.OPENAI_BASE_URL || '')) {
    missing.push('LLM_API_KEY (OpenRouter)');
  }
  const warnings = [];
  return { missing, warnings };
}

function renderSetupPage(map, { error = null, saved = false } = {}) {
  const { missing, warnings } = setupStatus(map);
  let sections = '';
  let lastSection = null;
  for (const f of SETUP_FIELDS) {
    if (f.section !== lastSection) {
      if (lastSection) sections += '</fieldset>';
      sections += `<fieldset><legend>${escapeHtml(f.section)}</legend>`;
      lastSection = f.section;
    }
    const val = map[f.key] ?? '';
    const req = f.required ? ' *' : '';
    const hint = f.hint ? `<span class="hint">${escapeHtml(f.hint)}</span>` : '';
    if (f.kind === 'checkbox') {
      const checked = (val || f.def || 'false') === 'true' ? ' checked' : '';
      sections += `<input type="hidden" name="${f.key}" value="false">` +
        `<label><input type="checkbox" name="${f.key}" value="true"${checked}> ${escapeHtml(f.label)}${req}</label>${hint}<br>`;
    } else if (f.kind === 'select') {
      const opts = f.options.map((o) => `<option${(val || f.options[0]) === o ? ' selected' : ''}>${o}</option>`).join('');
      sections += `<label>${escapeHtml(f.label)}${req} <select name="${f.key}">${opts}</select></label>${hint}<br>`;
    } else if (f.kind === 'password') {
      const ph = val ? '•••••••• (set — blank keeps it)' : '(not set)';
      sections += `<label>${escapeHtml(f.label)}${req} <input type="password" name="${f.key}" value="" placeholder="${ph}" autocomplete="off"></label>${hint}<br>`;
    } else {
      const attrs = [`type="${f.kind === 'number' ? 'number' : 'text'}"`, `name="${f.key}"`, `value="${escapeHtml(val)}"`];
      if (f.placeholder) attrs.push(`placeholder="${escapeHtml(f.placeholder)}"`);
      sections += `<label>${escapeHtml(f.label)}${req} <input ${attrs.join(' ')}></label>${hint}<br>`;
    }
  }
  sections += '</fieldset>';
  const status = missing.length
    ? `<p class="err">Missing required: ${missing.map(escapeHtml).join(', ')}</p>`
    : `<p class="ok">Required keys present 🎉</p>`;
  const warns = warnings.map((w) => `<p class="warn">⚠️ ${escapeHtml(w)}</p>`).join('');
  return `<html><head><title>PC Assistant setup</title>
    <style>body{font-family:sans-serif;max-width:720px;margin:2em auto;padding:0 1em}fieldset{margin-bottom:1em}input[type=text],input[type=password],input[type=number]{width:320px;max-width:100%}.hint{color:#666;font-size:.85em;margin-left:.5em}.err{color:#a00}.warn{color:#a60}.ok{color:#0a0}button{font-size:1.1em;padding:.4em 1.2em}</style></head>
    <body><h1>PC Assistant setup</h1>
    <p>Saved to the DuckDB store${process.env.STORE_PATH ? ` (<code>${escapeHtml(process.env.STORE_PATH)}</code>)` : ''} (bootstrap keys mirrored to <code>.env</code>). Secrets are write-only here.
    <a href="/health">health</a> · <a href="/api/confirm">approvals</a></p>
    ${saved ? '<p class="ok">Saved ✅ — restart the server/agent to pick up PORT and audio changes.</p>' : ''}
    ${error ? `<p class="err">${escapeHtml(error)}</p>` : ''}
    ${status}${warns}
    <form method="POST" action="/setup">${sections}<button type="submit">Save configuration</button></form>
    </body></html>`;
}

app.get('/setup', async (req, res) => {
  const map = await setupDisplayMap();
  res.send(renderSetupPage(map, {
    saved: req.query.saved === '1',
  }));
});

app.post('/setup', async (req, res) => {
  if (!isSameOriginRequest(req)) {
    return res.status(403).json({ error: 'Cross-origin setup requests are not allowed' });
  }
  const body = req.body || {};
  const isJson = (req.headers['content-type'] || '').includes('application/json');
  const current = await setupDisplayMap();
  const next = { ...current };
  for (const f of SETUP_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(body, f.key)) continue; // absent = keep
    const raw = Array.isArray(body[f.key]) ? body[f.key][body[f.key].length - 1] : body[f.key];
    if (f.kind === 'checkbox') {
      next[f.key] = (raw === true || raw === 'true' || raw === 'on' || raw === '1') ? 'true' : 'false';
      continue;
    }
    const v = String(raw ?? '').trim();
    if (f.secret && v === '') continue; // blank secret = keep stored value
    next[f.key] = v;
  }

  const errors = [];
  const port = Number(next.PORT || '3000');
  if (!Number.isInteger(port) || port < 1 || port > 65535) errors.push('PORT must be an integer 1-65535.');

  if (errors.length) {
    if (isJson) return res.status(400).json({ errors });
    return res.status(400).send(renderSetupPage(next, { error: errors.join(' ') }));
  }
  for (const f of SETUP_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(body, f.key)) {
      await setConfig(f.key, next[f.key] ?? '');
    }
  }
  await mirrorBootstrapToFile(next);
  if (isJson) {
    const updated = SETUP_FIELDS.map((f) => f.key).filter((k) => Object.prototype.hasOwnProperty.call(body, k) && !SETUP_FIELDS.find((f) => f.key === k)?.secret);
    return res.json({ ok: true, updated });
  }
  res.redirect('/setup?saved=1');
});

// ---- Store delegation endpoints (voice-agent process -> this server) ----
// The agent never opens the DuckDB file (single-writer rule); it forwards
// config/session/audit operations here, header-gated like approval requests.
app.get('/api/store/config', (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  allConfig().then((config) => res.json({ config })).catch((err) => res.status(500).json({ error: err.message }));
});

app.post('/api/store/config', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { key, value } = req.body || {};
  if (!key || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
    return res.status(400).json({ error: 'Invalid "key"' });
  }
  await setConfig(key, String(value ?? ''));
  res.json({ ok: true });
});

app.get('/api/store/session', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  res.json({ session: await storeLoadSession() });
});

app.post('/api/store/session', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  await storeSaveSession(req.body?.session || {});
  res.json({ ok: true });
});

app.post('/api/store/audit', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { kind, entry } = req.body || {};
  if (kind === 'tool') await appendToolAudit(entry || {});
  else if (kind === 'security') await appendSecurityAudit(entry || {});
  else return res.status(400).json({ error: 'kind must be "tool" or "security"' });
  res.json({ ok: true });
});

app.get('/api/store/memory', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { key, q, category } = req.query;
  const { memGet, memSearch } = await import('./lib/store.js');
  if (key) return res.json({ value: await memGet(String(key)) });
  res.json({ memories: await memSearch(String(q || ''), { category: category || null }) });
});

app.post('/api/store/memory', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { op, key, value, category } = req.body || {};
  const { memSet, memDelete } = await import('./lib/store.js');
  if (op === 'set' && key) {
    await memSet(String(key), value ?? '', category || 'fact');
    return res.json({ ok: true });
  }
  if (op === 'delete' && key) {
    return res.json({ ok: true, deleted: await memDelete(String(key)) });
  }
  return res.status(400).json({ error: 'op must be "set" or "delete" with a key' });
});

app.get('/api/store/workflows', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { wfGet, wfList } = await import('./lib/store.js');
  const { name } = req.query;
  if (name) return res.json({ workflow: await wfGet(String(name)) });
  res.json({ workflows: await wfList() });
});

app.post('/api/store/workflows', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { op, name, steps, description } = req.body || {};
  const { wfSave, wfDelete } = await import('./lib/store.js');
  if (op === 'save' && name && Array.isArray(steps)) {
    let parsed = steps;
    if (typeof steps === 'string') {
      try {
        parsed = JSON.parse(steps);
      } catch {
        return res.status(400).json({ error: 'steps must be valid JSON' });
      }
    }
    await wfSave(String(name), parsed, description || '');
    return res.json({ ok: true });
  }
  if (op === 'delete' && name) {
    return res.json({ ok: true, deleted: await wfDelete(String(name)) });
  }
  return res.status(400).json({ error: 'op must be "save" (name + steps) or "delete" (name)' });
});

app.get('/api/store/plans', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { planGet, planList } = await import('./lib/store.js');
  const { id } = req.query;
  if (id) return res.json({ plan: await planGet(String(id)) });
  res.json({ plans: await planList() });
});

app.post('/api/store/plans', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { op, plan } = req.body || {};
  const { planSave } = await import('./lib/store.js');
  if (op === 'save' && plan && plan.id && plan.goal && Array.isArray(plan.steps)) {
    await planSave(plan);
    return res.json({ ok: true, id: plan.id });
  }
  return res.status(400).json({ error: 'op must be "save" with { id, goal, steps }' });
});

app.get('/api/store/agents', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { agentGet, agentList } = await import('./lib/store.js');
  const { id, limit, active } = req.query;
  if (id) return res.json({ agent: await agentGet(String(id)) });
  res.json({ agents: await agentList(limit, active === '1') });
});

app.post('/api/store/agents', async (req, res) => {
  if (!validRemoteClient(req)) {
    return res.status(403).json({ error: 'Missing or invalid X-Requested-With header' });
  }
  const { op, agent } = req.body || {};
  const { agentSpawn } = await import('./lib/store.js');
  if (op === 'save' && agent && agent.id && agent.role) {
    await agentSpawn(agent);
    return res.json({ ok: true, id: agent.id });
  }
  return res.status(400).json({ error: 'op must be "save" with { id, role }' });
});

// ---- Agent timeline UI: task plans with checkpoints (vision §46) ----
// GET /tasks -> auto-refreshing HTML table of plans/steps/statuses.
// GET /api/tasks -> JSON list (for tray icon / polling).
app.get('/api/tasks', async (req, res) => {
  const { planList, agentList } = await import('./lib/store.js');
  res.json({ plans: await planList(50), agents: await agentList(50) });
});

app.get('/tasks', async (req, res) => {
  const { planList, planGet, agentList, agentGet } = await import('./lib/store.js');
  const selected = req.query.plan ? await planGet(String(req.query.plan)) : null;
  const selectedAgent = req.query.agent ? await agentGet(String(req.query.agent)) : null;
  const plans = await planList(50);
  const agents = await agentList(50);
  const statusIcon = (s) => ({ completed: '✅', failed: '❌', running: '🔄', cancelled: '⏹️', planned: '📝' }[s] || '❓');
  const rows = plans.map((p) => {
    const total = Number(p.total_steps || 0);
    const done = Number(p.current_step || 0);
    const pct = total ? Math.round((done / total) * 100) : 0;
    return `<tr><td>${statusIcon(p.status)} ${escapeHtml(p.status)}</td>
      <td><a href="/tasks?plan=${escapeHtml(p.id)}"><code>${escapeHtml(p.id)}</code></a></td>
      <td>${escapeHtml(String(p.goal).slice(0, 80))}</td>
      <td>${done}/${total} (${pct}%)</td>
      <td>${escapeHtml(String(p.error || '').slice(0, 80))}</td></tr>`;
  }).join('') || '<tr><td colspan="5">No task plans yet — ask the agent to plan something.</td></tr>';
  const detail = selected ? `<h2>Plan <code>${escapeHtml(selected.id)}</code></h2>
    <p><b>Goal:</b> ${escapeHtml(selected.goal)}</p>
    <p><b>Status:</b> ${statusIcon(selected.status)} ${escapeHtml(selected.status)} — step ${selected.current_step + 1}/${selected.steps.length}</p>
    <ol>${selected.steps.map((s, i) => {
      const r = (selected.results || [])[i];
      const mark = !r ? '⏳' : r.ok ? '✅' : '❌';
      return `<li>${mark} <code>${escapeHtml(s.tool)}</code> <small>${escapeHtml(JSON.stringify(s.args || {}).slice(0, 120))}</small>` +
        (r && !r.ok ? `<br><small style="color:#a00">${escapeHtml(String(r.error || '').slice(0, 200))}</small>` : '') + '</li>';
    }).join('')}</ol>` : '';
  const agentIcon = (s) => ({ completed: '✅', failed: '❌', running: '🔄', cancelled: '⏹️', spawned: '🐣', waiting: '⏳', timed_out: '⌛' }[s] || '❓');
  const agentRows = agents.map((a) => `<tr><td>${agentIcon(a.status)} ${escapeHtml(a.status)}</td>
      <td><a href="/tasks?agent=${escapeHtml(a.id)}"><code>${escapeHtml(a.id)}</code></a></td>
      <td>${escapeHtml(String(a.role || '').slice(0, 60))}</td>
      <td>${Number(a.depth || 0)}</td>
      <td>${a.parent_id ? `<code>${escapeHtml(String(a.parent_id).slice(0, 18))}</code>` : '—'}</td>
      <td>${escapeHtml(String(a.error || '').slice(0, 80))}</td></tr>`).join('')
    || '<tr><td colspan="6">No sub-agents yet — spawn one with spawn_agent.</td></tr>';
  const agentDetail = selectedAgent ? `<h2>Agent <code>${escapeHtml(selectedAgent.id)}</code></h2>
    <p><b>Role:</b> ${escapeHtml(selectedAgent.role)} · <b>Status:</b> ${agentIcon(selectedAgent.status)} ${escapeHtml(selectedAgent.status)} · <b>Depth:</b> ${Number(selectedAgent.depth || 0)}</p>
    <p><b>Instructions:</b> ${escapeHtml(String(selectedAgent.instructions || '').slice(0, 500))}</p>
    <p><b>Allowed tools:</b> <code>${escapeHtml((selectedAgent.allowed_tools || []).join(', '))}</code></p>
    <p><b>Budget:</b> <code>${escapeHtml(JSON.stringify(selectedAgent.budget || {}))}</code></p>
    ${(selectedAgent.messages || []).length ? `<h3>Messages</h3><ol>${selectedAgent.messages.map((m) => `<li><b>${escapeHtml(String(m.from || '?'))}:</b> ${escapeHtml(String(m.text || '').slice(0, 300))} <small>(${escapeHtml(String(m.ts || ''))})</small></li>`).join('')}</ol>` : ''}
    ${selectedAgent.result ? `<h3>Result</h3><pre>${escapeHtml(JSON.stringify(selectedAgent.result, null, 2).slice(0, 2000))}</pre>` : ''}
    ${selectedAgent.error ? `<p style="color:#a00"><b>Error:</b> ${escapeHtml(String(selectedAgent.error).slice(0, 500))}</p>` : ''}` : '';
  res.send(`<html><head><meta http-equiv="refresh" content="5"><title>Agent tasks</title>
    <style>body{font-family:sans-serif;max-width:900px;margin:2em auto;padding:0 1em}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:.4em .6em;text-align:left}code{font-size:.9em}</style></head>
    <body><h1>Agent tasks</h1>
    <p>Auto-refreshes every 5s. Plans checkpoint after every step — resume with execute_plan.
    <a href="/health">health</a> · <a href="/setup">setup</a> · <a href="/api/confirm">approvals</a></p>
    <table><tr><th>Status</th><th>ID</th><th>Goal</th><th>Progress</th><th>Error</th></tr>${rows}</table>
    ${detail}
    <h2>Sub-agents</h2>
    <table><tr><th>Status</th><th>ID</th><th>Role</th><th>Depth</th><th>Parent</th><th>Error</th></tr>${agentRows}</table>
    ${agentDetail}</body></html>`);
});

export default app;

// Start server (only when run directly, so tests can import the app)
// Binds to 127.0.0.1 only: this app is local-first, no deployment —
// nothing listens on the network, and API keys never leave this machine.
const isMain = process.argv[1] && process.argv[1].endsWith('server.js');
if (isMain) {
  (async () => {
    try {
      logger.info('Server starting');
      await initStore(); // opens DuckDB (this process is the single writer), seeds from legacy files
      const PORT = Number(cfg('PORT', '3000')) || 3000;
      
      app.listen(PORT, '127.0.0.1', () => {
        logger.info('Server started successfully', { 
          port: PORT, 
          endpoints: {
            health: `http://localhost:${PORT}/health`,
            setup: `http://localhost:${PORT}/setup`,
            confirm: `http://localhost:${PORT}/api/confirm`,
            metrics: `http://localhost:${PORT}/api/metrics`
          }
        });
        console.log(`Server running on http://localhost:${PORT}`);
        console.log(`Configure settings and keys at http://localhost:${PORT}/setup`);
        console.log(`Approve dangerous tools at http://localhost:${PORT}/api/confirm`);
        console.log(`View metrics at http://localhost:${PORT}/api/metrics`);
        verifyManifestAtStartup();
      });

      // Shut down pooled MCP stdio servers (spawned child processes) on exit.
      const shutdown = async () => {
        logger.info('Server shutting down');
        try {
          const { closeAllMCPClients } = await import('./lib/mcp-client.js');
          await closeAllMCPClients();
        } catch { /* noop */ }
        process.exit(0);
      };
      process.on('SIGINT', shutdown);
      process.on('SIGTERM', shutdown);
    } catch (error) {
      logger.fatal('Server startup failed', { error: error.message, stack: error.stack });
      console.error('Failed to start server:', error);
      process.exit(1);
    }
  })();
}
