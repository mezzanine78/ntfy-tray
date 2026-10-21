#Requires -Version 5.1
<#
    NtfyTray.Core - UI-free logic for the NtfyTray ntfy client.
    Works on Windows PowerShell 5.1 and PowerShell 7+ (any OS, except DPAPI which is Windows-only).

    Design follows simoneferrari/ntfy-desktop (MIT): per-server auth tokens encrypted with
    DPAPI, a durable timestamp cursor for `since=` resume, backfill detection by time,
    1-60 s reconnect backoff, http(s)-only click URLs, priority-based toast urgency and
    ntfy tags rendered as emoji. See THIRD-PARTY-NOTICES.md.
#>
# No Set-StrictMode: callers pass hashtables with optional keys (Control.StopAt, Message.Title, ...).

$script:BackoffSeconds = @(1, 2, 4, 8, 16, 30, 60)
$script:MaxSeenIds     = 500
$script:EmojiMap       = $null
$script:UserAgent      = 'NtfyTray/1.0 (+https://github.com/mezzanine78/ntfy-tray)'

# ---------------------------------------------------------------- paths
function Get-NtfyTrayPaths {
    [CmdletBinding()]
    param([string]$AppData, [string]$LocalAppData)
    if ([string]::IsNullOrEmpty($AppData)) { $AppData = [Environment]::GetFolderPath('ApplicationData') }
    if ([string]::IsNullOrEmpty($AppData)) { $AppData = $env:APPDATA }
    if ([string]::IsNullOrEmpty($AppData)) { $AppData = [IO.Path]::GetTempPath() }
    if ([string]::IsNullOrEmpty($LocalAppData)) { $LocalAppData = [Environment]::GetFolderPath('LocalApplicationData') }
    if ([string]::IsNullOrEmpty($LocalAppData)) { $LocalAppData = $env:LOCALAPPDATA }
    if ([string]::IsNullOrEmpty($LocalAppData)) { $LocalAppData = $AppData }
    $data = Join-Path $AppData 'NtfyTray'
    if ($env:NTFYTRAY_DATA) { $data = $env:NTFYTRAY_DATA }   # optional override (portable use / tests)
    [pscustomobject]@{
        DataDir     = $data
        ConfigPath  = Join-Path $data 'config.json'
        StateDir    = Join-Path $data 'state'
        TokenDir    = Join-Path $data 'tokens'
        LogPath     = Join-Path $data 'ntfytray.log'
        ReloadFlag  = Join-Path $data 'reload.flag'
        InstallDir  = Join-Path $LocalAppData 'NtfyTray'
    }
}

# ---------------------------------------------------------------- validation helpers
function ConvertTo-NtfyServerUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)
    $u = $Url.Trim()
    if ($u -eq '') { throw 'Server URL is empty.' }
    if ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $u = 'https://' + $u }
    $uri = $null
    if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri)) { throw "Invalid server URL: $Url" }
    if ($uri.Scheme -ne 'https' -and $uri.Scheme -ne 'http') { throw "Server URL must be http(s): $Url" }
    if ($uri.Query -or $uri.Fragment) { throw "Server URL must not contain a query or fragment: $Url" }
    return $u.TrimEnd('/')
}

function Test-NtfyTopicName {
    [CmdletBinding()]
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    return ($Name -match '^[-_A-Za-z0-9]{1,64}$')
}

