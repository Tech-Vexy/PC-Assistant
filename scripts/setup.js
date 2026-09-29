// Automated setup: verifies node/ffmpeg/env, installs deps, signs tool manifest.
// Usage: npm run setup  (or: node scripts/setup.js [--skip-install])
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);
const SKIP_INSTALL = process.argv.includes('--skip-install');
let failures = 0;
const ok = (m) => console.log(`  ✅ ${m}`);
const fail = (m) => {
  failures++;
  console.log(`  ❌ ${m}`);
};

console.log('PC Assistant setup\n');

// 1) Node version
const major = Number(process.versions.node.split('.')[0]);
if (major >= 18) ok(`Node ${process.versions.node}`);
else fail(`Node ${process.versions.node} — need 18+`);

// 2) FFmpeg
try {
  await execFileAsync('ffmpeg', ['-version'], { timeout: 10000 });
  ok('ffmpeg on PATH');
} catch {
  fail('ffmpeg not found — install from https://ffmpeg.org/download.html (Windows: add to PATH; macOS: brew install ffmpeg)');
}
try {
  await execFileAsync('ffplay', ['-version'], { timeout: 10000 });
  ok('ffplay on PATH (audio playback)');
} catch {
  fail('ffplay not found (ships with ffmpeg) — voice replies will fail');
}

// 3) Dependencies
if (!SKIP_INSTALL) {
  console.log('\nInstalling npm dependencies…');
  try {
    const { exec } = await import('child_process');
    await new Promise((resolve, reject) => {
      const p = exec('npm install', { cwd: process.cwd() });
      p.stdout?.pipe(process.stdout);
      p.stderr?.pipe(process.stderr);
      p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`npm install exited ${code}`))));
    });
    ok('npm install');
  } catch (e) {
    fail(e.message);
  }
}

// 4) Config store (DuckDB; seeds once from legacy .env/tokens/session/logs)
const { initStore, cfg } = await import('../lib/store.js');
await initStore();
for (const key of ['ASSEMBLYAI_API_KEY', 'LLM_API_KEY']) {
  const v = cfg(key);
  if (v && !v.includes('your_')) ok(`${key} set`);
  else console.log(`  ⚠️  ${key} missing — set it at /setup or in the environment`);
}
{
  const gemini = cfg('GEMINI_API_KEY');
  if (gemini && !gemini.includes('your_')) ok('GEMINI_API_KEY set (Computer Use vision loop)');
  else console.log('  ⚠️  GEMINI_API_KEY missing — optional; computer_use needs it');
}

// 5) Sign tool manifest (integrity baseline)
try {
  const { buildAllTools } = await import('../tools.js');
  const { signToolManifest } = await import('../lib/security-extras.js');
  await signToolManifest(buildAllTools());
  ok('tool manifest signed (tool-manifest.json)');
} catch (e) {
  fail(`manifest signing failed: ${e.message}`);
}

console.log(failures === 0 ? '\nSetup complete 🎉 — next: npm start, then npm run agent' : `\nSetup finished with ${failures} problem(s) — fix them and re-run.`);
process.exit(failures === 0 ? 0 : 1);
