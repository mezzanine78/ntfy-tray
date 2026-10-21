# Pester 5+ tests for NtfyTray.Core (offline; no network).
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\NtfyTray.Core.psm1') -Force -DisableNameChecking
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('ntfytray-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
}
AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'ConvertFrom-NtfyLine' {
    It 'parses a full message line' {
        $l = '{"id":"abcDEF123456","time":1700000000,"expires":1700043200,"event":"message","topic":"alerts","title":"Disk","message":"C: 95%","priority":5,"tags":["warning","srv01"],"click":"https://example.com/x","actions":[{"action":"view","label":"Dash","url":"https://example.org"},{"action":"http","label":"Ack","url":"https://api.example/ack","method":"PUT"}],"attachment":{"name":"a.png","url":"https://f/a.png","type":"image/png"}}'
        $m = ConvertFrom-NtfyLine $l
        $m.Event | Should -Be 'message'
        $m.Id | Should -Be 'abcDEF123456'
        $m.Time | Should -Be 1700000000
        $m.Topic | Should -Be 'alerts'
        $m.Priority | Should -Be 5
        $m.Tags | Should -Be @('warning', 'srv01')
        $m.Click | Should -Be 'https://example.com/x'
        $m.Actions.Count | Should -Be 2
        $m.Actions[1].Method | Should -Be 'PUT'
        $m.Attachment.Name | Should -Be 'a.png'
    }
    It 'defaults priority to 3 and tags to empty' {
        $m = ConvertFrom-NtfyLine '{"id":"x1","time":1,"event":"message","topic":"t","message":"hi"}'
        $m.Priority | Should -Be 3
        @($m.Tags).Count | Should -Be 0
        $m.Title | Should -Be ''
    }
    It 'clamps out-of-range priority' {
        (ConvertFrom-NtfyLine '{"event":"message","priority":9}').Priority | Should -Be 5
        (ConvertFrom-NtfyLine '{"event":"message","priority":0}').Priority | Should -Be 1
    }
    It 'parses open and keepalive events' {
        (ConvertFrom-NtfyLine '{"id":"o","time":1,"event":"open","topic":"a,b"}').Event | Should -Be 'open'
        (ConvertFrom-NtfyLine '{"id":"k","time":1,"event":"keepalive","topic":"a"}').Event | Should -Be 'keepalive'
    }
    It 'returns $null for blank, invalid JSON, arrays and objects without event' {
        ConvertFrom-NtfyLine '' | Should -BeNullOrEmpty
        ConvertFrom-NtfyLine '   ' | Should -BeNullOrEmpty
        ConvertFrom-NtfyLine '{not json' | Should -BeNullOrEmpty
        ConvertFrom-NtfyLine '[1,2]' | Should -BeNullOrEmpty
        ConvertFrom-NtfyLine '{"id":"x"}' | Should -BeNullOrEmpty
    }
    It 'keeps unicode in message text' {
        $m = ConvertFrom-NtfyLine ('{"event":"message","message":"caf\u00e9 \ud83d\ude80"}')
        $m.Message | Should -Be ("caf" + [char]0xE9 + ' ' + [char]::ConvertFromUtf32(0x1F680))
    }
}

