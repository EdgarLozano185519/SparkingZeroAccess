/*
 * SparkingZeroSpeech.c - in-process speech server for the Sparking Zero Access mod
 *
 * Built as an ASI plugin: a plain DLL named SparkingZeroSpeech.asi that the
 * Ultimate ASI Loader (dsound.dll, already installed for the UTOC bypass) loads
 * from SparkingZERO\Binaries\Win64\plugins\ when the game starts. It does not
 * depend on UE4SS at all, so it works with any UE4SS version.
 *
 * It owns the named pipe \\.\pipe\SparkingZeroSpeech. The Lua mod (speech.lua)
 * opens that pipe with plain io.open and writes one UTF-8 line per utterance:
 *   "!text\n"  speak now, interrupting current speech
 *   "+text\n"  speak after current speech
 * Lines are spoken through UniversalSpeech.dll (NVDA, JAWS, SAPI fallback),
 * loaded from this plugin's folder together with its own DLLs
 * (nvdaControllerClient.dll, ZDSRAPI.dll).
 *
 * Crash catcher (2026-09-13): the game sometimes dies silently (no UE4SS dump,
 * no Windows event) when the crash happens on the game thread inside UE's own
 * guarded main loop. A vectored exception handler sees every hardware
 * exception first, before UE or UE4SS: on fatal-looking codes it logs the
 * code, faulting address, module+offset, thread and a stack walk, and writes
 * a minidump (plugins\AE_crash_<time>.dmp, readable with experiments\mdump.py)
 * from a helper thread. The exception is then passed on unchanged.
 * DLL_PROCESS_DETACH is logged too: if the log ends without "Process exiting"
 * and without an exception line, the process was killed by TerminateProcess
 * or a fail-fast, which no handler can observe.
 *
 * Diagnostics: plugins\SparkingZeroSpeech.log (rewritten at every game start).
 */

#include <windows.h>
#include <dbghelp.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#define PIPE_NAME L"\\\\.\\pipe\\SparkingZeroSpeech"
#define READ_BUFFER_SIZE 4096
#define LINE_BUFFER_SIZE 16384
#define MAX_DUMPS 3
#define MAX_FRAMES 48

/* UniversalSpeech parameter constants */
#define SP_ENABLE_NATIVE_SPEECH 0xFFFF
#define SP_ENGINE 0x40000

typedef int (__cdecl *fn_speechSay)(const wchar_t* str, int interrupt);
typedef int (__cdecl *fn_speechSetValue)(int what, int value);
typedef const wchar_t* (__cdecl *fn_speechGetString)(int what);

typedef BOOL (WINAPI *fn_MiniDumpWriteDump)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
    PMINIDUMP_EXCEPTION_INFORMATION, PMINIDUMP_USER_STREAM_INFORMATION, PMINIDUMP_CALLBACK_INFORMATION);
typedef BOOL (WINAPI *fn_StackWalk64)(DWORD, HANDLE, HANDLE, LPSTACKFRAME64, PVOID,
    PREAD_PROCESS_MEMORY_ROUTINE64, PFUNCTION_TABLE_ACCESS_ROUTINE64, PGET_MODULE_BASE_ROUTINE64, PTRANSLATE_ADDRESS_ROUTINE64);
typedef PVOID (WINAPI *fn_SymFunctionTableAccess64)(HANDLE, DWORD64);
typedef DWORD64 (WINAPI *fn_SymGetModuleBase64)(HANDLE, DWORD64);
typedef BOOL (WINAPI *fn_SymInitialize)(HANDLE, PCSTR, BOOL);

static HMODULE g_self = NULL;
static HANDLE g_thread = NULL;
static volatile LONG g_stop = 0;
static HANDLE g_pipe = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION g_logLock;
static wchar_t g_dir[MAX_PATH];
static wchar_t g_logPath[MAX_PATH];

static HMODULE g_speechDll = NULL;
static fn_speechSay g_speechSay = NULL;
static fn_speechSetValue g_speechSetValue = NULL;
static fn_speechGetString g_speechGetString = NULL;

