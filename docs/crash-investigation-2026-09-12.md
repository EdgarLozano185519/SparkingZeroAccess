# Crash Investigation (2026-09-12), from branch experiment/game-thread-registry

Preserved from that branch's project_status.md before the branch was deleted (2026-09-13). Its game_thread.lua, crash dump readers and offline tests were merged into feature/pipe-speech-game-thread; its objects.lua registry (NotifyOnNewObject based) was NOT taken: on UE4SS 3.0.1 those callbacks run Lua on loading threads. Numbers here predate the per-class cache in the current objects.lua.


User report: game crashes when moving to World Tournament from the main menu.

Evidence (8 dumps 2026-09-12/13, 5 readable; parsed with stdlib Python scripts, no debugger or UE4SS PDB installed):
- All 5 crashes are inside UE4SS.dll, never in game code, never on the game's main thread
- 3x access violation reading freed or null UObject memory (one read at 0xC = UObjectBase::InternalIndex of a null object), 2x 0xC0000264 (lock released by a thread that did not own it)
- Every enabled Lua mod gets one UE4SS async thread (7 mods, 7 threads with the same entry point). 4 of 5 crashes are on the first of those threads, which is SparkingZeroAccess (first in mods.txt). The 5th was on the UE4SS event loop thread with nvdaControllerClient.dll on the stack (speech call)
- Other enabled mods do not poll (one-off hooks only)
- Latest crash (01:38:45) came 4 seconds after "Press confirm to start"; nothing else logged

Likely cause: LoopAsync polling (16 ms focus loop, 100 ms poll loop) reads UObjects off the game thread. Only LoadMap transitions are guarded; menu screen changes like World Tournament free widgets without a map load. pcall cannot catch these native crashes. Also the global TextBlock:SetText hook (team_overview.lua) runs Lua on the game thread for every text change, concurrently with the async loops.

UE4SS v3.0.1 threading, verified in RE-UE4SS v3.0.1 LuaMod.cpp (details in docs/ue4ss-lua-api-reference.md): LoopAsync and ExecuteWithDelay run on the mod's async thread with no lock; RegisterKeyBind runs on the event loop thread; ExecuteInGameThread runs inside a ProcessEvent pre-callback on the game thread. Calling ExecuteInGameThread from inside a game thread action corrupts UE4SS's action list.

Fix (2026-09-12, UNTESTED in game):
- New game_thread.lua: one LoopAsync(16) timer that only queues a single game thread tick (never more than one queued). The tick runs key handlers, GT.After callbacks, and GT.Every tasks. API: GT.Every(name, ms, fn), GT.After(ms, name, fn), GT.OnKey(key, name, fn), GT.Cancel(task), GT.Measure(name, fn, ...)
- main.lua: focus loop, poll loop, and watchdog replaced by one "Reader" task. PollFocus every tick, then ONE slow poll group per tick in rotation (8 groups, about 160 ms each). Empty focus scans back off to 1-in-12 after 60 ticks (battles)
- ExecuteWithDelay calls (team guide bar, dialog button label, title screen) now GT.After; the dialog label checks IsValidRef first
- debug_tools.lua: F3-F8 via GT.OnKey, dump/trace loops via GT.Every
- team_overview.lua: removed the unused global TextBlock:SetText hook (captured name had no readers); hold captions read directly instead of ExecuteInGameThread
- .luacheckrc: LoopAsync, ExecuteWithDelay, ExecuteInGameThread, RegisterKeyBind allowed only in game_thread.lua (W113 elsewhere, check fails)
- Diagnostics in UE4SS.log: "[AE] Slow game thread task: NAME took X ms" (over 12 ms, max one line per 2 s) and every 60 s "[AE] Game thread 60s: N ticks, avg, max, slowest tasks"
- Offline test (scratchpad, mocked UE4SS + fake clock) passed: tick rate, intervals, stop/cancel, errors, keys, After, no tick pile-up, stall requeue, logs

Test result 1 (2026-09-12): game significantly slower. UE4SS.log timing: ticks avg 37-73 ms (11-16 ticks/s instead of 60). Each GUObjectArray walk (FindAllOf/FindFirstOf with bUseUObjectArrayCache=false) costs about 45 ms on the game thread: PollRoom/PollHelpWindows (1 walk) ~45 ms, PollDialogs (2) ~90 ms, PollScreenChanges (3) up to 433 ms, PollFocus ~60 ms. Reading felt more consistent; no new crash dumps.

