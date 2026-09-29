// Isolated DuckDB store — never touches data/assistant.db.
import os from 'node:os';
import path from 'node:path';
process.env.STORE_PATH = path.join(os.tmpdir(), `test-server-store-${process.pid}.db`);

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('auth server routes', () => {
  let base;
  let server;

  it('starts on an ephemeral port', async () => {
    process.env.AUTO_APPROVE = 'true';
    const { default: app } = await import('../server.js');
    await new Promise((resolve) => {
      server = app.listen(0, resolve);
    });
    base = `http://localhost:${server.address().port}`;
  });

  it('GET /health returns ok', async () => {
    const r = await fetch(`${base}/health`).then((x) => x.json());
    assert.equal(r.status, 'ok');
  });

  it('GET /api/approvals returns a list', async () => {
    const r = await fetch(`${base}/api/approvals`).then((x) => x.json());
    assert.ok(Array.isArray(r.pending));
  });

  it('rejects cross-origin approval POSTs (CSRF guard)', async () => {
    const r = await fetch(`${base}/api/approvals/appr-fake`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' },
      body: JSON.stringify({ approved: true }),
    });
    assert.equal(r.status, 403);
  });

  it('remote approval delegation: request, list in UI queue, deny via decision endpoint', async () => {
    const RH = { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' };

    // 1) Request without the client header is rejected
    const noHeader = await fetch(`${base}/api/approvals/request`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tool: 'kill_process', args: { pid: 123 } }),
    });
    assert.equal(noHeader.status, 403);

    // 2) Delegate a request (long-poll) and deny it from a second connection
    const decisionPromise = fetch(`${base}/api/approvals/request`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ tool: 'kill_process', args: { pid: 4242 }, ttlMs: 10_000 }),
    }).then((x) => x.json());

    // UI queue should now list the pending approval
    await new Promise((r) => setTimeout(r, 150));
    const queue = await fetch(`${base}/api/approvals`).then((x) => x.json());
    assert.ok(queue.pending.length >= 1, 'remote request should appear in /api/approvals');
    const entry = queue.pending.find((p) => p.tool === 'kill_process');
    assert.ok(entry, 'kill_process entry visible to the confirm UI');

    // Deny it via the decision endpoint (as the confirm UI would)
    const deliver = await fetch(`${base}/api/approvals/${entry.id}/decision`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ approved: false, note: 'denied by test' }),
    });
    assert.equal(deliver.status, 200);

    const decision = await decisionPromise;
    assert.equal(decision.approved, false);
    assert.match(decision.note || '', /denied/i);

    // 3) Queue is drained after the decision
    const after = await fetch(`${base}/api/approvals`).then((x) => x.json());
    assert.ok(!after.pending.some((p) => p.id === entry.id), 'entry removed after decision');
  });

  it('remote approval delegation: approve flow resolves approved=true', async () => {
    const RH = { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' };
    const decisionPromise = fetch(`${base}/api/approvals/request`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ tool: 'run_command', args: { command: 'echo hi' }, ttlMs: 10_000 }),
    }).then((x) => x.json());

    await new Promise((r) => setTimeout(r, 150));
    const queue = await fetch(`${base}/api/approvals`).then((x) => x.json());
    const entry = queue.pending.find((p) => p.tool === 'run_command');
    assert.ok(entry);

    const deliver = await fetch(`${base}/api/approvals/${entry.id}/decision`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ approved: true, note: 'test approve' }),
    });
    assert.equal(deliver.status, 200);

    const decision = await decisionPromise;
    assert.equal(decision.approved, true);
  });

  it('remote approval delegation: UI endpoint POST /api/approvals/:id resolves approved=true without crash', async () => {
    const RH = { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' };
    const decisionPromise = fetch(`${base}/api/approvals/request`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ tool: 'open_application', args: { appName: 'Calculator' }, ttlMs: 10_000 }),
    }).then((x) => x.json());

    await new Promise((r) => setTimeout(r, 150));
    const queue = await fetch(`${base}/api/approvals`).then((x) => x.json());
    const entry = queue.pending.find((p) => p.tool === 'open_application');
    assert.ok(entry);

    // Simulate browser form post from /api/confirm
    const deliver = await fetch(`${base}/api/approvals/${entry.id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'approved=true',
      redirect: 'manual',
    });
    assert.equal(deliver.status, 302); // redirects back to /api/confirm

    const decision = await decisionPromise;
    assert.equal(decision.approved, true);
  });

  it('POST /test-tool dispatches read-only tools', async () => {
    const r = await fetch(`${base}/test-tool`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tool: 'system_status', args: {} }),
    }).then((x) => x.json());
    assert.ok(r.cpu || r.error);
  });

  it('closes cleanly', async () => {
    await new Promise((resolve) => server.close(resolve));
  });
});
