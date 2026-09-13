# Starts the game, sends a scripted key sequence to it, then stops it and prints the mod's log lines.
# Steps: array of "seconds:keys" (SendKeys syntax), seconds counted from process start.
# Reports the exit code and new crash dumps like Launch-Game.ps1 (UE4SS crash_*.dmp and the
# speech plugin's plugins\AE_crash_*.dmp).
param([string[]]$Steps = @("40:{ENTER}", "46:{DOWN}", "49:{UP}", "52:{DOWN}", "55:{UP}"), [int]$Timeout = 62, [string]$Label = "drive")
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
$w = "C:\Program Files (x86)\Steam\steamapps\common\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64"
$log = "$w\UE4SS.log"
$plog = "$w\plugins\SparkingZeroSpeech.log"
function Get-Dumps { @(Get-ChildItem "$w\crash_*.dmp", "$w\plugins\AE_crash_*.dmp" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) }
$dumpsBefore = Get-Dumps
Start-Process "steam://rungameid/1790600"
$start = $null; $proc = $null
$deadline = (Get-Date).AddSeconds(30)
while (-not $proc -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $proc = Get-Process -Name SparkingZERO-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $proc) { "game did not start"; exit 1 }
try { $null = $proc.Handle } catch {}   # keep a handle so the exit code is readable later
$start = Get-Date
$plan = @()
foreach ($s in $Steps) { $parts = $s -split ":", 2; $plan += [pscustomobject]@{ at = [double]$parts[0]; keys = $parts[1]; done = $false } }
$died = $null; $exitCode = $null
while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { $died = Get-Date; try { $exitCode = $proc.ExitCode } catch {}; break }
    $elapsed = ((Get-Date) - $start).TotalSeconds
    foreach ($step in $plan) {
        if (-not $step.done -and $elapsed -ge $step.at) {
            $step.done = $true
            try { [Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id) } catch {}
            Start-Sleep -Milliseconds 150
            [System.Windows.Forms.SendKeys]::SendWait($step.keys)
            "sent $($step.keys) at $([int]$elapsed)s"
        }
    }
}
"=== $Label : started $start died=$died"
if ($died) { "exit code: $(if ($null -ne $exitCode) { '0x{0:X8} ({0})' -f $exitCode } else { 'unknown' })" }
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force; "(game stopped by script)" }
"new crash dumps: $((Get-Dumps | Where-Object { $dumpsBefore -notcontains $_ }) -join ', ')"
$raw = Get-Content $log -Raw
$parts = ($raw -split "\[Lua\] ") | ForEach-Object { ($_ -replace "\[2026-[^\]]*\].*$", "").TrimEnd() }
"--- [AE] lines (without slow-task lines)"
$parts | Where-Object { $_ -match "^\[AE" -and $_ -notmatch "Slow game thread" } | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) } | Select-Object -First 160
"--- slow task count: " + ($parts | Where-Object { $_ -match "Slow game thread" }).Count
"--- Lua errors"
$parts | Where-Object { $_ -match "error:|Error:|\.lua:\d+" } | Select-Object -First 10
if (Test-Path $plog) { "--- plugin log"; Get-Content $plog | Select-Object -Last 40 }
