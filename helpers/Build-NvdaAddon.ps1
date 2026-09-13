<#
.SYNOPSIS
    Packages nvda-addon\ into build\output\SparkingZeroAccess-<version>.nvda-addon.
.DESCRIPTION
    An .nvda-addon file is a zip with manifest.ini at its root. The version in
    the manifest is taken from the VERSION file. Install it by opening the file
    with NVDA running (Enter on it in File Explorer), then restart NVDA.
#>
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Version = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
$Source = Join-Path $RepoRoot 'nvda-addon'
$Stage = Join-Path $RepoRoot 'build\stage\nvda-addon'
$OutputDir = Join-Path $RepoRoot 'build\output'
$Out = Join-Path $OutputDir "SparkingZeroAccess-$Version.nvda-addon"

if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Copy-Item -Path (Join-Path $Source '*') -Destination $Stage -Recurse
# Python caches from offline tests (experiments\pipe_server_stub.py) don't belong in the package
Get-ChildItem -LiteralPath $Stage -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force

$manifest = Join-Path $Stage 'manifest.ini'
$text = Get-Content -LiteralPath $manifest -Raw
if ($text -notmatch '(?m)^version\s*=') { throw 'manifest.ini has no version line' }
$text = $text -replace '(?m)^(version\s*=)\s*.*$', "`${1} $Version"
[IO.File]::WriteAllText($manifest, $text, (New-Object System.Text.UTF8Encoding($false)))

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out }
$zip = [IO.Compression.ZipFile]::Open($Out, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $Stage -Recurse -File) {
        # Forward slashes: backslash entry names break other zip readers
        $entryName = $file.FullName.Substring($Stage.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName) | Out-Null
    }
} finally {
    $zip.Dispose()
}
Write-Host "Created $Out"
