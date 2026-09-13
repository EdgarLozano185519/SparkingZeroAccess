--[[
    shop.lua — Shop accessibility
    Handles the shop item grid, reading item names, prices, descriptions,
    category tabs, and Zeni balance.

    Shop Top: WBP_OBJ_SH_BTN_Shop_C / WBP_OBJ_SH_BTN_Customize_C
      -> Handled via WidgetLabels in widget_reader.lua

    Shop Main (WBP_GRP_SH_Main_00_C):
      - Item grid: WBP_OBJ_SH_ItemIcon_S00_C (small, ability items)
                    WBP_OBJ_SH_ItemIcon_L00_C (large, characters/outfits)
      - Detail: TXT_Detail_00 (description), TXT_CategoryName, TXT_Money
      - Categories: WBP_OBJ_SH_BTN_Category_00 through _06
      - Pages: WBP_OBJ_SH_Pager_Item_1 through _5

    Item state (F6 dump of WBP_OBJ_SH_ItemIcon_S00_C, 2026-09-13):
      - WidgetSwitcher_Price pages: 0 Enable (plain price), 1 Sale,
        2 MoneyShortage, 3 SaleAndShortage, 4 SoldOut ("SOLD OUT" replaces
        the price). A purchased one-off item flips to page 4 and its
        WidgetSwitcher_Item to page 1
      - Overlay "Stock" (TXT_Stock_Label "Available" + TXT_Stock_Num_0),
        Overlay "Check" (IMG_Check) and Overlay "NewIcon" are Collapsed on
        every ability item seen so far; read when shown, since the L-type
        icons (characters/outfits) may use them
]]

local H = require("helpers")
local TryCall = H.TryCall
local TryGetProperty = H.TryGetProperty
local IsValidRef = H.IsValidRef
local GetWidgetName = H.GetWidgetName
local GetClassName = H.GetClassName

local Shop = {}

-- === STATE ===

local Speak = nil
local SpeakQueued = nil

local _lastItemName = nil
local _lastItemNameOnly = nil  -- just the name without price, for dedup
local _lastCategory = nil
local _announcedEntry = false
local _lastDialogHeader = nil

-- WidgetSwitcher_Price pages (see header comment)
local PRICE_PAGE_SALE = { [1] = true, [3] = true }
local PRICE_PAGE_SHORTAGE = { [2] = true, [3] = true }
local PRICE_PAGE_SOLDOUT = 4

-- ESlateVisibility values that hide a widget
local VIS_COLLAPSED = 1
local VIS_HIDDEN = 2

-- === DETECTION ===

-- Shop items come in two sizes: S (small, ability items) and L (large, characters/outfits)
function Shop.IsShopItem(widget)
    local cn = GetClassName(widget)
    return cn == "WBP_OBJ_SH_ItemIcon_S00_C" or cn == "WBP_OBJ_SH_ItemIcon_L00_C"
end

-- === READING ===

-- Read item details from TextBlocks inside the focused item icon.
-- Each item icon has TWO layers of TextBlocks: a template and real data.
-- We filter out template values (Japanese names, "99,999,999,000" price) to get the real data.
-- IMPORTANT: Match on widget's FULL PATH, not just name. Multiple grids can have
-- identically-named widgets (e.g. two WBP_GRP_SH_Main_L00_C instances for Characters vs Outfits).
local function ReadItemFromWidget(widget)
    -- Get unique path from widget's full name. The full name looks like:
    -- "ClassName /Engine/Transient.GameEngine_123:BP_SSGameInstance_456.Container_789.WidgetTree_012.WidgetName"
    -- We extract everything after ":" which includes unique container instance IDs.
    local ok0, widgetPath = pcall(function() return widget:GetFullName() end)
    if not ok0 or not widgetPath then return nil, nil end
    local instancePath = widgetPath:match(":(.+)$")
    if not instancePath then return nil, nil end

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil, nil end

    local itemName = nil
    local price = nil
    local salePrice = nil   -- TXT_PriceNum_Sale_0 (Sale page; TXT_PriceNum_1 next to it is the struck-out old price)
    local stockNum = nil    -- TXT_Stock_Num_0 (count shown in the "Stock" overlay)

    -- Template price "99,999,999,000" contains commas, real prices do not
    local function RealPrice(tb)
        local ok2, text = pcall(function() return tb:GetText():ToString() end)
        if ok2 and text and text ~= "" and not text:find(",", 1, true) then
            return text
        end
        return nil
    end

    for _, tb in ipairs(textBlocks) do
        local ok, tbPath = pcall(function() return tb:GetFullName() end)
        if ok and tbPath:find(instancePath, 1, true) then
            local tbName = GetWidgetName(tb)
            -- Keep FIRST non-template match for each field.
            -- S-type: template (Japanese/commas) first, real second → first valid = real
            -- L-type: real first, stale previous-category data second → first valid = real
            if tbName == "Txt_ItemName" and not itemName then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    -- Skip Japanese placeholder text (アイテム名)
                    if not text:find("\227\130\162\227\130\164\227\131\134\227\131\160", 1, true) then
                        itemName = text
                    end
                end
            elseif tbName == "TXT_PriceNum_0" and not price then
                price = RealPrice(tb)
            elseif tbName == "TXT_PriceNum_Sale_0" and not salePrice then
                salePrice = RealPrice(tb)
            elseif tbName == "TXT_Stock_Num_0" and not stockNum then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then stockNum = text end
            end
        end
    end

    return itemName, price, salePrice, stockNum
