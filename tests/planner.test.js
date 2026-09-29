// Phase 3 planner: plan/execute/verify/recover + checkpoints through the
// real dispatcher. Explicit steps everywhere (no LLM network in tests).
// Isolated DuckDB store.
process.env.AUTO_APPROVE = 'true';
process.env.MCP_ENABLED = 'false';

import os from 'node:os';
import path from 'node:path';
process.env.STORE_PATH = path.join(os.tmpdir(), `test-planner-store-${process.pid}.db`);
// Keep the real .env out of the first-run seed (see computer-use.test.js).
process.env.DOTENV_PATH = path.join(os.tmpdir(), `test-planner-env-${process.pid}.env`);

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { requiresConfirmation } from '../security.js';

const SYS_STATUS = { tool: 'system_status', args: {} };

describe('planner tools', () => {
  before(async () => {
    const { initStore } = await import('../lib/store.js');
    await initStore();
  });

  after(async () => {
    const { closeStore } = await import('../lib/store.js');
    await closeStore();
  });

  it('plan_task with explicit steps creates a checkpointed plan', async () => {
    const { dispatchTool } = await import('../tools.js');
    const made = await dispatchTool('plan_task', {
      goal: 'check system health twice',
      steps: [SYS_STATUS, { tool: 'recall', args: { query: 'zzz-no-match' } }],
    });
    assert.equal(made.success, true);
    assert.match(made.planId, /^plan-[a-z0-9]+$/i);
    assert.equal(made.steps.length, 2);

    const status = await dispatchTool('plan_status', { planId: made.planId });
    assert.equal(status.plan.status, 'planned');
    assert.equal(status.plan.current_step, 0);
  });

  it('plan_task rejects unknown tools and bad shapes', async () => {
    const { dispatchTool } = await import('../tools.js');
    const badTool = await dispatchTool('plan_task', {
      goal: 'x',
      steps: [{ tool: 'nope_not_a_tool', args: {} }],
    });
    assert.match(badTool.error, /unknown tool/i);
    const empty = await dispatchTool('plan_task', { goal: 'x', steps: [] });
    assert.match(empty.error, /non-empty array/i);
    const noGoal = await dispatchTool('plan_task', { goal: '  ' });
    assert.match(noGoal.error, /goal must be a non-empty string/i);
  });

  it('plan_task without steps needs an LLM (errors cleanly with no key)', async () => {
    const saved = {};
    for (const k of ['LLM_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'LLM_BASE_URL', 'OPENAI_BASE_URL']) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
    try {
      const { dispatchTool } = await import('../tools.js');
      const r = await dispatchTool('plan_task', { goal: 'do something clever' });
      assert.match(r.error, /No LLM configured/i);
    } finally {
      for (const k of Object.keys(saved)) {
        if (saved[k] === undefined) delete process.env[k];
        else process.env[k] = saved[k];
      }
    }
  });

  it('execute_plan runs steps with verification and completes', async () => {
    const { dispatchTool } = await import('../tools.js');
    const made = await dispatchTool('plan_task', {
      goal: 'verify system status shape',
      steps: [{ ...SYS_STATUS, verify: { tool: 'system_status', args: {}, expect: '"cpu"' } }],
    });
    const ran = await dispatchTool('execute_plan', { planId: made.planId });
    assert.equal(ran.success, true);
    assert.match(ran.message, /completed \(1\/1 steps\)/);
    const status = await dispatchTool('plan_status', { planId: made.planId });
    assert.equal(status.plan.status, 'completed');
    assert.equal(status.plan.results[0].ok, true);

    const again = await dispatchTool('execute_plan', { planId: made.planId });
    assert.match(again.message, /already completed/i);
  });

  it('failed verification stops the plan with a resume checkpoint', async () => {
    const { dispatchTool } = await import('../tools.js');
    const made = await dispatchTool('plan_task', {
      goal: 'plan with bad verify',
      steps: [
        SYS_STATUS,
        { ...SYS_STATUS, verify: { tool: 'system_status', args: {}, expect: 'no-such-substring-xyz' } },
      ],
    });
    const ran = await dispatchTool('execute_plan', { planId: made.planId });
    assert.match(ran.error, /stopped at step 2\/2 \(system_status\)/);
    assert.match(ran.error, /resume with execute_plan/i);
    const status = await dispatchTool('plan_status', { planId: made.planId });
    assert.equal(status.plan.status, 'failed');
    assert.equal(status.plan.current_step, 2);
    assert.equal(status.plan.results[0].ok, true);
    assert.equal(status.plan.results[1].ok, false);
  });

  it('cancel_plan stops execution; cancelled plans refuse to run', async () => {
    const { dispatchTool } = await import('../tools.js');
    const made = await dispatchTool('plan_task', { goal: 'to cancel', steps: [SYS_STATUS] });
    const cancelled = await dispatchTool('cancel_plan', { planId: made.planId });
    assert.equal(cancelled.success, true);
    const ran = await dispatchTool('execute_plan', { planId: made.planId });
    assert.match(ran.error, /was cancelled/i);
    const missing = await dispatchTool('cancel_plan', { planId: 'plan-doesnotexist123' });
    assert.match(missing.error, /No plan/i);
  });

  it('list_plans shows recent plans with progress', async () => {
    const { dispatchTool } = await import('../tools.js');
    const made = await dispatchTool('plan_task', { goal: 'list me', steps: [SYS_STATUS] });
    const listed = await dispatchTool('list_plans', {});
    const found = listed.plans.find((p) => p.id === made.planId);
    assert.ok(found, 'new plan listed');
    assert.equal(found.status, 'planned');
  });

  it('validates plan arguments and gates execution', async () => {
    const { dispatchTool } = await import('../tools.js');
    assert.equal(requiresConfirmation('execute_plan'), true);
    assert.equal(requiresConfirmation('plan_task'), false);
    assert.equal(requiresConfirmation('plan_status'), false);
    assert.equal(requiresConfirmation('list_plans'), false);
    assert.equal(requiresConfirmation('cancel_plan'), false);
    const bad = await dispatchTool('execute_plan', { planId: 'not-a-plan' });
    assert.match(bad.error, /planId must look like/i);
    const missing = await dispatchTool('plan_status', { planId: 'plan-abcdef123456' });
    assert.match(missing.error, /No plan/i);
  });
});