/* Crash catcher state */
static DWORD g_mainThreadId = 0;
static PVOID g_vehHandle = NULL;
static HANDLE g_dumpThread = NULL;
static HANDLE g_dumpRequest = NULL;     /* set by the crashing thread */
static HANDLE g_dumpDone = NULL;        /* set by the dumper thread */
static volatile LONG g_dumpLock = 0;    /* one crash at a time */
static volatile LONG g_dumpCount = 0;
static EXCEPTION_POINTERS* g_excPointers = NULL;
static CONTEXT g_excContext;            /* copy for the stack walk */
static DWORD g_excThreadId = 0;
static HANDLE g_excThread = NULL;
static HMODULE g_dbghelp = NULL;
static fn_MiniDumpWriteDump g_MiniDumpWriteDump = NULL;
static fn_StackWalk64 g_StackWalk64 = NULL;
static fn_SymFunctionTableAccess64 g_SymFunctionTableAccess64 = NULL;
static fn_SymGetModuleBase64 g_SymGetModuleBase64 = NULL;

static void log_line(const char* fmt, ...)
{
    char text[1024];
    va_list args;
    FILE* f;
    SYSTEMTIME st;

    va_start(args, fmt);
    _vsnprintf_s(text, sizeof(text), _TRUNCATE, fmt, args);
    va_end(args);

    EnterCriticalSection(&g_logLock);
    if (_wfopen_s(&f, g_logPath, L"a") == 0 && f) {
        GetLocalTime(&st);
        fprintf(f, "[%02d:%02d:%02d.%03d] %s\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, text);
        fclose(f);
    }
    LeaveCriticalSection(&g_logLock);
}

static BOOL init_paths(void)
{
    DWORD len = GetModuleFileNameW(g_self, g_dir, MAX_PATH);
    wchar_t* slash;
    if (len == 0 || len >= MAX_PATH) return FALSE;
    slash = wcsrchr(g_dir, L'\\');
    if (!slash) return FALSE;
    slash[1] = L'\0';
    if (wcslen(g_dir) + 40 >= MAX_PATH) return FALSE;
    wcscpy_s(g_logPath, MAX_PATH, g_dir);
    wcscat_s(g_logPath, MAX_PATH, L"SparkingZeroSpeech.log");
    return TRUE;
}

/* ---------------------------------------------------------------- speech */

static BOOL load_speech(void)
{
    wchar_t path[MAX_PATH];
    const wchar_t* engine;

    /* UniversalSpeech loads nvdaControllerClient.dll etc. by name at runtime:
       make this folder part of the DLL search path, like speech_bridge.dll did */
    SetDllDirectoryW(g_dir);

    wcscpy_s(path, MAX_PATH, g_dir);
    wcscat_s(path, MAX_PATH, L"UniversalSpeech.dll");
    g_speechDll = LoadLibraryW(path);
    if (!g_speechDll) {
        log_line("Failed to load UniversalSpeech.dll (error %lu)", GetLastError());
        return FALSE;
    }
    g_speechSay = (fn_speechSay)GetProcAddress(g_speechDll, "speechSay");
    g_speechSetValue = (fn_speechSetValue)GetProcAddress(g_speechDll, "speechSetValue");
    g_speechGetString = (fn_speechGetString)GetProcAddress(g_speechDll, "speechGetString");
    if (!g_speechSay) {
        log_line("speechSay not found in UniversalSpeech.dll");
        return FALSE;
    }
    if (g_speechSetValue) {
        g_speechSetValue(SP_ENABLE_NATIVE_SPEECH, 1); /* SAPI fallback */
    }
    engine = g_speechGetString ? g_speechGetString(SP_ENGINE) : NULL;
    log_line("UniversalSpeech loaded, engine: %S", engine ? engine : L"(unknown)");
    return TRUE;
}

static void speak_utf8(const char* text, size_t len, int interrupt)
{
    int wlen;
    wchar_t* wide;
    if (len == 0 || !g_speechSay) return;
    wlen = MultiByteToWideChar(CP_UTF8, 0, text, (int)len, NULL, 0);
    if (wlen <= 0) return;
    wide = (wchar_t*)malloc(((size_t)wlen + 1) * sizeof(wchar_t));
    if (!wide) return;
    MultiByteToWideChar(CP_UTF8, 0, text, (int)len, wide, wlen);
    wide[wlen] = L'\0';
    g_speechSay(wide, interrupt);
    free(wide);
}

/* One protocol line without its "\n" */
static void handle_line(const char* line, size_t len)
{
    int interrupt;
    /* strip "\r" and surrounding whitespace */
    while (len > 0 && (line[len - 1] == '\r' || line[len - 1] == ' ' || line[len - 1] == '\t')) len--;
    if (len < 2) return;
    if (line[0] == '!') interrupt = 1;
    else if (line[0] == '+') interrupt = 0;
    else return;
    line++; len--;
    while (len > 0 && (line[0] == ' ' || line[0] == '\t')) { line++; len--; }
    if (len == 0) return;
    speak_utf8(line, len, interrupt);
}

static void serve_client(HANDLE pipe)
{
    static char buf[READ_BUFFER_SIZE];
    static char pending[LINE_BUFFER_SIZE];
    size_t pendingLen = 0;
    DWORD count;
    log_line("Game connected");
    while (!g_stop) {
        if (!ReadFile(pipe, buf, READ_BUFFER_SIZE, &count, NULL) || count == 0) {
            DWORD err = GetLastError();
            if (err != ERROR_BROKEN_PIPE && err != ERROR_OPERATION_ABORTED && err != 0) {
                log_line("ReadFile failed (error %lu)", err);
            }
            break;
        }
        {
            DWORD i;
            for (i = 0; i < count; i++) {
                char c = buf[i];
                if (c == '\n') {
                    handle_line(pending, pendingLen);
                    pendingLen = 0;
                } else if (pendingLen < LINE_BUFFER_SIZE - 1) {
                    pending[pendingLen++] = c;
                }
            }
        }
    }
    log_line("Game disconnected");
}

static DWORD WINAPI server_thread(LPVOID param)
{
    DWORD lastCreateError = 0;
    (void)param;

    if (!load_speech()) {
        log_line("Speech unavailable, pipe server not started");
        return 1;
    }

    while (!g_stop) {
        HANDLE pipe = CreateNamedPipeW(PIPE_NAME,
            PIPE_ACCESS_INBOUND,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1, READ_BUFFER_SIZE, 65536, 0, NULL);
        if (pipe == INVALID_HANDLE_VALUE) {
            DWORD err = GetLastError();
            if (err != lastCreateError) {
                lastCreateError = err;
                log_line("CreateNamedPipe failed (error %lu). Is another speech server using the pipe?", err);
            }
            Sleep(3000);
            continue;
        }
        if (lastCreateError == 0) {
            log_line("Pipe server ready on \\\\.\\pipe\\SparkingZeroSpeech");
            lastCreateError = (DWORD)-1; /* log once */
        }
        g_pipe = pipe;
        if (ConnectNamedPipe(pipe, NULL) || GetLastError() == ERROR_PIPE_CONNECTED) {
            if (!g_stop) serve_client(pipe);
        }
        g_pipe = INVALID_HANDLE_VALUE;
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }
    return 0;
}

/* ---------------------------------------------------------- crash catcher */

/* "UE4SS.dll+0x4BDDAE" for an address, or "?" when it is in no module */
static void describe_address(DWORD64 addr, char* out, size_t outLen)
{
    HMODULE mod = NULL;
    wchar_t path[MAX_PATH];
    const wchar_t* base = NULL;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)(ULONG_PTR)addr, &mod) && mod) {
        if (GetModuleFileNameW(mod, path, MAX_PATH) > 0) {
            base = wcsrchr(path, L'\\');
            base = base ? base + 1 : path;
            _snprintf_s(out, outLen, _TRUNCATE, "%S+0x%llX", base, (unsigned long long)(addr - (DWORD64)(ULONG_PTR)mod));
            return;
        }
    }
    _snprintf_s(out, outLen, _TRUNCATE, "0x%llX (no module)", (unsigned long long)addr);
}

