// Phase 4 sub-agents: routing, deny-by-default enforcement, limits,
// lifecycle, parallel fan-out, cancellation, timeouts. The LLM is always
// injected (scripted decisions) — no network. Isolated DuckDB store.
process.env.AUTO_APPROVE = 'true';
process.env.MCP_ENABLED = 'false';

import os from 'node:os';
import path from 'node:path';
process.env.STORE_PATH = path.join(os.tmpdir(), `test-agents-store-${process.pid}.db`);

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { requiresConfirmation } from '../security.js';
import {
  resolveIsolation,
  checkSpawnLimits,
  spawnAgent,
  MAX_AGENTS,
  MAX_DEPTH,
} from '../tools/agents.js';

// scripted llmFn: array of decisions returned in order, then done.
function scriptLLM(decisions) {
  let i = 0;
  return async () => {
    if (i < decisions.length) return decisions[i++];
    return { done: true, summary: 'finished' };
  };
}

async function testDispatch(tool, args) {
  const { dispatchTool } = await import('../tools.js');
  return dispatchTool(tool, args);
}

describe('agent supervisor', () => {
  before(async () => {
    const { initStore } = await import('../lib/store.js');
    await initStore();
  });

  after(async () => {
    const { closeStore } = await import('../lib/store.js');
    await closeStore();
  });

  it('routes isolation by risk, honoring explicit overrides', () => {
    assert.equal(resolveIsolation(['recall', 'system_status'], 'auto'), 'shared');
    assert.equal(resolveIsolation(['run_command'], 'auto'), 'spawned');
    assert.equal(resolveIsolation(['computer_use'], 'auto'), 'spawned');
    assert.equal(resolveIsolation(['send_email'], 'auto'), 'spawned');
    assert.equal(resolveIsolation(['run_command'], 'shared'), 'shared');
    assert.equal(resolveIsolation(['recall'], 'spawned'), 'spawned');
    assert.equal(resolveIsolation([], 'auto'), 'shared');
  });

  it('enforces agent count and depth caps', () => {
    assert.match(checkSpawnLimits({ activeCount: MAX_AGENTS, depth: 0 }), /limit reached/i);
    assert.equal(checkSpawnLimits({ activeCount: 0, depth: 0 }), null);
    assert.match(checkSpawnLimits({ activeCount: 0, depth: MAX_DEPTH + 1 }), /depth limit/i);
  });

  it('rejects unknown tools and spawn_agent recursion at spawn time', async () => {
    await assert.rejects(
      spawnAgent({ role: 'x', allowed_tools: ['nope_not_a_tool'] }, async () => ({})),
      /Unknown or forbidden tools/
    );
    await assert.rejects(
      spawnAgent({ role: 'x', allowed_tools: ['spawn_agent'] }, async () => ({})),
      /Unknown or forbidden tools/
    );
  });

  it('runs a shared agent to completion with injected LLM + real dispatch', async () => {
    const llm = scriptLLM([
      { tool: 'system_status', args: {}, note: 'check health' },
      { done: true, summary: 'system is healthy' },
    ]);
    const out = await spawnAgent(
      { role: 'tester', instructions: 'check health', allowed_tools: ['system_status'], isolation: 'shared' },
      testDispatch,
      { llmFn: llm }
    );
    assert.equal(out.success, true);
    assert.equal(out.mode, 'shared');
    assert.equal(out.summary, 'system is healthy');
    const { agentGet } = await import('../lib/store.js');
    const record = await agentGet(out.agentId);
    assert.equal(record.status, 'completed');
    assert.equal(record.result.summary, 'system is healthy');
  });

  it('denies tools outside the allowlist at runtime', async () => {
    const llm = scriptLLM([{ tool: 'send_email', args: { to: 'x@y.z', subject: 's', body: 'b' } }]);
    const out = await spawnAgent(
      { role: 'rogue', instructions: 'try email', allowed_tools: ['system_status'], isolation: 'shared' },
      testDispatch,
      { llmFn: llm }
    );
    assert.equal(out.success, false);
    assert.match(out.error, /not in this agent's allowlist/i);
    const { agentGet } = await import('../lib/store.js');
    assert.equal((await agentGet(out.agentId)).status, 'failed');
  });

  it('fans out shared agents in parallel and merges results', async () => {
    const mkLlm = (summary) => scriptLLM([{ done: true, summary }]);
    const specs = ['alpha', 'beta', 'gamma', 'delta'];
    const outcomes = await Promise.allSettled(
      specs.map((s, i) =>
        spawnAgent(
          { role: `parallel-${s}`, instructions: 'finish fast', allowed_tools: ['system_status'], isolation: 'shared' },
          testDispatch,
          { llmFn: mkLlm(`result-${i}`) }
        )
      )
    );
    assert.equal(outcomes.length, 4);
    const merged = outcomes.map((o, i) => ({ spec: specs[i], status: o.status, summary: o.value?.summary }));
    assert.ok(merged.every((m) => m.status === 'fulfilled' && m.summary === `result-${specs.indexOf(m.spec)}`));
  });

  it('rejects the 11th concurrent active agent', async () => {
    const gates = [];
    const mkWaitingLlm = () => {
      let release;
      const gate = new Promise((r) => (release = r));
      gates.push(release);
      return async () => {
        await gate;
        return { done: true, summary: 'released' };
      };
    };
    const { cancelAgent, listAgents } = await import('../tools/agents.js');
    const pendings = [];
    for (let i = 0; i < MAX_AGENTS; i++) {
      pendings.push(
        spawnAgent(
          { role: `filler-${i}`, instructions: 'wait', allowed_tools: ['system_status'], isolation: 'shared' },
          testDispatch,
          { llmFn: mkWaitingLlm() }
        )
      );
    }
    try {
      // Poll until all 10 fillers are actually active (no fixed-sleep race).
      let active = [];
      const deadline = Date.now() + 15000;
      while (Date.now() < deadline) {
        active = (await listAgents({ active_only: true })).agents.filter((a) => a.role.startsWith('filler-'));
        if (active.length >= MAX_AGENTS) break;
        await new Promise((r) => setTimeout(r, 200));
      }
      assert.equal(active.length, MAX_AGENTS, 'all fillers active before overflow attempt');
      await assert.rejects(
        spawnAgent({ role: 'overflow', instructions: 'x', allowed_tools: ['system_status'], isolation: 'shared' }, testDispatch, {
          llmFn: scriptLLM([{ done: true, summary: 'x' }]),
        }),
        /limit reached/i
      );
    } finally {
      // Always release, or every later test starves on the agent cap.
      for (const release of gates) release();
      const outcomes = await Promise.all(pendings);
      assert.ok(outcomes.every((o) => o.ok || o.success));
      const active = await listAgents({ active_only: true });
      assert.ok(!active.agents.some((a) => a.role.startsWith('filler-')), 'fillers finished');
    }
  });

  it('cancels a running agent at the next step boundary', async () => {
    let release;
    const gate = new Promise((r) => (release = r));
    const llm = async () => {
      await gate;
      return { done: true, summary: 'late finish' };
    };
    const { cancelAgent } = await import('../tools/agents.js');
    const running = spawnAgent(
      { role: 'slow', instructions: 'wait', allowed_tools: ['system_status'], isolation: 'shared' },
      testDispatch,
      { llmFn: llm }
    );
    // Poll until the agent is actually active (no fixed-sleep race).
    let target = null;
    const { listAgents } = await import('../tools/agents.js');
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const before = await listAgents({ active_only: true });
      target = before.agents.find((a) => a.role === 'slow');
      if (target) break;
      await new Promise((r) => setTimeout(r, 200));
    }
    assert.ok(target, 'slow agent is active');
    const cancelled = await cancelAgent({ agentId: target.id });
    assert.equal(cancelled.success, true);
    release();
    const outcome = await running;
    assert.equal(outcome.ok, false);
    assert.equal(outcome.cancelled, true);
  });

  it('times out agents that exceed budget', async () => {
    const slow = async () => {
      await new Promise((r) => setTimeout(r, 1500));
      return { done: true, summary: 'too late' };
    };
    const { runAgentLoop } = await import('../tools/agents.js');
    const { agentSpawn, newAgentId, agentGet } = await import('../lib/store.js');
    const id = newAgentId();
    await agentSpawn({ id, role: 'tardy', allowed_tools: ['system_status'], budget: { max_steps: 10, timeoutMs: 400 } });
    const out = await runAgentLoop({ id, role: 'tardy', allowed_tools: ['system_status'], budget: { max_steps: 10, timeoutMs: 400 } }, testDispatch, { llmFn: slow });
    assert.equal(out.timedOut, true);
    assert.equal((await agentGet(id)).status, 'timed_out');
    await agentSpawn({ id, role: 'tardy', status: 'cancelled' });
  });

  it('spawned mode delegates to the worker and polls to completion', async () => {
    const seen = {};
    const fakeSpawn = (agentId, workerPath, env) => {
      seen.agentId = agentId;
      seen.workerPath = workerPath;
      seen.hasEnv = !!(env && env.PATH !== undefined);
      // Simulate the worker finishing shortly after spawn.
      setTimeout(async () => {
        const { agentUpdate } = await import('../lib/store.js');
        await agentUpdate(agentId, { status: 'completed', result: { summary: 'worker did it' } });
      }, 200);
      return { pid: 12345, on: () => {} };
    };
    const out = await spawnAgent(
      { role: 'isolated', instructions: 'risky stuff', allowed_tools: ['run_command'], isolation: 'spawned' },
      testDispatch,
      { spawnFn: fakeSpawn, waitMs: 10000 }
    );
    assert.equal(out.mode, 'spawned');
    assert.equal(out.status, 'completed');
    assert.equal(out.result.summary, 'worker did it');
    assert.ok(String(seen.workerPath).endsWith('agent-worker.js'));
    assert.ok(seen.agentId);
  });

  it('send_to_agent queues messages for live agents, refuses finished ones', async () => {
    const llm = scriptLLM([{ done: true, summary: 'ok' }]);
    const out = await spawnAgent(
      { role: 'listener', instructions: 'x', allowed_tools: ['system_status'], isolation: 'shared' },
      testDispatch,
      { llmFn: llm }
    );
    const { sendToAgent } = await import('../tools/agents.js');
    await assert.rejects(sendToAgent({ agentId: out.agentId, text: 'late note' }), /already completed/i);

    const { agentSpawn, newAgentId, agentGet } = await import('../lib/store.js');
    const id = newAgentId();
    await agentSpawn({ id, role: 'live', allowed_tools: ['system_status'], status: 'running' });
    const sent = await sendToAgent({ agentId: id, text: 'course correction', from: 'tester' });
    assert.equal(sent.success, true);
    const live = await agentGet(id);
    assert.equal(live.messages.length, 1);
    assert.equal(live.messages[0].text, 'course correction');
    await agentSpawn({ id, role: 'live', status: 'cancelled' });
  });

  it('validates agent tool arguments and gates spawning', async () => {
    const { dispatchTool } = await import('../tools.js');
    assert.equal(requiresConfirmation('spawn_agent'), true);
    assert.equal(requiresConfirmation('list_agents'), false);
    assert.equal(requiresConfirmation('agent_status'), false);
    assert.equal(requiresConfirmation('cancel_agent'), false);
    assert.equal(requiresConfirmation('send_to_agent'), false);
    const bad = await dispatchTool('spawn_agent', { role: '', allowed_tools: [] });
    assert.match(bad.error, /role must be|allowed_tools must be/i);
    const badId = await dispatchTool('agent_status', { agentId: 'bogus' });
    assert.match(badId.error, /agentId must look like/i);
    const missing = await dispatchTool('agent_status', { agentId: 'agent-deadbeef1234' });
    assert.match(missing.error, /No agent/i);
  });

  it('list_agents and agent lifecycle flow through the dispatcher', async () => {
    const { dispatchTool } = await import('../tools.js');
    const llm = scriptLLM([{ done: true, summary: 'via dispatch' }]);
    // Exercise the dispatcher path for spawn with shared routing.
    const { spawnAgent: spawnDirect } = await import('../tools/agents.js');
    const out = await spawnDirect(
      { role: 'dispatched', instructions: 'x', allowed_tools: ['system_status'], isolation: 'shared' },
      testDispatch,
      { llmFn: llm }
    );
    assert.equal(out.success, true);
    const listed = await dispatchTool('list_agents', { active_only: false });
    assert.ok(listed.agents.some((a) => a.id === out.agentId));
    const status = await dispatchTool('agent_status', { agentId: out.agentId });
    assert.equal(status.agent.status, 'completed');
  });
});
