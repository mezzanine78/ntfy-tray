#Requires -Version 5.1
<#
.SYNOPSIS
    NtfyTray - ntfy (https://ntfy.sh) client for the Windows 11 system tray.

.DESCRIPTION
    Subscribes to one or more topics on one or more ntfy servers (JSON stream, one
    connection per server), shows native Windows toast notifications mapped from ntfy
    priority / tags / click / view actions, and keeps a recent-messages list in the tray.
    Reconnects with backoff and resumes with since= so nothing is missed or duplicated
    after a network drop, sleep or restart.

    Config : %APPDATA%\NtfyTray\config.json
    Tokens : %APPDATA%\NtfyTray\tokens\<server>.token   (DPAPI, current Windows user only)
    Log    : %APPDATA%\NtfyTray\ntfytray.log

.PARAMETER SetToken     Prompt for (and store) the access token for each configured server, then exit.
.PARAMETER SelfTest     Check auth and poll the last hour for every configured server; prints counts only. Any OS.
.PARAMETER Console      Stream messages to the console instead of the tray (first server, or -Server). Any OS.
.PARAMETER ConfigPath   Use a different config.json (testing).
.PARAMETER TokenFromEnv Read the token from this environment variable instead of the DPAPI store (testing / CI). The value is never printed.
.PARAMETER DurationSec  -Console only: exit after this many seconds.
.PARAMETER MaxMessages  -Console only: exit after this many messages.

.EXAMPLE
    wscript.exe "$env:LOCALAPPDATA\NtfyTray\NtfyTray.vbs"          # normal start (hidden)
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\NtfyTray\NtfyTray.ps1" -SetToken
#>
[CmdletBinding()]
param(
    [switch]$SetToken,
    [switch]$SelfTest,
    [switch]$Console,
    [string]$ConfigPath,
    [string]$Server,
    [string]$TokenFromEnv,
    [int]$DurationSec = 0,
    [int]$MaxMessages = 0
)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'NtfyTray'
$script:AppTitle   = 'ntfy Tray'
$script:AppId      = 'mezzanine78.NtfyTray'
$script:AppDir     = $PSScriptRoot
$script:ModulePath = Join-Path $PSScriptRoot 'NtfyTray.Core.psm1'
$script:Repo       = 'mezzanine78/ntfy-tray'
$script:AppVersion = '0.0.0'
$verFile = Join-Path $PSScriptRoot 'VERSION'
if (Test-Path -LiteralPath $verFile) { $script:AppVersion = (Get-Content -LiteralPath $verFile -Raw).Trim() }

Import-Module $script:ModulePath -Force -DisableNameChecking
$script:Paths = Get-NtfyTrayPaths
if ($ConfigPath) { $script:Paths.ConfigPath = $ConfigPath }
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Write-NtfyLog {
    param([string]$Message)
    try {
        $dir = $script:Paths.DataDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lp = $script:Paths.LogPath
        if ((Test-Path -LiteralPath $lp) -and ((Get-Item -LiteralPath $lp).Length -gt 1MB)) { Move-Item -LiteralPath $lp -Destination ($lp + '.old') -Force }
        Add-Content -LiteralPath $lp -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch { }
}

$script:Config = Read-NtfyTrayConfig -Path $script:Paths.ConfigPath

# ---------------------------------------------------------------- -SetToken
if ($SetToken) {
    $cfg = $script:Config
    if (@($cfg.Servers).Count -eq 0) {
        $url = Read-Host 'ntfy server URL (e.g. https://ntfy.example.com)'
        $cfg = ConvertTo-NtfyTrayConfig @{ Server = $url; Topics = @() }
        Save-NtfyTrayConfig -Path $script:Paths.ConfigPath -Config $cfg
    }
    foreach ($s in @($cfg.Servers)) {
        Write-Host "Server $($s.Url)" -ForegroundColor Cyan
        $sec = Read-Host -AsSecureString '  Access token (input hidden; blank = keep current, "-" = remove)'
        if ($sec.Length -eq 0) { Write-Host '  unchanged'; continue }
        if ((ConvertTo-NtfyPlainToken $sec) -eq '-') { [void](Remove-NtfyToken -Server $s.Url -TokenDir $script:Paths.TokenDir); Write-Host '  removed'; continue }
        [void](Set-NtfyToken -Server $s.Url -Token $sec -TokenDir $script:Paths.TokenDir)
        $topic = @($cfg.Topics | Where-Object { $_.Server -eq $s.Name } | Select-Object -First 1)
        if ($topic) {
            $auth = Get-NtfyAuthHeader -Server $s.Url -TokenDir $script:Paths.TokenDir
            $code = 0; try { $code = Test-NtfyAuth -Server $s.Url -Topic $topic[0].Name -AuthHeader $auth } catch { }
            $auth = $null
            if ($code -eq 200) { Write-Host "  saved; token accepted for '$($topic[0].Name)' (HTTP 200)" -ForegroundColor Green }
            else { Write-Host "  saved, but the auth check for '$($topic[0].Name)' returned HTTP $code" -ForegroundColor Yellow }
        } else { Write-Host '  saved' }
    }
    try { Set-Content -LiteralPath $script:Paths.ReloadFlag -Value (Get-Date -Format o) } catch { }
    Write-Host 'Done. A running NtfyTray reconnects with the new token within a few seconds.'
    return
}

# ---------------------------------------------------------------- -SelfTest
if ($SelfTest) {
    $groups = @(Get-NtfySubscriptionGroups -Config $script:Config)
    Write-Output ('NtfyTray {0} self-test, PowerShell {1}, config {2}' -f $script:AppVersion, $PSVersionTable.PSVersion, $script:Paths.ConfigPath)
    if ($groups.Count -eq 0) { Write-Output 'No servers/topics configured.'; return }
    foreach ($g in $groups) {
        $auth = $null
        if ($g.Auth -eq 'token') { $auth = Get-NtfyAuthHeader -Server $g.Url -TokenDir $script:Paths.TokenDir -FromEnv $TokenFromEnv }
        Write-Output ('{0}: {1} topic(s), token {2}' -f $g.Url, $g.Topics.Count, $(if ($auth) { 'present' } else { 'none' }))
        foreach ($t in $g.Topics) {
            $code = 0; try { $code = Test-NtfyAuth -Server $g.Url -Topic $t -AuthHeader $auth } catch { }
            Write-Output ('  auth check {0}: HTTP {1}' -f $t, $code)
        }
        $p = Invoke-NtfyPoll -Server $g.Url -Topics $g.Topics -Since '1h' -AuthHeader $auth
        $auth = $null
        $byPri = ($p.Messages | Group-Object { $_.Priority } | Sort-Object Name | ForEach-Object { 'p{0}={1}' -f $_.Name, $_.Count }) -join ' '
        Write-Output ('  poll since=1h: HTTP {0}, {1} message(s) {2}' -f $p.StatusCode, @($p.Messages).Count, $byPri)
    }
    return
}

# ---------------------------------------------------------------- -Console
if ($Console) {
    $groups = @(Get-NtfySubscriptionGroups -Config $script:Config)
    if ($Server) { $groups = @($groups | Where-Object { $_.Url -eq (ConvertTo-NtfyServerUrl $Server) -or $_.Server -eq $Server }) }
    if ($groups.Count -eq 0) { throw 'No matching server/topics in config.' }
    $g = $groups[0]
    $ctl = [hashtable]::Synchronized(@{ Stop = $false; Status = 'starting'; Count = 0 })
    $script:ConsoleMax = $MaxMessages
    $tokenDir = $script:Paths.TokenDir
    $onMsg = {
        param($m, $bf)
        $ctl.Count++
        $c = Get-NtfyToastContent -Message $m
        $kind = 'LIVE'; if ($bf) { $kind = 'BACKFILL' }
        Write-Host ('[{0}] p{1} {2} | {3} | {4} | click={5} views={6} id={7}' -f $kind, $m.Priority, $m.Topic, $c.Title, ($c.Body -replace "`n", ' / '), $c.Click, @($c.Views).Count, $m.Id)
        if ($script:ConsoleMax -gt 0 -and $ctl.Count -ge $script:ConsoleMax) { $ctl.Stop = $true }
    }
    if ($DurationSec -gt 0) { $ctl.StopAt = (Get-Date).AddSeconds($DurationSec) }
    $log = { param($x) Write-Host ('# ' + $x) -ForegroundColor DarkGray }
    $cursorPath = Join-Path $script:Paths.StateDir ($g.Key + '.cursor.json')
    $tfe = $null; if ($g.Auth -eq 'token') { $tfe = $TokenFromEnv }
    Start-NtfySubscriber -Server $g.Url -Topics $g.Topics -OnMessage $onMsg -Control $ctl -CursorPath $cursorPath -TokenDir $tokenDir -TokenFromEnv $tfe -IdleTimeoutSec $script:Config.IdleTimeoutSec -Log $log
    return
}

# ================================================================ tray UI (Windows only)
if ($env:OS -ne 'Windows_NT') { throw 'The tray UI needs Windows. Use -SelfTest or -Console on other platforms.' }

$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\NtfyTray_mezzanine78', [ref]$createdNew)
if (-not $createdNew) { Write-NtfyLog 'Another instance is already running; exiting.'; return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('NtfyTrayNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NtfyTrayNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
}
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:EmojiMap = Get-NtfyEmojiMap

# ---------------------------------------------------------------- icon
$script:StatusColors = @{
    connected    = [System.Drawing.Color]::FromArgb(46, 125, 50)
    degraded     = [System.Drawing.Color]::FromArgb(249, 168, 37)
    disconnected = [System.Drawing.Color]::FromArgb(198, 40, 40)
    idle         = [System.Drawing.Color]::FromArgb(97, 97, 97)
}
$script:IconHandle = [IntPtr]::Zero

function New-NtfyBitmap {
    param([string]$Text, [System.Drawing.Color]$Back, [int]$Size = 32, [bool]$PausedMark = $false)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)
        $b = New-Object System.Drawing.SolidBrush($Back)
        $g.FillEllipse($b, 0, 0, $Size - 1, $Size - 1); $b.Dispose()
        $fmt = [System.Drawing.StringFormat]::GenericTypographic
        $font = $null
        for ($fs = [float]($Size * 0.7); $fs -ge 6; $fs -= 0.5) {
            if ($font) { $font.Dispose() }
            $font = New-Object System.Drawing.Font('Segoe UI', $fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $m = $g.MeasureString($Text, $font, 1000, $fmt)
            if ($m.Width -le ($Size - 6) -and $m.Height -le ($Size - 4)) { break }
        }
        $m = $g.MeasureString($Text, $font, 1000, $fmt)
        $g.DrawString($Text, $font, [System.Drawing.Brushes]::White, [float](($Size - $m.Width) / 2), [float](($Size - $m.Height) / 2), $fmt)
        $font.Dispose()
        if ($PausedMark) {
            $pb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 40, 40, 40))
            $g.FillRectangle($pb, $Size - 12, $Size - 12, 12, 12); $pb.Dispose()
            $g.FillRectangle([System.Drawing.Brushes]::White, $Size - 10, $Size - 10, 3, 8)
            $g.FillRectangle([System.Drawing.Brushes]::White, $Size - 5, $Size - 10, 3, 8)
        }
    } finally { $g.Dispose() }
    return $bmp
}

