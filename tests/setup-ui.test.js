// Browser setup UI (/setup) + session-time LLM override tests.
// Isolated via STORE_PATH (DuckDB file) and DOTENV_PATH (bootstrap mirror),
// so the real store and .env are never touched.
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';

const TMP = path.join(os.tmpdir(), `test-setup-${process.pid}`);
process.env.STORE_PATH = path.join(TMP, 'setup.db');
process.env.DOTENV_PATH = path.join(TMP, 'mirror.env');

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';

describe('browser setup UI (/setup)', () => {
  let base;

  before(async () => {
    await fs.mkdir(TMP, { recursive: true });
    const { initStore, setConfig } = await import('../lib/store.js');
    await initStore();
    await setConfig('ASSEMBLYAI_API_KEY', 'aai-secret-xyz');
    await setConfig('AGENT_ID', 'agent-123');
    await setConfig('LLM_API_KEY', 'old-llm-key');
    const { default: app } = await import('../server.js');
    await new Promise((resolve) => {
      const server = app.listen(0, resolve);
      globalThis.__setupTestServer = server;
    });
    base = `http://localhost:${globalThis.__setupTestServer.address().port}`;
  });

  after(async () => {
    await new Promise((resolve) => globalThis.__setupTestServer.close(resolve));
    const { closeStore } = await import('../lib/store.js');
    await closeStore();
    await fs.rm(TMP, { recursive: true, force: true });
  });

  it('GET /setup renders the slim form without leaking secrets', async () => {
    const html = await fetch(`${base}/setup`).then((x) => x.text());
    for (const name of ['ASSEMBLYAI_API_KEY', 'VOICE_ID', 'LLM_API_KEY', 'GEMINI_API_KEY', 'COMPUTER_USE_ENABLED', 'PORT']) {
      assert.match(html, new RegExp(`name="${name}"`), `expected field ${name}`);
    }
    assert.doesNotMatch(html, /name="FAST_MODEL"/, 'advanced model fields stay out of the UI');
    assert.doesNotMatch(html, /aai-secret-xyz/);
    assert.doesNotMatch(html, /old-llm-key/);
  });

  it('POST /setup persists to the store and mirrors bootstrap keys to file', async () => {
    const r = await fetch(`${base}/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ PORT: '3001', COMPUTER_USE_ENABLED: 'true' }),
    }).then((x) => x.json());
    assert.equal(r.ok, true);
    const { getConfig } = await import('../lib/store.js');
    assert.equal(await getConfig('PORT'), '3001');
    assert.equal(await getConfig('COMPUTER_USE_ENABLED'), 'true');
    assert.equal(await getConfig('ASSEMBLYAI_API_KEY'), 'aai-secret-xyz'); // untouched secret kept
    const mirror = await fs.readFile(process.env.DOTENV_PATH, 'utf8');
    assert.match(mirror, /^PORT=3001$/m); // bootstrap mirror, not the secret
    assert.doesNotMatch(mirror, /aai-secret-xyz/);
  });

  it('rejects cross-origin setup POSTs (CSRF guard)', async () => {
    const r = await fetch(`${base}/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' },
      body: JSON.stringify({ PORT: '3002' }),
    });
    assert.equal(r.status, 403);
  });

  it('blank secret keeps the stored value; new value replaces it', async () => {
    const { getConfig } = await import('../lib/store.js');
    await fetch(`${base}/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ LLM_API_KEY: '' }),
    }).then((x) => x.json());
    assert.equal(await getConfig('LLM_API_KEY'), 'old-llm-key');

    await fetch(`${base}/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ LLM_API_KEY: 'new-key-abc' }),
    }).then((x) => x.json());
    assert.equal(await getConfig('LLM_API_KEY'), 'new-key-abc');

    const html = await fetch(`${base}/setup`).then((x) => x.text());
    assert.doesNotMatch(html, /new-key-abc/);
  });

  it('resolves checkbox hidden-input pairs (false + true => true)', async () => {
    const params = new URLSearchParams();
    params.append('COMPUTER_USE_ENABLED', 'false');
    params.append('COMPUTER_USE_ENABLED', 'true');
    const res = await fetch(`${base}/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
      redirect: 'manual',
    });
    assert.equal(res.status, 302); // form posts redirect on success
    const { getConfig } = await import('../lib/store.js');
    assert.equal(await getConfig('COMPUTER_USE_ENABLED'), 'true');
  });

  it('rejects invalid values with 400', async () => {
    const r = await fetch(`${base}/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ PORT: '99999' }),
    });
    assert.equal(r.status, 400);
    const body = await r.json();
    assert.ok(body.errors.some((e) => /PORT/i.test(e)));
    // Invalid values must not have been persisted
    const { getConfig } = await import('../lib/store.js');
    assert.notEqual(await getConfig('PORT'), '99999');
  });

  it('saves configuration cleanly without requiring external auth', async () => {
    const r = await fetch(`${base}/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ PORT: '3001' }),
    }).then((x) => x.json());
    assert.equal(r.ok, true);
    assert.equal(r.next, undefined);

    const html = await fetch(`${base}/setup?saved=1`).then((x) => x.text());
    assert.match(html, /Saved ✅/i);
  });

  it('agent delegation endpoints round-trip (header-gated)', async () => {
    const RH = { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' };
    const denied = await fetch(`${base}/api/store/config`, {
      headers: { 'Content-Type': 'application/json' },
    });
    assert.equal(denied.status, 403);

    const set = await fetch(`${base}/api/store/config`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ key: 'DELEGATED_KEY', value: 'd1' }),
    }).then((x) => x.json());
    assert.equal(set.ok, true);
    const got = await fetch(`${base}/api/store/config`, { headers: RH }).then((x) => x.json());
    assert.equal(got.config.DELEGATED_KEY, 'd1');

    const sess = await fetch(`${base}/api/store/session`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ session: { sessionId: 'delegated' } }),
    }).then((x) => x.json());
    assert.equal(sess.ok, true);
    const loaded = await fetch(`${base}/api/store/session`, { headers: RH }).then((x) => x.json());
    assert.deepEqual(loaded.session, { sessionId: 'delegated' });

    const audit = await fetch(`${base}/api/store/audit`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ kind: 'tool', entry: { timestamp: new Date().toISOString(), tool: 'delegated_tool', arguments: {} } }),
    }).then((x) => x.json());
    assert.equal(audit.ok, true);
    const bad = await fetch(`${base}/api/store/audit`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ kind: 'nope', entry: {} }),
    });
    assert.equal(bad.status, 400);
  });

  it('memory + workflow delegation round-trips (header-gated)', async () => {
    const RH = { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' };
    const denied = await fetch(`${base}/api/store/memory?q=x`);
    assert.equal(denied.status, 403);

    const set = await fetch(`${base}/api/store/memory`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ op: 'set', key: 'delegated-pref', value: 'v', category: 'preference' }),
    }).then((x) => x.json());
    assert.equal(set.ok, true);
    const got = await fetch(`${base}/api/store/memory?key=delegated-pref`, { headers: RH }).then((x) => x.json());
    assert.equal(got.value, 'v');
    const search = await fetch(`${base}/api/store/memory?q=delegated&category=preference`, { headers: RH }).then((x) => x.json());
    assert.ok(search.memories.some((m) => m.key === 'delegated-pref'));
    const del = await fetch(`${base}/api/store/memory`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ op: 'delete', key: 'delegated-pref' }),
    }).then((x) => x.json());
    assert.equal(del.deleted, true);

    const wsave = await fetch(`${base}/api/store/workflows`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ op: 'save', name: 'delegated-wf', steps: [{ tool: 'system_status', args: {} }], description: 'd' }),
    }).then((x) => x.json());
    assert.equal(wsave.ok, true);
    const wgot = await fetch(`${base}/api/store/workflows?name=delegated-wf`, { headers: RH }).then((x) => x.json());
    assert.equal(wgot.workflow.steps.length, 1);
    const wlist = await fetch(`${base}/api/store/workflows`, { headers: RH }).then((x) => x.json());
    assert.ok(wlist.workflows.some((w) => w.name === 'delegated-wf'));
    const wdel = await fetch(`${base}/api/store/workflows`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ op: 'delete', name: 'delegated-wf' }),
    }).then((x) => x.json());
    assert.equal(wdel.deleted, true);
  });
});

describe('session-time LLM override (agent client)', () => {
  // GEMINI_* / LLM_FALLBACK_MODELS included because agent.js's module-load
  // dotenv.config() refills these from the real .env at first import, and
  // buildLlmRoutes() is Gemini-first (a leftover Gemini key returns a single
  // Gemini route instead of the fast/strong pair).
  const LLM_KEYS = ['LLM_API_KEY', 'LLM_BASE_URL', 'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'FAST_MODEL', 'STRONG_MODEL', 'GEMINI_API_KEY', 'GEMINI_MODEL', 'LLM_FALLBACK_MODELS'];
  let savedEnv;

  before(async () => {
    savedEnv = {};
    for (const k of LLM_KEYS) savedEnv[k] = process.env[k];
    for (const k of LLM_KEYS) delete process.env[k];
    // Clear DB-backed values too (earlier tests stored LLM keys there);
    // cfg() falls through empty strings to defaults.
    const { setConfig } = await import('../lib/store.js');
    for (const k of LLM_KEYS) await setConfig(k, '');
  });

  after(() => {
    for (const k of LLM_KEYS) {
      if (savedEnv[k] === undefined) delete process.env[k];
      else process.env[k] = savedEnv[k];
    }
  });

  it('initializeSession binds the stored agent by id alone (API protocol)', async () => {
    // session.agent_id is first-update-only and mutually exclusive with
    // inline fields — llm routes live on the published agent, not the session.
    // Set env directly: cfg() prefers env, and agent.js's dotenv.config()
    // cannot refill a var that is already present (no-override behavior).
    const savedAgentId = process.env.AGENT_ID;
    process.env.AGENT_ID = 'agent-test-1234';
    try {
      const { VoiceAgent } = await import('../agent.js');
      const agent = new VoiceAgent();
      const sent = [];
      agent.ws = { readyState: 1, send: (s) => sent.push(JSON.parse(s)) };
      agent.initializeSession();
      const update = sent.find((m) => m.type === 'session.update');
      assert.ok(update, 'session.update was sent');
      assert.deepEqual(update.session, { agent_id: 'agent-test-1234' });
    } finally {
      if (savedAgentId !== undefined) process.env.AGENT_ID = savedAgentId;
    }
  });

  it('initializeSession inline mode sends local provider without agent_id', async () => {
    // Delete again here: dotenv.config() (module load, during the first test)
    // refilled these from the real .env after before() cleared them.
    for (const k of LLM_KEYS) delete process.env[k];
    process.env.LLM_API_KEY = 'sess-key';
    process.env.LLM_BASE_URL = 'https://llm.example/v1';
    process.env.FAST_MODEL = 'f1';
    process.env.STRONG_MODEL = 's1';
    const savedAgentId = process.env.AGENT_ID;
    process.env.AGENT_ID = ''; // empty = falsy = inline mode; blocks dotenv refill
    const { VoiceAgent } = await import('../agent.js');
    const agent = new VoiceAgent();
    const sent = [];
    agent.ws = { readyState: 1, send: (s) => sent.push(JSON.parse(s)) };
    agent.initializeSession();
    const update = sent.find((m) => m.type === 'session.update');
    assert.ok(update, 'session.update was sent');
    assert.ok(!('agent_id' in update.session), 'no agent_id in inline mode (mutually exclusive)');
    assert.equal(update.session.llm.length, 2);
    assert.equal(update.session.llm[0].base_url, 'https://llm.example/v1');
    assert.equal(update.session.llm[0].model, 'f1');
    assert.equal(update.session.llm[0].api_key, 'sess-key');
    if (savedAgentId !== undefined) process.env.AGENT_ID = savedAgentId;
  });

  it('initializeSession inline mode omits llm when no provider is configured', async () => {
    for (const k of LLM_KEYS) delete process.env[k];
    const savedAgentId = process.env.AGENT_ID;
    process.env.AGENT_ID = '';
    const { VoiceAgent } = await import('../agent.js');
    const agent = new VoiceAgent();
    const sent = [];
    agent.ws = { readyState: 1, send: (s) => sent.push(JSON.parse(s)) };
    agent.initializeSession();
    const update = sent.find((m) => m.type === 'session.update');
    assert.ok(update, 'session.update was sent');
    assert.ok(!('llm' in update.session), 'no llm override without provider config');
    if (savedAgentId !== undefined) process.env.AGENT_ID = savedAgentId;
  });
});
