r"""Print exception, faulting module and stack module refs for a PZ2 crash minidump.

Dumps: %LOCALAPPDATA%\Temp\Frontier Developments\Planet Zoo 2\CrashDumps\*.dmp (newest = last crash).
Run: python tools/crashdump_info.py <file.dmp>   (needs: pip install minidump). Stack refs are raw values,
so some are stale leftovers, not live frames.
"""
import struct
import sys

import logging

from minidump.minidumpfile import MinidumpFile

logging.disable(logging.CRITICAL)  # the PEB parse error on these dumps is harmless


def module_for(mods, addr):
    for m in mods:
        if m.baseaddress <= addr < m.baseaddress + m.size:
            return f"{m.name.split(chr(92))[-1]}+0x{addr - m.baseaddress:x}"
    return None


def main(path):
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
    print("stack refs:")
    for h in hits[:60]:
        print("  ", h)


if __name__ == "__main__":
    main(sys.argv[1])