function Set-TrayIcon {
    param([string]$Text, [string]$Status)
    $col = $script:StatusColors[$Status]; if (-not $col) { $col = $script:StatusColors.idle }
    $size = [Math]::Max(32, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
    $bmp = New-NtfyBitmap -Text $Text -Back $col -Size $size -PausedMark ([bool]($script:Config.Paused -or $script:RuntimePaused))
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($h)
    $oldIcon = $script:Notify.Icon; $oldHandle = $script:IconHandle
    $script:Notify.Icon = $icon; $script:IconHandle = $h
    if ($oldIcon) { $oldIcon.Dispose() }
    if ($oldHandle -ne [IntPtr]::Zero) { [void][NtfyTrayNative]::DestroyIcon($oldHandle) }
}

# ---------------------------------------------------------------- toasts
$script:ToastMode = 'balloon'
$script:Notifier = $null
$script:BalloonUrl = $null

function Register-NtfyAppId {
    # HKCU AppUserModelId registration lets Windows attribute toasts to "ntfy Tray" (no admin, no COM server).
    try {
        $png = Join-Path $script:Paths.DataDir 'ntfytray.png'
        if (-not (Test-Path -LiteralPath $png)) {
            if (-not (Test-Path -LiteralPath $script:Paths.DataDir)) { New-Item -ItemType Directory -Path $script:Paths.DataDir -Force | Out-Null }
            $bmp = New-NtfyBitmap -Text 'n' -Back $script:StatusColors.connected -Size 64
            $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        }
        $key = "HKCU:\Software\Classes\AppUserModelId\$($script:AppId)"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name DisplayName -Value $script:AppTitle -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name IconUri -Value $png -PropertyType ExpandString -Force | Out-Null
        New-ItemProperty -Path $key -Name ShowInSettings -Value 1 -PropertyType DWord -Force | Out-Null
    } catch { Write-NtfyLog ('AppId registration failed: ' + $_.Exception.Message) }
}

function Initialize-Toasts {
    Register-NtfyAppId
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
            $script:Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:AppId)
            $script:ToastMode = 'winrt'
        } catch { Write-NtfyLog ('WinRT toasts unavailable: ' + $_.Exception.Message) }
    }
    if ($script:ToastMode -eq 'balloon') {
        try {
            if (Get-Module -ListAvailable -Name BurntToast) { Import-Module BurntToast -ErrorAction Stop; $script:ToastMode = 'burnttoast' }
        } catch { Write-NtfyLog ('BurntToast import failed: ' + $_.Exception.Message) }
    }
    Write-NtfyLog "Toast backend: $($script:ToastMode)"
}

