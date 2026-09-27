// Planner + executor (vision §12–13): Intent → Plan → Execute → Verify →
// Recover → Report. plan_task decomposes a goal (LLM via lib/llm.js, or an
// explicit step list for programmatic use); execute_plan runs steps through
// the real dispatcher with per-step verification, checkpoints after every
// step, one retry for transient failures, and resume from checkpoint.
//
// Like workflows, the dispatcher is injected (tools.js passes dispatchTool)
// to avoid a tools.js <-> plan.js import cycle. execute_plan is
// confirmation-gated; individual dangerous steps gate again via dispatch.
import {
  planSave,
  planGet,
  planList,
  planUpdate,
  newPlanId,
  memSearch,
} from '../lib/store.js';
import { chatComplete } from '../lib/llm.js';

const MAX_STEPS = 30;
const TRANSIENT_PATTERNS = [/timed out/i, /timeout/i, /ECONNRESET/i, /ETIMEDOUT/i, /rate limit/i, /429/, /503/, /overloaded/i];

function isTransient(message) {
  return TRANSIENT_PATTERNS.some((re) => re.test(String(message || '')));
}

async function knownToolNames() {
  const { buildAllTools } = await import('../tools.js');
  return buildAllTools();
}

export function validatePlanSteps(steps, tools) {
  const known = new Set(tools.map((t) => t.name));
  const problems = [];
  if (!Array.isArray(steps) || steps.length === 0) return ['steps must be a non-empty array'];
  if (steps.length > MAX_STEPS) return [`steps exceed limit (${MAX_STEPS})`];
  steps.forEach((s, i) => {
    const n = i + 1;
    if (!s || typeof s !== 'object') return problems.push(`Step ${n}: must be an object`);
    if (!s.tool || !known.has(s.tool)) return problems.push(`Step ${n}: unknown tool "${s?.tool}"`);
    if (s.args !== undefined && (typeof s.args !== 'object' || s.args === null || Array.isArray(s.args))) {
      problems.push(`Step ${n}: args must be an object`);
    }
    if (s.verify !== undefined) {
      if (typeof s.verify !== 'object' || !s.verify || !known.has(s.verify.tool)) {
        problems.push(`Step ${n}: verify.tool must be a known tool`);
      }
      if (s.verify && s.verify.expect !== undefined && typeof s.verify.expect !== 'string') {
        problems.push(`Step ${n}: verify.expect must be a string`);
      }
    }
  });
  return problems;
}

function plannerSystemPrompt(tools) {
  const catalog = tools.map((t) => `- ${t.name}: ${(t.description || '').slice(0, 160)}`).join('\n');
  return `You decompose PC tasks into tool-call plans. Reply with JSON only:
{"steps": [{"tool": "<name>", "args": {...}, "verify": {"tool": "<read-only tool>", "args": {...}, "expect": "<substring expected in its JSON result>"} | null, "note": "<short why>"}]}
Rules: use ONLY these tools:\n${catalog}\nPrefer deterministic tools (filesystem, terminal, native apps) over computer_use vision steps. Add a verify step-check whenever the step changes state (file written, app opened, command run). Keep plans short (<=10 steps). Never invent tools. verify.expect is matched as a substring of the JSON-stringified verify result.`;
}

export async function planTask(args) {
  const goal = String(args.goal || '').trim();
  if (!goal) throw new Error('goal is required');
  if (goal.length > 2000) throw new Error('goal exceeds safety limit (2000 characters)');

  const tools = await knownToolNames();
  let steps = args.steps;
  if (steps !== undefined) {
    const problems = validatePlanSteps(steps, tools);
    if (problems.length) throw new Error(`Invalid steps: ${problems.join('; ')}`);
  } else {
    // Memory context: known facts/locations help ground the plan
    // ("Open Tafiti" -> project:tafiti path) without asking the user.
    const context = await memSearch(goal.slice(0, 120), { limit: 8 }).catch(() => []);
    const contextBlock = context.length
      ? `Known context (use it, do not re-ask):\n${context.map((m) => `- ${m.key} [${m.category}]: ${String(m.value).slice(0, 200)}`).join('\n')}\n`
      : '';
    const parsed = await chatComplete({
      system: plannerSystemPrompt(tools),
      user: `${contextBlock}Goal: ${goal}`,
      json: true,
    });
    const problems = validatePlanSteps(parsed?.steps, tools);
    if (problems.length) throw new Error(`Planner produced an invalid plan: ${problems.join('; ')}`);
    steps = parsed.steps.map((s) => ({ tool: s.tool, args: s.args || {}, ...(s.verify ? { verify: s.verify } : {}), ...(s.note ? { note: s.note } : {}) }));
  }

  const id = newPlanId();
  await planSave({ id, goal, steps, status: 'planned', current_step: 0, results: [], error: null });
  return { success: true, planId: id, goal, steps, message: `Planned ${steps.length} steps (id ${id}). Run with execute_plan.` };
}

