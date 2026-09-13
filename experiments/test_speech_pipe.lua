-- Offline test: speech.lua talking to a pipe server (pipe_server_stub.py or NVDA).
-- Usage: lua test_speech_pipe.lua <mod scripts dir>
package.path = arg[1] .. "\\?.lua;" .. package.path

local Speech = require("speech")
Speech.Init()
print("connected after init: " .. tostring(Speech.IsConnected()))

Speech.Speak("First line, interrupting", true)
Speech.SpeakQueued("Second line, queued")
Speech.Speak("Line with\nnewline and\r\ncarriage return", true)
Speech.Speak("Unicode: Piccolo \u{00E9} \u{30AB}\u{30AB}\u{30ED}\u{30C3}\u{30C8}", true)
Speech.Speak("Icon markup: <icon id=\"Pad_03\" table=\"PS5\"/> Confirm", true)
Speech.Speak("", true)          -- ignored
Speech.SpeakQueued("   ")       -- ignored
print("connected at end: " .. tostring(Speech.IsConnected()) .. ", dropped: " .. Speech.DroppedCount())
