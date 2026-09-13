--[[
    customize.lua — Character customize screens (Battle Setup → Customize)

    All three screens focus invisible WBP_OBJ_Common_HitButton_C widgets whose
    RemoteButton property is the visible widget they drive. The owning dialog
    (in the hit button's full path) says which screen it is.

    Structure (F6 dumps 2026-09-13):
      - Top menu: WBP_GRP_BS_Custom_00_DP_C (Text_Title "Customize"; the
        character name is Text_Name in WBP_GRP_BS_Custom_NameSet_DP_C)
          HitButton_0 .. _6      -> WBP_OBJ_BS_ItemIcon_S_N (ability item slots,
                                    no text: BindImage/TextureResourceObject is
                                    T_UI_ItemFrame_Empty_Icon or the item's icon;
                                    switcher "Swich" 0 Normal / 1 SetOn / 2 Lock / 3 Disable)
          Hit_Category_0 .. _5   -> WBP_OBJ_BS_BTN_C_category_NN (caption:
                                    Outfits, CPU Settings, Emote, Fusion,
                                    Sparking! BGM, Taunt; WidgetSwitcher_88
                                    0 Normal / 1 Disable)
          TXT_ItemName (Caution scroll box) = warning text, Collapsed normally
      - Slots screen: WBP_OBJ_BS_Custom_MS_ItemName_0 .. _6 get focus directly
        (class WBP_OBJ_BS_Custom_MS_ItemName_C). NOT dumped yet: read as
        generic text + optional WidgetSwitcher_109 state (0 Empty / 1 Set / 2 Lock)
      - Picker: WBP_GRP_BS_Custom_Item_DP_C (Text_Title "Ability Items",
        description TextBlock_0 .. _4, one line each, unused lines Collapsed)
          HitButton_00 .. _14    -> WBP_OBJ_BS_ItemIcon_M_NN (Txt_ItemName,
                                    "Swich" 0 Normal / 1 SetOn / 2 Lock / 3 Disable,
                                    WBP_OBJ_Com_NewIcon_M). 3 columns, the view
                                    scroll recycles the 15 icons
      - Right panel (picker open): WBP_GRP_BS_Custom_Item_R_C
          Item_Sp_0 .. _6 (WidgetSwitcher_SP: 0 Nothing / 1 Select / 2 SetOn)
          WBP_OBJ_BS_Custom_Chart: ChartValueInterpolateTo (current stats) and
          ChartValueAfterInterpolateTo (preview with the focused item), 5
          floats: HP, Attack, Ki, Agility, Special Attack, scale 0-5

    Item icons carry no name on the top menu, so the picker teaches this
    module which icon texture belongs to which item name (strings only, safe
    across GC) and the top menu uses that map when it has seen the item.

    After a garbage collection the registry may answer nil for a class in the
    tick that re-fires the focus; every reader here then gives up quietly
    instead of speaking a widget name.
]]

local H = require("helpers")
local TryCall = H.TryCall
local TryGetProperty = H.TryGetProperty
local IsValidRef = H.IsValidRef
local GetWidgetName = H.GetWidgetName
local GetClassName = H.GetClassName

local Customize = {}

local Speak = nil
local SpeakQueued = nil

local TOP_CLASS = "WBP_GRP_BS_Custom_00_DP_C"
local NAME_CLASS = "WBP_GRP_BS_Custom_NameSet_DP_C"
local PICKER_CLASS = "WBP_GRP_BS_Custom_Item_DP_C"
local SLOT_CLASS = "WBP_OBJ_BS_Custom_MS_ItemName_C"
local RIGHT_PANEL_CLASS = "WBP_GRP_BS_Custom_Item_R_C"
local HIT_BUTTON_CLASS = "WBP_OBJ_Common_HitButton_C"
local EMPTY_TEXTURE = "T_UI_ItemFrame_Empty_Icon"

local ICON_STATE = { [1] = "equipped", [2] = "locked", [3] = "unavailable" }
local SLOT_STATE = { [0] = "empty", [2] = "locked" }
local STAT_NAMES = { "HP", "Attack", "Ki", "Agility", "Special Attack" }
local SP_SELECT, SP_SET = 1, 2

local VIS_COLLAPSED, VIS_HIDDEN = 1, 2

-- texture name -> item name, learned from the picker's icons
local _itemNameByTexture = {}

-- Untranslated widgets keep Japanese designer placeholders; never speak them
local JP_CHAR = "[\227-\233][\128-\191][\128-\191]"

local function CleanText(text)
    if not text or text:find(JP_CHAR) then return nil end
    local s = text:gsub("[\r\n]+", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if s == "" or s:find("^ST_UI_") then return nil end  -- unresolved string id
    return s
end

local function ReadText(tb)
    local ok, text = pcall(function() return tb:GetText():ToString() end)
    if ok then return CleanText(text) end
    return nil
end

local function GetSwitcherIndex(widget, propName)
    local sw = TryGetProperty(widget, propName)
    if not sw or not IsValidRef(sw) then return nil end
    local idx = TryCall(sw, "GetActiveWidgetIndex")
    return type(idx) == "number" and idx or nil
end

local function IsShown(widget)
    if not widget or not IsValidRef(widget) then return false end
    local vis = TryCall(widget, "GetVisibility")
    return type(vis) == "number" and vis ~= VIS_COLLAPSED and vis ~= VIS_HIDDEN
end

local function FullName(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and name or nil
end

-- Name of the texture an SSRemoteButton icon shows (TextureResourceObject)
local function IconTexture(icon)
    local ok, name = pcall(function()
        return icon.TextureResourceObject:GetFName():ToString()
    end)
    return ok and name or nil
end

local function FormatStat(v)
    local s = string.format("%.1f", v)
    return (s:gsub("%.0$", ""))
end

-- === DETECTION ===

--- "top" / "picker" for a customize hit button, nil for anything else
function Customize.HitButtonContext(widget)
    if GetClassName(widget) ~= HIT_BUTTON_CLASS then return nil end
    local path = FullName(widget)
    if not path then return nil end
    if path:find(PICKER_CLASS, 1, true) then return "picker" end
    if path:find(TOP_CLASS, 1, true) then return "top" end
    return nil
end

function Customize.IsSlot(widget)
    return GetClassName(widget) == SLOT_CLASS
end

-- === RIGHT PANEL (ability points + stat chart) ===

-- Returns points the focused item would take, points in use, gauge size
local function ReadPointGauge(panel)
    local selected, used, total = 0, 0, 0
    for i = 0, 6 do
        local idx = GetSwitcherIndex(TryGetProperty(panel, "Item_Sp_" .. i), "WidgetSwitcher_SP")
        if idx == nil then break end
        total = total + 1
        if idx == SP_SELECT then selected = selected + 1
        elseif idx == SP_SET then used = used + 1 end
    end
    if total == 0 then return nil end
    return selected, used, total
end

local function ReadFloatArray(obj, prop)
    local ok, vals = pcall(function()
        local arr = obj[prop]
        local out = {}
        for i = 1, #arr do out[i] = arr[i] end
        return out
    end)
    return ok and vals or nil
end

-- "HP 3.5 to 3.8, Attack 4.4 to 4.5" for the stats the focused item changes
local function ReadStatChanges(panel)
    local chart = TryGetProperty(panel, "WBP_OBJ_BS_Custom_Chart")
    if not chart or not IsValidRef(chart) then return nil end
    local now = ReadFloatArray(chart, "ChartValueInterpolateTo")
    local after = ReadFloatArray(chart, "ChartValueAfterInterpolateTo")
    if not now or not after then return nil end
    local parts = {}
    for i, stat in ipairs(STAT_NAMES) do
        local a, b = now[i], after[i]
        if type(a) == "number" and type(b) == "number" and math.abs(a - b) > 0.05 then
            table.insert(parts, stat .. " " .. FormatStat(a) .. " to " .. FormatStat(b))
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- === TOP MENU ===

local function OnTopFocused(widget, firstEntry)
    local name = GetWidgetName(widget)
    local remote = TryGetProperty(widget, "RemoteButton")
    if not remote or not IsValidRef(remote) then
        print("[AE] Customize top: no RemoteButton on " .. name)
        return
    end
    local remoteClass = GetClassName(remote)
    local parts = {}

    if remoteClass == "WBP_OBJ_BS_ItemIcon_S_C" then
        local slot = tonumber(GetWidgetName(remote):match("_(%d+)$"))
        table.insert(parts, "Ability item slot " .. (slot and slot + 1 or "?"))
        local tex = IconTexture(remote)
        if tex == nil or tex == EMPTY_TEXTURE then
            table.insert(parts, "empty")
        else
            table.insert(parts, _itemNameByTexture[tex] or "item set")
        end
        local state = ICON_STATE[GetSwitcherIndex(remote, "Swich") or 0]
        if state and state ~= "equipped" then table.insert(parts, state) end
        if IsShown(TryGetProperty(remote, "WBP_OBJ_Com_NewIcon_S")) then
            table.insert(parts, "new")
        end
    else
        -- Category button: caption is a bound TextBlock
        local caption = nil
        local cap = TryGetProperty(remote, "caption")
        if cap and IsValidRef(cap) then caption = ReadText(cap) end
        table.insert(parts, caption or GetWidgetName(remote))
        if GetSwitcherIndex(remote, "WidgetSwitcher_88") == 1 then
            table.insert(parts, "unavailable")
        end
        if IsShown(TryGetProperty(remote, "WBP_OBJ_Com_NewIcon_M")) then
            table.insert(parts, "new")
        end
    end

    local announcement = table.concat(parts, ", ")
    if firstEntry then
        -- Title + character name, then the focused element
        local header = { "Customize" }
        local textBlocks = FindAllOf("TextBlock")
        if textBlocks then
            for _, tb in ipairs(textBlocks) do
                if GetWidgetName(tb) == "Text_Name" then
                    local tbPath = FullName(tb)
                    if tbPath and tbPath:find(NAME_CLASS, 1, true) then
                        local charaName = ReadText(tb)
                        if charaName then table.insert(header, charaName) end
                        break
                    end
                end
            end
        end
        Speak(table.concat(header, ", "), true)
        SpeakQueued(announcement)
    else
        Speak(announcement, true)
    end
    print("[AE] Customize top: " .. announcement .. " (" .. GetWidgetName(remote) .. ")")
end

-- === ITEM PICKER ===

local function OnPickerFocused(widget, firstEntry)
    local path = FullName(widget)
    if not path then return end
    local pickerId = path:match("(" .. PICKER_CLASS .. "_%d+)")
    if not pickerId then return end

    local icon = TryGetProperty(widget, "RemoteButton")
    local iconName = (icon and IsValidRef(icon)) and GetWidgetName(icon) or nil
    if not iconName then
        print("[AE] Customize picker: no RemoteButton on " .. GetWidgetName(widget))
        return
    end

    -- Registry busy after a GC: this focus re-fires anyway, skip quietly
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then
        print("[AE] Customize picker: TextBlock registry empty, skipped")
        return
    end

    -- One TextBlock pass: title, every icon's item name, description lines
    local title = nil
    local namesByIcon = {}
    local descLines = {}
    for _, tb in ipairs(textBlocks) do
        local tbPath = FullName(tb)
        if tbPath and tbPath:find(pickerId, 1, true) then
            local tbName = GetWidgetName(tb)
            if tbName == "Text_Title" and not title then
                title = ReadText(tb)
            elseif tbName == "Txt_ItemName" then
                local owner = tbPath:match("%.(WBP_OBJ_BS_ItemIcon_M_%d+)%.")
                if owner and not namesByIcon[owner] then
                    namesByIcon[owner] = ReadText(tb)
                end
            else
                local n = tbName:match("^TextBlock_(%d+)$")
                if n and not descLines[tonumber(n)] and TryCall(tb, "IsVisible") then
                    descLines[tonumber(n)] = ReadText(tb)
                end
            end
        end
    end

    -- Teach the texture -> name map from every named icon on screen
    local picker = H.GetCachedFirstOf(PICKER_CLASS)
    if picker then
        for owner, itemName in pairs(namesByIcon) do
            if itemName then
                local ownerIcon = TryGetProperty(picker, owner)
                local tex = ownerIcon and IsValidRef(ownerIcon) and IconTexture(ownerIcon) or nil
                if tex and tex ~= EMPTY_TEXTURE then _itemNameByTexture[tex] = itemName end
            end
        end
    end

    local itemName = namesByIcon[iconName]
    if not itemName then
        print("[AE] Customize picker: no item name under " .. iconName)
        return
    end

    local parts = { itemName }
    local state = ICON_STATE[GetSwitcherIndex(icon, "Swich") or 0]
    if state then table.insert(parts, state) end
    if IsShown(TryGetProperty(icon, "WBP_OBJ_Com_NewIcon_M")) then
        table.insert(parts, "new")
    end
    local announcement = table.concat(parts, ", ")

    if firstEntry then
        Speak(title or "Ability Items", true)
        SpeakQueued(announcement)
    else
        Speak(announcement, true)
    end

    local desc = {}
    for i = 0, 9 do
        if descLines[i] then table.insert(desc, descLines[i]) end
    end
    if #desc > 0 then SpeakQueued(table.concat(desc, " ")) end

    local extra = nil
    local panel = H.GetCachedFirstOf(RIGHT_PANEL_CLASS)
    if panel then
        local changes = ReadStatChanges(panel)
        if changes then SpeakQueued(changes) end
        local selected, used, total = ReadPointGauge(panel)
        if selected and (selected > 0 or used > 0) then
            extra = string.format("cost %d, %d of %d points used", selected, used, total)
            SpeakQueued(extra)
        end
        extra = (changes or "") .. " / " .. (extra or "")
    end
    print(string.format("[AE] Customize item: %s (%s, %s)", announcement, iconName, tostring(extra)))
end

function Customize.OnHitButtonFocused(widget, context, firstEntry)
    if context == "picker" then
        OnPickerFocused(widget, firstEntry)
    elseif context == "top" then
        OnTopFocused(widget, firstEntry)
    end
end

-- === SLOTS SCREEN ===

function Customize.OnSlotFocused(widget)
    local name = GetWidgetName(widget)
    local slotNum = tonumber(name:match("_(%d+)$"))
    local path = FullName(widget)
    if not path then return end
    local instancePath = path:match(":(.+)$") or path

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then
        print("[AE] Customize slot: TextBlock registry empty, skipped")
        return
    end

    -- Every readable text inside the slot widget (layout not dumped yet)
    local texts = {}
    for _, tb in ipairs(textBlocks) do
        local tbPath = FullName(tb)
        if tbPath and tbPath:find(instancePath, 1, true) then
            local text = ReadText(tb)
            if text then table.insert(texts, GetWidgetName(tb) .. "=" .. text) end
        end
    end
    print("[AE] Customize slot " .. name .. ": " .. table.concat(texts, " | "))

    local parts = {}
    if slotNum then table.insert(parts, "Slot " .. (slotNum + 1)) end
    local state = SLOT_STATE[GetSwitcherIndex(widget, "WidgetSwitcher_109") or -1]
    local itemName = nil
    for _, entry in ipairs(texts) do
        local value = entry:match("^[^=]+=(.+)$")
        if value and value ~= "" then itemName = value; break end
    end
    if itemName and state ~= "empty" then
        table.insert(parts, itemName)
    elseif state then
        table.insert(parts, state)
    elseif not itemName then
        table.insert(parts, "empty")
    end
    Speak(table.concat(parts, ", "), true)

    local panel = H.GetCachedFirstOf(RIGHT_PANEL_CLASS)
    if panel then
        local _, used, total = ReadPointGauge(panel)
        if used and used > 0 then SpeakQueued(used .. " of " .. total .. " points used") end
    end
end

-- === LIFECYCLE ===

function Customize.Init(speakFn, speakQueuedFn)
    Speak = speakFn
    SpeakQueued = speakQueuedFn
end

function Customize.Reset()
    -- The texture -> name map holds strings only and is kept for the session
end

return Customize
