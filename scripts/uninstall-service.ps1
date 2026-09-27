# Removes what install-service.ps1 created.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\uninstall-service.ps1
param([string]$TaskName = "PCVoiceAssistant")

try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Host "Removed Scheduled Task '$TaskName'." }
catch { Write-Host "No Scheduled Task '$TaskName' found (or already removed)." }

$Startup = [Environment]::GetFolderPath("Startup")
$Lnk = Join-Path $Startup "$TaskName.lnk"
if (Test-Path $Lnk) { Remove-Item $Lnk -Force; Write-Host "Removed startup shortcut." }
else { Write-Host "No startup shortcut found." }
