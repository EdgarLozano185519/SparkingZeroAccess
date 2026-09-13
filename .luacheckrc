-- luacheck config for SparkingZeroAccess (UE4SS 3.0.1, Lua 5.4)
-- Run via: powershell -ExecutionPolicy Bypass -File helpers\Check-Lua.ps1

std = "lua54"
max_line_length = false

-- UE4SS hook callbacks receive arguments we often don't need (engine, world, url, ...)
unused_args = false

-- Globals provided by UE4SS at runtime
read_globals = {
    -- Object lookup
    "FindAllOf", "FindFirstOf", "StaticFindObject", "ForEachUObject",
    "NotifyOnNewObject", "StaticConstructObject", "CreateInvalidObject",
    -- Scheduling / threading and RegisterKeyBind: NOT listed here on purpose.
    -- Their callbacks run off the game thread (see game_thread.lua), so only
    -- game_thread.lua may call them. Everything else uses GT.Every / GT.After /
    -- GT.OnKey. Using them elsewhere fails the check (W113).
    -- Input
    "IsKeyBindRegistered", "Key", "ModifierKey",
    -- Hooks
    "RegisterHook", "UnregisterHook",
    "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
    "RegisterInitGameStatePreHook", "RegisterInitGameStatePostHook",
    "RegisterBeginPlayPreHook", "RegisterBeginPlayPostHook",
    -- Types / reflection
    "PropertyTypes", "FName", "FText", "FString",
}

exclude_files = { "build/**", "speech_bridge/**" }

-- objects.lua captures the real UE4SS lookups; main.lua replaces the globals with the cached versions
files["**/main.lua"] = {
    globals = { "FindAllOf", "FindFirstOf" },
}

files["**/game_thread.lua"] = {
    read_globals = { "LoopAsync", "ExecuteInGameThread", "RegisterKeyBind", "LoopInGameThreadWithDelay" },
}