function Test-NtfySafeUrl {
    # Only http and https are acted on (mirrors ntfy-desktop Domain/SafeUrl.cs). file:, cmd:,
    # javascript: and friends would let a publisher trigger shell behaviour on click.
    [CmdletBinding()]
    param([AllowNull()][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')
}

function Get-NtfyServerKey {
    # Filesystem-safe key for per-server files (token, cursor). host[_port][_path]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server)
    $uri = [Uri](ConvertTo-NtfyServerUrl $Server)
    $k = $uri.Host.ToLowerInvariant()
    if (-not $uri.IsDefaultPort) { $k += '_' + $uri.Port }
    $p = $uri.AbsolutePath.Trim('/')
    if ($p) { $k += '_' + $p }
    return ($k -replace '[^a-z0-9._-]', '_')
}

# ---------------------------------------------------------------- config
function New-NtfyTrayConfig {
    [ordered]@{
        Servers        = @()      # @{ Name; Url; Auth = 'token' | 'none' }
        Topics         = @()      # @{ Server; Name; DisplayName; MinPriority; Paused; Enabled }
        MinPriority    = 1        # global toast threshold (1-5)
        Paused         = $false   # global notification pause (connections stay live)
        ActiveHours    = [ordered]@{ Enabled = $false; Start = '09:00'; End = '18:00' }
        Autostart      = $true
        CatchUpSummary = $true    # one "N messages while you were away" toast instead of one per missed message
        RecentCount    = 50
        IdleTimeoutSec = 120      # reconnect if nothing (not even a keepalive) arrives for this long
    }
}

function Get-NtfyProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $Default
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function ConvertTo-NtfyInt {
    param($Value, [int]$Default, [int]$Min, [int]$Max)
    $n = 0
    if ($null -ne $Value -and [int]::TryParse([string]$Value, [ref]$n)) {
        if ($n -lt $Min) { $n = $Min }; if ($n -gt $Max) { $n = $Max }
        return $n
    }
    return $Default
}

function ConvertTo-NtfyTrayConfig {
    <#
      Normalises a parsed config object into the full shape. Accepts the long form
      (Servers[] + Topics[]) and a short form:
          { "Server": "https://ntfy.example.com", "Topics": ["alerts", "backups"] }
      Unknown keys are dropped; any key named like a secret (Token, Password, ...) is dropped too.
    #>
    [CmdletBinding()]
    param($InputObject)
    $cfg = New-NtfyTrayConfig
    if ($null -eq $InputObject) { return $cfg }

    $servers = New-Object System.Collections.ArrayList
    $byName = @{}
    $addServer = {
        param($url, $name, $auth)
        $norm = ConvertTo-NtfyServerUrl $url
        if (-not $name) { $name = ([Uri]$norm).Host }
        $name = [string]$name
        if ($byName.ContainsKey($name)) { return $byName[$name] }
        if ($auth -ne 'none') { $auth = 'token' }
        $s = [ordered]@{ Name = $name; Url = $norm; Auth = [string]$auth }
        [void]$servers.Add($s); $byName[$name] = $s
        return $s
    }

    foreach ($s in @(Get-NtfyProp $InputObject 'Servers' @())) {
        if ($null -eq $s) { continue }
        $url = Get-NtfyProp $s 'Url'
        if (-not $url) { continue }
        [void](& $addServer $url (Get-NtfyProp $s 'Name') (Get-NtfyProp $s 'Auth' 'token'))
    }
    $shortServer = Get-NtfyProp $InputObject 'Server'
    $defaultServer = $null
    if ($shortServer) { $defaultServer = & $addServer $shortServer $null (Get-NtfyProp $InputObject 'Auth' 'token') }
    elseif ($servers.Count -gt 0) { $defaultServer = $servers[0] }

    $topics = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($t in @(Get-NtfyProp $InputObject 'Topics' @())) {
        if ($null -eq $t) { continue }
        if ($t -is [string]) { $t = @{ Name = $t } }
        $name = [string](Get-NtfyProp $t 'Name')
        if (-not (Test-NtfyTopicName $name)) { Write-Warning "Skipping invalid topic name '$name'"; continue }
        $srvName = Get-NtfyProp $t 'Server'
        $srv = $null
        if ($srvName) {
            if ($byName.ContainsKey([string]$srvName)) { $srv = $byName[[string]$srvName] }
            elseif ([string]$srvName -match '://|\.') { $srv = & $addServer $srvName $null 'token' }
        } else { $srv = $defaultServer }
        if (-not $srv) { Write-Warning "Skipping topic '$name': unknown server '$srvName'"; continue }
        $key = $srv.Name + '|' + $name
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $mp = ConvertTo-NtfyInt (Get-NtfyProp $t 'MinPriority') 0 0 5
        [void]$topics.Add([ordered]@{
            Server      = $srv.Name
            Name        = $name
            DisplayName = [string](Get-NtfyProp $t 'DisplayName' '')
            MinPriority = $mp                       # 0 = use global
            Paused      = [bool](Get-NtfyProp $t 'Paused' $false)
            Enabled     = [bool](Get-NtfyProp $t 'Enabled' $true)
        })
    }

    $cfg.Servers = @($servers)
    $cfg.Topics = @($topics)
    $cfg.MinPriority = ConvertTo-NtfyInt (Get-NtfyProp $InputObject 'MinPriority') 1 1 5
    $cfg.Paused = [bool](Get-NtfyProp $InputObject 'Paused' $false)
    $ah = Get-NtfyProp $InputObject 'ActiveHours'
    if ($ah) {
        $cfg.ActiveHours.Enabled = [bool](Get-NtfyProp $ah 'Enabled' $false)
        foreach ($k in 'Start', 'End') {
            $v = [string](Get-NtfyProp $ah $k '')
            if ($v -match '^([01]?\d|2[0-3]):[0-5]\d$') { $cfg.ActiveHours[$k] = $v }
        }
    }
    $cfg.Autostart = [bool](Get-NtfyProp $InputObject 'Autostart' $true)
    $cfg.CatchUpSummary = [bool](Get-NtfyProp $InputObject 'CatchUpSummary' $true)
    $cfg.RecentCount = ConvertTo-NtfyInt (Get-NtfyProp $InputObject 'RecentCount') 50 5 500
    $cfg.IdleTimeoutSec = ConvertTo-NtfyInt (Get-NtfyProp $InputObject 'IdleTimeoutSec') 120 30 3600
    return $cfg
}

function Read-NtfyTrayConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return (New-NtfyTrayConfig) }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-NtfyTrayConfig) }
    $obj = $raw | ConvertFrom-Json
    return (ConvertTo-NtfyTrayConfig $obj)
}

function Save-NtfyTrayConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)
    $norm = ConvertTo-NtfyTrayConfig $Config   # also strips anything secret-looking
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $norm | ConvertTo-Json -Depth 6
    Write-NtfyFileAtomic -Path $Path -Text $json
}

function Write-NtfyFileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-NtfySubscriptionGroups {
    # One stream per server, carrying all its enabled topics (ntfy supports /t1,t2/json).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    foreach ($s in @($Config.Servers)) {
        $names = @($Config.Topics | Where-Object { $_.Server -eq $s.Name -and $_.Enabled } | ForEach-Object { $_.Name })
        if ($names.Count -eq 0) { continue }
        [pscustomobject]@{ Server = $s.Name; Url = $s.Url; Auth = $s.Auth; Topics = $names; Key = (Get-NtfyServerKey $s.Url) }
    }
}

