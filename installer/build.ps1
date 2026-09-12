<#
.SYNOPSIS
    Builds the Sparking Zero Access installer and manual-install zip.
.DESCRIPTION
    Downloads the pinned UE4SS release (verified by SHA256), stages it with the
    UTOC bypass from deps\, applies the UE4SS settings the mod needs, and
    compiles installer\SparkingZeroAccess.iss with Inno Setup 6.

    Output in build\output:
      SparkingZeroAccess-Setup-<version>.exe
      SparkingZeroAccess-<version>-manual.zip  (contents of SparkingZERO\Binaries\Win64)
.PARAMETER Version
    Version to build. Defaults to the VERSION file in the repo root.
.PARAMETER Iscc
    Path to ISCC.exe. Found automatically if omitted.
#>
param(
    [string]$Version,
    [string]$Iscc
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is very slow in Windows PowerShell with the progress bar on
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $RepoRoot 'build'
$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage'
$OutputDir = Join-Path $BuildDir 'output'

$Ue4ssUrl = 'https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip'
$Ue4ssSha256 = '4B47D4BCEDDD2F561A4E395BFA00924CCFC945AF576A2D0C613E6537846C57EC'

# UE4SS settings the mod needs (see project_status.md, Setup Status)
$Ue4ssSettings = [ordered]@{
    'bUseUObjectArrayCache' = 'false'
    'GraphicsAPI' = 'dx11'
    'GuiConsoleVisible' = '0'
}

function Find-Iscc {
    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw 'ISCC.exe (Inno Setup 6) not found. Install it with: winget install JRSoftware.InnoSetup'
}

# ZipFile.CreateFromDirectory in Windows PowerShell writes backslashes into entry
# names, which breaks other zip tools, so entries are added one by one
function New-ZipFromDirectory([string]$SourceDir, [string]$ZipPath) {
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $SourceDir -Recurse -File) {
            $entryName = $file.FullName.Substring($SourceDir.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName) | Out-Null
        }
    }
    finally {
        $zip.Dispose()
    }
}

if (-not $Version) {
    $Version = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid version '$Version', expected e.g. 1.0.1"
}
if (-not $Iscc) { $Iscc = Find-Iscc }

Write-Host "Building Sparking Zero Access $Version"

if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $CacheDir, $StageDir, $OutputDir | Out-Null

# UE4SS: download once into the cache, verify the hash every build
$ue4ssZip = Join-Path $CacheDir 'UE4SS_v3.0.1.zip'
$cachedOk = (Test-Path -LiteralPath $ue4ssZip) -and
    ((Get-FileHash -LiteralPath $ue4ssZip -Algorithm SHA256).Hash -eq $Ue4ssSha256)
if (-not $cachedOk) {
    Write-Host "Downloading $Ue4ssUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $Ue4ssUrl -OutFile $ue4ssZip
    $hash = (Get-FileHash -LiteralPath $ue4ssZip -Algorithm SHA256).Hash
    if ($hash -ne $Ue4ssSha256) {
        Remove-Item -LiteralPath $ue4ssZip
        throw "UE4SS download hash mismatch: expected $Ue4ssSha256, got $hash"
    }
}

$ue4ssDir = Join-Path $StageDir 'ue4ss'
$bypassDir = Join-Path $StageDir 'bypass'
Expand-Archive -LiteralPath $ue4ssZip -DestinationPath $ue4ssDir
Expand-Archive -LiteralPath (Join-Path $RepoRoot 'deps\utoc-bypass.zip') -DestinationPath $bypassDir

$iniPath = Join-Path $ue4ssDir 'UE4SS-settings.ini'
$ini = [IO.File]::ReadAllText($iniPath)
foreach ($key in $Ue4ssSettings.Keys) {
    $pattern = "(?m)^(\s*$key\s*=)[^\r\n]*"
    if ($ini -notmatch $pattern) { throw "UE4SS-settings.ini has no '$key' setting" }
    $ini = $ini -replace $pattern, "`${1} $($Ue4ssSettings[$key])"
}
[IO.File]::WriteAllText($iniPath, $ini)

# Manual-install zip, laid out as the contents of SparkingZERO\Binaries\Win64
$manualDir = Join-Path $StageDir 'manual'
New-Item -ItemType Directory -Force -Path $manualDir | Out-Null
foreach ($item in 'dwmapi.dll', 'UE4SS.dll', 'UE4SS-settings.ini', 'Mods') {
    Copy-Item -LiteralPath (Join-Path $ue4ssDir $item) -Destination $manualDir -Recurse
}
Copy-Item -Path (Join-Path $bypassDir '*') -Destination $manualDir -Recurse
$modTarget = Join-Path $manualDir 'Mods\SparkingZeroAccess\Scripts'
New-Item -ItemType Directory -Force -Path $modTarget | Out-Null
Copy-Item -Path (Join-Path $RepoRoot 'SparkingZeroAccess\*') -Destination $modTarget -Recurse
Copy-Item -LiteralPath (Join-Path $RepoRoot 'THIRD-PARTY-NOTICES.txt') -Destination (Split-Path -Parent $modTarget)
$modsTxt = Join-Path $manualDir 'Mods\mods.txt'
$modsLines = @('SparkingZeroAccess : 1') + @(Get-Content -LiteralPath $modsTxt)
Set-Content -LiteralPath $modsTxt -Value $modsLines -Encoding ASCII

$manualZip = Join-Path $OutputDir "SparkingZeroAccess-$Version-manual.zip"
if (Test-Path -LiteralPath $manualZip) { Remove-Item -LiteralPath $manualZip }
New-ZipFromDirectory $manualDir $manualZip
Write-Host "Created $manualZip"

# Installer
& $Iscc /Q "/DAppVersion=$Version" "/DStageDir=$StageDir" "/DOutputDir=$OutputDir" (Join-Path $PSScriptRoot 'SparkingZeroAccess.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
Write-Host "Created $(Join-Path $OutputDir "SparkingZeroAccess-Setup-$Version.exe")"
