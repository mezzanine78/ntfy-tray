#Requires -Version 5.1
<#
.SYNOPSIS  Removes NtfyTray: app files, Start-menu shortcut, autostart entry and toast registration.
.PARAMETER RemoveToken  Also delete the stored access token(s).
.PARAMETER RemoveAll    Also delete %APPDATA%\NtfyTray (config, cursor state, tokens, log).
.PARAMETER Quiet        Do not ask questions.
#>
[CmdletBinding()]
param([switch]$RemoveToken, [switch]$RemoveAll, [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$AppName    = 'NtfyTray'
$InstallDir = Join-Path $env:LOCALAPPDATA $AppName
$DataDir    = Join-Path $env:APPDATA $AppName
$Programs   = [Environment]::GetFolderPath('Programs')
if ([string]::IsNullOrEmpty($Programs)) { $Programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
$Shortcut   = Join-Path $Programs 'ntfy Tray.lnk'
function Write-Step([string]$m) { Write-Host "[NtfyTray] $m" -ForegroundColor Cyan }

if (-not $Quiet -and -not $RemoveAll -and -not $RemoveToken -and (Test-Path -LiteralPath (Join-Path $DataDir 'tokens'))) {
    $a = Read-Host 'Also delete the stored access token? [y/N]'
    if ($a -match '^(y|yes)$') { $RemoveToken = $true }
}

try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'NtfyTray\.ps1' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Write-Step "Stopping PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
Start-Sleep -Milliseconds 500
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $AppName -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $Shortcut) { Remove-Item -LiteralPath $Shortcut -Force }
Remove-Item -Path 'HKCU:\Software\Classes\AppUserModelId\mezzanine78.NtfyTray' -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
if ($RemoveAll) {
    if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
    Write-Step 'Removed app and all data (config, state, tokens, log).'
} else {
    if ($RemoveToken -and (Test-Path -LiteralPath (Join-Path $DataDir 'tokens'))) { Remove-Item -LiteralPath (Join-Path $DataDir 'tokens') -Recurse -Force; Write-Step 'Removed stored token(s).' }
    Write-Step "Removed app. Settings kept in $DataDir (delete with -RemoveAll)."
}
