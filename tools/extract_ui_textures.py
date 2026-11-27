#!/usr/bin/env python3
"""Dump Planet Zoo 2 UI textures and UI chrome into extracted/ui_textures/ (gitignored).

Output is Frontier-owned: local reference only. Never commit, package or publish it (CLAUDE.md rule 8).

  1. Content0/UI/UserInterfaceImagesC0*.ovl -> .tex as .png/.dds (cobra-tools).
  2. GameMain/Content/UserInterfaceEssentials.ovl -> every file inside its .ppuipkg (tools/ui_overlay.py reader),
     plus any .tex it holds.
  3. PlanetZoo2.exe cursor resources -> cursors/<group id>.cur + .png (Windows only, needs Pillow).

Usage:
  python tools/extract_ui_textures.py [--game-dir PATH] [--limit N] [--archive TEXT] [--skip-essentials] [--cursors-only]
"""
from __future__ import annotations

import argparse
import ctypes
import io
import logging
import struct
import sys
from bisect import bisect_left
from collections import Counter
from pathlib import Path

import ui_overlay
from extract_all_lua import REPO, load_cobra_tools, resolve_ovldata

OUT_DIR = REPO / "extracted" / "ui_textures"


def extract_textures(OvlFile, ovl_path: Path, out_dir: Path) -> bool:
    """Returns False if the archive failed or any of its textures produced no PNG."""
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        ovl = OvlFile()
        ovl.load(str(ovl_path), {})
        names = [n for n in ovl.loaders if n.lower().endswith(".tex")]
        if names:
            ovl.extract(str(out_dir), only_types=(".tex",))
    except Exception as exc:  # one broken archive must not stop the batch
        print(f"  ! {ovl_path.name}: {exc!r}")
        return False
    # PNG names may carry channel/tile suffixes after the texture's base name.
    pngs = sorted(p.relative_to(out_dir).as_posix().lower() for p in out_dir.rglob("*.png"))
    missing = []
    for name in names:
        base = name[:-len(".tex")].lower().removesuffix(".png")
        i = bisect_left(pngs, base)
        if i == len(pngs) or not pngs[i].startswith(base):
            missing.append(name)
    print(f"  {len(names)} textures, {len(pngs)} png, {len(missing)} without png")
    for name in missing[:10]:
        print(f"  ! no png: {name}")
    return not missing


