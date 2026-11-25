"""Build dist/PZ2Coop.zip for players.

Zip layout mirrors the game folder, so the player copies two items into the folder with PlanetZoo2.exe:
  version.dll                      proxy DLL (Windows only loads it next to the exe)
  Win64/ovldata/PZ2Coop/...        content pack
  PZ2Coop-README.txt               install / update / uninstall steps for novice players

Windows "Extract All" always adds a folder named after the zip, so extracting straight into the game folder never
puts version.dll next to PlanetZoo2.exe. The README therefore says: extract anywhere, then copy + paste.
No installer (.exe / .bat): players distrust them and unsigned ones trip AV / SmartScreen.

  python tools/make_installer.py
"""
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_ovl_mod import DLL_PATH, PACK_NAME, REPO, build  # noqa: E402

OUT = REPO / "dist" / "PZ2Coop.zip"

README = f"""Planet Zoo 2 Co-op - how to install

The mod is two things: a file called version.dll and a folder called Win64.
Installing means copying both into your Planet Zoo 2 game folder. That is all.

INSTALL
1. Close Planet Zoo 2.
2. Unzip the download somewhere easy, like your Downloads folder:
   right-click PZ2Coop.zip > Extract All > Extract.
   A new folder opens. Inside it you see:
     version.dll   (may show as just "version" - same file)
     Win64         (a folder)
     PZ2Coop-README.txt
3. Select version.dll AND Win64 (hold Ctrl and click both), then press Ctrl+C.
4. Open the game folder: in Steam, right-click Planet Zoo 2 > Manage > Browse local files.
   You are in the right place when you can see PlanetZoo2.exe (may show as just "PlanetZoo2").
5. Click an empty spot in that folder and press Ctrl+V.
   - Windows asks for administrator permission: click Continue.
   - Windows asks about replacing files: click "Replace the files in the destination".
   The game already has a Win64 folder. Windows adds our files into it; none of the game's files are removed.
6. Check: version.dll must now be in the SAME folder as PlanetZoo2.exe, not inside another folder.
   Anywhere else, the mod does nothing.
7. Start the game, load a Sandbox or Challenge zoo, press Esc and click "Co-op".

COMMON MISTAKE
Do not unzip straight into the game folder. Windows then puts everything in an extra
"{PACK_NAME}" folder, and the game never finds version.dll in there.
Fix: open that {PACK_NAME} folder and do steps 3 to 6 from there.

UPDATE
1. In the game folder, open Win64 > ovldata and delete the {PACK_NAME} folder.
2. Do the install steps again with the new zip.

UNINSTALL
In the game folder, delete these three:
  version.dll
  the {PACK_NAME} folder   (only log files)
  Win64 > ovldata > {PACK_NAME}   (open Win64, then ovldata, delete the {PACK_NAME} folder inside)
Do not delete Win64 itself or anything else in it - that is the game's own data.
"""


def crlf(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\n", "\r\n")


def main() -> int:
    if not DLL_PATH.is_file():
        sys.exit(f"build version.dll first ({DLL_PATH})")
    pack = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    # CLAUDE.md rule 8: the filled overlay holds Frontier code; only the template + patches may ship.
    banned = [f for f in pack.rglob("*") if f.suffix.lower() in (".ppuipkg",) or f.name.lower() == "pz2coopui.ovl"]
    if banned:
        sys.exit(f"[make_installer] refusing to zip Frontier-derived files: {banned}")
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(DLL_PATH, "version.dll")
        for f in sorted(pack.rglob("*")):
            if f.is_file():
                z.write(f, f"Win64/ovldata/{PACK_NAME}/{f.relative_to(pack).as_posix()}")
        z.writestr("PZ2Coop-README.txt", crlf(README))
    print(f"[make_installer] wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
