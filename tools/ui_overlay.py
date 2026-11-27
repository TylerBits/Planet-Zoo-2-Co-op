"""Reference implementation of the runtime UI-overlay build (version.dll ui_overlay.cpp does the same in C++).

Why: the release zip must not contain Frontier files (CLAUDE.md rule 8). So the zip ships
  - PZ2CoopUI.template: our UI overlay OVL with every patched vanilla file replaced by an empty slot
    ("/*PZ2COOP_SLOT <n> <size> <path>*/" + spaces), archive stored as uncompressed zlib blocks;
  - patch<n>.js: our anchor patch for slot n (src/ovl_ui/*_patch.js).
On the player's PC the DLL reads the vanilla file from the player's own UserInterfaceEssentials.ovl, applies the
patch, writes it into the slot (padded with spaces to the slot size) and fixes the zlib adler32. Sizes never change,
so no OVL header field changes.

Stdlib only (plus the game's oo2core_9_win64.dll for Oodle), so tests can check the C++ against it.
OVL layout: tools/cobra-tools/source/formats/ovl/ovl.xml (version 20, PZ2 user_version 8340 zlib / 8724 Oodle).
"""
from __future__ import annotations

import ctypes
import re
import struct
import zlib
from pathlib import Path

SLOT_RE = re.compile(rb"/\*PZ2COOP_SLOT (\d+) (\d+) ([^*\s]+)\*/")
COMPRESSION_ZLIB, COMPRESSION_OODLE = 1, 4
FIXED_HEADER = 144
ARCHIVE_ENTRY = 68


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def parse_header(ovl: bytes) -> dict:
    """Returns compression, end of header (= start of the STATIC archive) and the archive entries."""
    if ovl[:4] != b"FRES" or ovl[5] != 20:
        raise ValueError("not an OVL v20 file")
    user_version = u32(ovl, 8)
    (num_ovs_types, len_names, _zero2, num_aux, num_included, num_mimes, num_files, _nf2, num_deps,
     num_archives) = struct.unpack_from("<IIIIHHIIII", ovl, 12)
    (_npg, _np, _nd, _nb, num_stream_files, _z0, _z1, _z2, len_archive_names, _nf3, _ltn,
     num_triplets) = struct.unpack_from("<12I", ovl, 48)
    del num_ovs_types
    pos = FIXED_HEADER + len_names + num_mimes * 32
    pos += num_triplets * 3
    pos += (-num_triplets * 3) % 4
    pos += num_files * 12 + len_archive_names
    archives = []
    for i in range(num_archives):
        o = pos + i * ARCHIVE_ENTRY
        f = struct.unpack_from("<IIIIHHIIIIIIIQIII", ovl, o)
        archives.append({"entry_offset": o, "pools_offset": f[1], "num_pools": f[3], "num_datas": f[4],
                         "num_pool_groups": f[5], "num_buffer_groups": f[6], "num_buffers": f[7],
                         "num_fragments": f[8], "num_root_entries": f[9], "read_start": f[10],
                         "set_data_size": f[11], "compressed_size": f[12], "uncompressed_size": f[13]})
    pos += num_archives * ARCHIVE_ENTRY + num_included * 4 + num_deps * 20 + num_aux * 12
    pos += num_stream_files * 12 + num_archives * 8
    return {"compression": (user_version >> 7) & 7, "eof": pos, "archives": archives}


def oodle_decompress(dll: Path, data: bytes, size: int) -> bytes:
    lib = ctypes.WinDLL(str(dll))
    fn = lib.OodleLZ_Decompress
    fn.restype = ctypes.c_int64
    fn.argtypes = [ctypes.c_char_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int64] + [ctypes.c_int] * 3 + \
        [ctypes.c_void_p] * 6 + [ctypes.c_int]
    out = ctypes.create_string_buffer(size)
    if fn(data, len(data), out, size, 0, 0, 0, None, None, None, None, None, None, 3) != size:
        raise ValueError("Oodle decompression failed")
    return out.raw


def static_archive(ovl: bytes, oodle_dll: Path | None = None) -> tuple[dict, bytes]:
    """The first (STATIC) archive, decompressed."""
    hdr = parse_header(ovl)
    arc = hdr["archives"][0]
    raw = ovl[hdr["eof"]:hdr["eof"] + arc["compressed_size"]]
    if hdr["compression"] == COMPRESSION_OODLE:
        if oodle_dll is None:
            raise ValueError("Oodle archive needs oo2core_9_win64.dll")
        data = oodle_decompress(oodle_dll, raw, arc["uncompressed_size"])
    elif hdr["compression"] == COMPRESSION_ZLIB:
        data = zlib.decompress(raw)
    else:
        data = raw
    if len(data) != arc["uncompressed_size"]:
        raise ValueError("archive size mismatch")
    return arc, data


