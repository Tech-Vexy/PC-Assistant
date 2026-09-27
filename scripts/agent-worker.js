// Sub-agent worker (Phase 4): runs ONE agent-step loop in an isolated OS
// process and reports back through the store. Spawned by spawn_agent for
// high-risk tool allowlists; the parent never waits on IPC — it polls the
// agents table (or uses waitMs polling in spawnAgent).
//
// Like agent.js this process never opens the DuckDB file (single-writer
// rule): it uses remote store mode against the server URL inherited via
// APPROVAL_HTTP_URL (defaulting to localhost:PORT like agent.js).
// Approvals for dangerous steps resolve in the server UI via the same
// delegation path as the voice agent.
//
// Usage: node scripts/agent-worker.js <agentId>
import dotenv from 'dotenv';
import { dispatchTool } from '../tools.js';
import { initStore, agentGet, agentUpdate, cfg } from '../lib/store.js';
import { runAgentLoop } from '../tools/agents.js';

dotenv.config();

const isMain = process.argv[1] && process.argv[1].endsWith('agent-worker.js');
if (isMain) {
  const agentId = process.argv[2];
  if (!agentId) {
    console.error('Usage: node scripts/agent-worker.js <agentId>');
    process.exit(2);
  }
  if (!process.env.APPROVAL_HTTP_URL) {
    process.env.APPROVAL_HTTP_URL = `http://localhost:${cfg('PORT', '3000')}`;
  }

  const shutdown = async (code) => {
    try {
      const { closeStore } = await import('../lib/store.js');
      await closeStore();
    } catch {
      /* noop */
    }
    process.exit(code);
  };
  process.on('SIGINT', () => shutdown(130));
  process.on('SIGTERM', () => shutdown(143));

  (async () => {
    await initStore({ remote: process.env.APPROVAL_HTTP_URL });
    const agent = await agentGet(agentId);
    if (!agent) {
      console.error(`No agent "${agentId}"`);
      await shutdown(1);
      return;
    }
    console.log(`[worker ${agentId}] role=${agent.role} tools=${(agent.allowed_tools || []).join(',')}`);
    const outcome = await runAgentLoop(agent, dispatchTool);
    console.log(`[worker ${agentId}] finished ok=${outcome.ok}`);
    await shutdown(outcome.ok ? 0 : 1);
  })().catch(async (err) => {
    console.error(`[worker] fatal: ${err.message}`);
    try {
      await agentUpdate(process.argv[2], { status: 'failed', error: `Worker fatal: ${err.message}` });
    } catch {
      /* noop */
    }
    await shutdown(1);
  });
}
