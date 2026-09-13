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
 * Diagnostics: plugins\SparkingZeroSpeech.log (rewritten at every game start).
 */

#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#define PIPE_NAME L"\\\\.\\pipe\\SparkingZeroSpeech"
#define READ_BUFFER_SIZE 4096
#define LINE_BUFFER_SIZE 16384

/* UniversalSpeech parameter constants */
#define SP_ENABLE_NATIVE_SPEECH 0xFFFF
#define SP_ENGINE 0x40000

typedef int (__cdecl *fn_speechSay)(const wchar_t* str, int interrupt);
typedef int (__cdecl *fn_speechSetValue)(int what, int value);
typedef const wchar_t* (__cdecl *fn_speechGetString)(int what);

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
    if (wcslen(g_dir) + 24 >= MAX_PATH) return FALSE;
    wcscpy_s(g_logPath, MAX_PATH, g_dir);
    wcscat_s(g_logPath, MAX_PATH, L"SparkingZeroSpeech.log");
    return TRUE;
}

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

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = hinst;
        DisableThreadLibraryCalls(hinst);
        InitializeCriticalSection(&g_logLock);
        if (!init_paths()) return TRUE; /* stay loaded but inert */
        DeleteFileW(g_logPath);
        log_line("SparkingZeroSpeech plugin loaded");
        /* Nothing heavy in DllMain: the thread loads UniversalSpeech and serves the pipe */
        g_thread = CreateThread(NULL, 0, server_thread, NULL, 0, NULL);
        if (!g_thread) log_line("CreateThread failed (error %lu)", GetLastError());
    } else if (reason == DLL_PROCESS_DETACH) {
        InterlockedExchange(&g_stop, 1);
        if (g_pipe != INVALID_HANDLE_VALUE) {
            HANDLE h = g_pipe;
            g_pipe = INVALID_HANDLE_VALUE;
            CancelIoEx(h, NULL);
            CloseHandle(h);
        }
        /* Don't wait for the thread here: the process is exiting */
    }
    return TRUE;
}
