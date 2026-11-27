"""Map an offset in our version.dll to function + source line with the build's PDB (Windows dbghelp, no installs).

  python tools/pdb_symbols.py 0x4f1d0 [0x...]              offsets in build/proxy_dll/Release/version.dll
  python tools/pdb_symbols.py --from old.dll 0x4f1d0       offsets in an older build: each return address is
                                                           found in the current build by its preceding code bytes
Used by tools/crashdump_info.py for version.dll stack refs.
"""
from __future__ import annotations

import ctypes
import pathlib
import struct
import sys
from ctypes import wintypes

ROOT = pathlib.Path(__file__).resolve().parents[1]
DLL = ROOT / "build" / "proxy_dll" / "Release" / "version.dll"
BASE = 0x180000000


class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [("SizeOfStruct", wintypes.ULONG), ("TypeIndex", wintypes.ULONG), ("Reserved", ctypes.c_uint64 * 2),
                ("Index", wintypes.ULONG), ("Size", wintypes.ULONG), ("ModBase", ctypes.c_uint64),
                ("Flags", wintypes.ULONG), ("Value", ctypes.c_uint64), ("Address", ctypes.c_uint64),
                ("Register", wintypes.ULONG), ("Scope", wintypes.ULONG), ("Tag", wintypes.ULONG),
                ("NameLen", wintypes.ULONG), ("MaxNameLen", wintypes.ULONG), ("Name", wintypes.WCHAR * 512)]


class IMAGEHLP_LINEW64(ctypes.Structure):
    _fields_ = [("SizeOfStruct", wintypes.DWORD), ("Key", ctypes.c_void_p), ("LineNumber", wintypes.DWORD),
                ("FileName", wintypes.LPWSTR), ("Address", ctypes.c_uint64)]


class Symbols:
    def __init__(self, dll: pathlib.Path = DLL):
        self.ok = dll.is_file() and dll.with_suffix(".pdb").is_file()
        if not self.ok:
            return
        self.dbg = ctypes.WinDLL("dbghelp")
        self.h = ctypes.c_void_p(0x50A2C00F)  # any unique value works as the session handle
        self.dbg.SymSetOptions(0x2 | 0x10)  # UNDNAME | LOAD_LINES
        self.dbg.SymInitializeW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR, wintypes.BOOL]
        self.dbg.SymLoadModuleExW.restype = ctypes.c_uint64
        self.dbg.SymLoadModuleExW.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wintypes.LPCWSTR, wintypes.LPCWSTR,
                                              ctypes.c_uint64, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
        self.dbg.SymFromAddrW.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64),
                                          ctypes.POINTER(SYMBOL_INFOW)]
        self.dbg.SymGetLineFromAddrW64.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(wintypes.DWORD),
                                                   ctypes.POINTER(IMAGEHLP_LINEW64)]
        self.ok = bool(self.dbg.SymInitializeW(self.h, str(dll.parent), False)) and \
            self.dbg.SymLoadModuleExW(self.h, None, str(dll), None, BASE, 0, None, 0) != 0

    def name(self, rva: int) -> str | None:
        if not self.ok:
            return None
        sym = SYMBOL_INFOW(SizeOfStruct=88, MaxNameLen=511)  # 88 = sizeof(SYMBOL_INFOW) in dbghelp.h
        disp = ctypes.c_uint64(0)
        if not self.dbg.SymFromAddrW(self.h, BASE + rva, ctypes.byref(disp), ctypes.byref(sym)):
            return None
        line = IMAGEHLP_LINEW64(SizeOfStruct=ctypes.sizeof(IMAGEHLP_LINEW64))
        ldisp = wintypes.DWORD(0)
        where = ""
        # Return addresses point after the call: look up the line of the byte before it.
        if self.dbg.SymGetLineFromAddrW64(self.h, BASE + rva - 1, ctypes.byref(ldisp), ctypes.byref(line)):
            where = f" ({pathlib.Path(line.FileName).name}:{line.LineNumber})"
        return f"{sym.Name}+0x{disp.value:x}{where}"


def text_section(path: pathlib.Path) -> tuple[int, bytes]:
    d = path.read_bytes()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    count = struct.unpack_from("<H", d, pe + 6)[0]
    sec = pe + 24 + struct.unpack_from("<H", d, pe + 20)[0]
    for i in range(count):
        name, vsize, va, _, raw = struct.unpack_from("<8sIIII", d, sec + 40 * i)
        if name.rstrip(b"\0") == b".text":
            return va, d[raw:raw + vsize]
    raise ValueError(f"no .text in {path}")


def translate(old: pathlib.Path, rva: int, new: pathlib.Path = DLL, width: int = 24) -> int | None:
    """RVA in `old` -> RVA of the same code in `new`, if the code bytes before it occur exactly once."""
    ova, otext = text_section(old)
    nva, ntext = text_section(new)
    at = rva - ova
    if at < width or at > len(otext):
        return None
    for w in (width, 40, 64):
        probe = otext[at - w:at]
        hit = ntext.find(probe)
        if hit >= 0 and ntext.find(probe, hit + 1) < 0:
            return nva + hit + w
    return None


def main(argv: list[str]) -> int:
    old = None
    if argv[:1] == ["--from"]:
        old, argv = pathlib.Path(argv[1]), argv[2:]
    syms = Symbols()
    if not syms.ok:
        sys.exit(f"no PDB next to {DLL}: run python tools/build_dll.py")
    for a in argv:
        rva = int(a, 16)
        mapped = translate(old, rva) if old else rva
        label = syms.name(mapped) if mapped is not None else "(code not found in current build)"
        print(f"version.dll+0x{rva:x} -> {label}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