Experiment 2 (2026-09-12, UNTESTED): bUseUObjectArrayCache = true in the game's UE4SS-settings.ini (was false since the initial commit, no documented reason; UE4SS says false only helps startup crashes). Cache makes FindAllOf/FindFirstOf use per-class lists instead of walking GUObjectArray. installer\build.ps1 still writes false: change it only if this works.
- If the game crashes on startup: set it back to false, then plan B = event-driven widget registry via NotifyOnNewObject("/Script/UMG.UserWidget") replacing the 79 FindAllOf/FindFirstOf calls (callback runs on the constructing thread, matches subclasses, no lock)
- If still slow: compare the "[AE] Game thread 60s" summaries with result 1
- Fallback for normal play meanwhile: previous async build from git (HEAD), crash-prone

Result 2 (2026-09-12): FAILED. Main menu and World Tournament took very long to load; ticks still 35-52 ms (PollHelpWindows, one lookup, still ~32 ms), plus "tick did not run for 10s" twice. Setting reverted to false. The UE4SS 3.0.1 cache does not speed up FindAllOf/FindFirstOf here.

Fix 3 (2026-09-12, UNTESTED in game): object registry, objects.lua
- NotifyOnNewObject on root classes (UserWidget, TextBlock, RichTextBlock, Image, Pawn, PlayerController, PlayerCameraManager). Callback only appends to a queue (it runs on the constructing thread); the game thread tick registers queued objects (400 per tick, or all when a lookup needs them)
- Registration: skip class defaults ("Default__") and, for widget roots, non-Transient Blueprint templates. Store {obj, full name, address, class address} under every class name from the object's class up to its root, so lookups by Blueprint name or C++ base class work
- Objects.FindAllOf / FindFirstOf (nil when none) / PathOf (cached GetFullName). Lists are IsValid-checked at most once per tick (GC never runs inside a tick; map load hooks call Objects.InvalidateValidation). Prune task re-checks one root list every 2 s (IsValid + class address, catches reused addresses)
- Untracked classes (GameInstance, debug dumps) fall back to a real walk, logged once, reused for 2 s. KNOWN_CLASS_ROOTS maps classes looked up before any instance exists (BP_BattlePlayerController_C, SSDragonAdventureIFCT* widget bases); "WBP_" names are always UserWidget
- Startup: one walk per root (seed) on the first tick. A root with zero reports after 30 s switches to full walks (warning), except Pawn
- Migration: script replaced 92 FindAllOf/FindFirstOf and 122 :GetFullName() calls in 12 files with Objects.*; .luacheckrc allows FindAllOf/FindFirstOf/NotifyOnNewObject only in objects.lua
- Offline test (scratchpad, fake UE4SS objects) passed: subclass/base lookups, templates and class defaults skipped, destroyed objects, address reuse, path cache, invalidation, untracked fallback
- Log: "[AE] Objects: startup walk found N", every 60 s "[AE] Objects: UserWidget N (+new, reported) ...; templates skipped; full walks: ...", plus the game thread timing lines

Result 3 (2026-09-12): FAILED. Game closed to desktop more often. No UE4SS crash dump, no Windows error event, no WER report; UE4SS.log ends ~6 s after "Press confirm to start". Likely cause: on UE4SS 3.0.1, NotifyOnNewObject callbacks run on the constructing thread (async loading thread) while game thread Lua runs; Lua is not thread-safe, corruption kills the process without a dump. Also found: "UserWidget" lookups fell back to walks until the first UserWidget registered (fixed: roots map to themselves).

After 3 failed attempts, user chose: try a newer UE4SS.

