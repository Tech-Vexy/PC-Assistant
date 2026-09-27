// Phase 1 memory: remember/recall/forget/resolve + save/list/run/delete
// workflows through the real dispatcher. Isolated DuckDB store.
process.env.AUTO_APPROVE = 'true';
process.env.MCP_ENABLED = 'false';

import os from 'node:os';
import path from 'node:path';
process.env.STORE_PATH = path.join(os.tmpdir(), `test-memory-store-${process.pid}.db`);

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { requiresConfirmation } from '../security.js';

describe('memory tools', () => {
  before(async () => {
    const { initStore } = await import('../lib/store.js');
    await initStore();
  });

  after(async () => {
    const { closeStore } = await import('../lib/store.js');
    await closeStore();
  });

  it('remember/recall/forget round-trip through the dispatcher', async () => {
    const { dispatchTool } = await import('../tools.js');
    const saved = await dispatchTool('remember', { key: 'mem-editor', value: 'VS Code', category: 'preference' });
    assert.equal(saved.success, true);

    const exact = await dispatchTool('recall', { query: 'mem-editor' });
    assert.equal(exact.count, 1);
    assert.equal(exact.memories[0].value, 'VS Code');

    const search = await dispatchTool('recall', { query: 'vs code' });
    assert.ok(search.count >= 1, 'substring search finds the value');

    const filtered = await dispatchTool('recall', { query: 'vs code', category: 'location' });
    assert.equal(filtered.count, 0, 'category filter excludes preferences');

    const gone = await dispatchTool('forget', { key: 'mem-editor' });
    assert.equal(gone.success, true);
    const after = await dispatchTool('recall', { query: 'mem-editor' });
    assert.equal(after.count, 0);
  });

  it('resolve_location maps aliases to saved paths', async () => {
    const { dispatchTool } = await import('../tools.js');
    await dispatchTool('remember', { key: 'project:tafiti', value: 'C:\\Projects\\tafiti', category: 'project' });
    try {
      const hit = await dispatchTool('resolve_location', { name: 'tafiti' });
      assert.equal(hit.success, true);
      assert.equal(hit.value, 'C:\\Projects\\tafiti');
      const miss = await dispatchTool('resolve_location', { name: 'no-such-place-xyz' });
      assert.match(miss.error, /No saved location/i);
    } finally {
      await dispatchTool('forget', { key: 'project:tafiti' });
    }
  });

  it('save/list/run/delete workflow end to end', async () => {
    const { dispatchTool } = await import('../tools.js');
    const steps = [
      { tool: 'system_status', args: {} },
      { tool: 'recall', args: { query: 'nothing-matches-this-xyz' } },
    ];
    const saved = await dispatchTool('save_workflow', { name: 'mem-test-flow', steps, description: 'test flow' });
    assert.equal(saved.success, true);

    const listed = await dispatchTool('list_workflows', {});
    assert.ok(listed.workflows.some((w) => w.name === 'mem-test-flow'));

    const ran = await dispatchTool('run_workflow', { name: 'mem-test-flow' });
    assert.equal(ran.success, true);
    assert.equal(ran.steps.length, 2);
    assert.ok(ran.steps.every((s) => s.ok));

    const stats = (await dispatchTool('list_workflows', {})).workflows.find((w) => w.name === 'mem-test-flow');
    assert.equal(stats.use_count, 1);
    assert.equal(stats.success_count, 1);

    const deleted = await dispatchTool('delete_workflow', { name: 'mem-test-flow' });
    assert.equal(deleted.success, true);
  });

  it('run stops at the first failing step and reports it', async () => {
    const { dispatchTool } = await import('../tools.js');
    await dispatchTool('save_workflow', {
      name: 'mem-fail-flow',
      steps: [{ tool: 'system_status', args: {} }, { tool: 'kill_process', args: { pid: 1 } }],
    });
    try {
      const ran = await dispatchTool('run_workflow', { name: 'mem-fail-flow' });
      assert.match(ran.error, /stopped at step 2 \(kill_process\)/i);
    } finally {
      await dispatchTool('delete_workflow', { name: 'mem-fail-flow' });
    }
    const unknown = await dispatchTool('run_workflow', { name: 'no-such-workflow-xyz' });
    assert.match(unknown.error, /No workflow named/i);
  });

  it('save_workflow rejects unknown tools and bad shapes', async () => {
    const { dispatchTool } = await import('../tools.js');
    const badTool = await dispatchTool('save_workflow', { name: 'x', steps: [{ tool: 'nope_not_a_tool' }] });
    assert.match(badTool.error, /unknown tool/i);
    const empty = await dispatchTool('save_workflow', { name: 'x', steps: [] });
    assert.match(empty.error, /non-empty array/i);
  });

  it('validates memory arguments and gates workflow runs', async () => {
    const { dispatchTool } = await import('../tools.js');
    assert.equal(requiresConfirmation('run_workflow'), true);
    assert.equal(requiresConfirmation('remember'), false);
    assert.equal(requiresConfirmation('recall'), false);
    const bad = await dispatchTool('remember', { key: '', value: 'v' });
    assert.match(bad.error, /key must be/i);
    const badRun = await dispatchTool('run_workflow', { name: '' });
    assert.match(badRun.error, /name must be/i);
  });
});
