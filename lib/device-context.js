// Host device context: a compact inventory of OS facts + installed
// applications, injected into the voice agent's system prompt at publish time
// (setup-agent.js) so the model knows which apps actually exist on this
// machine before reaching for open_application / computer_use.
//
// Pure-ish by design: gathering takes a `deps` bag (injectable for tests);
// formatting takes data and returns text. No network calls.

import os from 'node:os';

// Ephemeral "apps" that never appear in uninstall registries but are launch
// targets for open_application (and map to its APP_ALIASES).
const COMMON_SYSTEM_APPS = [
  'Control Panel',
  'Settings',
  'Task Manager',
  'File Explorer',
  'Command Prompt',
  'PowerShell',
  'Windows Terminal',
  'Notepad',
  'Calculator',
  'Paint',
  'Snipping Tool',
];

const MAX_APPS_IN_CONTEXT = 60;
const MAX_PROMPT_CHARS = 4000;

/**
 * Gather host device context (OS facts + installed application names).
 * Uses the same discovery path as the list_installed_apps tool so the prompt
 * can never name apps that tool would not find.
 * @param {Object} [deps] - Injectable for tests.
 * @param {() => Promise<{applications: Array<{name: string}>}>} [deps.listInstalledApps]
 * @returns {Promise<{os: Object, apps: Array<{name: string}>, error?: string}>}
 */
export async function gatherDeviceContext(deps = {}) {
  const context = {
    os: {
      platform: process.platform,
      release: os.release(),
      arch: os.arch(),
      hostname: os.hostname(),
      username: os.userInfo().username,
    },
    apps: [],
  };

  try {
    const list = deps.listInstalledApps || (await import('../tools/desktop-suite.js')).listInstalledApps;
    const result = await list({ limit: 200 });
    context.apps = (result?.applications || [])
      .filter((a) => a && typeof a.name === 'string' && a.name.trim() !== '')
      .map((a) => ({ name: a.name.trim() }));
  } catch (err) {
    // Discovery is best-effort: publish must never fail because of it.
    context.error = err.message;
  }

  // PowerShell remoting (winrm/winrs) blocks native process execution — fall
  // back to the common Windows apps so the agent still has a launch vocabulary
  // (even when discovery errored; the error is surfaced as a note).
  if (context.apps.length === 0 && context.os.platform === 'win32') {
    context.apps = COMMON_SYSTEM_APPS.map((name) => ({ name }));
    context.fallback = 'common-system-apps';
  }

  return context;
}

/**
 * Render device context as a system-prompt block.
 * Keep it compact (the published prompt travels with every LLM call): app
 * names only, capped, deduplicated, alphabetized.
 * @param {Object} context - gatherDeviceContext() result.
 * @param {{maxApps?: number}} [opts]
 * @returns {string} '' when there is nothing useful to say.
 */
export function formatDeviceContext(context, opts = {}) {
  if (!context) return '';
  const maxApps = opts.maxApps ?? MAX_APPS_IN_CONTEXT;

  const names = [...new Set((context.apps || []).map((a) => a.name))]
    .sort((a, b) => a.localeCompare(b))
    .slice(0, maxApps);
  if (names.length === 0) return '';

  const osLine = `OS: ${context.os.platform} (${context.os.release}, ${context.os.arch}); user ${context.os.username} on ${context.os.hostname}.`;

  let appsBlock = `Installed applications (launch targets for open_application / computer_use):\n${names.map((n) => `- ${n}`).join('\n')}`;
  if ((context.apps || []).length > names.length) {
    appsBlock += `\n- … and ${(context.apps || []).length - names.length} more (call list_installed_apps to see the full list).`;
  }

  const notes = [];
  if (context.fallback === 'common-system-apps') {
    notes.push('App discovery was unavailable at publish time; this is the common built-in app list, not a full inventory.');
  }
  if (context.error) {
    notes.push(`App discovery failed at publish time (${context.error}); the full list may differ.`);
  }

  const text = [osLine, appsBlock, ...notes].join('\n\n');
  // Hard cap so a huge registry can never bloat the system prompt.
  return text.length > MAX_PROMPT_CHARS ? text.slice(0, MAX_PROMPT_CHARS - 1) + '…' : text;
}
