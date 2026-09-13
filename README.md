# Sparking Zero Access

A screen reader accessibility mod for **DRAGON BALL: Sparking! ZERO** on PC (Steam).

The mod reads the game's menus, character select, battles, story mode, shop, and online lobbies aloud through your screen reader (NVDA, JAWS, or Windows SAPI). It follows keyboard and controller focus and announces important changes, without altering gameplay or overriding game controls.

## Features

### Menus
- Title screen, main menu, options, and pause menu
- Settings read with label, current value, and description
- Dialogs and help windows announced automatically
- List position ("3 of 12") and tab changes
- Button prompts read as text (for example "Triangle" instead of an icon)

### Character Select
- Character names and DP costs in the roster grid (208 characters supported)
- Team slots with character name, DP cost, and slot number
- Skills with type, name, button combo, cost, and description
- Team overview with total DP
- Both player sides readable

### Battle
- HP, KI, and Sparking gauge changes for you and your opponent
- Skill point changes
- Match timer
- Battle intro skip prompt
- Match results: player level, rank up, rewards, and win streak
- Works in local and online matches
- Press **F2** to turn gauge, skill point, and timer announcements off or on. Match results are still read. The setting resets to on each time the game starts

### Episode Battle (Story Mode)
- Character select with chapter title and story text
- Story map: saga, arc, and chapter names, node navigation, and branch conditions
- Story map paths: announced when you step onto them, with the characters shown and branch conditions
- Details popup: your team, opponents, clear condition, and rewards
- Recap popup: saga name and recap text
- Episode Map: episode title, battle or event, arc, main story or "what if" route, position in the arc, and synopsis
- Cutscene narration and skip prompts

### Shop
- Item names and prices, followed by full descriptions; sold-out, on-sale, and unaffordable items are announced as such
- Category tabs and Zeni balance
- Purchase and purchase complete dialogs

### Online
- Player Match room lobby with player names, status, and win counts
- Room settings and the room sub-menu
- Room ID input with digit-by-digit navigation
- Player join and leave announcements
- Rank Match lobby

## Requirements

- DRAGON BALL: Sparking! ZERO (Steam, PC)
- A screen reader: NVDA (recommended), JAWS, or Windows SAPI. Nothing needs to be installed into the screen reader
- Windows 10 or later (64-bit)

## Installation

### Installer (Recommended)

