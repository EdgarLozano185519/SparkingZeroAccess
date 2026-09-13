# Project Status — Dragon Ball Sparking! ZERO Accessibility Mod

## Project Info
- **Game:** Dragon Ball Sparking! ZERO
- **Engine:** Unreal Engine 5, 64-bit
- **Game path:** C:\Program Files (x86)\Steam\steamapps\common\DRAGON BALL Sparking! ZERO
- **Mod framework:** UE4SS v3.0.1 (dev) + UTOC Signature Bypass
- **Speech library:** UniversalSpeech (via custom Lua C module bridge)
- **Screen reader:** NVDA (confirmed working)
- **User familiarity:** Knows the game well (menus, mechanics)

## Setup Status
- [x] Game installed and first-run complete
- [x] UE4SS: experimental build UE4SS_v3.0.1-1133-gb4cefa18 installed since 2026-09-12 (helpers\Switch-UE4SS.ps1; 3.0.1 backup in build\backup\ue4ss-3.0.1). UNTESTED with the pipe speech mod
- [x] UTOC Signature Bypass installed (dsound.dll + plugins\DBSparkingZeroUTOCBypass.asi)
- [x] UE4SS settings configured (bUseUObjectArrayCache=false, GraphicsAPI=dx11)
- [ ] Hot reload — tried 2026-09-12, Ctrl+R froze game + mod. Disabled again (EnableHotReloadSystem=0). Likely cause: LoopAsync loops / native hooks / speech DLL not surviving mod restart. Restart game after deploys
- **Controller:** user plays with a DualShock 4
- [x] Speech: named pipe to the NVDA add-on (nvda-addon\, installed in %APPDATA%\nvda\addons\SparkingZeroAccess) since 2026-09-12. speech_bridge.dll + UniversalSpeech/NVDA client/ZDSR DLLs retired. Offline pipe test passes; UNTESTED in game
- [x] SparkingZeroAccess Lua mod created and registered in mods.txt
- [x] Inno Setup installer replaces AccessForge (2026-09-12) — see "Distribution / Installer"
- [x] Lua dev tooling (2026-09-12): Lua 5.4.6 (winget DEVCOM.Lua, luac -p) + tools\luacheck.exe 1.2.0 (gitignored) + .luacheckrc + helpers\Check-Lua.ps1. Deploy-Mod.ps1 runs the check first. First run found: battle.lua Battle.Reset() cleared old undeclared enemy vars instead of _enemyState, so opponent HP/KI state leaked into the next battle (fixed: _enemyState = {}; UNTESTED in battle), and allTB/allRTB scope bug in F5 dump (fixed). 28 non-blocking warnings remain (unused vars/imports, shadowing) — cleanup candidate

## IN PROGRESS (2026-09-13, early morning) — native speech plugin + object registry on UE4SS 3.0.1

User feedback: the experimental UE4SS build did not start the game, and NO NVDA add-on (users should not have to install one). Direction: option 3, native code.

