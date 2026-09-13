; Sparking Zero Access installer (Inno Setup 6)
;
; Build with installer\build.ps1. It downloads and stages UE4SS and the UTOC
; bypass, then compiles this script with the defines checked below.

#if VER < EncodeVer(6, 3, 0)
  #error Inno Setup 6.3 or newer is required
#endif
#ifndef AppVersion
  #error AppVersion is not defined. Build with installer\build.ps1
#endif
#ifndef StageDir
  #error StageDir is not defined. Build with installer\build.ps1
#endif
#ifndef OutputDir
  #define OutputDir "..\build\output"
#endif

#define AppName "Sparking Zero Access"
#define AppGuid "7C3E9A52-4D1B-4F8E-9B26-1A5D0E83C4F7"
#define GameName "DRAGON BALL: Sparking! ZERO"
#define SteamAppId "1790600"
#define ShippingExeName "SparkingZERO-Win64-Shipping.exe"
#define ModName "SparkingZeroAccess"
; Folder and mods.txt entry used by AccessForge installs, removed on install
#define LegacyModName "dragon-ball-sparking-zero-access"
#define Win64Dir "{app}\SparkingZERO\Binaries\Win64"

[Setup]
AppId={{{#AppGuid}}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Sparking Zero Access contributors
AppPublisherURL=https://github.com/EdgarLozano185519/SparkingZeroAccess
AppSupportURL=https://github.com/EdgarLozano185519/SparkingZeroAccess/issues
; {app} is the game folder, found in InitializeSetup
DefaultDirName={code:GetDefaultGameDir}
UsePreviousAppDir=no
AppendDefaultDirName=no
DirExistsWarning=no
DisableWelcomePage=no
DisableProgramGroupPage=yes
; Keep the uninstaller out of the game folder
UninstallFilesDir={autopf}\{#AppName}
UninstallDisplayName={#AppName}
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; Offers to close the game if it has UE4SS or mod files open
CloseApplications=yes
RestartApplications=no
OutputDir={#OutputDir}
OutputBaseFilename=SparkingZeroAccess-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes

[Messages]
WelcomeLabel2=This will install [name/ver] into {#GameName}.%n%nSetup also installs the UE4SS v3.0.1 mod loader and the UTOC signature bypass, which the mod needs to run.%n%nClose the game before continuing.
SelectDirDesc=Where is {#GameName} installed?
; The "NoIcons" variant is the one shown, since setup creates no shortcuts
FinishedLabelNoIcons=Setup has installed [name] into {#GameName}.%n%nStart the game from Steam. On the title screen you should hear "Press confirm to start".

[CustomMessages]
GameFound=Setup found {#GameName} in the folder below. Click Next to install the mod there.
GameNotFound=Setup could not find {#GameName} automatically. Click Browse and select the game folder, the one that contains SparkingZERO.exe.
NotGameDir=The folder %1 does not contain {#GameName}.%n%nSelect the game folder, the one that contains SparkingZERO.exe.
ModsTxtFailed=Setup could not update %1.%n%nThe mod will not load until the line "{#ModName} : 1" is added to that file.
StartGame=Start {#GameName} now
CloseGame={#GameName} is running. Close the game, then click Retry.
ExistingTitle={#AppName} is already installed
ExistingVersionTitle={#AppName} %1 is already installed
ExistingText=Setup found the mod in this game folder:%n%1%n%nWhat would you like to do?
ReplaceButton=&Replace
ReplaceNote=Install version {#AppVersion} over the existing copy.
UninstallButton=&Uninstall
UninstallNoteFull=Remove the mod, UE4SS and the UTOC bypass from the game.
UninstallNoteModOnly=Remove the mod and its mods.txt entry. UE4SS and the UTOC bypass stay installed, because this copy was not installed by this setup.
Uninstalled={#AppName} was uninstalled.
UninstallFailed=Setup could not finish uninstalling {#AppName}. Make sure the game is closed, then try again.

[InstallDelete]
; Clean install of the mod scripts so files removed from the mod don't linger
Type: filesandordirs; Name: "{#Win64Dir}\Mods\{#ModName}\Scripts"
Type: filesandordirs; Name: "{#Win64Dir}\Mods\{#LegacyModName}"

[Files]
; UE4SS v3.0.1, settings already patched by build.ps1
Source: "{#StageDir}\ue4ss\dwmapi.dll"; DestDir: "{#Win64Dir}"; Flags: ignoreversion
Source: "{#StageDir}\ue4ss\UE4SS.dll"; DestDir: "{#Win64Dir}"; Flags: ignoreversion
Source: "{#StageDir}\ue4ss\UE4SS-settings.ini"; DestDir: "{#Win64Dir}"; Flags: ignoreversion
Source: "{#StageDir}\ue4ss\Mods\*"; Excludes: "mods.txt"; DestDir: "{#Win64Dir}\Mods"; Flags: ignoreversion recursesubdirs createallsubdirs
; Keep an existing mods.txt (other mods may be listed); UpdateModsTxt adds our entry
Source: "{#StageDir}\ue4ss\Mods\mods.txt"; DestDir: "{#Win64Dir}\Mods"; Flags: onlyifdoesntexist uninsneveruninstall

; UTOC signature bypass
Source: "{#StageDir}\bypass\dsound.dll"; DestDir: "{#Win64Dir}"; Flags: ignoreversion
Source: "{#StageDir}\bypass\plugins\*"; DestDir: "{#Win64Dir}\plugins"; Flags: ignoreversion recursesubdirs createallsubdirs

; The mod (Lua scripts; speech goes to the NVDA add-on over a named pipe)
Source: "..\SparkingZeroAccess\*"; DestDir: "{#Win64Dir}\Mods\{#ModName}\Scripts"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\THIRD-PARTY-NOTICES.txt"; DestDir: "{#Win64Dir}\Mods\{#ModName}"; Flags: ignoreversion

[UninstallDelete]
Type: filesandordirs; Name: "{#Win64Dir}\Mods\{#ModName}"
Type: filesandordirs; Name: "{#Win64Dir}\AE_debug"
Type: files; Name: "{#Win64Dir}\UE4SS.log"

[Run]
Filename: "steam://rungameid/{#SteamAppId}"; Description: "{cm:StartGame}"; Flags: shellexec postinstall nowait skipifsilent unchecked runasoriginaluser

[Code]
var
  DetectedGameDir: String;
  { Existing copy of the mod, found in InitializeSetup }
  ExistingGameDir: String;
  ExistingVersion: String;
  ExistingUninstaller: String;
  ExistingUninstallRoot: Integer;
  ExistingUninstallKey: String;
  ReplaceExisting: Boolean;

{ ---------- Game folder ---------- }

function Win64DirOf(const GameDir: String): String;
begin
  Result := AddBackslash(GameDir) + 'SparkingZERO\Binaries\Win64';
end;

function IsGameDir(const Dir: String): Boolean;
begin
  Result := (Dir <> '') and FileExists(Win64DirOf(Dir) + '\{#ShippingExeName}');
end;

function TryGameDir(const Dir: String): Boolean;
begin
  Result := IsGameDir(Dir);
  if Result then
    DetectedGameDir := RemoveBackslashUnlessRoot(Dir);
end;

{ Reads the value from a Steam VDF line such as:  "path"    "D:\\SteamLibrary" }
function ReadVdfValue(const Line, Key: String; var Value: String): Boolean;
var
  S: String;
  QuotePos: Integer;
begin
  Result := False;
  S := Trim(Line);
  if CompareText(Copy(S, 1, Length(Key) + 2), '"' + Key + '"') <> 0 then
    Exit;
  S := Trim(Copy(S, Length(Key) + 3, Length(S)));
  if Copy(S, 1, 1) <> '"' then
    Exit;
  Delete(S, 1, 1);
  QuotePos := Pos('"', S);
  if QuotePos = 0 then
    Exit;
  Value := Copy(S, 1, QuotePos - 1);
  StringChangeEx(Value, '\\', '\', True);
  Result := True;
end;

{ Returns the game folder from a Steam library's app manifest, or '' }
function GameDirInLibrary(const LibraryDir: String): String;
var
  Lines: TArrayOfString;
  InstallDir: String;
  I: Integer;
begin
  Result := '';
  if not LoadStringsFromFile(AddBackslash(LibraryDir) + 'steamapps\appmanifest_{#SteamAppId}.acf', Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
    if ReadVdfValue(Lines[I], 'installdir', InstallDir) then
    begin
      Result := AddBackslash(LibraryDir) + 'steamapps\common\' + InstallDir;
      Exit;
    end;
end;

procedure DetectGameDir;
var
  Location, SteamDir, LibraryDir: String;
  Lines: TArrayOfString;
  I: Integer;
begin
  DetectedGameDir := '';

  { Steam registers an uninstall entry for each installed game }
  if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App {#SteamAppId}', 'InstallLocation', Location) then
    if TryGameDir(Location) then
      Exit;
  if RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App {#SteamAppId}', 'InstallLocation', Location) then
    if TryGameDir(Location) then
      Exit;

  { Otherwise look for the game's app manifest in every Steam library }
  if not RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', SteamDir) then
    if not RegQueryStringValue(HKLM32, 'SOFTWARE\Valve\Steam', 'InstallPath', SteamDir) then
      SteamDir := ExpandConstant('{commonpf32}\Steam');
  StringChangeEx(SteamDir, '/', '\', True);

  if TryGameDir(GameDirInLibrary(SteamDir)) then
    Exit;
  if LoadStringsFromFile(AddBackslash(SteamDir) + 'steamapps\libraryfolders.vdf', Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      if ReadVdfValue(Lines[I], 'path', LibraryDir) then
        if TryGameDir(GameDirInLibrary(LibraryDir)) then
          Exit;
end;

{ ---------- Running game check (setup and uninstaller) ---------- }

function IsGameRunning: Boolean;
var
  Locator, Service, Processes: Variant;
begin
  Result := False;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Processes := Service.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name = ''{#ShippingExeName}''');
    Result := Processes.Count > 0;
  except
    Log('Could not check whether the game is running: ' + GetExceptionMessage);
  end;
end;

function EnsureGameClosed: Boolean;
begin
  Result := True;
  while IsGameRunning do
    if SuppressibleMsgBox(CustomMessage('CloseGame'), mbError, MB_RETRYCANCEL, IDCANCEL) <> IDRETRY then
    begin
      Result := False;
      Exit;
    end;
end;

{ ---------- mods.txt ---------- }

function ModsTxtPath: String;
begin
  Result := ExpandConstant('{#Win64Dir}\Mods\mods.txt');
end;

{ Returns the mod name of a mods.txt line such as "Keybinds : 1", or '' }
function ModsTxtEntryName(const Line: String): String;
var
  ColonPos: Integer;
begin
  Result := '';
  ColonPos := Pos(':', Line);
  if (ColonPos > 0) and (Copy(Trim(Line), 1, 1) <> ';') then
    Result := Trim(Copy(Line, 1, ColonPos - 1));
end;

{ Removes this mod's entries (current and legacy names) from mods.txt and,
  when Enable is set, adds the current entry back at the top }
function UpdateModsTxt(const ModsTxt: String; Enable: Boolean): Boolean;
var
  Lines, NewLines: TArrayOfString;
  I, Count: Integer;
  EntryName: String;
begin
  if not LoadStringsFromFile(ModsTxt, Lines) then
  begin
    if not Enable then
    begin
      Result := True;
      Exit;
    end;
    SetArrayLength(Lines, 0);
  end;

  SetArrayLength(NewLines, GetArrayLength(Lines) + 1);
  Count := 0;
  if Enable then
  begin
    NewLines[0] := '{#ModName} : 1';
    Count := 1;
  end;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    EntryName := ModsTxtEntryName(Lines[I]);
    if (CompareText(EntryName, '{#ModName}') <> 0) and (CompareText(EntryName, '{#LegacyModName}') <> 0) then
    begin
      NewLines[Count] := Lines[I];
      Count := Count + 1;
    end;
  end;
  SetArrayLength(NewLines, Count);

  Result := SaveStringsToFile(ModsTxt, NewLines, False);
  if Result then
    Log('Updated ' + ModsTxt)
  else
    Log('Failed to write ' + ModsTxt);
end;

{ ---------- Existing copy: detect, replace, uninstall ---------- }

{ Reads this app's uninstall entry, written by a previous run of this setup }
function ReadRegisteredInstall(RootKey: Integer): Boolean;
var
  Key, Location: String;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{' + '{#AppGuid}' + '}_is1';
  Result := RegQueryStringValue(RootKey, Key, 'UninstallString', ExistingUninstaller);
  if not Result then
    Exit;
  ExistingUninstallRoot := RootKey;
  ExistingUninstallKey := Key;
  if not RegQueryStringValue(RootKey, Key, 'DisplayVersion', ExistingVersion) then
    ExistingVersion := '';
  if RegQueryStringValue(RootKey, Key, 'InstallLocation', Location) then
    ExistingGameDir := RemoveBackslashUnlessRoot(Location);
end;

procedure DetectExistingMod;
var
  ModsDir: String;
begin
  ExistingGameDir := '';
  ExistingVersion := '';
  ExistingUninstaller := '';

  if ReadRegisteredInstall(HKLM64) or ReadRegisteredInstall(HKLM32) or ReadRegisteredInstall(HKCU) then
  begin
    Log('Found install by this setup: version ' + ExistingVersion + ' in ' + ExistingGameDir);
    Exit;
  end;

  { A copy installed another way (manually or with AccessForge) }
  if DetectedGameDir = '' then
    Exit;
  ModsDir := Win64DirOf(DetectedGameDir) + '\Mods';
  if FileExists(ModsDir + '\{#ModName}\Scripts\main.lua') or DirExists(ModsDir + '\{#LegacyModName}') then
  begin
    ExistingGameDir := DetectedGameDir;
    Log('Found copy not installed by this setup in ' + ExistingGameDir);
  end;
end;

function RunRegisteredUninstaller: Boolean;
var
  UninstallerExe: String;
  ResultCode, I: Integer;
begin
  Result := False;
  UninstallerExe := RemoveQuotes(ExistingUninstaller);
  Log('Running uninstaller: ' + UninstallerExe);
  if not Exec(UninstallerExe, '/SILENT /NORESTART', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
  begin
    Log('Could not start the uninstaller: ' + SysErrorMessage(ResultCode));
    Exit;
  end;

  { The uninstaller hands off to a temporary copy of itself, which deletes the
    uninstaller and its registry entry when done. Wait up to 60 seconds. }
  for I := 1 to 240 do
  begin
    if not FileExists(UninstallerExe) and not RegKeyExists(ExistingUninstallRoot, ExistingUninstallKey) then
    begin
      Result := True;
      Exit;
    end;
    Sleep(250);
  end;
  Log('Uninstaller did not finish within 60 seconds');
end;

{ Removes a copy this setup did not install. UE4SS and the bypass are left alone,
  since other mods may rely on them. }
function RemoveUnregisteredMod(const GameDir: String): Boolean;
var
  ModsDir: String;
begin
  ModsDir := Win64DirOf(GameDir) + '\Mods';
  Log('Removing mod files from ' + ModsDir);
  DelTree(ModsDir + '\{#ModName}', True, True, True);
  DelTree(ModsDir + '\{#LegacyModName}', True, True, True);
  DelTree(Win64DirOf(GameDir) + '\AE_debug', True, True, True);
  Result := UpdateModsTxt(ModsDir + '\mods.txt', False) and
    not DirExists(ModsDir + '\{#ModName}') and not DirExists(ModsDir + '\{#LegacyModName}');
end;

procedure UninstallExisting;
var
  Success: Boolean;
begin
  if not EnsureGameClosed then
    Exit;
  if ExistingUninstaller <> '' then
    Success := RunRegisteredUninstaller
  else
    Success := RemoveUnregisteredMod(ExistingGameDir);

  if Success then
    MsgBox(CustomMessage('Uninstalled'), mbInformation, MB_OK)
  else
    MsgBox(CustomMessage('UninstallFailed'), mbError, MB_OK);
end;

{ Returns IDYES for Replace, IDNO for Uninstall, IDCANCEL (or 0) for Cancel }
function AskReplaceOrUninstall: Integer;
var
  Instruction, UninstallNote: String;
  ButtonLabels: TArrayOfString;
begin
  if ExistingVersion <> '' then
    Instruction := FmtMessage(CustomMessage('ExistingVersionTitle'), [ExistingVersion])
  else
    Instruction := CustomMessage('ExistingTitle');
  if ExistingUninstaller <> '' then
    UninstallNote := CustomMessage('UninstallNoteFull')
  else
    UninstallNote := CustomMessage('UninstallNoteModOnly');

  { Each label is "button text", newline, "note shown under the button" }
  SetArrayLength(ButtonLabels, 2);
  ButtonLabels[0] := CustomMessage('ReplaceButton') + #13#10 + CustomMessage('ReplaceNote');
  ButtonLabels[1] := CustomMessage('UninstallButton') + #13#10 + UninstallNote;

  Result := TaskDialogMsgBox(Instruction, FmtMessage(CustomMessage('ExistingText'), [DetectedGameDir]),
    mbConfirmation, MB_YESNOCANCEL, ButtonLabels, 0);
end;

{ ---------- Setup events ---------- }

function InitializeSetup: Boolean;
var
  CmdLineDir: String;
begin
  Result := True;

  { An explicit /DIR= takes priority over Steam detection }
  CmdLineDir := ExpandConstant('{param:DIR|}');
  if IsGameDir(CmdLineDir) then
    DetectedGameDir := RemoveBackslashUnlessRoot(CmdLineDir)
  else
    DetectGameDir;
  if DetectedGameDir <> '' then
    Log('Detected game folder: ' + DetectedGameDir)
  else
    Log('Game folder not detected');

  DetectExistingMod;
  if (ExistingUninstaller = '') and (ExistingGameDir = '') then
    Exit;

  { Replace installs into the folder that already has the mod }
  if (CmdLineDir = '') and IsGameDir(ExistingGameDir) then
    DetectedGameDir := ExistingGameDir;

  { Silent installs replace the existing copy without asking }
  if WizardSilent then
    Exit;

  case AskReplaceOrUninstall of
    IDYES:
      ReplaceExisting := True;
    IDNO:
      begin
        UninstallExisting;
        Result := False;
      end;
  else
    Result := False;
  end;
end;

function GetDefaultGameDir(Param: String): String;
begin
  if DetectedGameDir <> '' then
    Result := DetectedGameDir
  else
    Result := ExpandConstant('{commonpf32}\Steam\steamapps\common\DRAGON BALL Sparking! ZERO');
end;

procedure InitializeWizard;
var
  Delta: Integer;
begin
  if DetectedGameDir <> '' then
    WizardForm.SelectDirLabel.Caption := CustomMessage('GameFound')
  else
    WizardForm.SelectDirLabel.Caption := CustomMessage('GameNotFound');

  { The new caption can wrap to more lines; shift the controls below it }
  Delta := WizardForm.AdjustLabelHeight(WizardForm.SelectDirLabel);
  WizardForm.SelectDirBrowseLabel.Top := WizardForm.SelectDirBrowseLabel.Top + Delta;
  WizardForm.DirEdit.Top := WizardForm.DirEdit.Top + Delta;
  WizardForm.DirBrowseButton.Top := WizardForm.DirBrowseButton.Top + Delta;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  { Replace already knows the game folder, so go straight to the Ready page }
  Result := ReplaceExisting and IsGameDir(DetectedGameDir) and
    ((PageID = wpWelcome) or (PageID = wpSelectDir));
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Dir: String;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    Exit;

  Dir := RemoveBackslashUnlessRoot(WizardDirValue);
  { Accept the Win64 folder too, and walk up to the game folder }
  if not IsGameDir(Dir) then
    if FileExists(AddBackslash(Dir) + '{#ShippingExeName}') then
    begin
      Dir := ExtractFileDir(ExtractFileDir(ExtractFileDir(Dir)));
      WizardForm.DirEdit.Text := Dir;
    end;

  if not IsGameDir(Dir) then
  begin
    MsgBox(FmtMessage(CustomMessage('NotGameDir'), [Dir]), mbError, MB_OK);
    Result := False;
  end;
end;

{ Also runs for silent installs, where the directory page is skipped }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not IsGameDir(WizardDirValue) then
    Result := FmtMessage(CustomMessage('NotGameDir'), [WizardDirValue]);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    if not UpdateModsTxt(ModsTxtPath, True) then
      SuppressibleMsgBox(FmtMessage(CustomMessage('ModsTxtFailed'), [ModsTxtPath]), mbError, MB_OK, IDOK);
end;

{ ---------- Uninstaller events ---------- }

function InitializeUninstall: Boolean;
begin
  Result := EnsureGameClosed;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    UpdateModsTxt(ModsTxtPath, False);
end;
