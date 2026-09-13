"""Runs the NVDA add-on's pipe server outside NVDA, printing what it would speak.

Usage: python pipe_server_stub.py [seconds]
Stops after the given number of seconds (default 10) or on Ctrl+C. Used by
Test-SpeechPipe.ps1 to test speech.lua against the real add-on code.
"""
import importlib.util
import logging
import os
import sys
import time
import types

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)

# Stand-ins for the NVDA modules the plugin imports
def _module(name, **attrs):
    mod = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(mod, k, v)
    sys.modules[name] = mod
    return mod

class _GlobalPlugin:
    def __init__(self):
        pass
    def terminate(self):
        pass

_module("globalPluginHandler", GlobalPlugin=_GlobalPlugin)
_module("queueHandler", eventQueue=None, queueFunction=lambda queue, fn, *a: fn(*a))
_module("speech", cancelSpeech=lambda: print("SPEECH cancel", flush=True))
_module("ui", message=lambda text: print("SPEECH say: " + text, flush=True))
_module("logHandler", log=logging.getLogger("nvda"))
_module("scriptHandler", script=lambda **kw: (lambda fn: fn))

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "..", "nvda-addon", "globalPlugins", "sparkingZeroAccess.py")
spec = importlib.util.spec_from_file_location("sparkingZeroAccess", path)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
gp = plugin.GlobalPlugin()
print("STUB ready", flush=True)
try:
    time.sleep(seconds)
except KeyboardInterrupt:
    pass
gp.terminate()
print("STUB done, lines received: %d" % gp._server.linesReceived, flush=True)
