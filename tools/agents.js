// Sub-agents (vision §18–26, Phase 4): fully dynamic specialists with
// deny-by-default tool permissions, budgets, lifecycle, and hybrid execution.
//
// Like workflows/plans, the dispatcher is injected (tools.js passes
// dispatchTool) to avoid a tools.js <-> agents.js import cycle.
// spawn_agent itself is confirmation-gated; every step a sub-agent takes
// goes through the real dispatcher, so per-tool gates still fire.
//
// Execution modes:
//   shared  — the agent-step loop runs in-process (fast, logical isolation).
//   spawned — a child `scripts/agent-worker.js` process runs the loop and
//             reports back through the store (crash-safe, for high-risk tools).
// isolation 'auto' (default) routes to spawned when the allowlist contains a
// high-risk tool, otherwise shared.
import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  agentSpawn,
  agentGet,
  agentList,
  agentUpdate,
  newAgentId,
  AGENT_STATUSES,
} from '../lib/store.js';
import { chatComplete } from '../lib/llm.js';
import { logSecurityEvent } from '../security.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const MAX_AGENTS = 10;
export const MAX_DEPTH = 3;
export const MAX_PARALLEL = 4;
export const DEFAULT_AGENT_STEPS = 15;
export const MAX_AGENT_STEPS = 50;
export const DEFAULT_AGENT_TIMEOUT_MS = 10 * 60 * 1000;
export const MAX_AGENT_TIMEOUT_MS = 30 * 60 * 1000;

// Tools that force spawned (process-isolated) execution under auto routing.
export const HIGH_RISK_TOOLS = new Set([
  'run_command',
  'terminal_execute',
  'terminal_start',
  'terminal_input',
  'computer_use',
  'run_workflow',
  'execute_plan',
  'file_organize',
  'file_rename',
  'file_convert',
  'send_email',
  'kill_process',
]);

export function resolveIsolation(allowedTools = [], requested = 'auto') {
  const r = String(requested || 'auto').toLowerCase();
  if (r === 'spawned' || r === 'shared') return r;
  const tools = Array.isArray(allowedTools) ? allowedTools : [];
  if (tools.some((t) => HIGH_RISK_TOOLS.has(String(t)))) return 'spawned';
  return 'shared';
}

export function checkSpawnLimits({ activeCount, depth }) {
  if (activeCount >= MAX_AGENTS) {
    return `Agent limit reached (max ${MAX_AGENTS} active). Cancel or wait for one to finish.`;
  }
  if (depth > MAX_DEPTH) {
    return `Agent depth limit reached (max depth ${MAX_DEPTH}). This spawn was rejected.`;
  }
  return null;
}

function agentSystemPrompt(agent) {
  const tools = (agent.allowed_tools || []).join(', ');
  return `You are a specialist sub-agent. Role: ${agent.role}.
Instructions: ${agent.instructions || '(none — use your tools to make progress)'}
You may call ONLY these tools (anything else is rejected by the runtime): ${tools || '(none)'}.
Parent messages (newest last) may contain guidance — follow them within your role.
Reply with JSON only, exactly one of:
{"tool": "<name>", "args": {...}, "note": "<one line on why>"} — take one action, or
{"done": true, "summary": "<result for the supervisor>"} — task complete.
Keep going until done. Never ask questions; if blocked, finish with done:false-style summary via {"done": true, "summary": "BLOCKED: <reason>"}.`;
}

function transcriptToPrompt(transcript) {
  return transcript
    .slice(-20)
    .map((t) => `${t.kind === 'action' ? 'Action' : t.kind === 'observation' ? 'Observation' : 'Note'}: ${t.text}`)
    .join('\n');
}

