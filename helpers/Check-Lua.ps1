<#
.SYNOPSIS
    Syntax-check and lint the mod's Lua files (run before deploying).
.DESCRIPTION
    1. luac -p on every file in SparkingZeroAccess\ (syntax errors fail the check)
    2. tools\luacheck.exe with .luacheckrc
       - luacheck errors fail the check
       - global variable warnings (W111/W112/W113) fail the check: in Lua a
         misspelled name or a missing "local" silently becomes a global
       - other warnings are listed but don't fail, unless -Strict is given
    Exit code 0 = passed, 1 = failed.
.PARAMETER Strict
    Fail on any luacheck warning.
.PARAMETER Quiet
    Only print problems and the final result.
#>
param(
    [switch]$Strict,
    [switch]$Quiet
)

# Native tools write to stderr; don't let PowerShell turn that into terminating errors
$ErrorActionPreference = "Continue"

$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "SparkingZeroAccess"
$files = @(Get-ChildItem $src -Filter *.lua | Sort-Object Name)
$failed = $false

# --- Locate tools ---
$luac = $null
$luacCmd = Get-Command luac -ErrorAction SilentlyContinue
if ($luacCmd) {
    $luac = $luacCmd.Source
} else {
    $fallback = Join-Path $env:LOCALAPPDATA "Programs\Lua\bin\luac.exe"
    if (Test-Path $fallback) { $luac = $fallback }
}
$luacheck = Join-Path $root "tools\luacheck.exe"

# --- 1. Syntax check ---
if (-not $Quiet) { Write-Host "== Syntax check (luac -p), $($files.Count) files ==" }
if (-not $luac) {
    Write-Host "luac not found. Install with: winget install DEVCOM.Lua"
    $failed = $true
} else {
    $syntaxErrors = 0
    foreach ($f in $files) {
        $out = & $luac -p $f.FullName 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "SYNTAX ERROR: $($out -join ' ')"
            $syntaxErrors++
        }
    }
    if ($syntaxErrors -gt 0) {
        $failed = $true
    } elseif (-not $Quiet) {
        Write-Host "OK"
    }
}

# --- 2. Lint ---
if (-not $Quiet) { Write-Host "== Lint (luacheck) ==" }
if (-not (Test-Path $luacheck)) {
    Write-Host "luacheck not found at tools\luacheck.exe (download luacheck.exe from github.com/lunarmodules/luacheck releases)"
    $failed = $true
} else {
    $config = Join-Path $root ".luacheckrc"
    $lint = @(& $luacheck --config $config --codes --formatter plain --no-color $src 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -ne "" })
    $lintExit = $LASTEXITCODE

    # Shorten paths for readability
    $lint = @($lint | ForEach-Object { $_.Replace("$src\", "") })

    $globalIssues = @($lint | Where-Object { $_ -match '\(W11[123]\)' })
    $otherWarnings = @($lint | Where-Object { $_ -notmatch '\(W11[123]\)' })

    if ($lintExit -ge 2) {
        $lint | ForEach-Object { Write-Host $_ }
        Write-Host "luacheck reported errors (exit $lintExit)"
        $failed = $true
    } else {
        if ($globalIssues.Count -gt 0) {
            Write-Host "Global variable issues (likely typo or missing 'local'):"
            $globalIssues | ForEach-Object { Write-Host "  $_" }
            $failed = $true
        }
        if ($otherWarnings.Count -gt 0) {
            if ($Strict -or -not $Quiet) {
                Write-Host "Other warnings ($($otherWarnings.Count)):"
                $otherWarnings | ForEach-Object { Write-Host "  $_" }
            }
            if ($Strict) { $failed = $true }
        } elseif (-not $Quiet) {
            Write-Host "No other warnings"
        }
    }
}

if ($failed) {
    Write-Host "CHECK FAILED"
    exit 1
}
Write-Host "CHECK PASSED"
exit 0
