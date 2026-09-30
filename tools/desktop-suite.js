import { execFile } from 'child_process';
import { promisify } from 'util';
import { keyboard, Key } from '@nut-tree-fork/nut-js';

const execFileAsync = promisify(execFile);

// 0. List Installed Applications
export async function listInstalledApps(args) {
  const { limit = 50 } = args;
  const maxApps = Math.min(Math.max(Number(limit) || 50, 10), 200);
  
  try {
    let apps = [];
    
    if (process.platform === 'win32') {
      // Get applications from Windows Registry and Start Menu
      const psScript = `
        $apps = @()
        
        # Get apps from Registry (Start Menu programs)
        $registryPaths = @(
          "HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*",
          "HKLM:\\Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*",
          "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*"
        )
        
        foreach ($path in $registryPaths) {
          if (Test-Path $path) {
            Get-ItemProperty $path -ErrorAction SilentlyContinue | ForEach-Object {
              if ($_.DisplayName -and $_.DisplayName.Trim() -ne "") {
                $apps += [PSCustomObject]@{
                  Name = $_.DisplayName.Trim()
                  Publisher = if ($_.Publisher) { $_.Publisher.Trim() } else { "Unknown" }
                  InstallLocation = if ($_.InstallLocation) { $_.InstallLocation.Trim() } else { "N/A" }
                  Version = if ($_.DisplayVersion) { $_.DisplayVersion.Trim() } else { "N/A" }
                }
              }
            }
          }
        }
        
        # Get common system apps by executable
        $systemApps = @(
          @{Name="Control Panel"; Executable="control.exe"},
          @{Name="Settings"; Executable="ms-settings.exe"},
          @{Name="Task Manager"; Executable="taskmgr.exe"},
          @{Name="File Explorer"; Executable="explorer.exe"},
          @{Name="Command Prompt"; Executable="cmd.exe"},
          @{Name="PowerShell"; Executable="powershell.exe"},
          @{Name="Notepad"; Executable="notepad.exe"},
          @{Name="Calculator"; Executable="calc.exe"},
          @{Name="Paint"; Executable="mspaint.exe"},
          @{Name="Windows Terminal"; Executable="wt.exe"}
        )
        
        foreach ($app in $systemApps) {
          if ($apps.Name -notcontains $app.Name) {
            $apps += [PSCustomObject]@{
              Name = $app.Name
              Publisher = "Microsoft"
              InstallLocation = "System"
              Version = "Built-in"
            }
          }
        }
        
        # Sort by name and limit results
        $apps | Sort-Object Name | Select-Object -First ${maxApps} | ConvertTo-Json
      `;
      
      const { stdout } = await execFileAsync('powershell', ['-NoProfile', '-Command', psScript], { timeout: 30000 });
      // ConvertTo-Json emits a single object (not an array) for exactly one
      // match and an empty string for zero matches — normalize both to arrays.
      let parsed;
      try {
        parsed = JSON.parse(stdout);
      } catch {
        parsed = [];
      }
      apps = Array.isArray(parsed) ? parsed : parsed ? [parsed] : [];
      // Registry hives overlap (HKLM + Wow6432Node list the same app twice) —
      // dedupe by display name, keeping the first (richest) entry.
      const seen = new Set();
      apps = apps.filter((a) => {
        const key = String(a?.Name || '').toLowerCase();
        if (!key || seen.has(key)) return false;
        seen.add(key);
        return true;
      });
      
    } else if (process.platform === 'darwin') {
      // Get macOS applications from /Applications
      const { stdout } = await execFileAsync('ls', ['/Applications'], { timeout: 10000 });
      apps = stdout.split('\n')
        .filter(name => name.endsWith('.app'))
        .map(name => ({
          Name: name.replace('.app', ''),
          Publisher: 'Unknown',
          InstallLocation: '/Applications',
          Version: 'N/A'
        }))
        .slice(0, maxApps);
    } else {
      // Get Linux applications from common paths
      const paths = ['/usr/share/applications', '/var/lib/snapd/desktop/applications'];
      for (const path of paths) {
        try {
          const { stdout } = await execFileAsync('ls', [path], { timeout: 10000 });
          const desktopFiles = stdout.split('\n')
            .filter(name => name.endsWith('.desktop'))
            .slice(0, maxApps - apps.length);
          
          for (const file of desktopFiles) {
            try {
              const { stdout: content } = await execFileAsync('cat', [`${path}/${file}`], { timeout: 5000 });
              const nameMatch = content.match(/^Name=(.+)$/m);
              if (nameMatch) {
                apps.push({
                  Name: nameMatch[1].trim(),
                  Publisher: 'Unknown',
                  InstallLocation: path,
                  Version: 'N/A'
                });
              }
            } catch {
              // Skip files that can't be read
            }
          }
        } catch {
          // Skip paths that don't exist
        }
      }
    }
    
    return {
      success: true,
      count: apps.length,
      applications: apps.map(app => ({
        name: app.Name,
        publisher: app.Publisher,
        location: app.InstallLocation,
        version: app.Version
      }))
    };
  } catch (error) {
    const hint = error.code === 'ENOENT'
      ? ' (powershell not found on PATH — required for app discovery)'
      : '';
    throw new Error(`Failed to list installed applications: ${error.message}${hint}`);
  }
}

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
  'control panel': 'control',
  control: 'control',
  'command prompt': 'cmd',
  cmd: 'cmd',
  'snipping tool': 'snippingtool',
  'windows security': 'windowsdefender:',
  camera: 'microsoft.windows.camera:',
  terminal: 'wt',
  powershell: 'powershell',
  explorer: 'explorer',
  'file explorer': 'explorer',
  edge: 'msedge',
  'microsoft edge': 'msedge',
  firefox: 'firefox',
  settings: 'ms-settings:',
  taskmgr: 'taskmgr',
  'task manager': 'taskmgr',
  paint: 'mspaint',
  photos: 'ms-photos:',
  store: 'ms-windows-store:',
  'microsoft store': 'ms-windows-store:'
};