// The shared agent-step loop. Used in-process for shared mode and imported by
// scripts/agent-worker.js for spawned mode. dispatchFn executes tools;
// llmFn defaults to chatComplete (injectable for tests).
export async function runAgentLoop(agent, dispatchFn, opts = {}) {
  const { llmFn = chatComplete, onStep = null, signal = null } = opts;
  const budget = agent.budget || {};
  const maxSteps = Math.min(Math.max(Number(budget.max_steps) || DEFAULT_AGENT_STEPS, 1), MAX_AGENT_STEPS);
  const timeoutMs = Math.min(Math.max(Number(budget.timeoutMs) || DEFAULT_AGENT_TIMEOUT_MS, 1000), MAX_AGENT_TIMEOUT_MS);
  const startedAt = Date.now();
  const transcript = [];

  const refresh = await agentGet(agent.id).catch(() => null);
  const current = refresh || agent;
  if (current.status === 'cancelled') return { ok: false, cancelled: true };

  await agentUpdate(agent.id, { status: 'running' }).catch(() => {});
  await logSecurityEvent('TOOL_EXECUTION', { tool: 'spawn_agent', agent: agent.id, role: agent.role }).catch(() => {});

  for (let step = 1; step <= maxSteps; step++) {
    const expired = async () => {
      await agentUpdate(agent.id, { status: 'timed_out', error: `Budget exceeded (${timeoutMs}ms)` }).catch(() => {});
      await logSecurityEvent('TOOL_EXECUTION_ERROR', { tool: 'spawn_agent', agent: agent.id, error: 'timeout' }).catch(() => {});
      return { ok: false, timedOut: true };
    };
    if (signal?.aborted) {
      await agentUpdate(agent.id, { status: 'cancelled', error: 'Cancelled by supervisor' }).catch(() => {});
      return { ok: false, cancelled: true };
    }
    if (Date.now() - startedAt > timeoutMs) return expired();
    const live = await agentGet(agent.id).catch(() => null);
    if (live && live.status === 'cancelled') return { ok: false, cancelled: true };

    const inbox = Array.isArray(live?.messages) ? live.messages.slice(-10) : [];
    const user = `${transcriptToPrompt(transcript)}\n${
      inbox.length ? `Messages from supervisor:\n${inbox.map((m) => `- [${m.from || '?'}] ${m.text || ''}`).join('\n')}\n` : ''
    }Take the next single action (step ${step}/${maxSteps}).`;

    let decision;
    try {
      decision = await llmFn({ system: agentSystemPrompt({ ...agent, allowed_tools: live?.allowed_tools ?? agent.allowed_tools }), user, json: true });
    } catch (err) {
      await agentUpdate(agent.id, { status: 'failed', error: `LLM error: ${err.message}` }).catch(() => {});
      return { ok: false, error: `LLM error: ${err.message}` };
    }
    // A slow LLM (or a cancelled-while-waiting supervisor decision) must not
    // land after the budget died: re-check timeout before acting on it.
    if (Date.now() - startedAt > timeoutMs) return expired();
    // Same for cancellation that arrived mid-LLM-call: honor it instead of
    // completing on a stale decision.
    const postLlm = await agentGet(agent.id).catch(() => null);
    if (postLlm && postLlm.status === 'cancelled') return { ok: false, cancelled: true };

    if (decision && decision.done) {
      const summary = String(decision.summary || '(no summary)');
      await agentUpdate(agent.id, { status: 'completed', result: { summary, stepsTaken: step - 1 } }).catch(() => {});
      return { ok: true, summary };
    }

    const tool = decision?.tool;
    const args = (decision?.args && typeof decision.args === 'object' ? decision.args : {}) || {};
    const allowed = new Set((live?.allowed_tools ?? agent.allowed_tools ?? []).map(String));
    if (!tool || !allowed.has(String(tool))) {
      const msg = `Denied: tool "${tool || '(none)'}" is not in this agent's allowlist.`;
      transcript.push({ kind: 'observation', text: `${msg} Finish with {"done": true} if you cannot proceed.` });
      await logSecurityEvent('CONFIRMATION_DENIED', { tool: 'spawn_agent', agent: agent.id, deniedTool: tool }).catch(() => {});
      await agentUpdate(agent.id, { status: 'failed', error: msg }).catch(() => {});
      return { ok: false, error: msg };
    }

    let result;
    try {
      result = await dispatchFn(tool, args);
    } catch (err) {
      result = { error: err.message };
    }
    if (Date.now() - startedAt > timeoutMs) return expired();
    const line = `${tool} ${JSON.stringify(args).slice(0, 200)} -> ${JSON.stringify(result ?? null).slice(0, 500)}`;
    transcript.push({ kind: 'action', text: `${decision?.note ? decision.note + ' | ' : ''}${line}` });
    if (onStep) {
      try {
        await onStep({ step, tool, args, result });
      } catch {
        /* observer must not break the loop */
      }
    }
  }

  await agentUpdate(agent.id, { status: 'timed_out', error: `Step budget exceeded (${maxSteps} steps)` }).catch(() => {});
  return { ok: false, timedOut: true };
}