end

-- Active page of a WidgetSwitcher that is a bound variable of the widget
local function GetSwitcherIndex(widget, propName)
    local sw = TryGetProperty(widget, propName)
    if not sw or not IsValidRef(sw) then return nil end
    local idx = TryCall(sw, "GetActiveWidgetIndex")
    return type(idx) == "number" and idx or nil
end

-- Whether the nearest ancestor of `child` named `name` is shown (not
-- Collapsed/Hidden). The item icon's "Stock" and "Check" overlays are not
-- bound variables, but their children are, so walk up from those.
-- Returns nil when the ancestor is not found.
local function NamedAncestorShown(child, name)
    if not child or not IsValidRef(child) then return nil end
    local w = child
    for _ = 1, 6 do
        local ok, parent = pcall(function() return w:GetParent() end)
        if not ok or not parent or not IsValidRef(parent) then return nil end
        if GetWidgetName(parent) == name then
            local vis = TryCall(parent, "GetVisibility")
            if type(vis) ~= "number" then return nil end
            return vis ~= VIS_COLLAPSED and vis ~= VIS_HIDDEN
        end
        w = parent
    end
    return nil
end

-- Purchase / price state of the focused item icon (see header comment).
-- Every field is nil when the icon has no such widget (e.g. an L-type icon
-- with a different layout), so callers fall back to the plain price.
local function ReadItemState(widget)
    local pricePage = GetSwitcherIndex(widget, "WidgetSwitcher_Price")
    local state = {
        pricePage = pricePage,
        soldOut = pricePage == PRICE_PAGE_SOLDOUT,
        sale = pricePage ~= nil and PRICE_PAGE_SALE[pricePage] == true,
        shortage = pricePage ~= nil and PRICE_PAGE_SHORTAGE[pricePage] == true,
        checkShown = NamedAncestorShown(TryGetProperty(widget, "IMG_Check"), "Check"),
        stockShown = NamedAncestorShown(TryGetProperty(widget, "WidgetSwitcher_StockNum"), "Stock"),
        stockLabel = nil,
    }
    if state.stockShown then
        local ok, text = pcall(function() return widget.TXT_Stock_Label:GetText():ToString() end)
        if ok and text and text ~= "" then state.stockLabel = text end
    end
    return state
end

-- Spoken form of name + price + state, following what the icon shows
local function BuildItemAnnouncement(itemName, price, salePrice, stockNum, state)
    local parts = { itemName }
    if state.soldOut then
        table.insert(parts, "sold out")
    elseif state.sale and salePrice then
        table.insert(parts, "on sale, " .. salePrice .. " Zeni")
        if price and price ~= salePrice then
            table.insert(parts, "was " .. price)
        end
    elseif price then
        table.insert(parts, price .. " Zeni")
    end
    if state.shortage then
        table.insert(parts, "not enough Zeni")
    end
    if state.checkShown then
        table.insert(parts, "owned")
    end
    if state.stockShown and stockNum then
        table.insert(parts, (state.stockLabel or "Held") .. " " .. stockNum)
    end
    return table.concat(parts, ", ")
end

