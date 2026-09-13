-- Offline test for game_thread.lua with mocked UE4SS globals and a fake clock.
-- Usage: lua test_game_thread.lua <mod scripts dir>
package.path = arg[1] .. "\\?.lua;" .. package.path

local clock = 0.0
os.clock = function() return clock end  -- luacheck: ignore

local asyncLoops, gameQueue, keyCallbacks = {}, {}, {}
LoopAsync = function(ms, fn) asyncLoops[#asyncLoops + 1] = { ms = ms / 1000, next = 0, fn = fn } end
ExecuteInGameThread = function(fn) gameQueue[#gameQueue + 1] = fn end
RegisterKeyBind = function(key, fn) keyCallbacks[key] = fn end

local printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = s end  -- luacheck: ignore

local GT = require("game_thread")

local failures = 0
local function check(cond, msg)
    if not cond then failures = failures + 1; realPrint("FAIL: " .. msg) else realPrint("ok   " .. msg) end
end
local function printedMatching(pat)
    for _, s in ipairs(printed) do if tostring(s):find(pat) then return true end end
    return false
end

-- Advance fake time in 1 ms steps; run async timers and (unless blocked) the game queue.
local gameBlocked = false
local function advance(ms)
    for _ = 1, ms do
        clock = clock + 0.001
        for _, loop in ipairs(asyncLoops) do
            if clock >= loop.next then
                loop.next = clock + loop.ms
                assert(loop.fn() == false, "timer must return false")
            end
        end
        if not gameBlocked and #gameQueue > 0 then
            local q = gameQueue
            gameQueue = {}
            for _, fn in ipairs(q) do fn() end
        end
    end
end

-- Tasks
local everyTick, every100, stopAfter3, errors = 0, 0, 0, 0
GT.Every("everyTick", 0, function() everyTick = everyTick + 1 end)
GT.Every("every100", 100, function() every100 = every100 + 1 end)
GT.Every("stopAfter3", 0, function() stopAfter3 = stopAfter3 + 1; return stopAfter3 >= 3 end)
GT.Every("errors", 50, function() errors = errors + 1; error("boom") end)
local keyRuns = 0
GT.OnKey("F5", "F5 test", function() keyRuns = keyRuns + 1 end)

check(#asyncLoops == 0, "no LoopAsync before Start")
GT.Start()
GT.Start()
check(#asyncLoops == 1, "Start creates exactly one LoopAsync")

advance(1000)
realPrint(string.format("     1 s: everyTick=%d every100=%d stopAfter3=%d errors=%d", everyTick, every100, stopAfter3, errors))
check(everyTick >= 40 and everyTick <= 70, "every-tick task runs 40-70 times per second (16 ms timer)")
check(every100 >= 8 and every100 <= 11, "100 ms task runs about 10 times per second")
check(stopAfter3 == 3, "task returning true stops")
check(errors >= 15, "erroring task keeps running")
check(printedMatching("errors error:.*boom"), "task error is logged with its name")

-- Never more than one tick queued
local maxQueued = 0
for _ = 1, 500 do advance(1); if #gameQueue > maxQueued then maxQueued = #gameQueue end end
check(maxQueued <= 1, "at most one tick queued at a time")

-- Key press from the "event loop thread" runs once on the next tick
keyCallbacks["F5"](); keyCallbacks["F5"]()
check(keyRuns == 0, "key handler does not run inside the keybind callback")
advance(50)
check(keyRuns == 1, "double press between ticks runs handler once")

-- After
local afterRan, afterAt = false, nil
local scheduledAt = clock
GT.After(300, "after test", function() afterRan = true; afterAt = clock end)
advance(250)
check(not afterRan, "After does not run early")
advance(100)
check(afterRan and afterAt - scheduledAt >= 0.3, "After runs once delay passed")

-- After scheduled from inside an After callback
local chained = 0
GT.After(0, "chain1", function() chained = 1; GT.After(0, "chain2", function() chained = 2 end) end)
advance(100)
check(chained == 2, "After scheduled inside After runs on a later tick")

-- Cancel
local cancelRuns = 0
local handle = GT.Every("cancel me", 0, function() cancelRuns = cancelRuns + 1 end)
advance(100)
local before = cancelRuns
GT.Cancel(handle)
GT.Cancel(nil)
advance(200)
check(before > 0 and cancelRuns == before, "Cancel stops a task; Cancel(nil) is safe")

-- Task added during a tick starts next tick
local addedRuns = 0
GT.After(0, "add task", function() GT.Every("added", 0, function() addedRuns = addedRuns + 1 end) end)
advance(100)
check(addedRuns > 0, "task added from a callback runs")

-- Game thread blocked (loading screen): no pile-up before the stall timeout, requeue after
gameBlocked = true
advance(5000)
check(#gameQueue == 1, "blocked game thread: still exactly one queued tick after 5 s")
advance(6000)
check(#gameQueue == 2, "blocked 11 s: one extra tick queued by stall recovery")
gameBlocked = false
local ticksBefore = everyTick
advance(100)
check(everyTick > ticksBefore, "ticks resume after the game thread unblocks")
check(printedMatching("did not run for 10"), "stall requeue is logged from the game thread")

-- Timing summary after 60 s, slow task warning
GT.Every("slow", 1000, function() clock = clock + 0.020 end)
advance(61000)
check(printedMatching("Slow game thread task: slow took 20"), "slow task logged")
check(printedMatching("%[AE%] Game thread %d+s: %d+ ticks"), "60 s timing summary logged")

realPrint("")
realPrint("Sample log lines:")
local shown = {}
for _, s in ipairs(printed) do
    local key = tostring(s):sub(1, 30)
    if not shown[key] then shown[key] = true; realPrint("  " .. tostring(s)) end
end
realPrint(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
