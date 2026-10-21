#Requires -Version 5.1
<#
.SYNOPSIS
    Installs, updates or uninstalls NtfyTray (ntfy client for the Windows tray). Per-user, no admin.

.DESCRIPTION
    One-liner (works only while the GitHub repo is PUBLIC):
        irm https://raw.githubusercontent.com/mezzanine78/ntfy-tray/main/install.ps1 | iex

    With options, e.g. uninstall:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mezzanine78/ntfy-tray/main/install.ps1))) -Uninstall

    From a clone or extracted release zip (private repo):
        gh repo clone mezzanine78/ntfy-tray; cd ntfy-tray
        powershell -ExecutionPolicy Bypass -File .\install.ps1

    What it does:
      1. Gets the app files: -SourcePath, else the src\ folder next to this script, else downloads
         the repo zip (-Ref branch/tag) from GitHub.
      2. Stops a running NtfyTray, copies the files to %LOCALAPPDATA%\NtfyTray.
      3. First install (or -Reconfigure): asks for server, topics and access token. The token is
         stored DPAPI-encrypted for your Windows user in %APPDATA%\NtfyTray\tokens - never in
         config.json. Updates keep the existing config and token.
      4. Registers the toast AppUserModelID, adds a Start-menu shortcut and the HKCU Run entry
         (autostart), and starts the app.

.PARAMETER Server        Server URL for a new config (skips the prompt).
.PARAMETER Topics        Topic(s) for a new config, comma-separated or an array (skips the prompt).
.PARAMETER NoToken       Server needs no token (public topics).
.PARAMETER Reconfigure   Ask for server/topics/token again even if a config exists.
.PARAMETER NoAutostart   Do not start with Windows.
.PARAMETER NoStart       Do not launch after installing.
.PARAMETER Uninstall     Remove the app, shortcut, autostart and toast registration.
.PARAMETER RemoveToken   With -Uninstall: also delete stored token(s).
.PARAMETER RemoveAll     With -Uninstall: also delete config, cursor state, tokens and log (%APPDATA%\NtfyTray).
.PARAMETER SourcePath    Folder containing NtfyTray.ps1 etc.
.PARAMETER Ref           Git branch or tag to download (default main).
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string[]]$Topics,
    [switch]$NoToken,
    [switch]$Reconfigure,
    [switch]$NoAutostart,
    [switch]$NoStart,
    [switch]$Uninstall,
    [switch]$RemoveToken,
    [switch]$RemoveAll,
    [string]$SourcePath,
    [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'
$Repo       = 'mezzanine78/ntfy-tray'
$AppName    = 'NtfyTray'
$AppId      = 'mezzanine78.NtfyTray'
$Files      = @('NtfyTray.ps1', 'NtfyTray.Core.psm1', 'NtfyTray.vbs', 'uninstall.ps1', 'emoji-tags.json', 'VERSION')
$InstallDir = Join-Path $env:LOCALAPPDATA $AppName
$DataDir    = Join-Path $env:APPDATA $AppName
$ConfigPath = Join-Path $DataDir 'config.json'
$Programs   = [Environment]::GetFolderPath('Programs')
if ([string]::IsNullOrEmpty($Programs)) { $Programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
$Shortcut   = Join-Path $Programs 'ntfy Tray.lnk'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Write-Step([string]$m) { Write-Host "[NtfyTray] $m" -ForegroundColor Cyan }

if ($env:OS -ne 'Windows_NT') { throw 'NtfyTray installs on Windows only.' }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Stop-NtfyTrayProcess {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'NtfyTray\.ps1' -and $_.CommandLine -notmatch '-SetToken' -and $_.ProcessId -ne $PID }
        foreach ($p in $procs) { Write-Step "Stopping running NtfyTray (PID $($p.ProcessId))"; Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        if ($procs) { Start-Sleep -Milliseconds 800 }
    } catch { Write-Warning "Could not check for a running NtfyTray: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    $u = Join-Path $InstallDir 'uninstall.ps1'
    if (Test-Path -LiteralPath $u) {
        & $u -RemoveToken:$RemoveToken -RemoveAll:$RemoveAll -Quiet
    } else {
        Stop-NtfyTrayProcess
        Remove-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Shortcut) { Remove-Item -LiteralPath $Shortcut -Force }
        Remove-Item -Path "HKCU:\Software\Classes\AppUserModelId\$AppId" -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
        if ($RemoveAll -and (Test-Path -LiteralPath $DataDir)) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
        elseif ($RemoveToken -and (Test-Path -LiteralPath (Join-Path $DataDir 'tokens'))) { Remove-Item -LiteralPath (Join-Path $DataDir 'tokens') -Recurse -Force }
        Write-Step 'Uninstalled.'
    }
    return
}

# ---------------------------------------------------------------- locate source
$src = $null
$tmp = $null
$candidates = @()
if ($SourcePath) { $candidates += $SourcePath }
elseif ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot 'src'); $candidates += $PSScriptRoot }
foreach ($c in $candidates) {
    $missing = @($Files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $c $_)) })
    if ($missing.Count -eq 0) { $src = (Resolve-Path -LiteralPath $c).Path; break }
}
if ($SourcePath -and -not $src) { throw "SourcePath '$SourcePath' does not contain all of: $($Files -join ', ')" }
if (-not $src) {
    $zipUrl = "https://github.com/$Repo/archive/$Ref.zip"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ntfytray-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'src.zip'
    Write-Step "Downloading $zipUrl"
    try { Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing }
    catch { throw ("Download failed ($($_.Exception.Message)). If the repo is private, clone it with 'gh repo clone $Repo' and run install.ps1 from the clone.") }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'NtfyTray.Core.psm1' | Select-Object -First 1
    if (-not $found) { throw 'Downloaded archive does not contain NtfyTray.Core.psm1.' }
    $src = $found.DirectoryName
}
Write-Step "Source: $src"

