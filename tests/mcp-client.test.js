import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { MCPClient } from '../lib/mcp-client.js';

// Minimal in-process mock MCP server speaking newline-delimited JSON-RPC over stdio.
const MOCK_SERVER_CODE = `
let buf = '';
process.stdin.on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    const respond = (result, error) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result, error }) + '\\n');
    if (msg.method === 'initialize') respond({ ok: true });
    else if (msg.method === 'tools/list') respond({ tools: [{ name: 'echo' }] });
    else if (msg.method === 'tools/call') respond({ echo: msg.params.arguments });
    else respond(null, { message: 'unknown method' });
  }
});
`;

describe('MCPClient (mock stdio server)', () => {
  it('initializes, lists tools, and calls a tool with pooling', async () => {
    const a = new MCPClient('mock', process.execPath, ['-e', MOCK_SERVER_CODE], { timeoutMs: 5000 });
    const tools = await a.listTools();
    assert.deepEqual(tools, [{ name: 'echo' }]);
    const res = await a.callTool('echo', { hello: 'world' });
    assert.deepEqual(res, { echo: { hello: 'world' } });
    await a.close();
  });

  it('surfaces unknown-method errors instead of hanging', async () => {
    const a = new MCPClient('mock2', process.execPath, ['-e', MOCK_SERVER_CODE], { timeoutMs: 5000 });
    await assert.rejects(() => a._request('nope.unknown', {}), /unknown method/);
    await a.close();
  });
});
