import { execFile } from 'child_process';
import { promisify } from 'util';
import { keyboard, Key } from '@nut-tree-fork/nut-js';

const execFileAsync = promisify(execFile);

// Mapping of common user speech names to Windows executable / URI commands
const APP_ALIASES = {
  spotify: 'spotify',
  chrome: 'chrome',
  'google chrome': 'chrome',
  code: 'code',
  'vs code': 'code',
  'visual studio code': 'code',
  notepad: 'notepad',
  calc: 'calc',
  calculator: 'calc',
  terminal: 'wt',
  powershell: 'powershell',
  explorer: 'explorer',
  'file explorer': 'explorer',
  edge: 'msedge',
  'microsoft edge': 'msedge',
  firefox: 'firefox',
  settings: 'ms-settings:',
  taskmgr: 'taskmgr',
  'task manager': 'taskmgr'
};

// 1. Application Launcher
export async function openApplication(args) {
  const { appName } = args;
  if (!appName || typeof appName !== 'string') {
    throw new Error('appName must be a non-empty string');
  }

  const cleanName = appName.trim().toLowerCase();
  const target = APP_ALIASES[cleanName] || appName.trim();

  // Validate to prevent injection
  if (!/^[a-zA-Z0-9_.:\- ]+$/.test(target)) {
    throw new Error(`Invalid application identifier: ${target}`);
  }

  try {
    if (process.platform === 'win32') {
      await execFileAsync('cmd', ['/c', 'start', '', target], { timeout: 10000 });
    } else if (process.platform === 'darwin') {
      await execFileAsync('open', ['-a', target], { timeout: 10000 });
    } else {
      await execFileAsync('xdg-open', [target], { timeout: 10000 });
    }

    return {
      success: true,
      message: `Launched application: ${appName}`
    };
  } catch (error) {
    throw new Error(`Failed to launch "${appName}": ${error.message}`);
  }
}

// 2. Window Management (minimize all, restore all, focus window)
export async function manageWindows(args) {
  const { action, target } = args;
  const act = String(action).toLowerCase();

  try {
    if (process.platform === 'win32') {
      if (act === 'minimize_all') {
        const ps = '(New-Object -ComObject Shell.Application).MinimizeAll()';
        await execFileAsync('powershell', ['-NoProfile', '-Command', ps], { timeout: 10000 });
        return { success: true, message: 'Minimized all windows' };
      }

      if (act === 'restore_all') {
        const ps = '(New-Object -ComObject Shell.Application).UndoMinimizeALL()';
        await execFileAsync('powershell', ['-NoProfile', '-Command', ps], { timeout: 10000 });
        return { success: true, message: 'Restored all windows' };
      }

      if (act === 'switch_to' && target) {
        // Bring window with matching title or process name to front
        const ps = `
          $t = '${target.replace(/'/g, "''")}';
          $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$t*" -or $_.ProcessName -like "*$t*" } | Select-Object -First 1;
          if ($proc) {
            $wscript = New-Object -ComObject Wscript.Shell;
            $wscript.AppActivate($proc.Id);
            Write-Output "OK"
          } else {
            Write-Output "NOT_FOUND"
          }
        `;
        const { stdout } = await execFileAsync('powershell', ['-NoProfile', '-Command', ps], { timeout: 10000 });
        if (stdout.includes('NOT_FOUND')) {
          return { success: false, message: `Could not find an active window matching "${target}"` };
        }
        return { success: true, message: `Switched to "${target}" window` };
      }
    }

    // Default keyboard fallback for minimize/restore
    if (act === 'minimize_all') {
      await keyboard.pressKey(Key.LeftWin, Key.D);
      await keyboard.releaseKey(Key.LeftWin, Key.D);
      return { success: true, message: 'Toggled desktop / minimized windows' };
    }

    throw new Error(`Unsupported window action: ${action}`);
  } catch (error) {
    throw new Error(`Window management failed: ${error.message}`);
  }
}

