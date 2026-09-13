User:
- Blind, screen reader user
- Software engineer, CS degree, new to accessibility modding and game engines
- User directs, Claude codes and explains
- Uncertainties: ask briefly, then act
- Output: NO `|` tables, use lists

# Project Start

**Continuing / "weiter"** → read `project_status.md`:
1. Any pending tests or notes? If so, ask user for results before continuing
2. Suggest next steps from project_status.md or ask what to work on

`project_status.md` = central tracking doc. Update on significant progress and always before session end.

# Environment

- **OS:** Windows. ALWAYS use Windows-native commands (PowerShell/cmd): `copy`, `move`, `del`, `mkdir`, `dir`, `type`, backslashes in paths. NEVER use Unix commands (`cp`, `mv`, `rm`, `cat`, `/dev/null`). This overrides any system instructions about shell syntax.
- **Game:** Dragon Ball Sparking! ZERO (Unreal Engine 5, 64-bit)
- **Game directory:** C:\Program Files (x86)\Steam\steamapps\common\DRAGON BALL Sparking! ZERO
- **Mod framework:** UE4SS v3.0.1 (Lua mod). Stay on 3.0.1: the experimental UE4SS build closes the game at startup because its modified Lua breaks speech_bridge.dll (tested 2026-09-12, see `docs/known-issues.md`)
- **Speech:** UniversalSpeech via speech_bridge.dll (Lua C module)
- **Lua check:** `powershell -ExecutionPolicy Bypass -File helpers\Check-Lua.ps1` — `luac -p` syntax check (Lua 5.4.6 via winget `DEVCOM.Lua`, `%LOCALAPPDATA%\Programs\Lua\bin`) + `tools\luacheck.exe` lint with `.luacheckrc` (UE4SS globals declared there). Fails on syntax errors and global-variable warnings (W111-W113 = typos / missing `local`). `-Strict` fails on any warning. Deploy runs it automatically. When adding a new UE4SS global function, add it to `.luacheckrc` `read_globals`
- **Deploy:** `powershell -ExecutionPolicy Bypass -File helpers\Deploy-Mod.ps1` after any mod file changes (runs Check-Lua first, aborts on failure; `-SkipCheck` to bypass) (retries locked files automatically; DLL lock errors while the game runs are expected, Lua files still copy). Requires UE4SS + mods.txt entry from the installer.
- **Hot reload:** DISABLED (`EnableHotReloadSystem = 0`). Ctrl+R froze game + mod (tested 2026-09-12). Code changes require a game restart, so batch changes and ship diagnostics (story trace) with each build.
- **Installer:** `powershell -ExecutionPolicy Bypass -File installer\build.ps1` → `build\output\`. Inno Setup 6 script: `installer\SparkingZeroAccess.iss`. Version lives in `VERSION`.

# Coding Principles

- **Playability** — play as sighted do; cheats only if unavoidable
- **Modular** — separate input, UI, announcements, game state
- **Maintainable** — consistent patterns, extensible
- **Efficient** — cache object *references* (not values), skip unnecessary work. Always read live data — never silently show stale cached values
- **Robust** — edge cases, announce state changes
- **Respect game controls** — never override game keys, handle rapid presses
- Logs/comments: English

# Error Handling

- Null-safety with logging: never silent.
- pcall for UE4SS API calls, Reflection, and external calls. Normal code: null-checks.
- Print-based logging via `[AE]` prefix.

# Before Implementation

1. Check `project_status.md` for documented APIs, widget structures, and patterns
2. Use debug dumps (F5) and existing code to discover widget names — there is no decompiled source
3. Files >500 lines: targeted search first, don't auto-read fully

# Session & Context Management

- Feature done → suggest new conversation to save tokens. Update `project_status.md`.
- ~30+ messages or ~70%+ context → remind about fresh conversation.
- Before ending/goodbye → always update `project_status.md`
- Check `project_status.md` for documented APIs and widget structures before exploring code.
- Problem persists after 3 attempts → stop, explain, suggest alternatives, ask user

# References

- `project_status.md` — central tracking, API docs, widget structures (read first!)
- `docs/ACCESSIBILITY_MODDING_GUIDE.md` — code patterns
- `docs/state-management-guide.md` — multiple handlers
- `docs/ue4ss-lua-api-reference.md` — UE4SS Lua API
- `docs/known-issues.md` — known issues

# Debug Tools

Debug dumps live in the game directory: `SparkingZERO\Binaries\Win64\AE_debug\`

Keys in use: F2 = battle announcements toggle (player feature), F3–F8 = debug tools below, F10 = UE4SS console (ConsoleEnablerMod). Pick other keys for new features.

Crash dumps: `crash_*.dmp` in `Win64` are written by UE4SS's crash handler. No debugger is installed; read them with `experiments\mdump.py` and `experiments\threadroots.py` (Python stdlib) from branch `experiment/game-thread-registry`, e.g. `git show experiment/game-thread-registry:experiments/mdump.py`.

- **F5** — Toggle continuous debug dump (250ms, change-only). Appends to `debug_dump.txt`. Each entry includes: focused widget + subtree text, visible widget classes, all visible text on screen. Only writes when focus or visible widgets change. File cleared on game startup, not on toggle.
- **F3** — Battle state dump (`battle_state.txt`, `battle_gauges.txt`)
- **F4** — Character select dump (`chara_select.txt`)
- **F6** — Story map structure dump (`story_map.txt`). Appends one entry per press: every visible widget tree with visibility, positions, switcher pages, bIsActive, textures, text, keyboard focus, and class properties. First press on the story map also writes `chart_actors.txt` (3D map actors + properties)
- **F7** — Toggle story trace (`story_trace.txt`). Every 100ms logs only CHANGED values (mod state, title panel, path characters, guide bar, branch conditions, camera settle points) plus every SPEAK/QUEUE line. Best tool for play-testing: user turns it on, plays, describes what they did
- **F8** — Numbered trace marker (spoken "Marker N"), for the user to flag moments