1. Download `SparkingZeroAccess-Setup-<version>.exe` from the [Releases page](https://github.com/EdgarLozano185519/SparkingZeroAccess/releases).
2. Close the game, run the installer, and accept the Windows administrator prompt.
3. The installer finds the game through Steam, including Steam libraries on other drives. If it can't, press Browse and choose the game folder, the one that contains `SparkingZERO.exe`.
4. Finish the wizard and start the game. On the title screen you should hear "Press confirm to start".

The installer sets up everything the mod needs in the game folder:
- UE4SS v3.0.1 mod loader, configured for this game
- UTOC Signature Bypass, which lets the game load mods
- The speech plugin in `plugins\`, which talks to your screen reader
- The mod itself, enabled in `Mods\mods.txt`. Other UE4SS mods listed there are kept.

### Manual Installation

1. Download `SparkingZeroAccess-<version>-manual.zip` from the [Releases page](https://github.com/EdgarLozano185519/SparkingZeroAccess/releases).
2. Extract it into `SparkingZERO\Binaries\Win64\` inside the game folder, replacing existing files.
3. Start the game. On the title screen you should hear "Press confirm to start".

The zip contains its own `Mods\mods.txt`, which replaces yours. If you use other UE4SS mods, enable them in that file again.

## Updating and Uninstalling

When the installer finds the mod already installed, it asks what to do before the wizard starts:
- **Replace** installs the new version over the existing copy and goes straight to the Ready to Install page.
- **Uninstall** removes the mod and closes setup.
  - For a copy installed by this installer, it also removes UE4SS and the UTOC bypass.
  - For a copy installed another way (manually or with AccessForge), it removes only the mod and its `mods.txt` entry. UE4SS and the bypass stay, since other mods may use them.
- **Cancel** closes setup without changing anything.

You can also uninstall "Sparking Zero Access" from Windows Settings, Apps, Installed apps. Setup and the uninstaller both ask you to close the game first if it's running.

Command-line options:
- `/VERYSILENT` installs without showing the wizard. An existing copy is replaced without asking.
- `/DIR="<game folder>"` uses that game folder instead of detecting it through Steam.

## Troubleshooting

- **No speech in game:** start your screen reader before the game. Then check `SparkingZERO\Binaries\Win64\plugins\SparkingZeroSpeech.log`: it should say "UniversalSpeech loaded", "Pipe server ready" and "Game connected". In `UE4SS.log` in `Win64\`, search for `[AE]`: `[AE] Speech pipe connected` means the mod reached the plugin; `[AE] Speech pipe not available` means the plugin did not load (is `plugins\SparkingZeroSpeech.asi` there, next to `DBSparkingZeroUTOCBypass.asi`?).
- **The installer can't find the game:** press Browse and select the game folder. It contains `SparkingZERO.exe` and a folder named `SparkingZERO`.
- **The game closes on its own:** the speech plugin records every crash. `SparkingZERO\Binaries\Win64\plugins\SparkingZeroSpeech.log` ends with an `EXCEPTION` block (code, module and offset, stack) and a `minidump written` line naming `plugins\AE_crash_<date>_<time>.dmp`. Attach both to a bug report. `UE4SS.log` shows what the mod was doing last (`[AE]` lines).

## Known Issues

- New DLC characters must be added to `chara_names.lua` before their names are read
- Some option values are shown as images instead of text, for example language selection
- The control style selector is a full-screen overlay without keyboard focus, so it isn't read
- Character select: costume and form selection, sort and filter, and team presets aren't read yet
- Battle: the health bar count and transformation count aren't announced yet
- Shop: page navigation isn't read yet; in Customize, only the ability items are read (outfits, CPU settings, emotes and BGM aren't yet)
- Episode Battle: whether a story map episode is cleared or locked isn't read yet
- Episode Battle: the Episode Map's "main story" and "what if" labels are inferred from the map layout and may be wrong for some sagas
- Opening World Tournament (offline mode) crashed the game in versions up to 1.0.1 and in the first main-thread builds. Two causes were found and fixed on 2026-09-13 (see [docs/known-issues.md](docs/known-issues.md)); a retest of World Tournament is pending. If the game closes, `Win64\plugins\SparkingZeroSpeech.log` and the newest `Win64\plugins\AE_crash_*.dmp` show what happened
- A rare crash can still happen while the game loads a screen: the mod's object lookups can meet objects the game is still constructing. This is a limitation of UE4SS 3.0.1; the mod keeps lookups rare

## Development

### Project Structure

- `SparkingZeroAccess/` — the Lua mod, installed to `Mods\SparkingZeroAccess\Scripts`
  - `main.lua` — orchestrator: focus tracking, keybinds, init
  - `game_thread.lua` — runs all mod work on the game thread: `GT.Every`, `GT.After`, `GT.OnKey`, timing logs
  - `objects.lua` — cached `FindAllOf` / `FindFirstOf` per class: rare object walks, one per frame at most, none during battle; detects every garbage collection and drops all cached references (see "SAFETY" in the file)
  - `helpers.lua` — TryCall, TryGetProperty, GetWidgetName, IsValidRef
  - `speech.lua` — Speak and SpeakQueued over the named pipe to the speech plugin
  - `widget_reader.lua` — text reading, widget matching, label resolution
  - `poll_trackers.lua` — dialog, help window, screen change, and room polling
  - `icon_parser.lua` — RichText icon markup to readable text
  - `battle.lua` — battle HUD: HP, KI, Sparking, opponent tracking, match results
  - `episode_battle.lua` — Episode Battle: character select, story map, path nodes, cutscenes
  - `episode_map.lua` — Episode Battle popups: Details, Recap, and the Episode Map overlay
  - `shop.lua` — shop: item grid and item state, categories, purchase dialogs
  - `team_overview.lua` — team setup: slot navigation, character names
  - `chara_roster.lua` — character roster: grid names, skills
  - `chara_names.lua` — texture ID to character name and DP lookup table
  - `skill_list.lua` — skill list overlay reading
  - `debug_tools.lua` — debug dumps and the story trace (F3 to F8)
- `speech_plugin/` — the speech plugin: `SparkingZeroSpeech.c` (named pipe server + UniversalSpeech + crash catcher, built to `SparkingZeroSpeech.asi` by `build.ps1`) and the screen reader libraries `UniversalSpeech.dll`, `nvdaControllerClient.dll`, `ZDSRAPI.dll`, all installed to `Win64\plugins`
- `experiments/` — offline tests (speech pipe, game thread scheduler) and crash dump readers, see [experiments/README.md](experiments/README.md)
- `installer/` — Windows installer
  - `SparkingZeroAccess.iss` — Inno Setup script: game detection, Replace and Uninstall, install and uninstall
  - `build.ps1` — builds the installer and manual zip
- `helpers/` — development scripts, see [helpers/README.md](helpers/README.md)
- `deps/utoc-bypass.zip` — UTOC Signature Bypass, bundled into releases
- `docs/` — modding guide, state management guide, UE4SS API reference, known issues, the 2026-09-12 crash investigation
- `.luacheckrc` — luacheck settings, including the globals UE4SS provides
- `tools/` — local development tools such as `luacheck.exe` (not in git)
- `THIRD-PARTY-NOTICES.txt` — licenses for bundled components
- `VERSION` — current release version
- `project_status.md` — development tracking, widget structures, API notes

### How It Works

All of the mod's work runs on the game's main thread: `game_thread.lua` queues a tick about 60 times a second with UE4SS's `ExecuteInGameThread` and runs the focus poll on every tick and the slower polls (dialogs, battle HUD, story map, shop) in rotating groups. Reading game objects from another thread raced with the game freeing them and crashed it, which is why the older `LoopAsync` design was replaced. Because every UE4SS object lookup walks all objects (about 50 ms), `objects.lua` caches the results per class and walks at most one class per frame, never during a battle. A cached reference is only safe until the engine's garbage collector frees the object (UE4SS 3.0.1 cannot tell a freed object apart), so the cache keeps a throwaway sentinel object, checks it at the start of every tick, and drops every cached reference in the mod the moment a collection has run. When focus moves to a new widget:

1. **Fast path:** check the `WidgetLabels` table for known widget names
2. **Screen-specific handlers:** character select, team overview, skill list, room ID input, and others have dedicated handlers
3. **Generic path:** read widget text through the `caption` property or child TextBlocks
4. **Slow fallback:** a `FindAllOf("TextBlock")` scan filtered by widget path

Speech goes through a named pipe inside the game process: `speech.lua` opens `\\.\pipe\SparkingZeroSpeech` with Lua's file functions and writes one line per announcement (`!` prefix interrupts, `+` prefix queues). `SparkingZeroSpeech.asi`, a small native plugin loaded by the same ASI loader as the UTOC bypass, owns the pipe and speaks the lines through UniversalSpeech. The Lua mod itself loads no DLLs, so it does not depend on UE4SS's Lua build. The plugin also carries a crash catcher: a vectored exception handler that logs any crash in the game process with a stack walk and writes a minidump to `plugins\`, including crashes on the game's main thread that UE4SS's own crash handler never sees.

### Deploying Changes

Run the installer once so UE4SS and the bypass are in place. After changing files in `SparkingZeroAccess/`, copy them into the game:

```
powershell -ExecutionPolicy Bypass -File helpers\Deploy-Mod.ps1
```

Deploying runs the Lua check first and copies nothing if it fails. Pass `-SkipCheck` to deploy anyway. Restart the game afterwards; UE4SS hot reload (Ctrl+R) freezes this game.

### Checking Lua Code

The check catches syntax errors and misspelled or undeclared variables before they cost a game restart:

```
powershell -ExecutionPolicy Bypass -File helpers\Check-Lua.ps1
```

It needs:
- Lua 5.4 for `luac`: `winget install DEVCOM.Lua`
- `luacheck.exe` from the [luacheck releases](https://github.com/lunarmodules/luacheck/releases), saved as `tools\luacheck.exe`

Syntax errors and global variable warnings fail the check. Other warnings are listed; `-Strict` makes them fail too. When the mod starts using another UE4SS global function, add it to `read_globals` in `.luacheckrc`.

### Building the Installer

Requires [Inno Setup 6.3 or newer](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`).

