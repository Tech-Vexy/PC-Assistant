// Native terminal tools: one-shot execute + interactive session lifecycle
// (start/read/input/kill) through the real dispatcher. Uses `node` itself as
// the test binary (allowlisted, cross-platform). Isolated DuckDB store.
process.env.AUTO_APPROVE = 'true';
process.env.MCP_ENABLED = 'false';

import os from 'node:os';
import path from 'node:path';
process.env.STORE_PATH = path.join(os.tmpdir(), `test-terminal-store-${process.pid}.db`);

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { requiresConfirmation } from '../security.js';
import { __clearSessions } from '../tools/terminal.js';

async function pollFor(fn, timeoutMs = 8000) {
  const start = Date.now();
  let last;
  while (Date.now() - start < timeoutMs) {
    last = await fn();
    if (last) return last;
    await new Promise((r) => setTimeout(r, 150));
  }
  return last;
}

describe('terminal tools', () => {
  before(async () => {
    const { initStore } = await import('../lib/store.js');
    await initStore();
  });

  after(async () => {
    __clearSessions();
    const { closeStore } = await import('../lib/store.js');
    await closeStore();
  });

  it('terminal_execute runs allowlisted commands with cwd/timeout', async () => {
    const { dispatchTool } = await import('../tools.js');
    const ok = await dispatchTool('terminal_execute', { command: 'echo hello-terminal' });
    assert.equal(ok.success, true);
    assert.match(ok.stdout, /hello-terminal/);

    const blocked = await dispatchTool('terminal_execute', { command: 'rm -rf /tmp/x' });
    assert.ok(blocked.error || blocked.success === false, 'non-allowlisted command blocked');

    const badCwd = await dispatchTool('terminal_execute', { command: 'echo hi', cwd: 'C:\\no-such-dir-xyz-123' });
    assert.match(badCwd.error || badCwd.stderr, /not an existing directory/i);

    const badTimeout = await dispatchTool('terminal_execute', { command: 'echo hi', timeoutMs: 5 });
    assert.match(badTimeout.error, /timeoutMs must be/i);
  });

  it('run_command accepts the new cwd/timeout options', async () => {
    const { dispatchTool } = await import('../tools.js');
    const ok = await dispatchTool('run_command', { command: 'echo hi', timeoutMs: 10000 });
    assert.equal(ok.success, true);
  });

  it('session lifecycle: start, read output, kill', async () => {
    const { dispatchTool } = await import('../tools.js');
    const started = await dispatchTool('terminal_start', {
      command: 'node -e "console.log(\'ready-marker-123\')"',
    });
    assert.ok(started.sessionId, 'session id returned');

    const seen = await pollFor(async () => {
      const r = await dispatchTool('terminal_read', { sessionId: started.sessionId });
      if (r.error) return null;
      if (r.output.includes('ready-marker-123')) return r;
      if (!r.running) return r; // exited without marker -> fail below
      return null;
    });
    assert.ok(seen && seen.output.includes('ready-marker-123'), 'session output readable');

    const killed = await dispatchTool('terminal_kill', { sessionId: started.sessionId });
    assert.equal(killed.success, true);

    const afterKill = await dispatchTool('terminal_read', { sessionId: started.sessionId });
    assert.match(afterKill.error, /No terminal session/i);
  });

  it('terminal_input reaches session stdin', async () => {
    const { dispatchTool } = await import('../tools.js');
    const started = await dispatchTool('terminal_start', {
      command: 'node -e "process.stdin.on(\'data\',function(d){console.log(\'got:\'+d.toString().trim())})"',
    });
    try {
      // Give the REPL a moment to boot before writing stdin.
      await new Promise((r) => setTimeout(r, 800));
      const sent = await dispatchTool('terminal_input', { sessionId: started.sessionId, input: 'hello-input\n' });
      assert.equal(sent.success, true);

      const seen = await pollFor(async () => {
        const r = await dispatchTool('terminal_read', { sessionId: started.sessionId });
        return !r.error && r.output.includes('got:hello-input') ? r : null;
      });
      assert.ok(seen, 'stdin echo observed in session output');
    } finally {
      await dispatchTool('terminal_kill', { sessionId: started.sessionId });
    }
  });

  it('unknown sessions and oversize input fail safely', async () => {
    const { dispatchTool } = await import('../tools.js');
    for (const tool of ['terminal_read', 'terminal_kill']) {
      const r = await dispatchTool(tool, { sessionId: 'term-doesnotexist' });
      assert.match(r.error, /No terminal session/i);
    }
    const noInput = await dispatchTool('terminal_input', { sessionId: 'term-doesnotexist', input: 'x' });
    assert.match(noInput.error, /No terminal session/i);
    const big = await dispatchTool('terminal_input', { sessionId: 'term-doesnotexist', input: 'x'.repeat(11 * 1024) });
    assert.match(big.error, /safety limit/i);
    const empty = await dispatchTool('terminal_start', { command: '   ' });
    assert.match(empty.error, /non-empty string/i);
  });

  it('gates execute/start, leaves read/input/kill session-scoped', async () => {
    assert.equal(requiresConfirmation('terminal_execute'), true);
    assert.equal(requiresConfirmation('terminal_start'), true);
    assert.equal(requiresConfirmation('terminal_read'), false);
    assert.equal(requiresConfirmation('terminal_input'), false);
    assert.equal(requiresConfirmation('terminal_kill'), false);
  });
});