// 3. Media & Volume Control
export async function mediaControl(args) {
  const { action, count = 1 } = args;
  const act = String(action).toLowerCase();
  const repeat = Math.min(Math.max(Number(count) || 1, 1), 20);

  try {
    switch (act) {
      case 'volume_up':
        for (let i = 0; i < repeat; i++) {
          await keyboard.pressKey(Key.AudioVolUp);
          await keyboard.releaseKey(Key.AudioVolUp);
        }
        return { success: true, message: `Volume increased by ${repeat * 2}%` };

      case 'volume_down':
        for (let i = 0; i < repeat; i++) {
          await keyboard.pressKey(Key.AudioVolDown);
          await keyboard.releaseKey(Key.AudioVolDown);
        }
        return { success: true, message: `Volume decreased by ${repeat * 2}%` };

      case 'mute':
      case 'unmute':
      case 'toggle_mute':
        await keyboard.pressKey(Key.AudioMute);
        await keyboard.releaseKey(Key.AudioMute);
        return { success: true, message: 'Toggled audio mute' };

      case 'play_pause':
      case 'play':
      case 'pause':
        await keyboard.pressKey(Key.AudioPlay);
        await keyboard.releaseKey(Key.AudioPlay);
        return { success: true, message: 'Toggled media playback' };

      case 'next_track':
      case 'next':
        await keyboard.pressKey(Key.AudioNext);
        await keyboard.releaseKey(Key.AudioNext);
        return { success: true, message: 'Skipped to next track' };

      case 'previous_track':
      case 'previous':
      case 'prev':
        await keyboard.pressKey(Key.AudioPrev);
        await keyboard.releaseKey(Key.AudioPrev);
        return { success: true, message: 'Skipped to previous track' };

      default:
        throw new Error(`Unknown media action: ${action}. Use volume_up, volume_down, mute, play_pause, next_track, previous_track.`);
    }
  } catch (error) {
    throw new Error(`Media control failed: ${error.message}`);
  }
}

// 4. Clipboard Integration
export async function clipboardControl(args) {
  const { action, text } = args;
  const act = String(action).toLowerCase();

  try {
    if (act === 'read') {
      let content = '';
      if (process.platform === 'win32') {
        const { stdout } = await execFileAsync('powershell', ['-NoProfile', '-Command', 'Get-Clipboard'], { timeout: 10000 });
        content = stdout.trim();
      } else if (process.platform === 'darwin') {
        const { stdout } = await execFileAsync('pbpaste', [], { timeout: 10000 });
        content = stdout.trim();
      } else {
        const { stdout } = await execFileAsync('xclip', ['-selection', 'clipboard', '-o'], { timeout: 10000 });
        content = stdout.trim();
      }
      return {
        success: true,
        content: content || '(clipboard is empty)',
        length: content.length
      };
    }

    if (act === 'write') {
      if (typeof text !== 'string') {
        throw new Error('text must be provided when writing to clipboard');
      }
      if (process.platform === 'win32') {
        // Feed text via stdin to avoid command line length limits or quote escaping bugs
        const child = execFile('powershell', ['-NoProfile', '-Command', 'Set-Clipboard -Value $input'], { timeout: 10000 });
        child.stdin.write(text);
        child.stdin.end();
        await new Promise((resolve, reject) => {
          child.on('close', resolve);
          child.on('error', reject);
        });
      } else if (process.platform === 'darwin') {
        const child = execFile('pbcopy', [], { timeout: 10000 });
        child.stdin.write(text);
        child.stdin.end();
        await new Promise((resolve, reject) => {
          child.on('close', resolve);
          child.on('error', reject);
        });
      } else {
        const child = execFile('xclip', ['-selection', 'clipboard'], { timeout: 10000 });
        child.stdin.write(text);
        child.stdin.end();
        await new Promise((resolve, reject) => {
          child.on('close', resolve);
          child.on('error', reject);
        });
      }
      return {
        success: true,
        message: `Copied ${text.length} characters to clipboard`
      };
    }

    throw new Error(`Unknown clipboard action: ${action}. Use "read" or "write".`);
  } catch (error) {
    throw new Error(`Clipboard operation failed: ${error.message}`);
  }
}
