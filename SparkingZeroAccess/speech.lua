--[[
    speech.lua — speech over a named pipe

    The mod runs inside the game's UE4SS Lua state and cannot load screen
    reader DLLs itself: UE4SS exports no Lua C API, and newer UE4SS builds ship
    a modified Lua that breaks a statically linked C module (speech_bridge.dll,
    removed 2026-09-12). Instead every announcement is written as one line to
    the named pipe \\.\pipe\SparkingZeroAccess. The Sparking Zero Access NVDA
    add-on (nvda-addon\) serves that pipe and speaks the lines.

    Line format, UTF-8, "\n" terminated:
        "!" .. text   speak now, interrupting current speech
        "+" .. text   speak after current speech
    Lua's io library opens the pipe like a file (fopen -> CreateFile). With no
    server the open fails at once and is retried on a later Speak, at most
    every RETRY_SECONDS. A failed write (server gone) closes the pipe and
    reconnects once; if that fails the line is dropped and counted.
]]

local IconParser = require("icon_parser")

local Speech = {}

local PIPE_PATH = [[\\.\pipe\SparkingZeroSpeech]]
local RETRY_SECONDS = 3.0

local _pipe = nil
local _nextTry = 0
local _openErrorLogged = nil
local _dropped = 0
local _droppedLogged = 0

local function Close()
    if _pipe then
        pcall(_pipe.close, _pipe)
        _pipe = nil
    end
end

-- Returns true when the pipe is open (possibly just opened).
local function Connect()
    if _pipe then return true end
    local now = os.clock()
    if now < _nextTry then return false end
    _nextTry = now + RETRY_SECONDS
    local f, err = io.open(PIPE_PATH, "wb")
    if not f then
        err = tostring(err)
        if err ~= _openErrorLogged then
            _openErrorLogged = err
            print("[AE] Speech pipe not available (" .. err .. "). Start NVDA with the Sparking Zero Access add-on; retrying every " .. RETRY_SECONDS .. " s")
        end
        return false
    end
    f:setvbuf("no")  -- one WriteFile per line, nothing waits in a CRT buffer
    _pipe = f
    _openErrorLogged = nil
    print("[AE] Speech pipe connected")
    return true
end

local function Send(prefix, text)
    -- One utterance per line; the server splits on "\n"
    text = text:gsub("[\r\n]+", " ")
    local line = prefix .. text .. "\n"
    if Connect() then
        local ok, err = _pipe:write(line)
        if ok then return true end
        print("[AE] Speech pipe write failed (" .. tostring(err) .. "), reconnecting")
        Close()
        _nextTry = 0
        if Connect() and _pipe:write(line) then return true end
    end
    _dropped = _dropped + 1
    if _dropped == 1 or _dropped >= _droppedLogged * 10 then
        _droppedLogged = _dropped
        print("[AE] Speech dropped, no pipe server (" .. _dropped .. " total): " .. text)
    end
    return false
end

function Speech.Init()
    if Connect() then
        print("[AE] Speech ready (pipe)")
    else
        print("[AE] Speech will connect when the pipe server appears")
    end
end

--- Speech is always "loaded": the transport needs no DLL. Kept for callers.
function Speech.IsLoaded()
    return true
end

function Speech.IsConnected()
    return _pipe ~= nil
end

function Speech.DroppedCount()
    return _dropped
end

-- Optional observer called with (text, interrupt) for everything spoken.
-- Used by the story trace in debug_tools.lua.
local _listener = nil

function Speech.SetListener(fn)
    _listener = fn
end

function Speech.Speak(text, interrupt)
    if not text or text == "" then return end
    text = IconParser.Parse(text)
    if not text or text == "" then return end
    interrupt = interrupt ~= false
    if _listener then pcall(_listener, text, interrupt) end
    Send(interrupt and "!" or "+", text)
end

function Speech.SpeakQueued(text)
    if not text or text == "" then return end
    text = IconParser.Parse(text)
    if not text or text == "" then return end
    if _listener then pcall(_listener, text, false) end
    Send("+", text)
end

return Speech
