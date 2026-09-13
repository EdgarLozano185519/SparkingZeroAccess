--[[
    debug_tools.lua — Debug dump utilities for SparkingZeroAccess
    Remove or comment out the require("debug_tools") line in main.lua to disable.

    Keybinds:
        F5 = Toggle continuous debug dump (250ms, change-only)
        F3 = Battle state dump
        F4 = Character select dump
        F6 = Story map structure dump (appends one entry per press);
             first press on the story map also saves chart_actors.txt
        F7 = Toggle story trace (story_trace.txt, change log + spoken text)
        F8 = Trace marker (numbered, works with trace on or off)

    All dumps go to AE_debug/ folder in the Win64 directory.
    Key handlers and loops run on the game thread (game_thread.lua).
]]

local DebugTools = {}

-- === HELPERS ===

local H = require("helpers")
local TryCall = H.TryCall
local TryGetProperty = H.TryGetProperty
local GetWidgetName = H.GetWidgetName
local GetClassName = H.GetClassName
local GT = require("game_thread")

local DUMP_DIR = "AE_debug"

local function WriteDump(filename, content)
    local f = io.open(DUMP_DIR .. "/" .. filename, "w")
    if not f then
        print("[AE-DBG] Error: could not write " .. filename)
        return
    end
    f:write(content)
    f:close()
    print("[AE-DBG] Wrote " .. DUMP_DIR .. "/" .. filename)
end

local function AppendDump(filename, content)
    local f = io.open(DUMP_DIR .. "/" .. filename, "a")
    if not f then
        print("[AE-DBG] Error: could not append " .. filename)
        return
    end
    f:write(content)
    f:close()
end

-- === CONTINUOUS DEBUG DUMP (F5 toggle) ===
-- Combines F5-F8 into a single rolling dump that fires on change.

local _dumpActive = false
local _lastDumpFocus = nil     -- last focused widget name
local _lastDumpClassKey = nil  -- hash of visible class set
local _dumpEntryCount = 0

