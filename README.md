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

### Episode Battle (Story Mode)
- Character select with chapter title and story text
- Story map: saga, arc, and chapter names, node navigation, and branch conditions
- Story map paths: announced when you step onto them, with the characters shown and branch conditions
- Details popup: your team, opponents, clear condition, and rewards
- Recap popup: saga name and recap text
- Episode Map: episode title, battle or event, arc, main story or "what if" route, position in the arc, and synopsis
- Cutscene narration and skip prompts

### Shop
- Item names and prices, followed by descriptions
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
- A screen reader: NVDA (recommended), JAWS, or Windows SAPI
- Windows 10 or later (64-bit)

## Installation

### Installer (Recommended)

1. Download `SparkingZeroAccess-Setup-<version>.exe` from the [Releases page](https://github.com/EdgarLozano185519/SparkingZeroAccess/releases).
2. Close the game, run the installer, and accept the Windows administrator prompt.
3. The installer finds the game through Steam, including Steam libraries on other drives. If it can't, press Browse and choose the game folder, the one that contains `SparkingZERO.exe`.
4. Finish the wizard and start the game. On the title screen you should hear "Press confirm to start".

The installer sets up everything the mod needs:
- UE4SS v3.0.1 mod loader, configured for this game
- UTOC Signature Bypass, which lets the game load mods
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

- **No speech in game:** start your screen reader before the game. Then open `UE4SS.log` in `SparkingZERO\Binaries\Win64\` and search for `[AE]`. The line `[AE] Speech bridge loaded!` means speech started; `[AE] Speech bridge failed` is followed by the reason.
- **The installer can't find the game:** press Browse and select the game folder. It contains `SparkingZERO.exe` and a folder named `SparkingZERO`.

## Known Issues

- New DLC characters must be added to `chara_names.lua` before their names are read
- Some option values are shown as images instead of text, for example language selection
- The control style selector is a full-screen overlay without keyboard focus, so it isn't read
- Character select: costume and form selection, sort and filter, and team presets aren't read yet
- Battle: the health bar count and transformation count aren't announced yet
- Shop: page navigation and the Customize screen aren't read yet
- Episode Battle: whether a story map episode is cleared or locked isn't read yet
- Episode Battle: the Episode Map's "main story" and "what if" labels are inferred from the map layout and may be wrong for some sagas

## Development

### Project Structure

- `SparkingZeroAccess/` — the Lua mod, installed to `Mods\SparkingZeroAccess\Scripts`
  - `main.lua` — orchestrator: focus tracking, keybinds, init
  - `helpers.lua` — TryCall, TryGetProperty, GetWidgetName, IsValidRef
  - `speech.lua` — speech init, Speak and SpeakQueued
  - `widget_reader.lua` — text reading, widget matching, label resolution
  - `poll_trackers.lua` — dialog, help window, screen change, and room polling
  - `icon_parser.lua` — RichText icon markup to readable text
  - `battle.lua` — battle HUD: HP, KI, Sparking, opponent tracking, match results
  - `episode_battle.lua` — Episode Battle: character select, story map, path nodes, cutscenes
  - `episode_map.lua` — Episode Battle popups: Details, Recap, and the Episode Map overlay
  - `shop.lua` — shop: item grid, categories, purchase dialogs
  - `team_overview.lua` — team setup: slot navigation, character names
  - `chara_roster.lua` — character roster: grid names, skills
  - `chara_names.lua` — texture ID to character name and DP lookup table
  - `skill_list.lua` — skill list overlay reading
  - `debug_tools.lua` — debug dumps and the story trace (F3 to F8)
  - `speech_bridge.dll` — Lua C module bridging to UniversalSpeech
  - `UniversalSpeech.dll`, `nvdaControllerClient.dll`, `ZDSRAPI.dll` — screen reader libraries
- `speech_bridge/` — speech bridge source, see [speech_bridge/README.md](speech_bridge/README.md)
- `installer/` — Windows installer
  - `SparkingZeroAccess.iss` — Inno Setup script: game detection, Replace and Uninstall, install and uninstall
  - `build.ps1` — builds the installer and manual zip
- `helpers/` — development scripts, see [helpers/README.md](helpers/README.md)
- `deps/utoc-bypass.zip` — UTOC Signature Bypass, bundled into releases
- `docs/` — modding guide, state management guide, UE4SS API reference, known issues
- `.luacheckrc` — luacheck settings, including the globals UE4SS provides
- `tools/` — local development tools such as `luacheck.exe` (not in git)
- `THIRD-PARTY-NOTICES.txt` — licenses for bundled components
- `VERSION` — current release version
- `project_status.md` — development tracking, widget structures, API notes

### How It Works

The mod polls for keyboard focus changes every 16 ms using UE4SS's `LoopAsync`. When focus moves to a new widget:

1. **Fast path:** check the `WidgetLabels` table for known widget names
2. **Screen-specific handlers:** character select, team overview, skill list, room ID input, and others have dedicated handlers
3. **Generic path:** read widget text through the `caption` property or child TextBlocks
4. **Slow fallback:** a `FindAllOf("TextBlock")` scan filtered by widget path

Speech goes through `speech_bridge.dll`, a Lua C module that statically links Lua 5.4 and loads UniversalSpeech at runtime.

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

### Releasing

Run the **Release** workflow from the GitHub Actions tab with a version number. It updates `VERSION`, builds the installer and manual zip, and publishes both to a GitHub release.

### Building the Speech Bridge

See [speech_bridge/README.md](speech_bridge/README.md). It needs MinGW-w64 and the Lua 5.4.7 source.

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
- [Lua](https://www.lua.org) 5.4.7, built into `speech_bridge.dll` — MIT License
- [UniversalSpeech](https://github.com/qtnc/UniversalSpeech) by Quentin Cosendey — MIT License
- NVDA Controller Client by [NV Access](https://www.nvaccess.org) — LGPL 2.1
- ZDSR API (`ZDSRAPI.dll`), distributed with UniversalSpeech
- [UTOC Signature Bypass Patch](https://www.nexusmods.com/dragonballsparkingzero/mods/18) by DeathChaos

The installer is built with [Inno Setup](https://jrsoftware.org/isinfo.php).

DRAGON BALL: Sparking! ZERO is developed by Spike Chunsoft and published by Bandai Namco Entertainment. This is a fan-made accessibility mod, not affiliated with either company. It adds files to the game folder but does not change the game's own files or gameplay.
