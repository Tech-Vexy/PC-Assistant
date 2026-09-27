// Generic MCP (Model Context Protocol) JSON-RPC 2.0 client over stdio.
// Spawns an MCP server process, performs `initialize`, and exposes `callTool`.
// Includes connection pooling (one process per server id, reused) and timeouts.
//
// Env:
//   MCP_ENABLED=true|false (default: true — falls back to direct SDK on any failure)
//   MCP_TIMEOUT_MS (default 15000)

import { spawn } from 'child_process';
import { cfg } from './store.js';

const pools = new Map(); // serverId -> MCPClient

export class MCPClient {
  constructor(serverId, command, args = [], opts = {}) {
    this.serverId = serverId;
    this.command = command;
    this.args = args;
    this.proc = null;
    this.buffer = '';
    this.pending = new Map(); // id -> { resolve, reject, timer }
    this.nextId = 1;
    this.timeoutMs = Number(cfg('MCP_TIMEOUT_MS', opts.timeoutMs || '15000')) || 15000;
    this.initialized = false;
  }

  get enabled() {
    return cfg('MCP_ENABLED', 'true').toLowerCase() !== 'false';
  }

  ensureStarted() {
    if (this.proc && !this.proc.killed) return;
    this.proc = spawn(this.command, this.args, { stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc.stdout.on('data', (d) => this._onData(d));
    this.proc.stderr.on('data', (d) => {
      // MCP servers log to stderr; ignore unless debugging
      if (process.env.MCP_DEBUG || cfg('MCP_DEBUG')) console.error(`[mcp:${this.serverId}]`, d.toString().slice(0, 500));
    });
    this.proc.on('exit', (code) => {
      const err = new Error(`MCP server '${this.serverId}' exited with code ${code}`);
      for (const [, p] of this.pending) {
        clearTimeout(p.timer);
        p.reject(err);
      }
      this.pending.clear();
      this.proc = null;
      this.initialized = false;
      pools.delete(this.serverId);
    });
  }

  _onData(chunk) {
    this.buffer += chunk.toString();
    let idx;
    // MCP stdio uses newline-delimited JSON-RPC
    while ((idx = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue; // skip non-JSON log lines
      }
      if (msg.id != null && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else p.resolve(msg.result);
      }
    }
  }

  _request(method, params = {}) {
    this.ensureStarted();
    const id = this.nextId++;
    const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n';
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`MCP request '${method}' timed out after ${this.timeoutMs}ms`));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.proc.stdin.write(payload, (err) => {
        if (err) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(err);
        }
      });
    });
  }

  async initialize() {
    if (this.initialized) return;
    await this._request('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'pc-assistant', version: '1.0.0' },
    });
    this.initialized = true;
  }

  async listTools() {
    await this.initialize();
    const result = await this._request('tools/list', {});
    return result.tools || [];
  }

  async callTool(name, args = {}) {
    await this.initialize();
    const result = await this._request('tools/call', { name, arguments: args });
    return result;
  }

  async close() {
    try {
      this.proc?.kill('SIGTERM');
    } catch { /* noop */ }
    this.proc = null;
    this.initialized = false;
    pools.delete(this.serverId);
  }
}

export function getMCPClient(serverId, command, args = []) {
  if (!pools.has(serverId)) {
    pools.set(serverId, new MCPClient(serverId, command, args));
  }
  return pools.get(serverId);
}

export async function closeAllMCPClients() {
  for (const [, c] of pools) {
    await c.close().catch(() => {});
  }
  pools.clear();
}

// Try an MCP tool call, return { ok, result } — never throws, so callers can fall back.
export async function tryMCPTool(serverId, command, args, toolName, toolArgs) {
  try {
    if (cfg('MCP_ENABLED', 'true').toLowerCase() === 'false') {
      return { ok: false, reason: 'MCP_DISABLED' };
    }
    const client = getMCPClient(serverId, command, args);
    const result = await client.callTool(toolName, toolArgs);
    return { ok: true, result };
  } catch (err) {
    return { ok: false, reason: err.message };
  }
}

// Normalize MCP tool results (some servers return { content: [{ text }] })
export function normalizeMCPResult(result) {
  if (!result) return result;
  if (Array.isArray(result.content)) {
    const texts = result.content.map((c) => c.text ?? JSON.stringify(c)).join('\n');
    try {
      return JSON.parse(texts);
    } catch {
      return { text: texts };
    }
  }
  return result;
}
