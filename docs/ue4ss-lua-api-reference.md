# UE4SS Lua API Reference

Relevant APIs for the SparkingZeroAccess mod, ordered by priority.

---

## Level Transition Hooks

Critical for preventing crashes during map reloads (retry, return to menu).

- `RegisterLoadMapPreHook(function(Engine, WorldContext, URL, PendingGame, Error))` — fires BEFORE the map starts unloading. Use this to set a freeze flag that stops all UObject access in LoopAsync callbacks. Objects are still alive when this fires.
- `RegisterLoadMapPostHook(function(Engine, WorldContext, URL, PendingGame, Error))` — fires AFTER the new map has loaded. Use this to reset cached references and resume UObject access. Objects in the new map are alive.

## Async Loops

The mod no longer calls these directly: `game_thread.lua` owns scheduling and everything else runs inside its game thread tick (see "Experimental UE4SS build" below).

- `LoopAsync(delayMs, callback)` — runs callback every delayMs milliseconds on a separate Lua thread (NOT the game thread). Callback returns `false` to continue, `true` to stop the loop. Does NOT automatically stop during map transitions. All UObject access from within LoopAsync should be guarded by a transition flag or wrapped in ExecuteInGameThread.
- `ExecuteInGameThread(callback)` — queues a callback to run on the game thread. Use for UObject access that must happen on the game thread (e.g. reading TextBlock text that fails from async context).
- `ExecuteWithDelay(delayMs, callback)` — one-shot delayed execution on the mod's async thread, the same thread as LoopAsync. NOT the game thread (verified in v3.0.1 LuaMod.cpp).

Note: LoopAsync is deprecated in UE4SS dev builds. Replacement is `LoopInGameThreadWithDelay(delayMs, callback)` (not in v3.0.1) which returns a handle supporting `CancelDelayedAction(handle)`, `PauseDelayedAction(handle)`, `UnpauseDelayedAction(handle)`, `IsDelayedActionActive(handle)`.

### Verified threading (RE-UE4SS v3.0.1 src/Mod/LuaMod.cpp, 2026-09-12)

- `LoopAsync` / `ExecuteWithDelay`: each Lua mod has one async thread (wakes every 5 ms). The Lua call holds no lock
- `ExecuteInGameThread`: queued, then run on the game thread inside a ProcessEvent pre-callback. Never call it from code already running as a game thread action: UE4SS iterates the action list while running actions, so appending corrupts it
- `RegisterKeyBind`: callbacks run on the UE4SS event loop thread (under `m_thread_actions_mutex`), not the game thread
- `RegisterHook` on native UFunctions (e.g. `TextBlock:SetText`): callback on the game thread, no lock
- `NotifyOnNewObject`: callback runs on the thread that constructs the object, loading threads included. Matches subclasses
- All of these share one Lua state, which is not thread-safe
- `FindAllOf` / `FindFirstOf` with `bUseUObjectArrayCache = false` walk every object: about 45 ms each on this game (measured on the game thread). `bUseUObjectArrayCache = true` did not make them faster
- `FindAllOf` returns nil when nothing is found; `FindFirstOf` returns an object wrapper (check `IsValid`)
- Crash dumps from the World Tournament crash and all fix attempts: branch experiment/game-thread-registry

### Experimental UE4SS build (in use since 2026-09-12, UE4SS_v3.0.1-1133-gb4cefa18)

