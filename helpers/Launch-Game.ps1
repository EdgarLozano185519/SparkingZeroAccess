# Starts the game through Steam, watches the process and UE4SS.log, then stops the game.
param([int]$Timeout = 80, [switch]$KeepRunning, [string]$Label = "run")
$w = "C:\Program Files (x86)\Steam\steamapps\common\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64"
$log = "$w\UE4SS.log"
$plog = "$w\plugins\SparkingZeroSpeech.log"
$start = Get-Date
$dumpsBefore = @(Get-ChildItem "$w\crash_*.dmp" | Select-Object -ExpandProperty Name)
Start-Process "steam://rungameid/1790600"
$seen = $false; $exitAt = $null; $firstSeen = $null
while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
    Start-Sleep -Seconds 2
    $p = Get-Process -Name SparkingZERO-Win64-Shipping -ErrorAction SilentlyContinue
    if ($p) { if (-not $seen) { $firstSeen = Get-Date }; $seen = $true }
    elseif ($seen) { $exitAt = Get-Date; break }
}
$alive = [bool](Get-Process -Name SparkingZERO-Win64-Shipping -ErrorAction SilentlyContinue)
"=== $Label : process seen=$seen firstSeen=$firstSeen exited=$exitAt aliveAtEnd=$alive"
if ($alive -and -not $KeepRunning) { Stop-Process -Name SparkingZERO-Win64-Shipping -Force; Start-Sleep -Seconds 2; "(game stopped by script)" }
$dumpsAfter = @(Get-ChildItem "$w\crash_*.dmp" | Select-Object -ExpandProperty Name)
$newDumps = $dumpsAfter | Where-Object { $dumpsBefore -notcontains $_ }
"new crash dumps: $($newDumps -join ', ')"
if (Test-Path $log) {
    $lines = Get-Content $log
    "log lines: $($lines.Count), last write: $((Get-Item $log).LastWriteTime)"
    "--- [AE] lines"; $lines | Select-String -Pattern "\[AE" | ForEach-Object { $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length)) } | Select-Object -First 30
    "--- last 12 lines"; $lines | Select-Object -Last 12 | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) }
}
if (Test-Path $plog) { "--- plugin log"; Get-Content $plog | Select-Object -Last 15 }