// 1. Application Launcher
export async function openApplication(args) {
  const { appName } = args;
  if (!appName || typeof appName !== 'string') {
    throw new Error('appName must be a non-empty string');
  }

  const rawLower = appName.trim().toLowerCase();
  const cleanName = rawLower.replace(/^the\s+/, '').replace(/\s+app$/, '').trim();
  const target = APP_ALIASES[cleanName] || APP_ALIASES[rawLower] || appName.trim();

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

      if (act === 'list') {
        const ps = `
          Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle.Trim() -ne "" } | 
            Select-Object Id, ProcessName, MainWindowTitle | 
            ConvertTo-Json -Compress
        `;
        const { stdout } = await execFileAsync('powershell', ['-NoProfile', '-Command', ps], { timeout: 10000 });
        const trimmed = stdout.trim();
        let windows = [];
        if (trimmed) {
          try {
            const raw = JSON.parse(trimmed);
            const arr = Array.isArray(raw) ? raw : [raw];
            windows = arr.map((w) => ({ pid: Number(w.Id), process: w.ProcessName, title: w.MainWindowTitle }));
          } catch { /* empty/malformed */ }
        }
        return {
          success: true,
          count: windows.length,
          windows,
          message: windows.length ? `Found ${windows.length} active window(s)` : 'No active windows with titles found'
        };
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
            $activated = $wscript.AppActivate($proc.Id);
            if (-not $activated -and $proc.MainWindowTitle) {
              $activated = $wscript.AppActivate($proc.MainWindowTitle);
            }
            if (-not $activated) {
              $activated = $wscript.AppActivate($t);
            }
            if ($activated) {
              Write-Output "OK"
            } else {
              Write-Output "ACTIVATE_FAILED"
            }
          } else {
            Write-Output "NOT_FOUND"
          }
        `;
        const { stdout } = await execFileAsync('powershell', ['-NoProfile', '-Command', ps], { timeout: 10000 });
        if (stdout.includes('NOT_FOUND')) {
          return { success: false, message: `Could not find an active window matching "${target}"` };
        }
        if (stdout.includes('ACTIVATE_FAILED')) {
          return { success: false, message: `Found window or process matching "${target}", but could not bring it to the foreground` };
        }
        return { success: true, message: `Switched to "${target}" window` };
      }

      if (act === 'close' && target) {
        const tLower = target.toLowerCase();
        const PROTECTED = ['antigravity', 'code', 'node', 'powershell', 'pwsh', 'cmd', 'explorer', 'dwm', 'csrss', 'lsass', 'services'];
        if (PROTECTED.some((p) => tLower.includes(p))) {
          return { success: false, message: `Cannot close protected application or system process matching "${target}"` };
        }
        const ps = `
          $t = '${target.replace(/'/g, "''")}';
          $procs = Get-Process | Where-Object { $_.MainWindowTitle -like "*$t*" -or $_.ProcessName -like "*$t*" };
          if ($procs) {
            $closedCount = 0;
            foreach ($p in $procs) {
              $closed = $p.CloseMainWindow();
              if (-not $closed) {
                Stop-Process -Id $p.Id -Force;
              }
              $closedCount++;
            }
            Write-Output "OK:$closedCount"
          } else {
            Write-Output "NOT_FOUND"
          }
        `;
        const { stdout } = await execFileAsync('powershell', ['-NoProfile', '-Command', ps], { timeout: 10000 });
        if (stdout.includes('NOT_FOUND')) {
          return { success: false, message: `Could not find an active window or process matching "${target}" to close` };
        }
        return { success: true, message: `Closed application window matching "${target}"` };
      }
    }

    if (act === 'close' && target) {
      const tLower = target.toLowerCase();
      const PROTECTED = ['antigravity', 'code', 'node', 'bash', 'zsh', 'terminal'];
      if (PROTECTED.some((p) => tLower.includes(p))) {
        return { success: false, message: `Cannot close protected application matching "${target}"` };
      }
      if (process.platform === 'darwin') {
        const script = `tell application "${target.replace(/"/g, '\\"')}" to quit`;
        await execFileAsync('osascript', ['-e', script], { timeout: 10000 });
        return { success: true, message: `Closed application "${target}"` };
      }
      try {
        await execFileAsync('wmctrl', ['-c', target], { timeout: 5000 });
        return { success: true, message: `Closed window matching "${target}"` };
      } catch {
        await execFileAsync('pkill', ['-f', target], { timeout: 5000 });
        return { success: true, message: `Closed process matching "${target}"` };
      }
    }

    if (act === 'list') {
      if (process.platform === 'darwin') {
        try {
          const script = 'tell application "System Events" to get name of every window of (every process whose background only is false)';
          const { stdout } = await execFileAsync('osascript', ['-e', script], { timeout: 10000 });
          const list = stdout.split(',').map((s) => s.trim()).filter(Boolean);
          return { success: true, count: list.length, windows: list.map((title) => ({ title })), message: `Found ${list.length} window(s)` };
        } catch {
          return { success: true, count: 0, windows: [], message: 'No active windows found' };
        }
      }
      try {
        const { stdout } = await execFileAsync('wmctrl', ['-l'], { timeout: 5000 });
        const list = stdout.split('\n').filter(Boolean).map((l) => ({ title: l.slice(l.indexOf(' ') + 1).trim() }));
        return { success: true, count: list.length, windows: list, message: `Found ${list.length} window(s)` };
      } catch {
        return { success: true, count: 0, windows: [], message: 'No active windows found' };
      }
    }

    // Default keyboard fallback for minimize/restore
    if (act === 'minimize_all') {
      await keyboard.pressKey(Key.LeftWin, Key.D);
      await keyboard.releaseKey(Key.LeftWin, Key.D);
      return { success: true, message: 'Toggled desktop / minimized windows' };
    }

    if (act === 'restore_all') {
      await keyboard.pressKey(Key.LeftWin, Key.D);
      await keyboard.releaseKey(Key.LeftWin, Key.D);
      return { success: true, message: 'Toggled desktop / restored windows' };
    }

    throw new Error(`Unsupported window action: ${action}`);
  } catch (error) {
    throw new Error(`Window management failed: ${error.message}`);
  }
}