function Show-WinRtToast {
    param([string]$Xml, [string]$Tag, [string]$Group)
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($Xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)
    if ($Tag) { $toast.Tag = $Tag.Substring(0, [Math]::Min(64, $Tag.Length)) }
    if ($Group) { $toast.Group = $Group.Substring(0, [Math]::Min(64, $Group.Length)) }
    $script:Notifier.Show($toast)
}

function Show-BurntToast {
    param($Content)
    $cmd = Get-Command New-BurntToastNotification
    $p = @{ Text = @($Content.Title, $Content.Body, $Content.Attribution) | Where-Object { $_ } | Select-Object -First 3 }
    if ($cmd.Parameters.ContainsKey('AppId')) { $p.AppId = $script:AppId }
    $pi = $Content.Priority
    if ($pi.Silent -and $cmd.Parameters.ContainsKey('Silent')) { $p.Silent = $true }
    elseif ($pi.Level -eq 5 -and $cmd.Parameters.ContainsKey('Sound')) { $p.Sound = 'Alarm' }
    elseif ($pi.Level -eq 4 -and $cmd.Parameters.ContainsKey('Sound')) { $p.Sound = 'Reminder' }
    if ($pi.Level -eq 5 -and $cmd.Parameters.ContainsKey('Urgent')) { $p.Urgent = $true }
    $buttons = @()
    if (Get-Command New-BTButton -ErrorAction SilentlyContinue) {
        $links = @()
        if ($Content.Click) { $links += @{ Label = 'Open'; Url = $Content.Click } }
        $links += @($Content.Views)
        foreach ($v in ($links | Select-Object -First 4)) { $buttons += New-BTButton -Content $v.Label -Arguments $v.Url -ActivationType Protocol }
        if ($pi.Level -ge 4) { $buttons += New-BTButton -Dismiss }
    }
    if ($buttons.Count -and $cmd.Parameters.ContainsKey('Button')) { $p.Button = $buttons }
    New-BurntToastNotification @p
}

