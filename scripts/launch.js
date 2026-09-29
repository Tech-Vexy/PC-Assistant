// One-command launcher: `npm run up` (add `--wakeword` to idle on wake word,
// `--no-browser` to never auto-open the setup page).
//
// Does everything needed to go from zero to talking:
//   1. Creates .env from the template if missing
//   2. Warns about missing ffmpeg/ffplay (voice needs them)
//   3. Signs the tool manifest (integrity baseline)
//   4. Starts the auth server and waits for /health
//   5. If keys are missing, opens the browser setup UI and waits for you
//   6. Auto-publishes the AssemblyAI agent when keys exist but AGENT_ID is missing
//   7. Starts the voice agent (or the wake-word supervisor)
// Ctrl+C stops everything.

import { spawn, execFile } from 'child_process';
import { promisify } from 'util';
import fs from 'fs/promises';
import path from 'path';
import readline from 'readline';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { validateConfiguration } from '../lib/config-validator.js';
import { colors } from '../lib/pretty.js';

const execFileAsync = promisify(execFile);
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.join(__dirname, '..');
const ENV_PATH = path.join(ROOT, '.env');

// ---------- tiny testable helpers ----------

// Placeholder/template values count as missing (truthy but unusable).
export function hasRealValue(v) {
  return typeof v === 'string' && v.trim() !== '' && !v.includes('your_');
}

export function isLocalBaseUrl(v) {
  return /localhost|127\.0\.0\.1|0\.0\.0\.0/i.test(v || '');
}

// Insert or replace one KEY=value line, preserving the rest of the file.
export async function setEnvKey(filePath, key, value) {
  let text = '';
  try {
    text = await fs.readFile(filePath, 'utf8');
  } catch {
    text = '';
  }
  const line = `${key}=${value}`;
  const re = new RegExp(`^${key}=.*$`, 'm');
  text = re.test(text) ? text.replace(re, line) : `${text.replace(/\s+$/, '')}\n${line}\n`;
  await fs.writeFile(filePath, text, { mode: 0o600 });
}

export function configStatus(env) {
  const missing = [];
  if (!hasRealValue(env.ASSEMBLYAI_API_KEY)) missing.push('ASSEMBLYAI_API_KEY');
  const hasLlm =
    hasRealValue(env.LLM_API_KEY) ||
    hasRealValue(env.OPENAI_API_KEY) ||
    (isLocalBaseUrl(env.LLM_BASE_URL) && hasRealValue(env.LLM_BASE_URL));
  if (!hasLlm) missing.push('LLM_API_KEY (OpenRouter)');
  const warnings = [];
  return { missing, warnings, hasLlm, hasAgent: hasRealValue(env.AGENT_ID) };
}

// ---------- launcher internals ----------

const children = [];
let shuttingDown = false;

function shutdown(code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log('\nStopping…');
  for (const c of children) {
    try {
      c.kill('SIGTERM');
    } catch {
      /* noop */
    }
  }
  setTimeout(() => process.exit(code), 800);
}

function spawnChild(name, script) {
  const c = spawn('node', [path.join(ROOT, script)], { cwd: ROOT, stdio: 'inherit', env: process.env });
  children.push(c);
  c.on('exit', (code) => {
    if (!shuttingDown) {
      console.error(`\n❌ ${name} exited (code ${code}) — stopping everything.`);
      shutdown(1);
    }
  });
  return c;
}

async function waitForHealth(url, timeoutMs = 20000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const r = await fetch(url);
      if (r.ok) return true;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}

async function openBrowser(url) {
  try {
    if (process.platform === 'win32') {
      await execFileAsync('cmd', ['/c', 'start', '', url], { timeout: 10000 });
    } else if (process.platform === 'darwin') {
      await execFileAsync('open', [url], { timeout: 10000 });
    } else {
      await execFileAsync('xdg-open', [url], { timeout: 10000 });
    }
    return true;
  } catch {
    return false;
  }
}

function waitForEnter(prompt) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => rl.question(prompt, (ans) => {
    rl.close();
    resolve(ans);
  }));
}

function reloadEnv() {
  dotenv.config({ path: ENV_PATH, override: true });
}

