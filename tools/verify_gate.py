#!/usr/bin/env python3
"""Verification gate: workspace hashing, file-to-plan mapping and the Claude Code Stop hook.

Single source of truth for "was this mod code verified in the live game?":
  compute_mod_hash(root)   SHA-256 over every production mod/proxy/build source (what ships in the game).
  compute_test_hash(root)  SHA-256 over the live autotest driver and runner.
  build/verify_stamp.json  written ONLY by tools/test_live_game.py after an ALL PASSED run whose AUTOTEST_META
                           run_id and build_hash matched this workspace (see write_stamp / check_run_meta).

Usage:
  python tools/verify_gate.py               Stop hook: exit 0 = allow, exit 2 = block (reason on stderr, <= 3 lines)
  python tools/verify_gate.py --baseline    SessionStart hook: fallback per-file baseline, used only without git
  python tools/verify_gate.py --guard-stamp PreToolUse hook: blocks Edit/Write calls on build/verify_stamp.json

Dirty detection is git-anchored (changes against HEAD, untracked included), so a session restart never hides
unverified mod edits. Fail closed: a missing, unreadable or mismatched stamp blocks.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]

STAMP_REL = "build/verify_stamp.json"
BASELINE_REL = "build/verify_baseline.json"
COUNTER_REL = "build/verify_gate_blocks.txt"
MAX_CONSECUTIVE_BLOCKS = 2
GENERATED_META = "pz2coop.build_meta.lua"

PLAN_RULES = {
    "src/ovl_mod/pz2coop.regionsync.lua": ["mirror_place"],
    "src/ovl_mod/pz2coop.buildsync.lua": ["mirror_place"],
    "*": ["mirror_place"],
}

PROXY_SUFFIXES = {".cpp", ".hpp", ".h", ".c", ".cc", ".def", ".rc", ".cmake", ".manifest"}
TEST_FILES = ("src/ovl_mod/pz2coop.autotest.lua", "tools/test_live_game.py")


# ---- hashing ---------------------------------------------------------------------------------------------
def is_production(rel: str) -> bool:
    """rel: repo-relative POSIX path. Production = shipped mod Lua, proxy DLL sources, the OVL builder."""
    if rel == "tools/build_ovl_mod.py":
        return True
    if rel.startswith("src/ovl_mod/") and rel.endswith(".lua"):
        name = rel.rsplit("/", 1)[-1]
        return not name.endswith(".autotest.lua") and name != GENERATED_META
    if rel.startswith("src/proxy_dll/"):
        parts = rel.split("/")
        if any(p in ("build", "out", "x64", "Release", "Debug") for p in parts[2:-1]):
            return False
        name = parts[-1]
        return name == "CMakeLists.txt" or pathlib.PurePosixPath(name).suffix.lower() in PROXY_SUFFIXES
    return False


def production_files(root: pathlib.Path) -> list[str]:
    out = []
    for base in ("src/ovl_mod", "src/proxy_dll"):
        d = root / base
        if d.is_dir():
            out += [p.relative_to(root).as_posix() for p in d.rglob("*") if p.is_file()]
    if (root / "tools" / "build_ovl_mod.py").is_file():
        out.append("tools/build_ovl_mod.py")
    return sorted(r for r in set(out) if is_production(r))


def file_digest(root: pathlib.Path, rel: str) -> str:
    # CRLF -> LF so a checkout's line-ending conversion is not a code change.
    return hashlib.sha256((root / rel).read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def _hash_files(root: pathlib.Path, rels: list[str]) -> str:
    h = hashlib.sha256()
    for rel in sorted(rels):
        h.update(rel.encode("utf-8") + b"\0" + file_digest(root, rel).encode("ascii") + b"\n")
    return h.hexdigest()


def compute_mod_hash(root: pathlib.Path = ROOT) -> str:
    return _hash_files(root, production_files(root))


def compute_test_hash(root: pathlib.Path = ROOT) -> str:
    return _hash_files(root, [r for r in TEST_FILES if (root / r).is_file()])


# ---- dirty detection -------------------------------------------------------------------------------------
def git_changed(root: pathlib.Path) -> set[str] | None:
    """Every path changed against HEAD (staged, unstaged, untracked, deleted). None if git is unavailable."""
    try:
        st = subprocess.run(["git", "status", "--porcelain", "-z", "--untracked-files=all"], cwd=root,
                            capture_output=True, check=True)
        diff = subprocess.run(["git", "diff", "--name-only", "-z", "HEAD"], cwd=root, capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    changed: set[str] = set()
    fields = st.stdout.decode("utf-8", "replace").split("\0")
    i = 0
    while i < len(fields):
        entry = fields[i]
        i += 1
        if len(entry) < 4:
            continue
        changed.add(entry[3:])
        if entry[0] in "RC" and i < len(fields):  # rename/copy: the old path follows as its own field
            changed.add(fields[i])
            i += 1
    changed |= {p for p in diff.stdout.decode("utf-8", "replace").split("\0") if p}
    return changed


def write_baseline(root: pathlib.Path) -> None:
    path = root / BASELINE_REL
    if path.is_file():
        return  # never re-baseline over unverified edits
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({r: file_digest(root, r) for r in production_files(root)}, indent=1), encoding="utf-8")


def dirty_production_files(root: pathlib.Path = ROOT) -> list[str]:
    changed = git_changed(root)
    if changed is not None:
        return sorted(r for r in changed if is_production(r))
    try:
        base = json.loads((root / BASELINE_REL).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return production_files(root) or ["<no git and no baseline>"]  # fail closed
    now = {r: file_digest(root, r) for r in production_files(root)}
    return sorted(r for r in set(base) | set(now) if base.get(r) != now.get(r))


def required_plans(dirty: list[str]) -> list[str]:
    plans: set[str] = set()
    for rel in dirty:
        hits = [v for k, v in PLAN_RULES.items() if k != "*" and fnmatch.fnmatch(rel, k)]
        for v in hits or [PLAN_RULES["*"]]:
            plans.update(v)
    return sorted(plans)


# ---- stamp -----------------------------------------------------------------------------------------------
def load_stamp(root: pathlib.Path) -> dict | None:
    try:
        stamp = json.loads((root / STAMP_REL).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return stamp if isinstance(stamp, dict) else None


def stamp_problem(root: pathlib.Path, plans: list[str]) -> str | None:
    """None when the stamp proves a live PASS of every plan for exactly this workspace."""
    stamp = load_stamp(root)
    if stamp is None:
        return "no valid stamp"
    if stamp.get("mod_hash") != compute_mod_hash(root):
        return "stamp is for different mod code"
    if stamp.get("test_hash") != compute_test_hash(root):
        return "stamp is for a different autotest"
    passed = stamp.get("plans_passed")
    if not isinstance(passed, list) or not set(plans).issubset(passed):
        return "plan(s) not passed"
    return None


def check_run_meta(root: pathlib.Path, meta: dict | None, expected_run_id: str) -> str | None:
    """None when the AUTOTEST_META seen in diag.log belongs to this run and this workspace's mod code."""
    if not meta:
        return "no AUTOTEST_META for this run"
    if not expected_run_id or meta.get("run_id") != expected_run_id:
        return f"run_id mismatch (got {meta.get('run_id')!r})"
    if meta.get("build_hash") != compute_mod_hash(root) or meta.get("test_hash") != compute_test_hash(root):
        return "STALE BUILD: run build_ovl_mod.py --install"
    return None