# ---------------------------------------------------------------- URLs
function Get-NtfySubscribeUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string[]]$Topics,
        [string]$Since,
        [switch]$Poll
    )
    $base = ConvertTo-NtfyServerUrl $Server
    $list = @($Topics | Where-Object { $_ })
    if ($list.Count -eq 0) { throw 'No topics given.' }
    foreach ($t in $list) { if (-not (Test-NtfyTopicName $t)) { throw "Invalid topic name: $t" } }
    $q = @()
    if ($Poll) { $q += 'poll=1' }
    if ($Since) {
        if ($Since -notmatch '^(all|latest|none|\d+|\d+[smhd]|[A-Za-z0-9]{12})$') { throw "Invalid since value: $Since" }
        $q += ('since=' + [Uri]::EscapeDataString($Since))
    }
    $url = '{0}/{1}/json' -f $base, ($list -join ',')
    if ($q.Count) { $url += '?' + ($q -join '&') }
    return $url
}

function Get-NtfyAuthCheckUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$Topic)
    if (-not (Test-NtfyTopicName $Topic)) { throw "Invalid topic name: $Topic" }
    return ('{0}/{1}/auth' -f (ConvertTo-NtfyServerUrl $Server), $Topic)
}

# ---------------------------------------------------------------- message parsing
function ConvertFrom-NtfyLine {
    <#
      Parses one line of the ntfy JSON stream. Returns $null for blank/invalid lines.
      Result: hashtable with Event, Id, Time, Expires, Topic, Priority (1-5, default 3),
      Title, Message, Tags (string[]), Click, ContentType, Actions (hashtable[]), Attachment.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try { $o = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $o -or $o -isnot [psobject] -or $o -is [array]) { return $null }
    $ev = [string](Get-NtfyProp $o 'event' '')
    if (-not $ev) { return $null }
    $pri = ConvertTo-NtfyInt (Get-NtfyProp $o 'priority') 3 1 5
    $time = [long]0; [void][long]::TryParse([string](Get-NtfyProp $o 'time' '0'), [ref]$time)
    $exp = [long]0; [void][long]::TryParse([string](Get-NtfyProp $o 'expires' '0'), [ref]$exp)
    $tags = @(@(Get-NtfyProp $o 'tags' @()) | Where-Object { $_ -ne $null -and "$_" -ne '' } | ForEach-Object { [string]$_ })
    $actions = @()
    foreach ($a in @(Get-NtfyProp $o 'actions' @())) {
        if ($null -eq $a) { continue }
        $actions += @{
            Action = [string](Get-NtfyProp $a 'action' '')
            Label  = [string](Get-NtfyProp $a 'label' '')
            Url    = [string](Get-NtfyProp $a 'url' '')
            Method = [string](Get-NtfyProp $a 'method' '')
            Value  = [string](Get-NtfyProp $a 'value' '')
            Clear  = [bool](Get-NtfyProp $a 'clear' $false)
        }
    }
    $att = $null
    $ao = Get-NtfyProp $o 'attachment'
    if ($ao) { $att = @{ Name = [string](Get-NtfyProp $ao 'name' ''); Url = [string](Get-NtfyProp $ao 'url' ''); Type = [string](Get-NtfyProp $ao 'type' '') } }
    return @{
        Event       = $ev
        Id          = [string](Get-NtfyProp $o 'id' '')
        Time        = $time
        Expires     = $exp
        Topic       = [string](Get-NtfyProp $o 'topic' '')
        Priority    = $pri
        Title       = [string](Get-NtfyProp $o 'title' '')
        Message     = [string](Get-NtfyProp $o 'message' '')
        Tags        = [string[]]$tags
        Click       = [string](Get-NtfyProp $o 'click' '')
        ContentType = [string](Get-NtfyProp $o 'content_type' '')
        Actions     = $actions
        Attachment  = $att
    }
}

# ---------------------------------------------------------------- cursor (since= resume + dedupe)
function New-NtfyCursor {
    @{ LastTime = [long]0; LastId = ''; SeenIds = (New-Object System.Collections.Generic.List[string]) }
}

function Update-NtfyCursor {
    <#
      Records a message in the cursor. Returns $true when it is new, $false for a duplicate
      (already seen id). The cursor keeps the newest message time (for since=<unix time>) and
      the last $MaxSeenIds ids, so a reconnect that replays overlapping messages never
      notifies twice.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Cursor, [Parameter(Mandatory)]$Message)
    $id = [string]$Message.Id
    if ($id -and $Cursor.SeenIds.Contains($id)) { return $false }
    if ($id) {
        $Cursor.SeenIds.Add($id)
        while ($Cursor.SeenIds.Count -gt $script:MaxSeenIds) { $Cursor.SeenIds.RemoveAt(0) }
    }
    if ([long]$Message.Time -ge [long]$Cursor.LastTime) {
        $Cursor.LastTime = [long]$Message.Time
        if ($id) { $Cursor.LastId = $id }
    }
    return $true
}

function Get-NtfySinceValue {
    <#
      since= value for a reconnect. A unix timestamp (not the message id) is used, like
      ntfy-desktop: an id that has aged out of the server cache makes ntfy return nothing,
      whereas an old timestamp returns whatever is still cached. ntfy's since=<time> is
      inclusive, so the last message comes back once and Update-NtfyCursor drops it.
      Returns $null when there is no history yet (fresh subscription = live only).
    #>
    [CmdletBinding()]
    param($Cursor)
    if ($null -eq $Cursor -or [long]$Cursor.LastTime -le 0) { return $null }
    return ([string][long]$Cursor.LastTime)
}

