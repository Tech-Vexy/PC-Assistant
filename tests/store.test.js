// DuckDB store tests: config/tokens/sessions/audits roundtrips, env
// precedence, and one-time migration from legacy files. Isolated via
// STORE_PATH so the real data/assistant.db is never touched.
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';

const TMP = path.join(os.tmpdir(), `test-store-${process.pid}`);
process.env.STORE_PATH = path.join(TMP, 'store.db');

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  initStore,
  closeStore,
  storeMode,
  cfg,
  getConfig,
  setConfig,
  allConfig,
  getTokens,
  saveTokens,
  loadSession,
  saveSession,
  appendToolAudit,
  appendSecurityAudit,
  recentToolAudits,
  recentSecurityAudits,
  memSearch,
  wfSave,
  wfList,
  wfDelete,
} from '../lib/store.js';

describe('duckdb store', () => {
  before(async () => {
    await fs.mkdir(TMP, { recursive: true });
    await initStore();
    assert.equal(storeMode(), 'local');
  });

  after(async () => {
    await closeStore();
    await fs.rm(TMP, { recursive: true, force: true });
  });

  it('round-trips config values', async () => {
    await setConfig('STORE_TEST_KEY', 'v1');
    assert.equal(await getConfig('STORE_TEST_KEY'), 'v1');
    assert.equal(cfg('STORE_TEST_KEY', 'dflt'), 'v1');
    const all = await allConfig();
    assert.equal(all.STORE_TEST_KEY, 'v1');
  });

  it('prefers process.env over the DB (12-factor + tests)', async () => {
    await setConfig('STORE_ENV_KEY', 'from-db');
    assert.equal(cfg('STORE_ENV_KEY'), 'from-db');
    process.env.STORE_ENV_KEY = 'from-env';
    try {
      assert.equal(cfg('STORE_ENV_KEY'), 'from-env');
    } finally {
      delete process.env.STORE_ENV_KEY;
    }
    assert.equal(cfg('STORE_ENV_KEY'), 'from-db');
  });

  it('round-trips OAuth tokens', async () => {
    await saveTokens({ access_token: 'a', refresh_token: 'r' }, 'google');
    assert.deepEqual(await getTokens('google'), { access_token: 'a', refresh_token: 'r' });
  });

  it('round-trips voice sessions', async () => {
    await saveSession({ sessionId: 'sess-1', lastTranscript: 'hello' });
    assert.deepEqual(await loadSession(), { sessionId: 'sess-1', lastTranscript: 'hello' });
  });

  it('returns JSON-serializable rows (no BigInt/Timestamp leaks)', async () => {
    await wfSave('json-safe-wf', [{ tool: 'system_status', args: {} }], 'd');
    await appendToolAudit({ timestamp: new Date().toISOString(), tool: 't', arguments: {} });
    for (const rows of [await wfList(), await recentToolAudits(5), await recentSecurityAudits(5), await memSearch('', {})]) {
      assert.doesNotThrow(() => JSON.stringify(rows), 'rows must survive res.json()');
    }
    const listed = await wfList();
    assert.match(listed.find((w) => w.name === 'json-safe-wf').updated_at, /^\d{4}-\d{2}-\d{2}T/, 'timestamps come back ISO');
    await wfDelete('json-safe-wf');
  });

  it('appends and reads back audit rows', async () => {
    await appendToolAudit({
      timestamp: '2026-01-01T00:00:00.000Z',
      tool: 'system_status',
      arguments: {},
      result: { ok: true },
    });
    await appendSecurityAudit({
      timestamp: '2026-01-01T00:00:01.000Z',
      event: 'TEST_EVENT',
      details: { x: 1 },
      severity: 'LOW',
    });
    const tools = await recentToolAudits(10);
    assert.ok(tools.some((r) => r.tool === 'system_status'));
    const sec = await recentSecurityAudits(10);
    assert.ok(sec.some((r) => r.event === 'TEST_EVENT'));
  });

  it('migrates legacy files once (seed-only, no double import)', async () => {
    const root = path.join(TMP, 'legacy');
    await fs.mkdir(root, { recursive: true });
    await fs.writeFile(path.join(root, '.env'), 'MIG_A=1\nMIG_B=two\n');
    await fs.writeFile(path.join(root, 'tokens.json'), JSON.stringify({ access_token: 'tok' }));
    await fs.writeFile(path.join(root, '.session-state.json'), JSON.stringify({ sessionId: 'old' }));
    await fs.writeFile(
      path.join(root, 'tool-audit.log'),
      JSON.stringify({ timestamp: '2026-01-02T00:00:00.000Z', tool: 'migrated_tool', arguments: {} }) + '\nnot-json\n'
    );
    // Fresh DB so counts are deterministic
    await closeStore();
    process.env.STORE_PATH = path.join(TMP, 'mig.db');
    await initStore();

    const { migrateFromFiles } = await import('../lib/store.js');
    const res1 = await migrateFromFiles({ root });
    assert.ok(res1.some((s) => s.startsWith('.env')), `expected .env migration, got ${JSON.stringify(res1)}`);
    assert.equal(await getConfig('MIG_A'), '1');
    assert.deepEqual(await getTokens('google'), { access_token: 'tok' });
    assert.ok((await recentToolAudits(1000)).some((r) => r.tool === 'migrated_tool'));

    const before = (await recentToolAudits(1000)).length;
    const res2 = await migrateFromFiles({ root });
    const after = (await recentToolAudits(1000)).length;
    assert.equal(before, after, 'log re-import must not duplicate rows');
    assert.ok(!res2.some((s) => s.includes('tool-audit.log')), 'second run skips fingerprinted logs');

    // .env seed must not overwrite existing DB values (config or session)
    await setConfig('MIG_A', 'db-wins');
    await saveSession({ sessionId: 'keep-me' });
    await migrateFromFiles({ root });
    assert.equal(await getConfig('MIG_A'), 'db-wins');
    assert.deepEqual(await loadSession(), { sessionId: 'keep-me' });
  });
});