# ---------------------------------------------------------------- copy files
Stop-NtfyTrayProcess
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($f in $Files) {
    $dest = Join-Path $InstallDir $f
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination $dest -Force
    try { Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue } catch { }
}
if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
$version = (Get-Content -LiteralPath (Join-Path $InstallDir 'VERSION') -Raw).Trim()
Write-Step "Installed version $version to $InstallDir"

Import-Module (Join-Path $InstallDir 'NtfyTray.Core.psm1') -Force -DisableNameChecking
$paths = Get-NtfyTrayPaths

# ---------------------------------------------------------------- config + token
$isNew = -not (Test-Path -LiteralPath $ConfigPath)
if ($isNew -or $Reconfigure -or $Server -or $Topics) {
    $old = Read-NtfyTrayConfig -Path $ConfigPath
    $defServer = 'https://ntfy.sh'; if (@($old.Servers).Count) { $defServer = $old.Servers[0].Url }
    if (-not $Server) {
        $ans = Read-Host "ntfy server URL [$defServer]"
        if ([string]::IsNullOrWhiteSpace($ans)) { $Server = $defServer } else { $Server = $ans }
    }
    $Server = ConvertTo-NtfyServerUrl $Server
    if (-not $Topics) {
        $defTopics = (@($old.Topics | ForEach-Object { $_.Name }) -join ',')
        do {
            $ans = Read-Host "Topic(s) to subscribe, comma-separated [$defTopics]"
            if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $defTopics }
        } while ([string]::IsNullOrWhiteSpace($ans))
        $Topics = @($ans)
    }
    $topicList = @($Topics | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
    $bad = @($topicList | Where-Object { -not (Test-NtfyTopicName $_) })
    if ($bad.Count) { throw "Invalid topic name(s): $($bad -join ', ') (allowed: letters, digits, - and _, max 64)" }
    $auth = 'token'; if ($NoToken) { $auth = 'none' }
    $cfg = ConvertTo-NtfyTrayConfig $old
    $cfg.Servers = @([ordered]@{ Name = ([Uri]$Server).Host; Url = $Server; Auth = $auth })
    $cfg.Topics = @($topicList | ForEach-Object { [ordered]@{ Server = ([Uri]$Server).Host; Name = $_; DisplayName = ''; MinPriority = 0; Paused = $false; Enabled = $true } })
    $cfg.Autostart = -not $NoAutostart
    Save-NtfyTrayConfig -Path $ConfigPath -Config $cfg
    Write-Step "Config written: $ConfigPath"

    if ($auth -eq 'token') {
        $have = $null -ne (Get-NtfyToken -Server $Server -TokenDir $paths.TokenDir)
        $prompt = 'Access token (input hidden; blank = no token)'
        if ($have) { $prompt = 'Access token (input hidden; blank = keep the stored one)' }
        $sec = Read-Host -AsSecureString $prompt
        if ($sec.Length -gt 0) { [void](Set-NtfyToken -Server $Server -Token $sec -TokenDir $paths.TokenDir); $have = $true; Write-Step 'Token stored (DPAPI, current user).' }
        if ($have) {
            $hdr = Get-NtfyAuthHeader -Server $Server -TokenDir $paths.TokenDir
            $code = 0; try { $code = Test-NtfyAuth -Server $Server -Topic $topicList[0] -AuthHeader $hdr } catch { }
            $hdr = $null
            if ($code -eq 200) { Write-Step "Token accepted for '$($topicList[0])' (HTTP 200)." }
            else { Write-Warning "Auth check for '$($topicList[0])' returned HTTP $code. Fix later with: tray menu > Set access token..." }
        } else {
            $cfg.Servers[0].Auth = 'none'; Save-NtfyTrayConfig -Path $ConfigPath -Config $cfg
            Write-Step 'No token: subscribing anonymously.'
        }
    }
} else {
    Write-Step "Keeping existing config: $ConfigPath (use -Reconfigure to change it)"
    $cfg = Read-NtfyTrayConfig -Path $ConfigPath
    if ($NoAutostart) { $cfg.Autostart = $false; Save-NtfyTrayConfig -Path $ConfigPath -Config $cfg }
}