/* Last debug-output strings (OutputDebugString raises DBG_PRINTEXCEPTION_C /
   _WIDE_C, which a vectored handler sees when no debugger is attached; UE's
   fatal-error path prints its message that way before it raises code 1) */
#define DEBUG_RING 24
#define DEBUG_LINE 512
static char g_debugRing[DEBUG_RING][DEBUG_LINE];
static volatile LONG g_debugCount = 0;
static CRITICAL_SECTION g_debugLock;

static void remember_debug_string(const char* text, size_t len, int wide)
{
    LONG slot;
    char* dst;
    EnterCriticalSection(&g_debugLock);
    slot = g_debugCount % DEBUG_RING;
    g_debugCount++;
    dst = g_debugRing[slot];
    if (wide) {
        int n = WideCharToMultiByte(CP_UTF8, 0, (const wchar_t*)text, (int)len, dst, DEBUG_LINE - 1, NULL, NULL);
        dst[n > 0 ? n : 0] = '\0';
    } else {
        if (len >= DEBUG_LINE) len = DEBUG_LINE - 1;
        memcpy(dst, text, len);
        dst[len] = '\0';
    }
    /* keep it on one log line */
    for (; *dst; dst++) if (*dst == '\r' || *dst == '\n') *dst = ' ';
    LeaveCriticalSection(&g_debugLock);
}

