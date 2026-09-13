# Helpers

Scripts for maintaining mod data and testing. Python scripts run with [uv](https://docs.astral.sh/uv/).

## Deploy-Mod.ps1

Copies `SparkingZeroAccess/` into the game's `Mods\SparkingZeroAccess\Scripts\` folder for testing. Finds the game through Steam, or pass `-GameDir`. Retries files the running game has locked.

```
powershell -ExecutionPolicy Bypass -File helpers\Deploy-Mod.ps1
```

Run the installer once first so UE4SS, the UTOC bypass, and the `mods.txt` entry are in place.

Before copying, it runs `Check-Lua.ps1` and stops if the check fails. Pass `-SkipCheck` to deploy without it. Restart the game after deploying; UE4SS hot reload (Ctrl+R) freezes this game.

## Check-Lua.ps1

Checks every Lua file in `SparkingZeroAccess/`:
1. `luac -p` syntax check
2. `luacheck` lint using `.luacheckrc` in the repo root

```
powershell -ExecutionPolicy Bypass -File helpers\Check-Lua.ps1
```

- Fails on syntax errors and on global variable warnings (W111, W112, W113). In Lua, a misspelled name or a missing `local` silently becomes a global, so these are almost always bugs.
- Other warnings, such as unused variables, are listed but don't fail. `-Strict` makes them fail too. `-Quiet` prints only problems and the result.

Requirements:
- Lua 5.4: `winget install DEVCOM.Lua` (the script also finds it in `%LOCALAPPDATA%\Programs\Lua\bin`)
- `tools\luacheck.exe` from the [luacheck releases](https://github.com/lunarmodules/luacheck/releases). The `tools/` folder is not in git.

## Switch-UE4SS.ps1

Installs the experimental UE4SS build or restores 3.0.1 in the game, without touching `mods.txt` or the mod folder. Refuses to run while the game is running.

```
powershell -ExecutionPolicy Bypass -File helpers\Switch-UE4SS.ps1 -Build experimental
powershell -ExecutionPolicy Bypass -File helpers\Switch-UE4SS.ps1 -Build stable
powershell -ExecutionPolicy Bypass -File helpers\Switch-UE4SS.ps1 -Status
```

- `experimental` copies `UE4SS.dll` and the default mods from the newest `build\stage\ue4ss-experimental-*` folder (the extracted experimental zip) and writes `UE4SS-settings.ini` from that build's template with the mod's settings. The 3.0.1 `dwmapi.dll` proxy stays; it loads `UE4SS.dll` from the same folder.
- `stable` restores `dwmapi.dll`, `UE4SS.dll`, the settings, and the default mods from `build\backup\ue4ss-3.0.1`.

## Build-NvdaAddon.ps1

Packages `nvda-addon\` into `build\output\SparkingZeroAccess-<version>.nvda-addon`, with the version from `VERSION`. Install it by pressing Enter on the file with NVDA running, then restart NVDA.

```
powershell -ExecutionPolicy Bypass -File helpers\Build-NvdaAddon.ps1
```

## Update-CharaNames.py

Pulls character texture IDs and names from the [community Google Sheet](https://docs.google.com/spreadsheets/d/177M1Uro7EtHebWKhYr8-P4D62jLuhEl7JLCVHirWFbE) and generates `SparkingZeroAccess/chara_names.lua` — the lookup table that maps texture IDs to display names and DP costs.

```bash
uv run helpers/Update-CharaNames.py
```

Run this when new characters are added to the game (DLC) or when the community sheet is updated.

## build_dp_table.py

Standalone DP cost table used as a data source by Update-CharaNames.py. Contains manually maintained DP values from ScreenRant and Fandom wiki sources.

```bash
uv run helpers/build_dp_table.py
```
