--[[
    objects.lua — cached object lookups (UE4SS 3.0.1, game thread)

    Why: on UE4SS 3.0.1 every FindAllOf / FindFirstOf walks the whole
    UObject array (about 50 ms in this game). The mod polls many classes many
    times a second, which made the game thread tick average 36 ms. The engine
    has hash tables for this, but 3.0.1's Lua cannot reach them (UFunctions
    with out params are broken there, NotifyOnNewObject runs Lua on loading
    threads). So each class the mod asks for is walked rarely and served from
    a per-class cache:

    - Objects.FindAllOf(name) keeps one entry per queried class name holding
      the last walk result (subclasses included, templates included, like the
      real call). Dead objects are pruned with IsValid, which is free.
    - A class is walked when first asked for, and again only when marked
      stale: a world change (all classes), a "focus lost" or explicit request
      (all widget classes), a miss on a present class (rate-limited), or the
      slow safety refresh. At most ONE walk per game thread tick, none during
      the first seconds after start (the game is still loading) and none while
      battle marks the registry busy (a 50 ms walk mid-fight is a visible hitch).
    - Only class names the mod already used with the real FindAllOf are
      walked ("UserWidget", "TextBlock", "Pawn", WBP_* ...). Walking the base
      classes "Widget" and "Actor" killed the game (2026-09-13), so no
      generic walks.

    main.lua replaces the FindAllOf / FindFirstOf globals with the functions
    here, so the rest of the mod is unchanged. Everything runs on the game
    thread (game_thread.lua); nothing here is thread-safe.
]]

local Objects = {}

-- The real UE4SS function, captured before main.lua overrides the globals
local UE_FindAllOf = FindAllOf

local STARTUP_GRACE = 5.0          -- no walk this long after mod start
local MISS_INTERVAL = 3.0          -- re-walk a class that had objects and lost them
local ABSENT_INTERVAL = 60.0       -- re-walk a class that has never had objects
local IDLE_INTERVAL = 30.0         -- safety re-walk of used classes while not busy
local STATS_INTERVAL = 60.0

-- name -> { list = {objects} or nil, walkedAt = t, stale = bool, absent = bool, lastQuery = t }
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
local _missCount = 0
local _missClasses = {}
local _lastStats = os.clock()
local _lastIdleCheck = os.clock()

local function IsAlive(obj)
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function IsWidgetClass(name)
    return name == "UserWidget" or name == "TextBlock" or name == "RichTextBlock" or name == "Image"
        or name == "WidgetSwitcher" or name == "Button" or name:find("^WBP_") ~= nil
end

local function Enqueue(name)
    if not _queued[name] then
        _queued[name] = true
        _queue[#_queue + 1] = name
    end
end

local function Walk(name, reason)
    local t0 = os.clock()
    local ok, list = pcall(UE_FindAllOf, name)
    _walkCount = _walkCount + 1
    local entry = _entries[name]
    if not entry then
        entry = { lastQuery = t0 }
        _entries[name] = entry
    end
    entry.list = (ok and list) or nil
    -- Live instances (under /Engine/Transient) are fixed for an object's
    -- lifetime, so classify once per walk (3 us per object) instead of per tick
    entry.live = {}
    if entry.list then
        for _, obj in ipairs(entry.list) do
            local okN, full = pcall(function() return obj:GetFullName() end)
            if okN and full and full:find("/Engine/Transient", 1, true) then
                entry.live[#entry.live + 1] = obj
            end
        end
    end
    entry.walkedAt = os.clock()
    entry.stale = false
    entry.absent = (entry.list == nil or #entry.list == 0)
    _queryCache[name] = nil
    _liveCache[name] = nil
    print(string.format("[AE] Objects: walked %s (%s) in %.0f ms: %d objects",
        name, tostring(reason), (entry.walkedAt - t0) * 1000, entry.list and #entry.list or 0))
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
        Enqueue(name)
    end
    entry.lastQuery = now
    local list = Prune(entry)
    if list == nil then
        -- Nothing live: had objects before -> re-walk soon; never had any -> rarely
        _missCount = _missCount + 1
        _missClasses[name] = (_missClasses[name] or 0) + 1
        local interval = entry.absent and ABSENT_INTERVAL or MISS_INTERVAL
        if not entry.stale and now - entry.walkedAt >= interval then
            entry.stale = true
            Enqueue(name)
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
--- forced = also while busy (world change). widgetsOnly = just widget classes
--- (focus lost). delaySeconds = earliest time for the walks, from now.
function Objects.RequestRefresh(reason, forced, widgetsOnly, delaySeconds)
    for name, entry in pairs(_entries) do
        if not widgetsOnly or IsWidgetClass(name) then
            entry.stale = true
            entry.forced = forced or entry.forced
            Enqueue(name)
        end
    end
    if delaySeconds then
        local t = os.clock() + delaySeconds
        if t > _pendingNotBefore then _pendingNotBefore = t end
    end
    print("[AE] Objects: refresh requested (" .. tostring(reason) .. "), " .. #_queue .. " classes queued")
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

--- Run once per game thread tick, before the polls. Performs at most one walk.
function Objects.Tick(tickId)
    _tickId = tickId
    local now = os.clock()
    if now < _notBefore or now < _pendingNotBefore then return end

    -- Slow safety refresh of classes still in use
    if not _busy and now - _lastIdleCheck >= 5.0 then
        _lastIdleCheck = now
        for name, entry in pairs(_entries) do
            if not entry.stale and now - entry.walkedAt >= IDLE_INTERVAL and now - entry.lastQuery < 5.0 then
                entry.stale = true
                Enqueue(name)
            end
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
            entry.forced = false
            Walk(name, "queued")
            break
        end
    end

    if now - _lastStats >= STATS_INTERVAL then
        _lastStats = now
        local top = {}
        for cname, n in pairs(_missClasses) do top[#top + 1] = cname .. " " .. n end
        table.sort(top)
        local classes = 0
        for _ in pairs(_entries) do classes = classes + 1 end
        print(string.format("[AE] Objects: %d classes cached, %d walks, %d misses (%s), queue %d, busy=%s",
            classes, _walkCount, _missCount, table.concat(top, ", "), #_queue, tostring(_busy)))
        _missClasses = {}
        _missCount = 0
    end
end

--- Call once during mod init. Nothing is walked until a class is asked for.
function Objects.Init()
    print("[AE] Objects: registry active (walks start " .. STARTUP_GRACE .. " s after load, one per tick)")
end

return Objects