```
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

The script downloads UE4SS v3.0.1 (checked against a pinned SHA256 hash), applies the UE4SS settings the mod needs, and writes `SparkingZeroAccess-Setup-<version>.exe` and `SparkingZeroAccess-<version>-manual.zip` to `build\output\`. The version comes from the `VERSION` file.

The installer also copies the speech plugin from `speech_plugin\` into `plugins\`.

### Building the Speech Plugin

```
powershell -ExecutionPolicy Bypass -File speech_plugin\build.ps1 -Deploy
```

Compiles `speech_plugin\SparkingZeroSpeech.c` with MSVC (Visual Studio 2022 Build Tools with the Windows SDK; MinGW gcc works too) and, with `-Deploy`, copies the plugin and the UniversalSpeech DLLs into the game's `Win64\plugins` folder. The built `.asi` is committed, so the installer can be built without a compiler.

### Releasing

Run the **Release** workflow from the GitHub Actions tab with a version number. It updates `VERSION`, builds the installer and manual zip, and publishes both to a GitHub release.

### Debug Tools

Press **F5** in game to toggle continuous debug dumping. Dumps are written to `SparkingZERO\Binaries\Win64\AE_debug\debug_dump.txt` every 250 ms when something changes. Each entry includes the focused widget with its subtree text, visible widget classes, and all visible text on screen.

Other dumps:
- **F3** — battle state and gauge values
- **F4** — character select texture IDs
- **F6** — story map structure, one entry per press in `story_map.txt`: every visible widget tree with visibility, positions, switcher pages, textures, text, and class properties. The first press on the story map also writes `chart_actors.txt`, the 3D map objects and their properties
- **F7** — turns the story trace on or off. While on, every 100 ms it writes only the values that changed (title panel, path characters, guide bar, branch conditions, camera stops, and the mod's own state) to `story_trace.txt`, along with every line the mod speaks
- **F8** — adds a numbered marker to the story trace, so a tester can flag a moment and describe it later

All dump files are in `SparkingZERO\Binaries\Win64\AE_debug\` and are cleared when the game starts.

### Adding New Characters

When DLC characters are added to the game, `chara_names.lua` needs their texture IDs (format `T_UI_ChThumbP1_XXXX_YY_ZZ`), display names, and DP costs. Run `uv run helpers/Update-CharaNames.py` to regenerate it from the community spreadsheet. See [helpers/README.md](helpers/README.md).

## Credits and Licenses

Sparking Zero Access bundles these third-party components. Full license texts are in [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt), and the installer places a copy in `Mods\SparkingZeroAccess\`.
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1 — MIT License
- [UniversalSpeech](https://github.com/qtnc/UniversalSpeech) by Quentin Cosendey — MIT License
- NVDA Controller Client by [NV Access](https://www.nvaccess.org) — LGPL 2.1
- ZDSR API (`ZDSRAPI.dll`), distributed with UniversalSpeech
- [UTOC Signature Bypass Patch](https://www.nexusmods.com/dragonballsparkingzero/mods/18) by DeathChaos, whose `dsound.dll` is the [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) by ThirteenAG (MIT License)

The installer is built with [Inno Setup](https://jrsoftware.org/isinfo.php).

DRAGON BALL: Sparking! ZERO is developed by Spike Chunsoft and published by Bandai Namco Entertainment. This is a fan-made accessibility mod, not affiliated with either company. It adds files to the game folder but does not change the game's own files or gameplay.