Describe 'URL building' {
    It 'builds a multi-topic stream URL' {
        Get-NtfySubscribeUrl -Server 'https://ntfy.example.com/' -Topics 'a', 'b_c' | Should -Be 'https://ntfy.example.com/a,b_c/json'
    }
    It 'adds since and poll' {
        Get-NtfySubscribeUrl -Server 'ntfy.example.com' -Topics 'a' -Since '1700000000' | Should -Be 'https://ntfy.example.com/a/json?since=1700000000'
        Get-NtfySubscribeUrl -Server 'https://n.example' -Topics 'a' -Since '1h' -Poll | Should -Be 'https://n.example/a/json?poll=1&since=1h'
        Get-NtfySubscribeUrl -Server 'https://n.example' -Topics 'a' -Since 'abcDEF123456' | Should -Match 'since=abcDEF123456$'
    }
    It 'rejects bad topics, bad since and non-http servers' {
        { Get-NtfySubscribeUrl -Server 'https://n' -Topics 'a/b' } | Should -Throw
        { Get-NtfySubscribeUrl -Server 'https://n' -Topics 'a' -Since '1&x=2' } | Should -Throw
        { ConvertTo-NtfyServerUrl 'ftp://n.example' } | Should -Throw
        { ConvertTo-NtfyServerUrl 'https://n.example/?q=1' } | Should -Throw
    }
    It 'keeps a sub-path server' {
        Get-NtfySubscribeUrl -Server 'https://host.example/ntfy/' -Topics 't' | Should -Be 'https://host.example/ntfy/t/json'
    }
    It 'builds the auth check URL' {
        Get-NtfyAuthCheckUrl -Server 'https://n.example' -Topic 't1' | Should -Be 'https://n.example/t1/auth'
    }
    It 'makes filesystem-safe server keys' {
        Get-NtfyServerKey 'https://NTFY.Example.com' | Should -Be 'ntfy.example.com'
        Get-NtfyServerKey 'http://127.0.0.1:8099' | Should -Be '127.0.0.1_8099'
        Get-NtfyServerKey 'https://h.example/sub/path' | Should -Be 'h.example_sub_path'
    }
    It 'validates topic names' {
        Test-NtfyTopicName 'my-alerts_01' | Should -BeTrue
        Test-NtfyTopicName ('a' * 65) | Should -BeFalse
        Test-NtfyTopicName 'has space' | Should -BeFalse
        Test-NtfyTopicName '' | Should -BeFalse
    }
}

Describe 'Cursor (since= resume and dedupe)' {
    It 'starts empty with no since value' {
        $c = New-NtfyCursor
        Get-NtfySinceValue $c | Should -BeNullOrEmpty
    }
    It 'tracks the newest time and drops duplicates' {
        $c = New-NtfyCursor
        Update-NtfyCursor -Cursor $c -Message @{ Id = 'a'; Time = 100 } | Should -BeTrue
        Update-NtfyCursor -Cursor $c -Message @{ Id = 'b'; Time = 105 } | Should -BeTrue
        Update-NtfyCursor -Cursor $c -Message @{ Id = 'a'; Time = 100 } | Should -BeFalse
        Update-NtfyCursor -Cursor $c -Message @{ Id = 'c'; Time = 103 } | Should -BeTrue   # out-of-order still new
        $c.LastTime | Should -Be 105
        $c.LastId | Should -Be 'b'
        Get-NtfySinceValue $c | Should -Be '105'
    }
    It 'simulates a reconnect replay: inclusive since returns the last message again, only new ones pass' {
        $c = New-NtfyCursor
        foreach ($m in @(@{ Id = 'm1'; Time = 10 }, @{ Id = 'm2'; Time = 20 })) { [void](Update-NtfyCursor -Cursor $c -Message $m) }
        $replay = @(@{ Id = 'm2'; Time = 20 }, @{ Id = 'm3'; Time = 25 }, @{ Id = 'm4'; Time = 30 })
        $new = @($replay | Where-Object { Update-NtfyCursor -Cursor $c -Message $_ })
        ($new | ForEach-Object { $_.Id }) | Should -Be @('m3', 'm4')
    }
    It 'caps the seen-id list at 500' {
        $c = New-NtfyCursor
        1..520 | ForEach-Object { [void](Update-NtfyCursor -Cursor $c -Message @{ Id = "id$_"; Time = $_ }) }
        $c.SeenIds.Count | Should -Be 500
        $c.SeenIds[0] | Should -Be 'id21'
    }
    It 'round-trips through a file' {
        $p = Join-Path $script:Tmp 'cur.json'
        $c = New-NtfyCursor
        [void](Update-NtfyCursor -Cursor $c -Message @{ Id = 'zz'; Time = 42 })
        Save-NtfyCursor -Path $p -Cursor $c
        $r = Read-NtfyCursor -Path $p
        $r.LastTime | Should -Be 42; $r.LastId | Should -Be 'zz'; $r.SeenIds.Contains('zz') | Should -BeTrue
        (Read-NtfyCursor -Path (Join-Path $script:Tmp 'missing.json')).LastTime | Should -Be 0
    }
    It 'flags backfill only when resumed and older than the connect time' {
        Test-NtfyIsBackfill -Message @{ Time = 90 } -ResumedSince '80' -ConnectStartedUnix 100 | Should -BeTrue
        Test-NtfyIsBackfill -Message @{ Time = 101 } -ResumedSince '80' -ConnectStartedUnix 100 | Should -BeFalse
        Test-NtfyIsBackfill -Message @{ Time = 90 } -ResumedSince $null -ConnectStartedUnix 100 | Should -BeFalse
    }
}