function Read-NtfyCursor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $c = New-NtfyCursor
    if (-not (Test-Path -LiteralPath $Path)) { return $c }
    try {
        $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $t = [long]0; [void][long]::TryParse([string](Get-NtfyProp $o 'LastTime' '0'), [ref]$t)
        $c.LastTime = $t
        $c.LastId = [string](Get-NtfyProp $o 'LastId' '')
        foreach ($i in @(Get-NtfyProp $o 'SeenIds' @())) { if ($i) { $c.SeenIds.Add([string]$i) } }
    } catch { }
    return $c
}

function Save-NtfyCursor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Cursor)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o = [ordered]@{ LastTime = [long]$Cursor.LastTime; LastId = [string]$Cursor.LastId; SeenIds = @($Cursor.SeenIds) }
    Write-NtfyFileAtomic -Path $Path -Text ($o | ConvertTo-Json -Depth 3)
}

function Test-NtfyIsBackfill {
    # A message replayed via since= (published before this connect attempt) is backlog, not live.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Message, [AllowNull()][string]$ResumedSince, [long]$ConnectStartedUnix)
    if ([string]::IsNullOrEmpty($ResumedSince)) { return $false }
    return ([long]$Message.Time -lt $ConnectStartedUnix)
}

# ---------------------------------------------------------------- priority / tags / toast
function Get-NtfyPriorityInfo {
    <#
      ntfy priority -> toast behaviour.
        1 min     : silent, low-key attribution
        2 low     : silent
        3 default : normal toast, default sound
        4 high    : 'reminder' scenario (stays until dismissed), reminder sound, Dismiss button
        5 urgent  : 'urgent' scenario (Win11 22H2+ breaks through Do Not Disturb where allowed),
                    long duration, looping alarm sound, Dismiss button
    #>
    [CmdletBinding()]
    param($Priority)
    $p = ConvertTo-NtfyInt $Priority 3 1 5
    switch ($p) {
        1 { @{ Level = 1; Label = 'Min';     Silent = $true;  Sound = $null; Scenario = $null; Duration = 'short'; Loop = $false; Badge = [char]::ConvertFromUtf32(0x26AA) } }
        2 { @{ Level = 2; Label = 'Low';     Silent = $true;  Sound = $null; Scenario = $null; Duration = 'short'; Loop = $false; Badge = [char]::ConvertFromUtf32(0x1F535) } }
        3 { @{ Level = 3; Label = 'Default'; Silent = $false; Sound = $null; Scenario = $null; Duration = 'short'; Loop = $false; Badge = '' } }
        4 { @{ Level = 4; Label = 'High';    Silent = $false; Sound = 'ms-winsoundevent:Notification.Reminder'; Scenario = 'reminder'; Duration = 'long'; Loop = $false; Badge = [char]::ConvertFromUtf32(0x1F7E0) } }
        5 { @{ Level = 5; Label = 'Urgent';  Silent = $false; Sound = 'ms-winsoundevent:Notification.Looping.Alarm'; Scenario = 'urgent'; Duration = 'long'; Loop = $true; Badge = [char]::ConvertFromUtf32(0x1F534) } }
    }
}

function Get-NtfyEmojiMap {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'emoji-tags.json'), [switch]$Reload)
    if ($script:EmojiMap -and -not $Reload) { return $script:EmojiMap }
    $map = @{}
    # Built-in fallback for the tags ntfy's docs use most, in case the json is missing.
    $builtin = @{
        warning = '26A0 FE0F'; rotating_light = '1F6A8'; white_check_mark = '2705'; heavy_check_mark = '2714 FE0F'
        x = '274C'; no_entry = '26D4'; tada = '1F389'; skull = '1F480'; fire = '1F525'; bell = '1F514'
        information_source = '2139 FE0F'; exclamation = '2757'; question = '2753'; '+1' = '1F44D'; '-1' = '1F44E'
        computer = '1F4BB'; floppy_disk = '1F4BE'; lock = '1F512'; unlock = '1F513'; key = '1F511'; zap = '26A1'
        rocket = '1F680'; hourglass = '231B'; loudspeaker = '1F4E2'; partying_face = '1F973'; cd = '1F4BF'
        green_circle = '1F7E2'; red_circle = '1F534'; yellow_circle = '1F7E1'; package = '1F4E6'; email = '1F4E7'
    }
    foreach ($k in $builtin.Keys) {
        $map[$k] = -join ($builtin[$k].Split(' ') | ForEach-Object { [char]::ConvertFromUtf32([Convert]::ToInt32($_, 16)) })
    }
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
        } catch { }
    }
    $script:EmojiMap = $map
    return $map
}

function ConvertTo-NtfyTagText {
    # Splits tags into emoji glyphs (known shortcodes) and plain labels (unknown tags), like ntfy's web client.
    [CmdletBinding()]
    param([AllowNull()][string[]]$Tags, [hashtable]$Map)
    if (-not $Map) { $Map = Get-NtfyEmojiMap }
    $emojis = ''
    $labels = @()
    foreach ($t in @($Tags)) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $k = $t.Trim()
        if ($Map.ContainsKey($k)) { $emojis += $Map[$k] }
        elseif ($Map.ContainsKey($k.ToLowerInvariant())) { $emojis += $Map[$k.ToLowerInvariant()] }
        else { $labels += $k }
    }
    [pscustomobject]@{ Emojis = $emojis; Labels = [string[]]$labels }
}

