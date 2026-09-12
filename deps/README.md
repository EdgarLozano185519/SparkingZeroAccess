# Dependencies

Bundled dependencies packed into the installer and manual-install zip by `installer\build.ps1`.

## utoc-bypass.zip

UTOC Signature Bypass Patch by DeathChaos ([Nexus Mods page](https://www.nexusmods.com/dragonballsparkingzero/mods/18)) — required for Sparking! ZERO to load modded content. Without this patch, the game's signature verification rejects any modified or added files.

Contains:
- `dsound.dll` — DLL proxy loader
- `plugins/DBSparkingZeroUTOCBypass.asi` — the bypass plugin

Installed next to the game executable (`SparkingZERO\Binaries\Win64`).

## UE4SS

UE4SS v3.0.1 is not stored in the repo. `installer\build.ps1` downloads `UE4SS_v3.0.1.zip` from the official UE4SS-RE GitHub release, checks its SHA256 hash, and caches it in `build\cache`.

## Licenses

License texts and credits for all bundled components are in `THIRD-PARTY-NOTICES.txt` at the repo root. The installer and manual zip place a copy in `Mods\SparkingZeroAccess\`. Update that file when a bundled component changes.