static void log_debug_ring(void)
{
    LONG total, first, i;
    EnterCriticalSection(&g_debugLock);
    total = g_debugCount;
    if (total == 0) {
        LeaveCriticalSection(&g_debugLock);
        log_line("  (no debug output strings seen)");
        return;
    }
    first = total > DEBUG_RING ? total - DEBUG_RING : 0;
    log_line("  last %ld of %ld debug output strings:", total - first, total);
    for (i = first; i < total; i++) log_line("    dbg: %s", g_debugRing[i % DEBUG_RING]);
    LeaveCriticalSection(&g_debugLock);
}

static const char* exception_name(DWORD code)
{
    switch (code) {
    case 1: return "UE fatal error (FPlatformMisc::RaiseException)";
    case EXCEPTION_ACCESS_VIOLATION: return "ACCESS_VIOLATION";
    case EXCEPTION_IN_PAGE_ERROR: return "IN_PAGE_ERROR";
    case EXCEPTION_STACK_OVERFLOW: return "STACK_OVERFLOW";
    case EXCEPTION_ILLEGAL_INSTRUCTION: return "ILLEGAL_INSTRUCTION";
    case EXCEPTION_PRIV_INSTRUCTION: return "PRIV_INSTRUCTION";
    case EXCEPTION_INT_DIVIDE_BY_ZERO: return "INT_DIVIDE_BY_ZERO";
    case EXCEPTION_BREAKPOINT: return "BREAKPOINT";
    case 0xC0000374: return "HEAP_CORRUPTION";
    case 0xC0000409: return "STACK_BUFFER_OVERRUN / fail fast";
    case 0xE06D7363: return "C++ exception";
    default: return "?";
    }
}

static BOOL is_fatal_code(DWORD code)
{
    switch (code) {
    case 1: /* UE: GError->Serialize -> FPlatformMisc::RaiseException(1), then RequestExit(true) = exit code 3 */
    case EXCEPTION_ACCESS_VIOLATION:
    case EXCEPTION_IN_PAGE_ERROR:
    case EXCEPTION_STACK_OVERFLOW:
    case EXCEPTION_ILLEGAL_INSTRUCTION:
    case EXCEPTION_PRIV_INSTRUCTION:
    case EXCEPTION_INT_DIVIDE_BY_ZERO:
    case EXCEPTION_BREAKPOINT:
    case 0xC0000374:
    case 0xC0000409:
        return TRUE;
    default:
        return FALSE;
    }
}