// Runtime config snapshot: DB values overlaid with real process env
// (env wins, same precedence as the app's cfg()). Opens the store briefly
// and closes it again so the server we spawn next gets the writer lock.
// Falls back to the .env bootstrap file when the DB can't be opened
// (e.g. another server instance already holds it).
async function readRuntimeEnv() {
  const { initStore, allConfig, closeStore, storeMode } = await import('../lib/store.js');
  await initStore();
  let snapshot = {};
  if (storeMode() === 'local') {
    snapshot = await allConfig();
    await closeStore();
  }
  if (Object.keys(snapshot).length === 0) {
    try {
      const text = await fs.readFile(ENV_PATH, 'utf8');
      for (const line of text.split(/\r?\n/)) {
        const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
        if (m && m[2].trim() !== '') snapshot[m[1]] = m[2].trim();
      }
    } catch {
      /* no bootstrap file */
    }
  }
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) snapshot[k] = v;
  }
  return snapshot;
}

async function autoPublish(port) {
  console.log('Keys found but no AGENT_ID — publishing the AssemblyAI agent…');
  try {
    const { stdout } = await execFileAsync('node', [path.join(ROOT, 'setup-agent.js')], {
      cwd: ROOT,
      timeout: 120000,
    });
    const m = String(stdout).match(/AGENT_ID=(\S+)/);
    // Reject placeholder values a broken publish script might print — storing
    // "undefined" as the agent id would poison every later connect.
    if (m && !/^(undefined|null)$/i.test(m[1])) {
      await setEnvKey(ENV_PATH, 'AGENT_ID', m[1]);
      process.env.AGENT_ID = m[1];
      // The server owns the store now — save through it (best-effort).
      try {
        await fetch(`http://localhost:${port}/api/store/config`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' },
          body: JSON.stringify({ key: 'AGENT_ID', value: m[1] }),
        });
      } catch {
        /* file mirror suffices; next boot seeds the store */
      }
      console.log(`✅ Agent published and AGENT_ID saved (${m[1]})`);
      return true;
    }
    console.warn('⚠️  Publish ran but no AGENT_ID was printed — run `npm run publish` manually.');
    return false;
  } catch (err) {
    console.warn(`⚠️  Auto-publish failed (${(err.stderr || err.message || '').toString().slice(0, 200)}) — run \`npm run publish\` manually.`);
    return false;
  }
}