- Adds `LoopInGameThreadWithDelay`, `ExecuteInGameThreadWithDelay`, `ExecuteInGameThreadAfterFrames`, `IsInGameThread`, engine tick scheduling, NotifyOnNewObject callbacks queued to the game thread, FUObjectHashTables lookups
- Its bundled Lua 5.4.7 is modified (`lua_lock` → `LuaLock`), and UE4SS exports no Lua C API, so a Lua C module (the old `speech_bridge.dll`) makes the game close at startup. Speech therefore goes over a named pipe (`speech.lua` → NVDA add-on)
- The mod's `game_thread.lua` uses `LoopInGameThreadWithDelay(16, Tick)` when present and falls back to the 3.0.1 timer otherwise. Nothing outside game_thread.lua may call `LoopAsync`, `ExecuteWithDelay`, `ExecuteInGameThread` or `RegisterKeyBind` (`.luacheckrc` enforces it); use `GT.Every`, `GT.After`, `GT.OnKey`
- Installed with `helpers\Switch-UE4SS.ps1 -Build experimental`: `UE4SS.dll`, default mods and settings from the experimental zip, 3.0.1 `dwmapi.dll` proxy kept (flat Win64 layout; the experimental proxy expects a `ue4ss\` subfolder and is untested here)

### Transition hooks in this game (verified from UE4SS.log, 2026-09-12)

- `RegisterLoadMapPreHook` / `RegisterLoadMapPostHook` fire once at startup and never again: battle maps and menus load through seamless travel or streaming, not `UEngine::LoadMap`
- `RegisterHook("/Script/Engine.PlayerController:ClientRestart", ...)` fires on every world change (new PlayerController), including the World Tournament transition that used to crash. Candidate for pausing or resetting state on transitions
- The `UStruct::SuperStruct = 0x40` line in the member offsets dump identified the crash: the object walk called IsChildOf on a null class pointer of an object being destroyed

## UObject Lookup

- `FindAllOf(className)` — returns a Lua table of all live instances of the given class. Iterates UE's GUObjectArray at the C++ level. Can cause native access violations during map transitions if objects are being destroyed. Cannot be protected by pcall (crash happens in C++ before Lua error handling). Always guard with a transition flag.
- `FindFirstOf(className)` — returns the first non-CDO instance of the given class. Same native crash risk as FindAllOf during transitions.
- `StaticFindObject(fullPath)` — finds a specific object by its full path. Useful for singleton lookups like DataAssets.
- `NotifyOnNewObject(className, callback)` — event-driven alternative to FindAllOf polling. Fires when a new instance of the class is constructed. Callback receives the new object. Does not iterate stale objects. Return `true` from callback to auto-unregister (one-shot).

## UObject Validation

- `obj:IsValid()` — UE4SS API that checks UObject liveness via weak pointer system. Safe to call on potentially dead objects. Returns false if the object has been destroyed.
- `obj:HasAnyFlags(EObjectFlags.RF_BeginDestroyed)` — checks if the object is in the process of being destroyed. Available flags: `RF_BeginDestroyed` (0x00008000), `RF_FinishDestroyed` (0x00010000).
- `obj:GetFullName()` — returns the full UObject path. Can crash on truly dead objects; wrap in pcall when used on cached references.
- `obj:GetFName():ToString()` — returns the short object name. Faster than GetFullName for simple lookups.

## Hook Registration

- `RegisterHook(ufunctionPath, callback)` — hooks a UFunction. Callback receives (self, ...). Fires whenever the function is called by the engine. Active globally, including during map transitions. Use with caution for hooks that access UObjects in their callback.
- `RegisterKeyBind(Key.XX, callback)` — binds a key press to a callback. Runs on the UE4SS event loop thread, not the game thread. Does not consume the key.

## Actor/Gameplay Hooks

- `RegisterBeginPlayPreHook(function(ActorParam))` — fires before AActor::BeginPlay on every actor. Useful for re-acquiring references after a map transition.
- `RegisterBeginPlayPostHook(function(ActorParam))` — fires after AActor::BeginPlay.
- `RegisterInitGameStatePreHook(function(GameState))` — fires before AGameModeBase::InitGameState.
- `RegisterInitGameStatePostHook(function(GameState))` — fires after AGameModeBase::InitGameState.

## Object Iteration

- `ForEachUObject(function(obj, chunkIndex, indexInChunk))` — iterates ALL UObjects in memory. Expensive. Useful for discovery/debugging only.
- `obj:GetClass():ForEachProperty(function(property))` — iterates all UPROPERTYs on an object's class. Used for property dumps.
- `obj:GetClass():ForEachFunction(function(func))` — iterates all UFUNCTIONs on an object's class.

## Widget/UMG Access

- `widget:HasKeyboardFocus()` — returns true if the widget currently has keyboard focus. Can crash on stale widget refs during transitions.
- `widget:IsVisible()` — returns true if the widget is visible.
- `widget:GetChildrenCount()` / `widget:GetChildAt(index)` — child widget traversal.
- `widget:GetText():ToString()` — reads text from TextBlock/RichTextBlock widgets. May fail from LoopAsync context for some widgets (threading issue). Use ExecuteInGameThread as workaround.
- `image.Brush.ResourceObject:GetFName():ToString()` — reads the texture/material name from an Image widget's brush. Works from LoopAsync context.
- `switcher:GetActiveWidgetIndex()` — active page of a WidgetSwitcher. All pages report `IsVisible() == true`, so this is the only way to know which one is shown (e.g. CharaIcon Normal/Unknown/Lock, popup Info/Outline).
- `widget:GetRenderOpacity()` — widgets faded out by animations keep their visibility; closed Episode Battle popups have root opacity 0 while `IsVisible()` stays true.
- `widget:GetParent()` — parent panel. Useful when the element you need (e.g. `Overlay_Cursor`) is not a Blueprint variable but one of its children is.
- `userWidget.WidgetTree.RootWidget` — root of a UserWidget's own tree; combine with `GetChildrenCount`/`GetChildAt` on panels to walk the full hierarchy (see F6 dump in debug_tools.lua).
- Named child widgets marked "Is Variable" in the Blueprint are properties: `details.WidgetSwitcher_Main`, `piece.IMG_Corner_0`. Check the F6 dump's property list to see which ones exist.

## Game-Specific Findings (Sparking! ZERO)

- **FindAllOf with C++ base classes:** `FindAllOf("SSDragonAdventureIFCTEventDetailsManager")` returns the Blueprint subclass instances (`WBP_GRP_AI_ChartDetails_C`). Use the C++ base when Blueprint class names vary (the Episode Map has one class per saga). Returns nil when no instance exists yet.
- **`SSMenuWidget.bIsActive`:** game menu widgets expose a bool that is true while the menu is open/active. Not reliable for every class (Map_CharacterSelect stays false while visible).
- **Reading a property that doesn't exist** on a widget does not error: it returns a non-nil UObject-like value. Check `type(value) == "boolean"` (or the expected type) instead of `~= nil`.
- **Hot reload:** `EnableHotReloadSystem = 1` + Ctrl+R freezes the game and mod. Keep it off.
- **Actors:** `actor:K2_GetActorLocation()` returns a vector with X/Y/Z. `PlayerCameraManager:GetCameraLocation()` gives the camera position (the story map camera glides between nodes). Both used by the F7 trace; not yet verified in game.

## Key Safety Rules

1. Never call FindAllOf or FindFirstOf during map transitions. Guard with a flag set in RegisterLoadMapPreHook.
2. LoopAsync runs on a separate thread. UObject access is not thread-safe. Wrap in ExecuteInGameThread when needed.
3. pcall catches Lua errors only, not native C++ access violations. It cannot protect against FindAllOf crashes during transitions.
4. Cached UObject references become invalid after map transitions. Invalidate all caches in RegisterLoadMapPreHook.
5. RegisterHook callbacks fire globally, including during transitions. Avoid UObject access in hook callbacks without validation.

## Stale Widget Reference Crashes — Lessons Learned

During retry/reload in Sparking ZERO, UE4SS crashes (EXCEPTION_ACCESS_VIOLATION inside UE4SS.dll) when Lua code accesses cached widget references that point to destroyed UObjects. pcall cannot catch these — they are native C++ crashes.

### What causes the crash
- Cached UObject references (e.g. timer digit Image widgets, parent visibility widgets) survive across map reloads in module-level Lua variables
- LoopAsync callbacks continue running during and after reload at 16ms intervals
- When the callback accesses a cached ref that points to freed memory, UE4SS crashes before Lua error handling can intervene
- RegisterLoadMapPostHook fires AFTER the reload completes — too late to prevent access during the transition
- RegisterLoadMapPreHook is not available in UE4SS v3.0.1 stable (crashes on startup)

### What works
- **IsValidRef() on parent widgets before accessing children.** If you cache a parent widget (e.g. WBP_Rep_TimeCount_C for the timer), check `IsValidRef(parent)` before accessing any of its cached child widgets. If the parent is dead, all children are dead too. IsValid() uses UE's weak pointer system and is safe to call on dead objects.
- **Invalidate cache when IsValidRef fails.** Set all cached refs to nil and return nil. On the next tick, re-acquire fresh refs via FindFirstOf/FindAllOf.
- **Guard the nil check.** Use `if _cachedParent and not IsValidRef(_cachedParent)` — not just `if not IsValidRef(_cachedParent)`. The latter returns false for nil, which prevents re-caching.
- **Avoid constant FindFirstOf polling for widgets that don't always exist.** Polling for `WBP_GRP_BS_Result_03_DP_C` (result screen) every 16ms crashes during retry because the widget exists briefly then is destroyed. Instead, trigger the read from a focus event when a child button receives keyboard focus — the widget is guaranteed alive at that point.
- **Separate concerns: poll vs event-driven.** Use polling (LoopAsync) only for widgets that are continuously present during battle (HP gauge, timer). Use event-driven triggers (focus detection) for transient screens (result screen, victory screen).

### Pattern: Safe cached widget access
```
-- Cache a parent widget and its children once
local _parentWidget = nil
local _childRefs = nil

local function CacheRefs()
    local ok, parent = pcall(FindFirstOf, "SomeWidget_C")
    if not ok or not parent then return false end
    _parentWidget = parent
    _childRefs = { ... }  -- acquire children
    return true
end

local function ReadCachedValue()
    if not _childRefs then
        if not CacheRefs() then return nil end
    end
    -- Validate parent before touching children
    if _parentWidget and not IsValidRef(_parentWidget) then
        _parentWidget = nil
        _childRefs = nil
        return nil  -- will re-cache next tick
    end
    -- Safe to access _childRefs here
end
```
