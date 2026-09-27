import { execFile } from 'child_process';
import { promisify } from 'util';
import fs from 'fs/promises';
import path from 'path';

const execFileAsync = promisify(execFile);

// Strict allowlist of permitted commands
const ALLOWLIST = [
  'ls',
  'dir',
  'pwd',
  'cd',
  'echo',
  'date',
  'whoami',
  'hostname',
  'uptime',
  'ps',
  'top',
  'htop',
  'df',
  'du',
  'free',
  'netstat',
  'ping',
  'traceroute',
  'nslookup',
  'ipconfig',
  'ifconfig',
  'curl',
  'wget',
  'git',
  'npm',
  'node',
  'python',
  'python3',
  'cat',
  'head',
  'tail',
  'grep',
  'find',
  'wc',
  'sort',
  'uniq',
  'cut',
  'awk',
  'sed'
];

// Reject shell metacharacters so chained/inline commands ("ls; rm -rf /",
// "cat x && shutdown", "echo `whoami`", "echo $(curl evil)") can't smuggle a
// non-allowlisted command past the first-token check.
const SHELL_META_PATTERN = /[;&|`$<>\n\r]/;

// Split a command string into argv without invoking a shell.
// Supports single/double quotes; throws on unbalanced quotes.
export function splitArgv(command) {
  const args = [];
  let current = '';
  let quote = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) quote = null;
      else current += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (/\s/.test(ch)) {
      if (current) {
        args.push(current);
        current = '';
      }
    } else {
      current += ch;
    }
  }
  if (quote) throw new Error('Unbalanced quote in command');
  if (current) args.push(current);
  return args;
}

// Windows launch resolution: spawn real binaries directly (preserves quoting —
// cmd.exe mangles quoted args), and only fall back to `cmd /c` for shell
// builtins (echo/dir/...) and batch files (.cmd/.bat/.ps1, e.g. npm) which
// Node cannot spawn without a shell.
export async function resolveWindowsTarget(argv, command) {
  const bin = String(argv[0] || '');
  if (/\.(cmd|bat|ps1)$/i.test(bin)) return { shell: true };
  try {
    const { stdout } = await execFileAsync('where', [bin], { timeout: 5000 });
    const found = String(stdout).split(/\r?\n/).map((s) => s.trim()).find(Boolean);
    if (!found) return { shell: true };
    if (/\.(cmd|bat|ps1)$/i.test(found)) return { shell: true };
    return { direct: [found, argv.slice(1)] };
  } catch {
    return { shell: true }; // builtin (echo/dir/...) or unknown — let cmd try
  }
}

// Check if command is a single allowlisted command with no shell chaining
export function isCommandAllowed(command) {
  if (!command || typeof command !== 'string') return false;
  const trimmed = command.trim();
  if (SHELL_META_PATTERN.test(trimmed)) return false;

  const baseCommand = trimmed.split(/\s+/)[0];
  const commandName = baseCommand.split('/').pop().split('\\').pop(); // Handle /usr/bin/git and C:\...\git

  return ALLOWLIST.includes(commandName);
}

// Run allowlisted shell command.
// Optional cwd (must be an existing directory) and timeoutMs (1–120s).
export async function runCommand(args) {
  const { command, cwd = null, timeoutMs = 30000 } = args;

  try {
    if (!command || typeof command !== 'string') {
      throw new Error('Invalid command provided');
    }

    // Check if command is allowed
    if (!isCommandAllowed(command)) {
      throw new Error(`Command not in allowlist: ${command}`);
    }

    const timeout = Math.min(Math.max(Number(timeoutMs) || 30000, 1000), 120000);
    let execCwd = process.cwd();
    if (cwd !== null && cwd !== undefined && String(cwd).trim() !== '') {
      const resolved = path.resolve(String(cwd));
      const st = await fs.stat(resolved).catch(() => null);
      if (!st || !st.isDirectory()) throw new Error(`cwd is not an existing directory: ${cwd}`);
      execCwd = resolved;
    }

    // Execute WITHOUT an extra shell layer. On POSIX, argv is passed directly
    // to the binary (no shell to interpret chaining/substitution/redirects).
    // On Windows, real binaries also spawn directly (cmd.exe mangles quoted
    // args); only builtins and batch files route through `cmd /c` — safe
    // because validation above already rejected all shell metacharacters
    // ([;&|`$<>\n\r]), leaving only a single simple command.
    // 'cd' is shell state with no effect in a child process — reject it here
    // (it passes validation only for backwards compat with the allowlist).
    const argv = splitArgv(command.trim());
    const bin = argv[0].split('/').pop().split('\\').pop();
    if (bin === 'cd') {
      throw new Error('cd is not executable as a child process (no-op)');
    }
    let stdout;
    let stderr;
    if (process.platform === 'win32') {
      const target = await resolveWindowsTarget(argv, command.trim());
      if (target.shell) {
        ({ stdout, stderr } = await execFileAsync('cmd', ['/d', '/s', '/c', command.trim()], {
          timeout,
          maxBuffer: 1024 * 1024 * 10,
          shell: false,
          cwd: execCwd,
        }));
      } else {
        ({ stdout, stderr } = await execFileAsync(target.direct[0], target.direct[1], {
          timeout,
          maxBuffer: 1024 * 1024 * 10,
          shell: false,
          cwd: execCwd,
        }));
      }
    } else {
      ({ stdout, stderr } = await execFileAsync(argv[0], argv.slice(1), {
        timeout, // clamped 1–120s above
        maxBuffer: 1024 * 1024 * 10, // 10MB buffer
        shell: false,
        cwd: execCwd,
      }));
    }

    return {
      success: true,
      command: command,
      stdout: stdout.trim(),
      stderr: stderr.trim(),
      exitCode: 0
    };
  } catch (error) {
    // Handle timeout
    if (error.killed && error.signal === 'SIGTERM') {
      throw new Error(`Command timed out: ${command}`);
    }

    return {
      success: false,
      command: command,
      stdout: error.stdout || '',
      stderr: error.stderr || error.message,
      exitCode: error.code || 1
    };
  }
}