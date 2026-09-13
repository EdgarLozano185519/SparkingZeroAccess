<#
.SYNOPSIS
    Builds SparkingZeroSpeech.asi (the in-game speech server plugin).
.DESCRIPTION
    Compiles speech_plugin\SparkingZeroSpeech.c into speech_plugin\SparkingZeroSpeech.asi
    with MSVC (Visual Studio 2022 Build Tools + Windows SDK) or, if cl.exe is not
    usable, with MinGW-w64 gcc. The .asi is a plain 64-bit DLL loaded by the
    Ultimate ASI Loader (dsound.dll) from SparkingZERO\Binaries\Win64\plugins\.
.PARAMETER Deploy
    Also copy the plugin and the UniversalSpeech DLLs into the game's plugins folder.
#>
param(
    [switch]$Deploy,
    [string]$GameDir
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$src = Join-Path $here 'SparkingZeroSpeech.c'
$out = Join-Path $here 'SparkingZeroSpeech.asi'

function Find-Vcvars {
    $candidates = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvars64.bat', 'C:\Program Files\Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvars64.bat' -ErrorAction SilentlyContinue
    if ($candidates) { return $candidates[0].FullName }
    return $null
}

$built = $false
$vcvars = Find-Vcvars
if ($vcvars) {
    Write-Host "MSVC: $vcvars"
    Push-Location $here
    try {
        cmd /c "call ""$vcvars"" >nul 2>&1 && cl /nologo /O2 /W4 /MT /D_CRT_SECURE_NO_WARNINGS /LD SparkingZeroSpeech.c /link /OUT:SparkingZeroSpeech.asi kernel32.lib"
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) { $built = $true } else { Write-Host "cl.exe failed (exit $LASTEXITCODE), trying gcc" }
    } finally { Pop-Location }
    Remove-Item (Join-Path $here 'SparkingZeroSpeech.obj'), (Join-Path $here 'SparkingZeroSpeech.exp'), (Join-Path $here 'SparkingZeroSpeech.lib') -ErrorAction SilentlyContinue
}
if (-not $built) {
    $gcc = (Get-Command gcc -ErrorAction SilentlyContinue).Source
    if (-not $gcc) { throw 'No usable compiler: install the Windows SDK for the VS 2022 Build Tools, or MinGW-w64 (winget install BrechtSanders.WinLibs.POSIX.UCRT)' }
    Write-Host "gcc: $gcc"
    & $gcc -shared -O2 -Wall -o $out $src -lkernel32
    if ($LASTEXITCODE -ne 0) { throw "gcc failed (exit $LASTEXITCODE)" }
    $built = $true
}
Write-Host "Built $out ($((Get-Item $out).Length) bytes)"

if ($Deploy) {
    if (-not $GameDir) { $GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\DRAGON BALL Sparking! ZERO' }
    $plugins = Join-Path $GameDir 'SparkingZERO\Binaries\Win64\plugins'
    if (-not (Test-Path -LiteralPath $plugins)) { throw "No plugins folder at $plugins (is the UTOC bypass installed?)" }
    foreach ($f in 'SparkingZeroSpeech.asi', 'UniversalSpeech.dll', 'nvdaControllerClient.dll', 'ZDSRAPI.dll') {
        Copy-Item -LiteralPath (Join-Path $here $f) -Destination (Join-Path $plugins $f) -Force
    }
    Write-Host "Deployed to $plugins"
}
