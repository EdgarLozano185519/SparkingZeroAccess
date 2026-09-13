--[[
    episode_map.lua — Episode Battle story map popups and overlays

    Handles the screens opened on top of the 3D story map:
    1. Details / Recap popup (WBP_GRP_AI_ChartDetails_C)
       - WidgetSwitcher_Main page 0 "Info": team list (left box = your team,
         right box = opponents), clear condition, rewards
       - Page 1 "Outline": saga recap text (TXT_Outline)
    2. Episode Map overlay (WBP_GRP_AI_Map_XXXX_XX_C, one class per saga)
       - Rows (WBP_OBJ_AI_Map_Row_*_00 = main arcs, other rows = side arcs)
         -> Blocks (one per arc, TXT_ChapterTitle) -> Pieces (episodes)
       - Cursor piece: Overlay_Cursor (parent of IMG_Corner_0) has opacity > 0
       - WBP_OBJ_AI_Map_Outline_C: TXT_Title, WidgetSwitcher_Header
         (0 Battle, 1 Event), TXT_main synopsis
       - WBP_OBJ_AI_Map_CharacterSelect_C: TXT_CharacterName (saga name)

    Closed popups stay alive with their root at opacity 0, so "open" means
    SSMenuWidget.bIsActive + visible + non-zero opacity. Lookups use the C++
    base classes (SSDragonAdventureIFCT*) because Blueprint class names
    differ per saga.
]]

local H = require("helpers")
local TryCall = H.TryCall
local IsValidRef = H.IsValidRef

local CharaNames = require("chara_names")

local EpisodeMap = {}

-- === STATE ===

local Speak = nil
local SpeakQueued = nil

-- Details / Recap popup
local _detailsOpen = false
local _detailsPendingKey = nil    -- content seen last tick (announce once stable)
local _detailsAnnouncedKey = nil  -- content last announced

-- Episode Map overlay
local _mapOpen = false
local _queueNextSelection = false -- queue (not interrupt) the first selection after opening
local _lastSaga = nil             -- TXT_CharacterName
local _lastSelectionKey = nil     -- cursor piece path + outline title
local _lastArcKey = nil           -- map + block of the last announced arc
local _announceCountdown = nil    -- ticks to wait so the outline panel catches up

local _loggedMissingClass = {}

function EpisodeMap.Init(speakFn, speakQueuedFn)
    Speak = speakFn
    SpeakQueued = speakQueuedFn
end

function EpisodeMap.Reset()
    _detailsOpen = false
    _detailsPendingKey = nil
    _detailsAnnouncedKey = nil
    _mapOpen = false
    _queueNextSelection = false
    _lastSaga = nil
    _lastSelectionKey = nil
    _lastArcKey = nil
    _announceCountdown = nil
end

--- True while a popup or the Episode Map is open (story node polling pauses).
function EpisodeMap.IsOverlayOpen()
    return _detailsOpen or _mapOpen
end

--- Internal state snapshot for the story trace (debug_tools.lua, F7).
function EpisodeMap.GetDebugState()
    return {
        { "map.detailsOpen", tostring(_detailsOpen) },
        { "map.mapOpen", tostring(_mapOpen) },
        { "map.saga", tostring(_lastSaga) },
        { "map.selection", tostring(_lastSelectionKey) },
    }
end

-- === HELPERS ===