Verified by launching the game from scripts (Launch-Game.ps1 in the session scratchpad, Steam URL + log watching):
- Experimental UE4SS (gb4cefa18) kills the game ~3 s after mods start EVEN WITH THE MOD DISABLED, no dump, no Windows error (game-thread crash inside UE's guarded main = silent exit). Unusable on this game. Restored 3.0.1 (Switch-UE4SS -Build stable)
- Speech now: `speech_plugin\SparkingZeroSpeech.asi` (plain C, MSVC, built by speech_plugin\build.ps1 -Deploy) loaded by the Ultimate ASI Loader (dsound.dll, already installed for the UTOC bypass) from Win64\plugins\, together with UniversalSpeech.dll + nvdaControllerClient.dll + ZDSRAPI.dll there. It serves the pipe `\\.\pipe\SparkingZeroSpeech` (speech.lua renamed to match) and speaks via UniversalSpeech. Log: plugins\SparkingZeroSpeech.log. WORKS (game connected, startup dialogs and "Press confirm to start" logged). NVDA add-on removed from the repo and from %APPDATA%\nvda\addons
- 3.0.1 + game_thread.lua (LoopAsync + ExecuteInGameThread fallback) + plugin: game ran 110 s, no crash, but the reader tick averages 36 ms (max 210) because every poll does a FindAllOf walk (47–50 ms each on the game thread)
- Probes (game thread, title screen, 811 live UserWidgets of 1624): FindAllOf(UserWidget) 47 ms; GetFullName 3 µs/obj; IsVisible / HasKeyboardFocus 7 µs/obj (6 ms per full scan); IsValid ~0; only 6 widgets visible. BindWidget properties work: `widget.RichText_MainTalk` returns the child widget directly (unknown property returns an invalid UObject, check IsValid)
- Dead ends on 3.0.1: UFunctions with out params (GetAllWidgetsOfClass, GetViewportSize...) are broken in 3.0.1's Lua (out-param table stays on the stack, array out params never pushed); NotifyOnNewObject runs Lua unlocked on the constructing thread; zDEV-UE4SS_v3.0.1.zip has no C++ SDK (UE4SS.dll does export LuaType/LuaMadeSimple/Hook symbols, so a C++ mod remains possible with a generated import lib and repo headers)
- Game-owned widget refs found: SSBattlePlayerController.TextAreaUi / TextAreaUiMainMenu (speech bubble WBP_OBJ_Common_TexWin_Black_C) / TextAreaUiMainMenuSet / GuideWidget / PauseManager / MenuGeneralDialog / HelpDialog / PlayerInfoWidget ... (most nil on the title screen); SSMenuManager base class has LastFocusedWidget; GameInstance has MenuInterruptManager, NotificationManager, WaitingIconManager
- Plan being implemented: objects.lua registry (one FindAllOf("Widget") + FindAllOf("Actor") walk at startup, after PlayerController:ClientRestart, on explicit request, or on a miss rate-limited to 3 s and never while battle is busy); FindAllOf/FindFirstOf globals overridden in main.lua to serve from the cache

## Session Handoff (2026-09-12, night) — Pipe Speech + Game Thread on Experimental UE4SS (SUPERSEDED, see above)

Branch: `feature/pipe-speech-game-thread` (not merged into main until the in-game test passes). Everything below is deployed to the game and to NVDA already; nothing has been run in the game yet.

What changed:
- Speech: speech_bridge.dll and the UniversalSpeech/NVDA client/ZDSR DLLs are gone from the mod. `speech.lua` writes one line per announcement to the named pipe `\\.\pipe\SparkingZeroAccess` with plain Lua `io.open` (`!text` = interrupt, `+text` = queue, UTF-8). Reconnects every 3 s when the server is missing, once immediately on a failed write, otherwise drops and counts (logged)
- NVDA add-on `nvda-addon\` (manifest.ini + globalPlugins\sparkingZeroAccess.py): ctypes named pipe server thread, speaks through queueHandler + speech.cancelSpeech + ui.message. Has an unbound "Reports whether the Sparking Zero Access game mod is connected" script (Input Gestures, category "Sparking Zero Access"). Installed copy: `%APPDATA%\nvda\addons\SparkingZeroAccess` (copied there directly, NVDA 2026.2). Package: `helpers\Build-NvdaAddon.ps1` → `build\output\SparkingZeroAccess-1.0.1.nvda-addon`
- Game thread: `game_thread.lua` from branch experiment/game-thread-registry (GT.Every / GT.After / GT.OnKey, timing logs). main.lua: one reader tick (focus every tick, slow polls in 8 rotating groups), no LoopAsync loops or watchdog, F2 through GT.OnKey; debug_tools F3–F8 and its loops through GT; poll_trackers/main delays through GT.After; team_overview reads hold captions directly (no ExecuteInGameThread, SetText hook removed). The objects.lua registry from that branch was NOT taken (reverse-migrated back to plain FindAllOf/FindFirstOf; on experimental UE4SS lookups use hash tables)
- UE4SS: experimental build UE4SS_v3.0.1-1133-gb4cefa18 installed in the game with `helpers\Switch-UE4SS.ps1 -Build experimental` (UE4SS.dll + default mods + settings from build\stage\ue4ss-experimental-20260912-223014, 3.0.1 dwmapi.dll proxy kept, mods.txt untouched). `-Build stable` restores 3.0.1 from build\backup
- luacheck: LoopAsync/ExecuteWithDelay/ExecuteInGameThread/RegisterKeyBind only allowed in game_thread.lua
- Offline tests pass: experiments\test_game_thread.lua, test_game_thread_native.lua, Test-SpeechPipe.ps1 (speech.lua ↔ the add-on's real server code with NVDA stubbed)
- Docs updated: README, CLAUDE.md, docs/known-issues.md, docs/ue4ss-lua-api-reference.md, helpers/README.md, experiments/README.md, THIRD-PARTY-NOTICES.txt (only UE4SS + bypass left), speech_bridge/README.md (retired)

Test plan (user):
1. Restart NVDA (NVDA+Q, Restart) so the add-on loads. Optional: Tools → Add-on store → Installed add-ons should list "Sparking Zero Access speech"
2. Start the game. Expect the usual startup dialogs and "Press confirm to start". If silent: NVDA log (NVDA+F1) should have "Sparking Zero Access: pipe server started"; UE4SS.log should have "[AE] Speech pipe connected" and "[AE] Game thread scheduler started (LoopInGameThreadWithDelay)"
3. Title → main menu a few times, a battle (F2 off/on), the result screen, then World Tournament (the crash case), story map, shop. Note any stutter or slower menu reading compared with before
4. Afterwards keep UE4SS.log: lines to look at are "[AE] Slow game thread task", "[AE] Game thread 60s:" summaries, and any "[AE] ... error"

If it fails:
- Game closes at startup or no [AE] lines: `helpers\Switch-UE4SS.ps1 -Build stable` (the mod also runs on 3.0.1 through LoopAsync + ExecuteInGameThread, slowly), or full revert: `git checkout main`, `helpers\Deploy-Mod.ps1`, `Switch-UE4SS.ps1 -Build stable`
- NVDA misbehaves: delete `%APPDATA%\nvda\addons\SparkingZeroAccess` and restart NVDA

Open follow-ups after a successful test:
1. Merge the branch, bump VERSION (1.1.0), tag
2. Installer: ship the experimental UE4SS (pin the zip in deps\, it is a rolling GitHub asset; keep the tested flat layout with the 3.0.1 dwmapi.dll or test the experimental proxy with its `ue4ss\` subfolder), build the .nvda-addon in the release workflow
3. Standalone pipe speech helper (C#/.NET Framework with csc.exe, or C) using UniversalSpeech for JAWS/SAPI users; it would serve the same pipe when NVDA's add-on is not running
4. Transition signal: hook PlayerController:ClientRestart to reset state on world changes (LoadMap hooks never fire in this game)
5. Story map node status, luacheck warning cleanup (still 28)

## Session Handoff (2026-09-12, late) — World Tournament Crash Investigation + F2 Toggle

Summary:
- Crash when opening World Tournament (also title → main menu): the Win64\crash_*.dmp files are written by UE4SS's crash handler. The readable dumps show access violations inside UE4SS.dll on the mod's LoopAsync thread, never on the game thread. The mod's async polling reads widgets while the game frees them on screen changes that are not map loads, so the LoadMap pause does not cover them
- Four fixes tried and parked on branch experiment/game-thread-registry (full write-up in that branch's project_status.md, "Crash Investigation"; dump readers and offline tests in its experiments\ folder):
  1. All polling on the game thread (LoopAsync timer + ExecuteInGameThread): no new crashes, but every FindAllOf/FindFirstOf walks all objects (~45 ms each), game much slower
  2. bUseUObjectArrayCache = true: lookups still slow, loading very slow. Keep false
  3. NotifyOnNewObject registry instead of walks: game closed to desktop more often (on UE4SS 3.0.1 those callbacks run Lua on loading threads)
  4. UE4SS experimental build (engine tick scheduling, callbacks queued to the game thread): game closes at startup, because its bundled Lua is modified with thread locks and speech_bridge.dll (static vanilla Lua) breaks. UE4SS exports no Lua C API, so speech on it would need a UE4SS C++ mod
- Restored: UE4SS 3.0.1 (backup build\backup\ue4ss-3.0.1, hash-verified) and the last committed mod, plus the F2 toggle
- New: F2 turns battle HUD announcements (timer, HP, KI, Sparking, skill points, enemy gauges) off/on, spoken "Battle announcements off/on". Not saved (on at every launch). Tracking continues silently while off, so nothing is replayed. Result screen unaffected
- Verified UE4SS threading facts added to docs/ue4ss-lua-api-reference.md

Test results (user, 2026-09-12, restored build):
- [x] Game starts and reads as before (UE4SS 3.0.1 restored)
- [x] F2 off in battle works (log "Battle HUD announcements off"); the result screen was still read afterwards
- [ ] F2 back on: new gauge changes announced again (not tried yet) — ask when continuing
- [ ] F2 in menus: the game does nothing unexpected (not confirmed) — ask when continuing
- World Tournament still crashes the restored build (fatal error). Dump crash_2026_09_13_03_52_46.dmp: ACCESS_VIOLATION reading 0x40 at UE4SS.dll+0x4BDDAE on the mod's LoopAsync thread (thread entry UE4SS.dll+0x39528F), the same crash address as the original 2026-09-13 00:38 dump. It came 23 s after the result screen was read (log 03:52:23, dump 03:52:46 UTC)

Crash findings (2026-09-12, follow-up session, read-only analysis):
- Dump crash_2026_09_13_03_52_46: rax=0x40, rdi=0, AV reading address 0x40. UE4SS.log offsets: UStruct::SuperStruct = 0x40. So the async FindAllOf/FindFirstOf walk called IsA/IsChildOf on an object whose ClassPrivate was already null (object being destroyed). Same address in all readable dumps; faulting thread root UE4SS.dll+0x39528F = a Lua mod async thread (7 such threads = 7 Lua mods)
- The LoadMap guard never fires in this game: UE4SS.log has "Map loaded, resetting state" once (startup) and never "Map load starting", although the battle loaded /Game/SS/Maps/Korat_P and the crash transition happened. The game must use seamless/level-streaming transitions, so RegisterLoadMapPreHook/PostHook give no protection at all
- The crash second (03:52:46 UTC) is exactly when CheatManagerEnabler's PlayerController:ClientRestart hook fired (new PlayerController = new world). ClientRestart is a usable transition signal on 3.0.1; earlier candidates to test: PlayerController:ClientTravel, RegisterInitGameStatePreHook
- After the crash the game kept running for 5 min (more ClientRestart lines, no [AE] lines): only the mod's async thread died; the UE crash dialog blocked the process later
- UE4SS 3.0.1 CppUserModBase has on_update() and on_lua_start(mod_name, lua, main_lua, async_lua, hook_luas), so a C++ mod can register Lua globals in our mod's state (speech without speech_bridge.dll). Visual Studio 2022 is installed; no gcc on PATH any more
- Alternative speech transport without any C linkage: Lua io.open on a named pipe (\\.\pipe\...) to a small companion speech process or NVDA add-on. Would make the experimental UE4SS build usable (its only failure was speech_bridge.dll)

Next steps (user decides):
1. World Tournament crash. Options: (a) narrow mitigation on UE4SS 3.0.1: find what opening World Tournament does to widgets (e.g. an F6 dump right before opening it, UE4SS.log timing) and pause polling around that transition; (b) move speech to a UE4SS C++ mod, then switch to a newer UE4SS where the experiment branch's game thread design can work
2. Story map node status (cleared / locked), from the previous handoff below
3. Clean up the 28 non-blocking luacheck warnings
The older pending tests in the previous handoff below (story map paths, Episode Map, Details popup, F6/F7/F8, battle Reset fix) are still unanswered.

Tools and local files:
- Crash dump reader: experiments\mdump.py and threadroots.py on branch experiment/game-thread-registry (git show experiment/game-thread-registry:experiments/mdump.py). Python 3 stdlib only; no debugger is installed
- Branch experiment/game-thread-registry is local only (not pushed)
- Not in git (build\ is ignored): build\backup\ue4ss-3.0.1 (UE4SS 3.0.1 backup: dwmapi.dll, UE4SS.dll, UE4SS-settings.ini, Mods), build\cache\UE4SS_v3.0.1-1133-gb4cefa18.zip (experimental UE4SS, SHA-256 89B7EED47C37D6FF6EAA144A41311A75098279A3454777F4EDD2446CEA1EA7A8), build\stage\ue4ss-experimental-* (extracted copy)
- VERSION unchanged (1.0.1); F2 is not in a release yet

## Session Handoff (2026-09-12) — Story Map Accessibility + Dev Tooling

Done this session:
- F6 story map dumps revealed the popup and Episode Map structures (see "Story Map Popups & Episode Map" below)
- episode_map.lua (new): Details popup (your team, opponents, clear condition, rewards), Recap popup (saga + recap text), Episode Map overlay (title, Battle/Event, arc + main/"what if" route, "Episode X of Y", synopsis, saga switch). User confirmed Details and Recap read as expected
- episode_battle.lua: returning to an episode from a path node is announced again (title visibility, not text); "???" titles say "Unknown episode"; path nodes announce "Path", the characters shown (OtherCharaIcon portraits), and branch conditions, and re-announce when the portraits change (path to path movement)
- User learned: Episode Battle first screen = character list (up/down), left/right = Continue / Story Map / New Game buttons (already read correctly)
- Debug tools: F6 widget-tree dump (switcher page, bIsActive, chart_actors.txt on first press), F7 story trace (story_trace.txt, change log + spoken lines), F8 markers
- UE4SS hot reload tried and disabled again (Ctrl+R froze the game)
- Lua dev tooling: Lua 5.4.6 + luacheck 1.2.0, helpers\Check-Lua.ps1, run automatically by Deploy-Mod.ps1
- luacheck found and fixed: battle.lua Battle.Reset() never cleared _enemyState (opponent HP/KI state leaked into the next battle); F5 dump allTB/allRTB scope bug

Pending tests (user) — ask for results when continuing:
- [ ] Path to path movement announces "Path" + characters + conditions (e.g. Piccolo's Saga chapter 2, press left on a path node). Do the portrait character names make sense for each path?
- [ ] Episode Map overlay while moving: title, Battle/Event, arc, "Episode X of Y", synopsis; saga switching. Are "main story" / "what if" correct (Vegeta's Saga: Parental Bond, Number One Spot = what if?)
- [ ] Details popup: "Your team" really lists the player's side
- [ ] F7 trace writes story_trace.txt (changes, SPEAK/QUEUE lines, camera settled lines); F8 markers appear
- [ ] F6 on the story map says "Map objects saved" and writes chart_actors.txt
- [ ] Battle: opponent HP announcements still work across consecutive battles and rematches (Reset fix)

Next steps:
1. Read the user's story_trace.txt and chart_actors.txt: find cleared / unlocked / locked state of 3D chart nodes (user priority: "where to go next, what's locked")
2. Announce node status on the story map, possibly a "next unplayed episode" hint
3. Clean up the 28 non-blocking luacheck warnings (unused imports and variables, shadowing)

## Phase 1: UI Exploration (DONE)
- [x] First UI dump completed (F10 / SparkingZeroAccess_dump.txt)
- UE5 built-in accessibility system: NOT available (compiled out)
- 688 TextBlocks, 487 RichTextBlocks — text is readable from widgets
- Game uses standard UMG widgets (TextBlock, Button, WidgetSwitcher, etc.)
- Game HUD: SSMainGameHUD, GameInstance: BP_SSGameInstance_C
- Key widget classes identified:
  - WBP_Title_C — title screen
  - WBP_Title_Button_C / WBP_Title_Button_PC_C — title buttons
  - WBP_Option_C — options menu
  - WBP_BTN_PauseMenu_C — pause menu buttons
  - WBP_Dialog_000_C / WBP_Dialog_002_C — dialogs
  - WBP_MainMenu_Base_TextSub_C — main menu text
  - WBP_OBJ_Option_List_* — option list items

## Phase 2: Menu Accessibility (IN PROGRESS)
- [x] Focus detection via HasKeyboardFocus() — works with both keyboard and controller
- [x] Title screen navigation (Start/Options/Quit) — labels spoken on focus change
- [x] Auto-dismiss dialog text reading (via RichTextBlock Text_Main_0, tracks text changes)
- [x] Main menu navigation — sub-button captions read via "caption" property
- [x] Main menu description text — TXT_GuideMessage queued after button label
- [x] Main menu tab suppression — WBP_MainMenu_Base_C / ModeMenu_C suppressed
- [x] Stage/BGM/Settings select — HitBtn_Text_XX mapped to BS_BTN_Menu_DP_XX captions
- [x] List header announcements — Text_Title tracked, announced on L1/R1 tab switch
- [x] SpeakQueued for non-interrupting speech (descriptions after labels)
- [x] Help window dismiss — queues "Press Back to close" after body text
- [x] List position announcements — "X of Y" for stage, BGM, and rule settings lists
- [x] Dialog button ordering — dialog header + body spoken before button label on open
- [x] Options menu setting names — Title/TitleText/TXT_Label read for setting labels (class-gated, no perf impact)
- [x] Options menu tips — TEXT_TipsMain read via FindAllOf (class-gated to Option_List widgets only)
- [x] Online: Room ID input — digit position, value, change announcements (cached refs for all 9 panels)
- [x] Key binding values — RichTextBlock caption inside ChangeKey child widgets
- [x] Icon markup parser — converts glyph tags to readable text (keys, PS/Xbox buttons)
- [x] Title screen "Press any button" — WBP_Title_C tracked in screen changes
- [x] Code split into modules — helpers, speech, widget_reader, poll_trackers, icon_parser
- [x] Character select: roster grid — character name + DP via texture ID lookup (rewritten 2026-03-29)
- [x] Character select: team slot numbers — "Slot 1" through "Slot 5" announced
- [x] Character select: skill slots — skill name with type prefix (Blast/Ultimate)
- [x] Character select: Switch/Remove/Switch View buttons via WidgetLabels
- [x] Character select: team slot character names — via IMG_Face_Main texture ID + lookup table
- [x] Character select: team slot DP values — calculated from static lookup table (208 chars)
- [x] Character select: character DP cost per slot — announced with character name
- [x] Character select: team overview guide bar — shortcuts announced on first entry
- [x] Character select: hold buttons (Start Battle, Return to Main Menu) — game-thread caption read
- [x] Skill list overlay — name, button combo, cost, description (skill_list.lua, works in roster + pause)
- [ ] Character select: costume/form selection within a character
- [x] Character select: 2P/CPU side team reading — R1 switches sides, full slot reading
- [ ] Character select: sort/filter overlay reading
- [ ] Character select: team presets reading
- [ ] Options: "Battle Assist" false title match on ControlButton
- [ ] Options: Language values shown as images, not text
- [ ] Options: Control style selector (full-screen overlay, no keyboard focus)
- [ ] Stage variant detection — arrow widgets identical for variant/no-variant stages
- [ ] HitBtn_Text_05 has no matching SetRuleBTN_05 on some settings screens
- [x] Pause menu navigation — WidgetLabels fast path, instant response
- [x] In-battle HUD — HP % thresholds (75/50/25/10), KI bars, Sparking activation/countdown
- [x] In-battle skill points — BlastStockCount changes announced
- [x] In-battle opponent tracking — all enemy pawns HP/KI/Sparking announced
- [x] In-battle enemy Sparking — activation, countdown, ended
- [x] Online: player pawn detection — camera controller + player side from team overview (see notes below)
- [x] In-battle match result screen — player level, rank up, rewards, win streak (polled via WBP_GRP_BS_Result_03_DP_C visibility)
- [ ] In-battle HP bar count — big number at bottom corners (remaining health bar layers, separate from HP %)
- [ ] In-battle transformation count — small number with up-arrow next to KI (available transformations for current character, CharaNum in StyleIcon_Timer)
- [x] Battle intro — skip shortcut announced
- [x] Title screen — "Loading" on logo, "Press confirm to start" with 1s delay
- [x] Icon parser — full PS/Xbox mappings, Triangle/Square fix, Left Stick vs D-Pad fix
- [x] In-battle timer — texture-based digit reading from WBP_Rep_TimerNum widgets, parent visibility check for hidden digits
- [x] Online: room settings labels read (Rank, Battle Rules, Time, etc.)
- [x] Online: Player Match room lobby — player panels with slot/name/status/wins
- [x] Online: room guide bar announced (Sub-menu, Show/Hide Room ID, Leave Room)
- [x] Online: room ID toggle detection — announces real ID when shown
- [x] Online: player status/join/leave polling in room lobby
- [x] Online: Sub-menu (Triangle) — Player Card, Training, Invite, Disband, Kick, etc.
- [x] Online: Rank Match lobby (basic navigation done; status changes after opponent joins still TODO)
- [x] Episode Battle: character select — character name (CaracterText_0), chapter title, story text, button captions (Continue/Story Map/New Game)
- [x] Episode Battle: character select guide bar — announced on first entry
- [x] Episode Battle: story map — saga/arc/chapter announced on entry with ~100ms delay (avoids Japanese placeholder text)
- [x] Episode Battle: story map node navigation — Text_EventTitle polled for changes, "???" filtered
- [x] Episode Battle: story map guide bar — Start, Back, Details, Recap, Change Difficulty, Episode Map
- [x] Episode Battle: path node detection — guide button count drop triggers "Path" + branch conditions
- [x] Episode Battle: branch conditions — visible WBP_OBJ_AI_BranchConditons_Set_C read with position + locked status
- [x] Episode Battle: cutscene skip — "Hold confirm to skip" announced when WBP_GRP_AI_EventSkip_C appears
- [x] Episode Battle: cutscene narration — RichText_MainTalk polled, only spoken when no Text_CharaName (voice-acted dialog skipped), "Press confirm to continue" icon queued after
- [x] Episode Battle: cutscene skip/next icons — raw icon markup passed through SpeakQueued for icon parser handling
- [x] Shop: top screen — Shop/Customize buttons via WidgetLabels
- [x] Shop: item grid — name + price for S-type (ability items) and L-type (characters/outfits/voices)
- [x] Shop: item descriptions — queued after item, filtered for duplicates and useless fragments
- [x] Shop: category tabs — announced on first entry and polled for L1/R1 changes
- [x] Shop: Zeni balance — announced on first entry
- [x] Shop: purchase dialog — header, item, price, balance after, button label (tracks header for dedup)
- [x] Shop: purchase complete dialog — detected via header text change
- [ ] Shop: page navigation — pager items visible but not yet announced
- [ ] Shop: customize screen — not yet explored
- [ ] Episode Battle: consecutive path nodes (UNTESTED fix 2026-09-12) — only signal is ChartTitle WBP_OBJ_AI_OtherCharaIcon_N portrait textures (e.g. Piccolo saga ch.2: Frieza 4th Form -> Goku (Super)). Path announced on entry + on portrait signature change: "Path", characters, conditions. Portrait meaning unconfirmed
- [ ] Debug: F7 story trace + F8 markers + chart_actors.txt (UNTESTED 2026-09-12) — verify trace output, then use chart_actors.txt to find node cleared/locked state
- [ ] Episode Battle: story map "Close" (Square) toggle — outline panel visibility toggle, not yet handled
- [ ] Episode Battle: story map navigation (user priority, 2026-09-12) — user is stuck on "where to go next". Needed:
  - Per-episode status: cleared / unlocked / locked
  - Main story vs "What If" route indicator (color-coded in game; find texture/color source)
  - Triangle/Square popup with episode info — not read
  - D-pad left/right on an episode — behavior unknown, investigate
- [x] Debug: F6 story map dump (debug_tools.lua) — all top-level widget trees, now also switcher activeIndex + bIsActive
- [ ] Episode Battle: episode_map.lua (2026-09-12, UNTESTED) — Details popup (team, clear condition, rewards), Recap popup, Episode Map overlay (title, Battle/Event, arc + main/"what if" route guess, episode X of Y, synopsis, saga switch). Needs in-game test; verify left team box = player team, row 00 = main story, cursor via Overlay_Cursor opacity
- [ ] Episode Battle: 3D chart node status (cleared/locked) — nodes are level actors, not widgets; needs actor property exploration (F7 candidate)
- [ ] PS4 icon table — separate from PS5, only Pad_05=Cross mapped so far. More mappings needed as discovered
- [ ] skill_list.lua line 117 — `table.insert` crash: "bad argument #2 (number expected, got string)". Pre-existing bug, investigate next session
- [ ] In-battle victory screen — removed (too many false triggers from intro dialogue TextWindow; player knows win/loss from gameplay)
- [ ] Character select: locked character detection — lock is purely visual (icon overlay), no text signal. Need to probe CharaIcon widget properties

### Online Player Pawn Detection — SOLVED (2026-04-05)
**Problem:** When player 2 (invited player), own HP/KI announced as "Enemy" and opponent's as own.
**Root cause:** In online matches, 3 BP_BattlePlayerController_C instances exist. Both active pawns have different controllers but both claim `IsLocalController()=true`. `IsLocallyViewed()` works for P2 but inverts for P1. The camera controller's Pawn is always the P1-side character.
**Solution:** Two-part approach:
1. **Player side detection:** Team overview sets `_playerSide` ("1P" or "2P") on first focus entry. Only the first value is accepted (browsing opponent's team won't overwrite). Reset when re-entering character select from a non-team screen.
2. **Pawn identification:** Find the controller whose `GetViewTarget()` is `BP_DirectorMainCamera_C` — its `.Pawn` is always the P1-side character. If we're P1, use that pawn. If we're P2, use that pawn's `TargetPawn` (our character from P1's perspective).
**Key findings from debug dumps:**
- Camera controller (GetViewTarget=BP_DirectorMainCamera_C) always has Player=LocalPlayer_2147481445 (consistent ID)
- Its Pawn = P1-side character always
- The other local controller's Pawn = P2-side character, with GetViewTarget pointing to its own pawn
- `IsLocallyViewed()` = true on P2-side pawn, false on P1-side pawn (unreliable for identification alone)
- Fallback to FindFirstOf controller approach for offline/single player

### Team Slot Character Name — SOLVED (2026-03-29)
**Solution:** Read character portrait texture from IMG_Face_Main Image widget inside each
CharaIcon via Brush.ResourceObject.GetFullName(). Texture names encode character IDs
(e.g. T_UI_ChThumbP1_0000_00_00 = Goku Z-Early). Lookup table maps IDs to display names.
Source: community Google Sheet, auto-updated via `uv run scripts/Update-CharaNames.py`.

**Key discoveries:**
- Text_CharaName in speech bubble contains placeholder text "キャラ名はここ", not actual name
- UE4SS Blueprint property access returns opaque UObject pointers (false positives)
- FSlateBrush.ResourceObject.GetFullName() works from LoopAsync (unlike TextBlock text reading)
- SSCharacterDataAsset (294 instances) uses same ID scheme as textures
- SetText hook registered but never fired (game doesn't use SetText for bubble text)
- ExecuteInGameThread didn't fix TextBlock reading either

### Focus Detection Architecture
- **IsValidRef():** Uses UE4SS IsValid() API to check UObject liveness before accessing cached refs. Only used on cached/persisted references, NOT on FindAllOf iteration results (too expensive).
- **Fast path:** Check cached widget reference with IsValidRef + HasKeyboardFocus() — 2 calls, instant
- **Slow path:** Single FindAllOf("UserWidget"), iterate checking HasKeyboardFocus() with pcall per-widget
- **Poll rate:** 16ms (LoopAsync), feels instant on fast path
- **Transition safety:** Dialog-dismiss cooldown (400ms) + RegisterLoadMapPostHook for map transitions + watchdog restarts dead loops
- **Widget dedup:** Checks both widget name AND object identity (handles duplicate names across team/roster)

### UE4SS API Discoveries (v3.0.1)
**APIs we adopted:**
- `IsValid()` — UObject liveness check. Used on cached refs only (too expensive for iteration). Falls back to pcall(GetFullName) if IsValid not available.
- `FindFirstOf(className)` — Returns first non-CDO instance. Used for singleton lookups (ReadGuideMessage, ReadOptionsTip, PollScreenChanges).
- `RegisterLoadMapPostHook(callback)` — Fires after map loads. Used to reset all state on map transitions instead of fragile dialog-dismiss heuristics.

**APIs available but not yet used:**
- `RegisterHook("/Script/UMG.UserWidget:Construct/Destruct")` — Widget lifecycle hooks. Too noisy for focus tracking but could help detect screen changes.
- `NotifyOnNewObject(className, callback)` — Widget creation detection. Could replace FindAllOf for screen detection.
- `ExecuteInGameThread(callback)` — Queue code on game thread. May fix the bubble TextBlock reading issue (threading context).
- `ExecuteWithDelay(delayMs, callback)` — One-shot delayed execution. Could replace frame-counting approaches.
- `RegisterHook` on game-specific UFunctions — Could capture character selection events if we find the right functions.

**APIs investigated but not useful:**
- `RegisterHook on OnFocusReceived` — Only fires if game widgets override the Blueprint event (most don't)
- UObject property access on Blueprint types — Returns opaque pointers for most game-specific properties. UE4SS reflection can't resolve Blueprint-defined structs.

### Dialog Detection
- Polls at 100ms (dialogs don't use focus, auto-dismiss)
- Tracks both visibility AND text content per dialog instance
- Text found in RichTextBlock named Text_Main_0 inside WBP_Dialog_000_C
- Dialog button captions in RichTextBlock named "caption" inside button sub-widgets
- Dialog dismiss triggers 400ms transition cooldown

### Widget Naming
- Live instances in "/Engine/Transient..." paths, blueprint defaults in "/Game/SS/UI/..." paths
- Button names from widget tree: StartButton, OptionButton, QuitButton, StoreButton
- WidgetLabels table maps internal names to spoken labels
- HitBtn_Text_XX pattern: focus lands on transparent hit areas, actual labels in sibling BS_BTN_Menu_DP_XX caption TextBlocks (same suffix number)
- Fallback: GetButtonText reads child TextBlock/RichTextBlock, then CleanWidgetName
- SuppressedClasses table prevents container widgets from being announced

### Main Menu Structure
- WBP_MainMenu_Base_C — main frame (suppressed)
- WBP_MainMenu_ModeMenu_C — tab content container (suppressed)
- 6 tabs cycled with L1/R1 (tab names are images, not text — cannot be read)
- Sub-buttons: WBP_OBJ_MainMenu_BTN_Sub1_C with "caption" property
- TXT_GuideMessage — description text that changes per selection
- Character speech bubble: RichText_MainTalk + Text_CharaName

### Character Select Structure
- **Team overview:** WBP_GRP_BS_Top_00_1P_C / _2P_C with HitButton_0 through _4 (team slots)
- **Roster grid:** WBP_GRP_BS_CharaList_DP_C with HitButton_00 through _33+ (character grid)
- **Info panel:** WBP_GRP_BS_CharaNameSet_DP_C — Text_Name, Text_Name_Plus, Text_CharaBonusNum
- **Skills panel:** WBP_GRP_BS_SkillList_DP_C — SkillBTN_0/1 (normal), SkillBTN_Brast_0/1 (blast), SkillBTN_Ult_0 (ultimate)
- **Speech bubble:** WBP_OBJ_Common_TexWin_Black — Text_CharaName (only with 2+ team members)
- **Character icons:** WBP_OBJ_BS_CharaIcon_00_C — properties all opaque UObjects
- **Action buttons:** HitBTN_Replace (Switch), HitBTN_Remove (Remove), Toggle_HitButton (Switch View)

### Shop Structure (2026-04-04)
- **Module:** shop.lua — item grid, categories, purchase dialogs
- **Top screen:** WBP_GRP_SH_Top_C
  - WBP_OBJ_SH_BTN_Shop_C / WBP_OBJ_SH_BTN_Customize_C — via WidgetLabels
- **Main panel:** WBP_GRP_SH_Main_00_C
  - TXT_ShopName, TXT_CategoryName, TXT_Detail_00 (description), TXT_Money (Zeni balance)
  - TXT_Shortage_Guide_0/1 — static labels, NOT per-item (cannot detect sold-out)
  - WBP_OBJ_SH_Custom: Text_00-04 — stat labels (HP, Attack, Ki, Agility, Special Attack)
- **Item grids:**
  - S-type (small, ability items): WBP_GRP_SH_Main_S00_C → WBP_OBJ_SH_ItemIcon_S00_C through S19
  - L-type (large, characters/outfits/voices): WBP_GRP_SH_Main_L00_C → WBP_OBJ_SH_ItemIcon_L00_C through L15
  - Each item has TWO TextBlock layers: template + real data. Template has Japanese placeholders and "99,999,999,000" price. Use FIRST non-template match.
  - L-type grids persist across category switches — must match on widget FULL PATH (after `:`) not just name
  - Child widgets inside item icons receive focus after the icon itself — generic handler dedup needed
  - TXT_Detail_00 contains item name (not description) for Outfits; "Emote Voiceover Set of" for Voices — filtered
- **Categories:** WBP_OBJ_SH_BTN_Category_00 through _06, L/R buttons
  - TXT_CategoryName polled for changes (focus doesn't change on L1/R1)
- **Pages:** WBP_OBJ_SH_Pager_Item_1 through _5
- **Purchase dialog:** WBP_Dialog_SH_000_C (reused instance)
  - Txt_Header ("Purchase the following items?" / "Purchase complete.")
  - TXT_ItemLabel, TXT_Price, TXT_Money_0 (before), TXT_Money_1 (after)
  - TXT_ItemNum ("Held"), TXT_ItemNum_0 (count owned)
  - Buttons: LeftButton (OK), RightButton (Purchase/Cancel) — WBP_OBJ_Dialog_Button_C
  - Dialog pattern `WBP_Dialog_%d+_C_%d+` does NOT match shop dialogs (Lua `%w` excludes underscore)
  - Dedup via header text comparison (same header = switching buttons, different = new dialog)

### Episode Battle Structure (2026-04-04)
- **Module:** episode_battle.lua — character select, story map, cutscene skip
- **Container:** WBP_GRP_AI_CharacterSelect_C (suppressed in widget_reader)
- **Character select:**
  - 6 character panels: WBP_OBJ_AI_CharacterPanel_0-5 with Text_CharacterName_1
  - Focus on WBP_OBJ_Common_HitButton_C (no text) — both chars and action buttons
  - Selected character: CaracterText_0 (note game typo "Caracter")
  - Action buttons: WBP_OBJ_AI_BTN_Menu_0 (New Game), _1 (Continue), _2 (Story Map) — caption TextBlocks
  - HitButton suffix maps to BTN_Menu suffix for button reading
  - Outline panel: TXT_ChapterTitle ("Previously..." or "Character Introduction") + TXT_main (story/bio)
  - Characters with progress: 2 HitButtons + 2-3 BTN_Menu. Without: 1 HitButton + 1 BTN_Menu
- **Story map:**
  - WBP_GRP_AI_ChartTitle_C — detected via Text_ScenarioTitle_0 (not FindFirstOf, avoids crash)
  - Text_ScenarioTitle_0 (saga), Text_ScenarioTitle_1 (arc), Text_Chapter, Text_EventTitle (node title)
  - "???" in Text_EventTitle = placeholder, filtered out
  - No keyboard focus on map nodes — poll-based text change detection
  - Path nodes: guide button count drops (<=3), Text_EventTitle becomes Collapsed but KEEPS the previous episode's text. Returning to the same episode must be detected via title visibility (fixed 2026-09-12, was silent before)
  - WBP_OBJ_AI_BranchConditons_Set_C: Text_BranchCondition_0/1/2 — branch requirements
  - Branch conditions: use IsVisible() on parent widget to filter, but many stay visible across map
  - Entry announcement delayed ~100ms to avoid reading char select's stale guide bar / Japanese placeholders
- **Cutscene:** WBP_GRP_AI_EventSkip_C with hold button "Skip" — FindFirstOf guarded by _announcedEntry flag
- **Cutscene dialog:** WBP_GRP_Common_EventText_C > WBP_OBJ_Common_TextWindow with Text_CharaName + RichText_MainTalk (not yet implemented, voice acted)

### Story Map Popups & Episode Map (2026-09-12, from F6 dumps)
- **Module:** episode_map.lua (polled before PollStoryMap; story node announcements pause while an overlay is open)
- **3D chart:** nodes are level actors (Map800_Chart_XXXX_XX level instance, e.g. Text_Branch_002_Blueprint_C), NOT widgets. Only the title panel (WBP_GRP_AI_ChartTitle_C) is UI
- **Open detection:** closed popups stay alive/visible with root CanvasPanel opacity 0. Use SSMenuWidget.bIsActive + IsVisible + opacity
- **C++ classes (stable across sagas):** SSDragonAdventureIFCTEventDetailsManager (details popup), SSDragonAdventureIFCTMapManager (episode map root), SSDragonAdventureIFCTMapIconWidget (piece, NameProperty EventBlockName), SSDragonAdventureIFCTMapIslandWidget (block), SSDragonAdventureIFCTMapRowWidget, SSDragonAdventureIFCTMapOutlineManager, SSDragonAdventureIFCTMapCharaSelectManager, SSDragonAdventureIFCTEventTitleManager (ChartTitle), SSDragonAdventureIFCTRootInfoManager (branch conditions)
- **Details popup WBP_GRP_AI_ChartDetails_C:** WidgetSwitcher_Main page 0 = Info (WBP_OBJ_AI_TeamList_Set: CharaIcon_0-4 left box, 5-9 right box; VictoryConditions_Set: CategoryTitleText + Text_StageName; Reward_Set: Reward_0-6 with Text_RewardName/Count/Num; TXT_Reward_Text), page 1 = Outline (CategoryTitleText saga + TXT_Outline recap). Pager + BTN_Page_L/R (Pad_06/Pad_10) for multiple pages. Untranslated placeholders are Japanese
- **WBP_OBJ_AI_CharaIcon_C:** WidgetSwitcher_0 (0 Normal, 1 Unknown "?", 2 Lock), IMG_Chara texture T_UI_ChThumbP1_XXXX (chara_names lookup), T_UI_BS_IconDummy_00 = empty slot
- **Episode Map WBP_GRP_AI_Map_0020_60_C (Vegeta):** Row_00 (Block_01 Planet Namek Arc, 02 Android/Cell Arc, 03 Majin Buu Arc) + Row_01 (Block_08 "Parental Bond", 09 "Number One Spot", assumed "what if" arcs, row opacity 0). Block: TXT_ChapterTitle, pieces WBP_OBJ_AI_Map_Piece_NN (WidgetSwitcher_Icon 0 Event / 1 Battle, Overlay_Cursor opacity 1 on selected), thumbnails (T_EventBlock_* when reached, PT_00 placeholder + Hidden otherwise). Some pieces Hidden (meaning unconfirmed: locked or unrevealed)
- **Map_Outline:** TXT_Title, WidgetSwitcher_Header (0 Battle, 1 Event), TXT_main synopsis, IMG_OutlineThumbnail
- **Map_CharacterSelect:** TXT_CharacterName (saga), IMG_ArrowL/R to switch saga; bIsActive stays false while visible
- **Guide bar on map:** Back, Details (Pad_05), Recap (Pad_04), Change Difficulty (Pad_07), Episode Map (Pad_11). Path nodes hide buttons 3-4 and show OtherCharacter icons in ChartTitle

### Stage/BGM/Settings Select
- WBP_GRP_BS_StageList_DP2_C — list container with Text_Title header ("Stage", etc.)
- WBP_OBJ_Common_HitBtn_Text_XX — transparent hit areas that receive focus
- WBP_OBJ_BS_BTN_Menu_DP_XX — actual menu items with caption TextBlocks
- Same suffix number links focus widget to label widget
- L1/R1 cycles between views, header announced via Text_Title tracking

### Battle HUD — Game State Properties (2026-03-29)
**On SSCharacter (C++ class, readable via pawn.PropertyName):**
- `HPGaugeValue` (FloatProperty, 0x2A14) — current HP, percentage-based thresholds used
- `SPGaugeValue` (FloatProperty, 0x2A18) — KI energy, 10k per bar, max 50k (5 bars)
- `SparkingGaugeValue` (FloatProperty, 0x2A30) — Sparking gauge, full = 50k
- `BlastStockCount` (IntProperty, 0x2A48) — blast stock count
- `ComboNum` (IntProperty, 0x2B24) — current combo hit count
- `BattleState` (EnumProperty) — character state

**On BP_BattleGameStateBase_C:**
- `ReplicatedWorldTimeSeconds` (FloatProperty) — elapsed world time
- `bIsTimeOverSettle` (BoolProperty) — time-over flag
- Match countdown timer NOT directly exposed as a property

**Player pawn access:** Camera controller (GetViewTarget=BP_DirectorMainCamera_C) + player side from team overview. See "Online Player Pawn Detection" notes.
**Opponent detection:** Player pawn's TargetPawn property, or all BPCHR_ pawns except player's

### Post-Battle Result Screen (2026-04-06)
**Detection:** Poll for `WBP_GRP_BS_Result_03_DP_C` visibility (FindAllOf, not FindFirstOf). Wait for rewards to populate (non-placeholder) before announcing.
**Widgets and TextBlocks:**
- `WBP_GRP_BS_Result_03_DP_C` — result panel (scoped by instance ID for Text_RankNum)
  - `Text_RankNum` — player level number
  - `Text_UserName` — your username
  - `Text_Rank` — "Player Level" label
- `WBP_GRP_BS_PlayerRankUP_C` — rank up panel (only visible when you rank up; hidden = Japanese placeholder)
  - `Text_RewardInfo` — "Rank Up"
  - `Text_RankNum_0` — new level number
- `WBP_GRP_MainMenu_Notification_gift_C` → `WBP_OBJ_MainMenu_Notification_gift_Item_X`
  - `Txt_ItemName` — reward name (filter "アイテム名" placeholder)
  - `TXT_Num` — amount (filter "99999999" placeholder)
  - `Txt_Header` — "New Rewards"
- `WBP_PlayerInfo_C` (not always present in online)
  - `Txt_WinningStreak_Value` — your win streak (filter "999" placeholder)
**Timing:** Result panel appears ~10s after battle ends. Rewards populate ~5s after panel. Rank up ~7s after. Code retries every 100ms until rewards are real.

### Title Screen Flow
1. Auto-dismiss dialog 1 (autosave notice)
2. Auto-dismiss dialog 2 ("Loading saved data...")
3. "Press any button" screen (WBP_Title_PressAnyButton_C)
4. Collapsed title: Start + Quit (WBP_Title_Button_PC_C: GameStart_Button, GameQuit_Button)
5. Expanded title: Start + Options + Quit (WBP_Title_Button_C: StartButton, OptionButton, QuitButton)
6. Start → Main menu

## Distribution / Installer (2026-09-12)
AccessForge removed (accessforge.yml deleted). Version now lives in `VERSION`.

Files:
- `installer\SparkingZeroAccess.iss` — Inno Setup 6 script
- `installer\build.ps1` — downloads UE4SS_v3.0.1.zip (SHA256 pinned, cached in build\cache), extracts deps\utoc-bypass.zip, patches UE4SS-settings.ini (bUseUObjectArrayCache=false, GraphicsAPI=dx11, GuiConsoleVisible=0), builds `build\output\SparkingZeroAccess-Setup-<ver>.exe` and `SparkingZeroAccess-<ver>-manual.zip` (Win64 layout)
- `helpers\Deploy-Mod.ps1` — dev deploy (robocopy /MIR into Mods\SparkingZeroAccess\Scripts, retries locked files)
- `.github\workflows\release.yml` — choco installs Inno Setup, runs build.ps1, uploads exe + manual zip
- `THIRD-PARTY-NOTICES.txt` — license texts and credits: UE4SS (MIT, Narknon), Lua 5.4.7 (MIT, in speech_bridge.dll), UniversalSpeech (MIT, Quentin Cosendey), NVDA Controller Client (LGPL 2.1), ZDSRAPI.dll, UTOC bypass (DeathChaos). Installed to Mods\SparkingZeroAccess\ and included in the manual zip. Update it when a bundled component changes

Installer behavior:
- Game detection order: Steam uninstall key "Steam App 1790600" InstallLocation (HKLM 64/32) → Steam path (HKCU SteamPath / HKLM32 InstallPath) → each library in libraryfolders.vdf → appmanifest_1790600.acf installdir
- Valid game folder = contains SparkingZERO\Binaries\Win64\SparkingZERO-Win64-Shipping.exe. Selecting the Win64 folder is auto-corrected. Checked in NextButtonClick and PrepareToInstall (silent installs too)
- Installs UE4SS (full zip minus README/Changelog), bypass, mod into Mods\SparkingZeroAccess\Scripts (Scripts folder wiped first)
- mods.txt: installed only if missing; then `SparkingZeroAccess : 1` added at top, other entries kept
- Removes AccessForge-era `Mods\dragon-ball-sparking-zero-access\` folder and its mods.txt entry (AccessForge used the manifest id as folder/slug; would cause double speech)
- Uninstaller in Program Files\Sparking Zero Access (not in game folder). Uninstall removes UE4SS, bypass, mod, AE_debug, UE4SS.log; removes only our mods.txt entry
- Admin by default; `/CURRENTUSER` allowed on command line. CloseApplications=yes offers to close the game
- Finish page: unchecked "Start game" option (steam://rungameid/1790600). Text comes from `FinishedLabelNoIcons` (not `FinishedLabel`, since no shortcuts are created)

Existing copy dialog (added 2026-09-12):
- Checked in InitializeSetup, before the wizard. Registered install = this setup's uninstall key `{7C3E9A52-4D1B-4F8E-9B26-1A5D0E83C4F7}_is1` in HKLM64, HKLM32 or HKCU. Unregistered copy = `Mods\SparkingZeroAccess\Scripts\main.lua` or the legacy AccessForge folder in the detected game folder
- TaskDialogMsgBox with command links: Replace (IDYES), Uninstall (IDNO), Cancel. MSAA exposes them as push buttons with the note as description
- Replace: skips the Welcome and folder pages and goes to Ready. Installs into the folder that has the mod (registry InstallLocation for registered installs, unless /DIR is given)
- Uninstall, registered: runs UninstallString with /SILENT, waits up to 60s for unins000.exe and the registry key to disappear, then shows "was uninstalled"
- Uninstall, unregistered (user decision: mod only): deletes Mods\SparkingZeroAccess, the legacy folder, AE_debug, and the mods.txt entries. UE4SS and bypass are kept
- /VERYSILENT skips the dialog and replaces. /DIR= also drives detection, ahead of Steam
- Game running check (WMI query for SparkingZERO-Win64-Shipping.exe) with Retry/Cancel: before a dialog uninstall and in InitializeUninstall
- Inno gotcha: a [Code] line starting with `[` (for example a wrapped open array literal) is parsed as a section tag. Use an array variable instead

Automated tests passed (fake game folder, silent /CURRENTUSER install):
- Detection found real game on this PC; install exit 0; all files present; settings patched; stale script and legacy folder removed; mods.txt merged correctly
- Uninstall removed files, registry entry, uninstaller folder; mods.txt kept other entries
- Wrong folder rejected with no files written; manual zip uses forward-slash entry names
- Note: test folders need short paths — deep UE4SS files exceed MAX_PATH under long temp paths (installer rolled back cleanly)

Dialog tests passed (UI Automation clicking the real dialog, fake game folders, /CURRENTUSER):
- Unregistered copy → Uninstall: mod and legacy folders removed, UE4SS kept, mods.txt entries removed
- Cancel: nothing changed
- Registered → Replace: location read from registry, Ready page shown directly, reinstall removed a stale script
- Registered → Uninstall: files, registry entry, and uninstaller folder removed
- Test scripts were kept in the session scratchpad, not the repo

Pending tests (user):
- [ ] Fresh install with NVDA on the real game: welcome page, folder page ("Setup found..." text), UAC, finish page
- [ ] Run the installer again: the dialog reads its title, folder, and both buttons with their notes. Try Replace
- [ ] Run the installer again and choose Uninstall
- [ ] Launch game after install → "Press confirm to start"
- [ ] Release workflow on GitHub Actions (not run yet)

Follow-ups:
- NVDA Controller Client is LGPL 2.1. The notices link to the full license text; consider bundling the text itself (lgpl-2.1.txt from gnu.org)
- UTOC bypass redistribution permission not verified (Nexus page blocked automated access). ZDSRAPI.dll license unknown
- The repo has no license of its own
- AppPublisher is "Sparking Zero Access contributors". Change if desired

## Known Issues
- UniversalSpeech reports "JAWS" as detected engine even when NVDA is active (cosmetic, speech works correctly through NVDA)
- UE4SS GUI debug window disabled (GuiConsoleVisible=0) for accessibility
- Team slot character names not readable (see investigation notes above)
- Crash dumps `crash_*.dmp` in the Win64 directory are written by UE4SS's crash handler. The 2026-09-12 dumps ARE mod-related: LoopAsync polling races with widget destruction on screen changes (World Tournament, title screen). Fix (all polling on the game thread, experimental UE4SS) deployed 2026-09-12 night, UNTESTED, see "Session Handoff (2026-09-12, night)"

## Architecture
- UE4SS Lua mod: SparkingZeroAccess (Mods/SparkingZeroAccess/Scripts/)
  - main.lua — orchestrator: focus tracking, keybinds, init, RegisterLoadMapPostHook; one reader tick on the game thread (focus every tick + rotating slow poll groups)
  - game_thread.lua — GT.Every / GT.After / GT.OnKey scheduler on the game thread (LoopInGameThreadWithDelay on experimental UE4SS, LoopAsync + ExecuteInGameThread fallback on 3.0.1), slow task and 60 s timing logs
  - helpers.lua — TryCall, TryGetProperty, GetWidgetName, GetClassName, IsValidRef
  - speech.lua — Speak/SpeakQueued over the named pipe \\.\pipe\SparkingZeroAccess (applies icon_parser automatically)
  - widget_reader.lua — text reading, widget matching, label resolution, list position
  - poll_trackers.lua — dialog, help window, screen change, room ID/status polling
  - icon_parser.lua — converts RichText icon markup to readable text (full PS/Xbox/keyboard mappings)
  - skill_list.lua — Explanation of Controls overlay: skill name, button combo, cost, description
  - episode_battle.lua — Episode Battle (story mode): char select, story map, path nodes (portrait signature), cutscene skip
  - episode_map.lua — Episode Battle popups: Details (team/condition/rewards), Recap, Episode Map overlay (polled before PollStoryMap, pauses node announcements while open)
  - shop.lua — Shop: item grid (S/L types), categories, purchase dialogs, Zeni balance
  - battle.lua — battle HUD: HP/KI/Sparking announcements, opponent tracking, intro skip
  - team_overview.lua — team setup screen: slot navigation, bubble name reading
  - chara_roster.lua — character roster grid: name reading, skills, teamlist (cached TextBlock refs)
  - debug_tools.lua (F3-F8, loaded via require, remove to disable). F6 story map dump + chart_actors.txt, F7 story trace, F8 marker. Trace records speech via Speech.SetListener
- Dev tooling: helpers\Check-Lua.ps1 (luac -p + tools\luacheck.exe with .luacheckrc), run automatically by helpers\Deploy-Mod.ps1
- NVDA add-on: nvda-addon\ (manifest.ini, globalPlugins\sparkingZeroAccess.py: ctypes named pipe server, speaks via ui.message). Build: helpers\Build-NvdaAddon.ps1. Offline test: experiments\Test-SpeechPipe.ps1
- Retired: speech_bridge.dll (Lua C module + UniversalSpeech). Source kept in speech_bridge\ for a possible standalone JAWS/SAPI pipe helper. No gcc on PATH any more; Visual Studio 2022 is installed
- Git repo initialized at mod directory (branch: main)

## Files Modified in Game Directory
Installed by the installer: dwmapi.dll, UE4SS.dll, UE4SS-settings.ini, Mods\ (UE4SS default mods + ours), dsound.dll, plugins\DBSparkingZeroUTOCBypass.asi

Original manual setup:
- SparkingZERO\Binaries\Win64\UE4SS-settings.ini (bUseUObjectArrayCache, GraphicsAPI, GuiConsoleVisible)
- SparkingZERO\Binaries\Win64\Mods\mods.txt (added SparkingZeroAccess)
- SparkingZERO\Binaries\Win64\Mods\SparkingZeroAccess\ (our mod)
- SparkingZERO\Binaries\Win64\UniversalSpeech.dll, nvdaControllerClient.dll, ZDSRAPI.dll (retired 2026-09-12, no longer deployed)

Outside the game directory (2026-09-12): %APPDATA%\nvda\addons\SparkingZeroAccess (the NVDA add-on), build\stage\ue4ss-experimental-* and build\backup\ue4ss-3.0.1 (UE4SS builds for Switch-UE4SS.ps1)
