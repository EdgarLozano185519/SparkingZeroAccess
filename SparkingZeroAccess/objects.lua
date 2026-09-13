--[[
    objects.lua — cached object lookups (UE4SS 3.0.1, game thread)

    Why: on UE4SS 3.0.1 every FindAllOf / FindFirstOf walks the whole
    UObject array (about 30-50 ms in this game). The mod polls many classes many
    times a second, which made the game thread tick average 36 ms. The engine
    has hash tables for this, but 3.0.1's Lua cannot reach them (UFunctions
    with out params are broken there, NotifyOnNewObject runs Lua on loading
    threads). So each class the mod asks for is walked rarely and served from
    a per-class cache:

    - Objects.FindAllOf(name) keeps one entry per queried class name holding
      the last walk result (subclasses included, templates included, like the
      real call). Dead objects are pruned with IsValid, which is free.
    - Widget blueprint classes ("WBP_*", all UUserWidget subclasses) are NOT
      walked on their own after their first walk: every "UserWidget" walk
      indexes its objects by class name and rewrites those entries. So one
      walk refreshes the focus scan and every screen/dialog class at once.
      (The first real walk of a WBP_ class records the subclass names it
      found, so subclasses stay included afterwards.)
    - "UserWidget" is re-walked every MENU_WIDGET_INTERVAL while not busy, and
      sooner when main.lua asks (Objects.RequestWidgetRefresh: nothing has
      keyboard focus, which is what a new screen looks like before its
      widgets are in the cache). When a walk finds a changed widget
      population, the plain widget classes (TextBlock, RichTextBlock, ...)
      are marked stale too, so text lookups see the new screen.
    - Other classes are walked when first asked for, and again only when
      marked stale: a world change (all classes), a miss on a present class
      (rate-limited), or the slow safety refresh. At most ONE walk per game
      thread tick, none during the first seconds after start (the game is
      still loading) and none while battle marks the registry busy (a 50 ms
      walk mid-fight is a visible hitch).
    - Only class names the mod already used with the real FindAllOf are
      walked ("UserWidget", "TextBlock", "Pawn", WBP_* ...). Walking the base
      classes "Widget" and "Actor" killed the game (2026-09-13), so no
      generic walks.

    SAFETY: a cached reference is only safe until the engine's garbage
    collector frees the object. UE4SS 3.0.1's IsValid() reads the object's own
    InternalIndex, so on freed (unmapped) memory it crashes instead of
    returning false (crash 2026-09-13 09:03, AE_crash dump: AV reading
    obj+0xC on the game thread). UObjects are only freed by a GC purge, and a
    purge unhashes every unreachable object before it destroys any of them.
    So the registry keeps a throwaway plain UObject (the "sentinel") that
    nothing references and calls ITS IsValid() at the start of every tick.
    UE4SS 3.0.1's IsValid is: remote pointer set, not flagged Unreachable
    (reads InternalIndex from the object), and still in UE4SS's map of live
    objects (kept by a delete listener: the engine reports every destroyed
    object). The sentinel is flagged Unreachable at the GC mark, before any
    object is freed, and after its own destruction the map check returns
    false. Reading its InternalIndex stays safe because a 40-byte object lives
    in a small-block page shared with thousands of other allocations that
    never all die at once (unlike a screen full of big widgets). Sentinel
    invalid = a GC ran: every cached reference (here and in the modules, via
    Objects.OnFlush) is dropped before anything touches it, walks pause for
    GC_HOLD (the purge frees objects over a few frames and a walk can meet an
    object whose class is already gone), then flushed classes are walked
    again on demand. StaticFindObject is NOT used per tick: on 3.0.1 it is a
    15 ms linear search.

    Walks themselves can also crash while the game streams assets (objects
    are registered in the array before their fields are initialised; crash
    2026-09-13 09:18, IsChildOf on garbage during the title load), so walks
    are kept rare: main.lua asks for none during transition cooldowns.

    History: on 2026-09-13 the title screen was not read because its classes
    were walked once during loading (0 objects), marked absent and not walked
    again for 60 s, while the title buttons never reached the UserWidget cache.

    main.lua replaces the FindAllOf / FindFirstOf globals with the functions
    here, so the rest of the mod is unchanged. Everything runs on the game
    thread (game_thread.lua); nothing here is thread-safe.
]]

