# Known Issues

## Mod Issues
- UE4SS GUI debug window disabled (GuiConsoleVisible=0) for accessibility
- Team slot character names use texture ID lookup — new DLC characters need to be added to chara_names.lua
- FindFirstOf may return CDO (class default object) instead of live instance — always check for "Transient" in path or use FindAllOf with path filtering
- UE4SS hot reload (Ctrl+R, EnableHotReloadSystem=1) freezes the game and the mod. Keep it disabled and restart the game after deploying
- Crash on screen changes (World Tournament, title → main menu) in versions up to 1.0.1: the mod polled widgets from LoopAsync, off the game thread, while the game freed them (dump: read of 0x40 = UStruct::SuperStruct through a null class pointer inside an object walk). pcall cannot catch it. Since 2026-09-12 all polling runs on the game thread (game_thread.lua) on the experimental UE4SS build; UNTESTED in game
- The LoadMap hooks (RegisterLoadMapPreHook/PostHook) never fire in this game after startup: the battle map and menu transitions use seamless travel or streaming. `[AE] Map loaded` appears once per launch. PlayerController:ClientRestart (hooked by CheatManagerEnablerMod) does fire on every world change and is the usable transition signal
- The game thread scheduler falls back to LoopAsync + ExecuteInGameThread on UE4SS 3.0.1, where every FindAllOf/FindFirstOf walks all objects (~45 ms) and the game becomes very slow. NotifyOnNewObject callbacks run Lua on loading threads on 3.0.1 (registry attempt on branch experiment/game-thread-registry closed the game)
- UE4SS experimental builds are incompatible with a Lua C module: their bundled Lua is modified with thread locks (lua_lock → LuaLock), and UE4SS exports no Lua C API to link against. speech_bridge.dll was retired for that reason; speech now goes over a named pipe to the NVDA add-on. Only NVDA is supported until a standalone pipe speech helper (UniversalSpeech) exists
- Installer (installer\build.ps1) still stages UE4SS 3.0.1. The experimental build (UE4SS_v3.0.1-1133-gb4cefa18.zip, cached in build\cache) is installed with helpers\Switch-UE4SS.ps1 until it is confirmed and pinned in the installer
- bUseUObjectArrayCache = true does not speed up lookups on 3.0.1 and makes loading very slow. Keep it false
- Episode Battle story map: the episode nodes are 3D level actors (Map800_Chart_* level instance), not widgets. Cleared/locked status per node is not read yet; chart_actors.txt (F6) is the starting point
- Episode Battle story map: on path nodes Text_EventTitle is collapsed but keeps the previous episode's text. Detect "back on an episode" by title visibility, not text changes
- Episode Battle story map: consecutive path nodes only differ in the title panel's OtherCharaIcon portraits. What the portraits represent is unconfirmed
- Episode Battle popups (Details/Recap, Episode Map) stay alive and IsVisible() after closing, with their root at opacity 0. Use SSMenuWidget.bIsActive + opacity to detect "open"
- Episode Map "main story" / "what if" route labels are a guess: row 00 = main story, other rows = what if