Experiment 4 (2026-09-12, UNTESTED in game): UE4SS experimental build
- File: UE4SS_v3.0.1-1133-gb4cefa18.zip from RE-UE4SS release "experimental-latest" (rolling tag), SHA-256 89B7EED47C37D6FF6EAA144A41311A75098279A3454777F4EDD2446CEA1EA7A8, cached in build\cache
- Why it should help (checked in RE-UE4SS main LuaMod.cpp): LoopInGameThreadWithDelay / ExecuteInGameThread run on the engine tick with pending queues (safe to schedule from game thread code); NotifyOnNewObject calls Lua directly only on the game thread and queues callbacks from other threads to the engine tick; lookups use FUObjectHashTables when available. LoopAsync still runs Lua unlocked on the async thread (deprecated, no longer used by the mod there). Bundled Lua 5.4.7 = speech_bridge.dll's Lua 5.4.7
- Installed in place (documented compatibility path): only Win64\UE4SS.dll replaced; 3.0.1 dwmapi.dll proxy, Win64 layout, Mods folder, mods.txt unchanged (mods.txt still controls loading; mods.json is not read at startup). Default UE4SS mods (BPModLoaderMod, Keybinds, shared, ...) updated from the zip
- UE4SS-settings.ini: experimental template, current values kept for existing keys (bUseUObjectArrayCache=false, GraphicsAPI=dx11, GuiConsoleVisible=0, ConsoleEnabled=0, EnableHotReloadSystem=0), new defaults for new keys (DefaultExecuteInGameThreadMethod=EngineTick, HookEngineTick=1, ...), SecondsToScanBeforeGivingUp=120
- Backup of 3.0.1: build\backup\ue4ss-3.0.1 (dwmapi.dll, UE4SS.dll, UE4SS-settings.ini, Mods). Restore: close the game, copy those three files and the Mods folder back into Win64
- Mod: game_thread.lua uses LoopInGameThreadWithDelay(16, Tick) when present (log "[AE] Game thread scheduler started (LoopInGameThreadWithDelay)"), else the 3.0.1 LoopAsync timer. objects.lua unchanged apart from the root-name fix. Offline tests pass for both scheduler paths and the registry
- installer\build.ps1 and Deploy paths still assume UE4SS 3.0.1: update only if the experimental build works

Result 4 (2026-09-12): FAILED. Game closes on startup. UE4SS experimental itself loads fine (AOB scans, EngineTick hook, mods start); UE4SS.log ends right after "[AE] Initializing SparkingZeroAccess Phase 2...", i.e. inside require("speech_bridge"). No dump, no Windows error event.
- Cause: experimental UE4SS ships a modified Lua 5.4.7 (deps/first/LuaRaw): luaconf.h defines lua_lock/lua_unlock as LuaLock/LuaUnlock and luai_userstateopen/close/thread as LuaLockInitial/LuaLockFinal (declared in lua.h). speech_bridge.dll statically links vanilla Lua 5.4.7 and runs its own copy of the Lua core on UE4SS's lua_State. UE4SS 3.0.1 used unmodified Lua 5.4.4, which worked with it
- UE4SS.dll exports no Lua C API (0 lua_* exports in both 3.0.1 and experimental) and not LuaLock, so a Lua C module cannot be built compatibly. Speech on experimental UE4SS would need a UE4SS C++ mod
- Restore: UE4SS 3.0.1 files, default mods and mods.txt copied back from build\backup\ue4ss-3.0.1 (hash-verified)

Decision (user, 2026-09-12): restore a working game. main = last commit (async polling, fast, occasional transition crash) plus the F2 battle toggle. This whole investigation (game_thread.lua, objects.lua, migration, offline tests in experiments\) is kept on branch experiment/game-thread-registry.

Lessons for any future attempt:
- UE4SS 3.0.1: game thread Lua is safe from UObject races but every FindAllOf/FindFirstOf walk costs ~45 ms; NotifyOnNewObject callbacks run on loading threads (Lua corruption)
- UE4SS experimental: fixes both (engine tick scheduling, NotifyOnNewObject queued to the game thread, hash table lookups) but breaks speech_bridge.dll (modified Lua). Needs speech as a C++ mod first
- [ ] World Tournament from the main menu: no crash, menus still read
- [ ] Title screen → main menu several times: no crash, "Press confirm to start" still spoken
- [ ] Menu responsiveness: focus announcements as fast as before?
- [ ] Battle: any new stutter? HP/KI announcements still work? (then send UE4SS.log: slow task lines and 60 s summaries)
- [ ] Team setup: guide bar shortcuts incl. hold buttons still read
- [ ] Dialogs: body text, then button label after 1.5 s
- [ ] F5/F7/F8 debug keys still work
- [ ] New crash_*.dmp files in Win64? If yes, keep them for analysis

## Phase 1: UI Exploration (DONE)
- [x] First UI dump completed (F10 / SparkingZeroAccess_dump.txt)
- UE5 built-in accessibility system: NOT available (compiled out)
- 688 TextBlocks, 487 RichTextBlocks — text is readable from widgets
- Game uses standard UMG widgets (TextBlock, Button, WidgetSwitcher, etc.)
- Game HUD: SSMainGameHUD, GameInstance: BP_SSGameInstance_C
- Key widget classes identified:
  - WBP_Title_C — title screen
  - WBP_Title_Button_C / WBP_Title_Button_PC_C — title buttons
  - WBP_Option_C — options menu
  - WBP_BTN_PauseMenu_C — pause menu buttons
  - WBP_Dialog_000_C / WBP_Dialog_002_C — dialogs
  - WBP_MainMenu_Base_TextSub_C — main menu text
  - WBP_OBJ_Option_List_* — option list items