-- Read text from a named TextBlock inside WBP_GRP_SH_Main_00_C
local function ReadMainPanelText(tbName)
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil end

    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == tbName then
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find("WBP_GRP_SH_Main_00_C", 1, true)
               and tbPath:find("Transient", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    return text:gsub("\n", " "):gsub("%s+", " ")
                end
            end
        end
    end
    return nil
end

-- Read the item description from the main shop panel. The game splits it
-- into one TextBlock per line, TXT_Detail_00 through TXT_Detail_07 (unused
-- lines are Collapsed), so collect every shown line in order and join them.
local function ReadDescription()
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil end

    local lines = {}
    for _, tb in ipairs(textBlocks) do
        local idx = GetWidgetName(tb):match("^TXT_Detail_(%d+)$")
        if idx and not lines[tonumber(idx)] then
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find("WBP_GRP_SH_Main_00_C", 1, true)
               and tbPath:find("Transient", 1, true)
               and TryCall(tb, "IsVisible") then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    lines[tonumber(idx)] = text:gsub("[\r\n]+", " "):gsub("%s+", " ")
                end
            end
        end
    end

    local ordered = {}
    for i = 0, 15 do
        if lines[i] then table.insert(ordered, lines[i]) end
    end
    if #ordered == 0 then return nil end

    local desc = table.concat(ordered, " ")
    if desc == "Shop" then return nil end
    return desc
end

-- Read current category name
local function ReadCategory()
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil end

    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == "TXT_CategoryName" then
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find("Transient", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    return text
                end
            end
        end
    end
    return nil
end

-- Read current Zeni balance from main shop panel
local function ReadZeni()
    return ReadMainPanelText("TXT_Money")
end

-- === FOCUS HANDLER (called from main.lua) ===

function Shop.OnItemFocused(widget)
    local firstEntry = not _announcedEntry

    -- Read item info
    local itemName, price, salePrice, stockNum = ReadItemFromWidget(widget)
    local state = ReadItemState(widget)

    _lastDialogHeader = nil

    -- First entry: announce category + Zeni before the item
    if firstEntry then
        _announcedEntry = true
        local category = ReadCategory()
        if category then
            _lastCategory = category
            Speak(category, true)
        end
        local zeni = ReadZeni()
        if zeni then
            SpeakQueued(zeni .. " Zeni")
        end
    end

    if itemName then
        -- The state is part of the dedup key, so a purchase (focus returns to
        -- the same item, now sold out) is announced again
        local announcement = BuildItemAnnouncement(itemName, price, salePrice, stockNum, state)

        if announcement ~= _lastItemName or firstEntry then
            _lastItemName = announcement
            _lastItemNameOnly = itemName
            if firstEntry then
                SpeakQueued(announcement)
            else
                Speak(announcement, true)
            end
            print(string.format("[AE] Shop item: %s (price page %s, check %s, stock %s)",
                announcement, tostring(state.pricePage), tostring(state.checkShown),
                tostring(state.stockShown)))

            -- Queue description (skip if it repeats the item name or is a useless fragment)
            local desc = ReadDescription()
            if desc and desc ~= itemName
               and not desc:find("Emote Voiceover Set of", 1, true) then
                SpeakQueued(desc)
            end
        end
    end
end

-- Return the last item name without price (for dedup in main.lua generic handler)
function Shop.GetLastItemName()
    return _lastItemNameOnly
end

-- === SHOP DIALOG ===

-- Detect if widget is inside a shop purchase dialog (WBP_Dialog_SH_000_C)
function Shop.IsShopDialog(widget)
    local ok, path = pcall(function() return widget:GetFullName() end)
    if not ok or not path then return false end
    return path:find("WBP_Dialog_SH_", 1, true) ~= nil
end

-- Read shop dialog fields and announce
function Shop.OnShopDialogFocused(widget)
    local ok, widgetPath = pcall(function() return widget:GetFullName() end)
    if not ok or not widgetPath then return end

    local dialogId = widgetPath:match("(WBP_Dialog_SH_%d+_C_%d+)")
    if not dialogId then return end

    -- Read button label
    local WR = require("widget_reader")
    local buttonLabel = WR.GetSpokenLabel(widget)

    -- Read current header to detect new/changed dialog
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    local header = nil
    local itemLabel = nil
    local price = nil
    local balanceAfter = nil

    for _, tb in ipairs(textBlocks) do
        local tbOk, tbPath = pcall(function() return tb:GetFullName() end)
        if tbOk and tbPath:find(dialogId, 1, true) then
            local tbName = GetWidgetName(tb)
            if tbName == "Txt_Header" and not header then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then header = text end
            elseif tbName == "TXT_ItemLabel" and not itemLabel then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then itemLabel = text end
            elseif tbName == "TXT_Price" and not price then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then price = text end
            elseif tbName == "TXT_Money_1" and not balanceAfter then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then balanceAfter = text end
            end
        end
    end

    -- Same header as before = switching buttons within same dialog
    if header and header == _lastDialogHeader then
        if buttonLabel then
            Speak(buttonLabel, true)
        end
        return
    end
    _lastDialogHeader = header

    -- New dialog — announce full content
    if header then
        Speak(header, true)
        print("[AE] Shop dialog: " .. header)
    end
    if itemLabel then
        local itemInfo = itemLabel
        if price then itemInfo = itemInfo .. ", " .. price .. " Zeni" end
        SpeakQueued(itemInfo)
    end
    if balanceAfter then
        SpeakQueued("Balance after: " .. balanceAfter .. " Zeni")
    end
    if buttonLabel then
        SpeakQueued(buttonLabel)
    end
end

-- === POLLING ===

-- Poll for category changes (L1/R1 can switch categories without changing focus).
function Shop.PollCategory()
    if not _announcedEntry then return end -- not in shop yet

    local category = ReadCategory()
    if category and category ~= _lastCategory then
        _lastCategory = category
        -- Clear item cache so next focus navigation announces the item
        _lastItemName = nil
        Speak(category, true)
        print("[AE] Shop category: " .. category)
    end
end

-- === LIFECYCLE ===

function Shop.Init(speakFn, speakQueuedFn)
    Speak = speakFn
    SpeakQueued = speakQueuedFn
end

function Shop.Reset()
    _lastItemName = nil
    _lastItemNameOnly = nil
    _lastCategory = nil
    _announcedEntry = false
    _lastDialogHeader = nil
end

return Shop
