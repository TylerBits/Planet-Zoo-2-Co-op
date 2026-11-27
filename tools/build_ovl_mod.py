#!/usr/bin/env python3
"""Package src/ovl_mod into a Planet Zoo 2 content pack, and optionally install it.

Content pack layout (mirrors Win64/ovldata/Content0): <pack>/Manifest.xml + <pack>/Main.ovl.
The exe scans /run_platform/ovldata/ (= Win64/ovldata) for these folders; database.main.lua then
requires "Database.<Name>LuaDatabase" from each loaded pack.

PZ2 archives report OVL version 20 / user_version 8724, the Planet Coaster 2 generation, so the
cobra-tools "Planet Coaster 2" preset is used. Lua is packed as plain text (as cobra-tools mods do).

The pack also carries our UI overlay: a .ppuipkg (Gameface UI package, the same format vanilla overlays in
Content0/UI use) with the co-op screen and the main menu's Join Friends card (UI_NEW_FILES), plus patched copies
of a few vanilla files (UI_PATCHES; anchor patches in src/ovl_ui/). Lua loads it with api.ui2.LoadOverlay +
MapResources, and its files shadow the game's.

No Frontier file is ever packed (CLAUDE.md rule 8): the pack ships <pack>/UI/PZ2CoopUI.template (the overlay with
an empty slot per patched file, see tools/ui_overlay.py) and UI/patch<n>.js. version.dll fills the slots from the
player's own game files at start-up and writes UI/PZ2CoopUI.ovl there (src/proxy_dll/ui_overlay.cpp). The build
still applies every patch to the dev's installed game, so a moved anchor or a JS syntax error fails the build,
and it fills the template once in Python to check the result loads in cobra-tools.

Usage:
  python tools/build_ovl_mod.py              build into build/ovl_mod/PZ2Coop/
  python tools/build_ovl_mod.py --install    build, then copy the pack + version.dll into the game
  python tools/build_ovl_mod.py --uninstall  remove both from the game
"""
from __future__ import annotations

import argparse
import base64
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
from extract_all_lua import find_game_dir  # noqa: E402
import ui_overlay  # noqa: E402

PACK_NAME = "PZ2Coop"
PACK_GUID = "7A3C2F10-5E2B-4C61-9D3A-2B8E6F4C1D20"  # fixed so reinstalls keep the same pack identity
SRC_DIR = REPO / "src" / "ovl_mod"
OUT_DIR = REPO / "build" / "ovl_mod" / PACK_NAME
DLL_PATH = REPO / "build" / "proxy_dll" / "Release" / "version.dll"
COBRA = REPO / "tools" / "cobra-tools"
UI_DIR = REPO / "src" / "ovl_ui"
TMP_ROOT = Path(tempfile.gettempdir()) / "pz2coop_build"
UI_CACHE = TMP_ROOT / "ui_cache"
# Bytes reserved per patched vanilla file in the template (patched files are ~8-11 KB today).
UI_SLOT_SIZE = 65536
UI_OVERLAY = "PZ2CoopUI"
UI_ROOT = "UIGameface/"
# Vanilla UI files patched on the player's PC (slot n = n-th entry; our overlay shadows the game's copy).
UI_PATCHES = {
    "js/project/modules/Frontend/HomeButtons.js": "homebuttons_patch.js",
    "js/project/modules/PauseMenu/PauseMenu.js": "pausemenu_patch.js",
    "js/project/modules/PauseMenu/PauseMenuModule.js": "pausemenumodule_patch.js",
    "js/project/data/Schemas/BrowserItemsDatabase.js": "browseritemsdatabase_patch.js",
    "js/project/modules/Browser/BrowserUtils.js": "browserutils_patch.js",
}
# Our own UI files (new paths, nothing shadowed).
UI_NEW_FILES = {
    "js/project/modules/PZ2Coop/CoopMenu.js": "CoopMenu.js",
    "css/project/components/PZ2Coop/CoopMenu.css": "CoopMenu.css",
    "js/project/modules/PZ2Coop/JoinFriends.js": "JoinFriends.js",
    "css/project/components/PZ2Coop/JoinFriends.css": "JoinFriends.css",
    "js/project/modules/PZ2Coop/EmoteWheel.js": "EmoteWheel.js",
    "css/project/components/PZ2Coop/EmoteWheel.css": "EmoteWheel.css",
    "img/icons/PZ2Coop_Cheer.svg": "icons/PZ2Coop_Cheer.svg",
    "img/icons/PZ2Coop_Clap.svg": "icons/PZ2Coop_Clap.svg",
    "img/icons/PZ2Coop_Point.svg": "icons/PZ2Coop_Point.svg",
    "img/icons/PZ2Coop_Laugh.svg": "icons/PZ2Coop_Laugh.svg",
    "img/icons/PZ2Coop_Phone.svg": "icons/PZ2Coop_Phone.svg",
    "img/icons/PZ2Coop_Spooked.svg": "icons/PZ2Coop_Spooked.svg",
    "img/icons/PZ2Coop_Taunt.svg": "icons/PZ2Coop_Taunt.svg",
    "img/icons/PZ2Coop_Calm.svg": "icons/PZ2Coop_Calm.svg",
    "img/icons/PZ2Coop_Umbrella.svg": "icons/PZ2Coop_Umbrella.svg",
    "img/icons/PZ2Coop_Coffee.svg": "icons/PZ2Coop_Coffee.svg",
    "img/icons/PZ2Coop_IceCream.svg": "icons/PZ2Coop_IceCream.svg",
    "img/icons/PZ2Coop_Balloon.svg": "icons/PZ2Coop_Balloon.svg",
}
MANIFEST = f"""<ContentPack version="1">
  <Name>{PACK_NAME}</Name>
  <ID>{PACK_GUID}</ID>
  <Version>1</Version>
  <Type>Game</Type>
</ContentPack>"""