function ConvertTo-NtfyPlainText {
    # Flattens the markdown subset ntfy supports to readable toast text.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '!\[([^\]]*)\]\(([^)]+)\)', '$1')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^)]+)\)', '$1 ($2)')
    $t = [regex]::Replace($t, '(\*\*|__)(.+?)\1', '$2')
    $t = [regex]::Replace($t, '(?<![\w*])[*_](?!\s)(.+?)(?<!\s)[*_](?![\w*])', '$1')
    $t = [regex]::Replace($t, '`{1,3}([^`]*)`{1,3}', '$1')
    $t = [regex]::Replace($t, '(?m)^\s{0,3}#{1,6}\s+', '')
    return $t
}

function ConvertTo-NtfyXmlText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '' }
    # Drop characters that are illegal in XML 1.0.
    $v = [regex]::Replace($Value, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    return $v.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')
}

function Get-NtfyToastContent {
    # Title/body/attribution strings shared by every toast backend (WinRT, BurntToast, balloon).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Message, [string]$TopicLabel, [hashtable]$EmojiMap)
    $tags = ConvertTo-NtfyTagText -Tags $Message.Tags -Map $EmojiMap
    $topic = $TopicLabel; if (-not $topic) { $topic = $Message.Topic }
    $title = $Message.Title; if ([string]::IsNullOrWhiteSpace($title)) { $title = $topic }
    if ($tags.Emojis) { $title = $tags.Emojis + ' ' + $title }
    $body = $Message.Message
    if ($Message.ContentType -eq 'text/markdown') { $body = ConvertTo-NtfyPlainText $body }
    if ($Message.Attachment -and $Message.Attachment.Name) { $body = ($body + "`n[attachment] " + $Message.Attachment.Name).Trim() }
    if ($tags.Labels.Count) { $body = ($body + "`n" + (($tags.Labels | ForEach-Object { '#' + $_ }) -join ' ')).Trim() }
    $pi = Get-NtfyPriorityInfo $Message.Priority
    $attr = $topic
    if ($pi.Badge) { $attr = '{0} {1} - {2}' -f $pi.Badge, $pi.Label, $topic }
    $click = $null; if (Test-NtfySafeUrl $Message.Click) { $click = $Message.Click }
    $views = @(Get-NtfyViewActions $Message)
    [pscustomobject]@{ Title = $title; Body = $body; Attribution = $attr; Priority = $pi; Click = $click; Views = $views; TagLabels = $tags.Labels }
}

function Get-NtfyViewActions {
    # 'view' actions with an http(s) URL, max 3 (ntfy's own cap). http/copy/broadcast are not rendered on toasts.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Message)
    $out = @()
    foreach ($a in @($Message.Actions)) {
        if ($null -eq $a) { continue }
        if ($a.Action -ne 'view' -or -not (Test-NtfySafeUrl $a.Url)) { continue }
        $label = $a.Label; if ([string]::IsNullOrWhiteSpace($label)) { $label = 'Open' }
        $out += @{ Label = $label; Url = $a.Url }
        if ($out.Count -ge 3) { break }
    }
    return $out
}

function New-NtfyToastXml {
    <#
      Builds ToastGeneric XML. Clicking the toast opens the message's click URL (protocol
      activation - works without a COM activator, the browser handles it). 'view' actions
      become protocol buttons. Priority 4/5 add a system Dismiss button, scenario and sound.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Message, [string]$TopicLabel, [hashtable]$EmojiMap)
    $c = Get-NtfyToastContent -Message $Message -TopicLabel $TopicLabel -EmojiMap $EmojiMap
    $pi = $c.Priority
    $attrs = ''
    if ($pi.Scenario) { $attrs += ' scenario="{0}"' -f $pi.Scenario }
    if ($pi.Duration -eq 'long') { $attrs += ' duration="long"' }
    if ($c.Click) { $attrs += ' activationType="protocol" launch="{0}"' -f (ConvertTo-NtfyXmlText $c.Click) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<toast$attrs><visual><binding template=`"ToastGeneric`">")
    [void]$sb.Append('<text>' + (ConvertTo-NtfyXmlText $c.Title) + '</text>')
    if ($c.Body) { [void]$sb.Append('<text>' + (ConvertTo-NtfyXmlText $c.Body) + '</text>') }
    [void]$sb.Append('<text placement="attribution">' + (ConvertTo-NtfyXmlText $c.Attribution) + '</text>')
    [void]$sb.Append('</binding></visual>')
    $buttons = @()
    foreach ($v in $c.Views) {
        $buttons += '<action content="{0}" activationType="protocol" arguments="{1}"/>' -f (ConvertTo-NtfyXmlText $v.Label), (ConvertTo-NtfyXmlText $v.Url)
    }
    if ($pi.Level -ge 4) { $buttons += '<action content="Dismiss" activationType="system" arguments="dismiss"/>' }
    if ($buttons.Count) { [void]$sb.Append('<actions>' + ($buttons -join '') + '</actions>') }
    if ($pi.Silent) { [void]$sb.Append('<audio silent="true"/>') }
    elseif ($pi.Sound) {
        $loop = ''; if ($pi.Loop) { $loop = ' loop="true"' }
        [void]$sb.Append(('<audio src="{0}"{1}/>' -f $pi.Sound, $loop))
    }
    [void]$sb.Append('</toast>')
    return $sb.ToString()
}

