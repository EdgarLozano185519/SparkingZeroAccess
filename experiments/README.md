# Experiments and offline tests

Tools that run without the game. Lua tests need Lua 5.4 (`winget install DEVCOM.Lua`, see `helpers\Check-Lua.ps1`); Python tools need Python 3 (standard library only).

## Speech pipe

- `test_speech_pipe.lua <mod scripts dir>` — sends test lines through `SparkingZeroAccess\speech.lua` (interrupt, queued, newlines, Unicode, icon markup, empty). The server side is the in-game plugin `speech_plugin\SparkingZeroSpeech.asi`, so run this while the game is running to hear the lines through your screen reader, or point it at any process that serves `\\.\pipe\SparkingZeroSpeech`.

## Game thread scheduler

- `test_game_thread.lua <mod scripts dir>` — `game_thread.lua` on UE4SS 3.0.1 (mocked `LoopAsync`, `ExecuteInGameThread`, `RegisterKeyBind`, fake clock): tick scheduling, key handling, delayed callbacks, stall recovery, timing logs
- `test_game_thread_native.lua <mod scripts dir>` — the same scheduler with `LoopInGameThreadWithDelay` (newer UE4SS builds; not usable on this game, see docs/known-issues.md)

```
%LOCALAPPDATA%\Programs\Lua\bin\lua.exe experiments\test_game_thread.lua SparkingZeroAccess
```

## In-game tests without a tester

`helpers\Launch-Game.ps1` starts the game through Steam, watches the process and `UE4SS.log`, stops the game, and prints the mod's log lines. `helpers\Drive-Game.ps1` does the same and sends keys at given seconds (`"40:{ENTER}"`, SendKeys syntax) to move through menus. Game-thread crashes end the process silently (no dump, no Windows event), so "process gone, log stops" is the signal.

## Crash dumps

UE4SS writes `crash_*.dmp` into `SparkingZERO\Binaries\Win64\` when a crash happens on one of its own threads. No debugger is needed to get the basics:

- `mdump.py crash_*.dmp` — exception code, faulting module and offset, registers, heuristic stack scan
- `threadroots.py crash_*.dmp ...` — which thread crashed and its entry module (a UE4SS Lua async thread vs the game thread)

Combine the faulting offset with the member offsets UE4SS prints at startup in `UE4SS.log` (for example `UStruct::SuperStruct = 0x40`): the original World Tournament crash was a read of address 0x40 from a null class pointer inside an object walk on the mod's async thread. See docs/crash-investigation-2026-09-12.md.