def load_cobra():
    sys.path.insert(0, str(COBRA))
    import logging

    if not hasattr(logging, "success"):
        logging.success = logging.info
    logging.disable(logging.WARNING)
    from generated.formats.ovl import OvlFile

    return OvlFile


def run_cobra_new(stage: Path, ovl: Path) -> None:
    cmd = [sys.executable, str(COBRA / "ovl_tool_cmd.py"), "new", "-g", "Planet Coaster 2",
           "-i", str(stage), "-o", str(ovl), "--force"]
    result = subprocess.run(cmd, cwd=COBRA, capture_output=True, text=True)
    if result.returncode != 0 or not ovl.is_file():
        sys.exit(f"cobra-tools failed:\n{result.stdout}\n{result.stderr}")


def fresh_dir(path: Path) -> Path:
    shutil.rmtree(path, ignore_errors=True)
    path.mkdir(parents=True, exist_ok=True)  # OneDrive can hold the folder open after rmtree
    for leftover in path.iterdir():
        leftover.unlink()
    return path


def vanilla_ui_files(paths: list[str]) -> dict[str, str]:
    """Vanilla UI files from the installed game's UI package, read the same way version.dll reads them."""
    game = find_game_dir()
    if game is None:
        sys.exit("Planet Zoo 2 not found (the UI patches are checked against the installed game)")
    src_ovl = game / "Win64" / "ovldata" / "GameMain" / "Content" / "UserInterfaceEssentials.ovl"
    arc, data = ui_overlay.static_archive(src_ovl.read_bytes(), game / "oo2core_9_win64.dll")
    found = ui_overlay.find_ppuipkg_files(arc, data, paths)
    missing = set(paths) - set(found)
    if missing:
        sys.exit(f"[build_ovl_mod] not found in {src_ovl}: {sorted(missing)}")
    return {p: found[p].decode("utf-8") for p in paths}

def apply_patch(vanilla: str, patch_file: Path) -> str:
    """Applies a patch file: "import ..." lines are hoisted to the top; each "@@ before|after <anchor>"
    section is inserted at its anchor ("@@ replace <anchor>" swaps the anchor for the section's text),
    which must occur exactly once (a game update that moves code fails the build instead of shipping a
    broken menu)."""
    imports: list[str] = []
    sections: list[tuple[str, str, list[str]]] = []
    for line in patch_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("@@ "):
            mode, _, anchor = line[3:].partition(" ")
            if mode not in ("before", "after", "replace") or not anchor:
                sys.exit(f"[build_ovl_mod] {patch_file.name}: bad section header {line!r}")
            sections.append((mode, anchor, []))
        elif sections:
            sections[-1][2].append(line)
        elif line.startswith("import "):
            imports.append(line)
    text = vanilla
    for mode, anchor, body in sections:
        if text.count(anchor) != 1:
            sys.exit(f"[build_ovl_mod] {patch_file.name}: anchor not found exactly once "
                     f"(game UI changed?): {anchor!r}")
        at = text.index(anchor)
        insert = "\n".join(body).rstrip()
        if mode == "replace":
            text = text[:at] + insert + text[at + len(anchor):]
            continue
        if mode == "after":
            at += len(anchor)
            insert = "\n" + insert
        else:
            # The inserted text takes the anchor's place on its line; the anchor moves to a new line
            # with its original indentation.
            line_start = text.rfind("\n", 0, at) + 1
            indent = text[line_start:at] if text[line_start:at].strip() == "" else ""
            insert = insert + "\n" + indent
        text = text[:at] + insert + text[at:]
    return "\n".join(imports + [text]) if imports else text


