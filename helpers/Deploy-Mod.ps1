<#
.SYNOPSIS
    Copies the mod's scripts and DLLs into the game for testing.
.DESCRIPTION
    Mirrors SparkingZeroAccess\ into Mods\SparkingZeroAccess\Scripts\ in the game.
    UE4SS, the UTOC bypass and the mods.txt entry come from the installer, so run
    the installer once before using this script.
.PARAMETER GameDir
    Game folder (the one containing SparkingZERO.exe). Found through Steam if omitted.
.PARAMETER SkipCheck
    Deploy without running helpers\Check-Lua.ps1 first (syntax check + lint).
#>
param(
    [string]$GameDir,
    [switch]$SkipCheck
)

$ErrorActionPreference = 'Stop'

$SteamAppId = '1790600'
$ShippingExe = 'SparkingZERO\Binaries\Win64\SparkingZERO-Win64-Shipping.exe'

function Test-GameDir([string]$Dir) {
    return [bool]$Dir -and (Test-Path -LiteralPath (Join-Path $Dir $ShippingExe))
}

function Find-GameDir {
    # Steam registers an uninstall entry for each installed game
    $uninstallKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App $SteamAppId"
    $dir = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
    if (Test-GameDir $dir) { return $dir }

    # Otherwise look for the game's app manifest in every Steam library
    $steamDir = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steamDir) { return $null }
    $vdf = Join-Path $steamDir 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) { return $null }
    foreach ($match in Select-String -LiteralPath $vdf -Pattern '^\s*"path"\s*"(.+)"') {
        $library = $match.Matches[0].Groups[1].Value -replace '\\\\', '\'
        $manifest = Join-Path $library "steamapps\appmanifest_$SteamAppId.acf"
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $installDir = Select-String -LiteralPath $manifest -Pattern '^\s*"installdir"\s*"(.+)"' | Select-Object -First 1
        if (-not $installDir) { continue }
        $dir = Join-Path $library "steamapps\common\$($installDir.Matches[0].Groups[1].Value)"
        if (Test-GameDir $dir) { return $dir }
    }
    return $null
}

# Catch syntax errors and misspelled variables before they cost a game restart
if (-not $SkipCheck) {
    $checkScript = Join-Path $PSScriptRoot 'Check-Lua.ps1'
    & powershell -ExecutionPolicy Bypass -File $checkScript -Quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'Lua check failed, nothing deployed. Fix the errors above or pass -SkipCheck.'
    }
}

if (-not $GameDir) { $GameDir = Find-GameDir }
if (-not (Test-GameDir $GameDir)) {
    throw 'Game not found. Pass -GameDir with the folder that contains SparkingZERO.exe.'
}

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'SparkingZeroAccess'
$win64 = Join-Path $GameDir 'SparkingZERO\Binaries\Win64'
$target = Join-Path $win64 'Mods\SparkingZeroAccess\Scripts'

if (-not (Test-Path -LiteralPath (Join-Path $win64 'UE4SS.dll'))) {
    Write-Warning 'UE4SS is not installed in the game. Run the installer once first.'
}

Write-Host "Deploying to $target"
# /R:3 /W:10 retries files the running game has locked
robocopy $source $target /MIR /R:3 /W:10 /NJH /NJS /NP /NDL
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

$modsTxt = Join-Path $win64 'Mods\mods.txt'
$enabled = (Test-Path -LiteralPath $modsTxt) -and
    (Select-String -LiteralPath $modsTxt -Pattern '^\s*SparkingZeroAccess\s*:\s*1' -Quiet)
if (-not $enabled) {
    Write-Warning "SparkingZeroAccess is not enabled in $modsTxt. Run the installer once first."
}

Write-Host 'Deploy complete.'
exit 0
