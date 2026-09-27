// Computer Use loop orchestration (spec §6.4): screenshot → model →
// execute → screenshot → repeat, with gateAction() on every proposed action.
//
// Contract (see tests/computer-use.test.js):
//   runComputerUseTask({ task, environment }) ->
//     { status: 'complete', summary, steps } |
//     { status: 'error', message } |
//     { status: 'blocked', summary } |
//     { status: 'cancelled', summary }
// Test hooks: __setOverrides({ execDesktop, execBrowser, shotDesktop,
// shotBrowser, getPage }) replaces all real side effects; resetTaskLock()
// releases the single-task serialization lock between tests.
import { cfg } from '../lib/store.js';
import { logSecurityEvent } from '../security.js';
import { resolveLlmConfig } from '../lib/model-router.js';
import { getClient } from './gemini-client.js';
import { gateAction } from './safety.js';

const DEFAULT_MAX_STEPS = 20;
const HARD_MAX_STEPS = 50;

let overrides = {};
let taskRunning = false;

export function __setOverrides(next = {}) {
  overrides = { ...next };
}

export function resetTaskLock() {
  taskRunning = false;
}

function maxSteps() {
  const n = Math.floor(Number(cfg('COMPUTER_USE_MAX_STEPS', String(DEFAULT_MAX_STEPS))));
  if (!Number.isFinite(n) || n < 1) return DEFAULT_MAX_STEPS;
  return Math.min(n, HARD_MAX_STEPS);
}

function defaultEnvironment() {
  const e = String(cfg('COMPUTER_USE_ENVIRONMENT', 'desktop')).toLowerCase();
  return e === 'browser' ? 'browser' : 'desktop';
}

function normalizeOutcome(raw) {
  if (!raw || typeof raw !== 'object') return { ok: false, message: String(raw ?? '') };
  const ok = raw.ok ?? raw.success ?? false;
  const message = raw.message ?? raw.detail ?? '';
  return { ok: Boolean(ok), message: String(message) };
}

async function shotFor(env, page) {
  if (env === 'browser') {
    if (overrides.shotBrowser) return overrides.shotBrowser(page);
    const { captureBrowserScreenshot } = await import('./browser-executor.js');
    return { data: await captureBrowserScreenshot(page), mime_type: 'image/png' };
  }
  if (overrides.shotDesktop) return overrides.shotDesktop();
  const { captureDesktopScreenshot } = await import('./screenshot.js');
  return { data: await captureDesktopScreenshot(), mime_type: 'image/png' };
}

async function execFor(env, action, page, screenSize) {
  if (env === 'browser') {
    if (overrides.execBrowser) return normalizeOutcome(await overrides.execBrowser(action, page));
    const { executeBrowserAction } = await import('./browser-executor.js');
    return normalizeOutcome(await executeBrowserAction({ name: action.name, args: action.arguments }, page));
  }
  if (overrides.execDesktop) return normalizeOutcome(await overrides.execDesktop(action));
  const { executeDesktopAction } = await import('./desktop-executor.js');
  return normalizeOutcome(await executeDesktopAction({ name: action.name, args: action.arguments }, screenSize));
}

async function pageFor() {
  if (overrides.getPage) return { page: await overrides.getPage(), owned: false };
  const { launchBrowser } = await import('./browser-executor.js');
  const ctx = await launchBrowser();
  return {
    page: ctx.page,
    owned: true,
    close: async () => ctx.browser?.close?.().catch(() => {}),
  };
}

export async function runComputerUseTask({ task, environment } = {}) {
  const t = String(task || '').trim();
  if (!t) return { status: 'error', message: 'computer_use needs a task description' };
  if (cfg('COMPUTER_USE_ENABLED', 'true').toLowerCase() !== 'true') {
    return { status: 'error', message: 'Computer Use is disabled (COMPUTER_USE_ENABLED=false).' };
  }
  let geminiKey = '';
  try {
    geminiKey = resolveLlmConfig().geminiKey || '';
  } catch {
    geminiKey = cfg('GEMINI_API_KEY') || '';
  }
  if (!geminiKey) {
    return { status: 'error', message: 'Gemini API key is not configured — set GEMINI_API_KEY at /setup.' };
  }
  if (taskRunning) {
    return { status: 'error', message: 'A computer_use task is already running — wait for it to finish.' };
  }
  taskRunning = true;

  const env = environment === 'browser' ? 'browser' : environment === 'desktop' ? 'desktop' : defaultEnvironment();
  const cap = maxSteps();
  const steps = [];
  let pageHandle = null;

  try {
    await logSecurityEvent('TOOL_EXECUTION', { tool: 'computer_use', task: t, environment: env }).catch(() => {});
    const client = await getClient({ environment: env });

    if (env === 'browser') pageHandle = await pageFor();
    let screenSize = null;
    if (env === 'desktop' && !overrides.execDesktop) {
      try {
        const { getScreenSize } = await import('./desktop-executor.js');
        screenSize = await getScreenSize();
      } catch {
        screenSize = { width: 1920, height: 1080 };
      }
    }

    const first = await shotFor(env, pageHandle?.page);
    let interaction = await client.interactions.create({
      input: [
        { type: 'text', text: `Task: ${t}` },
        { type: 'image', data: first.data, mime_type: first.mime_type || 'image/png' },
      ],
      environment: env,
    });

    let continuations = 0;
    for (;;) {
      const calls = (interaction.steps || []).filter((s) => s?.type === 'function_call');
      if (calls.length === 0) {
        const text = (interaction.steps || [])
          .filter((s) => s?.type === 'model_output')
          .flatMap((s) => s.content || [])
          .filter((c) => c?.type === 'text')
          .map((c) => c.text)
          .join('\n')
          .trim();
        return { status: 'complete', summary: text || '(no further actions)', steps };
      }
      if (continuations >= cap) {
        return { status: 'error', message: `Stopped after ${cap} steps without completion`, steps };
      }
      continuations++;

      const functionResults = [];
      for (const fc of calls) {
        const action = { name: fc.name, arguments: fc.arguments || fc.args || {} };
        const gate = await gateAction({ action, task: t });
        if (!gate.ok) {
          if (gate.blocked) {
            return { status: 'blocked', summary: `Blocked: ${action.name} was vetoed by safety policy`, steps };
          }
          return { status: 'cancelled', summary: 'User declined confirmation', steps };
        }
        const outcome = await execFor(env, action, pageHandle?.page, screenSize);
        steps.push({ ok: outcome.ok, action: action.name, message: outcome.message });
        const shot = await shotFor(env, pageHandle?.page);
        functionResults.push({
          name: fc.name,
          call_id: fc.id,
          result: [
            { text: JSON.stringify({ success: outcome.ok, message: outcome.message }) },
            { data: shot.data, mime_type: shot.mime_type || 'image/png' },
          ],
        });
      }
      interaction = await client.interactions.create({
        previous_interaction_id: interaction.id,
        function_results: functionResults,
        environment: env,
      });
    }
  } catch (err) {
    await logSecurityEvent('TOOL_EXECUTION_ERROR', { tool: 'computer_use', error: err.message }).catch(() => {});
    return { status: 'error', message: err.message, steps };
  } finally {
    taskRunning = false;
    if (pageHandle?.owned) {
      await pageHandle.close().catch(() => {});
    }
  }
}