export async function planStatus(args) {
  const plan = await planGet(String(args.planId || '').trim());
  if (!plan) throw new Error(`No plan "${args.planId}". List them with list_plans first.`);
  return { success: true, plan };
}

export async function listPlans(args = {}) {
  const plans = await planList(args.limit);
  return { plans, count: plans.length };
}

export async function cancelPlan(args) {
  const id = String(args.planId || '').trim();
  const plan = await planGet(id);
  if (!plan) throw new Error(`No plan "${id}".`);
  if (plan.status === 'completed') throw new Error(`Plan ${id} already completed.`);
  await planUpdate(id, { status: 'cancelled' });
  return { success: true, message: `Plan ${id} cancelled at step ${plan.current_step + 1}/${plan.steps.length}` };
}

async function runVerifyStep(verify, dispatchFn) {
  try {
    const result = await dispatchFn(verify.tool, verify.args || {});
    if (result?.error) return { ok: false, detail: result.error };
    const text = JSON.stringify(result ?? null);
    if (verify.expect && !text.includes(verify.expect)) {
      return { ok: false, detail: `verify expected substring not found: "${verify.expect}"` };
    }
    return { ok: true, detail: 'verified' };
  } catch (err) {
    return { ok: false, detail: `verify tool threw: ${err.message}` };
  }
}

// Execute (or resume) a plan. Checkpoint = current_step persisted after every
// step, so a crash/restart resumes via execute_plan again. One automatic retry
// for transient failures; anything else stops the plan for the user.
export async function executePlan(args, dispatchFn) {
  const id = String(args.planId || '').trim();
  if (!id) throw new Error('planId is required');
  if (typeof dispatchFn !== 'function') throw new Error('Plan executor unavailable in this context');

  let plan = await planGet(id);
  if (!plan) throw new Error(`No plan "${id}". Create one with plan_task first.`);
  if (plan.status === 'completed') return { success: true, message: `Plan ${id} already completed.`, plan };
  if (plan.status === 'cancelled') throw new Error(`Plan ${id} was cancelled. Re-plan with plan_task to try again.`);

  plan = await planUpdate(id, { status: 'running', error: null });
  const results = Array.isArray(plan.results) ? plan.results : [];

  for (let i = plan.current_step; i < plan.steps.length; i++) {
    const fresh = await planGet(id);
    if (fresh && fresh.status === 'cancelled') {
      return { success: false, message: `Plan ${id} cancelled at step ${i + 1}/${plan.steps.length}.`, plan: fresh };
    }
    const step = plan.steps[i];
    let attempt = 0;
    let stepResult = null;
    let stepError = null;
    // Attempt 1 + a single retry for transient failures (timeouts, 429/503).
    while (attempt < 2) {
      attempt++;
      try {
        stepResult = await dispatchFn(step.tool, step.args || {});
        if (stepResult?.error) throw new Error(stepResult.error);
        if (step.verify) {
          const check = await runVerifyStep(step.verify, dispatchFn);
          if (!check.ok) throw new Error(`verification failed: ${check.detail}`);
        }
        stepError = null;
        break;
      } catch (err) {
        stepError = err.message;
        if (attempt >= 2 || !isTransient(stepError)) break;
      }
    }
    const ok = stepError === null;
    results[i] = { step: i + 1, tool: step.tool, ok, ...(ok ? { result: stepResult } : { error: stepError }) };
    plan = await planUpdate(id, { current_step: i + 1, results, status: ok ? 'running' : 'failed', error: ok ? null : stepError });
    if (!ok) {
      const done = results.filter((r) => r?.ok).length;
      throw new Error(
        `Plan ${id} stopped at step ${i + 1}/${plan.steps.length} (${step.tool}): ${stepError}. ` +
        `${done} steps completed — fix the issue and resume with execute_plan, or cancel_plan.`
      );
    }
  }
  plan = await planUpdate(id, { status: 'completed', error: null });
  return { success: true, message: `Plan ${id} completed (${plan.steps.length}/${plan.steps.length} steps).`, plan };
}
