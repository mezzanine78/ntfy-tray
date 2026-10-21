# Builds src/emoji-tags.json (ntfy tag -> emoji glyph) from a gemoji-format emoji.json.
# Source data: GitHub gemoji (MIT), the same file ntfy ships as scripts/emoji.json and
# ntfy-desktop bundles as Domain/Emojis/emoji.json. Output is pure ASCII (\uXXXX escapes)
# so Windows PowerShell 5.1 reads it correctly regardless of code page.
param(
    [Parameter(Mandatory)][string]$EmojiJson,
    [string]$OutFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/emoji-tags.json')
)
$ErrorActionPreference = 'Stop'
$data = Get-Content -LiteralPath $EmojiJson -Raw -Encoding UTF8 | ConvertFrom-Json
$map = [ordered]@{}
foreach ($e in $data) {
    if (-not $e.emoji) { continue }
    foreach ($a in @($e.aliases)) {
        if ($a -and -not $map.Contains([string]$a)) { $map[[string]$a] = [string]$e.emoji }
    }
}
function ConvertTo-AsciiJsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34) { [void]$sb.Append('\"') }
        elseif ($c -eq 92) { [void]$sb.Append('\\') }
        elseif ($c -lt 32 -or $c -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}
$lines = foreach ($k in $map.Keys) { '  "{0}": "{1}"' -f (ConvertTo-AsciiJsonString $k), (ConvertTo-AsciiJsonString $map[$k]) }
$text = "{`n" + ($lines -join ",`n") + "`n}`n"
[IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
"Wrote $($map.Count) tags to $OutFile"
