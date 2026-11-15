# Publishes the current version to GitHub: commits and pushes the addon, then creates a release
# (tag v<Version from the .toc>) with AHPriceTracker.zip attached. Players always get the newest
# version from: https://github.com/<owner>/<repo>/releases/latest/download/AHPriceTracker.zip
# Needs the GitHub CLI, signed in (gh auth login).
param([string]$Notes = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = 'C:\Program Files\GitHub CLI\gh.exe' }

$toc = Get-Content (Join-Path $root 'AHPriceTracker.toc')
$version = ($toc | Where-Object { $_ -match '^## Version:\s*(\S+)' } | ForEach-Object { $Matches[1] }) | Select-Object -First 1
if (-not $version) { throw 'No ## Version line in AHPriceTracker.toc' }
$tag = "v$version"

# Zip with the AHPriceTracker folder inside, so it unzips straight into Interface\AddOns.
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'stage'
Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $stage 'AHPriceTracker') | Out-Null
Get-ChildItem $root -Force | Where-Object { $_.Name -notin @('.git', 'dist', '.gitignore') } |
    Copy-Item -Destination (Join-Path $stage 'AHPriceTracker') -Recurse -Force
Remove-Item -Recurse -Force (Join-Path $stage 'AHPriceTracker\tools\cache') -ErrorAction SilentlyContinue
$zip = Join-Path $dist 'AHPriceTracker.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)

Push-Location $root
try {
    git add -A
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git commit -m "AH Price Tracker $version" | Out-Null }
    git push origin HEAD
    & $gh release view $tag 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $gh release upload $tag $zip --clobber
        Write-Host "Updated the zip on release $tag."
    } else {
        if (-not $Notes) { $Notes = "AH Price Tracker $version. Unzip into World of Warcraft\_forever_\Interface\AddOns and /reload." }
        & $gh release create $tag $zip --title "AH Price Tracker $version" --notes $Notes --latest
        Write-Host "Published release $tag."
    }
    $repo = & $gh repo view --json url -q .url
    Write-Host "Download link (always the newest): $repo/releases/latest/download/AHPriceTracker.zip"
} finally { Pop-Location }
