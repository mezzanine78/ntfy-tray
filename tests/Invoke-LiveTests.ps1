<#
  Live tests for the NtfyTray stream code (run on the build box, any OS, pwsh 7).
    -LocalUrl  : a local unauthenticated ntfy server (e.g. ntfy serve) - publish, reconnect,
                 since= resume, dedupe and idle-timeout (SIGSTOP) tests. -ServerPid enables
                 the restart/idle tests (Linux only).
    -NtfySh    : end-to-end on a random throwaway topic on the public https://ntfy.sh.
    -ReadOnlyServer/-ReadOnlyTopic/-TokenEnv : read-only checks against a private server
                 (auth endpoint, poll since=1h, a short stream connect). Prints HTTP status and
                 counts only; never publishes; the token is read from the env var and never printed.
#>
param(
    [string]$LocalUrl,
    [int]$ServerPid,
    [string]$RestartCommand,
    [switch]$NtfySh,
    [string]$ReadOnlyServer,
    [string]$ReadOnlyTopic,
    [string]$TokenEnv = 'NTFY_TOKEN'
)
$ErrorActionPreference = 'Stop'
$ModulePath = Join-Path $PSScriptRoot '..\src\NtfyTray.Core.psm1'
Import-Module $ModulePath -Force -DisableNameChecking
$script:Pass = 0; $script:Fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:Pass++; Write-Output "PASS  $Name $Detail" } else { $script:Fail++; Write-Output "FAIL  $Name $Detail" }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ntfytray-live-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# Background subscriber, same pattern as the tray (runspace + ConcurrentQueue + synchronized control).
function Start-TestSubscriber([string]$Server, [string[]]$Topics, [string]$CursorPath, [int]$Idle = 120, [string]$TokenFromEnv) {
    $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $ctl = [hashtable]::Synchronized(@{ Stop = $false; Status = 'starting' })
    $logq = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($ModulePath, $Server, $Topics, $Ctl, $Q, $CursorPath, $Idle, $LogQ, $TokenFromEnv)
        Import-Module $ModulePath -DisableNameChecking
        Start-NtfySubscriber -Server $Server -Topics $Topics -Control $Ctl -CursorPath $CursorPath -IdleTimeoutSec $Idle -TokenFromEnv $TokenFromEnv `
            -OnMessage { param($m, $bf) $Q.Enqueue(@{ M = $m; Backfill = $bf }) } -Log { param($x) $LogQ.Enqueue($x) }
    }).AddArgument($ModulePath).AddArgument($Server).AddArgument($Topics).AddArgument($ctl).AddArgument($q).AddArgument($CursorPath).AddArgument($Idle).AddArgument($logq).AddArgument($TokenFromEnv)
    $h = $ps.BeginInvoke()
    return @{ PS = $ps; H = $h; Ctl = $ctl; Q = $q; Log = $logq }
}
function Stop-TestSubscriber($s) { $s.Ctl.Stop = $true; [void]$s.H.AsyncWaitHandle.WaitOne(5000); try { $s.PS.EndInvoke($s.H) } catch { }; $s.PS.Dispose() }
function Wait-Status($s, [string]$Status, [int]$Sec = 15) { $u = (Get-Date).AddSeconds($Sec); while ((Get-Date) -lt $u) { if ($s.Ctl.Status -eq $Status) { return $true }; Start-Sleep -Milliseconds 200 }; return $false }
function Get-Received($s, [int]$Expect, [int]$Sec = 15) {
    $out = @(); $u = (Get-Date).AddSeconds($Sec); $it = $null
    while ((Get-Date) -lt $u -and $out.Count -lt $Expect) { while ($s.Q.TryDequeue([ref]$it)) { $out += $it }; Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 700; while ($s.Q.TryDequeue([ref]$it)) { $out += $it }
    return $out
}
function Publish([string]$Server, [string]$Topic, [string]$Body, [hashtable]$Headers = @{}) {
    Invoke-RestMethod -Method Post -Uri "$Server/$Topic" -Body ([Text.Encoding]::UTF8.GetBytes($Body)) -Headers $Headers -ContentType 'text/plain; charset=utf-8' | Out-Null
}
function Get-LogText($s) { $x = $null; $l = @(); while ($s.Log.TryDequeue([ref]$x)) { $l += $x }; return ($l -join ' || ') }

$set = @(
    @{ Body = 'min priority'; H = @{ Title = 'p1 test'; Priority = '1'; Tags = 'floppy_disk' } },
    @{ Body = 'default with click'; H = @{ Title = 'p3 test'; Click = 'https://example.com/p3'; Tags = 'white_check_mark,srv01' } },
    @{ Body = 'high with view action'; H = @{ Title = 'p4 test'; Priority = '4'; Tags = 'warning'; Actions = 'view, Open dash, https://example.org/dash; http, Ack, https://example.invalid/ack' } },
    @{ Body = 'urgent'; H = @{ Title = 'p5 test'; Priority = '5'; Tags = 'rotating_light,skull,custom-label' } }
)
function Test-Set([string]$Label, $Got) {
    Check "$Label received 4" ($Got.Count -eq 4) "(got $($Got.Count))"
    $by = @{}; foreach ($g in $Got) { $by[$g.M.Title] = $g.M }
    Check "$Label priorities 1/3/4/5" (($by['p1 test'].Priority -eq 1) -and ($by['p3 test'].Priority -eq 3) -and ($by['p4 test'].Priority -eq 4) -and ($by['p5 test'].Priority -eq 5))
    $c3 = Get-NtfyToastContent -Message $by['p3 test']; $c4 = Get-NtfyToastContent -Message $by['p4 test']; $c5 = Get-NtfyToastContent -Message $by['p5 test']
    Check "$Label click URL" ($c3.Click -eq 'https://example.com/p3')
    Check "$Label tags -> emoji + labels" (($c3.Title.StartsWith([char]::ConvertFromUtf32(0x2705))) -and ($c3.Body -match '#srv01') -and ($c5.Title.StartsWith([char]::ConvertFromUtf32(0x1F6A8))) -and ($c5.Body -match '#custom-label'))
    Check "$Label view action only (http action skipped)" ((@($c4.Views).Count -eq 1) -and ($c4.Views[0].Url -eq 'https://example.org/dash'))
    $ok = $true; foreach ($g in $Got) { try { [void][xml](New-NtfyToastXml -Message $g.M) } catch { $ok = $false } }
    Check "$Label toast XML well-formed" $ok
    Check "$Label all live (not backfill)" (@($Got | Where-Object { $_.Backfill }).Count -eq 0)
}

# ================================================================ local server
if ($LocalUrl) {
    Write-Output "== Local server $LocalUrl"
    $topic = 'nt' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $cur = Join-Path $tmp 'local.cursor.json'
    $s = Start-TestSubscriber -Server $LocalUrl -Topics @($topic, ($topic + 'b')) -CursorPath $cur -Idle 8
    Check 'local connect (open event)' (Wait-Status $s 'connected')
    foreach ($m in $set) { Publish $LocalUrl $topic $m.Body $m.H }
    Test-Set 'local' (Get-Received $s 4)
    Publish $LocalUrl ($topic + 'b') 'second topic' @{ Title = 'topic b' }
    $g = @(Get-Received $s 1)
    Check 'local multi-topic stream' (($g.Count -eq 1) -and ($g[0].M.Topic -eq ($topic + 'b')))
    Stop-TestSubscriber $s

    # App closed: messages published meanwhile must arrive once, as backfill, with no replays of old ones.
    Start-Sleep -Seconds 1
    Publish $LocalUrl $topic 'while away 1' @{ Title = 'away1' }
    Publish $LocalUrl $topic 'while away 2' @{ Title = 'away2' }
    Start-Sleep -Seconds 2
    $s = Start-TestSubscriber -Server $LocalUrl -Topics @($topic, ($topic + 'b')) -CursorPath $cur -Idle 8
    $g = @(Get-Received $s 2 10)
    Check 'resume since=: exactly the 2 missed messages' (($g.Count -eq 2) -and (($g | ForEach-Object { $_.M.Title }) -join ',') -eq 'away1,away2') "(got: $(($g | ForEach-Object { $_.M.Title }) -join ','))"
    if ($g.Count -ne 2) { Write-Output ('DEBUG log: ' + (Get-LogText $s) + ' status=' + $s.Ctl.Status + ' err=' + $s.Ctl.LastError) }
    Check 'resume since=: flagged as backfill' (@($g | Where-Object { $_.Backfill }).Count -eq 2)
    Publish $LocalUrl $topic 'live after resume' @{ Title = 'live2' }
    $g = @(Get-Received $s 1)
    Check 'live after resume, not backfill' (($g.Count -eq 1) -and -not $g[0].Backfill)

    if ($ServerPid -and $RestartCommand) {
        # Server restart -> stream drops -> backoff reconnect with since= -> nothing missed, nothing duplicated.
        Stop-Process -Id $ServerPid -Force
        Start-Sleep -Seconds 2
        Check 'detects server down' ($s.Ctl.Status -in 'reconnecting', 'connecting') "($($s.Ctl.Status))"
        $newPid = [int](bash -c $RestartCommand)
        Start-Sleep -Seconds 1
        Publish $LocalUrl $topic 'published right after restart' @{ Title = 'after-restart' }
        Check 'reconnects after restart' (Wait-Status $s 'connected' 30)
        $g = @(Get-Received $s 1 10)
        Check 'after restart: got the new message exactly once, no duplicates' ((@($g | Where-Object { $_.M.Title -eq 'after-restart' }).Count -eq 1) -and $g.Count -eq 1) "(got: $(($g | ForEach-Object { $_.M.Title }) -join ','))"

        # Half-open socket / sleep: freeze the server; the idle timeout (8 s here) must force a reconnect.
        bash -c "kill -STOP $newPid"
        Start-Sleep -Seconds 11
        $idleSeen = (Get-LogText $s) -match 'idle'
        bash -c "kill -CONT $newPid"
        Check 'idle timeout triggers reconnect (frozen server)' $idleSeen
        Check 'reconnected after idle' (Wait-Status $s 'connected' 30)
        Publish $LocalUrl $topic 'after idle' @{ Title = 'after-idle' }
        $g = @(Get-Received $s 1 10)
        Check 'after idle: message received once' ((@($g | Where-Object { $_.M.Title -eq 'after-idle' }).Count -eq 1) -and $g.Count -eq 1) "(got: $(($g | ForEach-Object { $_.M.Title }) -join ','))"
        Write-Output "LOCAL_SERVER_PID=$newPid"
    }
    Stop-TestSubscriber $s
    $c = Read-NtfyCursor -Path $cur
    Check 'cursor persisted' ($c.LastTime -gt 0 -and $c.SeenIds.Count -ge 7) "(LastTime=$($c.LastTime), ids=$($c.SeenIds.Count))"
}

# ================================================================ public ntfy.sh, throwaway topic
if ($NtfySh) {
    $srv = 'https://ntfy.sh'
    $topic = 'ntfytray-test-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
    Write-Output "== ntfy.sh throwaway topic $topic"
    $s = Start-TestSubscriber -Server $srv -Topics @($topic) -CursorPath (Join-Path $tmp 'sh.cursor.json')
    Check 'ntfy.sh connect (open event)' (Wait-Status $s 'connected' 20)
    foreach ($m in $set) { Publish $srv $topic $m.Body $m.H; Start-Sleep -Milliseconds 300 }
    Test-Set 'ntfy.sh' (Get-Received $s 4 20)
    Stop-TestSubscriber $s
    $p = Invoke-NtfyPoll -Server $srv -Topics @($topic) -Since 'all'
    Check 'ntfy.sh poll since=all returns the 4' (($p.StatusCode -eq 200) -and (@($p.Messages).Count -eq 4)) "(HTTP $($p.StatusCode), $(@($p.Messages).Count))"
}

# ================================================================ read-only private server
if ($ReadOnlyServer) {
    Write-Output "== Read-only checks on $ReadOnlyServer (counts only)"
    $hdr = Get-NtfyAuthHeader -Server $ReadOnlyServer -FromEnv $TokenEnv
    Check "token env var $TokenEnv present" ([bool]$hdr)
    $code = Test-NtfyAuth -Server $ReadOnlyServer -Topic $ReadOnlyTopic -AuthHeader $hdr
    Check 'auth endpoint with token' ($code -eq 200) "(HTTP $code)"
    $codeAnon = Test-NtfyAuth -Server $ReadOnlyServer -Topic $ReadOnlyTopic
    Write-Output "INFO  auth endpoint without token: HTTP $codeAnon"
    $p = Invoke-NtfyPoll -Server $ReadOnlyServer -Topics @($ReadOnlyTopic) -Since '1h' -AuthHeader $hdr
    Check 'poll since=1h with token' ($p.StatusCode -eq 200) "(HTTP $($p.StatusCode), $(@($p.Messages).Count) message(s) in the last hour)"
    $hdr = $null
    $s = Start-TestSubscriber -Server $ReadOnlyServer -Topics @($ReadOnlyTopic) -CursorPath (Join-Path $tmp 'ro.cursor.json') -TokenFromEnv $TokenEnv
    Check 'stream connect with token (open event)' (Wait-Status $s 'connected' 20) "(status $($s.Ctl.Status))"
    Start-Sleep -Seconds 3
    Stop-TestSubscriber $s
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "RESULT passed=$($script:Pass) failed=$($script:Fail)"
