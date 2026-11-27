#!/usr/bin/env python3
"""Mutation smoke check: the offline suite must FAIL on each one-line bug below (run: python tools/test_assertion_quality.py).

Each mutant is applied in memory only (no file is written) and the test that guards that code is run against it.
A surviving mutant means an assertion got too weak to catch a real regression. A mutant whose source line no
longer exists fails too, so this list is updated whenever the guarded code changes.
"""
from __future__ import annotations

import contextlib
import importlib
import io
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
LOGIC = ROOT / "src" / "ovl_mod" / "pz2coop.regionsync_logic.lua"
GATE = ROOT / "tools" / "verify_gate.py"

# (name, file, original text, mutated text[, verify_gate test that must catch it])
MUTANTS = [
    ("path flag detection inverted", LOGIC,
     "return (math.tointeger(_nFlags) & math.tointeger(_nBit)) ~= 0",
     "return (math.tointeger(_nFlags) & math.tointeger(_nBit)) == 0"),
    ("sender drops chunks lying inside the grown area", LOGIC,
     "if _tBoxByChunk[nChunk] == nil and Logic.Inside(tWhole, rFit) then",
     "if false then"),
    ("receiver deletes own chunks reaching outside the area", LOGIC,
     "if rTol ~= nil and tWhole ~= nil and not Logic.Inside(tWhole, rTol) then",
     "if false then"),
    ("stale build_hash accepted", GATE,
     'if meta.get("build_hash") != compute_mod_hash(root) or meta.get("test_hash") != compute_test_hash(root):',
     "if False:", "test_live_runner_refuses_stale_or_foreign_runs"),
    ("hot run stamped", GATE,
     'if (meta or {}).get("hot") == "1":',
     "if False:", "test_hot_runs_never_stamp"),
]


def run_regionsync(logic_src: str) -> bool:
    """True when tools/test_regionsync.py fails with this logic module source."""
    mod = importlib.import_module("test_regionsync")
    saved = mod.SOURCES["PZ2Coop.RegionSync_Logic"]
    mod.SOURCES["PZ2Coop.RegionSync_Logic"] = logic_src
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return mod.main() != 0
    except Exception:  # noqa: BLE001 - a crash is a failing test too
        return True
    finally:
        mod.SOURCES["PZ2Coop.RegionSync_Logic"] = saved


def run_verify_gate(gate_src: str, test_name: str) -> bool:
    """True when test_name in tools/test_verify_gate.py fails with this verify_gate.py source (one test: each
    builds throwaway git repos, the whole file takes ~20 s)."""
    names = ("verify_gate", "test_live_game", "test_verify_gate", "agent_status")
    saved = {n: sys.modules.pop(n) for n in names if n in sys.modules}
    gate = types.ModuleType("verify_gate")
    gate.__file__ = str(GATE)
    try:
        exec(compile(gate_src, str(GATE), "exec"), gate.__dict__)  # noqa: S102 - our own file, mutated in memory
        sys.modules["verify_gate"] = gate
        tests = importlib.import_module("test_verify_gate")
        with contextlib.redirect_stdout(io.StringIO()):
            getattr(tests, test_name)()
        return False
    except Exception:  # noqa: BLE001 - AssertionError = caught, anything else = failing test too
        return True
    finally:
        for n in names:
            sys.modules.pop(n, None)
        sys.modules.update(saved)


def main() -> int:
    # Control: the unmutated sources must pass, or every "kill" below would only prove the harness is broken.
    if run_regionsync(LOGIC.read_text(encoding="utf-8")):
        print("FAIL: control run of test_regionsync fails on the unmutated logic module")
        return 1
    for test in sorted({m[4] for m in MUTANTS if len(m) > 4}):
        if run_verify_gate(GATE.read_text(encoding="utf-8"), test):
            print(f"FAIL: control run of {test} fails on the unmutated verify_gate.py")
            return 1
    survivors: list[str] = []
    for name, path, old, new, *test in MUTANTS:
        src = path.read_text(encoding="utf-8")
        if src.count(old) != 1:
            survivors.append(f"{name}: guarded line not found once in {path.name} (update MUTANTS)")
            continue
        mutated = src.replace(old, new)
        killed = run_regionsync(mutated) if path == LOGIC else run_verify_gate(mutated, test[0])
        if not killed:
            survivors.append(f"{name}: suite still passes ({path.name})")
    if survivors:
        for s in survivors:
            print("SURVIVED", s)
        print(f"FAIL: {len(survivors)}/{len(MUTANTS)} mutant(s) survived")
        return 1
    print(f"ok: {len(MUTANTS)}/{len(MUTANTS)} mutants killed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
