# Builds dist/ntfy-tray-v<version>.zip containing ntfy-tray/{install.ps1, README.md, LICENSE, THIRD-PARTY-NOTICES.md, src/}
param([string]$Version)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Version) { $Version = (Get-Content -LiteralPath (Join-Path $root 'src/VERSION') -Raw).Trim() }
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'stage'
$pkg = Join-Path $stage 'ntfy-tray'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $pkg 'src') -Force | Out-Null
Copy-Item (Join-Path $root 'install.ps1'), (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE'), (Join-Path $root 'THIRD-PARTY-NOTICES.md') -Destination $pkg
Copy-Item (Join-Path $root 'src/*') -Destination (Join-Path $pkg 'src')
$zip = Join-Path $dist "ntfy-tray-v$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $pkg -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Output $zip
