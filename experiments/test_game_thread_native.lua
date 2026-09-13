-- Offline test: game_thread.lua on newer UE4SS (LoopInGameThreadWithDelay present).
-- Usage: lua test_game_thread_native.lua <mod scripts dir>
package.path = arg[1] .. "\\?.lua;" .. package.path

local clock = 0.0
os.clock = function() return clock end  -- luacheck: ignore
local printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = tostring(s) end  -- luacheck: ignore

local loops, asyncUsed, queued, keys = {}, false, 0, {}
LoopInGameThreadWithDelay = function(ms, fn) loops[#loops + 1] = { ms = ms / 1000, next = 0, fn = fn }; return #loops end
LoopAsync = function() asyncUsed = true end
ExecuteInGameThread = function() queued = queued + 1 end
RegisterKeyBind = function(key, fn) keys[key] = fn end

local GT = require("game_thread")
local failures = 0
local function check(cond, msg)
    if cond then realPrint("ok   " .. msg) else failures = failures + 1; realPrint("FAIL " .. msg) end
end

local runs, hundred, keyRuns, afterRan = 0, 0, 0, false
GT.Every("tick", 0, function() runs = runs + 1 end)
GT.Every("100ms", 100, function() hundred = hundred + 1 end)
GT.OnKey("F2", "F2", function() keyRuns = keyRuns + 1 end)
GT.After(200, "after", function() afterRan = true end)
GT.Start()

check(#loops == 1 and not asyncUsed, "uses LoopInGameThreadWithDelay, not LoopAsync")

local lastTick = GT.TickId()
for _ = 1, 1000 do
    clock = clock + 0.001
    for _, loop in ipairs(loops) do
        if clock >= loop.next then
            loop.next = clock + loop.ms
            loop.fn()
        end
    end
end
check(runs >= 55 and runs <= 65, "every-tick task ~60 times per second (" .. runs .. ")")
check(hundred >= 9 and hundred <= 11, "100 ms task ~10 times per second (" .. hundred .. ")")
check(afterRan, "After callback ran")
check(GT.TickId() > lastTick, "TickId advances")
check(queued == 0, "ExecuteInGameThread never called")
keys["F2"]()
loops[1].fn()
check(keyRuns == 1, "key handler runs on the next tick")

local startedLine = false
for _, s in ipairs(printed) do if s:find("LoopInGameThreadWithDelay", 1, true) then startedLine = true end end
check(startedLine, "start message names LoopInGameThreadWithDelay")

realPrint(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