local function GetFullName(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and name or nil
end

--- Last path segment, e.g. "WBP_GRP_AI_ChartDetails_C_2147464258".
local function InstanceIdOf(obj)
    local path = GetFullName(obj)
    return path and path:match("([^%.:]+)$") or nil
end

local function GetOpacity(w)
    local v = TryCall(w, "GetRenderOpacity")
    return type(v) == "number" and v or 1.0
end

--- Open = game marks the menu active, it is visible, and it is actually drawn.
local function IsShown(w)
    if not w or not IsValidRef(w) then return false end
    local okA, active = pcall(function() return w.bIsActive end)
    if okA and active == false then return false end
    if not TryCall(w, "IsVisible") then return false end
    if GetOpacity(w) < 0.01 then return false end
    local okR, root = pcall(function() return w.WidgetTree.RootWidget end)
    if okR and root and IsValidRef(root) and GetOpacity(root) < 0.01 then
        return false
    end
    return true
end

--- Live (Transient) instances of a class, including Blueprint subclasses.
local function FindLive(className)
    local ok, list = pcall(FindAllOf, className)
    if not ok or not list then
        if not _loggedMissingClass[className] then
            _loggedMissingClass[className] = true
            print("[AE] EpisodeMap: no instances of " .. className .. " (logged once)")
        end
        return {}
    end
    local result = {}
    for _, obj in ipairs(list) do
        local path = GetFullName(obj)
        if path and path:find("Transient", 1, true) then
            table.insert(result, obj)
        end
    end
    return result
end

local function FindShown(className)
    for _, w in ipairs(FindLive(className)) do
        if IsShown(w) then return w end
    end
    return nil
end

local function ReadTextProp(w, propName)
    local ok, text = pcall(function() return w[propName]:GetText():ToString() end)
    if ok and text and text ~= "" then return text end
    return nil
end

local function GetSwitcherIndex(w, propName)
    local ok, sw = pcall(function() return w[propName] end)
    if not ok or not sw or not IsValidRef(sw) then return nil end
    local idx = TryCall(sw, "GetActiveWidgetIndex")
    return type(idx) == "number" and idx or nil
end

-- Untranslated widgets keep Japanese designer placeholders; never speak them
local JP_CHAR = "[\227-\233][\128-\191][\128-\191]"

local function CleanText(text)
    if not text or text:find(JP_CHAR) then return nil end
    local collapsed = text:gsub("[\r\n]+", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if not collapsed or collapsed == "" or collapsed == "text" then return nil end
    return collapsed
end

--- All non-empty TextBlocks inside a widget instance.
local function CollectTexts(instanceId)
    local result = {}
    if not instanceId then return result end
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return result end
    local needle = instanceId .. "."
    for _, tb in ipairs(textBlocks) do
        local path = GetFullName(tb)
        if path and path:find(needle, 1, true) then
            local ok, text = pcall(function() return tb:GetText():ToString() end)
            if ok and text and text ~= "" then
                table.insert(result, {
                    name = path:match("([^%.:]+)$"),
                    path = path,
                    text = text,
                })
            end
        end
    end
    return result
end

local function SpeakLines(lines, interrupt)
    for i, line in ipairs(lines) do
        if i == 1 and interrupt then
            Speak(line, true)
        else
            SpeakQueued(line)
        end
    end
end

-- === DETAILS / RECAP POPUP ===

--- Character name from a WBP_OBJ_AI_CharaIcon_C (switcher: 0 Normal, 1 Unknown, 2 Lock).
local function ReadIconName(icon)
    if not icon or not IsValidRef(icon) or not TryCall(icon, "IsVisible") then return nil end
    local state = GetSwitcherIndex(icon, "WidgetSwitcher_0") or 0
    local imgName = (state == 2) and "IMG_Chara_01" or "IMG_Chara"
    local okT, texName = pcall(function()
        local res = icon[imgName].Brush.ResourceObject
        return res and res:GetFullName() or nil
    end)
    local charaId = okT and texName and CharaNames.ExtractIdFromTexture(texName) or nil
    if not charaId then return nil end  -- dummy texture = unused slot
    if state == 1 then return "Unknown fighter" end
    local name = CharaNames.GetName(charaId) or ("Character " .. charaId)
    if state == 2 then name = name .. ", locked" end
    return name
end

local function BuildInfoPage(details, detailsId, texts)
    local lines = { "Details" }

    -- Teams: icons 0-4 sit in the left box, 5-9 in the right box
    for _, teamSet in ipairs(FindLive("WBP_OBJ_AI_TeamList_Set_C")) do
        local path = GetFullName(teamSet)
        if path and path:find(detailsId .. ".", 1, true) then
            local yours, theirs = {}, {}
            for i = 0, 9 do
                local ok, icon = pcall(function() return teamSet["WBP_OBJ_AI_CharaIcon_" .. i] end)
                local name = ok and ReadIconName(icon) or nil
                if name then
                    table.insert(i <= 4 and yours or theirs, name)
                end
            end
            if #yours > 0 then table.insert(lines, "Your team: " .. table.concat(yours, ", ")) end
            if #theirs > 0 then table.insert(lines, "Opponents: " .. table.concat(theirs, ", ")) end
            break
        end
    end

    -- Clear condition and rewards
    local condTitle, condText, rewardTitle, rewardNote
    local rewards = {}
    for _, t in ipairs(texts) do
        local clean = CleanText(t.text)
        if clean then
            if t.path:find(".WBP_OBJ_AI_VictoryConditions_Set.", 1, true) then
                if t.name == "CategoryTitleText" then condTitle = clean
                elseif t.name == "Text_StageName" then condText = clean end
            elseif t.path:find(".WBP_OBJ_AI_Reward_Set.", 1, true) then
                local idx = t.path:match("%.WBP_OBJ_AI_Reward_(%d+)%.")
                if idx then
                    rewards[tonumber(idx)] = rewards[tonumber(idx)] or {}
                    rewards[tonumber(idx)][t.name] = clean
                elseif t.name == "CategoryTitleText" then
                    rewardTitle = clean
                end
            elseif t.name == "TXT_Reward_Text" then
                rewardNote = clean
            end
        end
    end

    if condText then
        table.insert(lines, (condTitle or "Clear condition") .. ": " .. condText)
    end

    local okRS, rewardSet = pcall(function() return details.WBP_OBJ_AI_Reward_Set end)
    local rewardParts = {}
    for i = 0, 6 do
        local r = rewards[i]
        local visible = true
        if okRS and rewardSet and IsValidRef(rewardSet) then
            local okR, rw = pcall(function() return rewardSet["WBP_OBJ_AI_Reward_" .. i] end)
            visible = okR and rw and TryCall(rw, "IsVisible") or false
        end
        if r and visible and r.Text_RewardName then
            local part = r.Text_RewardName
            if r.Text_RewardNum then
                part = part .. " " .. (r.Text_RewardCount or "x") .. " " .. r.Text_RewardNum
            end
            table.insert(rewardParts, part)
        end
    end
    if #rewardParts > 0 then
        table.insert(lines, (rewardTitle or "Rewards") .. ": " .. table.concat(rewardParts, ", "))
    end
    if rewardNote then table.insert(lines, rewardNote) end

    return lines
end

local function BuildOutlinePage(texts)
    local lines = { "Recap" }
    local title, body
    for _, t in ipairs(texts) do
        if not t.path:find(".WBP_OBJ_AI_VictoryConditions_Set.", 1, true)
           and not t.path:find(".WBP_OBJ_AI_Reward_Set.", 1, true) then
            if t.name == "CategoryTitleText" then title = CleanText(t.text)
            elseif t.name == "TXT_Outline" then body = CleanText(t.text) end
        end
    end
    if title then table.insert(lines, title) end
    if body then table.insert(lines, body) end
    return lines
end

local function PollDetails()
    local details = FindShown("SSDragonAdventureIFCTEventDetailsManager")
    if not details then
        if _detailsOpen then
            _detailsOpen = false
            _detailsPendingKey = nil
            _detailsAnnouncedKey = nil
            print("[AE] Episode details closed")
        end
        return
    end
    _detailsOpen = true

    local detailsId = InstanceIdOf(details)
    local texts = CollectTexts(detailsId)
    local page = GetSwitcherIndex(details, "WidgetSwitcher_Main")
    local lines
    if page == 1 then
        lines = BuildOutlinePage(texts)
    else
        lines = BuildInfoPage(details, detailsId, texts)
    end
    if #lines <= 1 then return end  -- content not filled in yet

    -- Announce only once the content is stable for a tick (widgets fill in
    -- over several frames); re-announce when the page content changes
    local key = tostring(page) .. "|" .. table.concat(lines, "|")
    if key ~= _detailsPendingKey then
        _detailsPendingKey = key
        return
    end
    if key == _detailsAnnouncedKey then return end
    _detailsAnnouncedKey = key

    SpeakLines(lines, true)
    print("[AE] Episode details page " .. tostring(page) .. ": " .. table.concat(lines, " | "))
end

-- === EPISODE MAP OVERLAY ===

--- Arc, route, and position of the piece under the cursor.
local function DescribePiece(mapId, piecePath, pieces)
    local info = {}
    local blockName = piecePath:match("%.(WBP_OBJ_AI_Map_Block_[%d_]+)%.")
    local rowName = piecePath:match("%.(WBP_OBJ_AI_Map_Row_[%d_]+)%.")
    local pieceIdx = tonumber(piecePath:match("Piece_(%d+)$") or "")
    if not blockName then return info end

    info.arcKey = mapId .. "|" .. blockName
    local rowSuffix = rowName and rowName:match("_(%d+)$")
    info.route = (rowSuffix == nil or rowSuffix == "00") and "main story" or "what if story"

    -- Position among visible episodes of the same arc
    local indices = {}
    local blockNeedle = "." .. blockName .. "."
    for _, p in ipairs(pieces) do
        local path = GetFullName(p)
        if path and path:find(mapId .. ".", 1, true) and path:find(blockNeedle, 1, true)
           and TryCall(p, "IsVisible") then
            local idx = tonumber(path:match("Piece_(%d+)$") or "")
            if idx then table.insert(indices, idx) end
        end
    end
    table.sort(indices)
    for i, idx in ipairs(indices) do
        if idx == pieceIdx then
            info.position = i
            break
        end
    end
    info.total = #indices

    -- Arc title lives in the block's TXT_ChapterTitle
    for _, t in ipairs(CollectTexts(mapId)) do
        if t.name == "TXT_ChapterTitle" and t.path:find(blockNeedle, 1, true) then
            info.arc = CleanText(t.text)
            break
        end
    end
    return info
end

local function AnnounceSelection(mapId, cursorPath, pieces, outline)
    local lines = {}

    local title = outline and ReadTextProp(outline, "TXT_Title") or nil
    if title == "???" then
        title = "Unknown episode"
    else
        title = CleanText(title)
    end
    table.insert(lines, title or "Episode")

    local header = outline and GetSwitcherIndex(outline, "WidgetSwitcher_Header") or nil
    if header == 0 then
        table.insert(lines, "Battle")
    elseif header == 1 then
        table.insert(lines, "Event")
    end

    if cursorPath then
        local info = DescribePiece(mapId, cursorPath, pieces)
        if info.arcKey and info.arcKey ~= _lastArcKey then
            _lastArcKey = info.arcKey
            table.insert(lines, (info.arc or "Arc") .. ", " .. info.route)
        end
        if info.position and info.total and info.total > 0 then
            table.insert(lines, "Episode " .. info.position .. " of " .. info.total)
        end
    end

    if outline then
        for _, t in ipairs(CollectTexts(InstanceIdOf(outline))) do
            if t.name == "TXT_main" then
                local synopsis = CleanText(t.text)
                if synopsis then table.insert(lines, synopsis) end
                break
            end
        end
    end

    SpeakLines(lines, not _queueNextSelection)
    _queueNextSelection = false
    print("[AE] Episode map selection: " .. table.concat(lines, " | "):sub(1, 200))
end

local function PollEpisodeMap()
    local mapW = FindShown("SSDragonAdventureIFCTMapManager")
    if not mapW then
        if _mapOpen then
            _mapOpen = false
            _queueNextSelection = false
            _lastSaga = nil
            _lastSelectionKey = nil
            _lastArcKey = nil
            _announceCountdown = nil
            print("[AE] Episode map closed")
        end
        return
    end
    local mapId = InstanceIdOf(mapW)
    if not mapId then return end

    if not _mapOpen then
        _mapOpen = true
        _queueNextSelection = true
        Speak("Episode Map", true)
        print("[AE] Episode map opened: " .. mapId)
    end

    -- Saga selector (bIsActive stays false here, so only check visibility)
    for _, sel in ipairs(FindLive("SSDragonAdventureIFCTMapCharaSelectManager")) do
        if TryCall(sel, "IsVisible") then
            local saga = CleanText(ReadTextProp(sel, "TXT_CharacterName"))
            if saga then
                if saga ~= _lastSaga then
                    local switched = _lastSaga ~= nil
                    _lastSaga = saga
                    _lastArcKey = nil
                    if switched then
                        Speak(saga, true)
                        _queueNextSelection = true
                    else
                        SpeakQueued(saga)
                    end
                    print("[AE] Episode map saga: " .. saga)
                end
                break
            end
        end
    end

    -- Cursor piece + outline title identify the current selection
    local pieces = FindLive("SSDragonAdventureIFCTMapIconWidget")
    local cursorPath = nil
    local needle = mapId .. "."
    for _, piece in ipairs(pieces) do
        local path = GetFullName(piece)
        if path and path:find(needle, 1, true) and TryCall(piece, "IsVisible") then
            local ok, opacity = pcall(function()
                return piece.IMG_Corner_0:GetParent():GetRenderOpacity()
            end)
            if ok and type(opacity) == "number" and opacity > 0.1 then
                cursorPath = path
                break
            end
        end
    end

    local outline = FindShown("SSDragonAdventureIFCTMapOutlineManager")
    local title = outline and ReadTextProp(outline, "TXT_Title") or nil

    local key = (cursorPath or "") .. "|" .. (title or "")
    if key ~= _lastSelectionKey then
        -- Wait one tick so the outline panel and cursor settle together
        _lastSelectionKey = key
        _announceCountdown = 0
        return
    end

    if _announceCountdown then
        if _announceCountdown > 0 then
            _announceCountdown = _announceCountdown - 1
            return
        end
        _announceCountdown = nil
        if cursorPath or title then
            AnnounceSelection(mapId, cursorPath, pieces, outline)
        end
    end
end

-- === POLL ENTRY ===

--- Called from the 100ms poll loop. Only does work while the story map is up.
function EpisodeMap.Poll(storyMapActive)
    if not Speak then return end
    if not storyMapActive then
        if _detailsOpen or _mapOpen then
            EpisodeMap.Reset()
        end
        return
    end
    PollDetails()
    PollEpisodeMap()
end

return EpisodeMap