local Objects = {}

-- The real UE4SS function, captured before main.lua overrides the globals
local UE_FindAllOf = FindAllOf

local USER_WIDGET = "UserWidget"

local STARTUP_GRACE = 5.0          -- no walk this long after mod start
local MISS_INTERVAL = 3.0          -- re-walk a class that had objects and lost them
local ABSENT_INTERVAL = 60.0       -- re-walk a class that has never had objects
local IDLE_INTERVAL = 30.0         -- safety re-walk of used classes while not busy
local MENU_WIDGET_INTERVAL = 3.0   -- UserWidget re-walk cadence while not busy
local STATS_INTERVAL = 60.0

-- name -> { list = {objects} or nil, live = {objects}, walkedAt = t, stale = bool,
--           absent = bool, lastQuery = t, classNames = {name = true},
--           walkedReal = bool, classIndex (UserWidget only) }
local _entries = {}
local _queue = {}                  -- class names waiting for a walk, in request order
local _queued = {}                 -- name -> true while in _queue
local _liveCache = {}              -- name -> { tick = n, list = {...} }
local _queryCache = {}             -- name -> { tick = n, list = table or false }

local _tickId = 0
local _notBefore = os.clock() + STARTUP_GRACE
local _pendingNotBefore = 0
local _busy = false
local _walkCount = 0
local _derivedCount = 0
local _missCount = 0
local _missClasses = {}
local _lastStats = os.clock()
local _lastIdleCheck = os.clock()
local _widgetRefreshDue = nil      -- os.clock() time of the next requested UserWidget walk
local _widgetRefreshReason = nil

-- GC sentinel (see header). Mode: "init" (not created yet), "active", "broken"
-- (creation or lookup failed: the cache runs without GC protection, logged once)
local GC_HOLD = 0.3                -- no walks this long after a GC was detected
local _sentinelMode = "init"
local _sentinelPath = nil
local _sentinelObj = nil
local _sentinelCounter = 0
local _generation = 0              -- incremented at every flush
local _gcCheckedTick = -1
local _flushListeners = {}
local _holdUntil = 0

local function IsAlive(obj)
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function IsWidgetClass(name)
    return name == USER_WIDGET or name == "TextBlock" or name == "RichTextBlock" or name == "Image"
        or name == "WidgetSwitcher" or name == "Button" or name:find("^WBP_") ~= nil
end

-- Widget blueprint classes: served from the UserWidget walk (see header)
local function IsDerived(name)
    return name:find("^WBP_") ~= nil
end

local function ClassNameOf(fullName)
    return fullName:match("^(.-)%s") or fullName
end