async function main() {
  const useWakeword = process.argv.includes('--wakeword');
  const skipBrowser = process.argv.includes('--no-browser') || !process.stdout.isTTY;
  console.log('🚀 PC Assistant — one-command startup\n');

  // 1) .env bootstrap
  try {
    await fs.access(ENV_PATH);
  } catch {
    await fs.copyFile(path.join(ROOT, '.env.example'), ENV_PATH);
    console.log('Created .env from the template.');
  }
  reloadEnv();

  // 2) configuration validation (malformed values only — missing keys are
  // handled later by the guided /setup loop, which can save them to the store)
  try {
    const { initStore, allConfig, closeStore, storeMode } = await import('../lib/store.js');
    await initStore();
    let storedConfig = {};
    if (storeMode() === 'local') {
      storedConfig = await allConfig();
      await closeStore();
    } else {
      console.warn('⚠️  Store busy — validating .env values only.');
    }
    const mergedConfig = { ...storedConfig, ...process.env };
    const configValidation = validateConfiguration(mergedConfig);
    for (const w of new Set(configValidation.warnings)) console.log(`⚠️  ${w}`);
    // One compact line instead of a wall of per-key default notices.
    const defaultedKeys = configValidation.defaultsUsed.map((d) => d.key);
    if (defaultedKeys.length > 0) {
      console.log(colors.gray(`ℹ️  ${defaultedKeys.length} optional keys using defaults (${defaultedKeys.join(', ')})`));
    }
    if (configValidation.invalid.length > 0) {
      console.error('❌ Configuration values are invalid:');
      for (const error of configValidation.invalid) {
        console.error(`   - ${error}`);
      }
      console.error('\nPlease fix these at http://localhost:3000/setup or in your .env file.');
      shutdown(1);
      return;
    }
  } catch (err) {
    // Validation is a convenience gate, not a hard dependency: if the store
    // cannot be opened at all, let the normal startup flow report it.
    console.warn(`⚠️  Skipped configuration validation (${err.message}).`);
  }

  // 3) ffmpeg preflight (warn only — the app still boots for setup)
  for (const bin of ['ffmpeg', 'ffplay']) {
    try {
      await execFileAsync(bin, ['-version'], { timeout: 10000 });
    } catch {
      console.warn(`⚠️  ${bin} not on PATH — voice capture/playback needs it (see README). Continuing for setup.`);
    }
  }

  // 4) tool manifest baseline
  try {
    const { buildAllTools } = await import('../tools.js');
    const { signToolManifest } = await import('../lib/security-extras.js');
    const m = await signToolManifest(buildAllTools());
    console.log(`Tool manifest signed (${m.sha256.slice(0, 12)}…)`);
  } catch (err) {
    console.warn(`⚠️  Could not sign tool manifest: ${err.message}`);
  }

  // 5) auth server (PORT resolved store-first so /setup changes apply)
  let runtimeEnv = await readRuntimeEnv();
  const PORT = Number(runtimeEnv.PORT || 3000) || 3000;
  spawnChild('auth server', 'server.js');
  const healthy = await waitForHealth(`http://localhost:${PORT}/health`);
  if (!healthy) {
    console.error(`❌ Server did not become healthy at http://localhost:${PORT}/health`);
    shutdown(1);
    return;
  }
  console.log(`Auth server up at http://localhost:${PORT}`);

  // 6) guided configuration: loop until keys exist (browser UI does the work)
  let status = configStatus(runtimeEnv);
  let browserOpened = false;
  while (status.missing.length > 0) {
    const setupUrl = `http://localhost:${PORT}/setup`;
    console.log(`\n🔧 First-time setup needed: ${status.missing.join(', ')}`);
    if (!skipBrowser && !browserOpened) {
      if (await openBrowser(setupUrl)) {
        console.log(`Opened ${setupUrl} — fill in your keys there.`);
        browserOpened = true;
      } else {
        console.log(`Open ${setupUrl} in your browser and fill in your keys.`);
      }
    } else {
      console.log(`Fill in your keys at ${setupUrl}.`);
    }
    if (!process.stdin.isTTY) {
      console.log('Non-interactive shell — complete setup in the browser, then re-run `npm run up`.');
      shutdown(0);
      return;
    }
    await waitForEnter('Press Enter once saved (Ctrl+C to quit)… ');
    reloadEnv();
    runtimeEnv = await readRuntimeEnv();
    status = configStatus(runtimeEnv);
  }

  // Google OAuth still needs its one-time browser click (can't be automated).
  // The /setup form sends users straight to /auth once credentials are saved.
  console.log('\n✅ API keys configured.');
  for (const w of status.warnings || []) console.log(`⚠️  ${w}`);
  console.log(`If Google isn't connected yet: http://localhost:${PORT}/auth`);

  // 7) publish the stored agent if needed
  if (!status.hasAgent) {
    await autoPublish(PORT);
    runtimeEnv = await readRuntimeEnv();
    status = configStatus(runtimeEnv);
  }
  if (!status.hasAgent) {
    console.warn('⚠️  Continuing without AGENT_ID — the voice agent needs a stored agent. Run `npm run publish` in another terminal.');
  }

  // 8) voice agent (or wake-word supervisor)
  if (useWakeword) {
    console.log('Starting wake-word supervisor (say the wake word to talk)…');
    spawnChild('wake word', 'wakeword.js');
  } else {
    console.log('Starting voice agent — talk now. Ctrl+C to stop.');
    spawnChild('voice agent', 'agent.js');
  }

  process.on('SIGINT', () => shutdown(0));
  process.on('SIGTERM', () => shutdown(0));
}

const isMain = process.argv[1] && process.argv[1].endsWith('launch.js');
if (isMain) {
  main().catch((err) => {
    console.error('Launcher failed:', err.message);
    shutdown(1);
  });
}
