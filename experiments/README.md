# Experiments and offline tests

Tools that run without the game. Lua tests need Lua 5.4 (`winget install DEVCOM.Lua`, see `helpers\Check-Lua.ps1`); Python tools need Python 3 (standard library only).

## Speech pipe

- `Test-SpeechPipe.ps1` — end-to-end test of `SparkingZeroAccess\speech.lua` against the NVDA add-on's pipe server code, with NVDA stubbed out. Starts `pipe_server_stub.py`, runs `test_speech_pipe.lua`, checks what would have been spoken. NVDA's copy of the add-on must not be running (it owns the pipe), so stop NVDA or uninstall the add-on first.
- `pipe_server_stub.py [seconds]` — runs the add-on's `PipeSpeechServer` outside NVDA and prints every line it receives. Handy for watching what the game sends: start it, then start the game without NVDA.
- `test_speech_pipe.lua <mod scripts dir>` — sends test lines through `speech.lua` (interrupt, queued, newlines, Unicode, icon markup, empty).

## Game thread scheduler

- `test_game_thread.lua <mod scripts dir>` — `game_thread.lua` on UE4SS 3.0.1 (mocked `LoopAsync`, `ExecuteInGameThread`, `RegisterKeyBind`, fake clock): tick scheduling, key handling, delayed callbacks, stall recovery, timing logs
- `test_game_thread_native.lua <mod scripts dir>` — the same scheduler on newer UE4SS with `LoopInGameThreadWithDelay`

```
%LOCALAPPDATA%\Programs\Lua\bin\lua.exe experiments\test_game_thread_native.lua SparkingZeroAccess
```

## Crash dumps

UE4SS writes `crash_*.dmp` into `SparkingZERO\Binaries\Win64\` when the game crashes. No debugger is needed to get the basics:

- `mdump.py crash_*.dmp` — exception code, faulting module and offset, registers, heuristic stack scan
- `threadroots.py crash_*.dmp ...` — which thread crashed and its entry module (a UE4SS Lua async thread vs the game thread)

Combine the faulting offset with the member offsets UE4SS prints at startup in `UE4SS.log` (for example `UStruct::SuperStruct = 0x40`): the World Tournament crash was a read of address 0x40 from a null class pointer inside an object walk on the mod's async thread.