local function Enqueue(name)
    if not _queued[name] then
        _queued[name] = true
        _queue[#_queue + 1] = name
    end
end

local function EnqueueFront(name)
    if _queued[name] then
        for i = 1, #_queue do
            if _queue[i] == name then table.remove(_queue, i); break end
        end
    end
    _queued[name] = true
    table.insert(_queue, 1, name)
end

local function InvalidateCaches(name)
    _queryCache[name] = nil
    _liveCache[name] = nil
end

--- StaticFindObject by path: the object if it is hashed and valid, else nil.
--- Never touches an unhashed (possibly freed) object.
local function LookupPath(path)
    local ok, obj = pcall(StaticFindObject, path)
    if not ok or obj == nil then return nil end
    local okV, valid = pcall(function() return obj:IsValid() end)
    if okV and valid == true then return obj end
    return nil
end

-- The transient package (/Engine/Transient, outer of every runtime object) is
-- not found by name with UE4SS 3.0.1's StaticFindObject, so it is reached
-- through the GameInstance: GameInstance -> GameEngine -> package.
local _sentinelClass = nil
local _sentinelOuter = nil

local function FindSentinelParents()
    if _sentinelClass and _sentinelOuter then return true end
    _sentinelClass = LookupPath("/Script/CoreUObject.Object")
    if not _sentinelClass then error("class /Script/CoreUObject.Object not found") end
    local gi = Objects.FindFirstOf("GameInstance")
    if not gi then error("no GameInstance yet") end
    local outer = gi:GetOuter()
    if outer then outer = outer:GetOuter() end
    local full = outer and outer:GetFullName() or "nil"
    if full ~= "Package /Engine/Transient" then error("GameInstance outer chain gave " .. full) end
    _sentinelOuter = outer
    return true
end

local function CreateSentinel()
    _sentinelCounter = _sentinelCounter + 1
    local name = "AE_GCSentinel_" .. _sentinelCounter
    local path = "/Engine/Transient." .. name
    local t0 = os.clock()
    local sentinel = nil
    local ok, err = pcall(function()
        FindSentinelParents()
        local obj = StaticConstructObject(_sentinelClass, _sentinelOuter, FName(name))
        if obj == nil then error("StaticConstructObject returned nil") end
        local okV, valid = pcall(function() return obj:IsValid() end)
        if not okV or valid ~= true then error("constructed object is not valid") end
        local full = obj:GetFullName()
        if full ~= "Object " .. path then error("constructed object is " .. tostring(full)) end
        sentinel = obj
    end)
    local t1 = os.clock()
    if ok and _sentinelCounter == 1 and not LookupPath(path) then
        -- One-time verification (StaticFindObject is a slow linear search on 3.0.1)
        ok, err = false, path .. " not found right after creation"
    end
    if not ok then
        if err and tostring(err):find("no GameInstance yet", 1, true) then
            return false  -- retried next tick, mode stays "init"
        end
        _sentinelMode = "broken"
        _sentinelPath = nil
        _sentinelObj = nil
        _sentinelOuter = nil
        print("[AE] Objects: GC sentinel unavailable (" .. tostring(err)
            .. "): cached references stay unprotected against garbage collection (crash risk)")
        return false
    end
    _sentinelMode = "active"
    _sentinelPath = path
    _sentinelObj = sentinel
    if _sentinelCounter <= 3 then
        print(string.format("[AE] Objects: GC sentinel %s created in %.1f ms", path, (t1 - t0) * 1000))
    end
    return true
end

--- True while the sentinel is alive (no GC mark since its creation).
local function SentinelAlive()
    local ok, valid = pcall(function() return _sentinelObj:IsValid() end)
    return ok and valid == true
end

--- Drop every cached reference. Flushed entries are walked again on demand.
local function Flush(reason, quiet)
    _generation = _generation + 1
    for _, entry in pairs(_entries) do
        entry.list = nil
        entry.live = nil
        entry.classIndex = nil
        entry.stale = true
        entry.unsafe = true
    end
    _queryCache = {}
    _liveCache = {}
    for _, fn in ipairs(_flushListeners) do
        local ok, err = pcall(fn, _generation)
        if not ok then print("[AE] Objects: flush listener error: " .. tostring(err)) end
    end
    if not quiet then
        print(string.format("[AE] Objects: %s, generation %d, cache flushed", reason, _generation))
    end
end

--- Rewrite a WBP_ entry from the UserWidget entry's class index (no walk).
local function DeriveEntry(name, entry, uw)
    local list, live = {}, {}
    local function take(cls)
        local bucket = uw.classIndex[cls]
        if not bucket then return end
        for i = 1, #bucket.objs do list[#list + 1] = bucket.objs[i] end
        for i = 1, #bucket.live do live[#live + 1] = bucket.live[i] end
    end
    take(name)
    if entry.classNames then
        for cls in pairs(entry.classNames) do
            if cls ~= name then take(cls) end
        end
    end
    entry.list = list
    entry.live = live
    entry.walkedAt = uw.walkedAt
    entry.stale = false
    entry.forced = false
    entry.unsafe = false
    entry.absent = (#list == 0)
    _derivedCount = _derivedCount + 1
    InvalidateCaches(name)
end

local function DeriveAll(uw)
    for name, entry in pairs(_entries) do
        if IsDerived(name) then DeriveEntry(name, entry, uw) end
    end
end

--- The widget population changed: plain widget classes need a walk of their own.
local function MarkPlainWidgetsStale()
    local n = 0
    for name, entry in pairs(_entries) do
        if IsWidgetClass(name) and not IsDerived(name) and name ~= USER_WIDGET and not entry.stale then
            entry.stale = true
            Enqueue(name)
            n = n + 1
        end
    end
    return n
end

local _walkTick = -1               -- tick id of the last walk

local function Walk(name, reason)
    local t0 = os.clock()
    local ok, list = pcall(UE_FindAllOf, name)
    _walkCount = _walkCount + 1
    _walkTick = _tickId
    local entry = _entries[name]
    if not entry then
        entry = { lastQuery = t0 }
        _entries[name] = entry
    end
    entry.list = (ok and list) or nil
    -- Live instances (under /Engine/Transient) are fixed for an object's
    -- lifetime, so classify once per walk (3 us per object) instead of per tick.
    -- The class name comes from the same GetFullName call.
    entry.live = {}
    entry.classNames = {}
    local classIndex = (name == USER_WIDGET) and {} or nil
    if entry.list then
        for _, obj in ipairs(entry.list) do
            local okN, full = pcall(function() return obj:GetFullName() end)
            if okN and full then
                local isLive = full:find("/Engine/Transient", 1, true) ~= nil
                if isLive then entry.live[#entry.live + 1] = obj end
                local cls = ClassNameOf(full)
                entry.classNames[cls] = true
                if classIndex then
                    local bucket = classIndex[cls]
                    if not bucket then
                        bucket = { objs = {}, live = {} }
                        classIndex[cls] = bucket
                    end
                    bucket.objs[#bucket.objs + 1] = obj
                    if isLive then bucket.live[#bucket.live + 1] = obj end
                end
            end
        end
    end
    entry.walkedAt = os.clock()
    entry.stale = false
    entry.forced = false
    entry.unsafe = false
    entry.walkedReal = true
    entry.absent = (entry.list == nil or #entry.list == 0)
    InvalidateCaches(name)
    local extra = ""
    if classIndex then
        local classCount = 0
        for _ in pairs(classIndex) do classCount = classCount + 1 end
        local changed = entry.classCount ~= classCount or entry.liveCount ~= #entry.live
        entry.classIndex = classIndex
        entry.classCount = classCount
        entry.liveCount = #entry.live
        DeriveAll(entry)
        extra = string.format(", %d live, %d classes", #entry.live, classCount)
        if changed then
            local n = MarkPlainWidgetsStale()
            if n > 0 then extra = extra .. string.format(", %d text classes queued", n) end
        end
    end
    print(string.format("[AE] Objects: walked %s (%s) in %.0f ms: %d objects%s",
        name, tostring(reason), (entry.walkedAt - t0) * 1000, entry.list and #entry.list or 0, extra))
end

local function Prune(entry)
    local list = entry.list
    if not list then return nil end
    local dead = false
    for i = 1, #list do
        if not IsAlive(list[i]) then dead = true; break end
    end
    if dead then
        local kept = {}
        for i = 1, #list do
            if IsAlive(list[i]) then kept[#kept + 1] = list[i] end
        end
        entry.list = kept
        list = kept
    end
    if #list == 0 then return nil end
    return list
end

--- Same contract as UE4SS FindAllOf: a table of objects (subclasses included), or nil.
function Objects.FindAllOf(name)
    local cached = _queryCache[name]
    if cached and cached.tick == _tickId then
        return cached.list or nil
    end
    local now = os.clock()
    local entry = _entries[name]
    if not entry then
        entry = { list = nil, walkedAt = -math.huge, stale = true, absent = true, lastQuery = now }
        _entries[name] = entry
        local uw = _entries[USER_WIDGET]
        if IsDerived(name) and uw and uw.classIndex then
            -- Instant answer from the last UserWidget walk; the queued real
            -- walk below only records subclass names
            DeriveEntry(name, entry, uw)
            entry.stale = true
        end
        Enqueue(name)
    end
    entry.lastQuery = now
    if entry.unsafe and now < _holdUntil then
        -- Purge in progress: nothing cached, no walk either
        _queryCache[name] = { tick = _tickId, list = false }
        return nil
    end
    if entry.unsafe and _walkTick == _tickId then
        -- Another class already walked this tick: spread the after-GC walks
        -- over several frames (one 40 ms hitch each instead of a 200 ms freeze)
        _queryCache[name] = { tick = _tickId, list = false }
        return nil
    end
    if entry.unsafe then
        -- Flushed after a GC: nothing cached may be touched, walk now (busy or
        -- not: the alternative is reading freed memory)
        if IsDerived(name) then
            local uw = _entries[USER_WIDGET]
            if uw then
                if uw.unsafe then Walk(USER_WIDGET, "after GC") end
                if entry.unsafe then DeriveEntry(name, entry, uw) end
            else
                Walk(name, "after GC")
            end
        else
            Walk(name, "after GC")
        end
    end
    local list = Prune(entry)
    if list == nil then
        _missCount = _missCount + 1
        _missClasses[name] = (_missClasses[name] or 0) + 1
        if not (IsDerived(name) and entry.walkedReal) then
            -- Nothing live: had objects before -> re-walk soon; never had any -> rarely.
            -- (Derived classes wait for the next UserWidget walk instead.)
            local interval = entry.absent and ABSENT_INTERVAL or MISS_INTERVAL
            if not entry.stale and now - entry.walkedAt >= interval then
                entry.stale = true
                Enqueue(name)
            end
        end
    end
    _queryCache[name] = { tick = _tickId, list = list or false }
    return list
end

--- Same contract as UE4SS FindFirstOf: the first object of the class, or nil.
function Objects.FindFirstOf(name)
    local list = Objects.FindAllOf(name)
    return list and list[1] or nil
end

--- Live instances only (full name under /Engine/Transient), for hot paths.
function Objects.FindAllLive(name)
    local cached = _liveCache[name]
    if cached and cached.tick == _tickId then
        return cached.list
    end
    Objects.FindAllOf(name)  -- schedules the walk and prunes entry.list
    local entry = _entries[name]
    local list = {}
    if entry and entry.live then
        local dead = false
        for _, obj in ipairs(entry.live) do
            if IsAlive(obj) then list[#list + 1] = obj else dead = true end
        end
        if dead then entry.live = list end
    end
    _liveCache[name] = { tick = _tickId, list = list }
    return list
end

--- Mark classes stale so they are walked again (one per tick, when allowed).
--- forced = also while busy (world change). widgetsOnly = just widget classes.
--- delaySeconds = earliest time for the walks, from now.
function Objects.RequestRefresh(reason, forced, widgetsOnly, delaySeconds)
    for name, entry in pairs(_entries) do
        if not widgetsOnly or IsWidgetClass(name) then
            entry.stale = true
            entry.forced = forced or entry.forced
            entry.reason = reason
            Enqueue(name)
        end
    end
    if delaySeconds then
        local t = os.clock() + delaySeconds
        if t > _pendingNotBefore then _pendingNotBefore = t end
    end
    print("[AE] Objects: refresh requested (" .. tostring(reason) .. "), " .. #_queue .. " classes queued")
end

--- Ask for a UserWidget walk (which rewrites every WBP_ class) at least
--- minIntervalSeconds after the previous one. Cheap to call every tick; the
--- earliest pending request wins. Ignored while busy (battle).
function Objects.RequestWidgetRefresh(reason, minIntervalSeconds)
    local uw = _entries[USER_WIDGET]
    if not uw or uw.stale or _busy then return end
    local due = math.max(os.clock(), uw.walkedAt + (minIntervalSeconds or 0))
    if not _widgetRefreshDue or due < _widgetRefreshDue then
        _widgetRefreshDue = due
        _widgetRefreshReason = reason
    end
end

--- While busy (battle), only forced walks run.
function Objects.SetBusy(flag, reason)
    if flag == _busy then return end
    _busy = flag
    print("[AE] Objects: " .. (flag and ("busy (" .. tostring(reason) .. "), walks paused") or "walks resumed"))
end

function Objects.IsBusy()
    return _busy
end

--- GC check. Runs first in every game thread tick (GT tick prologue), before
--- any callback can touch a cached object; Objects.Tick repeats it harmlessly.
function Objects.BeginTick(tickId)
    _tickId = tickId
    if _gcCheckedTick == tickId then return end
    _gcCheckedTick = tickId
    if _sentinelMode == "init" then
        -- Nothing is cached before the first walk (startup grace), so the
        -- sentinel is only needed from then on
        if os.clock() < _notBefore then return end
        CreateSentinel()
    elseif _sentinelMode == "active" then
        if not SentinelAlive() then
            Flush("garbage collection detected")
            _holdUntil = os.clock() + GC_HOLD
            CreateSentinel()
        end
    end
    -- "broken": nothing to do, the registry runs unprotected (logged once)
end

--- Number of flushes so far. Modules that keep their own object references
--- must drop them when it changes (or register with Objects.OnFlush).
function Objects.Generation()
    return _generation
end

--- fn(generation) is called during every flush, before any cached object can
--- be touched again. Drop every private UObject reference in it.
function Objects.OnFlush(fn)
    _flushListeners[#_flushListeners + 1] = fn
end

--- Run once per game thread tick, before the polls. Performs at most one walk.
function Objects.Tick(tickId)
    Objects.BeginTick(tickId)
    local now = os.clock()
    if now < _notBefore or now < _pendingNotBefore or now < _holdUntil then return end

    -- Steady refresh of classes still in use: UserWidget on the menu cadence,
    -- everything else on the slow safety interval
    if not _busy and now - _lastIdleCheck >= 1.0 then
        _lastIdleCheck = now
        for name, entry in pairs(_entries) do
            if not entry.stale and not IsDerived(name) and now - entry.lastQuery < 5.0 then
                local interval = (name == USER_WIDGET) and MENU_WIDGET_INTERVAL or IDLE_INTERVAL
                if now - entry.walkedAt >= interval then
                    entry.stale = true
                    entry.reason = "refresh"
                    Enqueue(name)
                end
            end
        end
    end

    -- Requested UserWidget walk (no focus anywhere / screen change): first in line
    if _widgetRefreshDue and now >= _widgetRefreshDue then
        _widgetRefreshDue = nil
        local uw = _entries[USER_WIDGET]
        if uw and not _busy then
            uw.stale = true
            uw.reason = _widgetRefreshReason
            EnqueueFront(USER_WIDGET)
        end
    end

    -- One walk per tick, oldest request first
    while #_queue > 0 do
        local name = table.remove(_queue, 1)
        _queued[name] = nil
        local entry = _entries[name]
        if entry and entry.stale then
            if _busy and not entry.forced then
                -- Keep it queued for when the battle ends
                Enqueue(name)
                break
            end
            local uw = _entries[USER_WIDGET]
            if IsDerived(name) and entry.walkedReal and uw then
                -- Served from the UserWidget walk: refresh that instead (no break,
                -- the redirect costs nothing)
                entry.stale = false
                if not uw.stale then
                    uw.stale = true
                    uw.reason = entry.reason or "derived"
                    EnqueueFront(USER_WIDGET)
                end
                uw.forced = uw.forced or entry.forced
                entry.forced = false
            else
                local reason = entry.reason or "queued"
                entry.reason = nil
                Walk(name, reason)
                break
            end
        end
    end

    if now - _lastStats >= STATS_INTERVAL then
        _lastStats = now
        local top = {}
        for cname, n in pairs(_missClasses) do top[#top + 1] = cname .. " " .. n end
        table.sort(top)
        local classes = 0
        for _ in pairs(_entries) do classes = classes + 1 end
        print(string.format("[AE] Objects: %d classes cached, %d walks, %d derived, %d misses (%s), queue %d, busy=%s, generation %d (%s)",
            classes, _walkCount, _derivedCount, _missCount, table.concat(top, ", "), #_queue, tostring(_busy),
            _generation, _sentinelMode))
        _missClasses = {}
        _missCount = 0
    end
end

--- Call once during mod init. Nothing is walked until a class is asked for.
function Objects.Init()
    print("[AE] Objects: registry active (walks start " .. STARTUP_GRACE .. " s after load, one per tick, UserWidget every "
        .. MENU_WIDGET_INTERVAL .. " s in menus)")
end

return Objects
