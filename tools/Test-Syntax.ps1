# Parses every .ps1/.psm1 with the PowerShell parser; if PSScriptAnalyzer is present, also reports
# warnings/errors and PSUseCompatibleSyntax for PowerShell 5.1 and 7.0. Exit 1 on parse errors.
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
$bad = 0
foreach ($f in $files) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    '{0,-40} parse errors: {1}' -f $f.FullName.Substring($root.Length + 1), $errs.Count
    foreach ($e in $errs) { "    L$($e.Extent.StartLineNumber): $($e.Message)"; $bad++ }
}
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $excl = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseApprovedVerbs', 'PSReviewUnusedParameter', 'PSUseSingularNouns', 'PSAvoidUsingEmptyCatchBlock')
    $res = @(foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f.FullName -ExcludeRule $excl -Severity Warning, Error })
    "PSScriptAnalyzer warnings/errors: $($res.Count) (excluded: $($excl -join ', '))"
    foreach ($r in $res) { '    {0} {1} {2}:{3} {4}' -f $r.Severity, $r.RuleName, $r.ScriptName, $r.Line, $r.Message }
    foreach ($ver in @('5.1', '7.0')) {
        $compat = @(foreach ($f in $files) {
            Invoke-ScriptAnalyzer -Path $f.FullName -IncludeRule PSUseCompatibleSyntax -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @($ver) } } }
        })
        "PSUseCompatibleSyntax target $ver : $($compat.Count) finding(s)"
        foreach ($r in $compat) { '    {0}:{1} {2}' -f $r.ScriptName, $r.Line, $r.Message }
    }
}
if ($bad) { exit 1 }