// 3. Media & Volume Control

// Absolute mute control via Windows Core Audio (IAudioEndpointVolume).
// The AudioMute media key is a blind TOGGLE: sending it for "unmute" without
// knowing current state mutes the machine half the time. Reading and SETTING
// state over COM makes each action do exactly what it says. The script is
// dependency-free PowerShell (Add-Type inline C#), so no extra npm dep.
const PS_MUTE_SCRIPT = [
  "$ErrorActionPreference = 'Stop'",
  'Add-Type -TypeDefinition @"',
  'using System;',
  'using System.Runtime.InteropServices;',
  '[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]',
  'interface IAudioEndpointVolume {',
  '  int RegisterControlChangeNotify(IntPtr n);',
  '  int UnregisterControlChangeNotify(IntPtr n);',
  '  int GetChannelCount(out uint c);',
  '  int SetMasterVolumeLevel(float l, Guid e);',
  '  int SetMasterVolumeLevelScalar(float l, Guid e);',
  '  int GetMasterVolumeLevel(out float l);',
  '  int GetMasterVolumeLevelScalar(out float l);',
  '  int SetChannelVolumeLevel(uint ch, float l, Guid e);',
  '  int SetChannelVolumeLevelScalar(uint ch, float l, Guid e);',
  '  int GetChannelVolumeLevel(uint ch, out float l);',
  '  int GetChannelVolumeLevelScalar(uint ch, out float l);',
  '  int SetMute(bool m, Guid e);',
  '  int GetMute(out bool m);',
  '}',
  '[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]',
  'interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }',
  '[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]',
  'interface IMMDeviceEnumerator {',
  '  int EnumAudioEndpoints(int f, int m, IntPtr d);',
  '  int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d);',
  '}',
  '[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]',
  'class MMDeviceEnumeratorCom { }',
  'public static class AudioMute {',
  '  static IAudioEndpointVolume Endpoint() {',
  '    var en = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorCom();',
  '    IMMDevice dev; en.GetDefaultAudioEndpoint(0, 1, out dev);',
  '    var iid = typeof(IAudioEndpointVolume).GUID;',
  '    object o; dev.Activate(ref iid, 1, IntPtr.Zero, out o);',
  '    return (IAudioEndpointVolume)o;',
  '  }',
  '  public static void Set(bool mute) { Endpoint().SetMute(mute, Guid.Empty); }',
  '  public static bool Get() { bool m; Endpoint().GetMute(out m); return m; }',
  '}',
  '"@',
].join('\n');

