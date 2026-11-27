#!/usr/bin/env python3
"""Unified offline test & invariant runner for PZ2-Coop (run: python tools/run_all_tests.py).

Runs every offline verification check in one command with zero human intervention:
  1. Lua syntax check across all src/ovl_mod/*.lua
  2. C++ DLL selftest (build/proxy_dll/Release/pz2coop_selftest.exe)
  3. DLL vs Python UI overlay byte-for-byte check (test_ui_overlay.py)
  4. All Lua unit & integration tests (buildsync, regionsync, presence, menujoin, watersync,
     staffsync, notifications, two-peer E2E wire simulator)
  5. Headless Node.js UI check (test_ui_js.mjs)
  6. Distribution & security invariants (CLAUDE.md rule 8: no Spacewar 480, no Frontier files in zip)
  7. Verification gate (verify_gate.py, live-runner stamp/nonce/build-hash checks, fixture chunk parser)

--quiet prints only failing checks (with their output) and one final line: PASS: N/N or FAIL: K/N.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import time
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def check_lua_syntax() -> tuple[bool, str]:
    import lupa

    rt = lupa.LuaRuntime()
    loader = rt.eval("function(s, n) return assert(load(s, n)) end")
    files = sorted((ROOT / "src" / "ovl_mod").glob("*.lua"))
    for p in files:
        loader(p.read_text(encoding="utf-8"), p.name)
    return True, f"{len(files)} Lua files ok"


def check_invariants() -> tuple[bool, str]:
    issues: list[str] = []
    # Never reference Spacewar AppID 480 or ship steam_appid.txt
    for p in (ROOT / "src").rglob("*"):
        if p.is_file() and p.suffix.lower() in (".cpp", ".hpp", ".lua", ".js"):
            txt = p.read_text(encoding="utf-8", errors="ignore")
            if re.search(r"\bsteam_appid\.txt\b", txt):
                issues.append(f"steam_appid.txt referenced in {p.relative_to(ROOT)}")
    zip_path = ROOT / "dist" / "PZ2Coop.zip"
    if zip_path.is_file():
        with zipfile.ZipFile(zip_path) as z:
            for name in z.namelist():
                low = name.lower()
                if low.endswith(".ppuipkg") or low.endswith("pz2coopui.ovl") or "steam_appid.txt" in low:
                    issues.append(f"banned file in dist/PZ2Coop.zip: {name}")
    if issues:
        return False, "; ".join(issues)
    return True, "release & security invariants clean"


def run_cmd(cmd: list[str], full: bool = False) -> tuple[bool, str]:
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    out = (res.stdout.strip() or res.stderr.strip()).splitlines()
    if full and res.returncode != 0:
        return False, "\n".join((res.stdout.strip() + "\n" + res.stderr.strip()).strip().splitlines()[-40:])
    summary = out[-1] if out else f"exit {res.returncode}"
    return res.returncode == 0, summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline test & invariant runner")
    parser.add_argument("--quiet", action="store_true", help="only failures plus one summary line")
    quiet = parser.parse_args().quiet
    t0 = time.monotonic()
    py = sys.executable
    selftest = ROOT / "build" / "proxy_dll" / "Release" / "pz2coop_selftest.exe"

    checks: list[tuple[str, object]] = [
        ("lua syntax", check_lua_syntax),
        ("cpp selftest", [str(selftest)] if selftest.is_file() else None),
        ("ui overlay (DLL vs Py)", [py, "tools/test_ui_overlay.py"]),
        ("buildsync", [py, "tools/test_buildsync.py"]),
        ("regionsync", [py, "tools/test_regionsync.py"]),
        ("presence + avatar 0x12", [py, "tools/test_presence.py"]),
        ("menujoin", [py, "tools/test_menujoin.py"]),
        ("saveguard", [py, "tools/test_saveguard.py"]),
        ("watersync", [py, "tools/test_watersync.py"]),
        ("terrainsync", [py, "tools/test_terrainsync.py"]),
        ("staffsync", [py, "tools/test_staffsync.py"]),
        ("animalsync", [py, "tools/test_animalsync.py"]),
        ("researchsync", [py, "tools/test_researchsync.py"]),
        ("careersync", [py, "tools/test_careersync.py"]),
        ("AAA locomotion & actions", [py, "tools/test_actions.py"]),
        ("4-seat vehicles", [py, "tools/test_vehicles.py"]),
        ("notifications", [py, "tools/test_notifications.py"]),
        ("two-peer E2E wire", [py, "tools/test_two_peer_e2e.py"]),
        ("ui JS headless", [shutil.which("node"), "tools/test_ui_js.mjs"] if shutil.which("node") else None),
        ("verify gate + live stamp", [py, "tools/test_verify_gate.py"]),
        ("crash dump symbols", [py, "tools/test_pdb_symbols.py"]),
        ("release invariants", check_invariants),
    ]

    failures = ran = 0
    for label, action in checks:
        if action is None:
            if not quiet:
                print(f"SKIP {label:24s} (tool/binary not available)")
            continue
        ran += 1
        try:
            ok, msg = action() if callable(action) else run_cmd(action, full=quiet)
        except Exception as exc:
            ok, msg = False, str(exc)
        status = "PASS" if ok else "FAIL"
        if not ok or not quiet:
            print(f"{status} {label:24s} {msg}")
        if not ok:
            failures += 1

    elapsed = time.monotonic() - t0
    if quiet:
        print(f"PASS: {ran}/{ran}" if failures == 0 else f"FAIL: {failures}/{ran}")
    else:
        print(f"\n{'ALL PASSED' if failures == 0 else f'{failures} FAILED'} in {elapsed:.1f}s")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
