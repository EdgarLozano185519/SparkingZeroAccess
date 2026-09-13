# Known Issues

## Mod Issues
- UE4SS GUI debug window disabled (GuiConsoleVisible=0) for accessibility
- Team slot character names use texture ID lookup — new DLC characters need to be added to chara_names.lua
- FindFirstOf may return CDO (class default object) instead of live instance — always check for "Transient" in path or use FindAllOf with path filtering
- UE4SS hot reload (Ctrl+R, EnableHotReloadSystem=1) freezes the game and the mod. Keep it disabled and restart the game after deploying
- Occasional crash on screen changes (World Tournament, title → main menu): the mod polls widgets from LoopAsync, off the game thread, while the game frees them. pcall cannot catch it. Fix attempts are parked on branch experiment/game-thread-registry: game thread polling is far too slow on UE4SS 3.0.1 (each FindAllOf/FindFirstOf walks all objects, ~45 ms), and NotifyOnNewObject callbacks run Lua on loading threads there
- UE4SS experimental builds are incompatible with speech_bridge.dll: their bundled Lua is modified with thread locks (lua_lock → LuaLock), and UE4SS exports no Lua C API to link against. Stay on UE4SS 3.0.1 unless speech moves to a UE4SS C++ mod
- bUseUObjectArrayCache = true does not speed up lookups on 3.0.1 and makes loading very slow. Keep it false
- Episode Battle story map: the episode nodes are 3D level actors (Map800_Chart_* level instance), not widgets. Cleared/locked status per node is not read yet; chart_actors.txt (F6) is the starting point
- Episode Battle story map: on path nodes Text_EventTitle is collapsed but keeps the previous episode's text. Detect "back on an episode" by title visibility, not text changes
- Episode Battle story map: consecutive path nodes only differ in the title panel's OtherCharaIcon portraits. What the portraits represent is unconfirmed
- Episode Battle popups (Details/Recap, Episode Map) stay alive and IsVisible() after closing, with their root at opacity 0. Use SSMenuWidget.bIsActive + opacity to detect "open"
- Episode Map "main story" / "what if" route labels are a guess: row 00 = main story, other rows = what if
