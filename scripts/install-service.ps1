# Installs the PC Voice Assistant to run in the USER session at logon.
# Why a Scheduled Task and not a Windows Service?
#   Windows Services run in Session 0 (isolated, no interactive desktop), so
#   nut-js mouse/keyboard control would silently fail. A Scheduled Task with
#   LogonTrigger runs in the user's session with desktop access.
#
# Usage (elevated PowerShell recommended, but per-user task works unelevated):
#   powershell -ExecutionPolicy Bypass -File scripts\install-service.ps1
# Options:
#   -TaskName "PCVoiceAssistant" -ProjectDir "C:\path\to\pc_assistant"

param(
  [string]$TaskName = "PCVoiceAssistant",
  [string]$ProjectDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ProjectDir)) {
  # Fallback: assume script lives in <project>\scripts
  $ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExe) { throw "node not found on PATH. Install Node.js 18+ first." }

# Wrapper: start server + agent together, restart on crash
$Wrapper = Join-Path $ProjectDir "scripts\run-assistant.cmd"
@"
@echo off
cd /d "$ProjectDir"
where npm >nul 2>nul || exit /b 1
start "pc-assistant-server" /min cmd /c "npm start"
timeout /t 3 /nobreak >nul
start "pc-assistant-agent" /min cmd /c "npm run agent"
"@ | Set-Content -Path $Wrapper -Encoding ASCII

# Scheduled Task: at logon, in user session, run wrapper
$Action = New-ScheduledTaskAction -Execute $Wrapper
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$Principal = New-ScheduledTaskPrincipal -GroupId "Users" -RunLevel Limited

try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description "PC Voice Assistant (user-session, avoids Session 0 isolation)" | Out-Null

# Optional: Startup folder shortcut as a second autostart path
$Startup = [Environment]::GetFolderPath("Startup")
$Wsh = New-Object -ComObject WScript.Shell
$Shortcut = $Wsh.CreateShortcut((Join-Path $Startup "$TaskName.lnk"))
$Shortcut.TargetPath = $Wrapper
$Shortcut.WorkingDirectory = $ProjectDir
$Shortcut.Description = "PC Voice Assistant"
$Shortcut.Save()

Write-Host "Installed '$TaskName':"
Write-Host "  - Scheduled Task (AtLogOn, user session): $TaskName"
Write-Host "  - Startup shortcut: $(Join-Path $Startup "$TaskName.lnk")"
Write-Host "  - Wrapper: $Wrapper"
Write-Host ""
Write-Host "Start now with: Start-ScheduledTask -TaskName $TaskName"
Write-Host "Uninstall with: powershell -File scripts\uninstall-service.ps1"