/* Runs on the dumper thread while the crashing thread waits: walk its stack
   from the exception context and write the minidump. */
static void write_crash_report(void)
{
    EXCEPTION_RECORD* rec = g_excPointers->ExceptionRecord;
    DWORD code = rec->ExceptionCode;
    char where[160];
    SYSTEMTIME st;
    wchar_t dumpPath[MAX_PATH];
    HANDLE file;
    LONG index = InterlockedIncrement(&g_dumpCount);

    describe_address((DWORD64)(ULONG_PTR)rec->ExceptionAddress, where, sizeof(where));
    log_line("EXCEPTION 0x%08lX %s at %s on thread %lu%s", code, exception_name(code), where,
             g_excThreadId, g_excThreadId == g_mainThreadId ? " (game thread)" : "");
    if (code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR) {
        log_line("  %s address 0x%llX",
                 rec->ExceptionInformation[0] == 0 ? "reading" : (rec->ExceptionInformation[0] == 1 ? "writing" : "executing"),
                 (unsigned long long)rec->ExceptionInformation[1]);
    }
    if (code == 1 && rec->NumberParameters >= 1 && rec->ExceptionInformation[0] != 0) {
        /* UE passes GErrorHist (the fatal error text, wide) as the first parameter */
        const wchar_t* msg = (const wchar_t*)rec->ExceptionInformation[0];
        char text[900];
        int n = 0;
        if (!IsBadReadPtr(msg, 2)) {
            n = WideCharToMultiByte(CP_UTF8, 0, msg, -1, text, sizeof(text) - 1, NULL, NULL);
        }
        if (n > 0) {
            char* p;
            text[n] = '\0';
            for (p = text; *p; p++) if (*p == '\r' || *p == '\n') *p = ' ';
            log_line("  UE error text: %s", text);
        }
    }
    log_debug_ring();
    log_line("  rip=%llX rsp=%llX rax=%llX rcx=%llX rdx=%llX rdi=%llX rsi=%llX",
             (unsigned long long)g_excContext.Rip, (unsigned long long)g_excContext.Rsp,
             (unsigned long long)g_excContext.Rax, (unsigned long long)g_excContext.Rcx,
             (unsigned long long)g_excContext.Rdx, (unsigned long long)g_excContext.Rdi,
             (unsigned long long)g_excContext.Rsi);

    if (g_StackWalk64 && g_excThread) {
        CONTEXT ctx = g_excContext;
        STACKFRAME64 frame;
        int i;
        memset(&frame, 0, sizeof(frame));
        frame.AddrPC.Offset = ctx.Rip;    frame.AddrPC.Mode = AddrModeFlat;
        frame.AddrFrame.Offset = ctx.Rbp; frame.AddrFrame.Mode = AddrModeFlat;
        frame.AddrStack.Offset = ctx.Rsp; frame.AddrStack.Mode = AddrModeFlat;
        for (i = 0; i < MAX_FRAMES; i++) {
            if (!g_StackWalk64(IMAGE_FILE_MACHINE_AMD64, GetCurrentProcess(), g_excThread, &frame, &ctx,
                               NULL, g_SymFunctionTableAccess64, g_SymGetModuleBase64, NULL)) break;
            if (frame.AddrPC.Offset == 0) break;
            describe_address(frame.AddrPC.Offset, where, sizeof(where));
            log_line("  #%02d %s", i, where);
        }
    } else {
        log_line("  (no stack walk: dbghelp not loaded)");
    }

    if (!g_MiniDumpWriteDump) {
        log_line("  (no minidump: MiniDumpWriteDump not available)");
        return;
    }
    if (index > MAX_DUMPS) {
        log_line("  (no minidump: limit of %d reached)", MAX_DUMPS);
        return;
    }
    GetLocalTime(&st);
    _snwprintf_s(dumpPath, MAX_PATH, _TRUNCATE, L"%sAE_crash_%04d_%02d_%02d_%02d_%02d_%02d.dmp", g_dir,
                 st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    file = CreateFileW(dumpPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        log_line("  (no minidump: CreateFile failed, error %lu)", GetLastError());
        return;
    }
    {
        MINIDUMP_EXCEPTION_INFORMATION info;
        MINIDUMP_TYPE type = (MINIDUMP_TYPE)(MiniDumpNormal | MiniDumpWithIndirectlyReferencedMemory
            | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpWithHandleData);
        BOOL ok;
        info.ThreadId = g_excThreadId;
        info.ExceptionPointers = g_excPointers;
        info.ClientPointers = FALSE;
        ok = g_MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file, type, &info, NULL, NULL);
        if (ok) {
            LARGE_INTEGER size;
            size.QuadPart = 0;
            GetFileSizeEx(file, &size);
            log_line("  minidump written: %S (%lld bytes)", dumpPath, (long long)size.QuadPart);
        } else {
            log_line("  MiniDumpWriteDump failed (error 0x%08lX)", GetLastError());
        }
    }
    CloseHandle(file);
}