function Show-Balloon {
    param($Content)
    $icon = [System.Windows.Forms.ToolTipIcon]::Info
    if ($Content.Priority.Level -ge 5) { $icon = [System.Windows.Forms.ToolTipIcon]::Error }
    elseif ($Content.Priority.Level -eq 4) { $icon = [System.Windows.Forms.ToolTipIcon]::Warning }
    elseif ($Content.Priority.Level -le 2) { $icon = [System.Windows.Forms.ToolTipIcon]::None }
    $script:BalloonUrl = $Content.Click
    if (-not $script:BalloonUrl -and @($Content.Views).Count) { $script:BalloonUrl = $Content.Views[0].Url }
    $body = $Content.Body; if (-not $body) { $body = ' ' }
    $script:Notify.ShowBalloonTip(10000, $Content.Title, $body, $icon)
}

function Show-NtfyToast {
    param($Item)
    $m = $Item.Message
    $label = Get-TopicLabel -Server $Item.Server -Topic $m.Topic
    try {
        if ($script:ToastMode -eq 'winrt') {
            Show-WinRtToast -Xml (New-NtfyToastXml -Message $m -TopicLabel $label -EmojiMap $script:EmojiMap) -Tag $m.Id -Group $m.Topic
            return
        }
        $c = Get-NtfyToastContent -Message $m -TopicLabel $label -EmojiMap $script:EmojiMap
        if ($script:ToastMode -eq 'burnttoast') { Show-BurntToast $c } else { Show-Balloon $c }
    } catch {
        Write-NtfyLog ("Toast ($($script:ToastMode)) failed: " + $_.Exception.Message)
        try { Show-Balloon (Get-NtfyToastContent -Message $m -TopicLabel $label -EmojiMap $script:EmojiMap) } catch { }
    }
}

function Show-SummaryToast {
    param([hashtable]$Counts)
    try {
        if ($script:ToastMode -eq 'winrt') { Show-WinRtToast -Xml (New-NtfySummaryToastXml -CountsByTopic $Counts) -Tag 'backfill-summary' -Group 'ntfytray-summary'; return }
        $total = 0; foreach ($v in $Counts.Values) { $total += $v }
        $fake = @{ Title = "$total message(s) while you were away"; Body = (($Counts.Keys | ForEach-Object { "$_ ($($Counts[$_]))" }) -join ', '); Attribution = ''; Priority = (Get-NtfyPriorityInfo 2); Click = $null; Views = @() }
        if ($script:ToastMode -eq 'burnttoast') { Show-BurntToast $fake } else { Show-Balloon $fake }
    } catch { Write-NtfyLog ('Summary toast failed: ' + $_.Exception.Message) }
}

function Get-TopicLabel {
    param([string]$Server, [string]$Topic)
    $tc = Get-NtfyTopicConfig -Config $script:Config -Server $Server -Topic $Topic
    if ($tc -and $tc.DisplayName) { return $tc.DisplayName }
    return $Topic
}

function Open-SafeUrl {
    param([string]$Url)
    if (Test-NtfySafeUrl $Url) { try { Start-Process $Url } catch { Write-NtfyLog ('Open URL failed: ' + $_.Exception.Message) } }
}

