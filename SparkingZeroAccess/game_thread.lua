--[[
    game_thread.lua — runs all mod work on the game thread

    UE4SS v3.0.1 threading (checked in RE-UE4SS v3.0.1 src/Mod/LuaMod.cpp):
    - LoopAsync and ExecuteWithDelay callbacks run on the mod's async thread,
      with no lock around the Lua call
    - RegisterKeyBind callbacks run on the UE4SS event loop thread
    - ExecuteInGameThread callbacks run on the game thread, inside a
      ProcessEvent pre-callback
    Reading UObjects from the async thread raced with the game freeing widgets
    on screen changes (World Tournament, title screen): access violations
    inside UE4SS.dll that pcall cannot catch. These threads also share one Lua
    state without a lock, so Lua must not run on two of them at once.

    Rules for the rest of the mod (enforced by .luacheckrc):
    - Don't call LoopAsync, ExecuteWithDelay, ExecuteInGameThread or
      RegisterKeyBind. Use GT.Every, GT.After and GT.OnKey.
    - Never call ExecuteInGameThread from game thread code. UE4SS loops over
      its action list while running an action; queuing from inside one
      modifies that list mid-loop.

    Newer UE4SS (experimental builds) has LoopInGameThreadWithDelay, which
    runs Tick directly on the game thread every TIMER_INTERVAL_MS (engine
    tick). GT.Start uses it when present; the timer below is the UE4SS 3.0.1
    fallback.

    How it works (UE4SS 3.0.1):
    - One LoopAsync timer. It only compares numbers and, when no tick is
      queued and the last one ended at least MIN_GAP_SECONDS ago, queues Tick
      with ExecuteInGameThread. No prints, string building or UObject access
      on the async thread.
    - Keybind callbacks only set a flag; Tick runs the handler.
    - Tick runs pressed-key handlers, due GT.After callbacks, then every
      GT.Every task whose interval elapsed, and records timings. Slow tasks
      and a periodic summary are logged with the [AE] prefix.
]]

local GT = {}

-- About 60 ticks per second, like the old 16 ms focus loop
local TIMER_INTERVAL_MS = 16
-- Idle time between the end of one tick and queuing the next. Lets UE4SS
-- finish its own bookkeeping after the action, and gives the game thread room
-- when ticks get slow.
local MIN_GAP_SECONDS = 0.008
-- A queued tick only goes missing if UE4SS drops it. Loading screens can hold
-- the game thread for seconds, so wait long before queuing another one.
local STALL_REQUEUE_SECONDS = 10.0
local SLOW_TASK_MS = 12
local SLOW_LOG_INTERVAL_SECONDS = 2.0
local STATS_INTERVAL_SECONDS = 60.0

-- Shared with the async timer. After GT.Start only existing number/boolean
-- fields are written, so neither thread allocates in or rehashes this table.
local _timer = {
    queued = false,
    queuedAt = 0.0,
    finishedAt = 0.0,
    requeues = 0,
    queueErrors = 0,
    nativeFallback = false,
}
local _reportedNativeFallback = false
local _started = false
local _tickId = 0  -- increments at the start of every tick

-- Game thread only (plus registration during mod init)
local _tasks = {}       -- {name, interval, nextRun, fn, stopped}
local _after = {}       -- {due, name, fn}
local _keys = {}        -- {name, fn}
local _keyPressed = {}  -- same index as _keys; set by the keybind thread

-- Timing diagnostics (game thread only)
local _taskMaxMs = {}
local _windowStart = 0.0
local _tickCount = 0
local _tickTotalMs = 0.0
local _tickMaxMs = 0.0
local _lastSlowLog = -math.huge
local _reportedRequeues = 0
local _reportedQueueErrors = 0

--- Id of the current (or last) game thread tick. Work can be cached for one
--- tick: garbage collection never runs inside a tick.
function GT.TickId()
    return _tickId
