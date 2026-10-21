<#
  Secret scan for the repo folder and (if it is a git repo) the staged files.
  Fails (exit 1) on: secret-ish file names (.env, auth.*, *.token, *.pem, *.key, id_*),
  PEM private keys, GitHub tokens (ghp_/gho_/ghs_/github_pat_), ntfy access tokens (tk_ + 29 chars),
  bearer headers with a literal value, and - without ever printing it - the literal value of
  every env var named in -EnvNames (default NTFY_TOKEN).
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot), [string[]]$EnvNames = @('NTFY_TOKEN'))
$ErrorActionPreference = 'Stop'
$hits = New-Object System.Collections.ArrayList
$badNames = '^(\.env(\..*)?|auth\..*|.*\.token|.*\.pem|.*\.key|.*\.pfx|id_(rsa|ed25519|ecdsa).*|credentials.*)$'
$patterns = @(
    @{ N = 'PEM private key'; R = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ N = 'GitHub token'; R = '\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}' },
    @{ N = 'ntfy access token'; R = '\btk_[a-z0-9]{29}\b' },
    @{ N = 'literal bearer value'; R = 'Bearer\s+(?!\$|<|\{|tk_unit|tk_file|tk_http|tk_should|tk_also)[A-Za-z0-9_\-\.]{16,}' }
)
$secrets = @()
foreach ($n in $EnvNames) { $v = [Environment]::GetEnvironmentVariable($n); if ($v -and $v.Length -ge 6) { $secrets += @{ Name = $n; Value = $v } } }

function Test-Content([string]$Label, [string]$Text) {
    foreach ($p in $patterns) { if ($Text -match $p.R) { [void]$hits.Add("$Label : $($p.N)") } }
    foreach ($s in $secrets) { if ($Text.Contains($s.Value)) { [void]$hits.Add("$Label : contains the value of `$env:$($s.Name)") } }
}

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
foreach ($f in $files) {
    if ($f.Name -match $badNames) { [void]$hits.Add("$($f.FullName.Substring($Root.Length)) : secret-like file name") }
    if ($f.Extension -eq '.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($f.FullName)
        try { foreach ($e in $z.Entries) { if ($e.Length -gt 0) { $r = New-Object IO.StreamReader($e.Open()); Test-Content "$($f.Name)!$($e.FullName)" $r.ReadToEnd(); $r.Dispose() } } } finally { $z.Dispose() }
        continue
    }
    Test-Content $f.FullName.Substring($Root.Length) ([IO.File]::ReadAllText($f.FullName))
}
$staged = 0
if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
    $names = @(git -C $Root diff --cached --name-only)
    $staged = $names.Count
    foreach ($n in $names) {
        if ((Split-Path -Leaf $n) -match $badNames) { [void]$hits.Add("staged $n : secret-like file name") }
        $blob = (git -C $Root show ":$n" 2>$null) -join "`n"
        Test-Content "staged $n" $blob
    }
    # Everything already committed too.
    $tracked = @(git -C $Root ls-files)
    foreach ($n in $tracked) { $blob = (git -C $Root show "HEAD:$n" 2>$null) -join "`n"; if ($blob) { Test-Content "HEAD $n" $blob } }
}
"Scanned $($files.Count) file(s), $staged staged; env values checked: $(@($secrets | ForEach-Object { $_.Name }) -join ', ')"
if ($hits.Count) { 'SECRET SCAN FAILED:'; $hits; exit 1 }
'SECRET SCAN CLEAN'
