-- luacheck config for SparkingZeroAccess (UE4SS v3.0.1, Lua 5.4)
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
    -- Scheduling / threading
    "LoopAsync", "ExecuteWithDelay", "ExecuteInGameThread", "ExecuteAsync",
    -- Input
    "RegisterKeyBind", "IsKeyBindRegistered", "Key", "ModifierKey",
    -- Hooks
    "RegisterHook", "UnregisterHook",
    "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
    "RegisterInitGameStatePreHook", "RegisterInitGameStatePostHook",
    "RegisterBeginPlayPreHook", "RegisterBeginPlayPostHook",
    -- Types / reflection
    "PropertyTypes", "FName", "FText", "FString",
}

exclude_files = { "build/**", "speech_bridge/**" }