static DWORD WINAPI dump_thread(LPVOID param)
{
    wchar_t path[MAX_PATH];
    UINT n;
    (void)param;

    /* dbghelp from System32 only (the plugin folder is on the DLL search path) */
    n = GetSystemDirectoryW(path, MAX_PATH);
    if (n > 0 && n + 12 < MAX_PATH) {
        wcscat_s(path, MAX_PATH, L"\\dbghelp.dll");
        g_dbghelp = LoadLibraryW(path);
    }
    if (g_dbghelp) {
        fn_SymInitialize symInit = (fn_SymInitialize)GetProcAddress(g_dbghelp, "SymInitialize");
        g_MiniDumpWriteDump = (fn_MiniDumpWriteDump)GetProcAddress(g_dbghelp, "MiniDumpWriteDump");
        g_StackWalk64 = (fn_StackWalk64)GetProcAddress(g_dbghelp, "StackWalk64");
        g_SymFunctionTableAccess64 = (fn_SymFunctionTableAccess64)GetProcAddress(g_dbghelp, "SymFunctionTableAccess64");
        g_SymGetModuleBase64 = (fn_SymGetModuleBase64)GetProcAddress(g_dbghelp, "SymGetModuleBase64");
        if (symInit) symInit(GetCurrentProcess(), NULL, TRUE); /* module list for the stack walk, no symbols */
        log_line("Crash catcher ready (minidump %s, stack walk %s)",
                 g_MiniDumpWriteDump ? "yes" : "no", g_StackWalk64 ? "yes" : "no");
    } else {
        log_line("Crash catcher without dbghelp.dll (error %lu): exceptions are logged only", GetLastError());
    }

    for (;;) {
        DWORD wait = WaitForSingleObject(g_dumpRequest, INFINITE);
        if (wait != WAIT_OBJECT_0 || g_stop) break;
        write_crash_report();
        SetEvent(g_dumpDone);
    }
    return 0;
}

