import os from 'os';
import fs from 'fs/promises';
import osUtils from 'node-os-utils';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { systemCache, cacheKey } from '../lib/cache.js';

const execFileAsync = promisify(execFile);

async function getProcessList() {
  if (process.platform === 'win32') {
    // Try tasklist CSV first — fast native Windows executable
    try {
      const { stdout } = await execFileAsync('tasklist', ['/FO', 'CSV', '/NH'], { timeout: 15000, maxBuffer: 10 * 1024 * 1024 });
      const lines = stdout
        .split(/\r?\n/)
        .filter((l) => l.trim().startsWith('"'))
        .map((line) => {
          const matches = line.match(/"([^"]*)"/g);
          if (!matches || matches.length < 5) return null;
          const cols = matches.map((c) => c.slice(1, -1));
          const memKb = Number((cols[4] || '0').replace(/[, K]/g, '')) || 0;
          return { pid: Number(cols[1]), name: cols[0] || 'unknown', cpu: 0, mem: Math.round(memKb / 1024) };
        })
        .filter((p) => p && Number.isFinite(p.pid));
      if (lines.length > 0) return lines;
    } catch {
      // Fallback: PowerShell Get-Process
    }

    try {
      const ps = 'Get-Process | Select-Object -First 60 -Property Id, ProcessName, CPU, WorkingSet64 | ConvertTo-Json -Compress';
      const { stdout } = await execFileAsync('powershell', ['-NoProfile', '-Command', ps], { timeout: 15000, maxBuffer: 10 * 1024 * 1024 });
      const trimmed = stdout.trim();
      if (!trimmed) return [];
      const raw = JSON.parse(trimmed);
      const arr = Array.isArray(raw) ? raw : [raw];
      return arr
        .map((p) => ({
          pid: Number(p.Id),
          name: p.ProcessName || 'unknown',
          cpu: Math.round((Number(p.CPU) || 0) * 100) / 100,
          mem: Math.round((Number(p.WorkingSet64) || 0) / (1024 * 1024))
        }))
        .filter((p) => Number.isFinite(p.pid));
    } catch (e) {
      throw new Error(`Failed to list processes on Windows: ${e.message}`);
    }
  }
  const { stdout } = await execFileAsync('ps', ['-eo', 'pid,pcpu,pmem,comm'], { timeout: 15000, maxBuffer: 10 * 1024 * 1024 });
  return stdout
    .split('\n')
    .slice(1)
    .map((line) => {
      const m = line.trim().match(/^(\d+)\s+([\d.]+)\s+([\d.]+)\s+(.+)$/);
      if (!m) return null;
      return { pid: Number(m[1]), name: m[4], cpu: Number(m[2]), mem: Number(m[3]) };
    })
    .filter(Boolean);
}

// Get system status (cached 5s — cpu.usage() samples over ~1s, so caching also saves latency)
export async function systemStatus(args) {
  const key = cacheKey('sys-status', {});
  const cached = systemCache.get(key);
  if (cached) return cached;
  try {
    const cpu = await osUtils.cpu.usage();
    // Use Node built-ins for memory (node-os-utils mem API shape varies by version/platform)
    const totalMemMb = os.totalmem() / 1024 / 1024;
    const freeMemMb = os.freemem() / 1024 / 1024;
    const usedMemMb = totalMemMb - freeMemMb;
    // Drive stats: native Node.js statfs works across Windows, Linux, and macOS.
    let driveInfo = null;
    try {
      const rootPath = process.platform === 'win32' ? process.cwd().slice(0, 3) : '/';
      const stats = await fs.statfs(rootPath);
      const totalGb = (stats.blocks * stats.bsize) / (1024 ** 3);
      const freeGb = (stats.bavail * stats.bsize) / (1024 ** 3);
      const usedGb = totalGb - freeGb;
      const usedPercentage = totalGb > 0 ? `${((usedGb / totalGb) * 100).toFixed(1)}%` : '0%';
      driveInfo = {
        totalGb: Math.round(totalGb * 100) / 100,
        usedGb: Math.round(usedGb * 100) / 100,
        freeGb: Math.round(freeGb * 100) / 100,
        usage: usedPercentage
      };
    } catch (driveErr) {
      driveInfo = { error: driveErr.message };
    }
    // Display stats: probe primary screen dimensions
    let displayInfo = null;
    try {
      const { screen } = await import('@nut-tree-fork/nut-js');
      const width = await screen.width();
      const height = await screen.height();
      if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
        displayInfo = {
          width,
          height,
          resolution: `${width}x${height}`
        };
      }
    } catch {
      /* display probe optional */
    }

    const result = {
      cpu: {
        usage: cpu,
        cores: os.cpus().length,
        model: os.cpus()[0].model
      },
      memory: {
        total: Math.round(totalMemMb * 100) / 100,
        free: Math.round(freeMemMb * 100) / 100,
        used: Math.round(usedMemMb * 100) / 100,
        usage: ((usedMemMb / totalMemMb) * 100).toFixed(2)
      },
      disk: driveInfo && !driveInfo.error ? {
        total: driveInfo.totalGb,
        used: driveInfo.usedGb,
        free: driveInfo.freeGb,
        usage: driveInfo.usage
      } : { error: driveInfo?.error || 'unavailable' },
      display: displayInfo || { width: 1920, height: 1080, resolution: '1920x1080' },
      system: {
        type: os.type(),
        release: os.release(),
        hostname: os.hostname(),
        uptime: os.uptime(),
        uptimeFormatted: formatUptime(os.uptime())
      }
    };
    systemCache.set(key, result);
    return result;
  } catch (error) {
    throw new Error(`Failed to get system status: ${error.message}`);
  }
}