function New-NtfySummaryToastXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$CountsByTopic)
    $total = 0; foreach ($v in $CountsByTopic.Values) { $total += [int]$v }
    $noun = 'messages'; if ($total -eq 1) { $noun = 'message' }
    $title = '{0} {1} while you were away' -f $total, $noun
    $parts = $CountsByTopic.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { '{0} ({1})' -f $_.Key, $_.Value }
    $body = ($parts -join ', ') + '. Open the tray menu > Recent messages.'
    return ('<toast><visual><binding template="ToastGeneric"><text>{0}</text><text>{1}</text></binding></visual><audio silent="true"/></toast>' -f (ConvertTo-NtfyXmlText $title), (ConvertTo-NtfyXmlText $body))
}

# ---------------------------------------------------------------- notification gate
function Test-NtfyActiveHours {
    # True when $Now is inside Start-End (handles ranges that span midnight, e.g. 22:00-06:00).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Start, [Parameter(Mandatory)][string]$End, [datetime]$Now = (Get-Date))
    $s = [TimeSpan]::Parse($Start); $e = [TimeSpan]::Parse($End); $t = $Now.TimeOfDay
    if ($s -le $e) { return ($t -ge $s -and $t -le $e.Add([TimeSpan]::FromSeconds(59))) }
    return ($t -ge $s -or $t -le $e.Add([TimeSpan]::FromSeconds(59)))
}

function Get-NtfyTopicConfig {
    param([Parameter(Mandatory)]$Config, [string]$Server, [string]$Topic)
    @($Config.Topics | Where-Object { $_.Server -eq $Server -and $_.Name -eq $Topic }) | Select-Object -First 1
}

function Test-NtfyShouldNotify {
    <#
      Decides whether a received message pops a toast. Messages are always recorded in the
      recent list; this only gates the toast: global pause, per-topic pause, min priority
      (per-topic overrides global), and active hours. Priority 5 ignores active hours.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Message, [Parameter(Mandatory)]$Config, [string]$Server, [datetime]$Now = (Get-Date), [bool]$RuntimePaused = $false)
    if ($Message.Event -ne 'message') { return $false }
    if ($Config.Paused -or $RuntimePaused) { return $false }
    $tc = Get-NtfyTopicConfig -Config $Config -Server $Server -Topic $Message.Topic
    if ($tc -and $tc.Paused) { return $false }
    $min = [int]$Config.MinPriority
    if ($tc -and [int]$tc.MinPriority -gt 0) { $min = [int]$tc.MinPriority }
    if ([int]$Message.Priority -lt $min) { return $false }
    if ($Config.ActiveHours.Enabled -and [int]$Message.Priority -lt 5) {
        if (-not (Test-NtfyActiveHours -Start $Config.ActiveHours.Start -End $Config.ActiveHours.End -Now $Now)) { return $false }
    }
    return $true
}

function Get-NtfyBackoffDelay {
    # 1, 2, 4, 8, 16, 30, 60 s (ntfy-desktop's schedule), +0-20% jitter. Auth/rate-limit errors wait at least 60 s.
    [CmdletBinding()]
    param([int]$Attempt, [int]$StatusCode = 0, [switch]$NoJitter)
    $i = [Math]::Max(0, [Math]::Min($Attempt, $script:BackoffSeconds.Count - 1))
    $d = [double]$script:BackoffSeconds[$i]
    if ($StatusCode -in 401, 403, 429) { $d = [Math]::Max($d, 60) }
    if ($StatusCode -in 401, 403) { $d = [Math]::Max($d, 300) }
    if (-not $NoJitter) { $d = $d * (1 + (Get-Random -Minimum 0.0 -Maximum 0.2)) }
    return $d
}

# ---------------------------------------------------------------- tokens (DPAPI, CurrentUser)
function ConvertTo-NtfyPlainToken {
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Protect-NtfyToken {
    # SecureString -> DPAPI-encrypted string (ConvertFrom-SecureString without -Key = DPAPI CurrentUser on Windows).
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Security.SecureString]$Token)
    return (ConvertFrom-SecureString -SecureString $Token)
}

function Unprotect-NtfyToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Protected)
    return (ConvertTo-SecureString -String $Protected.Trim())
}

function Get-NtfyTokenPath {
    param([Parameter(Mandatory)][string]$TokenDir, [Parameter(Mandatory)][string]$Server)
    Join-Path $TokenDir ((Get-NtfyServerKey $Server) + '.token')
}

function Set-NtfyToken {
    <#
    .SYNOPSIS  Stores the access token for a server, DPAPI-encrypted for the current Windows user.
    .EXAMPLE   Set-NtfyToken -Server https://ntfy.example.com     # prompts (input hidden)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [System.Security.SecureString]$Token,
        [string]$TokenDir = (Get-NtfyTrayPaths).TokenDir
    )
    if (-not $Token) { $Token = Read-Host -AsSecureString "Access token for $Server (input hidden)" }
    if ($Token.Length -eq 0) { throw 'Empty token; nothing saved.' }
    if (-not (Test-Path -LiteralPath $TokenDir)) { New-Item -ItemType Directory -Path $TokenDir -Force | Out-Null }
    $path = Get-NtfyTokenPath -TokenDir $TokenDir -Server $Server
    Write-NtfyFileAtomic -Path $path -Text (Protect-NtfyToken -Token $Token)
    return $path
}

function Get-NtfyToken {
    # Returns the stored token as a SecureString, or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [string]$TokenDir = (Get-NtfyTrayPaths).TokenDir)
    $path = Get-NtfyTokenPath -TokenDir $TokenDir -Server $Server
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Unprotect-NtfyToken (Get-Content -LiteralPath $path -Raw)) } catch { return $null }
}

function Remove-NtfyToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [string]$TokenDir = (Get-NtfyTrayPaths).TokenDir)
    $path = Get-NtfyTokenPath -TokenDir $TokenDir -Server $Server
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; return $true }
    return $false
}