Describe 'Priority and tag mapping' {
    It 'maps priorities to toast behaviour' {
        (Get-NtfyPriorityInfo 1).Silent | Should -BeTrue
        (Get-NtfyPriorityInfo 2).Silent | Should -BeTrue
        (Get-NtfyPriorityInfo 3).Silent | Should -BeFalse
        (Get-NtfyPriorityInfo 3).Scenario | Should -BeNullOrEmpty
        (Get-NtfyPriorityInfo 4).Scenario | Should -Be 'reminder'
        (Get-NtfyPriorityInfo 5).Scenario | Should -Be 'urgent'
        (Get-NtfyPriorityInfo 5).Loop | Should -BeTrue
        (Get-NtfyPriorityInfo $null).Level | Should -Be 3
    }
    It 'renders known tags as emoji and unknown as labels' {
        $r = ConvertTo-NtfyTagText -Tags @('warning', 'rotating_light', 'white_check_mark', 'srv01')
        $r.Emojis | Should -Be ([char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F + [char]::ConvertFromUtf32(0x1F6A8) + [char]::ConvertFromUtf32(0x2705))
        $r.Labels | Should -Be @('srv01')
    }
    It 'loads the full gemoji map (1800+ aliases)' {
        (Get-NtfyEmojiMap -Reload).Count | Should -BeGreaterThan 1800
        (Get-NtfyEmojiMap)['tada'] | Should -Be ([char]::ConvertFromUtf32(0x1F389))
    }
    It 'falls back to the built-in map when the json is missing' {
        $m = Get-NtfyEmojiMap -Path (Join-Path $script:Tmp 'nope.json') -Reload
        $m['warning'] | Should -Not -BeNullOrEmpty
        $m.ContainsKey('grinning') | Should -BeFalse
        [void](Get-NtfyEmojiMap -Reload)
    }
}

Describe 'Toast content and XML' {
    BeforeAll {
        $script:Msg = ConvertFrom-NtfyLine '{"id":"t1","time":1700000000,"event":"message","topic":"alerts","title":"Backup <failed>","message":"Job \"nightly\" & more","priority":5,"tags":["warning","nas"],"click":"https://example.com/?a=1&b=2","actions":[{"action":"view","label":"Logs","url":"https://logs.example"},{"action":"view","label":"Bad","url":"file:///c:/x"},{"action":"http","label":"Retry","url":"https://x"}]}'
    }
    It 'builds well-formed XML with escaping' {
        $x = New-NtfyToastXml -Message $script:Msg
        { [xml]$x } | Should -Not -Throw
        $doc = [xml]$x
        $doc.toast.scenario | Should -Be 'urgent'
        $doc.toast.launch | Should -Be 'https://example.com/?a=1&b=2'
        $doc.toast.activationType | Should -Be 'protocol'
        $doc.toast.visual.binding.text[0] | Should -Match 'Backup <failed>$'
        $doc.toast.visual.binding.text[1] | Should -Match 'Job "nightly" & more'
        $doc.toast.visual.binding.text[1] | Should -Match '#nas'
        $doc.toast.audio.loop | Should -Be 'true'
    }
    It 'adds only safe view actions plus Dismiss for high priority' {
        $doc = [xml](New-NtfyToastXml -Message $script:Msg)
        $acts = @($doc.toast.actions.action)
        $acts.Count | Should -Be 2
        $acts[0].content | Should -Be 'Logs'; $acts[0].arguments | Should -Be 'https://logs.example'
        $acts[1].activationType | Should -Be 'system'
    }
    It 'drops unsafe click URLs and silences low priority' {
        $m = ConvertFrom-NtfyLine '{"id":"t2","time":1,"event":"message","topic":"x","message":"m","priority":1,"click":"javascript:alert(1)"}'
        $doc = [xml](New-NtfyToastXml -Message $m)
        $doc.toast.GetAttribute('launch') | Should -Be ''
        $doc.toast.audio.silent | Should -Be 'true'
        $doc.toast.visual.binding.text[0] | Should -Be 'x'    # no title -> topic
    }
    It 'uses the topic display name and priority badge in the attribution' {
        $c = Get-NtfyToastContent -Message $script:Msg -TopicLabel 'NAS alerts'
        $c.Attribution | Should -Match 'Urgent - NAS alerts$'
    }
    It 'flattens markdown bodies' {
        $m = ConvertFrom-NtfyLine '{"event":"message","topic":"t","message":"**bold** and [link](https://x.example) `code`","content_type":"text/markdown"}'
        (Get-NtfyToastContent -Message $m).Body | Should -Be 'bold and link (https://x.example) code'
    }
    It 'builds a summary toast' {
        $doc = [xml](New-NtfySummaryToastXml -CountsByTopic @{ alerts = 3; backups = 1 })
        $doc.toast.visual.binding.text[0] | Should -Be '4 messages while you were away'
        $doc.toast.visual.binding.text[1] | Should -Match '^alerts \(3\), backups \(1\)'
    }
    It 'Test-NtfySafeUrl allows only http(s)' {
        Test-NtfySafeUrl 'https://a.example' | Should -BeTrue
        Test-NtfySafeUrl 'http://a.example' | Should -BeTrue
        Test-NtfySafeUrl 'file:///c:/windows' | Should -BeFalse
        Test-NtfySafeUrl 'ms-settings:' | Should -BeFalse
        Test-NtfySafeUrl '' | Should -BeFalse
    }
}

Describe 'Notification gate' {
    BeforeAll {
        $script:Cfg = ConvertTo-NtfyTrayConfig @{ Server = 'https://n.example'; Topics = @('alerts', @{ Name = 'noisy'; MinPriority = 4 }, @{ Name = 'muted'; Paused = $true }) }
        $script:Srv = 'n.example'
    }
    It 'passes normal messages' {
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'alerts'; Priority = 3 } -Config $script:Cfg -Server $script:Srv | Should -BeTrue
    }
    It 'applies per-topic min priority and pause' {
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'noisy'; Priority = 3 } -Config $script:Cfg -Server $script:Srv | Should -BeFalse
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'noisy'; Priority = 4 } -Config $script:Cfg -Server $script:Srv | Should -BeTrue
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'muted'; Priority = 5 } -Config $script:Cfg -Server $script:Srv | Should -BeFalse
    }
    It 'applies global min priority and pause' {
        $c = ConvertTo-NtfyTrayConfig @{ Server = 'https://n.example'; Topics = @('alerts'); MinPriority = 3 }
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'alerts'; Priority = 2 } -Config $c -Server 'n.example' | Should -BeFalse
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'alerts'; Priority = 3 } -Config $c -Server 'n.example' -RuntimePaused $true | Should -BeFalse
    }
    It 'honours active hours, but priority 5 breaks through' {
        $c = ConvertTo-NtfyTrayConfig @{ Server = 'https://n.example'; Topics = @('alerts'); ActiveHours = @{ Enabled = $true; Start = '09:00'; End = '18:00' } }
        $night = Get-Date -Hour 23 -Minute 0
        $day = Get-Date -Hour 10 -Minute 0
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'alerts'; Priority = 4 } -Config $c -Server 'n.example' -Now $night | Should -BeFalse
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'alerts'; Priority = 4 } -Config $c -Server 'n.example' -Now $day | Should -BeTrue
        Test-NtfyShouldNotify -Message @{ Event = 'message'; Topic = 'alerts'; Priority = 5 } -Config $c -Server 'n.example' -Now $night | Should -BeTrue
    }
    It 'handles active-hours ranges across midnight' {
        Test-NtfyActiveHours -Start '22:00' -End '06:00' -Now (Get-Date -Hour 23 -Minute 30) | Should -BeTrue
        Test-NtfyActiveHours -Start '22:00' -End '06:00' -Now (Get-Date -Hour 5 -Minute 59) | Should -BeTrue
        Test-NtfyActiveHours -Start '22:00' -End '06:00' -Now (Get-Date -Hour 12 -Minute 0) | Should -BeFalse
    }
}

