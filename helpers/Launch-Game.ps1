# Starts the game through Steam, watches the process and UE4SS.log, then stops the game.
# Reports the exit code (0xC0000005 = access violation, 0xC0000409 = fail fast, 0xC00000FD = stack
# overflow, 0xC0000374 = heap corruption, 0 = clean exit) and any new crash dump from UE4SS
# (Win64\crash_*.dmp) or from the speech plugin's crash catcher (Win64\plugins\AE_crash_*.dmp).
param([int]$Timeout = 80, [switch]$KeepRunning, [string]$Label = "run")
$w = "C:\Program Files (x86)\Steam\steamapps\common\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64"
$log = "$w\UE4SS.log"
$plog = "$w\plugins\SparkingZeroSpeech.log"
$start = Get-Date
function Get-Dumps { @(Get-ChildItem "$w\crash_*.dmp", "$w\plugins\AE_crash_*.dmp" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) }
$dumpsBefore = Get-Dumps
Start-Process "steam://rungameid/1790600"
$seen = $false; $exitAt = $null; $firstSeen = $null; $proc = $null; $exitCode = $null
while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
    Start-Sleep -Seconds 2
    if (-not $proc) {
        $proc = Get-Process -Name SparkingZERO-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $firstSeen = Get-Date; $seen = $true
            try { $null = $proc.Handle } catch {}   # keep a handle so the exit code is readable later
        }
    } elseif ($proc.HasExited) {
        $exitAt = Get-Date
        try { $exitCode = $proc.ExitCode } catch {}
        break
    }
}
$alive = [bool]($proc -and -not $proc.HasExited)
"=== $Label : process seen=$seen firstSeen=$firstSeen exited=$exitAt aliveAtEnd=$alive"
if ($exitAt) { "exit code: $(if ($null -ne $exitCode) { '0x{0:X8} ({0})' -f $exitCode } else { 'unknown' })" }
if ($alive -and -not $KeepRunning) { Stop-Process -Name SparkingZERO-Win64-Shipping -Force; Start-Sleep -Seconds 2; "(game stopped by script)" }
$newDumps = Get-Dumps | Where-Object { $dumpsBefore -notcontains $_ }
"new crash dumps: $($newDumps -join ', ')"
if (Test-Path $log) {
    $lines = Get-Content $log
    "log lines: $($lines.Count), last write: $((Get-Item $log).LastWriteTime)"
    "--- [AE] lines"; $lines | Select-String -Pattern "\[AE" | ForEach-Object { $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length)) } | Select-Object -First 30
    "--- last 12 lines"; $lines | Select-Object -Last 12 | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) }
}
if (Test-Path $plog) { "--- plugin log"; Get-Content $plog | Select-Object -Last 40 }