def check_js(files: dict[str, bytes]) -> None:
    """Syntax-checks every JS file with node (ES module mode) when node is installed."""
    node = shutil.which("node")
    if node is None:
        print("[build_ovl_mod] node not found, JS syntax check skipped")
        return
    tmp = fresh_dir(UI_CACHE / "check")
    for path, data in files.items():
        if path.endswith(".js"):
            target = tmp / (path.replace("/", "_")[:-3] + ".mjs")
            target.write_bytes(data)
            result = subprocess.run([node, "--check", str(target)], capture_output=True, text=True)
            if result.returncode != 0:
                sys.exit(f"[build_ovl_mod] JS syntax error in {path}:\n{result.stderr}")


def pack_ui_ovl(files: dict[str, bytes], ovl: Path) -> None:
    entries = "".join(
        f"""\t\t<ppuipkgfile file_size="{len(data)}">
\t\t\t<file_name>{UI_ROOT}{path}</file_name>
\t\t\t<file_content encoding="base64">{base64.b64encode(data).decode("ascii")}</file_content>
\t\t</ppuipkgfile>
""" for path, data in files.items())
    pkg = f"""<PPUIPKGRoot game="Planet Coaster 2">
\t<basic_path>{PACK_NAME}/UI</basic_path>
\t<files>
{entries}\t</files>
\t<icondata />
</PPUIPKGRoot>
"""
    stage = fresh_dir(TMP_ROOT / "stage_ui")
    (stage / f"{UI_OVERLAY.lower()}.ppuipkg").write_text(pkg, encoding="utf-8")
    run_cobra_new(stage, ovl)


def read_ui_ovl(ovl: Path) -> dict[str, bytes]:
    """Every file in a UI overlay, via cobra-tools (independent check of our own reader/writer)."""
    tmp = fresh_dir(UI_CACHE / "extract")
    archive = load_cobra()()
    archive.load(str(ovl), {})
    archive.extract(str(tmp), only_types=(".ppuipkg",))
    found = {}
    for pkg in tmp.glob("*.ppuipkg"):
        text = pkg.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"<file_name>" + re.escape(UI_ROOT) + r"([^<]+)</file_name>\s*"
                             r"<file_content encoding=\"base64\">([^<]*)</file_content>", text):
            found[m.group(1)] = base64.b64decode(m.group(2))
    shutil.rmtree(tmp, ignore_errors=True)
    return found