// List running processes — native OS commands (node-os-utils has no process list API).
// Windows: tasklist CSV. macOS/Linux: ps. Normalized to { pid, name, cpu, mem }.
export async function listProcesses(args = {}) {
  const { sortBy = 'cpu', limit = 20, name = '' } = args;
  const key = cacheKey('proc-list', { sortBy, limit, name });
  const cached = systemCache.get(key);
  if (cached) return cached;

  try {
    const processes = await getProcessList();

    let filteredProcesses = processes;
    if (name && typeof name === 'string' && name.trim()) {
      const q = name.trim().toLowerCase();
      filteredProcesses = processes.filter((p) => p.name.toLowerCase().includes(q));
    }

    // Sort processes based on sortBy parameter
    // (Windows tasklist has no per-process CPU% — 'cpu' sort falls back to memory there.)
    const sortField = sortBy.toLowerCase() === 'cpu' && process.platform === 'win32' ? 'mem' : sortBy.toLowerCase();
    let sortedProcesses = [...filteredProcesses];
    switch (sortField) {
      case 'cpu':
        sortedProcesses.sort((a, b) => b.cpu - a.cpu);
        break;
      case 'mem':
        sortedProcesses.sort((a, b) => b.mem - a.mem);
        break;
      case 'pid':
        sortedProcesses.sort((a, b) => a.pid - b.pid);
        break;
      case 'name':
        sortedProcesses.sort((a, b) => a.name.localeCompare(b.name));
        break;
      default:
        sortedProcesses.sort((a, b) => b.cpu - a.cpu);
    }

    // Limit results
    const limitedProcesses = sortedProcesses.slice(0, limit);

    const result = {
      processes: limitedProcesses,
      count: limitedProcesses.length
    };
    systemCache.set(key, result);
    return result;
  } catch (error) {
    throw new Error(`Failed to list processes: ${error.message}`);
  }
}

// Kill process by PID
export async function killProcess(args) {
  const { pid } = args;

  try {
    // Protected PIDs check
    if (pid === 1 || pid === 0) {
      throw new Error('Cannot kill PID 1 (system process)');
    }

    // Get current process PID and parent PID to protect the assistant itself and runner
    const currentPid = process.pid;
    const parentPid = process.ppid;
    if (pid === currentPid || pid === parentPid) {
      throw new Error('Cannot kill the assistant process itself or its parent runner');
    }

    // Protect known IDEs and critical system processes
    try {
      const procs = await getProcessList();
      const target = procs.find((p) => p.pid === pid);
      if (target) {
        const lower = target.name.toLowerCase();
        const PROTECTED = ['antigravity', 'code', 'node', 'explorer', 'dwm', 'csrss', 'lsass', 'services'];
        if (PROTECTED.some((p) => lower.includes(p))) {
          throw new Error(`Cannot kill protected process: ${target.name} (PID ${pid})`);
        }
      }
    } catch (err) {
      if (err.message.startsWith('Cannot kill protected process')) throw err;
    }

    process.kill(pid, 'SIGTERM');

    return {
      success: true,
      message: `Process ${pid} terminated successfully`
    };
  } catch (error) {
    if (error.code === 'ESRCH') {
      throw new Error(`Process ${pid} not found`);
    }
    if (error.code === 'EPERM') {
      throw new Error(`Permission denied to kill process ${pid}`);
    }
    throw new Error(`Failed to kill process: ${error.message}`);
  }
}

// Helper function to format uptime
function formatUptime(seconds) {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);

  const parts = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0) parts.push(`${minutes}m`);
  if (secs > 0) parts.push(`${secs}s`);

  return parts.join(' ') || '0s';
}