// Mock AssemblyAI WebSocket + dispatcher integration tests.
// process.env.AUTO_APPROVE=true so dangerous-tool tests don't block on the approval queue.
process.env.AUTO_APPROVE = 'true';
process.env.MCP_ENABLED = 'false'; // unit tests exercise direct-SDK validation, not live MCP servers
// Isolated DuckDB store (sessions/audit) — never touches data/assistant.db.
import os from 'node:os';
import path from 'node:path';
process.env.STORE_PATH = path.join(os.tmpdir(), `test-tools-store-${process.pid}.db`);

import { describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';

describe('tools dispatcher', () => {
  it('rejects unknown tools', async () => {
    const { dispatchTool } = await import('../tools.js');
    const r = await dispatchTool('nope_not_a_tool', {});
    assert.ok(r.error);
  });

  it('fails argument validation safely', async () => {
    const { dispatchTool } = await import('../tools.js');
    const r = await dispatchTool('kill_process', { pid: 1 });
    assert.match(r.error, /validation|protected/i);
  });

  it('blocks non-allowlisted shell commands', async () => {
    const { dispatchTool } = await import('../tools.js');
    const r = await dispatchTool('run_command', { command: 'rm -rf / --no-preserve-root' });
    assert.ok(r.error || r.success === false);
  });

  it('system_status returns structured data', async () => {
    const { dispatchTool } = await import('../tools.js');
    const r = await dispatchTool('system_status', {});
    assert.ok(r.cpu && r.memory && r.system);
  });

  it('list_processes returns a process list', async () => {
    const { dispatchTool } = await import('../tools.js');
    const r = await dispatchTool('list_processes', { limit: 3 });
    assert.ok(Array.isArray(r.processes) && r.processes.length > 0);
    assert.ok(typeof r.processes[0].pid === 'number');
  });

  it('validates click_mouse arguments', async () => {
    const { dispatchTool } = await import('../tools.js');
    const r = await dispatchTool('click_mouse', { button: 'invalid_button' });
    assert.match(r.error, /validation|Button must be/i);
  });

  it('validates open_application arguments', async () => {
    const { dispatchTool } = await import('../tools.js');
    const r = await dispatchTool('open_application', { appName: '' });
    assert.match(r.error, /validation|appName must be/i);
  });

  it('validates media_control and handles volume actions', async () => {
    const { dispatchTool } = await import('../tools.js');
    const bad = await dispatchTool('media_control', { action: 'super_loud' });
    assert.match(bad.error, /validation|Invalid media action/i);
    const ok = await dispatchTool('media_control', { action: 'mute' });
    assert.equal(ok.success, true);
  });

  it('clipboard tool writes and reads', async () => {
    const { dispatchTool } = await import('../tools.js');
    const write = await dispatchTool('clipboard', { action: 'write', text: 'assemblyai-voice-assistant' });
    assert.equal(write.success, true);
    const read = await dispatchTool('clipboard', { action: 'read' });
    assert.equal(read.success, true);
    assert.match(read.content, /assemblyai-voice-assistant/);
  });
});

describe('AssemblyAI message handling (mock WebSocket)', () => {
  it('answers tool.call with tool.result', async () => {
    const { VoiceAgent } = await import('../agent.js');
    const agent = new VoiceAgent();
    const sent = [];
    agent.sessionId = 'sess-test';
    agent.ws = { readyState: 1, send: (s) => sent.push(JSON.parse(s)) };
    await agent.handleToolCall({ call_id: 'c1', name: 'system_status', arguments: {} });
    assert.equal(sent.length, 1);
    assert.equal(sent[0].type, 'tool.result');
    assert.equal(sent[0].call_id, 'c1');
  });

  it('updates session state on session.ready', async () => {
    const { VoiceAgent } = await import('../agent.js');
    const agent = new VoiceAgent();
    agent.startRecording = mock.fn(); // don't spawn ffmpeg in tests
    agent.ws = { readyState: 1, send: () => {} };
    await agent.handleMessage(JSON.stringify({ type: 'session.ready', session_id: 'sess-123' }));
    assert.equal(agent.sessionId, 'sess-123');
  });
});