# ---------------------------------------------------------------- AUMID, shortcut, autostart
$aumid = "HKCU:\Software\Classes\AppUserModelId\$AppId"
if (-not (Test-Path $aumid)) { New-Item -Path $aumid -Force | Out-Null }
New-ItemProperty -Path $aumid -Name DisplayName -Value 'ntfy Tray' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $aumid -Name ShowInSettings -Value 1 -PropertyType DWord -Force | Out-Null

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$psExe   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$vbs     = Join-Path $InstallDir 'NtfyTray.vbs'
if (Test-Path -LiteralPath $wscript) { $target = $wscript; $arguments = "`"$vbs`"" }
else { $target = $psExe; $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $InstallDir 'NtfyTray.ps1')`"" }
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($Shortcut)
$lnk.TargetPath = $target; $lnk.Arguments = $arguments; $lnk.WorkingDirectory = $InstallDir
$lnk.IconLocation = "$psExe,0"; $lnk.Description = 'ntfy Tray - ntfy notifications in the Windows tray'
$lnk.Save()
Write-Step "Start-menu shortcut: $Shortcut"

if ($cfg.Autostart) {
    New-ItemProperty -Path $RunKey -Name $AppName -Value ("`"$target`" $arguments") -PropertyType String -Force | Out-Null
    Write-Step 'Start with Windows: on'
} else {
    Remove-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue
    Write-Step 'Start with Windows: off'
}

Write-Step "Uninstall later with: powershell -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""
if (-not $NoStart) {
    Start-Process -FilePath $target -ArgumentList $arguments -WorkingDirectory $InstallDir
    Write-Step 'Started - look for the round "n" icon in the tray (it may be in the ^ overflow).'
}