end

--- Run fn(...) protected and timed. Errors are logged with the name.
--- Game thread only. Returns pcall's ok and first result.
function GT.Measure(name, fn, ...)
    local startedAt = os.clock()
    local ok, result = pcall(fn, ...)
    local ms = (os.clock() - startedAt) * 1000
    if not ok then
        print("[AE] " .. name .. " error: " .. tostring(result))
    end
    local prevMax = _taskMaxMs[name]
    if not prevMax or ms > prevMax then
        _taskMaxMs[name] = ms
    end
    if ms >= SLOW_TASK_MS and startedAt - _lastSlowLog >= SLOW_LOG_INTERVAL_SECONDS then
        _lastSlowLog = startedAt
        print(string.format("[AE] Slow game thread task: %s took %.1f ms", name, ms))
    end
    return ok, result
end

--- Run fn every intervalMs on the game thread (0 = every tick, about 20 ms).
--- fn returns true to stop. Returns a handle for GT.Cancel.
function GT.Every(name, intervalMs, fn)
    local task = { name = name, interval = intervalMs / 1000, nextRun = 0.0, fn = fn, stopped = false }
    _tasks[#_tasks + 1] = task
    return task
end

--- Stop a GT.Every task. Accepts nil.
function GT.Cancel(task)
    if task then
        task.stopped = true
    end
end

--- Run fn once on the game thread, at least delayMs from now.
function GT.After(delayMs, name, fn)
    _after[#_after + 1] = { due = os.clock() + delayMs / 1000, name = name, fn = fn }
end

--- Run fn on the game thread when key is pressed. Call during mod init.
function GT.OnKey(key, name, fn)
    local index = #_keys + 1
    _keys[index] = { name = name, fn = fn }
    _keyPressed[index] = false
    RegisterKeyBind(key, function()
        -- UE4SS event loop thread: only set the existing flag
        _keyPressed[index] = true
    end)
end

local _prologue = nil

--- fn(tickId) runs first in every tick, before keys, delayed callbacks and
--- tasks (objects.lua's GC check, which must precede any object access).
function GT.SetTickPrologue(fn)
    _prologue = fn
end

local function RunTick(now)
    if _prologue then
        GT.Measure("TickPrologue", _prologue, _tickId)
    end
    -- Timer events are reported here: printing on the async thread allocates
    if _timer.nativeFallback and not _reportedNativeFallback then
        _reportedNativeFallback = true
        print("[AE] LoopInGameThreadWithDelay never ticked (engine tick hook off?), switched to the LoopAsync + ExecuteInGameThread timer")
    end
    if _timer.requeues ~= _reportedRequeues then
        _reportedRequeues = _timer.requeues
        print("[AE] Game thread tick did not run for " .. STALL_REQUEUE_SECONDS
            .. "s, queued again (" .. _reportedRequeues .. " total)")
    end
    if _timer.queueErrors ~= _reportedQueueErrors then
        _reportedQueueErrors = _timer.queueErrors
        print("[AE] ExecuteInGameThread failed (" .. _reportedQueueErrors .. " total)")
    end

    for i = 1, #_keys do
        if _keyPressed[i] then
            _keyPressed[i] = false
            GT.Measure(_keys[i].name, _keys[i].fn)
        end
    end

    -- Callbacks scheduled while running these land in the new list
    if #_after > 0 then
        local pending = _after
        _after = {}
        for _, item in ipairs(pending) do
            if now >= item.due then
                GT.Measure(item.name, item.fn)
            else
                _after[#_after + 1] = item
            end
        end
    end

    -- Tasks added while running these start on the next tick
    local anyStopped = false
    for i = 1, #_tasks do
        local task = _tasks[i]
        if not task.stopped and now >= task.nextRun then
            task.nextRun = now + task.interval
            local ok, result = GT.Measure(task.name, task.fn)
            if ok and result == true then
                task.stopped = true
            end
        end
        if task.stopped then
            anyStopped = true
        end
    end
    if anyStopped then
        local kept = {}
        for _, task in ipairs(_tasks) do
            if not task.stopped then
                kept[#kept + 1] = task
            end
        end
        _tasks = kept
    end
end

local function RecordTick(now, ms)
    _tickCount = _tickCount + 1
    _tickTotalMs = _tickTotalMs + ms
    if ms > _tickMaxMs then
        _tickMaxMs = ms
    end
    if now - _windowStart < STATS_INTERVAL_SECONDS then
        return
    end

    local names = {}
    for name in pairs(_taskMaxMs) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b) return _taskMaxMs[a] > _taskMaxMs[b] end)
    local slowest = {}
    for i = 1, math.min(4, #names) do
        slowest[i] = string.format("%s %.1f", names[i], _taskMaxMs[names[i]])
    end
    print(string.format("[AE] Game thread %.0fs: %d ticks, avg %.2f ms, max %.1f ms. Slowest (max ms): %s",
        now - _windowStart, _tickCount, _tickTotalMs / _tickCount, _tickMaxMs, table.concat(slowest, ", ")))

    _windowStart = now
    _tickCount = 0
    _tickTotalMs = 0.0
    _tickMaxMs = 0.0
    _taskMaxMs = {}
end

-- Game thread, queued by TimerCallback
local function Tick()
    _tickId = _tickId + 1
    local startedAt = os.clock()
    local ok, err = pcall(RunTick, startedAt)
    if not ok then
        print("[AE] Game thread tick error: " .. tostring(err))
    end
    local finished = os.clock()
    pcall(RecordTick, finished, (finished - startedAt) * 1000)
    -- Order matters: the timer reads queued first, then finishedAt
    _timer.finishedAt = finished
    _timer.queued = false
end

-- UE4SS async thread. Keep this free of allocations, prints and UObject access.
local function TimerCallback()
    local now = os.clock()
    if _timer.queued then
        if now - _timer.queuedAt < STALL_REQUEUE_SECONDS then
            return false
        end
        _timer.requeues = _timer.requeues + 1
    elseif now - _timer.finishedAt < MIN_GAP_SECONDS then
        return false
    end
    _timer.queued = true
    _timer.queuedAt = now
    if not pcall(ExecuteInGameThread, Tick) then
        _timer.queueErrors = _timer.queueErrors + 1
        _timer.queued = false
    end
    return false
end

--- Start the timer. Call once, after mod init registered its tasks and keys.
function GT.Start()
    if _started then
        return
    end
    _started = true
    _windowStart = os.clock()

    -- Newer UE4SS (experimental builds): loop natively on the game thread,
    -- driven by the engine tick. No async thread involved at all.
    if type(LoopInGameThreadWithDelay) == "function" then
        local ok, err = pcall(LoopInGameThreadWithDelay, TIMER_INTERVAL_MS, Tick)
        if ok then
            print("[AE] Game thread scheduler started (LoopInGameThreadWithDelay)")
            -- The native loop needs UE4SS's engine tick hook. If that hook is
            -- off or never fires, no tick ever runs: fall back to the timer.
            local checks = 0
            LoopAsync(1000, function()
                checks = checks + 1
                if _tickId > 0 then return true end
                if checks < 5 then return false end
                _timer.nativeFallback = true  -- reported from the game thread
                LoopAsync(TIMER_INTERVAL_MS, TimerCallback)
                return true
            end)
            return
        end
        print("[AE] LoopInGameThreadWithDelay failed, using LoopAsync timer: " .. tostring(err))
    end

    -- UE4SS 3.0.1: async timer that queues Tick with ExecuteInGameThread
    LoopAsync(TIMER_INTERVAL_MS, TimerCallback)
    print("[AE] Game thread scheduler started (LoopAsync + ExecuteInGameThread)")
end

return GT