def write_stamp(root: pathlib.Path, plan: str, run_id: str, meta: dict | None, all_ok: bool) -> str | None:
    """Writes/merges the stamp. Returns None when written, else why it was refused (stamp left untouched)."""
    if not all_ok:
        return "run failed"
    problem = check_run_meta(root, meta, run_id)
    if problem:
        return problem
    mod_hash, test_hash = compute_mod_hash(root), compute_test_hash(root)
    old = load_stamp(root) or {}
    plans = set(old.get("plans_passed") or []) if (old.get("mod_hash") == mod_hash and
                                                   old.get("test_hash") == test_hash) else set()
    plans.add(plan)
    path = root / STAMP_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "mod_hash": mod_hash,
        "test_hash": test_hash,
        "run_id": run_id,
        "plans_passed": sorted(plans),
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, indent=2), encoding="utf-8")
    return None


# ---- Stop hook -------------------------------------------------------------------------------------------
def final_message(payload: dict) -> str:
    msg = payload.get("last_assistant_message")
    if isinstance(msg, str):
        return msg
    transcript = payload.get("transcript_path")
    if not transcript:
        return ""
    try:
        lines = pathlib.Path(transcript).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "assistant":
            continue
        content = (entry.get("message") or {}).get("content")
        if isinstance(content, str) and content.strip():
            return content
        if isinstance(content, list):
            text = "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
            if text.strip():
                return text
    return ""


