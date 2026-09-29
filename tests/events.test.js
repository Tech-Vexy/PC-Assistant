// Event bus + cross-process relay tests (isolated DuckDB store, like server.test.js)
import os from 'node:os';
import path from 'node:path';
process.env.STORE_PATH = path.join(os.tmpdir(), `test-events-store-${process.pid}.db`);

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('server event relay endpoint', () => {
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

  it('rejects publish without the delegation header', async () => {
    const r = await fetch(`${base}/api/events/publish`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ events: [{ type: 'state', data: { state: 'ready' } }] }),
    });
    assert.equal(r.status, 403);
  });

  it('forwards relayed events to SSE subscribers', async () => {
    // Subscribe first (SSE stays open), then publish from a "separate process".
    const gotEvent = new Promise((resolve) => {
      const ctrl = new AbortController();
      fetch(`${base}/api/events`, { signal: ctrl.signal })
        .then(async (res) => {
          const reader = res.body.getReader();
          const decoder = new TextDecoder();
          let buf = '';
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buf += decoder.decode(value, { stream: true });
            const lines = buf.split('\n\n');
            buf = lines.pop() || '';
            for (const block of lines) {
              const m = block.match(/^data: (.*)$/m);
              if (!m) continue;
              const ev = JSON.parse(m[1]);
              if (ev.type === 'transcript') {
                ctrl.abort();
                resolve(ev);
                return;
              }
            }
          }
        })
        .catch(() => {});
    });

    // Give the SSE connection a moment to attach its listener.
    await new Promise((r) => setTimeout(r, 200));

    const RH = { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' };
    const pub = await fetch(`${base}/api/events/publish`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({
        events: [
          { type: 'state', timestamp: 't1', data: { state: 'ready' } },
          { type: 'transcript', timestamp: 't2', data: { speaker: 'user', text: 'hello dashboard' } },
        ],
      }),
    }).then((x) => x.json());
    assert.equal(pub.ok, true);
    assert.equal(pub.forwarded, 2);

    const ev = await Promise.race([
      gotEvent,
      new Promise((_, rej) => setTimeout(() => rej(new Error('SSE event never arrived')), 3000)),
    ]);
    assert.equal(ev.type, 'transcript');
    assert.equal(ev.data.text, 'hello dashboard');
  });

  it('drops malformed relay entries and caps the batch', async () => {
    const RH = { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' };
    const junk = [
      null,
      { type: 42, data: {} }, // non-string type
      { type: 'state' }, // missing data
      { type: 'tool_call', data: { toolName: 'run_command', args: {}, callId: 'c1' } },
    ];
    const r = await fetch(`${base}/api/events/publish`, {
      method: 'POST',
      headers: RH,
      body: JSON.stringify({ events: junk }),
    }).then((x) => x.json());
    assert.equal(r.ok, true);
    assert.equal(r.forwarded, 1);
  });

  it('closes cleanly', async () => {
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  });
});