function Get-NtfyAuthHeader {
    <#
      'Bearer <token>' for the server, or $null when no token / auth = none.
      Like ntfy-desktop, credentials are never attached over plain http:// (except localhost).
      Override with an env var name via -FromEnv (used by the test scripts; value never printed).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [string]$TokenDir, [string]$FromEnv)
    $uri = [Uri](ConvertTo-NtfyServerUrl $Server)
    if ($uri.Scheme -ne 'https' -and -not $uri.IsLoopback) { return $null }
    $plain = $null
    if ($FromEnv) { $plain = [Environment]::GetEnvironmentVariable($FromEnv) }
    else {
        if (-not $TokenDir) { $TokenDir = (Get-NtfyTrayPaths).TokenDir }
        $sec = Get-NtfyToken -Server $Server -TokenDir $TokenDir
        if ($sec) { $plain = ConvertTo-NtfyPlainToken $sec }
    }
    if ([string]::IsNullOrEmpty($plain)) { return $null }
    return ('Bearer ' + $plain.Trim())
}

# ---------------------------------------------------------------- HTTP
function Initialize-NtfyHttp {
    if (-not ('System.Net.Http.HttpClient' -as [type])) { Add-Type -AssemblyName System.Net.Http }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}

function New-NtfyHttpClient {
    Initialize-NtfyHttp
    $h = New-Object System.Net.Http.HttpClientHandler
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    return $c
}

function Invoke-NtfyGet {
    # Simple GET returning @{ StatusCode; Body }. Never throws for HTTP errors.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [string]$AuthHeader, [int]$TimeoutSec = 30)
    $client = New-NtfyHttpClient
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent)
        if ($AuthHeader) { [void]$req.Headers.TryAddWithoutValidation('Authorization', $AuthHeader) }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return @{ StatusCode = [int]$resp.StatusCode; Body = $body }
    } finally { $client.Dispose() }
}

function Invoke-NtfyPoll {
    # One-shot fetch of cached messages (poll=1). Returns @{ StatusCode; Messages }.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string[]]$Topics, [string]$Since = 'all', [string]$AuthHeader)
    $r = Invoke-NtfyGet -Url (Get-NtfySubscribeUrl -Server $Server -Topics $Topics -Since $Since -Poll) -AuthHeader $AuthHeader
    $msgs = @()
    if ($r.StatusCode -eq 200) {
        foreach ($l in ($r.Body -split "`n")) {
            $m = ConvertFrom-NtfyLine $l
            if ($m -and $m.Event -eq 'message') { $msgs += $m }
        }
    }
    return @{ StatusCode = $r.StatusCode; Messages = $msgs }
}

function Test-NtfyAuth {
    # GET /<topic>/auth -> 200 when the credentials may read the topic. Returns the HTTP status code.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$Topic, [string]$AuthHeader)
    return (Invoke-NtfyGet -Url (Get-NtfyAuthCheckUrl -Server $Server -Topic $Topic) -AuthHeader $AuthHeader -TimeoutSec 15).StatusCode
}

function Test-NtfyStop {
    # True when the control asks to stop (Stop flag, or StopAt deadline passed).
    param([hashtable]$Control)
    if ($null -eq $Control) { return $false }
    if ($Control.Stop) { return $true }
    if ($Control.StopAt -and (Get-Date) -ge [datetime]$Control.StopAt) { $Control.Stop = $true; return $true }
    return $false
}

function Invoke-NtfyStream {
    <#
      Opens one JSON stream and reads it until it ends, goes idle past -IdleTimeoutSec
      (no keepalive -> half-open socket, e.g. after sleep), or $Control.Stop is set.
      Calls $OnEvent with each parsed event hashtable. Returns
      @{ Reason = 'eof'|'idle'|'stopped'|'http'|'error'; StatusCode; Error; Opened }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$AuthHeader,
        [Parameter(Mandatory)][scriptblock]$OnEvent,
        [hashtable]$Control,
        [int]$IdleTimeoutSec = 120,
        [int]$ConnectTimeoutSec = 30
    )
    if (-not $Control) { $Control = @{ Stop = $false } }
    $client = New-NtfyHttpClient
    $resp = $null; $reader = $null
    $result = @{ Reason = 'error'; StatusCode = 0; Error = $null; Opened = $false }
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent)
        if ($AuthHeader) { [void]$req.Headers.TryAddWithoutValidation('Authorization', $AuthHeader) }
        $send = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        $waited = 0
        while (-not $send.Wait(500)) {
            $waited += 500
            if (Test-NtfyStop $Control) { $result.Reason = 'stopped'; return $result }
            if ($waited -ge ($ConnectTimeoutSec * 1000)) { throw "connect timed out after $ConnectTimeoutSec s" }
        }
        $resp = $send.Result
        $result.StatusCode = [int]$resp.StatusCode
        if (-not $resp.IsSuccessStatusCode) {
            $result.Reason = 'http'
            $result.Error = 'HTTP {0} {1}' -f [int]$resp.StatusCode, $resp.ReasonPhrase
            return $result
        }
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
        while ($true) {
            $task = $reader.ReadLineAsync()
            $idle = 0
            while (-not $task.Wait(500)) {
                $idle += 500
                if (Test-NtfyStop $Control) { $result.Reason = 'stopped'; return $result }
                if ($idle -ge ($IdleTimeoutSec * 1000)) { $result.Reason = 'idle'; $result.Error = "no data for $IdleTimeoutSec s"; return $result }
            }
            $line = $task.Result
            if ($null -eq $line) { $result.Reason = 'eof'; return $result }
            $ev = ConvertFrom-NtfyLine $line
            if ($null -eq $ev) { continue }
            if ($ev.Event -eq 'open') { $result.Opened = $true }
            $null = & $OnEvent $ev
            if (Test-NtfyStop $Control) { $result.Reason = 'stopped'; return $result }
        }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $result.Reason = 'error'; $result.Error = $e.Message
        return $result
    } finally {
        if ($reader) { try { $reader.Dispose() } catch { } }
        if ($resp) { try { $resp.Dispose() } catch { } }
        try { $client.Dispose() } catch { }
    }
}

