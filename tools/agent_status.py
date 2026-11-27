#!/usr/bin/env python3
"""Read-only orientation for an agent session, in <= 25 lines (run: python tools/agent_status.py).

  python tools/agent_status.py                     git state, dirty mod files, verify stamp, last autotest lines
  python tools/agent_status.py --symbols region    file:line + signature of functions/constants in matching
                                                   src/ovl_mod/*.lua (instead of reading 70-170 KB files whole)
Writes nothing.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import verify_gate  # noqa: E402

AUTOTEST_RE = re.compile(r"AUTOTEST_(META|CHECK|TIMING|SUMMARY|DONE)")
SYMBOL_RE = re.compile(r"^(local function [\w.]+\s*\(.*|local [\w]+ = function\s*\(.*|[\w]+\.[\w]+ = function\s*\(.*"
                       r"|local c_\w+ = .*)$")
MAX_LINES = 25


def git_summary(root: pathlib.Path) -> list[str]:
    try:
        out = subprocess.run(["git", "status", "--short"], cwd=root, capture_output=True, text=True, check=True).stdout
        branch = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root, capture_output=True,
                                text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ["git: unavailable"]
    rows = [r for r in out.splitlines() if r.strip()]
    untracked = sum(1 for r in rows if r.startswith("??"))
    return [f"git: {branch}, {len(rows) - untracked} changed, {untracked} untracked"]


def stamp_summary(root: pathlib.Path) -> list[str]:
    dirty = verify_gate.dirty_production_files(root)
    if not dirty:
        return ["mod: no uncommitted production files (no live run required)"]
    plans = verify_gate.required_plans(dirty)
    shown = ", ".join(p.rsplit("/", 1)[-1] for p in dirty[:6]) + (f" +{len(dirty) - 6}" if len(dirty) > 6 else "")
    problem = verify_gate.stamp_problem(root, plans)
    offline = "ok" if verify_gate.offline_stamp_ok(root) else "stale/missing"
    return [f"mod: {len(dirty)} dirty production file(s): {shown}",
            f"stamp: {'VALID' if problem is None else problem} for plan(s) {','.join(plans)}; offline stamp {offline}"]


def autotest_lines(limit: int = 10) -> list[str]:
    try:
        from extract_all_lua import find_game_dir
        game = find_game_dir()
    except Exception:  # noqa: BLE001 - no Steam/registry
        game = None
    if game is None:
        return ["diag: game not installed"]
    for name in ("diag.log", "diag.prev.log"):
        log = pathlib.Path(game) / "PZ2Coop" / name
        if not log.is_file():
            continue
        hits = [ln.split("lua: ", 1)[-1].strip() for ln in log.read_text(encoding="utf-8", errors="replace").splitlines()
                if AUTOTEST_RE.search(ln)]
        if hits:
            return [f"diag ({name}, last {min(limit, len(hits))} autotest lines):"] + \
                ["  " + (h if len(h) <= 150 else h[:147] + "...") for h in hits[-limit:]]
    return ["diag: no AUTOTEST lines in diag.log / diag.prev.log (last session was not an autotest)"]


def symbols(root: pathlib.Path, substr: str) -> list[str]:
    out: list[str] = []
    for p in sorted((root / "src" / "ovl_mod").glob("*.lua")):
        if substr.lower() not in p.name.lower():
            continue
        for n, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = SYMBOL_RE.match(line)
            if m:
                sig = m.group(1)
                out.append(f"{p.relative_to(root).as_posix()}:{n}  {sig if len(sig) <= 110 else sig[:107] + '...'}")
    return out or [f"no src/ovl_mod/*.lua matching {substr!r}"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--symbols", metavar="MODULE_SUBSTR", help="list functions/constants of matching modules")
    args = parser.parse_args()
    if args.symbols:
        print("\n".join(symbols(ROOT, args.symbols)))  # on demand: may exceed 25 lines, it replaces a file read
        return 0
    lines = git_summary(ROOT) + stamp_summary(ROOT) + autotest_lines()
    print("\n".join(lines[:MAX_LINES]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