Describe 'Backoff' {
    It 'follows 1,2,4,8,16,30,60 and caps at 60' {
        (0..8 | ForEach-Object { Get-NtfyBackoffDelay -Attempt $_ -NoJitter }) | Should -Be @(1, 2, 4, 8, 16, 30, 60, 60, 60)
    }
    It 'waits longer after auth and rate-limit errors' {
        Get-NtfyBackoffDelay -Attempt 0 -StatusCode 429 -NoJitter | Should -Be 60
        Get-NtfyBackoffDelay -Attempt 0 -StatusCode 401 -NoJitter | Should -Be 300
    }
    It 'adds at most 20% jitter' {
        $d = Get-NtfyBackoffDelay -Attempt 3
        $d | Should -BeGreaterOrEqual 8; $d | Should -BeLessOrEqual 9.6
    }
}

Describe 'Config load/save' {
    It 'returns defaults for a missing file' {
        $c = Read-NtfyTrayConfig -Path (Join-Path $script:Tmp 'none.json')
        @($c.Servers).Count | Should -Be 0
        $c.MinPriority | Should -Be 1
        $c.Autostart | Should -BeTrue
    }
    It 'expands the short form and round-trips' {
        $p = Join-Path $script:Tmp 'c1.json'
        $c = ConvertTo-NtfyTrayConfig @{ Server = 'ntfy.example.com'; Topics = @('a', 'b'); MinPriority = 2; Autostart = $false }
        Save-NtfyTrayConfig -Path $p -Config $c
        $r = Read-NtfyTrayConfig -Path $p
        $r.Servers[0].Url | Should -Be 'https://ntfy.example.com'
        $r.Servers[0].Auth | Should -Be 'token'
        @($r.Topics).Count | Should -Be 2
        $r.Topics[1].Server | Should -Be 'ntfy.example.com'
        $r.MinPriority | Should -Be 2
        $r.Autostart | Should -BeFalse
    }
    It 'supports several servers and per-topic server' {
        $c = ConvertTo-NtfyTrayConfig @{
            Servers = @(@{ Name = 'home'; Url = 'https://ntfy.home.example' }, @{ Name = 'pub'; Url = 'https://ntfy.sh'; Auth = 'none' })
            Topics  = @(@{ Server = 'home'; Name = 'alerts' }, @{ Server = 'pub'; Name = 'news' }, @{ Server = 'home'; Name = 'backups' }, @{ Server = 'nope'; Name = 'x' })
        } 3>$null
        $g = @(Get-NtfySubscriptionGroups -Config $c)
        $g.Count | Should -Be 2
        $g[0].Topics | Should -Be @('alerts', 'backups')
        $g[1].Auth | Should -Be 'none'
    }
    It 'drops invalid topics, duplicates and disabled topics from the stream' {
        $c = ConvertTo-NtfyTrayConfig @{ Server = 'https://n.example'; Topics = @('ok', 'ok', 'bad topic', @{ Name = 'off'; Enabled = $false }) } 3>$null
        @($c.Topics).Count | Should -Be 2
        (Get-NtfySubscriptionGroups -Config $c).Topics | Should -Be @('ok')
    }
    It 'never writes secret-looking keys' {
        $p = Join-Path $script:Tmp 'c2.json'
        Save-NtfyTrayConfig -Path $p -Config @{ Server = 'https://n.example'; Topics = @('a'); Token = 'tk_shouldnotbesaved'; Servers = @(@{ Url = 'https://n.example'; Token = 'tk_alsonot'; Password = 'pw' }) }
        $raw = Get-Content -LiteralPath $p -Raw
        $raw | Should -Not -Match 'tk_'
        $raw | Should -Not -Match 'Password'
    }
    It 'clamps numbers and validates times' {
        $c = ConvertTo-NtfyTrayConfig @{ MinPriority = 99; RecentCount = 1; ActiveHours = @{ Enabled = $true; Start = '25:00'; End = '07:30' } }
        $c.MinPriority | Should -Be 5
        $c.RecentCount | Should -Be 5
        $c.ActiveHours.Start | Should -Be '09:00'
        $c.ActiveHours.End | Should -Be '07:30'
    }
}

