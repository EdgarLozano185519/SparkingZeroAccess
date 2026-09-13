# Sparking Zero Access - NVDA add-on
#
# The game mod (UE4SS Lua, running inside DRAGON BALL Sparking! ZERO) cannot
# load screen reader DLLs itself, so it writes everything it wants spoken to a
# named pipe. This add-on owns the server end of that pipe and speaks the lines
# through NVDA.
#
# Protocol (client -> server), one UTF-8 line per utterance, "\n" terminated:
#   "!text"  speak now, interrupting current speech
#   "+text"  speak after current speech
# Anything else is ignored. Only Windows API calls from ctypes are used, so the
# add-on has no dependencies beyond NVDA itself.

import ctypes
import ctypes.wintypes as wt
import threading
import time

import globalPluginHandler
import queueHandler
import speech
import ui
from logHandler import log
from scriptHandler import script

PIPE_NAME = r"\\.\pipe\SparkingZeroAccess"
ADDON_LABEL = "Sparking Zero Access"

PIPE_ACCESS_INBOUND = 0x00000001
PIPE_TYPE_BYTE = 0x00000000
PIPE_READMODE_BYTE = 0x00000000
PIPE_WAIT = 0x00000000
PIPE_REJECT_REMOTE_CLIENTS = 0x00000008
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
THREAD_TERMINATE = 0x0001
INVALID_HANDLE_VALUE = wt.HANDLE(-1).value
ERROR_PIPE_CONNECTED = 535
ERROR_BROKEN_PIPE = 109
ERROR_OPERATION_ABORTED = 995
READ_BUFFER_SIZE = 4096

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.CreateNamedPipeW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.DWORD, wt.DWORD, wt.DWORD, wt.DWORD, ctypes.c_void_p]
_k32.CreateNamedPipeW.restype = wt.HANDLE
_k32.ConnectNamedPipe.argtypes = [wt.HANDLE, ctypes.c_void_p]
_k32.ConnectNamedPipe.restype = wt.BOOL
_k32.DisconnectNamedPipe.argtypes = [wt.HANDLE]
_k32.DisconnectNamedPipe.restype = wt.BOOL
_k32.ReadFile.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
_k32.ReadFile.restype = wt.BOOL
_k32.CloseHandle.argtypes = [wt.HANDLE]
_k32.CloseHandle.restype = wt.BOOL
_k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ctypes.c_void_p, wt.DWORD, wt.DWORD, wt.HANDLE]
_k32.CreateFileW.restype = wt.HANDLE
_k32.GetCurrentThreadId.argtypes = []
_k32.GetCurrentThreadId.restype = wt.DWORD
_k32.OpenThread.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
_k32.OpenThread.restype = wt.HANDLE
_k32.CancelSynchronousIo.argtypes = [wt.HANDLE]
_k32.CancelSynchronousIo.restype = wt.BOOL


class PipeSpeechServer:
	"""Named pipe server thread. speak(text, interrupt) is called for every
	line received; it runs on the server thread, so the caller must hand the
	work to NVDA's main thread."""

	def __init__(self, speak, log):
		self._speak = speak
		self._log = log
		self._stop = threading.Event()
		self._thread = None
		self._threadId = 0
		self._handle = None
		self.connected = False
		self.linesReceived = 0
		self._lastCreateError = None

	def start(self):
		self._thread = threading.Thread(target=self._run, name="SparkingZeroAccessPipe", daemon=True)
		self._thread.start()

	def stop(self):
		self._stop.set()
		# Unblock ConnectNamedPipe / ReadFile on the server thread
		if self._threadId:
			th = _k32.OpenThread(THREAD_TERMINATE, False, self._threadId)
			if th:
				_k32.CancelSynchronousIo(th)
				_k32.CloseHandle(th)
		client = _k32.CreateFileW(PIPE_NAME, GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None)
		if client != INVALID_HANDLE_VALUE:
			_k32.CloseHandle(client)
		if self._thread:
			self._thread.join(2.0)

	def _run(self):
		self._threadId = _k32.GetCurrentThreadId()
		while not self._stop.is_set():
			handle = _k32.CreateNamedPipeW(
				PIPE_NAME,
				PIPE_ACCESS_INBOUND,
				PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
				1, READ_BUFFER_SIZE, 65536, 0, None)
			if handle == INVALID_HANDLE_VALUE:
				err = ctypes.get_last_error()
				if err != self._lastCreateError:
					self._lastCreateError = err
					self._log.error("%s: cannot create pipe %s (error %d). Is another speech helper running?" % (ADDON_LABEL, PIPE_NAME, err))
				self._stop.wait(5.0)
				continue
			self._lastCreateError = None
			self._handle = handle
			try:
				self._serveOne(handle)
			except Exception:
				self._log.exception("%s: pipe server error" % ADDON_LABEL)
			finally:
				self.connected = False
				self._handle = None
				_k32.DisconnectNamedPipe(handle)
				_k32.CloseHandle(handle)

	def _serveOne(self, handle):
		ok = _k32.ConnectNamedPipe(handle, None)
		if not ok and ctypes.get_last_error() != ERROR_PIPE_CONNECTED:
			return
		if self._stop.is_set():
			return
		self.connected = True
		self._log.info("%s: game connected" % ADDON_LABEL)
		buf = ctypes.create_string_buffer(READ_BUFFER_SIZE)
		count = wt.DWORD(0)
		pending = b""
		while not self._stop.is_set():
			ok = _k32.ReadFile(handle, buf, READ_BUFFER_SIZE, ctypes.byref(count), None)
			if not ok or count.value == 0:
				err = ctypes.get_last_error()
				if err not in (ERROR_BROKEN_PIPE, ERROR_OPERATION_ABORTED, 0):
					self._log.warning("%s: pipe read failed (error %d)" % (ADDON_LABEL, err))
				break
			pending += buf.raw[:count.value]
			while b"\n" in pending:
				line, pending = pending.split(b"\n", 1)
				self._handleLine(line)
		self._log.info("%s: game disconnected" % ADDON_LABEL)

	def _handleLine(self, raw):
		text = raw.decode("utf-8", "replace").replace("\r", "")
		if len(text) < 2:
			return
		flag, body = text[0], text[1:].strip()
		if not body:
			return
		if flag == "!":
			interrupt = True
		elif flag == "+":
			interrupt = False
		else:
			return
		self.linesReceived += 1
		self._speak(body, interrupt)


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	scriptCategory = ADDON_LABEL

	def __init__(self):
		super(GlobalPlugin, self).__init__()
		self._server = PipeSpeechServer(self._queueSpeech, log)
		self._server.start()
		log.info("%s: pipe server started on %s" % (ADDON_LABEL, PIPE_NAME))

	def terminate(self):
		self._server.stop()
		super(GlobalPlugin, self).terminate()

	def _queueSpeech(self, text, interrupt):
		# Called on the pipe thread: NVDA speech must run on its main thread
		queueHandler.queueFunction(queueHandler.eventQueue, self._say, text, interrupt)

	def _say(self, text, interrupt):
		if interrupt:
			speech.cancelSpeech()
		ui.message(text)

	@script(description="Reports whether the Sparking Zero Access game mod is connected")
	def script_reportStatus(self, gesture):
		if self._server.connected:
			ui.message("%s: game connected, %d messages received" % (ADDON_LABEL, self._server.linesReceived))
		else:
			ui.message("%s: waiting for the game" % ADDON_LABEL)