function Start-NtfySubscriber {
    <#
      Reconnecting subscriber for one server (all its topics on one stream). Blocks until
      $Control.Stop. Each attempt re-reads the token and resumes with since=<last time>,
      drops duplicates by id, tags replayed messages as backfill, persists the cursor, and
      backs off 1..60 s (longer for 401/403/429). $OnMessage gets ($message, $isBackfill).
      $Control (synchronized hashtable) gets Status / LastError / Connected / Attempts updates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string[]]$Topics,
        [Parameter(Mandatory)][scriptblock]$OnMessage,
        [Parameter(Mandatory)][hashtable]$Control,
        [string]$CursorPath,
        [string]$TokenDir,
        [string]$TokenFromEnv,
        [int]$IdleTimeoutSec = 120,
        [scriptblock]$Log = { param($m) }
    )
    $cursor = New-NtfyCursor
    if ($CursorPath) { $cursor = Read-NtfyCursor -Path $CursorPath }
    $attempt = 0
    $Control.Status = 'connecting'
    while (-not (Test-NtfyStop $Control)) {
        $since = Get-NtfySinceValue $cursor
        $connectStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $url = Get-NtfySubscribeUrl -Server $Server -Topics $Topics -Since $since
        $auth = Get-NtfyAuthHeader -Server $Server -TokenDir $TokenDir -FromEnv $TokenFromEnv
        $Control.Status = 'connecting'
        $null = & $Log ('Connecting {0} (since={1}, auth={2})' -f ($url -replace '\?.*$', ''), $(if ($since) { $since } else { 'none' }), [bool]$auth)
        $state = @{ Dirty = $false }
        $onEvent = {
            param($ev)
            if ($ev.Event -eq 'open') {
                $Control.Status = 'connected'; $Control.LastError = $null; $Control.ConnectedSince = Get-Date
                return
            }
            if ($ev.Event -ne 'message') { return }
            if (-not (Update-NtfyCursor -Cursor $cursor -Message $ev)) { return }
            $state.Dirty = $true
            $bf = Test-NtfyIsBackfill -Message $ev -ResumedSince $since -ConnectStartedUnix $connectStart
            $null = & $OnMessage $ev $bf
            if ($CursorPath) { try { Save-NtfyCursor -Path $CursorPath -Cursor $cursor; $state.Dirty = $false } catch { } }
        }
        $r = Invoke-NtfyStream -Url $url -AuthHeader $auth -OnEvent $onEvent -Control $Control -IdleTimeoutSec $IdleTimeoutSec
        $auth = $null
        if ($state.Dirty -and $CursorPath) { try { Save-NtfyCursor -Path $CursorPath -Cursor $cursor } catch { } }
        if ($r.Opened) { $attempt = 0 }
        if (Test-NtfyStop $Control) { break }
        $Control.LastError = $r.Error
        $Control.LastStatusCode = $r.StatusCode
        if ($r.StatusCode -in 401, 403) { $Control.Status = 'auth failed' } else { $Control.Status = 'reconnecting' }
        $delay = Get-NtfyBackoffDelay -Attempt $attempt -StatusCode $r.StatusCode
        $attempt++
        $Control.Attempts = $attempt
        $null = & $Log ('Stream ended: {0} {1}; retry in {2:N0} s' -f $r.Reason, $r.Error, $delay)
        $until = (Get-Date).AddSeconds($delay)
        while ((Get-Date) -lt $until -and -not (Test-NtfyStop $Control) -and -not $Control.ReconnectNow) { Start-Sleep -Milliseconds 250 }
        $Control.ReconnectNow = $false
    }
    $Control.Status = 'stopped'
}

function Format-NtfyRecentLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Message, [int]$MaxLength = 70, [hashtable]$EmojiMap)
    $tags = ConvertTo-NtfyTagText -Tags $Message.Tags -Map $EmojiMap
    $t = $Message.Title; if ([string]::IsNullOrWhiteSpace($t)) { $t = $Message.Message }
    $t = ($t -replace '\s+', ' ').Trim()
    $time = [DateTimeOffset]::FromUnixTimeSeconds([long]$Message.Time).ToLocalTime().ToString('ddd HH:mm')
    $line = '{0}  [{1}] {2}{3}' -f $time, $Message.Topic, $(if ($tags.Emojis) { $tags.Emojis + ' ' } else { '' }), $t
    if ([int]$Message.Priority -ge 4) { $line = '(!) ' + $line }
    if ($line.Length -gt $MaxLength) { $line = $line.Substring(0, $MaxLength - 3) + '...' }
    return $line
}

Export-ModuleMember -Function *-Ntfy*, Get-NtfyTrayPaths, New-NtfyTrayConfig, ConvertTo-NtfyTrayConfig, Read-NtfyTrayConfig, Save-NtfyTrayConfig