def honest_disclaimer(msg: str) -> bool:
    """The reply admits it is unverified and does not claim "fixed" without a quoted live PASS line."""
    if "NOT verified in game" not in msg:
        return False
    claims = re.sub(r"(?i)\b(not|never|isn't|wasn't|un)\s*(yet\s+)?fixed\b", "", msg)
    claims_fixed = re.search(r"(?i)\bfixed\b", claims) is not None
    return not claims_fixed or re.search(r"AUTOTEST_CHECK \S+ PASS", msg) is not None


def _counter(root: pathlib.Path, value: int | None = None) -> int:
    path = root / COUNTER_REL
    if value is None:
        try:
            return int(path.read_text(encoding="utf-8").strip() or 0)
        except (OSError, ValueError):
            return 0
    if value == 0:
        path.unlink(missing_ok=True)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(value), encoding="utf-8")
    return value


def gate(root: pathlib.Path, payload: dict) -> tuple[int, str]:
    """(exit code, stderr message). 0 = allow stop, 2 = block."""
    dirty = dirty_production_files(root)
    if not dirty:
        _counter(root, 0)
        return 0, ""
    plans = required_plans(dirty)
    if stamp_problem(root, plans) is None:
        _counter(root, 0)
        return 0, ""
    if payload.get("stop_hook_active") is True:
        if honest_disclaimer(final_message(payload)) or _counter(root) >= MAX_CONSECUTIVE_BLOCKS:
            _counter(root, 0)
            return 0, ""
    _counter(root, _counter(root) + 1)
    p = ",".join(plans)
    return 2, (f"BLOCKED: Mod code changed without live PASS for plan(s): {p}.\n"
               f"Run: python tools/build_ovl_mod.py --install && python tools/test_live_game.py --plan {p}\n"
               "Do not claim fixed.")


def guard_stamp(root: pathlib.Path, payload: dict) -> tuple[int, str]:
    tool_input = payload.get("tool_input") or {}
    target = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not target:
        return 0, ""
    path = pathlib.Path(target)
    if not path.is_absolute():
        path = root / path
    try:
        hit = path.resolve() == (root / STAMP_REL).resolve()
    except OSError:
        hit = path.name == "verify_stamp.json"
    if hit:
        return 2, "BLOCKED: build/verify_stamp.json is written only by tools/test_live_game.py."
    return 0, ""


def read_payload() -> dict:
    if sys.stdin is None or sys.stdin.isatty():
        return {}
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--baseline", action="store_true")
    group.add_argument("--guard-stamp", action="store_true")
    args = parser.parse_args()
    if args.baseline:
        if git_changed(ROOT) is None:
            write_baseline(ROOT)
        return 0
    payload = read_payload()
    code, msg = guard_stamp(ROOT, payload) if args.guard_stamp else gate(ROOT, payload)
    if msg:
        print(msg, file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
