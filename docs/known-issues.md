# Known Issues

## Open (2026-09-13, branch feature/pipe-speech-game-thread)
- World Tournament → offline mode still crashes the game (user test 2026-09-13, silent exit: no crash dump, no Windows error event, UE4SS.log just stops). Game-thread crashes inside UE's guarded main loop always exit like this; the speech plugin could install a vectored exception handler that writes a minidump to get evidence
- Title screen regression: "Press confirm to start" and the title buttons were not read (user test 2026-09-13). Cause in the log: the registry walked the title widget classes while the game was still loading (0 objects), marked them absent, and re-walks absent classes only every 60 s. objects.lua needs a faster cadence for widget classes while not in battle (a walk is ~45 ms, harmless in menus), and a re-walk when a screen change is detected or focus is nowhere
- The installer ships the plugin files (added 2026-09-13) but has not been built or tested since

## Mod Issues
- UE4SS GUI debug window disabled (GuiConsoleVisible=0) for accessibility
- Team slot character names use texture ID lookup — new DLC characters need to be added to chara_names.lua
- FindFirstOf may return CDO (class default object) instead of live instance — always check for "Transient" in path or use FindAllOf with path filtering
- UE4SS hot reload (Ctrl+R, EnableHotReloadSystem=1) freezes the game and the mod. Keep it disabled and restart the game after deploying
- Crash on screen changes (World Tournament, title → main menu) in versions up to 1.0.1: the mod polled widgets from LoopAsync, off the game thread, while the game freed them (dump: read of 0x40 = UStruct::SuperStruct through a null class pointer inside an object walk). pcall cannot catch it. Since 2026-09-12 all polling runs on the game thread (game_thread.lua) and lookups come from objects.lua's cache; the World Tournament crash still happens, cause unknown (see Open)
- The LoadMap hooks (RegisterLoadMapPreHook/PostHook) never fire in this game after startup: the battle map and menu transitions use seamless travel or streaming. `[AE] Map loaded` appears once per launch. main.lua tracks the PlayerController instead: every world gets a new one, so the old one dying is the world-change signal
- RegisterHook on `/Script/Engine.PlayerController:ClientRestart` from this mod killed the game at startup (2 of 2 runs, 2026-09-13), although CheatManagerEnablerMod hooks the same function. Probably Lua running on the hook thread while the mod's LoopAsync timer runs Lua too. Don't add RegisterHook callbacks to this mod while the timer path is in use
- Walking the base classes with FindAllOf("Widget") or FindAllOf("Actor") killed the game (2026-09-13). Only walk the class names the mod already used (UserWidget, TextBlock, RichTextBlock, Image, WBP_*, Pawn, PlayerController, GameInstance, ...). No walk during the first 5 s after mod start either (game still loading)
- UE4SS 3.0.1 Lua: UFunctions with out params are broken (an out param followed by other params leaves its table on the Lua stack; TArray out params are never written back), so engine enumerators like WidgetBlueprintLibrary::GetAllWidgetsOfClass cannot be used. Errors from such calls arrive as a Lua function value, not a message
- UE4SS 3.0.1 Lua: NotifyOnNewObject callbacks run Lua on the thread that constructs the object (loading threads included) with no lock. Not usable
- UE4SS experimental builds (tested UE4SS_v3.0.1-1133-gb4cefa18) kill this game about 3 s after the mods start, even with SparkingZeroAccess disabled in mods.txt, with no dump. Stay on 3.0.1 (helpers\Switch-UE4SS.ps1 -Build stable restores it)
- On 3.0.1 every FindAllOf/FindFirstOf walks all objects: 28–50 ms each on the game thread (136–150 ms while the game loads). objects.lua walks at most one class per tick, none while a battle is busy
- bUseUObjectArrayCache = true does not speed up lookups on 3.0.1 and makes loading very slow. Keep it false
- Episode Battle story map: the episode nodes are 3D level actors (Map800_Chart_* level instance), not widgets. Cleared/locked status per node is not read yet; chart_actors.txt (F6) is the starting point
- Episode Battle story map: on path nodes Text_EventTitle is collapsed but keeps the previous episode's text. Detect "back on an episode" by title visibility, not text changes
- Episode Battle story map: consecutive path nodes only differ in the title panel's OtherCharaIcon portraits. What the portraits represent is unconfirmed
- Episode Battle popups (Details/Recap, Episode Map) stay alive and IsVisible() after closing, with their root at opacity 0. Use SSMenuWidget.bIsActive + opacity to detect "open"
- Episode Map "main story" / "what if" route labels are a guess: row 00 = main story, other rows = what if
