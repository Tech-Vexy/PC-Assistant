// Semantic + procedural memory tools (vision §15–17).
// remember/recall/forget operate on DuckDB `memories` (preferences,
// locations, projects, facts). save/run/list/delete_workflow operate on
// `workflows` — named tool sequences ("prepare my Tafiti environment").
//
// runWorkflow takes the dispatcher as an argument (wired in tools.js) so this
// module never imports tools.js back — no import cycle. Every step runs
// through the full dispatcher, so per-step approvals/validation still apply;
// the workflow run itself is confirmation-gated as a dangerous tool.
import {
  memGet,
  memSet,
  memDelete,
  memSearch,
  resolveLocation,
  wfSave,
  wfGet,
  wfList,
  wfDelete,
  wfRecordUse,
  MEMORY_CATEGORIES,
} from '../lib/store.js';

export async function rememberMemory(args) {
  const { key, value, category = 'fact' } = args;
  await memSet(key.trim(), String(value), category);
  return { success: true, message: `Remembered ${key.trim()} (${MEMORY_CATEGORIES.includes(category) ? category : 'fact'})` };
}

export async function recallMemory(args) {
  const { query = '', category = null, limit = 10 } = args;
  // Exact-key fast path first (covers "what is X" lookups).
  if (query && !category) {
    const exact = await memGet(query.trim());
    if (exact !== null) return { memories: [{ key: query.trim(), value: exact }], count: 1 };
  }
  const memories = await memSearch(String(query || ''), { category, limit });
  return { memories, count: memories.length };
}

export async function forgetMemory(args) {
  const { key } = args;
  const deleted = await memDelete(key.trim());
  return deleted
    ? { success: true, message: `Forgot ${key.trim()}` }
    : { success: false, message: `Nothing stored under "${key.trim()}"` };
}

export async function resolvePlace(args) {
  const { name } = args;
  const hit = await resolveLocation(name);
  if (!hit) throw new Error(`No saved location or project matches "${name}". Teach me with the remember tool first.`);
  return { success: true, ...hit };
}

async function knownToolNames() {
  const { buildAllTools } = await import('../tools.js');
  return new Set(buildAllTools().map((t) => t.name));
}

export async function saveWorkflow(args) {
  const { name, steps, description = '' } = args;
  const cleanName = String(name).trim();
  if (!Array.isArray(steps) || steps.length === 0 || steps.length > 50) {
    throw new Error('steps must be a non-empty array (max 50)');
  }
  const known = await knownToolNames();
  const clean = [];
  for (const [i, s] of steps.entries()) {
    if (!s || typeof s.tool !== 'string' || !known.has(s.tool)) {
      throw new Error(`Step ${i + 1}: unknown tool "${s?.tool}". Known tools: ${[...known].join(', ')}`);
    }
    if (s.args !== undefined && (typeof s.args !== 'object' || s.args === null)) {
      throw new Error(`Step ${i + 1}: args must be an object`);
    }
    clean.push({ tool: s.tool, args: s.args || {} });
  }
  await wfSave(cleanName, clean, String(description || ''));
  return { success: true, message: `Saved workflow "${cleanName}" (${clean.length} steps)` };
}

export async function listWorkflows() {
  const workflows = await wfList();
  return { workflows, count: workflows.length };
}

export async function deleteWorkflow(args) {
  const { name } = args;
  const deleted = await wfDelete(String(name).trim());
  return deleted
    ? { success: true, message: `Deleted workflow "${String(name).trim()}"` }
    : { success: false, message: `No workflow named "${String(name).trim()}"` };
}

// Execute a saved workflow step by step through the real dispatcher.
// Stops at the first failing step. Stats recorded for workflow learning.
export async function runWorkflow(args, dispatchFn) {
  const name = String(args.name || '').trim();
  if (!name) throw new Error('Workflow name is required');
  const wf = await wfGet(name);
  if (!wf) throw new Error(`No workflow named "${name}". List them with list_workflows first.`);
  if (typeof dispatchFn !== 'function') throw new Error('Workflow runner unavailable in this context');

  const stepResults = [];
  let failed = false;
  for (const [i, step] of wf.steps.entries()) {
    const result = await dispatchFn(step.tool, step.args || {});
    const ok = !result?.error && result?.success !== false;
    stepResults.push({ step: i + 1, tool: step.tool, ok, result });
    if (!ok) {
      failed = true;
      break;
    }
  }
  await wfRecordUse(name, !failed);
  const done = stepResults.filter((s) => s.ok).length;
  if (failed) {
    const bad = stepResults[stepResults.length - 1];
    throw new Error(`Workflow "${name}" stopped at step ${bad.step} (${bad.tool}): ${bad.result?.error || 'failed'}. ${done} of ${wf.steps.length} steps completed.`);
  }
  return {
    success: true,
    message: `Workflow "${name}" completed (${done}/${wf.steps.length} steps)`,
    steps: stepResults,
  };
}