def find_ppuipkg_files(arc: dict, data: bytes, paths: list[str] | None) -> dict[str, bytes]:
    # paths=None returns every UIGameface/ file (used by extract_ui_textures.py).
    """ppuipkg file entries are {file_name ptr, file_size u64, file_content ptr}; pointers are fragments
    (link pool/offset -> struct pool/offset). A fragment whose target is one of our path strings is a
    file_name slot, so its file's size and content follow it."""
    pos = arc["num_pool_groups"] * 4
    pools_hdr = pos
    pos += arc["num_pools"] * 32 + arc["num_datas"] * 32 + arc["num_buffers"] * 8
    pos += arc["num_buffer_groups"] * 32 + arc["num_root_entries"] * 16
    frags_at = pos
    pos += arc["num_fragments"] * 16 + arc["set_data_size"]
    pool_start = []
    for i in range(arc["num_pools"]):
        pool_start.append(pos)
        pos += u32(data, pools_hdr + i * 32 + 8)
    links = {}
    wanted = {("UIGameface/" + p).encode() + b"\0": p for p in paths or ()}
    names = []
    for i in range(arc["num_fragments"]):
        lp, lo, sp, so = struct.unpack_from("<iIiI", data, frags_at + i * 16)
        links[(lp, lo)] = (sp, so)
        at = pool_start[sp] + so
        if paths is None:
            if data[at:at + 11] == b"UIGameface/":
                names.append((data[at + 11:data.index(b"\0", at)].decode(), lp, lo))
            continue
        for key, path in wanted.items():
            if data[at:at + len(key)] == key:
                names.append((path, lp, lo))
    found = {}
    for path, lp, lo in names:
        target = links.get((lp, lo + 16))
        if target is None:
            continue
        size = struct.unpack_from("<Q", data, pool_start[lp] + lo + 8)[0]
        at = pool_start[target[0]] + target[1]
        found[path] = data[at:at + size]
    return found


def strip_source_map(js: str) -> str:
    """Drops the trailing debug-only //# sourceMappingURL line (keeps slots small)."""
    return re.sub(r"\n//# sourceMappingURL=[^\n]*\s*$", "\n", js)


def stored_zlib(data: bytes) -> bytes:
    c = zlib.compressobj(level=0)
    return c.compress(data) + c.flush()


def stored_segments(z: bytes) -> list[tuple[int, int, int]]:
    """(file offset, data offset, length) of each stored block of a zlib stream; raises if not all stored."""
    segs, pos, out = [], 2, 0
    while True:
        head = z[pos]
        if head & ~1:
            raise ValueError("zlib stream is not made of byte-aligned stored blocks")
        ln, nln = struct.unpack_from("<HH", z, pos + 1)
        if ln ^ nln != 0xFFFF:
            raise ValueError("bad stored block length")
        segs.append((pos + 5, out, ln))
        pos += 5 + ln
        out += ln
        if head & 1:
            return segs


def make_template(ovl: bytes) -> bytes:
    """Re-stores a zlib OVL's single STATIC archive as uncompressed zlib blocks (same uncompressed size)."""
    hdr = parse_header(ovl)
    if hdr["compression"] != COMPRESSION_ZLIB or len(hdr["archives"]) != 1:
        raise ValueError("template must be a zlib OVL with one archive")
    arc = hdr["archives"][0]
    start, end = hdr["eof"], hdr["eof"] + arc["compressed_size"]
    body = stored_zlib(zlib.decompress(ovl[start:end]))
    out = bytearray(ovl[:start] + body + ovl[end:])
    struct.pack_into("<I", out, arc["entry_offset"] + 44, len(body))  # ArchiveEntry.compressed_size
    return bytes(out)


def fill_template(template: bytes, contents: dict[int, bytes]) -> bytes:
    """Writes contents[n] into slot n (space padded); recomputes adler32. Missing slot or oversize -> error."""
    hdr = parse_header(template)
    arc = hdr["archives"][0]
    start = hdr["eof"]
    out = bytearray(template)
    z = template[start:start + arc["compressed_size"]]
    segs = stored_segments(z)
    data = bytearray(arc["uncompressed_size"])
    for fpos, dpos, ln in segs:
        data[dpos:dpos + ln] = z[fpos:fpos + ln]
    seen = set()
    for m in SLOT_RE.finditer(bytes(data)):
        n, size = int(m.group(1)), int(m.group(2))
        if n not in contents:
            raise ValueError(f"no content for slot {n}")
        body = contents[n]
        if len(body) > size:
            raise ValueError(f"slot {n} too small ({len(body)} > {size})")
        data[m.start():m.start() + size] = body + b" " * (size - len(body))
        seen.add(n)
    if seen != set(contents):
        raise ValueError(f"slots missing in template: {sorted(set(contents) - seen)}")
    for fpos, dpos, ln in segs:
        out[start + fpos:start + fpos + ln] = data[dpos:dpos + ln]
    end = start + len(z)
    struct.pack_into(">I", out, end - 4, zlib.adler32(bytes(data)))
    return bytes(out)