describe('end-to-end approval flow over the event bus', () => {
  let base;
  let server;

  it('agent dispatch waits for a remote approval and executes once approved', async () => {
    process.env.AUTO_APPROVE = 'false'; // manual confirmation under test
    process.env.APPROVAL_HTTP_URL = '';
    process.env.APPROVAL_TTL_MS = '20000'; // bound the wait so failures fail fast
    const { default: app } = await import('../server.js');
    await new Promise((resolve) => {
      server = app.listen(0, resolve);
    });
    base = `http://localhost:${server.address().port}`;
    process.env.APPROVAL_HTTP_URL = base; // what agent.js sets in its main block
    const { setRelayUrl, eventEmitter } = await import('../lib/event-emitter.js');
    setRelayUrl(base); // agent -> server event forwarding, like the live agent

    const ctrl = new AbortController();
    try {

    // Warm up the connection pool and confirm the server answers before dispatching.
    for (let i = 0; i < 20; i++) {
      try {
        const h = await fetch(`${base}/api/approvals`);
        if (h.ok) break;
      } catch { /* retry */ }
      await new Promise((r) => setTimeout(r, 100));
    }

    // Collect SSE events on the server side.
    const sseEvents = [];
    fetch(`${base}/api/events`, { signal: ctrl.signal })
      .then(async (res) => {
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buf = '';
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          const blocks = buf.split('\n\n');
          buf = blocks.pop() || '';
          for (const block of blocks) {
            const m = block.match(/^data: (.*)$/m);
            if (m) {
              try { sseEvents.push(JSON.parse(m[1])); } catch { /* noop */ }
            }
          }
        }
      })
      .catch(() => {});
    await new Promise((r) => setTimeout(r, 200));

    // 1) Dispatch a dangerous tool from the "agent process" — it must BLOCK.
    const { dispatchTool } = await import('../tools.js');
    const t0 = Date.now();
    const dispatchPromise = dispatchTool('run_command', { command: 'echo approval-flow-ok' });

    // 2) The pending approval appears in the server queue with a real id.
    // (Poll: the first audit append can take a moment on a fresh store.)
    let entry = null;
    for (let i = 0; i < 60 && !entry; i++) {
      await new Promise((r) => setTimeout(r, 250));
      const queue = await fetch(`${base}/api/approvals`).then((x) => x.json());
      entry = queue.pending.find((p) => p.tool === 'run_command') || null;
    }
    assert.ok(entry, 'dangerous tool is pending approval on the server');
    assert.ok(String(entry.id).startsWith('appr-'), 'queue id is the real approval id');

    // 3) Approve via the decision endpoint (as the dashboard/confirm UI would).
    const deliver = await fetch(`${base}/api/approvals/${entry.id}/decision`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' },
      body: JSON.stringify({ approved: true, note: 'approved by test' }),
    });
    assert.equal(deliver.status, 200);

    // 4) The blocked dispatch resolves and the command actually ran.
    const result = await dispatchPromise;
    const waitedMs = Date.now() - t0;
    assert.ok(waitedMs >= 300, `dispatch blocked for the approval (${waitedMs}ms)`);
    assert.ok(!result.error, `no denial error: ${JSON.stringify(result)}`);
    assert.ok(JSON.stringify(result).includes('approval-flow-ok'), 'command output present');

    // 5) SSE subscribers saw the full lifecycle with the same real id.
    await new Promise((r) => setTimeout(r, 500));
    ctrl.abort();
    const reqEv = sseEvents.find((e) => e.type === 'approval_request');
    const resEv = sseEvents.find((e) => e.type === 'approval_resolved');
    assert.ok(reqEv, 'approval_request reached the SSE stream');
    assert.equal(reqEv.data.approvalId, entry.id);
    assert.ok(resEv, 'approval_resolved reached the SSE stream');
    assert.equal(resEv.data.approvalId, entry.id);
    assert.equal(resEv.data.approved, true);
    } finally {
      ctrl.abort();
      setRelayUrl(null);
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
    }
  });
});

describe('event bus internals', () => {
  it('emits approval events with the payload intact', async () => {
    const { eventEmitter } = await import('../lib/event-emitter.js');
    const seen = [];
    const listener = (e) => seen.push(e);
    eventEmitter.on('event', listener);
    try {
      eventEmitter.emitApprovalRequest('run_command', { command: 'echo hi' }, 'appr-abc');
      eventEmitter.emitApprovalResolved('appr-abc', { tool: 'run_command', approved: true, note: 'ok' });
    } finally {
      eventEmitter.off('event', listener);
    }
    const req = seen.find((e) => e.type === 'approval_request');
    const res = seen.find((e) => e.type === 'approval_resolved');
    assert.equal(req.data.approvalId, 'appr-abc');
    assert.equal(req.data.toolName, 'run_command');
    assert.equal(res.data.approved, true);
    assert.equal(res.data.tool, 'run_command');
  });

  it('relay thins audio_level bursts and keeps other events in order', async () => {
    const { setRelayUrl } = await import('../lib/event-emitter.js');
    const { eventEmitter } = await import('../lib/event-emitter.js');
    const batches = [];
    const origFetch = globalThis.fetch;
    globalThis.fetch = async (url, opts) => {
      batches.push(JSON.parse(opts.body));
      return { ok: true, json: async () => ({ ok: true }) };
    };
    try {
      setRelayUrl('http://relay.test');
      for (let i = 0; i < 20; i++) {
        eventEmitter.emitAudioLevel(i, i % 2 === 0);
      }
      eventEmitter.emitTranscript('user', 'test text');
      // Wait past the flush interval.
      await new Promise((r) => setTimeout(r, 300));
    } finally {
      setRelayUrl(null);
      globalThis.fetch = origFetch;
    }
    const audioBatches = batches.flatMap((b) => b.events.filter((e) => e.type === 'audio_level'));
    const transcripts = batches.flatMap((b) => b.events.filter((e) => e.type === 'transcript'));
    assert.ok(audioBatches.length <= 4, `audio thinned to <=4 per flush, got ${audioBatches.length}`);
    assert.equal(transcripts.length, 1);
    assert.equal(transcripts[0].data.text, 'test text');
    assert.equal(batches[0].events[0].type, 'audio_level', 'ordering preserved');
  });

  it('does not relay when no URL is set (server process mode)', async () => {
    const { eventEmitter, getRelayUrl } = await import('../lib/event-emitter.js');
    assert.equal(getRelayUrl(), null);
    let fetchCalled = false;
    const origFetch = globalThis.fetch;
    globalThis.fetch = async () => {
      fetchCalled = true;
      return { ok: true, json: async () => ({}) };
    };
    try {
      eventEmitter.emitState('ready', {});
      await new Promise((r) => setTimeout(r, 250));
    } finally {
      globalThis.fetch = origFetch;
    }
    assert.equal(fetchCalled, false);
  });
});
