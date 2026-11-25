#!/usr/bin/env python3
"""Extract and decompile Planet Zoo 2 Lua scripts (docs/LUA_EXTRACTION_GUIDE.md).

Pipeline:
  1. Find <PZ2>/Win64/ovldata (Steam auto-detect or --game-dir). Missing/incomplete install -> exit 0.
  2. Unpack script-bearing .ovl archives with ./tools/cobra-tools into ./decompiled_lua/raw/.
  3. Files starting with b"\\x1bLua" are decompiled with ./tools/unluac.jar into ./decompiled_lua/vanilla/;
     plain-text .lua/.xml/.html/.js files are copied there as-is.

Usage:
  python tools/extract_all_lua.py [--game-dir PATH] [--all] [--skip-extract]
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

APP_ID = "3219030"
GAME_FOLDER = "Planet Zoo 2"
LUA_MAGIC = b"\x1bLua"
EXTRACT_TYPES = (".lua", ".xml", ".html", ".js")
TEXT_SUFFIXES = (".lua", ".xml", ".html", ".js")
# ovl names likely to carry scripts/UI; --all scans every archive instead.
SCRIPT_OVL_RE = re.compile(r"^(main|game.*|ui.*|userinterface(?!images).*|lua.*|archives?.*|script.*|config)\.ovl$", re.I)

REPO = Path(__file__).resolve().parent.parent
COBRA_DIR = REPO / "tools" / "cobra-tools"
UNLUAC_JAR = REPO / "tools" / "unluac.jar"
RAW_DIR = REPO / "decompiled_lua" / "raw"
VANILLA_DIR = REPO / "decompiled_lua" / "vanilla"


# --------------------------------------------------------------------------------------------
# Locating the game
# --------------------------------------------------------------------------------------------
def steam_roots() -> list[Path]:
    roots: list[Path] = []
    if sys.platform == "win32":
        import winreg

        for hive, key, value in (
            (winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
            (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
            (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath"),
        ):
            try:
                with winreg.OpenKey(hive, key) as k:
                    roots.append(Path(winreg.QueryValueEx(k, value)[0]))
            except OSError:
                pass
    roots += [Path(r"C:\Program Files (x86)\Steam"), Path.home() / ".steam" / "steam", Path.home() / ".local/share/Steam"]
    unique: list[Path] = []
    for r in roots:
        if r.is_dir() and r.resolve() not in [u.resolve() for u in unique]:
            unique.append(r)
    return unique


def steam_libraries() -> list[Path]:
    libs: list[Path] = []
    for root in steam_roots():
        libs.append(root)
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if vdf.is_file():
            text = vdf.read_text(encoding="utf-8", errors="replace")
            libs += [Path(p.replace("\\\\", "\\")) for p in re.findall(r'"path"\s+"([^"]+)"', text)]
    seen, out = set(), []
    for lib in libs:
        key = str(lib).lower()
        if key not in seen and lib.is_dir():
            seen.add(key)
            out.append(lib)
    return out


def find_game_dir() -> Path | None:
    for lib in steam_libraries():
        candidate = lib / "steamapps" / "common" / GAME_FOLDER
        if candidate.is_dir():
            return candidate
    return None


def install_state(game_dir: Path) -> str | None:
    """Returns a reason string if Steam reports the install as incomplete, else None."""
    manifest = game_dir.parent.parent / f"appmanifest_{APP_ID}.acf"
    if not manifest.is_file():
        return None  # not a Steam library layout (e.g. --game-dir copy); trust the files
    match = re.search(r'"StateFlags"\s+"(\d+)"', manifest.read_text(encoding="utf-8", errors="replace"))
    if match and int(match.group(1)) != 4:  # 4 = StateFullyInstalled
        return f"Steam StateFlags={match.group(1)} (download/update in progress)"
    return None


def resolve_ovldata(game_dir_arg: str | None) -> Path | None:
    if game_dir_arg:
        given = Path(game_dir_arg).expanduser()
        for candidate in (given / "Win64" / "ovldata", given / "ovldata", given):
            if candidate.name.lower() == "ovldata" and candidate.is_dir():
                return candidate
        return given / "Win64" / "ovldata"
    game_dir = find_game_dir()
    return game_dir / "Win64" / "ovldata" if game_dir else None


def not_ready(message: str) -> int:
    print(f"[extract_all_lua] {message}")
    print("[extract_all_lua] Re-run this script once the Planet Zoo 2 Steam download has finished.")
    return 0


# --------------------------------------------------------------------------------------------
# Extraction + decompilation
# --------------------------------------------------------------------------------------------
def load_cobra_tools():
    if not (COBRA_DIR / "generated" / "formats" / "ovl").is_dir():
        sys.exit(f"[extract_all_lua] cobra-tools not found at {COBRA_DIR}.\n"
                 f"  git clone --depth 1 https://github.com/OpenNaja/cobra-tools.git \"{COBRA_DIR}\"")
    sys.path.insert(0, str(COBRA_DIR))
    import logging

    # cobra-tools' GUI installs logging.success; its CLI (ovl_tool_cmd.py) shims it the same way.
    if not hasattr(logging, "success"):
        logging.success = logging.info
    try:
        from generated.formats.ovl import OvlFile  # noqa: E402  (cobra-tools package layout)
    except ImportError as exc:
        sys.exit(f"[extract_all_lua] cobra-tools import failed: {exc}\n"
                 f"  {sys.executable} -m pip install imageio numpy pillow bitarray")
    return OvlFile


def extract_ovls(ovls: list[Path], ovldata: Path) -> tuple[int, list[str]]:
    OvlFile = load_cobra_tools()
    extracted, failures = 0, []
    for i, ovl_path in enumerate(ovls, 1):
        rel = ovl_path.relative_to(ovldata).with_suffix("")
        out_dir = RAW_DIR / rel
        print(f"[{i}/{len(ovls)}] {ovl_path.relative_to(ovldata)}", flush=True)
        try:
            ovl = OvlFile()
            ovl.load(str(ovl_path), {})
            out_dir.mkdir(parents=True, exist_ok=True)
            extracted += len(ovl.extract(str(out_dir), only_types=EXTRACT_TYPES))
        except Exception as exc:  # one broken archive must not stop the batch
            failures.append(f"{ovl_path.relative_to(ovldata)}: {exc!r}")
    return extracted, failures


def vanilla_target(raw_file: Path) -> Path:
    rel = raw_file.relative_to(RAW_DIR)
    name = rel.name
    for suffix in (".lua.bin", ".luac"):
        if name.lower().endswith(suffix):
            name = name[: -len(suffix)] + ".lua"
    return VANILLA_DIR / rel.with_name(name)


def decompile_all() -> tuple[int, int, list[str]]:
    java = shutil.which("java")
    have_unluac = UNLUAC_JAR.is_file() and java is not None
    # PZ2 ships Frontier-modified Lua 5.3 bytecode (format byte 0x02, vec3 literals) that stock
    # unluac may reject; cobra-tools' bundled, Cobra-aware luadec is the fallback.
    load_cobra_tools()
    import logging

    logging.disable(logging.ERROR)  # luadec failures are collected and reported below instead
    from modules.formats.utils.lua_conversion import bin_to_lua

    if not have_unluac:
        print("[extract_all_lua] unluac.jar/java unavailable; using cobra-tools luadec only.")
    decompiled, copied, failures = 0, 0, []
    for raw_file in sorted(p for p in RAW_DIR.rglob("*") if p.is_file()):
        lower = raw_file.name.lower()
        if not (lower.endswith(TEXT_SUFFIXES) or lower.endswith((".lua.bin", ".luac"))):
            continue
        with raw_file.open("rb") as f:
            header = f.read(4)
        target = vanilla_target(raw_file)
        target.parent.mkdir(parents=True, exist_ok=True)
        if header == LUA_MAGIC:
            source, err = None, ""
            if have_unluac:
                result = subprocess.run([java, "-jar", str(UNLUAC_JAR), str(raw_file)], capture_output=True)
                if result.returncode == 0 and result.stdout:
                    source = result.stdout
                else:
                    err = result.stderr.decode(errors="replace").strip()
            if source is None:
                source, luadec_err = bin_to_lua(str(raw_file))
                err = err or luadec_err or ""
            if source:
                target.write_bytes(source)
                decompiled += 1
            else:
                failures.append(f"{raw_file.relative_to(RAW_DIR)}: {err[:200]}")
        elif lower.endswith(TEXT_SUFFIXES):
            shutil.copyfile(raw_file, target)
            copied += 1
    return decompiled, copied, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game-dir", help="Planet Zoo 2 install folder (or its Win64/ovldata folder)")
    parser.add_argument("--all", action="store_true", help="scan every .ovl, not just likely script archives")
    parser.add_argument("--skip-extract", action="store_true", help="only (re)decompile what is already in decompiled_lua/raw")
    args = parser.parse_args()

    if not args.skip_extract:
        ovldata = resolve_ovldata(args.game_dir)
        if ovldata is None:
            return not_ready("Planet Zoo 2 not found in any Steam library (use --game-dir).")
        if not ovldata.is_dir():
            return not_ready(f"{ovldata} does not exist yet.")
        reason = install_state(ovldata.parent.parent)
        if reason:
            return not_ready(f"Install incomplete: {reason}.")
        all_ovls = sorted(ovldata.rglob("*.ovl"))
        if not all_ovls:
            return not_ready(f"No .ovl archives in {ovldata} yet.")
        ovls = all_ovls if args.all else [p for p in all_ovls if SCRIPT_OVL_RE.match(p.name) or "GameMain" in p.parts]
        print(f"[extract_all_lua] {ovldata}: {len(ovls)} of {len(all_ovls)} archives selected")
        extracted, extract_failures = extract_ovls(ovls, ovldata)
        print(f"[extract_all_lua] cobra-tools wrote {extracted} files ({len(extract_failures)} archives failed)")
        for line in extract_failures:
            print(f"  ! {line}")

    if not RAW_DIR.is_dir():
        print("[extract_all_lua] decompiled_lua/raw/ is empty; nothing to decompile.")
        return 1 if not args.skip_extract else 0
    decompiled, copied, failures = decompile_all()
    print(f"[extract_all_lua] vanilla/: {decompiled} decompiled, {copied} plain-text copied, {len(failures)} failed")
    for line in failures[:50]:
        print(f"  ! {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