async function readMuteState() {
  const { stdout } = await execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', `${PS_MUTE_SCRIPT}\n[AudioMute]::Get()`],
    { timeout: 10000 }
  );
  return String(stdout).trim().toLowerCase() === 'true';
}

async function writeMuteState(target) {
  await execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', `${PS_MUTE_SCRIPT}\n[AudioMute]::Set($${target ? 'true' : 'false'})`],
    { timeout: 10000 }
  );
}

/**
 * Set (or flip) the system mute state. Returns a result object on success,
 * or null when absolute control is unavailable (caller falls back to the
 * toggle media key).
 */
async function setMuteState(target /* true | false | null = flip */) {
  try {
    let state = target;
    if (state === null) state = !(await readMuteState());
    await writeMuteState(state);
    return { success: true, message: state ? 'Audio muted' : 'Audio unmuted' };
  } catch {
    return null;
  }
}

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
      case 'toggle_mute': {
        // Prefer absolute state over the toggle key so "unmute" can never mute.
        const target = act === 'mute' ? true : act === 'unmute' ? false : null;
        if (process.platform === 'win32') {
          const abs = await setMuteState(target);
          if (abs) return abs;
        }
        // Fallback: toggle key (state unknown — reported honestly).
        await keyboard.pressKey(Key.AudioMute);
        await keyboard.releaseKey(Key.AudioMute);
        return { success: true, message: 'Toggled audio mute (toggle key — absolute state unavailable)' };
      }

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
