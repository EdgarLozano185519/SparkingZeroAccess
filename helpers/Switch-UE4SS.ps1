<#
.SYNOPSIS
    Installs the experimental or the stable (3.0.1) UE4SS build into the game.
.DESCRIPTION
    -Build experimental : copies UE4SS.dll and the default mods from the newest
                          build\stage\ue4ss-experimental-* folder and writes
                          UE4SS-settings.ini from that build's template with the
                          settings this mod needs. The 3.0.1 dwmapi.dll proxy is
                          kept (it loads UE4SS.dll from the same folder).
    -Build stable       : restores dwmapi.dll, UE4SS.dll, UE4SS-settings.ini and
                          the default mods from build\backup\ue4ss-3.0.1.
    -Status             : only reports which build is installed.
    mods.txt and Mods\SparkingZeroAccess are never touched. Refuses to run
    while the game is running.
.PARAMETER GameDir
    Game folder (the one containing SparkingZERO.exe). Found through Steam if omitted.
#>
param(
    [ValidateSet('experimental', 'stable')]
    [string]$Build,
    [switch]$Status,
    [string]$GameDir
)

$ErrorActionPreference = 'Stop'
$SteamAppId = '1790600'
$ShippingExe = 'SparkingZERO\Binaries\Win64\SparkingZERO-Win64-Shipping.exe'
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Settings applied on top of the experimental template (see project_status.md)
$Settings = [ordered]@{
    'EnableHotReloadSystem'       = '0'
    'bUseUObjectArrayCache'       = 'false'
    'SecondsToScanBeforeGivingUp' = '120'
    'ConsoleEnabled'              = '0'
    'GuiConsoleEnabled'           = '1'
    'GuiConsoleVisible'           = '0'
    'GraphicsAPI'                 = 'dx11'
}

function Test-GameDir([string]$Dir) {
    return [bool]$Dir -and (Test-Path -LiteralPath (Join-Path $Dir $ShippingExe))
}

function Find-GameDir {
    $uninstallKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App $SteamAppId"
    $dir = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
    if (Test-GameDir $dir) { return $dir }
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

function Get-InstalledBuild([string]$Win64) {
    $dll = Join-Path $Win64 'UE4SS.dll'
    if (-not (Test-Path -LiteralPath $dll)) { return 'none' }
    $ver = (Get-Item -LiteralPath $dll).VersionInfo
    $size = (Get-Item -LiteralPath $dll).Length
    if ($size -eq 16263680) { return 'stable 3.0.1' }
    return "experimental ($size bytes, file version '$($ver.FileVersion)')"
}

if (-not $GameDir) { $GameDir = Find-GameDir }
if (-not (Test-GameDir $GameDir)) {
    throw 'Game not found. Pass -GameDir with the folder that contains SparkingZERO.exe.'
}
$win64 = Join-Path $GameDir 'SparkingZERO\Binaries\Win64'
Write-Host "Installed UE4SS: $(Get-InstalledBuild $win64)"
if ($Status -or -not $Build) { exit 0 }

if (Get-Process -Name 'SparkingZERO-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'The game is running. Close it first.'
}

$modsDir = Join-Path $win64 'Mods'
$keep = @('SparkingZeroAccess', 'mods.txt', 'mods.json')

if ($Build -eq 'experimental') {
    $stage = Get-ChildItem (Join-Path $RepoRoot 'build\stage') -Directory -Filter 'ue4ss-experimental-*' |
        Sort-Object Name | Select-Object -Last 1
    if (-not $stage) { throw 'No build\stage\ue4ss-experimental-* folder. Extract the experimental UE4SS zip there first.' }
    $src = Join-Path $stage.FullName 'ue4ss'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'UE4SS.dll'))) { throw "No UE4SS.dll in $src" }
    Write-Host "Source: $src"

    # Settings: the experimental template with our values
    $ini = Get-Content -LiteralPath (Join-Path $src 'UE4SS-settings.ini') -Raw
    foreach ($key in $Settings.Keys) {
        $pattern = "(?m)^(\s*$key\s*=)\s*.*$"
        if ($ini -notmatch $pattern) { throw "Template has no '$key' setting" }
        $ini = $ini -replace $pattern, "`${1} $($Settings[$key])"
    }
    Set-Content -LiteralPath (Join-Path $win64 'UE4SS-settings.ini') -Value $ini -Encoding utf8 -NoNewline

    Copy-Item -LiteralPath (Join-Path $src 'UE4SS.dll') -Destination (Join-Path $win64 'UE4SS.dll') -Force
    foreach ($item in Get-ChildItem (Join-Path $src 'Mods')) {
        if ($keep -contains $item.Name) { continue }
        $dest = Join-Path $modsDir $item.Name
        if ($item.PSIsContainer) {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
        }
    }
    Write-Host 'Installed the experimental UE4SS build (UE4SS.dll, default mods, settings). dwmapi.dll proxy kept.'
} else {
    $src = Join-Path $RepoRoot 'build\backup\ue4ss-3.0.1'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'UE4SS.dll'))) { throw "No 3.0.1 backup in $src" }
    Write-Host "Source: $src"
    foreach ($file in 'dwmapi.dll', 'UE4SS.dll', 'UE4SS-settings.ini') {
        Copy-Item -LiteralPath (Join-Path $src $file) -Destination (Join-Path $win64 $file) -Force
    }
    foreach ($item in Get-ChildItem (Join-Path $src 'Mods')) {
        if ($keep -contains $item.Name) { continue }
        $dest = Join-Path $modsDir $item.Name
        if ($item.PSIsContainer) {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
        }
    }
    Write-Host 'Restored UE4SS 3.0.1 (dwmapi.dll, UE4SS.dll, settings, default mods).'
}
Write-Host "Installed UE4SS now: $(Get-InstalledBuild $win64)"