# ---------------------------------------------------------------- autostart
function Get-LauncherCommand {
    $vbs = Join-Path $script:AppDir 'NtfyTray.vbs'
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if ((Test-Path -LiteralPath $vbs) -and (Test-Path -LiteralPath $wscript)) { return ('"{0}" "{1}"' -f $wscript, $vbs) }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $ps, (Join-Path $script:AppDir 'NtfyTray.ps1'))
}
function Test-Autostart { try { return $null -ne (Get-ItemProperty -Path $script:RunKey -Name $script:AppName -ErrorAction Stop).$($script:AppName) } catch { return $false } }
function Set-Autostart {
    param([bool]$Enabled)
    try {
        if ($Enabled) { New-ItemProperty -Path $script:RunKey -Name $script:AppName -Value (Get-LauncherCommand) -PropertyType String -Force | Out-Null }
        else { Remove-ItemProperty -Path $script:RunKey -Name $script:AppName -ErrorAction SilentlyContinue }
    } catch { Write-NtfyLog ('Run key: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- workers (one background runspace per server)
$script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Workers = @()
$script:WorkerScript = {
    param($ModulePath, $Group, $Ctl, $Queue, $CursorPath, $TokenDir, $IdleTimeoutSec, $LogPath)
    Import-Module $ModulePath -DisableNameChecking
    $log = { param($m) try { Add-Content -LiteralPath $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  [{1}] {2}' -f (Get-Date), $Group.Server, $m) } catch { } }
    $onMsg = { param($m, $bf) $Queue.Enqueue(@{ Server = $Group.Server; Message = $m; IsBackfill = $bf; Received = Get-Date }) }
    try {
        Start-NtfySubscriber -Server $Group.Url -Topics $Group.Topics -OnMessage $onMsg -Control $Ctl -CursorPath $CursorPath -TokenDir $TokenDir -IdleTimeoutSec $IdleTimeoutSec -Log $log
    } catch {
        $Ctl.Status = 'crashed'; $Ctl.LastError = $_.Exception.Message
        & $log ('Worker crashed: ' + $_.Exception.Message)
    }
}

function Start-Workers {
    foreach ($g in @(Get-NtfySubscriptionGroups -Config $script:Config)) {
        $ctl = [hashtable]::Synchronized(@{ Stop = $false; ReconnectNow = $false; Status = 'connecting'; LastError = $null; Attempts = 0 })
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $auth = 'token'; if ($g.Auth -eq 'none') { $auth = $null }
        $tokenDir = $script:Paths.TokenDir
        if (-not $auth) { $tokenDir = Join-Path $script:Paths.DataDir 'no-token' }   # auth = none: look in an empty dir
        $cursor = Join-Path $script:Paths.StateDir ($g.Key + '.cursor.json')
        [void]$ps.AddScript($script:WorkerScript).AddArgument($script:ModulePath).AddArgument($g).AddArgument($ctl).AddArgument($script:Queue).AddArgument($cursor).AddArgument($tokenDir).AddArgument($script:Config.IdleTimeoutSec).AddArgument($script:Paths.LogPath)
        $h = $ps.BeginInvoke()
        $script:Workers += @{ Group = $g; Ctl = $ctl; PS = $ps; RS = $rs; Handle = $h }
        Write-NtfyLog ('Started worker for {0}: {1}' -f $g.Url, ($g.Topics -join ','))
    }
}

function Stop-Workers {
    foreach ($w in $script:Workers) { $w.Ctl.Stop = $true }
    $until = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $until -and @($script:Workers | Where-Object { -not $_.Handle.IsCompleted }).Count) { Start-Sleep -Milliseconds 100 }
    foreach ($w in $script:Workers) {
        try { if (-not $w.Handle.IsCompleted) { [void]$w.PS.BeginStop($null, $null) } else { [void]$w.PS.EndInvoke($w.Handle) } } catch { }
        try { $w.PS.Dispose() } catch { }
        try { $w.RS.Dispose() } catch { }
    }
    $script:Workers = @()
}

function Restart-Workers {
    Stop-Workers
    $script:Config = Read-NtfyTrayConfig -Path $script:Paths.ConfigPath
    Start-Workers
    Update-Ui -Force
}

function Get-OverallStatus {
    if (@($script:Workers).Count -eq 0) { return 'idle' }
    $conn = @($script:Workers | Where-Object { $_.Ctl.Status -eq 'connected' }).Count
    if ($conn -eq @($script:Workers).Count) { return 'connected' }
    if ($conn -gt 0 -or @($script:Workers | Where-Object { $_.Ctl.Status -in 'connecting', 'reconnecting' }).Count) { return 'degraded' }
    return 'disconnected'
}

# ---------------------------------------------------------------- message handling
$script:Recent = New-Object System.Collections.ArrayList
$script:Unread = 0
$script:RuntimePaused = $false
$script:Summary = @{}
$script:SummaryLast = [datetime]::MinValue

function Receive-QueuedMessages {
    $item = $null; $changed = $false; $n = 0
    while ($n -lt 200 -and $script:Queue.TryDequeue([ref]$item)) {
        $n++; $changed = $true
        $m = $item.Message
        $script:Recent.Insert(0, $item)
        while ($script:Recent.Count -gt $script:Config.RecentCount) { $script:Recent.RemoveAt($script:Recent.Count - 1) }
        $script:Unread++
        if (Test-NtfyShouldNotify -Message $m -Config $script:Config -Server $item.Server -RuntimePaused $script:RuntimePaused) {
            if ($item.IsBackfill -and $script:Config.CatchUpSummary) {
                $label = Get-TopicLabel -Server $item.Server -Topic $m.Topic
                if ($script:Summary.ContainsKey($label)) { $script:Summary[$label]++ } else { $script:Summary[$label] = 1 }
                $script:SummaryLast = Get-Date
            } else {
                Show-NtfyToast $item
            }
        }
    }
    # Debounced catch-up summary: fire once the backfill burst has been quiet for 2 s.
    if ($script:Summary.Count -and ((Get-Date) - $script:SummaryLast).TotalSeconds -ge 2) {
        Show-SummaryToast $script:Summary
        $script:Summary = @{}
    }
    return $changed
}

# ---------------------------------------------------------------- recent-messages window
$script:RecentForm = $null
function Show-RecentWindow {
    if ($script:RecentForm -and -not $script:RecentForm.IsDisposed) { Update-RecentWindow; $script:RecentForm.Activate(); return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "$($script:AppTitle) - recent messages"; $f.Width = 900; $f.Height = 480; $f.StartPosition = 'CenterScreen'
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Dock = 'Fill'; $lv.HideSelection = $false
    foreach ($col in @(@('Time', 110), @('Topic', 140), @('Pri', 60), @('Title', 220), @('Message', 360))) { [void]$lv.Columns.Add($col[0], $col[1]) }
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel; $panel.Dock = 'Bottom'; $panel.Height = 38; $panel.FlowDirection = 'RightToLeft'
    $bClose = New-Object System.Windows.Forms.Button; $bClose.Text = 'Close'; $bClose.Add_Click({ $script:RecentForm.Close() })
    $bOpen = New-Object System.Windows.Forms.Button; $bOpen.Text = 'Open link'; $bOpen.Width = 90
    $bOpen.Add_Click({ $sel = $script:RecentList.SelectedItems; if ($sel.Count) { Invoke-RecentItem $sel[0].Tag } })
    $bCopy = New-Object System.Windows.Forms.Button; $bCopy.Text = 'Copy text'; $bCopy.Width = 90
    $bCopy.Add_Click({ $sel = $script:RecentList.SelectedItems; if ($sel.Count) { $m = $sel[0].Tag.Message; [System.Windows.Forms.Clipboard]::SetText(("{0}`r`n{1}" -f $m.Title, $m.Message).Trim()) } })
    [void]$panel.Controls.Add($bClose); [void]$panel.Controls.Add($bOpen); [void]$panel.Controls.Add($bCopy)
    $lv.Add_DoubleClick({ $sel = $script:RecentList.SelectedItems; if ($sel.Count) { Invoke-RecentItem $sel[0].Tag } })
    $f.Controls.Add($lv); $f.Controls.Add($panel)
    $script:RecentForm = $f; $script:RecentList = $lv
    Update-RecentWindow
    $script:Unread = 0; Update-Ui -Force
    $f.Show()
}

function Update-RecentWindow {
    if (-not $script:RecentForm -or $script:RecentForm.IsDisposed) { return }
    $lv = $script:RecentList
    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($it in $script:Recent) {
        $m = $it.Message
        $tags = ConvertTo-NtfyTagText -Tags $m.Tags -Map $script:EmojiMap
        $title = $m.Title; if ($tags.Emojis) { $title = $tags.Emojis + ' ' + $title }
        $row = New-Object System.Windows.Forms.ListViewItem([DateTimeOffset]::FromUnixTimeSeconds($m.Time).ToLocalTime().ToString('dd MMM HH:mm:ss'))
        [void]$row.SubItems.Add((Get-TopicLabel -Server $it.Server -Topic $m.Topic))
        [void]$row.SubItems.Add((Get-NtfyPriorityInfo $m.Priority).Label)
        [void]$row.SubItems.Add($title)
        [void]$row.SubItems.Add(($m.Message -replace '\s+', ' '))
        $row.Tag = $it
        if ($m.Priority -ge 5) { $row.ForeColor = [System.Drawing.Color]::DarkRed } elseif ($m.Priority -ge 4) { $row.ForeColor = [System.Drawing.Color]::DarkOrange }
        [void]$lv.Items.Add($row)
    }
    $lv.EndUpdate()
}

function Invoke-RecentItem {
    param($Item)
    $m = $Item.Message
    $c = Get-NtfyToastContent -Message $m -EmojiMap $script:EmojiMap
    if ($c.Click) { Open-SafeUrl $c.Click; return }
    if (@($c.Views).Count) { Open-SafeUrl $c.Views[0].Url; return }
    [void][System.Windows.Forms.MessageBox]::Show(("{0}`r`n`r`n{1}" -f $c.Body, $c.Attribution), $c.Title)
}

# ---------------------------------------------------------------- tray menu
$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$miTitle = New-Object System.Windows.Forms.ToolStripMenuItem("$($script:AppTitle) $($script:AppVersion)"); $miTitle.Enabled = $false
[void]$script:Menu.Items.Add($miTitle)
$script:MiStatusAnchor = New-Object System.Windows.Forms.ToolStripSeparator
[void]$script:Menu.Items.Add($script:MiStatusAnchor)
$script:StatusItems = @()

$script:MiRecent = New-Object System.Windows.Forms.ToolStripMenuItem('Recent messages')
[void]$script:Menu.Items.Add($script:MiRecent)
$miShowAll = New-Object System.Windows.Forms.ToolStripMenuItem('Show recent messages...'); $miShowAll.Add_Click({ Show-RecentWindow })
[void]$script:Menu.Items.Add($miShowAll)
$miRead = New-Object System.Windows.Forms.ToolStripMenuItem('Mark all read'); $miRead.Add_Click({ $script:Unread = 0; Update-Ui -Force })
[void]$script:Menu.Items.Add($miRead)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:MiPause = New-Object System.Windows.Forms.ToolStripMenuItem('Pause notifications')
$script:MiPause.Add_Click({
    if ($script:Config.Paused) { $script:Config.Paused = $false; $script:RuntimePaused = $false }
    else { $script:RuntimePaused = -not $script:RuntimePaused }
    Update-Ui -Force
})
[void]$script:Menu.Items.Add($script:MiPause)
$miReconnect = New-Object System.Windows.Forms.ToolStripMenuItem('Reconnect all'); $miReconnect.Add_Click({ Restart-Workers })
[void]$script:Menu.Items.Add($miReconnect)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:MiStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
$script:MiStartup.Add_Click({
    $on = -not (Test-Autostart)
    Set-Autostart $on
    $script:Config.Autostart = $on
    try { Save-NtfyTrayConfig -Path $script:Paths.ConfigPath -Config $script:Config } catch { Write-NtfyLog ('Save config: ' + $_.Exception.Message) }
    Update-Ui -Force
})
[void]$script:Menu.Items.Add($script:MiStartup)
$miToken = New-Object System.Windows.Forms.ToolStripMenuItem('Set access token...')
$miToken.Add_Click({
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -SetToken' -f (Join-Path $script:AppDir 'NtfyTray.ps1'))
})
[void]$script:Menu.Items.Add($miToken)
$miConfig = New-Object System.Windows.Forms.ToolStripMenuItem('Open config file')
$miConfig.Add_Click({
    if (-not (Test-Path -LiteralPath $script:Paths.ConfigPath)) { Save-NtfyTrayConfig -Path $script:Paths.ConfigPath -Config $script:Config }
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:Paths.ConfigPath)
})
[void]$script:Menu.Items.Add($miConfig)
$miReload = New-Object System.Windows.Forms.ToolStripMenuItem('Reload config'); $miReload.Add_Click({ Restart-Workers })
[void]$script:Menu.Items.Add($miReload)
$miLog = New-Object System.Windows.Forms.ToolStripMenuItem('Open log')
$miLog.Add_Click({ Write-NtfyLog 'Log opened from tray'; Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:Paths.LogPath) })
[void]$script:Menu.Items.Add($miLog)
$miUpdate = New-Object System.Windows.Forms.ToolStripMenuItem('Check for updates...'); $miUpdate.Add_Click({ Invoke-UpdateCheck })
[void]$script:Menu.Items.Add($miUpdate)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem('Exit'); $miExit.Add_Click({ Stop-NtfyTray })
[void]$script:Menu.Items.Add($miExit)

function Invoke-UpdateCheck {
    $raw = "https://raw.githubusercontent.com/$($script:Repo)/main"
    try {
        $r = Invoke-NtfyGet -Url "$raw/src/VERSION" -TimeoutSec 15
        if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode) (the repo must be public for update checks)" }
        $latest = [version]($r.Body.Trim()); $current = [version]$script:AppVersion
        if ($latest -le $current) { [void][System.Windows.Forms.MessageBox]::Show("You're up to date ($current).", $script:AppTitle); return }
        $ans = [System.Windows.Forms.MessageBox]::Show("Version $latest is available (you have $current).`r`n`r`nUpdate now? Your config and token are kept.", $script:AppTitle, 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Start-Process -FilePath $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Command "irm {0}/install.ps1 | iex"' -f $raw)
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Update check failed: $($_.Exception.Message)`r`n`r`nTo update manually, re-run the install command from the README.", $script:AppTitle)
    }
}

$script:LastUiKey = ''
function Update-Ui {
    param([switch]$Force)
    $overall = Get-OverallStatus
    $paused = [bool]($script:Config.Paused -or $script:RuntimePaused)
    $statusKey = ($script:Workers | ForEach-Object { '{0}={1}' -f $_.Group.Server, $_.Ctl.Status }) -join ';'
    $key = '{0}|{1}|{2}|{3}|{4}' -f $overall, $paused, $script:Unread, $statusKey, $script:Recent.Count
    if (-not $Force -and $key -eq $script:LastUiKey) { return }
    $script:LastUiKey = $key

    $txt = 'n'
    if ($script:Unread -gt 0) { $txt = [string][Math]::Min($script:Unread, 99) }
    Set-TrayIcon -Text $txt -Status $overall

    $word = @{ connected = 'connected'; degraded = 'reconnecting'; disconnected = 'disconnected'; idle = 'no topics configured' }[$overall]
    $tip = "$($script:AppTitle) - $word"
    if ($paused) { $tip += ', paused' }
    if ($script:Unread -gt 0) { $tip += ", $($script:Unread) unread" }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $script:Notify.Text = $tip

    foreach ($si in $script:StatusItems) { $script:Menu.Items.Remove($si); $si.Dispose() }
    $script:StatusItems = @()
    $idx = $script:Menu.Items.IndexOf($script:MiStatusAnchor)
    foreach ($w in $script:Workers) {
        $c = $w.Ctl
        $line = '{0}: {1} ({2} topic{3})' -f ([Uri]$w.Group.Url).Host, $c.Status, $w.Group.Topics.Count, $(if ($w.Group.Topics.Count -ne 1) { 's' } else { '' })
        $si = New-Object System.Windows.Forms.ToolStripMenuItem($line); $si.Enabled = $false
        if ($c.LastError -and $c.Status -ne 'connected') { $si.ToolTipText = [string]$c.LastError }
        $script:Menu.Items.Insert($idx, $si); $idx++
        $script:StatusItems += $si
    }
    if (@($script:Workers).Count -eq 0) {
        $si = New-Object System.Windows.Forms.ToolStripMenuItem('No topics - open config file'); $si.Enabled = $false
        $script:Menu.Items.Insert($idx, $si); $script:StatusItems += $si
    }

    $script:MiRecent.DropDownItems.Clear()
    if ($script:Recent.Count -eq 0) {
        $e = New-Object System.Windows.Forms.ToolStripMenuItem('(none yet)'); $e.Enabled = $false; [void]$script:MiRecent.DropDownItems.Add($e)
    } else {
        foreach ($it in @($script:Recent | Select-Object -First 15)) {
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem((Format-NtfyRecentLine -Message $it.Message -EmojiMap $script:EmojiMap))
            $mi.Tag = $it
            $mi.Add_Click({ param($src, $evt) Invoke-RecentItem $src.Tag })
            [void]$script:MiRecent.DropDownItems.Add($mi)
        }
    }
    $script:MiRecent.Text = 'Recent messages'
    if ($script:Unread -gt 0) { $script:MiRecent.Text += " ($($script:Unread) unread)" }
    if ($paused) { $script:MiPause.Text = 'Resume notifications' } else { $script:MiPause.Text = 'Pause notifications' }
    $script:MiStartup.Checked = Test-Autostart
    Update-RecentWindow
}

$script:Notify.ContextMenuStrip = $script:Menu
$script:Notify.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-RecentWindow } })
$script:Notify.Add_BalloonTipClicked({ if ($script:BalloonUrl) { Open-SafeUrl $script:BalloonUrl } })

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 500
$script:Tick = 0
$script:Timer.Add_Tick({
    try {
        $script:Tick++
        $changed = Receive-QueuedMessages
        if (($script:Tick % 4) -eq 0 -and (Test-Path -LiteralPath $script:Paths.ReloadFlag)) {
            Remove-Item -LiteralPath $script:Paths.ReloadFlag -Force -ErrorAction SilentlyContinue
            Write-NtfyLog 'Reload requested (token/config changed)'
            Restart-Workers
        }
        Update-Ui -Force:$changed
    } catch { Write-NtfyLog ('Timer: ' + $_.Exception.Message) }
})

function Stop-NtfyTray {
    try { $script:Timer.Stop() } catch { }
    Write-NtfyLog 'Exiting'
    Stop-Workers
    try { $script:Notify.Visible = $false; $script:Notify.Dispose() } catch { }
    if ($script:IconHandle -ne [IntPtr]::Zero) { [void][NtfyTrayNative]::DestroyIcon($script:IconHandle) }
    try { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } catch { }
    [System.Windows.Forms.Application]::ExitThread()
}

# ---------------------------------------------------------------- start
Write-NtfyLog "NtfyTray $($script:AppVersion) started (PowerShell $($PSVersionTable.PSVersion))"
Initialize-Toasts
if ($script:Config.Autostart -ne (Test-Autostart)) { Set-Autostart $script:Config.Autostart }
Set-TrayIcon -Text 'n' -Status 'idle'
$script:Notify.Text = "$($script:AppTitle) - starting"
$script:Notify.Visible = $true
Start-Workers
Update-Ui -Force
if (@($script:Workers).Count -eq 0) {
    $script:Notify.ShowBalloonTip(8000, $script:AppTitle, 'No topics configured yet. Right-click the tray icon > Open config file.', [System.Windows.Forms.ToolTipIcon]::Info)
}
$script:Timer.Start()
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
