// Lightweight status monitor ("tray lite") — dependency-free.
// Polls the local auth server health + pending approvals and surfaces them in the
// console. On Windows, pair with scripts/install-service.ps1 which runs the
// assistant in the user session (avoids Session 0 isolation so nut-js input works).
// Usage: node scripts/tray.js [--open] — --open launches the confirm page on approval.

const PORT = process.env.PORT || 3000;
const OPEN_ON_APPROVAL = process.argv.includes('--open');
const POLL_MS = 5000;

let lastPending = 0;

async function check() {
  try {
    const health = await fetch(`http://localhost:${PORT}/health`).then((r) => r.json());
    const { pending } = await fetch(`http://localhost:${PORT}/api/approvals`).then((r) => r.json());
    const stamp = new Date().toLocaleTimeString();
    if (pending.length !== lastPending) {
      lastPending = pending.length;
      if (pending.length > 0) {
        console.log(`[${stamp}] ⚠️  ${pending.length} pending approval(s)! Open http://localhost:${PORT}/api/confirm`);
        for (const p of pending) console.log(`   - ${p.id}: ${p.tool} ${JSON.stringify(p.args)}`);
        if (OPEN_ON_APPROVAL) {
          const { exec } = await import('child_process');
          const url = `http://localhost:${PORT}/api/confirm`;
          const cmd = process.platform === 'win32' ? `start "" "${url}"` : process.platform === 'darwin' ? `open "${url}"` : `xdg-open "${url}"`;
          exec(cmd);
        }
      } else {
        console.log(`[${stamp}] ✅ server ok (${health.timestamp}), no pending approvals`);
      }
    }
  } catch (err) {
    console.log(`[${new Date().toLocaleTimeString()}] ❌ server unreachable: ${err.message} (is 'npm start' running?)`);
  }
}

console.log(`PC Assistant monitor — polling http://localhost:${PORT} every ${POLL_MS / 1000}s. Ctrl+C to stop.`);
console.log('Commands: [o]pen confirm page | [q]uit');
await check();
setInterval(check, POLL_MS);

// Minimal interactive controls (no extra deps)
if (process.stdin.isTTY) {
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.on('data', async (key) => {
    const k = key.toString().toLowerCase();
    if (k === 'q' || k === '\u0003') process.exit(0);
    if (k === 'o') {
      const { exec } = await import('child_process');
      const url = `http://localhost:${PORT}/api/confirm`;
      exec(process.platform === 'win32' ? `start "" "${url}"` : process.platform === 'darwin' ? `open "${url}"` : `xdg-open "${url}"`);
    }
  });
}
