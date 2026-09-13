# End-to-end test of the speech pipe without the game or NVDA:
# starts pipe_server_stub.py (the add-on's server code with NVDA stubbed out),
# runs test_speech_pipe.lua with the mod's speech.lua, and checks the output.
# Requires python 3 and lua 5.4 (see helpers\Check-Lua.ps1).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$mod = Join-Path (Split-Path -Parent $here) 'SparkingZeroAccess'
$lua = (Get-Command lua -ErrorAction SilentlyContinue).Source
if (-not $lua) { $lua = Join-Path $env:LOCALAPPDATA 'Programs\Lua\bin\lua.exe' }
$out = Join-Path $env:TEMP 'sza_pipe_stub.txt'
$err = Join-Path $env:TEMP 'sza_pipe_stub_err.txt'

# Stop NVDA's copy of the server first or the stub cannot create the pipe.
$proc = Start-Process -FilePath python -ArgumentList "`"$(Join-Path $here 'pipe_server_stub.py')`" 6" `
    -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host '--- lua client'
& $lua (Join-Path $here 'test_speech_pipe.lua') $mod
$proc.WaitForExit()
Write-Host '--- stub output'
$lines = Get-Content -LiteralPath $out
$lines | ForEach-Object { Write-Host $_ }
if (Test-Path $err) { Get-Content -LiteralPath $err | ForEach-Object { Write-Host "stderr: $_" } }

$failures = 0
function Expect([string]$pattern, [string]$what) {
    if ($lines -match $pattern) { Write-Host "ok   $what" } else { Write-Host "FAIL $what"; $script:failures++ }
}
Expect 'SPEECH say: First line, interrupting' 'interrupting line spoken'
Expect 'SPEECH say: Second line, queued' 'queued line spoken'
Expect 'SPEECH say: Line with newline and carriage return' 'newlines replaced by spaces'
Expect 'Piccolo ' 'unicode line spoken'
Expect 'lines received: 5' 'exactly 5 lines received (empty ones ignored)'
$cancels = @($lines | Where-Object { $_ -eq 'SPEECH cancel' }).Count
if ($cancels -eq 4) { Write-Host 'ok   4 interrupts' } else { Write-Host "FAIL interrupts: $cancels"; $failures++ }
if ($failures -eq 0) { Write-Host 'ALL PASSED'; exit 0 } else { Write-Host "$failures FAILED"; exit 1 }