local function BuildDumpEntry()
    local lines = {}
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")

    -- Find focused widget and all visible widgets in one pass
    local allWidgets = FindAllOf("UserWidget")
    local focused = nil
    local classes = {}
    local classOrder = {}
    local totalVisible = 0

    if allWidgets then
        for _, w in ipairs(allWidgets) do
            local visible = TryCall(w, "IsVisible")
            if visible then
                local ok, fullName = pcall(function() return w:GetFullName() end)
                if ok and fullName:find("Transient") then
                    local className = GetClassName(w)
                    local widgetName = GetWidgetName(w)
                    local hasFocus = TryCall(w, "HasKeyboardFocus")

                    if hasFocus then focused = w end

                    if not classes[className] then
                        classes[className] = {}
                        table.insert(classOrder, className)
                    end
                    table.insert(classes[className], {
                        name = widgetName,
                        focused = hasFocus,
                    })
                    totalVisible = totalVisible + 1
                end
            end
        end
    end

    -- Build change detection key
    local focusName = focused and GetWidgetName(focused) or "(none)"
    local classKey = table.concat(classOrder, "|") .. "#" .. totalVisible

    -- Skip if nothing changed
    if focusName == _lastDumpFocus and classKey == _lastDumpClassKey then
        return nil
    end
    _lastDumpFocus = focusName
    _lastDumpClassKey = classKey

    -- === Header ===
    _dumpEntryCount = _dumpEntryCount + 1
    table.insert(lines, "========== Entry " .. _dumpEntryCount .. " [" .. timestamp .. "] ==========")
    table.insert(lines, "")

    -- TextBlock lists fetched for the focused subtree, reused for "All Visible Text"
    local allTB, allRTB = nil, nil

    -- === Focused Widget (F8 equivalent) ===
    table.insert(lines, "--- Focused Widget ---")
    if focused then
        table.insert(lines, "Name: " .. GetWidgetName(focused))
        table.insert(lines, "Class: " .. GetClassName(focused))
        table.insert(lines, "Path: " .. focused:GetFullName())

        -- Subtree text
        local focusedInstance = GetWidgetName(focused)
        local foundAny = false
        allTB = FindAllOf("TextBlock")
        if allTB then
            for _, tb in ipairs(allTB) do
                local ok2, tbPath = pcall(function() return tb:GetFullName() end)
                if ok2 and tbPath:find(focusedInstance, 1, true) then
                    local tbName = GetWidgetName(tb)
                    local ok3, text = pcall(function() return tb:GetText():ToString() end)
                    if ok3 and text and text ~= "" then
                        table.insert(lines, "  TB: " .. tbName .. " = \"" .. text .. "\"")
                        foundAny = true
                    end
                end
            end
        end
        allRTB = FindAllOf("RichTextBlock")
        if allRTB then
            for _, rb in ipairs(allRTB) do
                local ok2, rbPath = pcall(function() return rb:GetFullName() end)
                if ok2 and rbPath:find(focusedInstance, 1, true) then
                    local rbName = GetWidgetName(rb)
                    local ok3, text = pcall(function() return rb:GetText():ToString() end)
                    if ok3 and text and text ~= "" then
                        table.insert(lines, "  RTB: " .. rbName .. " = \"" .. text .. "\"")
                        foundAny = true
                    end
                end
            end
        end
        if not foundAny then
            table.insert(lines, "  (no text in subtree)")
        end
    else
        table.insert(lines, "(no widget has keyboard focus)")
    end
    table.insert(lines, "")

    -- === Visible Widget Classes (F5 equivalent) ===
    table.insert(lines, "--- Visible Widgets (" .. totalVisible .. " total, " .. #classOrder .. " classes) ---")
    for _, className in ipairs(classOrder) do
        local instances = classes[className]
        table.insert(lines, className .. " (" .. #instances .. ")")
        for _, inst in ipairs(instances) do
            local focusTag = inst.focused and " [FOCUSED]" or ""
            table.insert(lines, "  " .. inst.name .. focusTag)
        end
    end
    table.insert(lines, "")

    -- === All Visible Text (F7 equivalent) ===
    table.insert(lines, "--- All Visible Text ---")
    local textCount = 0

    -- Reuse allTB/allRTB from above if we had a focused widget, otherwise fetch fresh
    local tbList = allTB or FindAllOf("TextBlock")
    if tbList then
        for _, tb in ipairs(tbList) do
            local visible = TryCall(tb, "IsVisible")
            if visible then
                local ok, text = pcall(function() return tb:GetText():ToString() end)
                if ok and text and text ~= "" and text ~= "Text Block" then
                    table.insert(lines, "TB \"" .. text .. "\"")
                    table.insert(lines, "   " .. tb:GetFullName())
                    textCount = textCount + 1
                end
            end
        end
    end

    local rtbList = allRTB or FindAllOf("RichTextBlock")
    if rtbList then
        for _, rb in ipairs(rtbList) do
            local visible = TryCall(rb, "IsVisible")
            if visible then
                local ok, text = pcall(function() return rb:GetText():ToString() end)
                if ok and text and text ~= "" then
                    table.insert(lines, "RTB \"" .. text .. "\"")
                    table.insert(lines, "   " .. rb:GetFullName())
                    textCount = textCount + 1
                end
            end
        end
    end
    table.insert(lines, "(" .. textCount .. " text elements)")
    table.insert(lines, "")

    return table.concat(lines, "\n")
end

local _dumpTask = nil

local function StartDumpLoop()
    _dumpActive = true
    _lastDumpFocus = nil
    _lastDumpClassKey = nil

    AppendDump("debug_dump.txt", "\n=== Dump Started " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n\n")

    -- A quick off/on toggle must not leave two dump loops running
    GT.Cancel(_dumpTask)
    _dumpTask = GT.Every("DebugDump", 250, function()
        if not _dumpActive then return true end  -- stop loop
        local ok, entry = pcall(BuildDumpEntry)
        if ok and entry then
            AppendDump("debug_dump.txt", entry)
        end
        return false  -- continue loop
    end)
end

local function StopDumpLoop()
    _dumpActive = false
    AppendDump("debug_dump.txt", "=== Dump Stopped " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
end

-- === F4: CHARA SELECT — TEXTURE ID + DATATABLE SEARCH ===

local function DumpCharaSelectInfo()
    local lines = {}
    table.insert(lines, "=== Character Select: Texture IDs + DataTable Search ===")
    table.insert(lines, "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"))
    table.insert(lines, "")

    -- === 1. Read IMG_Face_Main texture per team slot (compact) ===
    table.insert(lines, "--- Team Slot Textures (1P, IMG_Face_Main) ---")
    local images = FindAllOf("Image")
    if images then
        for slotIdx = 0, 4 do
            local iconName = "WBP_OBJ_BS_CharaIcon_" .. slotIdx
            local found = false
            for _, img in ipairs(images) do
                local ok, imgPath = pcall(function() return img:GetFullName() end)
                if ok and imgPath:find(iconName, 1, true)
                   and imgPath:find("Top_00_1P", 1, true)
                   and imgPath:find("Transient", 1, true) then
                    local imgWidgetName = GetWidgetName(img)
                    if imgWidgetName == "IMG_Face_Main" then
                        found = true
                        -- Try Brush.ResourceObject
                        local texInfo = "(no texture)"
                        local brushKeys = {"Brush", "brush"}
                        for _, bk in ipairs(brushKeys) do
                            local ok2, texName = pcall(function()
                                local brush = img[bk]
                                if not brush then return nil end
                                local res = brush.ResourceObject
                                if not res then return nil end
                                return res:GetFullName()
                            end)
                            if ok2 and texName then
                                texInfo = texName
                                break
                            end
                        end
                        table.insert(lines, "Slot " .. (slotIdx+1) .. ": " .. texInfo)
                        break
                    end
                end
            end
            if not found then
                table.insert(lines, "Slot " .. (slotIdx+1) .. ": (IMG_Face_Main not found)")
            end
        end
    else
        table.insert(lines, "(no Image widgets found)")
    end
    WriteDump("chara_select.txt", table.concat(lines, "\n"))

    -- === 2. DataTable search — find character data tables ===
    table.insert(lines, "")
    table.insert(lines, "--- DataTable Search ---")
    local dtClasses = {"DataTable", "UDataTable"}
    for _, dtClass in ipairs(dtClasses) do
        local dts = FindAllOf(dtClass)
        if dts then
            table.insert(lines, dtClass .. " instances: " .. #dts)
            for _, dt in ipairs(dts) do
                local ok, dtPath = pcall(function() return dt:GetFullName() end)
                if ok then
                    -- Log ALL data tables, filter for interesting ones
                    local isChara = dtPath:find("Chara", 1, true)
                        or dtPath:find("chara", 1, true)
                        or dtPath:find("Character", 1, true)
                        or dtPath:find("Battle", 1, true)
                        or dtPath:find("Param", 1, true)
                        or dtPath:find("Name", 1, true)
                        or dtPath:find("Icon", 1, true)
                        or dtPath:find("Thumb", 1, true)
                        or dtPath:find("ID", 1, true)
                    if isChara then
                        table.insert(lines, "  [MATCH] " .. dtPath)
                    end
                end
            end
            -- Also log first 20 paths regardless of filter
            table.insert(lines, "")
            table.insert(lines, "  First 50 DataTable paths:")
            local count = 0
            for _, dt in ipairs(dts) do
                if count >= 50 then break end
                local ok, dtPath = pcall(function() return dt:GetFullName() end)
                if ok then
                    table.insert(lines, "  " .. dtPath)
                    count = count + 1
                end
            end
            if #dts > 50 then
                table.insert(lines, "  ... and " .. (#dts - 50) .. " more")
            end
        else
            table.insert(lines, dtClass .. ": not found")
        end
    end
    WriteDump("chara_select.txt", table.concat(lines, "\n"))

    -- === 3. Inspect SSCharacterDataAsset properties ===
    table.insert(lines, "")
    table.insert(lines, "--- SSCharacterDataAsset Deep Inspect (first 3) ---")
    local charaAssets = FindAllOf("SSCharacterDataAsset")
    if charaAssets then
        table.insert(lines, "Total: " .. #charaAssets)
        -- Inspect first 3 assets to find readable properties
        for i = 1, math.min(3, #charaAssets) do
            local asset = charaAssets[i]
            local ok, assetPath = pcall(function() return asset:GetFullName() end)
            if ok then
                table.insert(lines, "")
                table.insert(lines, "[" .. i .. "] " .. assetPath)
                -- Try common name/ID properties
                local nameProps = {
                    "CharacterName", "CharaName", "DisplayName", "Name",
                    "CharacterID", "CharaID", "ID", "CharaId",
                    "NameText", "NameLabel", "Label",
                    "ShortName", "FullName_", "Title",
                    "ThumbnailID", "ThumbID", "IconID",
                    "BattleName", "SelectName",
                    "DP", "DPCost", "Cost",
                }
                for _, prop in ipairs(nameProps) do
                    local ok2, val = pcall(function() return asset[prop] end)
                    if ok2 and val ~= nil then
                        local info = "type=" .. type(val) .. " tostring=" .. tostring(val)
                        -- Try ToString
                        local ok3, s3 = pcall(function() return val:ToString() end)
                        if ok3 and s3 then info = info .. " ToString=\"" .. s3 .. "\"" end
                        -- Try GetText
                        local ok4, s4 = pcall(function() return val:GetText():ToString() end)
                        if ok4 and s4 then info = info .. " GetText=\"" .. s4 .. "\"" end
                        -- Try GetFullName
                        local ok5, s5 = pcall(function() return val:GetFullName() end)
                        if ok5 and s5 then info = info .. " FullName=" .. s5 end
                        -- Check if it's a number
                        if type(val) == "number" then info = "number=" .. val end
                        if type(val) == "string" then info = "string=\"" .. val .. "\"" end
                        if type(val) == "boolean" then info = "bool=" .. tostring(val) end
                        table.insert(lines, "  " .. prop .. " = " .. info)
                    end
                end
            end
        end

        -- === 4. List ALL SSCharacterDataAsset paths (for ID mapping) ===
        table.insert(lines, "")
        table.insert(lines, "--- ALL SSCharacterDataAsset paths ---")
        for _, asset in ipairs(charaAssets) do
            local ok, path = pcall(function() return asset:GetFullName() end)
            if ok then
                -- Extract just the asset name
                local assetName = path:match("([^%.]+)$") or path
                table.insert(lines, assetName)
            end
        end
    else
        table.insert(lines, "SSCharacterDataAsset: not found")
    end

    -- === 5. Look for assets matching our texture IDs ===
    table.insert(lines, "")
    table.insert(lines, "--- StaticFindObject: texture ID probes ---")
    local probeIds = {"0000_00", "0000_10", "0020_00", "0030_00", "0050_00"}
    for _, cid in ipairs(probeIds) do
        local probePaths = {
            "/Game/SS/MasterDataAsset/CharacterData/CharacterData_" .. cid,
            "/Game/SS/MasterDataAsset/CharacterData/CharacterData_" .. cid .. ".CharacterData_" .. cid,
        }
        for _, path in ipairs(probePaths) do
            local ok, obj = pcall(function() return StaticFindObject(path) end)
            if ok and obj then
                table.insert(lines, "FOUND: " .. path)
                -- Try reading name from it
                local nameProps2 = {"CharacterName", "CharaName", "DisplayName", "Name"}
                for _, np in ipairs(nameProps2) do
                    local ok2, val = pcall(function() return obj[np] end)
                    if ok2 and val then
                        local ok3, s = pcall(function() return val:ToString() end)
                        if ok3 and s then
                            table.insert(lines, "  " .. np .. " = \"" .. s .. "\"")
                        end
                    end
                end
            end
        end
    end

    WriteDump("chara_select.txt", table.concat(lines, "\n"))

    -- === 6. DP VALUE PROBE ===
    -- Search for any TextBlock/RichTextBlock with numeric content in the 1P panel
    -- Also check Img_DPNum material parameters for numeric values
    table.insert(lines, "")
    table.insert(lines, "--- DP Value Probe ---")

    -- 6a. ALL TextBlocks inside Top_00_1P (not just visible — hidden ones might have DP)
    table.insert(lines, "All TextBlocks in Top_00_1P:")
    local allTB = FindAllOf("TextBlock")
    if allTB then
        for _, tb in ipairs(allTB) do
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find("Top_00_1P", 1, true) and tbPath:find("Transient", 1, true) then
                local tbName = GetWidgetName(tb)
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                local vis = TryCall(tb, "IsVisible")
                local textStr = (ok2 and text) or "(error)"
                table.insert(lines, "  " .. tbName .. " = \"" .. textStr .. "\" visible=" .. tostring(vis))
            end
        end
    end

    -- 6b. Check Img_DPNum MaterialInstanceDynamic for scalar/vector parameters
    table.insert(lines, "")
    table.insert(lines, "Img_DPNum material parameter probe (CharaIcon_0 and _1):")
    local mats = FindAllOf("MaterialInstanceDynamic")
    if mats then
        for _, mat in ipairs(mats) do
            local ok, matPath = pcall(function() return mat:GetFullName() end)
            if ok and matPath:find("Img_DPNum", 1, true)
               and matPath:find("Top_00_1P", 1, true) then
                table.insert(lines, "  " .. matPath)
                -- Try reading scalar parameters
                local scalarNames = {"Value", "Number", "DP", "Num", "Digit",
                    "Param", "Amount", "Count", "DPValue", "NumValue",
                    "Hundreds", "Tens", "Ones", "Digit0", "Digit1", "Digit2"}
                for _, sn in ipairs(scalarNames) do
                    local ok2, val = pcall(function() return mat[sn] end)
                    if ok2 and val ~= nil then
                        local info = "type=" .. type(val)
                        if type(val) == "number" then info = info .. " value=" .. val end
                        if type(val) == "boolean" then info = info .. " value=" .. tostring(val) end
                        local ok3, s = pcall(function() return val:ToString() end)
                        if ok3 and s then info = info .. " ToString=\"" .. s .. "\"" end
                        table.insert(lines, "    " .. sn .. " = " .. info)
                    end
                end
            end
        end
    end

    -- 6c. Search for ANY widget class with "DP" in name
    table.insert(lines, "")
    table.insert(lines, "Widget classes containing 'DP' in Top_00_1P:")
    local allWidgets = FindAllOf("UserWidget")
    if allWidgets then
        for _, w in ipairs(allWidgets) do
            local ok, wPath = pcall(function() return w:GetFullName() end)
            if ok and wPath:find("Top_00_1P", 1, true) and wPath:find("Transient", 1, true) then
                local wName = GetWidgetName(w)
                if wName:find("DP", 1, true) or wName:find("dp", 1, true) then
                    table.insert(lines, "  " .. GetClassName(w) .. " : " .. wName)
                    table.insert(lines, "    " .. wPath)
                end
            end
        end
    end

    -- 6d. Check the BtnSet panel for DP-related text (Total DP values)
    table.insert(lines, "")
    table.insert(lines, "All TextBlocks in Top_00_BtnSet:")
    if allTB then
        for _, tb in ipairs(allTB) do
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find("BtnSet", 1, true) and tbPath:find("Transient", 1, true) then
                local tbName = GetWidgetName(tb)
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                local textStr = (ok2 and text) or "(error)"
                table.insert(lines, "  " .. tbName .. " = \"" .. textStr .. "\"")
            end
        end
    end

    -- 6e. Search ALL visible TextBlocks for anything that looks like a number (DP value)
    table.insert(lines, "")
    table.insert(lines, "All TextBlocks with numeric content (possible DP values):")
    if allTB then
        for _, tb in ipairs(allTB) do
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find("Transient", 1, true)
               and not tbPath:find("Debug", 1, true)
               and not tbPath:find("Notification", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text:match("^%d+$") then
                    local tbName = GetWidgetName(tb)
                    table.insert(lines, "  " .. tbName .. " = \"" .. text .. "\" path=" .. tbPath)
                end
            end
        end
    end

    -- === 7. SSCharacterDataAsset DP extraction attempts ===
    table.insert(lines, "")
    table.insert(lines, "--- SSCharacterDataAsset DP Extraction (3 known characters) ---")
    -- Try multiple UE4SS APIs to read properties from known character data assets
    local testIds = {"0000_00", "0920_01", "0030_00"} -- Goku Z-Early, Kefla SSJ, Gohan Kid
    for _, cid in ipairs(testIds) do
        local assetPath = "/Game/SS/MasterDataAsset/CharacterData/CharacterData_" .. cid .. ".CharacterData_" .. cid
        local ok, asset = pcall(function() return StaticFindObject(assetPath) end)
        if ok and asset then
            table.insert(lines, "")
            table.insert(lines, "CharacterData_" .. cid .. ":")

            -- Method 1: Iterate reflected properties using ForEachProperty (if available)
            local ok1, err1 = pcall(function()
                local propCount = 0
                asset:ForEachProperty(function(prop)
                    propCount = propCount + 1
                    local propName = prop:GetFName():ToString()
                    local propType = prop:GetClass():GetFName():ToString()
                    local entry = "  [prop] " .. propName .. " type=" .. propType

                    -- Try to read value based on type
                    if propType == "IntProperty" or propType == "Int32Property"
                       or propType == "FloatProperty" or propType == "DoubleProperty" then
                        local ok2, val = pcall(function()
                            return prop:ContainerPtrToValuePtr(asset):get()
                        end)
                        if ok2 then entry = entry .. " value=" .. tostring(val) end
                    elseif propType == "StrProperty" or propType == "NameProperty" then
                        local ok2, val = pcall(function()
                            return prop:ContainerPtrToValuePtr(asset):get():ToString()
                        end)
                        if ok2 and val then entry = entry .. " value=\"" .. val .. "\"" end
                    elseif propType == "TextProperty" then
                        local ok2, val = pcall(function()
                            return prop:ContainerPtrToValuePtr(asset):get():ToString()
                        end)
                        if ok2 and val then entry = entry .. " value=\"" .. val .. "\"" end
                    end

                    table.insert(lines, entry)
                end)
                table.insert(lines, "  Total properties: " .. propCount)
            end)
            if not ok1 then
                table.insert(lines, "  ForEachProperty failed: " .. tostring(err1))
            end

            -- Method 2: Try GetPropertyValue (UE4SS custom API)
            local dpProps = {"DP", "DPCost", "Cost", "BattlePoint", "Point",
                "CharacterName", "ID", "CharaID"}
            for _, dp in ipairs(dpProps) do
                -- Try :GetPropertyValue(name)
                local ok3, val3 = pcall(function()
                    return asset:GetPropertyValue(dp)
                end)
                if ok3 and val3 ~= nil then
                    local info = "type=" .. type(val3)
                    if type(val3) == "number" then info = info .. " value=" .. val3 end
                    if type(val3) == "string" then info = info .. " value=\"" .. val3 .. "\"" end
                    if type(val3) == "boolean" then info = info .. " value=" .. tostring(val3) end
                    local ok4, s = pcall(function() return val3:ToString() end)
                    if ok4 and s then info = info .. " ToString=\"" .. s .. "\"" end
                    table.insert(lines, "  GetPropertyValue(\"" .. dp .. "\") = " .. info)
                end

                -- Try :GetKismetPropertyValue(name)
                local ok5, val5 = pcall(function()
                    return asset:GetKismetPropertyValue(dp)
                end)
                if ok5 and val5 ~= nil then
                    local info = "type=" .. type(val5)
                    if type(val5) == "number" then info = info .. " value=" .. val5 end
                    if type(val5) == "string" then info = info .. " value=\"" .. val5 .. "\"" end
                    table.insert(lines, "  GetKismetPropertyValue(\"" .. dp .. "\") = " .. info)
                end
            end

            -- Method 3: Try member function approach
            local ok6, val6 = pcall(function()
                return asset:GetDP()
            end)
            if ok6 and val6 then
                table.insert(lines, "  GetDP() = " .. tostring(val6))
            end
            local ok7, val7 = pcall(function()
                return asset:GetDPCost()
            end)
            if ok7 and val7 then
                table.insert(lines, "  GetDPCost() = " .. tostring(val7))
            end
        else
            table.insert(lines, "CharacterData_" .. cid .. ": not found")
        end
    end

    WriteDump("chara_select.txt", table.concat(lines, "\n"))
end

-- === F3: BATTLE HUD — HP & KI GAUGE EXPLORATION (appends) ===

local function ProbeProperties(obj, propNames)
    local results = {}
    for _, prop in ipairs(propNames) do
        local ok, val = pcall(function() return obj[prop] end)
        if ok and val ~= nil then
            local display = tostring(val)
            -- Try to get numeric value
            if type(val) == "userdata" then
                -- Try common value accessors
                for _, method in ipairs({"GetValue", "GetCurrentValue", "GetPercent",
                    "GetFillPercent", "ToString", "GetFloat", "GetInt"}) do
                    local mok, mval = pcall(function()
                        local fn = val[method]
                        if fn then return fn(val) end
                        return nil
                    end)
                    if mok and mval ~= nil then
                        display = display .. " -> " .. method .. "()=" .. tostring(mval)
                    end
                end
                -- Try GetFullName for UObject identification
                local nok, fname = pcall(function() return val:GetFullName() end)
                if nok and fname then
                    display = display .. " [" .. fname:sub(1, 120) .. "]"
                end
            end
            table.insert(results, "  " .. prop .. " = " .. display)
        end
    end
    return results
end

local function DumpBattleGauges()
    local lines = {}
    table.insert(lines, "--- Battle Gauge Snapshot " .. os.date("%Y-%m-%d %H:%M:%S") .. " ---")

    -- Common gauge property names to probe
    local gaugeProps = {
        "Percent", "percent", "FillPercent", "fillPercent",
        "CurrentValue", "currentValue", "Value", "value",
        "MaxValue", "maxValue", "MinValue",
        "CurrentHP", "currentHP", "HP", "hp", "Health", "health",
        "MaxHP", "maxHP",
        "Ratio", "ratio", "Rate", "rate",
        "GaugePercent", "gaugePercent",
        "BarPercent", "barPercent",
        "FillAmount", "fillAmount",
        "Progress", "progress",
        "CurrentKi", "Ki", "ki", "Energy", "energy",
        "SpGauge", "spGauge", "SpecialGauge",
        "StockNum", "stockNum", "StockCount",
        "CharaNum", "charaNum",
        "bIsActive", "bIsVisible",
        "Gauge", "gauge", "GaugeValue",
        "Material", "DynamicMaterial",
        "Img_Gauge", "IMG_Gauge", "img_gauge",
        "Img_GaugeColor", "IMG_GaugeColor",
        "GaugeImage", "gaugeImage",
        "ProgressBar", "progressBar",
    }

    -- === HP GAUGES ===
    for _, playerTag in ipairs({"P1", "P2"}) do
        local className = "WBP_OBJ_HpGauge_" .. playerTag .. "_C"
        table.insert(lines, "")
        table.insert(lines, "=== " .. className .. " ===")
        local widget = FindFirstOf(className)
        if widget then
            local ok, path = pcall(function() return widget:GetFullName() end)
            if ok then table.insert(lines, "Path: " .. path) end

            local props = ProbeProperties(widget, gaugeProps)
            if #props > 0 then
                for _, p in ipairs(props) do table.insert(lines, p) end
            else
                table.insert(lines, "  (no matching properties found)")
            end

            -- Try to get children
            local cok, childCount = pcall(function() return widget:GetChildrenCount() end)
            if cok and childCount and childCount > 0 then
                table.insert(lines, "  Children: " .. childCount)
                for i = 0, math.min(childCount - 1, 15) do
                    local child = TryCall(widget, "GetChildAt", i)
                    if child then
                        local cn = GetClassName(child)
                        local cname = GetWidgetName(child)
                        local entry = "    [" .. i .. "] " .. cn .. " : " .. cname
                        -- Probe child for gauge values too
                        local childProps = ProbeProperties(child, gaugeProps)
                        for _, cp in ipairs(childProps) do
                            entry = entry .. "\n      " .. cp:sub(3)
                        end
                        table.insert(lines, entry)
                    end
                end
            end
        else
            table.insert(lines, "  (not found)")
        end
    end

    -- === HP STOCK ===
    table.insert(lines, "")
    table.insert(lines, "=== HP Stock (WBP_Rep_HpStock_C) ===")
    local hpStocks = FindAllOf("WBP_Rep_HpStock_C")
    if hpStocks then
        local count = 0
        for _, stock in ipairs(hpStocks) do
            local ok, path = pcall(function() return stock:GetFullName() end)
            if ok and path:find("Transient", 1, true) then
                local visible = TryCall(stock, "IsVisible")
                local name = GetWidgetName(stock)
                local opacity = TryCall(stock, "GetRenderOpacity")
                table.insert(lines, "  " .. name .. " visible=" .. tostring(visible) .. " opacity=" .. tostring(opacity))
                count = count + 1
                if count >= 14 then break end
            end
        end
    else
        table.insert(lines, "  (not found)")
    end

    -- === KI / SPECIAL GAUGE ===
    for _, playerTag in ipairs({"P1", "P2"}) do
        local className = "WBP_GRP_SpGauge_" .. playerTag .. "_C"
        table.insert(lines, "")
        table.insert(lines, "=== " .. className .. " ===")
        local widget = FindFirstOf(className)
        if widget then
            local ok, path = pcall(function() return widget:GetFullName() end)
            if ok then table.insert(lines, "Path: " .. path) end

            local props = ProbeProperties(widget, gaugeProps)
            if #props > 0 then
                for _, p in ipairs(props) do table.insert(lines, p) end
            else
                table.insert(lines, "  (no matching properties found)")
            end

            -- Children
            local cok, childCount = pcall(function() return widget:GetChildrenCount() end)
            if cok and childCount and childCount > 0 then
                table.insert(lines, "  Children: " .. childCount)
                for i = 0, math.min(childCount - 1, 15) do
                    local child = TryCall(widget, "GetChildAt", i)
                    if child then
                        local cn = GetClassName(child)
                        local cname = GetWidgetName(child)
                        local entry = "    [" .. i .. "] " .. cn .. " : " .. cname
                        local childProps = ProbeProperties(child, gaugeProps)
                        for _, cp in ipairs(childProps) do
                            entry = entry .. "\n      " .. cp:sub(3)
                        end
                        table.insert(lines, entry)
                    end
                end
            end
        else
            table.insert(lines, "  (not found)")
        end
    end

    -- === KI GAUGE PARTS (individual segments) ===
    table.insert(lines, "")
    table.insert(lines, "=== SpGaugeParts (WBP_OBJ_SpGaugePartsSet_C) ===")
    local kiParts = FindAllOf("WBP_OBJ_SpGaugePartsSet_C")
    if kiParts then
        local count = 0
        for _, part in ipairs(kiParts) do
            local ok, path = pcall(function() return part:GetFullName() end)
            if ok and path:find("Transient", 1, true) then
                local name = GetWidgetName(part)
                local visible = TryCall(part, "IsVisible")
                local opacity = TryCall(part, "GetRenderOpacity")
                local entry = "  " .. name .. " visible=" .. tostring(visible) .. " opacity=" .. tostring(opacity)
                -- Probe each part
                local partProps = ProbeProperties(part, gaugeProps)
                for _, pp in ipairs(partProps) do
                    entry = entry .. "\n    " .. pp:sub(3)
                end
                table.insert(lines, entry)
                count = count + 1
                if count >= 10 then break end
            end
        end
    else
        table.insert(lines, "  (not found)")
    end

    -- === KING GAUGE (burst gauge) ===
    for _, playerTag in ipairs({"P1", "P2"}) do
        local className = "WBP_OBJ_KingGauge_" .. playerTag .. "_C"
        local widget = FindFirstOf(className)
        if widget then
            table.insert(lines, "")
            table.insert(lines, "=== " .. className .. " ===")
            local props = ProbeProperties(widget, gaugeProps)
            if #props > 0 then
                for _, p in ipairs(props) do table.insert(lines, p) end
            else
                table.insert(lines, "  (no matching properties found)")
            end
        end
    end

    -- === CHARACTER STOCK NUMBERS ===
    table.insert(lines, "")
    table.insert(lines, "=== Character Stock Numbers ===")
    local textBlocks = FindAllOf("TextBlock")
    if textBlocks then
        for _, tb in ipairs(textBlocks) do
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find("StyleIcon_Timer", 1, true) and tbPath:find("Transient", 1, true) then
                local name = GetWidgetName(tb)
                if name == "CharaNum" then
                    local ok2, text = pcall(function() return tb:GetText():ToString() end)
                    local player = tbPath:find("_P1_") and "P1" or "P2"
                    table.insert(lines, "  " .. player .. " CharaNum = " .. (ok2 and text or "?"))
                end
            end
        end
    end

    table.insert(lines, "")
    AppendDump("battle_gauges.txt", table.concat(lines, "\n") .. "\n")
end

-- === F2: BATTLE GAME STATE — HP/KI FROM GAME LOGIC (appends) ===

local function ProbeObject(obj, label, propNames)
    local lines = {}
    table.insert(lines, label)
    local ok, path = pcall(function() return obj:GetFullName() end)
    if ok then table.insert(lines, "  Path: " .. path) end
    local cls = GetClassName(obj)
    table.insert(lines, "  Class: " .. cls)

    for _, prop in ipairs(propNames) do
        local pok, val = pcall(function() return obj[prop] end)
        if pok and val ~= nil then
            local display = tostring(val)
            if type(val) == "number" then
                display = tostring(val)
            elseif type(val) == "boolean" then
                display = tostring(val)
            elseif type(val) == "userdata" then
                -- Try numeric conversions
                for _, method in ipairs({"GetFloat", "GetInt", "GetValue", "ToString"}) do
                    local mok, mval = pcall(function()
                        local fn = val[method]
                        if fn then return fn(val) end
                        return nil
                    end)
                    if mok and mval ~= nil then
                        display = display .. " -> " .. method .. "()=" .. tostring(mval)
                    end
                end
                -- Try GetFullName for identification
                local nok, fname = pcall(function() return val:GetFullName() end)
                if nok and fname then
                    display = display .. " [" .. fname:sub(1, 100) .. "]"
                end
            end
            table.insert(lines, "  " .. prop .. " = " .. display)
        end
    end
    return lines
end

-- === OBJECT DUMPER (from ConsoleCommandsMod/dump_object.lua) ===

local UClassStaticClass = StaticFindObject("/Script/CoreUObject.Class")
local UScriptStructStaticClass = StaticFindObject("/Script/CoreUObject.ScriptStruct")

local function SafeIsA(Property, TypeKey)
    if not TypeKey then return false end
    local ok, result = pcall(function() return Property:IsA(TypeKey) end)
    return ok and result
end

local function DumpPropertyWithinObject(Object, Property)
    local PropName = Property:GetFName():ToString()
    local ValueStr = ""

    -- Try type-specific reading
    if SafeIsA(Property, PropertyTypes.Int8Property) or SafeIsA(Property, PropertyTypes.Int16Property)
       or SafeIsA(Property, PropertyTypes.IntProperty) or SafeIsA(Property, PropertyTypes.Int64Property)
       or SafeIsA(Property, PropertyTypes.ByteProperty) then
        local ok, Value = pcall(function() return Object[PropName] end)
        ValueStr = ok and string.format("%s", Value) or "?"
    elseif SafeIsA(Property, PropertyTypes.FloatProperty) or SafeIsA(Property, PropertyTypes.DoubleProperty) then
        local ok, Value = pcall(function() return Object[PropName] end)
        ValueStr = ok and string.format("%s", Value) or "?"
    elseif SafeIsA(Property, PropertyTypes.BoolProperty) then
        local ok, Value = pcall(function() return Object[PropName] end)
        ValueStr = ok and (Value and "True" or "False") or "?"
    elseif SafeIsA(Property, PropertyTypes.NameProperty) or SafeIsA(Property, PropertyTypes.StrProperty)
        or SafeIsA(Property, PropertyTypes.TextProperty) then
        local ok, Value = pcall(function() return Object[PropName]:ToString() end)
        ValueStr = ok and Value or "?"
    elseif SafeIsA(Property, PropertyTypes.EnumProperty) then
        local ok, Value = pcall(function()
            local v = Object[PropName]
            return string.format("%s(%s)", Property:GetEnum():GetNameByValue(v):ToString(), v)
        end)
        ValueStr = ok and Value or "?"
    elseif SafeIsA(Property, PropertyTypes.ObjectProperty) then
        local ok, Value = pcall(function() return Object[PropName]:GetFullName() end)
        ValueStr = ok and Value:sub(1, 120) or "?"
    elseif SafeIsA(Property, PropertyTypes.StructProperty) then
        local ok, Value = pcall(function() return Object[PropName]:GetFullName() end)
        ValueStr = ok and Value:sub(1, 120) or "(struct)"
    elseif SafeIsA(Property, PropertyTypes.ArrayProperty) then
        local ok, Value = pcall(function()
            local arr = Object[PropName]
            return string.format("Array[%d]", arr:GetArrayNum())
        end)
        ValueStr = ok and Value or "Array[?]"
    else
        -- Fallback: try raw read for unhandled types (DoubleProperty, etc.)
        local ok, Value = pcall(function() return Object[PropName] end)
        if ok and Value ~= nil then
            if type(Value) == "number" or type(Value) == "boolean" then
                ValueStr = tostring(Value)
            elseif type(Value) == "string" then
                ValueStr = Value
            else
                local fnOk, fn = pcall(function() return Value:GetFullName() end)
                ValueStr = fnOk and fn:sub(1, 80) or tostring(Value)
            end
        else
            ValueStr = "?"
        end
    end

    local offset = 0
    pcall(function() offset = Property:GetOffset_Internal() end)
    local typeName = "?"
    pcall(function() typeName = Property:GetClass():GetFName():ToString() end)
    return string.format("0x%04X %s %s = %s", offset, typeName, PropName, ValueStr)
end

local function DumpObjectToLines(Object, lines)
    local clsOk, ObjectClass = pcall(function() return Object:GetClass() end)
    if not clsOk or not ObjectClass then
        table.insert(lines, "  (could not get class)")
        return
    end
    while ObjectClass and ObjectClass:IsValid() do
        local nameOk, clsName = pcall(function() return ObjectClass:GetFullName() end)
        table.insert(lines, string.format("=== %s ===", nameOk and clsName or "?"))
        pcall(function()
            ObjectClass:ForEachProperty(function(Property)
                local ok, line = pcall(DumpPropertyWithinObject, Object, Property)
                if ok and type(line) == "string" then
                    table.insert(lines, "  " .. line)
                else
                    -- Still show name, type, and offset for errored properties
                    local pname = "?"
                    local ptype = "?"
                    local poffset = "????"
                    pcall(function() pname = Property:GetFName():ToString() end)
                    pcall(function() ptype = Property:GetClass():GetFName():ToString() end)
                    pcall(function() poffset = string.format("0x%04X", Property:GetOffset_Internal()) end)
                    table.insert(lines, "  " .. poffset .. " " .. ptype .. " " .. pname .. " = (error)")
                end
            end)
        end)
        local superOk, super = pcall(function() return ObjectClass:GetSuperStruct() end)
        if superOk and super and super:IsValid() then
            ObjectClass = super
        else
            break
        end
    end
end

local function DumpBattleGameState()
    local lines = {}
    table.insert(lines, "--- Battle Game State " .. os.date("%Y-%m-%d %H:%M:%S") .. " ---")

    -- Get player's active pawn
    local pc = FindFirstOf("BP_BattlePlayerController_C")
    if not pc then
        table.insert(lines, "(not in battle)")
        AppendDump("battle_state.txt", table.concat(lines, "\n") .. "\n")
        return
    end

    local pawn = pc.Pawn
    local pawnPath = "(none)"
    pcall(function() pawnPath = pawn:GetFullName() end)
    table.insert(lines, "Player Pawn: " .. pawnPath)
    table.insert(lines, "")

    -- Full dump of player pawn (entire class hierarchy)
    DumpObjectToLines(pawn, lines)

    -- Dump game state (for timer, round info, etc.)
    table.insert(lines, "")
    table.insert(lines, "=== Battle Game State Object ===")
    local gsOk, gs = pcall(FindFirstOf, "BP_BattleGameStateBase_C")
    if gsOk and gs then
        local gsPath = "?"
        pcall(function() gsPath = gs:GetFullName() end)
        table.insert(lines, "Path: " .. gsPath)
        pcall(DumpObjectToLines, gs, lines)
    else
        table.insert(lines, "  (not found)")
    end

    -- Pawn summary
    table.insert(lines, "")
    table.insert(lines, "=== All Battle Pawns (summary) ===")
    local allPawns = FindAllOf("Pawn")
    if allPawns then
        for _, p in ipairs(allPawns) do
            local pok, path = pcall(function() return p:GetFullName() end)
            if pok and path and not path:find("/Script/") then
                local sgOk, sg = pcall(function() return p.SpGaugeValue end)
                local bsOk, bs = pcall(function() return p.BattleState end)
                local sgStr = sgOk and type(sg) == "number" and (" SpGauge=" .. sg) or ""
                local bsStr = bsOk and type(bs) == "number" and (" BattleState=" .. bs) or ""
                table.insert(lines, "  " .. path:sub(1, 100) .. sgStr .. bsStr)
            end
        end
    end

    -- Write main dump before attempting identification debug
    AppendDump("battle_state.txt", table.concat(lines, "\n") .. "\n")
    lines = {}

    -- === PAWN IDENTIFICATION DEBUG ===
    table.insert(lines, "=== Pawn Identification Debug ===")

    -- Safe name getter that never returns nil
    local function SafeName(obj)
        if not obj then return "nil" end
        local ok, name = pcall(function() return obj:GetFullName() end)
        if ok and name then return name:sub(1, 120) end
        return "?"
    end

    if allPawns then
        for _, p in ipairs(allPawns) do
            local path = SafeName(p)
            if path:find("BPCHR_") and not path:find("DESTROYED") then
                table.insert(lines, "")
                table.insert(lines, "--- " .. path .. " ---")

                -- UE networking properties
                local roleOk, role = pcall(function() return p.Role end)
                table.insert(lines, "  Role = " .. (roleOk and tostring(role) or "err"))
                local remOk, rem = pcall(function() return p.RemoteRole end)
                table.insert(lines, "  RemoteRole = " .. (remOk and tostring(rem) or "err"))

                -- UE methods
                local methods = {"IsLocallyControlled", "IsPlayerControlled", "HasAuthority", "IsLocallyViewed"}
                for _, m in ipairs(methods) do
                    local mok, mval = pcall(function() return p[m](p) end)
                    table.insert(lines, "  " .. m .. "() = " .. (mok and tostring(mval) or "err"))
                end

                -- Controller identity
                local cok, ctrl = pcall(function() return p.Controller end)
                if cok and ctrl then
                    table.insert(lines, "  Controller = " .. SafeName(ctrl))
                    local lcOk, lc = pcall(function() return ctrl.IsLocalController(ctrl) end)
                    table.insert(lines, "  Controller:IsLocalController() = " .. (lcOk and tostring(lc) or "err"))
                    local lpcOk, lpc = pcall(function() return ctrl.IsLocalPlayerController(ctrl) end)
                    table.insert(lines, "  Controller:IsLocalPlayerController() = " .. (lpcOk and tostring(lpc) or "err"))
                    table.insert(lines, "  Controller.Pawn = " .. SafeName(pcall(function() return ctrl.Pawn end) and ctrl.Pawn or nil))
                else
                    table.insert(lines, "  Controller = (none)")
                end

                -- PlayerState
                local psOk, ps = pcall(function() return p.PlayerState end)
                if psOk and ps then
                    table.insert(lines, "  PlayerState = " .. SafeName(ps))
                    local pidOk, pid = pcall(function() return ps.PlayerId end)
                    table.insert(lines, "  PlayerState.PlayerId = " .. (pidOk and tostring(pid) or "err"))
                    local compOk, comp = pcall(function() return ps.CompressedPing end)
                    table.insert(lines, "  PlayerState.CompressedPing = " .. (compOk and tostring(comp) or "err"))
                else
                    table.insert(lines, "  PlayerState = (none)")
                end

                -- TargetPawn
                local tpOk, tp = pcall(function() return p.TargetPawn end)
                table.insert(lines, "  TargetPawn = " .. SafeName(tpOk and tp or nil))

                -- Game-specific identification properties
                local idProps = {
                    "StartPlayerControllerID", "bIsLocalViewTarget",
                    "PlayerSide", "BattleSide", "SideIndex", "TeamIndex",
                    "PlayerIndex", "CharacterIndex", "OwnerIndex",
                    "bIsPlayer1", "bIsPlayer2", "bIsLocalPlayer",
                    "bIsMyCharacter", "bIsRemoteCharacter",
                    "ViewingController",
                }
                for _, prop in ipairs(idProps) do
                    local propOk, propVal = pcall(function() return p[prop] end)
                    if propOk and propVal ~= nil then
                        local display = tostring(propVal)
                        if type(propVal) == "userdata" then
                            display = SafeName(propVal)
                        end
                        table.insert(lines, "  " .. prop .. " = " .. display)
                    end
                end

                -- HP/KI for correlation
                local hpOk, hp = pcall(function() return p.HPGaugeValue end)
                local spOk, sp = pcall(function() return p.SPGaugeValue end)
                table.insert(lines, "  HPGaugeValue = " .. (hpOk and tostring(hp) or "err"))
                table.insert(lines, "  SPGaugeValue = " .. (spOk and tostring(sp) or "err"))
            end
        end
    end

    -- Write pawn identification before attempting controller debug
    AppendDump("battle_state.txt", table.concat(lines, "\n") .. "\n")
    lines = {}

    -- === ALL CONTROLLERS ===
    table.insert(lines, "=== All BP_BattlePlayerControllers ===")
    local allCtrls = FindAllOf("BP_BattlePlayerController_C")
    if allCtrls then
        for i, ctrl in ipairs(allCtrls) do
            table.insert(lines, "")
            table.insert(lines, "--- Controller " .. i .. ": " .. SafeName(ctrl) .. " ---")
            local lcOk, lc = pcall(function() return ctrl.IsLocalController(ctrl) end)
            table.insert(lines, "  IsLocalController() = " .. (lcOk and tostring(lc) or "err"))
            local lpcOk, lpc = pcall(function() return ctrl.IsLocalPlayerController(ctrl) end)
            table.insert(lines, "  IsLocalPlayerController() = " .. (lpcOk and tostring(lpc) or "err"))
            local cpOk, cpawn = pcall(function() return ctrl.Pawn end)
            table.insert(lines, "  Pawn = " .. SafeName(cpOk and cpawn or nil))
            local apOk, apawn = pcall(function() return ctrl.AcknowledgedPawn end)
            table.insert(lines, "  AcknowledgedPawn = " .. SafeName(apOk and apawn or nil))
            local vtOk, vt = pcall(function() return ctrl:GetViewTarget() end)
            table.insert(lines, "  GetViewTarget() = " .. SafeName(vtOk and vt or nil))
            local psOk2, ps2 = pcall(function() return ctrl.PlayerState end)
            table.insert(lines, "  PlayerState = " .. SafeName(psOk2 and ps2 or nil))
            local netOk, netMode = pcall(function() return ctrl.GetNetMode(ctrl) end)
            table.insert(lines, "  GetNetMode() = " .. (netOk and tostring(netMode) or "err"))
            local plOk, pl = pcall(function() return ctrl.Player end)
            table.insert(lines, "  Player = " .. SafeName(plOk and pl or nil))
        end
    else
        table.insert(lines, "  (none found)")
    end

    table.insert(lines, "")
    AppendDump("battle_state.txt", table.concat(lines, "\n") .. "\n")
end

-- === F6: STORY MAP STRUCTURE DUMP ===
-- Walks every visible top-level widget tree (map, popups, guide bar) and
-- records hierarchy, visibility, layout position, textures, and text.
-- Goal: find node positions, cleared/locked flags, connections, and the cursor.
-- Appends one entry per press so consecutive nodes can be compared.

local STORY_MAP_TREE_BUDGET = 20000  -- max widget lines per entry
local STORY_MAP_MAX_DEPTH = 25
local _storyMapEntryCount = 0
local _storyMapSeenClasses = {}  -- non-episode classes whose properties were already dumped

local VIS_NAMES = {
    [0] = "Visible", [1] = "Collapsed", [2] = "Hidden",
    [3] = "HitTestInvisible", [4] = "SelfHitTestInvisible",
}

local function Vec2Str(v)
    local ok, s = pcall(function() return string.format("%.1f,%.1f", v.X, v.Y) end)
    return ok and s or nil
end

local function SafeClassName(obj)
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and name or "?"
end

--- Visibility, slot position, render translation/opacity for one widget.
local function DescribeLayout(w)
    local parts = {}

    local vis = TryCall(w, "GetVisibility")
    if vis ~= nil then
        table.insert(parts, "vis=" .. (VIS_NAMES[vis] or tostring(vis)))
    end

    local slotOk, slot = pcall(function() return w.Slot end)
    if slotOk and slot and H.IsValidRef(slot) then
        local slotClass = SafeClassName(slot)
        if slotClass == "CanvasPanelSlot" then
            local pos = nil
            local pOk, p = pcall(function() return slot:GetPosition() end)
            if pOk and p then pos = Vec2Str(p) end
            if not pos then
                local oOk, o = pcall(function()
                    local off = slot.LayoutData.Offsets
                    return string.format("%.1f,%.1f", off.Left, off.Top)
                end)
                if oOk then pos = o end
            end
            table.insert(parts, "canvasPos=" .. (pos or "?"))
            local sOk, sz = pcall(function() return slot:GetSize() end)
            if sOk and sz then
                local s = Vec2Str(sz)
                if s then table.insert(parts, "size=" .. s) end
            end
        else
            table.insert(parts, "slot=" .. slotClass)
        end
    end

    local tOk, tr = pcall(function() return w.RenderTransform.Translation end)
    if tOk and tr then
        local s = Vec2Str(tr)
        if s and s ~= "0.0,0.0" then table.insert(parts, "renderT=" .. s) end
    end

    local opacity = TryCall(w, "GetRenderOpacity")
    if type(opacity) == "number" and opacity < 0.999 then
        table.insert(parts, string.format("opacity=%.2f", opacity))
    end

    -- Active page of switchers (children all report visible otherwise)
    local active = TryCall(w, "GetActiveWidgetIndex")
    if type(active) == "number" then
        table.insert(parts, "activeIndex=" .. active)
    end

    -- Game menu active flag (true while a popup/overlay is open)
    local isActive = TryGetProperty(w, "bIsActive")
    if type(isActive) == "boolean" then
        table.insert(parts, "bIsActive=" .. tostring(isActive))
    end

    return table.concat(parts, " ")
end

--- Text for TextBlock/RichTextBlock, texture name for Image.
local function DescribeContent(w, className)
    if className:find("TextBlock", 1, true) then
        local ok, text = pcall(function() return w:GetText():ToString() end)
        if ok and text and text ~= "" then
            return " text=\"" .. text:gsub("\n", "\\n") .. "\""
        end
    elseif className == "Image" then
        for _, bk in ipairs({"Brush", "brush"}) do
            local ok, texName = pcall(function()
                local res = w[bk].ResourceObject
                if not res then return nil end
                return res:GetFullName()
            end)
            if ok and texName then
                return " tex=" .. (texName:match("([^%.]+)$") or texName)
            end
        end
    end
    return ""
end

local function WalkWidgetTree(w, depth, lines, budget)
    if budget.n <= 0 then return end
    budget.n = budget.n - 1

    local className = SafeClassName(w)
    table.insert(lines, string.rep("  ", depth) .. className .. " " .. GetWidgetName(w)
        .. " [" .. DescribeLayout(w) .. "]" .. DescribeContent(w, className))

    if depth >= STORY_MAP_MAX_DEPTH then return end

    -- PanelWidget children (CanvasPanel, Overlay, Border, SizeBox, ...)
    local cOk, count = pcall(function() return w:GetChildrenCount() end)
    if cOk and type(count) == "number" then
        for i = 0, count - 1 do
            local okc, child = pcall(function() return w:GetChildAt(i) end)
            if okc and child and H.IsValidRef(child) then
                WalkWidgetTree(child, depth + 1, lines, budget)
            end
        end
        return
    end

    -- UserWidget: descend into its own widget tree
    local rOk, root = pcall(function() return w.WidgetTree.RootWidget end)
    if rOk and root and H.IsValidRef(root) then
        WalkWidgetTree(root, depth + 1, lines, budget)
    end
end

--- Blueprint/game-level properties only (stops at /Script/UMG base classes).
local function DumpOwnProperties(obj, lines)
    local clsOk, cls = pcall(function() return obj:GetClass() end)
    if not clsOk or not cls then
        table.insert(lines, "  (could not get class)")
        return
    end
    while cls and cls:IsValid() do
        local nameOk, clsName = pcall(function() return cls:GetFullName() end)
        if not nameOk or clsName:find("/Script/UMG.", 1, true)
           or clsName:find("/Script/Engine.", 1, true) then break end
        table.insert(lines, "=== " .. clsName .. " ===")
        pcall(function()
            cls:ForEachProperty(function(Property)
                local ok, line = pcall(DumpPropertyWithinObject, obj, Property)
                if ok and type(line) == "string" then
                    table.insert(lines, "  " .. line)
                end
            end)
        end)
        local superOk, super = pcall(function() return cls:GetSuperStruct() end)
        if superOk and super and super:IsValid() then
            cls = super
        else
            break
        end
    end
end

local function DumpStoryMap()
    local lines = {}
    _storyMapEntryCount = _storyMapEntryCount + 1
    table.insert(lines, "========== Story Map Entry " .. _storyMapEntryCount
        .. " [" .. os.date("%Y-%m-%d %H:%M:%S") .. "] ==========")

    local allWidgets = FindAllOf("UserWidget")
    if not allWidgets then
        table.insert(lines, "(no UserWidgets found)")
        AppendDump("story_map.txt", table.concat(lines, "\n") .. "\n\n")
        return 0
    end

    -- Collect all visible widgets, grouped by class. Roots are top-level
    -- widgets (not nested in another widget's WidgetTree), so popups and
    -- map widgets without the "_AI_" prefix are included too.
    local classes, classOrder, roots = {}, {}, {}
    local focusedName = "(none)"
    for _, w in ipairs(allWidgets) do
        local ok, fullName = pcall(function() return w:GetFullName() end)
        if ok and fullName:find("Transient", 1, true) and TryCall(w, "IsVisible") then
            local className = SafeClassName(w)
            if not classes[className] then
                classes[className] = {}
                table.insert(classOrder, className)
            end
            table.insert(classes[className], w)

            local name = GetWidgetName(w)
            if TryCall(w, "HasKeyboardFocus") then
                focusedName = className .. " " .. name
            end

            local path = fullName:match("^%S+%s+(.*)$") or fullName
            local prefix = path:sub(1, #path - #name)
            if not prefix:find("WidgetTree", 1, true) then
                table.insert(roots, w)
            end
        end
    end

    -- Current node title, for correlating entries with the player's position
    local title = "(none)"
    local textBlocks = FindAllOf("TextBlock")
    if textBlocks then
        for _, tb in ipairs(textBlocks) do
            if GetWidgetName(tb) == "Text_EventTitle" then
                local ok, text = pcall(function() return tb:GetText():ToString() end)
                if ok and text and text ~= "" then title = text end
            end
        end
    end
    table.insert(lines, "Text_EventTitle: " .. title)
    table.insert(lines, "Keyboard focus: " .. focusedName)
    table.insert(lines, "")

    table.insert(lines, "--- Visible classes ---")
    for _, className in ipairs(classOrder) do
        table.insert(lines, className .. " (" .. #classes[className] .. ")")
    end
    table.insert(lines, "")

    local budget = { n = STORY_MAP_TREE_BUDGET }
    for _, root in ipairs(roots) do
        local ok, fullName = pcall(function() return root:GetFullName() end)
        table.insert(lines, "--- Tree: " .. (ok and fullName or "?") .. " ---")
        local wOk, err = pcall(WalkWidgetTree, root, 0, lines, budget)
        if not wOk then
            table.insert(lines, "  (walk error: " .. tostring(err) .. ")")
        end
        table.insert(lines, "")
    end
    if budget.n <= 0 then
        table.insert(lines, "(tree budget exhausted, output truncated)")
    end

    -- Properties of the first instance of each game widget class. Episode
    -- classes ("_AI_") every press, since values like the selected node may
    -- change; other classes once per session to keep the file readable.
    for _, className in ipairs(classOrder) do
        local isEpisode = className:find("_AI_", 1, true) ~= nil
        if className:find("^WBP_") and (isEpisode or not _storyMapSeenClasses[className]) then
            _storyMapSeenClasses[className] = true
            table.insert(lines, "--- Properties: " .. className .. " (first instance) ---")
            local ok, err = pcall(DumpOwnProperties, classes[className][1], lines)
            if not ok then
                table.insert(lines, "  (property error: " .. tostring(err) .. ")")
            end
            table.insert(lines, "")
        end
    end

    AppendDump("story_map.txt", table.concat(lines, "\n") .. "\n\n")
    print("[AE-DBG] Story map entry " .. _storyMapEntryCount .. ": " .. #roots .. " roots, "
        .. (STORY_MAP_TREE_BUDGET - budget.n) .. " widgets")
    return #roots
end

-- === CHART ACTORS (saved on first F6 press on the story map) ===
-- The 3D story map nodes are level actors (Map800_Chart_* level instance),
-- not widgets. Lists every matching actor with location, plus the game-level
-- properties of the first instance of each class.

local _chartActorsDumped = false

local function DumpChartActors()
    local lines = { "===== Chart actors " .. os.date("%Y-%m-%d %H:%M:%S") .. " =====" }
    local ok, actors = pcall(FindAllOf, "Actor")
    if not ok or not actors then
        table.insert(lines, "(FindAllOf Actor returned nothing)")
        WriteDump("chart_actors.txt", table.concat(lines, "\n") .. "\n")
        return 0
    end

    local classes, order, total = {}, {}, 0
    for _, actor in ipairs(actors) do
        local nOk, full = pcall(function() return actor:GetFullName() end)
        if nOk and not full:find("Default__", 1, true)
           and (full:find("Chart", 1, true) or full:find("AdventureIF", 1, true)) then
            local cls = SafeClassName(actor)
            if not classes[cls] then
                classes[cls] = {}
                table.insert(order, cls)
            end
            table.insert(classes[cls], actor)
            total = total + 1
        end
    end
    table.insert(lines, "Matched " .. total .. " actors in " .. #order .. " classes")

    for _, cls in ipairs(order) do
        local list = classes[cls]
        table.insert(lines, "")
        table.insert(lines, "--- " .. cls .. " (" .. #list .. ") ---")
        for i, actor in ipairs(list) do
            if i > 80 then
                table.insert(lines, "  ... " .. (#list - 80) .. " more")
                break
            end
            local locOk, locStr = pcall(function()
                local loc = actor:K2_GetActorLocation()
                return string.format(" @ %.0f, %.0f, %.0f", loc.X, loc.Y, loc.Z)
            end)
            local hidden = TryGetProperty(actor, "bHidden")
            table.insert(lines, "  " .. GetWidgetName(actor) .. (locOk and locStr or "")
                .. (type(hidden) == "boolean" and (" hidden=" .. tostring(hidden)) or ""))
        end
        table.insert(lines, "  [properties of first instance]")
        local pOk, err = pcall(DumpOwnProperties, list[1], lines)
        if not pOk then
            table.insert(lines, "  (property error: " .. tostring(err) .. ")")
        end
    end

    WriteDump("chart_actors.txt", table.concat(lines, "\n") .. "\n")
    print("[AE-DBG] Chart actors: " .. total .. " in " .. #order .. " classes")
    return total
end

-- === F7: STORY TRACE / F8: MARKER ===
-- Automatic change log for play-testing without F6 presses. While on, every
-- 100ms snapshots story map state (mod internals, raw title panel, path
-- characters, guide bar, branch conditions, camera) and appends only CHANGED
-- values to story_trace.txt, plus every line the mod speaks.

local CharaNames = require("chara_names")

local TRACE_VALUE_MAX = 300

local _traceActive = false
local _traceGen = 0               -- invalidates old loops on quick off/on
local _traceLast = {}             -- key -> last logged value
local _traceLastError = nil
local _traceMarker = 0
local _traceStart = os.clock()
local _camPrev = nil              -- camera location last tick
local _camLogged = nil            -- camera location last logged

local function TraceWrite(line)
    AppendDump("story_trace.txt", string.format("%s +%7.1fs  %s\n",
        os.date("%H:%M:%S"), os.clock() - _traceStart, line))
end

local function TextOf(widget)
    local ok, text = pcall(function() return widget:GetText():ToString() end)
    return ok and text or nil
end

local function TraceDistance(a, b)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

local function BuildTraceSnapshot()
    local snap = {}
    local function put(key, value)
        local s = (value == nil) and "nil" or tostring(value)
        s = s:gsub("[\r\n]+", " ")
        if #s > TRACE_VALUE_MAX then s = s:sub(1, TRACE_VALUE_MAX) .. "..." end
        table.insert(snap, { key, s })
    end

    -- Mod internal state
    for _, modName in ipairs({ "episode_battle", "episode_map" }) do
        local ok, mod = pcall(require, modName)
        if ok and type(mod) == "table" and mod.GetDebugState then
            local sOk, state = pcall(mod.GetDebugState)
            if sOk and type(state) == "table" then
                for _, kv in ipairs(state) do put(kv[1], kv[2]) end
            end
        end
    end

    -- Title panel text + visibility, branch condition texts
    local titleFields = {
        Text_ScenarioTitle_0 = true, Text_ScenarioTitle_1 = true,
        Text_Chapter = true, Text_EventTitle = true, TXT_Orb = true,
    }
    local branchTexts = {}
    local textBlocks = FindAllOf("TextBlock")
    if textBlocks then
        local found = {}
        for _, tb in ipairs(textBlocks) do
            local name = GetWidgetName(tb)
            if titleFields[name] or name == "Text_BranchCondition_0" then
                local ok, path = pcall(function() return tb:GetFullName() end)
                if ok and path:find("Transient", 1, true) then
                    if titleFields[name] and path:find("WBP_GRP_AI_ChartTitle_C", 1, true) then
                        local vis = TryCall(tb, "IsVisible")
                        found[name] = tostring(TextOf(tb)) .. (vis and "" or " [hidden]")
                    elseif name == "Text_BranchCondition_0" then
                        local inst = path:match("(WBP_OBJ_AI_BranchConditons_Set_C_%d+)")
                        if inst then branchTexts[inst] = TextOf(tb) end
                    end
                end
            end
        end
        local names = {}
        for name in pairs(titleFields) do table.insert(names, name) end
        table.sort(names)
        for _, name in ipairs(names) do put("ui." .. name, found[name]) end
    end

    -- Path characters (title panel OtherCharaIcon_N portraits)
    local charas = {}
    local okI, icons = pcall(FindAllOf, "WBP_OBJ_AI_CharaIcon_C")
    if okI and icons then
        for _, icon in ipairs(icons) do
            local ok, path = pcall(function() return icon:GetFullName() end)
            local idx = ok and path:find("WBP_GRP_AI_ChartTitle_C", 1, true)
                and path:match("WBP_OBJ_AI_OtherCharaIcon_(%d+)$")
            if idx and TryCall(icon, "IsVisible") then
                local tOk, texName = pcall(function()
                    local res = icon.IMG_Chara.Brush.ResourceObject
                    return res and res:GetFullName() or nil
                end)
                local id = tOk and texName and CharaNames.ExtractIdFromTexture(texName) or nil
                if id then
                    table.insert(charas, idx .. ":" .. (CharaNames.GetName(id) or id))
                end
            end
        end
    end
    table.sort(charas)
    put("ui.pathCharacters", table.concat(charas, ", "))

    -- Guide bar (visible buttons, sorted by widget name)
    local guide = {}
    local okG, buttons = pcall(FindAllOf, "WBP_OBJ_Guide_Btn_0_C")
    if okG and buttons then
        for _, btn in ipairs(buttons) do
            if TryCall(btn, "IsVisible") then
                local okR, rt = pcall(function() return btn.RTEXT_Help_0 end)
                table.insert(guide, { GetWidgetName(btn), (okR and rt and TextOf(rt)) or "?" })
            end
        end
    end
    table.sort(guide, function(a, b) return a[1] < b[1] end)
    local guideParts = {}
    for _, g in ipairs(guide) do table.insert(guideParts, g[2]) end
    put("ui.guide", #guide .. " | " .. table.concat(guideParts, " | "))

    -- Branch condition sets
    local branchParts = {}
    local okB, sets = pcall(FindAllOf, "WBP_OBJ_AI_BranchConditons_Set_C")
    if okB and sets then
        for _, set in ipairs(sets) do
            local inst = GetWidgetName(set)
            if branchTexts[inst] ~= nil then
                local swOk, sw = pcall(function() return set.WidgetSwitcher_1 end)
                local opacity = swOk and sw and TryCall(sw, "GetRenderOpacity") or nil
                local page = swOk and sw and TryCall(sw, "GetActiveWidgetIndex") or nil
                table.insert(branchParts, string.format("%s vis=%s page=%s opacity=%s text=%s",
                    inst:match("_(%d+)$") or inst,
                    tostring(TryCall(set, "IsVisible")),
                    tostring(page),
                    type(opacity) == "number" and string.format("%.2f", opacity) or "?",
                    tostring(branchTexts[inst])))
            end
        end
    end
    table.sort(branchParts)
    put("ui.branch", table.concat(branchParts, " ; "))

    -- Camera location (moves between nodes on the 3D map)
    local cam = nil
    local okC, cams = pcall(FindAllOf, "PlayerCameraManager")
    if okC and cams then
        for _, c in ipairs(cams) do
            local nOk, full = pcall(function() return c:GetFullName() end)
            if nOk and not full:find("Default__", 1, true) then
                local lOk, v = pcall(function()
                    local loc = c:GetCameraLocation()
                    return { loc.X, loc.Y, loc.Z }
                end)
                if lOk and v and type(v[1]) == "number" then
                    cam = v
                    break
                end
            end
        end
    end

    return snap, cam
end

local function TraceTick()
    -- Skip map transitions (FindAllOf can crash while objects are destroyed)
    local okT, trackers = pcall(require, "poll_trackers")
    if okT and type(trackers) == "table" and trackers.IsInTransition then
        local tOk, inTransition = pcall(trackers.IsInTransition)
        if tOk and inTransition then return end
    end

    local snap, cam = BuildTraceSnapshot()
    for _, kv in ipairs(snap) do
        local key, value = kv[1], kv[2]
        local old = _traceLast[key]
        if old ~= value then
            if old == nil then
                TraceWrite(key .. " = " .. value)
            else
                TraceWrite(key .. " = " .. value .. "   (was: " .. old .. ")")
            end
            _traceLast[key] = value
        end
    end

    -- Camera glides between nodes: log only once it settles somewhere new
    if cam then
        if _camPrev and TraceDistance(cam, _camPrev) < 1
           and (not _camLogged or TraceDistance(cam, _camLogged) > 50) then
            TraceWrite(string.format("camera settled at %.0f, %.0f, %.0f", cam[1], cam[2], cam[3])
                .. (_camLogged and string.format("   (moved %.0f)", TraceDistance(cam, _camLogged)) or ""))
            _camLogged = cam
        end
        _camPrev = cam
    end
end

local function StartTrace()
    _traceGen = _traceGen + 1
    local gen = _traceGen
    _traceActive = true
    _traceLast = {}
    _traceLastError = nil
    _camPrev, _camLogged = nil, nil
    AppendDump("story_trace.txt", "\n===== Trace started " .. os.date("%Y-%m-%d %H:%M:%S") .. " =====\n")

    GT.Every("StoryTrace", 100, function()
        if not _traceActive or gen ~= _traceGen then return true end  -- stop loop
        local ok, err = pcall(TraceTick)
        if not ok and tostring(err) ~= _traceLastError then
            _traceLastError = tostring(err)
            TraceWrite("TRACE ERROR: " .. _traceLastError)
        end
        return false
    end)
end

-- === INIT & KEYBINDS ===

function DebugTools.Init(SpeakFn)
    -- Create dump directory
    os.execute("mkdir " .. DUMP_DIR .. " 2>NUL")

    -- Clear dump files on startup
    local filesToClear = {"debug_dump.txt", "chara_select.txt", "battle_gauges.txt", "battle_state.txt", "story_map.txt", "story_trace.txt", "chart_actors.txt"}
    for _, f in ipairs(filesToClear) do
        local fh = io.open(DUMP_DIR .. "/" .. f, "w")
        if fh then
            fh:write("(cleared on startup " .. os.date("%Y-%m-%d %H:%M:%S") .. ")\n\n")
            fh:close()
        end
    end

    -- F5: Toggle continuous debug dump
    GT.OnKey(Key.F5, "F5 debug dump", function()
        if _dumpActive then
            StopDumpLoop()
            if SpeakFn then SpeakFn("Debug dump off", true) end
            print("[AE-DBG] Continuous dump stopped")
        else
            StartDumpLoop()
            if SpeakFn then SpeakFn("Debug dump on", true) end
            print("[AE-DBG] Continuous dump started (250ms, change-only)")
        end
    end)

    -- F4: Character select dump
    GT.OnKey(Key.F4, "F4 chara select dump", function()
        if SpeakFn then SpeakFn("Inspecting character select...", true) end
        pcall(DumpCharaSelectInfo)
        if SpeakFn then SpeakFn("Character select dump complete", true) end
    end)

    -- F3: Battle state dump
    GT.OnKey(Key.F3, "F3 battle dump", function()
        if SpeakFn then SpeakFn("Battle dump", true) end
        local ok, err = pcall(DumpBattleGameState)
        if not ok then
            AppendDump("battle_state.txt", "--- ERROR: " .. tostring(err) .. " ---\n\n")
            print("[AE-DBG] Battle state error: " .. tostring(err))
        end
        pcall(DumpBattleGauges)
        if SpeakFn then SpeakFn("Battle dump complete", true) end
    end)

    -- F6: Story map structure dump
    GT.OnKey(Key.F6, "F6 story map dump", function()
        if SpeakFn then SpeakFn("Story map dump", true) end
        local ok, result = pcall(DumpStoryMap)
        if not ok then
            AppendDump("story_map.txt", "--- ERROR: " .. tostring(result) .. " ---\n\n")
            print("[AE-DBG] Story map dump error: " .. tostring(result))
            if SpeakFn then SpeakFn("Story map dump failed", true) end
        elseif result == 0 then
            if SpeakFn then SpeakFn("Story map dump: no widgets found", true) end
        else
            if SpeakFn then SpeakFn("Story map dump " .. _storyMapEntryCount .. " complete", true) end
        end

        -- First press with chart actors present also saves the 3D map objects
        if not _chartActorsDumped then
            local aOk, count = pcall(DumpChartActors)
            if not aOk then
                print("[AE-DBG] Chart actor dump error: " .. tostring(count))
            elseif type(count) == "number" and count > 0 then
                _chartActorsDumped = true
                if SpeakFn then SpeakFn("Map objects saved", false) end
            end
        end
    end)

    -- F7: Toggle story trace
    GT.OnKey(Key.F7, "F7 story trace", function()
        if _traceActive then
            _traceActive = false
            TraceWrite("===== Trace stopped =====")
            if SpeakFn then SpeakFn("Trace off", true) end
            print("[AE-DBG] Story trace stopped")
        else
            StartTrace()
            if SpeakFn then SpeakFn("Trace on", true) end
            print("[AE-DBG] Story trace started")
        end
    end)

    -- F8: Numbered marker in the trace
    GT.OnKey(Key.F8, "F8 trace marker", function()
        _traceMarker = _traceMarker + 1
        TraceWrite("########## MARKER " .. _traceMarker .. " ##########")
        print("[AE-DBG] Trace marker " .. _traceMarker)
        if SpeakFn then SpeakFn("Marker " .. _traceMarker, true) end
    end)

    -- Record everything the mod speaks while the trace is on
    local okS, Speech = pcall(require, "speech")
    if okS and type(Speech) == "table" and Speech.SetListener then
        Speech.SetListener(function(text, interrupt)
            if _traceActive then
                TraceWrite((interrupt and "SPEAK: " or "QUEUE: ") .. tostring(text))
            end
        end)
    else
        print("[AE-DBG] Speech listener unavailable, trace will not record speech")
    end

    print("[AE-DBG] Debug tools loaded. F3=battle dump, F4=chara select, F5=toggle debug dump, F6=story map dump, F7=story trace, F8=trace marker")
end

return DebugTools
