#!/usr/bin/env python3
"""Offline check for tools/pdb_symbols.py (run: python tools/test_pdb_symbols.py; needs tools/build_dll.py once)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pdb_symbols as ps  # noqa: E402


def main() -> int:
    if not ps.DLL.with_suffix(".pdb").is_file():
        print("SKIP: no version.pdb (run python tools/build_dll.py)")
        return 0
    va, text = ps.text_section(ps.DLL)
    syms = ps.Symbols()
    assert syms.ok, "dbghelp could not load version.pdb"
    found = 0
    for rva in range(va + 0x1000, va + len(text), len(text) // 50):  # sample code across .text
        name = syms.name(rva)
        if name:
            found += 1
            assert ps.translate(ps.DLL, rva) in (rva, None), f"self-translate moved 0x{rva:x}"
    assert found >= 25, f"only {found}/50 sampled addresses symbolized"
    print(f"ok: {found}/50 sampled version.dll addresses symbolized")
    return 0


if __name__ == "__main__":
    sys.exit(main())