function defaultSpawnFn(agentId, workerPath, env) {
  const child = spawn(process.execPath, [workerPath, agentId], {
    cwd: path.join(__dirname, '..'),
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout?.on('data', () => {});
  child.stderr?.on('data', () => {});
  child.on('error', () => {});
  return child;
}

export async function spawnAgent(args, dispatchFn, opts = {}) {
  const {
    spawnFn = defaultSpawnFn,
    parentId = null,
    parentDepth = -1,
    waitMs = 0,
    llmFn = null,
  } = opts;
  const role = String(args.role || '').trim();
  const instructions = String(args.instructions || '').trim();
  const allowedTools = Array.isArray(args.allowed_tools) ? args.allowed_tools.map(String) : [];
  if (!role) throw new Error('role is required');
  if (!allowedTools.length) throw new Error('allowed_tools must be a non-empty array (deny-by-default)');
  const depth = parentDepth + 1;

  // Fail fast on unknown tools (deny-by-default means typos would only
  // surface mid-run otherwise). spawn_agent itself is excluded to prevent
  // unbounded recursive spawning through the front door — nesting is still
  // possible programmatically via parentDepth, subject to the depth cap.
  const { buildAllTools } = await import('../tools.js');
  const known = new Set(buildAllTools().map((t) => t.name));
  const unknown = allowedTools.filter((t) => !known.has(t) || t === 'spawn_agent');
  if (unknown.length) {
    throw new Error(`Unknown or forbidden tools in allowlist: ${unknown.join(', ')}. Known tools: ${[...known].filter((t) => t !== 'spawn_agent').join(', ')}`);
  }

  const active = await agentList(100, true).catch(() => []);
  const limitError = checkSpawnLimits({ activeCount: active.length, depth });
  if (limitError) throw new Error(limitError);

  const budget = {
    max_steps: Math.min(Math.max(Number(args.max_steps) || DEFAULT_AGENT_STEPS, 1), MAX_AGENT_STEPS),
    timeoutMs: Math.min(Math.max(Number(args.timeoutMs) || DEFAULT_AGENT_TIMEOUT_MS, 1000), MAX_AGENT_TIMEOUT_MS),
  };
  const id = newAgentId();
  await agentSpawn({
    id, parent_id: parentId, role, instructions, allowed_tools: allowedTools,
    status: 'spawned', budget, depth, messages: [],
  });
  await logSecurityEvent('TOOL_EXECUTION', { tool: 'spawn_agent', agent: id, role, depth }).catch(() => {});

  const mode = resolveIsolation(allowedTools, args.isolation);
  if (mode === 'shared') {
    const loopOpts = llmFn ? { llmFn } : {};
    const outcome = await runAgentLoop(
      { id, role, instructions, allowed_tools: allowedTools, budget },
      dispatchFn,
      loopOpts
    );
    return { success: outcome.ok, agentId: id, mode, ...outcome };
  }

  // spawned: child worker reports back through the store; optionally wait.
  const workerPath = path.join(__dirname, '..', 'scripts', 'agent-worker.js');
  try {
    spawnFn(id, workerPath, { ...process.env });
  } catch (err) {
    await agentUpdate(id, { status: 'failed', error: `Worker spawn failed: ${err.message}` }).catch(() => {});
    throw new Error(`Worker spawn failed: ${err.message}`);
  }
  await agentUpdate(id, { status: 'running' }).catch(() => {});
  if (waitMs > 0) {
    const deadline = Date.now() + Math.min(waitMs, budget.timeoutMs);
    for (;;) {
      const live = await agentGet(id).catch(() => null);
      if (!live || ['completed', 'failed', 'cancelled', 'timed_out'].includes(live.status)) {
        return { success: live?.status === 'completed', agentId: id, mode, status: live?.status, result: live?.result, error: live?.error };
      }
      if (Date.now() > deadline) {
        return { success: true, agentId: id, mode, status: 'running', message: 'Still running — check agent_status.' };
      }
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  return { success: true, agentId: id, mode, status: 'running', message: 'Spawned in isolation — check agent_status for results.' };
}

export async function listAgents(args = {}) {
  const agents = await agentList(args.limit, args.active_only === true);
  return { agents, count: agents.length };
}

export async function agentStatus(args) {
  const agent = await agentGet(String(args.agentId || '').trim());
  if (!agent) throw new Error(`No agent "${args.agentId}". List them with list_agents first.`);
  return { success: true, agent };
}

export async function cancelAgent(args) {
  const id = String(args.agentId || '').trim();
  const agent = await agentGet(id);
  if (!agent) throw new Error(`No agent "${id}".`);
  if (['completed', 'failed', 'cancelled', 'timed_out'].includes(agent.status)) {
    throw new Error(`Agent ${id} already ${agent.status}.`);
  }
  await agentUpdate(id, { status: 'cancelled' });
  return { success: true, message: `Agent ${id} cancelled.` };
}

export async function sendToAgent(args) {
  const id = String(args.agentId || '').trim();
  const text = String(args.text || '').trim();
  if (!text) throw new Error('text is required');
  const agent = await agentGet(id);
  if (!agent) throw new Error(`No agent "${id}".`);
  if (['completed', 'failed', 'cancelled', 'timed_out'].includes(agent.status)) {
    throw new Error(`Agent ${id} already ${agent.status} — messages would go nowhere.`);
  }
  const messages = [...(agent.messages || []), { from: args.from || 'supervisor', text, ts: new Date().toISOString() }].slice(-50);
  await agentUpdate(id, { messages });
  return { success: true, message: `Message queued for agent ${id}.` };
}
