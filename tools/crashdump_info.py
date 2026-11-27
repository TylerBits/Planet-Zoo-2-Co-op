r"""Print exception, faulting module and stack module refs for a PZ2 crash minidump.

Dumps: %LOCALAPPDATA%\Temp\Frontier Developments\Planet Zoo 2\CrashDumps\*.dmp (newest = last crash).
Run: python tools/crashdump_info.py <file.dmp>   (needs: pip install minidump). Stack refs are raw values,
so some are stale leftovers, not live frames. version.dll refs get function + source line from
build/proxy_dll/Release/version.pdb (tools/pdb_symbols.py) when the dump's version.dll is that exact build;
for an older build: python tools/pdb_symbols.py --from <copy of that dll> <offsets>.
"""
import pathlib
import struct
import sys

import logging

from minidump.minidumpfile import MinidumpFile

logging.disable(logging.CRITICAL)  # the PEB parse error on these dumps is harmless
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pdb_symbols  # noqa: E402


def local_build_matches(mods) -> bool:
    """True when the dump's version.dll is build/proxy_dll/Release/version.dll (same PE timestamp and size)."""
    mod = next((m for m in mods if m.name.lower().endswith("\\version.dll")), None)
    if mod is None or not pdb_symbols.DLL.is_file():
        return False
    d = pdb_symbols.DLL.read_bytes()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    stamp = struct.unpack_from("<I", d, pe + 8)[0]
    size = struct.unpack_from("<I", d, pe + 24 + 56)[0]  # OptionalHeader.SizeOfImage
    return stamp == mod.timestamp and size == mod.size


def module_for(mods, addr):
    for m in mods:
        if m.baseaddress <= addr < m.baseaddress + m.size:
            return f"{m.name.split(chr(92))[-1]}+0x{addr - m.baseaddress:x}"
    return None


def main(path, max_refs: int = 60):
    mf = MinidumpFile.parse(path)
    mods = mf.modules.modules
    exc = mf.exception.exception_records[0] if mf.exception else None
    if exc is None:
        print("no exception stream")
        return
    rec = exc.ExceptionRecord
    tid = exc.ThreadId
    print(f"thread {tid} code {rec.ExceptionCode} flags {rec.ExceptionFlags} addr 0x{rec.ExceptionAddress:x} -> "
          f"{module_for(mods, rec.ExceptionAddress)}")
    print("params", [hex(p) for p in rec.ExceptionInformation[: rec.NumberParameters]])
    reader = mf.get_reader()
    thread = next((t for t in mf.threads.threads if t.ThreadId == tid), None)
    if thread is None:
        return
    # Context RSP is at offset 0x98 in a CONTEXT (x64); read via raw thread context bytes.
    ctx_loc = exc.ThreadContext
    with open(path, "rb") as f:
        f.seek(ctx_loc.Rva)
        ctx = f.read(ctx_loc.DataSize)
    rsp = struct.unpack_from("<Q", ctx, 0x98)[0]
    rip = struct.unpack_from("<Q", ctx, 0xF8)[0]
    print(f"rip 0x{rip:x} -> {module_for(mods, rip)}  rsp 0x{rsp:x}")
    stack = thread.Stack
    base = stack.StartOfMemoryRange
    with open(path, "rb") as f:
        f.seek(stack.MemoryLocation.Rva)
        data = f.read(stack.MemoryLocation.DataSize)
    start = max(0, rsp - base)
    hits = []
    for off in range(start, min(len(data) - 8, start + 0x8000), 8):
        v = struct.unpack_from("<Q", data, off)[0]
        name = module_for(mods, v)
        if name and not name.startswith(("ntdll", "KERNEL")):
            hits.append(name)
    syms = pdb_symbols.Symbols() if local_build_matches(mods) else None
    if syms is None or not syms.ok:
        print("(version.dll refs unsymbolized: dump is not from the local build or no PDB)")
    print("stack refs:")
    for h in hits[:max_refs]:
        label = ""
        if syms is not None and syms.ok and h.startswith("version.dll+0x"):
            label = f"  {syms.name(int(h.split('+0x')[1], 16)) or ''}"
        print("  ", h + label)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Inspect a PZ2 crash minidump")
    ap.add_argument("dump", help="Path to .dmp file")
    ap.add_argument("--max-refs", type=int, default=60, help="Max stack refs to print")
    ns = ap.parse_args()
    main(ns.dump, max_refs=ns.max_refs)