static LONG WINAPI vectored_handler(EXCEPTION_POINTERS* ep)
{
    DWORD code;
    if (!ep || !ep->ExceptionRecord) return EXCEPTION_CONTINUE_SEARCH;
    code = ep->ExceptionRecord->ExceptionCode;
    if (code == 0x40010006 /* DBG_PRINTEXCEPTION_C */ && ep->ExceptionRecord->NumberParameters >= 2) {
        remember_debug_string((const char*)ep->ExceptionRecord->ExceptionInformation[1],
                              (size_t)ep->ExceptionRecord->ExceptionInformation[0], 0);
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (code == 0x4001000A /* DBG_PRINTEXCEPTION_WIDE_C */ && ep->ExceptionRecord->NumberParameters >= 2) {
        remember_debug_string((const char*)ep->ExceptionRecord->ExceptionInformation[1],
                              (size_t)ep->ExceptionRecord->ExceptionInformation[0], 1);
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (!is_fatal_code(code)) return EXCEPTION_CONTINUE_SEARCH;
    /* One crash at a time; a second crashing thread just passes its exception on */
    if (InterlockedCompareExchange(&g_dumpLock, 1, 0) != 0) return EXCEPTION_CONTINUE_SEARCH;

    g_excPointers = ep;
    g_excContext = *ep->ContextRecord;
    g_excThreadId = GetCurrentThreadId();
    g_excThread = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, g_excThreadId);
    ResetEvent(g_dumpDone);
    if (g_dumpThread && SetEvent(g_dumpRequest)) {
        /* Hold this thread here so its stack stays intact for the walk and the dump */
        WaitForSingleObject(g_dumpDone, 30000);
    } else {
        char where[160];
        describe_address((DWORD64)(ULONG_PTR)ep->ExceptionRecord->ExceptionAddress, where, sizeof(where));
        log_line("EXCEPTION 0x%08lX %s at %s on thread %lu (no dumper thread)", code, exception_name(code), where, g_excThreadId);
    }
    if (g_excThread) { CloseHandle(g_excThread); g_excThread = NULL; }
    g_excPointers = NULL;
    InterlockedExchange(&g_dumpLock, 0);
    return EXCEPTION_CONTINUE_SEARCH; /* UE / UE4SS handle it as before */
}

static void start_crash_catcher(void)
{
    g_dumpRequest = CreateEventW(NULL, FALSE, FALSE, NULL);
    g_dumpDone = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!g_dumpRequest || !g_dumpDone) {
        log_line("Crash catcher: CreateEvent failed (error %lu)", GetLastError());
        return;
    }
    g_dumpThread = CreateThread(NULL, 0, dump_thread, NULL, 0, NULL);
    if (!g_dumpThread) {
        log_line("Crash catcher: CreateThread failed (error %lu)", GetLastError());
        return;
    }
    /* First = called before every other vectored handler */
    g_vehHandle = AddVectoredExceptionHandler(1, vectored_handler);
    if (!g_vehHandle) log_line("Crash catcher: AddVectoredExceptionHandler failed");
}

/* ----------------------------------------------------------------- entry */

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = hinst;
        g_mainThreadId = GetCurrentThreadId();
        DisableThreadLibraryCalls(hinst);
        InitializeCriticalSection(&g_logLock);
        InitializeCriticalSection(&g_debugLock);
        if (!init_paths()) return TRUE; /* stay loaded but inert */
        DeleteFileW(g_logPath);
        log_line("SparkingZeroSpeech plugin loaded (pid %lu, main thread %lu)", GetCurrentProcessId(), g_mainThreadId);
        start_crash_catcher();
        /* Nothing heavy in DllMain: the thread loads UniversalSpeech and serves the pipe */
        g_thread = CreateThread(NULL, 0, server_thread, NULL, 0, NULL);
        if (!g_thread) log_line("CreateThread failed (error %lu)", GetLastError());
    } else if (reason == DLL_PROCESS_DETACH) {
        /* reserved != NULL: the process is exiting (ExitProcess). A kill by
           TerminateProcess or a fail-fast never reaches this point. */
        log_line("Process exiting (%s)", reserved ? "ExitProcess" : "plugin unloaded");
        InterlockedExchange(&g_stop, 1);
        if (g_vehHandle) { RemoveVectoredExceptionHandler(g_vehHandle); g_vehHandle = NULL; }
        if (g_pipe != INVALID_HANDLE_VALUE) {
            HANDLE h = g_pipe;
            g_pipe = INVALID_HANDLE_VALUE;
            CancelIoEx(h, NULL);
            CloseHandle(h);
        }
        /* Don't wait for the threads here: the process is exiting */
    }
    return TRUE;
}