def dump_ppuipkg(ovl_path: Path, oodle: Path, out_dir: Path) -> int:
    arc, data = ui_overlay.static_archive(ovl_path.read_bytes(), oodle)
    files = ui_overlay.find_ppuipkg_files(arc, data, None)
    root = out_dir.resolve()
    for name, content in files.items():
        target = (root / name).resolve()
        if not target.is_relative_to(root):
            raise ValueError(f"unsafe path in ppuipkg: {name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    kinds = Counter(Path(n).suffix.lower() for n in files)
    print(f"  {len(files)} ppuipkg files: {dict(kinds.most_common())}")
    return len(files)


def dump_cursors(exe: Path, out_dir: Path) -> int:
    """The cursors are plain Win32 RT_GROUP_CURSOR resources; the exe is mapped as data, nothing runs."""
    from ctypes import wintypes as w

    from PIL import Image

    k = ctypes.WinDLL("kernel32", use_last_error=True)
    callback = ctypes.WINFUNCTYPE(w.BOOL, w.HMODULE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
    for fn, res, args in (
        (k.LoadLibraryExW, w.HMODULE, [w.LPCWSTR, w.HANDLE, w.DWORD]),
        (k.FreeLibrary, w.BOOL, [w.HMODULE]),
        (k.EnumResourceNamesW, w.BOOL, [w.HMODULE, ctypes.c_void_p, callback, ctypes.c_void_p]),
        (k.FindResourceW, w.HRSRC, [w.HMODULE, ctypes.c_void_p, ctypes.c_void_p]),
        (k.SizeofResource, w.DWORD, [w.HMODULE, w.HRSRC]),
        (k.LoadResource, w.HGLOBAL, [w.HMODULE, w.HRSRC]),
        (k.LockResource, ctypes.c_void_p, [w.HGLOBAL]),
    ):
        fn.restype, fn.argtypes = res, args
    module = k.LoadLibraryExW(str(exe), None, 0x2)  # LOAD_LIBRARY_AS_DATAFILE
    if not module:
        raise ctypes.WinError(ctypes.get_last_error())

    def resource(kind: int, name: int) -> bytes:
        found = k.FindResourceW(module, name, kind)
        if not found:
            raise ctypes.WinError(ctypes.get_last_error())
        return ctypes.string_at(k.LockResource(k.LoadResource(module, found)), k.SizeofResource(module, found))

    ids: list[int] = []

    def collect(_module, _kind, name, _param):
        if name < 0x10000:  # integer resource id (all of this game's cursors)
            ids.append(name)
        return True

    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        k.EnumResourceNamesW(module, 12, callback(collect), None)  # RT_GROUP_CURSOR
        for group_id in ids:
            group = resource(12, group_id)
            images = []
            for i in range(struct.unpack_from("<H", group, 4)[0]):
                width, height, _planes, bits, _size, image_id = struct.unpack_from("<HHHHIH", group, 6 + i * 14)
                raw = resource(1, image_id)  # RT_CURSOR: u16 hotspot x, y, then the bitmap
                images.append((width, height // 2, bits, struct.unpack_from("<HH", raw), raw[4:]))
            # .cur stores the hotspot in the two fields where .ico stores planes/bit depth.
            for kind, suffix in ((2, ".cur"), (1, ".ico")):
                head, body = struct.pack("<HHH", 0, kind, len(images)), b""
                for width, height, bits, hotspot, bitmap in images:
                    a, b = hotspot if kind == 2 else (1, bits)
                    offset = 6 + 16 * len(images) + len(body)
                    head += struct.pack("<BBBBHHII", width & 255, height & 255, 0, 0, a, b, len(bitmap), offset)
                    body += bitmap
                if kind == 2:
                    (out_dir / f"{group_id}{suffix}").write_bytes(head + body)
                else:  # Pillow reads alpha correctly from .ico, so render the PNG through it
                    Image.open(io.BytesIO(head + body)).save(out_dir / f"{group_id}.png")
    finally:
        k.FreeLibrary(module)
    print(f"  {len(ids)} cursors")
    return len(ids)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game-dir", help="Planet Zoo 2 install folder (or its Win64/ovldata folder)")
    parser.add_argument("--limit", type=int, help="test run: only the first N image archives")
    parser.add_argument("--archive", help="only image archives whose file name contains TEXT")
    parser.add_argument("--skip-essentials", action="store_true", help="do not dump UserInterfaceEssentials.ovl")
    parser.add_argument("--cursors-only", action="store_true", help="only dump the cursors from PlanetZoo2.exe")
    args = parser.parse_args()

    ovldata = resolve_ovldata(args.game_dir)
    if ovldata is None or not ovldata.is_dir():
        print("[extract_ui_textures] Planet Zoo 2 not found (use --game-dir).")
        return 1
    exe = ovldata.parent.parent / "PlanetZoo2.exe"
    if args.cursors_only:
        return 0 if dump_cursors(exe, OUT_DIR / "cursors") else 1
    images = sorted(ovldata.glob("Content0/UI/UserInterfaceImagesC0*.ovl"))
    if args.archive:
        images = [p for p in images if args.archive.lower() in p.name.lower()]
    images = images[:args.limit]
    if not images:
        print("[extract_ui_textures] no UserInterfaceImagesC0*.ovl matched.")
        return 1

    OvlFile = load_cobra_tools()
    logging.disable(logging.INFO)  # cobra-tools logs several lines per texture
    ok = True
    for i, path in enumerate(images, 1):
        print(f"[{i}/{len(images)}] {path.name}", flush=True)
        ok &= extract_textures(OvlFile, path, OUT_DIR / path.stem)

    if not args.skip_essentials:
        essentials = ovldata / "GameMain" / "Content" / "UserInterfaceEssentials.ovl"
        print(essentials.name, flush=True)
        out_dir = OUT_DIR / essentials.stem
        ok &= dump_ppuipkg(essentials, ovldata.parent.parent / "oo2core_9_win64.dll", out_dir / "UIGameface") > 0
        ok &= extract_textures(OvlFile, essentials, out_dir / "tex")

    print(exe.name, flush=True)
    ok &= dump_cursors(exe, OUT_DIR / "cursors") > 0

    print(f"[extract_ui_textures] output: {OUT_DIR}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
