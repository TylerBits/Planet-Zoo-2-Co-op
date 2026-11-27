#!/usr/bin/env python3
"""One command for a live fix cycle (AGENTS.md rule 9 order), so an agent spends one tool call, not four.

  python tools/dev_cycle.py --plan mirror_place [--dry-run] [extra test_live_game.py args]

  1. close PlanetZoo2.exe (it locks version.dll)
  2. python tools/build_dll.py         only when src/proxy_dll sources changed since the last successful build
  3. python tools/build_ovl_mod.py --install
  4. python tools/test_live_game.py --plan <plan>
Stops at the first failing step and exits with its code.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import verify_gate  # noqa: E402

DLL_STAMP = ROOT / "build" / "proxy_dll" / "src_hash.txt"


def proxy_hash() -> str:
    rels = [r for r in verify_gate.production_files(ROOT) if r.startswith("src/proxy_dll/")]
    return verify_gate._hash_files(ROOT, rels)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--dry-run", action="store_true", help="print the steps without running them")
    args, extra = parser.parse_known_args()

    py = sys.executable
    src = proxy_hash()
    dll_built = DLL_STAMP.is_file() and DLL_STAMP.read_text(encoding="utf-8").strip() == src
    steps = [["taskkill", "/IM", "PlanetZoo2.exe", "/F"]]
    if not dll_built:
        steps.append([py, "tools/build_dll.py"])
    steps += [[py, "tools/build_ovl_mod.py", "--install"],
              [py, "tools/test_live_game.py", "--plan", args.plan, *extra]]

    for cmd in steps:
        print("[dev_cycle] " + " ".join(pathlib.Path(c).name if c == py else c for c in cmd), flush=True)
        if args.dry_run:
            continue
        if cmd[0] == "taskkill":
            subprocess.run(cmd, capture_output=True)  # exit 128 = game was not running
            continue
        code = subprocess.run(cmd, cwd=ROOT).returncode
        if code != 0:
            print(f"[dev_cycle] stopped: step failed with exit {code}")
            return code
        if cmd[-1] == "tools/build_dll.py":
            DLL_STAMP.write_text(src, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
