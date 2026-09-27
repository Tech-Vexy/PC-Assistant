// Native terminal tools (vision §8): deterministic command execution plus
// long-running interactive sessions (start/read/input/kill).
//
// One-shot execution reuses the allowlisted runner from shell-control.js.
// Sessions spawn the same allowlisted commands with piped stdio and an
// in-memory ring buffer; output is polled with terminal_read. A session is
// approved ONCE at start (dangerous tool) — input afterwards flows without
// per-keystroke approval, which is the documented session contract.
//
// Limits: max 10 concurrent sessions, 200KB output buffer each, 10-minute
// idle expiry swept on every session operation.
import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import crypto from 'crypto';
import { runCommand, isCommandAllowed, splitArgv, resolveWindowsTarget } from './shell-control.js';

const MAX_SESSIONS = 10;
const MAX_BUFFER_BYTES = 200 * 1024;
const IDLE_EXPIRY_MS = 10 * 60 * 1000;
const MAX_INPUT_BYTES = 10 * 1024;

const sessions = new Map(); // id -> { proc, argv, command, cwd, output, readOffset, exitCode, startedAt, lastActivity }

export function __clearSessions() {
  for (const [, s] of sessions) {
    try {
      s.proc.kill('SIGKILL');
    } catch {
      /* noop */
    }
  }
  sessions.clear();
}

function sweepIdle() {
  const now = Date.now();
  for (const [id, s] of sessions) {
    if (now - s.lastActivity > IDLE_EXPIRY_MS) {
      try {
        s.proc.kill('SIGKILL');
      } catch {
        /* noop */
      }
      sessions.delete(id);
    }
  }
}

function pushOutput(s, chunk) {
  s.output += chunk;
  s.lastActivity = Date.now();
  if (s.output.length > MAX_BUFFER_BYTES) {
    const drop = s.output.length - MAX_BUFFER_BYTES;
    s.output = s.output.slice(drop);
    s.readOffset = Math.max(0, s.readOffset - drop);
  }
}

async function resolveCwd(cwd) {
  if (cwd === null || cwd === undefined || String(cwd).trim() === '') return process.cwd();
  const resolved = path.resolve(String(cwd));
  const st = await fs.stat(resolved).catch(() => null);
  if (!st || !st.isDirectory()) throw new Error(`cwd is not an existing directory: ${cwd}`);
  return resolved;
}

function newSessionId() {
  return `term-${crypto.randomBytes(8).toString('hex')}`;
}

export async function terminalExecute(args) {
  const { command, cwd = null, timeoutMs = 30000 } = args;
  return runCommand({ command, cwd, timeoutMs });
}

export async function terminalStart(args) {
  const { command, cwd = null } = args;
  if (!command || typeof command !== 'string' || !command.trim()) {
    throw new Error('command must be a non-empty string');
  }
  if (!isCommandAllowed(command)) {
    throw new Error(`Command not in allowlist: ${command}`);
  }
  sweepIdle();
  if (sessions.size >= MAX_SESSIONS) {
    throw new Error(`Too many terminal sessions (max ${MAX_SESSIONS}). Kill one with terminal_kill first.`);
  }
  const execCwd = await resolveCwd(cwd);
  const argv = splitArgv(command.trim());
  const bin = argv[0].split('/').pop().split('\\').pop();
  if (bin === 'cd') throw new Error('cd is not executable as a child process (use cwd instead)');

  let proc;
  if (process.platform === 'win32') {
    // Real binaries spawn directly (cmd mangles quoted args); builtins and
    // batch files fall back to cmd /c (same policy as one-shot execution).
    const target = await resolveWindowsTarget(argv, command.trim());
    proc = target.shell
      ? spawn('cmd', ['/d', '/s', '/c', command.trim()], { cwd: execCwd, stdio: ['pipe', 'pipe', 'pipe'] })
      : spawn(target.direct[0], target.direct[1], { cwd: execCwd, stdio: ['pipe', 'pipe', 'pipe'], shell: false });
  } else {
    proc = spawn(argv[0], argv.slice(1), { cwd: execCwd, stdio: ['pipe', 'pipe', 'pipe'], shell: false });
  }
  const id = newSessionId();
  const s = {
    proc, argv, command: command.trim(), cwd: execCwd,
    output: '', readOffset: 0, exitCode: null, startedAt: Date.now(), lastActivity: Date.now(),
  };
  proc.stdout.on('data', (d) => pushOutput(s, d.toString()));
  proc.stderr.on('data', (d) => pushOutput(s, d.toString()));
  proc.on('close', (code) => {
    s.exitCode = code;
    s.lastActivity = Date.now();
  });
  proc.on('error', (err) => {
    pushOutput(s, `\n[process error: ${err.message}]\n`);
    s.exitCode = 1;
  });
  sessions.set(id, s);
  return { success: true, sessionId: id, message: `Terminal session started: ${command.trim()} (cwd: ${execCwd})` };
}

export async function terminalRead(args) {
  const { sessionId, tailChars = 8000 } = args;
  sweepIdle();
  const s = sessions.get(sessionId);
  if (!s) throw new Error(`No terminal session "${sessionId}". List them from an earlier terminal_start result.`);
  s.lastActivity = Date.now();
  const tail = Math.min(Math.max(Number(tailChars) || 8000, 100), 50000);
  const fresh = s.output.slice(s.readOffset);
  s.readOffset = s.output.length;
  const running = s.exitCode === null;
  return {
    success: true,
    sessionId,
    running,
    ...(running ? {} : { exitCode: s.exitCode }),
    output: fresh.length > tail ? `…(truncated to last ${tail} chars)\n` + fresh.slice(-tail) : fresh,
    outputLength: fresh.length,
  };
}

export async function terminalInput(args) {
  const { sessionId, input } = args;
  sweepIdle();
  const s = sessions.get(sessionId);
  if (!s) throw new Error(`No terminal session "${sessionId}".`);
  if (s.exitCode !== null) throw new Error(`Session "${sessionId}" already exited (code ${s.exitCode}).`);
  if (typeof input !== 'string' || input.length === 0) throw new Error('input must be a non-empty string');
  if (Buffer.byteLength(input) > MAX_INPUT_BYTES) {
    throw new Error(`input exceeds safety limit (${MAX_INPUT_BYTES} bytes)`);
  }
  s.lastActivity = Date.now();
  await new Promise((resolve, reject) => {
    s.proc.stdin.write(input, (err) => (err ? reject(err) : resolve()));
  });
  return { success: true, sessionId, bytesWritten: Buffer.byteLength(input) };
}

export async function terminalKill(args) {
  const { sessionId } = args;
  const s = sessions.get(sessionId);
  if (!s) throw new Error(`No terminal session "${sessionId}".`);
  try {
    s.proc.kill('SIGTERM');
  } catch {
    /* already dead */
  }
  await new Promise((r) => setTimeout(r, 500));
  if (s.exitCode === null) {
    try {
      s.proc.kill('SIGKILL');
    } catch {
      /* noop */
    }
  }
  sessions.delete(sessionId);
  return { success: true, sessionId, message: `Terminal session ${sessionId} terminated` };
}