def build_ui(out_dir: Path) -> None:
    vanilla = vanilla_ui_files(list(UI_PATCHES))
    patched: dict[int, bytes] = {}
    files: dict[str, bytes] = {}
    for n, (path, patch) in enumerate(UI_PATCHES.items()):
        patched[n] = apply_patch(ui_overlay.strip_source_map(vanilla[path]), UI_DIR / patch).encode("utf-8")
        if len(patched[n]) > UI_SLOT_SIZE:
            sys.exit(f"[build_ovl_mod] {path}: patched file ({len(patched[n])} B) exceeds UI_SLOT_SIZE")
        files[path] = f"/*PZ2COOP_SLOT {n} {UI_SLOT_SIZE} {path}*/".encode("ascii").ljust(UI_SLOT_SIZE, b" ")
    for path, src in UI_NEW_FILES.items():
        files[path] = (UI_DIR / src).read_bytes()
    check_js({**{p: d for p, d in files.items() if p in UI_NEW_FILES},
              **{p: patched[n] for n, p in enumerate(UI_PATCHES)}})

    ui_out = out_dir / "UI"
    ui_out.mkdir(parents=True, exist_ok=True)
    (ui_out / f"{UI_OVERLAY}.ovl").unlink(missing_ok=True)  # never pack a filled overlay (it holds Frontier code)
    expected_patches = {f"patch{n}.js" for n in range(len(UI_PATCHES))}
    for stale in ui_out.glob("patch*.js"):
        if stale.name not in expected_patches:
            stale.unlink(missing_ok=True)
    zlib_ovl = TMP_ROOT / f"{UI_OVERLAY}.zlib.ovl"
    pack_ui_ovl(files, zlib_ovl)
    template = ui_overlay.make_template(zlib_ovl.read_bytes())
    for path, text in vanilla.items():
        probe = text.encode("utf-8")[len(text) // 2:len(text) // 2 + 200]
        if probe in template:
            sys.exit(f"[build_ovl_mod] template contains vanilla code from {path}")
    (ui_out / f"{UI_OVERLAY}.template").write_bytes(template)
    for n, patch in enumerate(UI_PATCHES.values()):
        (ui_out / f"patch{n}.js").write_bytes((UI_DIR / patch).read_bytes())

    # Fill once here, exactly as version.dll will, and check the result with cobra-tools.
    check = TMP_ROOT / "check" / f"{UI_OVERLAY}.ovl"
    check.parent.mkdir(parents=True, exist_ok=True)
    check.write_bytes(ui_overlay.fill_template(template, patched))
    got = read_ui_ovl(check)
    expected = {**{p: d for p, d in files.items() if p in UI_NEW_FILES},
                **{p: patched[n].ljust(UI_SLOT_SIZE, b" ") for n, p in enumerate(UI_PATCHES)}}
    if got != expected:
        sys.exit(f"[build_ovl_mod] filled template check failed: {sorted(set(got) ^ set(expected)) or 'content'}")

def build() -> Path:
    stage = fresh_dir(TMP_ROOT / "stage")
    sources = sorted(SRC_DIR.glob("*.lua"))
    if not sources:
        sys.exit(f"no .lua files in {SRC_DIR}")
    for src in sources:
        shutil.copyfile(src, stage / src.name)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ovl = OUT_DIR / "Main.ovl"
    tmp_ovl = TMP_ROOT / "Main.ovl"
    run_cobra_new(stage, tmp_ovl)
    ovl.write_bytes(tmp_ovl.read_bytes())
    (OUT_DIR / "Manifest.xml").write_text(MANIFEST, encoding="utf-8")
    verify(ovl, {s.name for s in sources})
    build_ui(OUT_DIR)
    print(f"[build_ovl_mod] built {OUT_DIR}")
    return OUT_DIR


def verify(ovl: Path, expected: set[str]) -> None:
    """Re-open the archive and check every script went in byte-identical."""
    archive = load_cobra()()
    archive.load(str(ovl), {})
    found = {name: loader for name, loader in archive.loaders.items() if name.endswith(".lua")}
    missing = expected - set(found)
    if missing:
        sys.exit(f"[build_ovl_mod] missing from archive: {sorted(missing)}")
    for name in expected:
        data = found[name].data_entry.buffer_datas[0].rstrip(b"\x00")
        if data != (SRC_DIR / name).read_bytes().rstrip(b"\x00"):
            sys.exit(f"[build_ovl_mod] {name} differs after packing")


def game_paths() -> tuple[Path, Path]:
    game = find_game_dir()
    if game is None:
        sys.exit("Planet Zoo 2 not found")
    return game / "Win64" / "ovldata" / PACK_NAME, game / "version.dll"


def install(pack: Path) -> None:
    pack_dst, dll_dst = game_paths()
    if not DLL_PATH.is_file():
        sys.exit(f"build version.dll first ({DLL_PATH})")
    shutil.copytree(pack, pack_dst, dirs_exist_ok=True)
    shutil.copyfile(DLL_PATH, dll_dst)
    print(f"[build_ovl_mod] installed {pack_dst}\n[build_ovl_mod] installed {dll_dst}")


def uninstall() -> None:
    pack_dst, dll_dst = game_paths()
    shutil.rmtree(pack_dst, ignore_errors=True)
    dll_dst.unlink(missing_ok=True)
    game = dll_dst.parent
    shutil.rmtree(game / PACK_NAME, ignore_errors=True)  # file-bridge folder created by version.dll
    print(f"[build_ovl_mod] removed {pack_dst}, {dll_dst}, {game / PACK_NAME}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--install", action="store_true")
    group.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    if args.uninstall:
        uninstall()
        return 0
    pack = build()
    if args.install:
        install(pack)
    return 0


if __name__ == "__main__":
    sys.exit(main())