Describe 'Token store' {
    It 'protects and unprotects a token (DPAPI on Windows)' {
        $sec = ConvertTo-SecureString 'tk_unit_test_value' -AsPlainText -Force
        $prot = Protect-NtfyToken -Token $sec
        $prot | Should -Not -Match 'tk_unit_test_value'
        ConvertTo-NtfyPlainToken (Unprotect-NtfyToken $prot) | Should -Be 'tk_unit_test_value'
    }
    It 'saves, reads, builds the auth header and removes' {
        $dir = Join-Path $script:Tmp 'tokens'
        $sec = ConvertTo-SecureString 'tk_file_test' -AsPlainText -Force
        $path = Set-NtfyToken -Server 'https://n.example' -Token $sec -TokenDir $dir
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match 'tk_file_test'
        Get-NtfyAuthHeader -Server 'https://n.example' -TokenDir $dir | Should -Be 'Bearer tk_file_test'
        Remove-NtfyToken -Server 'https://n.example' -TokenDir $dir | Should -BeTrue
        Get-NtfyAuthHeader -Server 'https://n.example' -TokenDir $dir | Should -BeNullOrEmpty
    }
    It 'never sends a token over plain http (except loopback)' {
        $dir = Join-Path $script:Tmp 'tokens2'
        $sec = ConvertTo-SecureString 'tk_http' -AsPlainText -Force
        [void](Set-NtfyToken -Server 'http://n.example' -Token $sec -TokenDir $dir)
        [void](Set-NtfyToken -Server 'http://127.0.0.1:8099' -Token $sec -TokenDir $dir)
        Get-NtfyAuthHeader -Server 'http://n.example' -TokenDir $dir | Should -BeNullOrEmpty
        Get-NtfyAuthHeader -Server 'http://127.0.0.1:8099' -TokenDir $dir | Should -Be 'Bearer tk_http'
    }
}

Describe 'Recent line formatting' {
    It 'formats and truncates' {
        $m = @{ Time = 1700000000; Topic = 'alerts'; Title = 'A very long title that keeps going and going and going and going'; Message = 'x'; Priority = 4; Tags = @('warning') }
        $l = Format-NtfyRecentLine -Message $m -MaxLength 50
        $l.Length | Should -Be 50
        $l | Should -Match '^\(!\) '
        $l | Should -Match '\[alerts\]'
    }
}
