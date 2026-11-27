#!/usr/bin/env python3
"""Offline tests for tools/verify_gate.py and the stamp/nonce/build-hash checks in tools/test_live_game.py
(run: python tools/test_verify_gate.py). Each case runs in a throwaway git repo shaped like this one."""
from __future__ import annotations

import contextlib
import io
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import verify_gate as vg  # noqa: E402
import test_live_game as live  # noqa: E402

FILES = {
    "src/ovl_mod/pz2coop.regionsync.lua": "-- region sync\n",
    "src/ovl_mod/pz2coop.bridge.lua": "-- bridge\n",
    "src/ovl_mod/pz2coop.autotest.lua": "-- autotest\n",
    "src/proxy_dll/dllmain.cpp": "// dll\n",
    "tools/build_ovl_mod.py": "# build\n",
    "tools/test_live_game.py": "# live\n",
    "docs/notes.md": "notes\n",
}


def git(root: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)


@contextlib.contextmanager
def repo():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="pz2coop_gate_"))
    try:
        for rel, text in FILES.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text(text, encoding="utf-8")
        git(tmp, "init", "-q")
        git(tmp, "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A")
        git(tmp, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "base")
        yield tmp
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def edit(root: pathlib.Path, rel: str) -> None:
    with (root / rel).open("a", encoding="utf-8") as fh:
        fh.write("-- edit\n")


def passing_meta(root: pathlib.Path, run_id: str) -> dict:
    return {"run_id": run_id, "build_hash": vg.compute_mod_hash(root), "test_hash": vg.compute_test_hash(root),
            "plan": "mirror_place"}


def stamp(root: pathlib.Path, plan: str = "mirror_place") -> None:
    assert vg.write_stamp(root, plan, "r1", passing_meta(root, "r1"), True) is None


def blocked(root: pathlib.Path, payload: dict | None = None) -> bool:
    code, msg = vg.gate(root, payload or {})
    if code:
        assert len(msg.splitlines()) <= 3 and msg.startswith("BLOCKED:"), msg
    return code == 2


def test_dirty_without_stamp_blocks():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        assert vg.dirty_production_files(r) == ["src/ovl_mod/pz2coop.regionsync.lua"]
        assert vg.required_plans(vg.dirty_production_files(r)) == ["mirror_place"]
        assert blocked(r)


def test_stale_hash_or_missing_plan_blocks():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.bridge.lua")
        stamp(r)
        edit(r, "src/ovl_mod/pz2coop.bridge.lua")  # code changed after the PASS
        assert blocked(r)
    with repo() as r:
        edit(r, "src/proxy_dll/dllmain.cpp")
        stamp(r, plan="full")  # right hash, wrong plan
        assert blocked(r)
    with repo() as r:
        edit(r, "tools/build_ovl_mod.py")
        (r / vg.STAMP_REL).parent.mkdir(parents=True, exist_ok=True)
        (r / vg.STAMP_REL).write_text("{not json", encoding="utf-8")
        assert blocked(r)


def test_matching_stamp_allows():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        stamp(r)
        assert not blocked(r)


def test_test_only_edit_allows():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.autotest.lua")
        edit(r, "tools/test_live_game.py")
        edit(r, "docs/notes.md")
        (r / "src/ovl_mod" / vg.GENERATED_META).write_text("-- generated\n", encoding="utf-8")
        assert vg.dirty_production_files(r) == []
        assert not blocked(r)


def test_session_restart_still_blocks():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        assert blocked(r)
        (r / vg.COUNTER_REL).unlink(missing_ok=True)  # a new session starts with no hook state
        vg.write_baseline(r)  # SessionStart hook; ignored while git works
        assert blocked(r)
        git(r, "add", "-A")  # staging is not committing
        assert blocked(r)


def test_stop_hook_active_loop_guard():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        assert blocked(r)  # first stop: 1 block
        assert blocked(r, {"stop_hook_active": True, "last_assistant_message": "Path sync fixed."})  # 2 blocks
        assert not blocked(r, {"stop_hook_active": True, "last_assistant_message": "Path sync fixed."})  # cap
        assert blocked(r)  # counter reset after the allow
        assert not blocked(r, {"stop_hook_active": True,
                               "last_assistant_message": "Harness added; offline only, NOT verified in game."})
        assert blocked(r)
        claim = "NOT verified in game, but the bug is fixed."
        assert blocked(r, {"stop_hook_active": True, "last_assistant_message": claim})
        quoted = "Fixed: AUTOTEST_CHECK mp_path_own PASS expRef=24 ... (rest NOT verified in game)"
        assert not blocked(r, {"stop_hook_active": True, "last_assistant_message": quoted})
        transcript = r / "t.jsonl"
        transcript.write_text('{"type":"user","message":{"content":"hi"}}\n'
                              '{"type":"assistant","message":{"content":[{"type":"text","text":'
                              '"Bug not fixed yet, offline only, NOT verified in game."}]}}\n', encoding="utf-8")
        assert blocked(r)
        assert not blocked(r, {"stop_hook_active": True, "transcript_path": str(transcript)})


def test_live_runner_refuses_stale_or_foreign_runs():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        quiet = contextlib.redirect_stdout(io.StringIO())
        with quiet:
            assert not live.record_result(r, "mirror_place", "abc", None, True)  # no META
            assert not live.record_result(r, "mirror_place", "abc", {"build_hash": vg.compute_mod_hash(r)}, True)
            assert not live.record_result(r, "mirror_place", "abc", passing_meta(r, "other"), True)  # stale log
            assert not live.record_result(r, "mirror_place", "abc", {"run_id": "abc", "build_hash": "old"}, True)
            stale_test = passing_meta(r, "abc") | {"test_hash": "old"}  # installed autotest differs
            assert not live.record_result(r, "mirror_place", "abc", stale_test, True)
            assert not live.record_result(r, "mirror_place", "abc", passing_meta(r, "abc"), False)  # failed run
        assert not (r / vg.STAMP_REL).exists()
        with quiet:
            assert live.record_result(r, "mirror_place", "abc", passing_meta(r, "abc"), True)
        assert vg.load_stamp(r)["plans_passed"] == ["mirror_place"] and not blocked(r)
        assert live.parse_meta("12 LOG  lua: AUTOTEST_META run_id=abc build_hash=f00 plan=mirror_place") == \
            {"run_id": "abc", "build_hash": "f00", "plan": "mirror_place"}


def test_stamp_guard_blocks_direct_edits():
    with repo() as r:
        assert vg.guard_stamp(r, {"tool_input": {"file_path": str(r / "build" / "verify_stamp.json")}})[0] == 2
        assert vg.guard_stamp(r, {"tool_input": {"file_path": "build/verify_stamp.json"}})[0] == 2
        assert vg.guard_stamp(r, {"tool_input": {"file_path": str(r / "build" / "other.json")}})[0] == 0


def blueprint(n_count: int, n_records: int) -> bytes:
    records = b"".join(bytes([i + 1]) + b"\x06\x03\xb3" + b"\x00" * 8 + live.CHUNK_TAIL + b"\x00\x01"
                       for i in range(n_records))
    raw = b"CobraSav....VolumeManager\x00\x0c\x01\x00\x00\xc0\x9e" + bytes([n_count]) + records + \
        b"<<ClientClient>>VolumeSurfaceManager\x00"
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    return live.BLUEPRINT_MAGIC + comp.compress(raw) + comp.flush()


def test_fixture_chunk_count():
    assert live.fixture_chunk_count(blueprint(4, 4)) == 4
    for bad in (blueprint(5, 4), blueprint(0, 0), b"not a blueprint"):
        try:
            live.fixture_chunk_count(bad)
        except ValueError:
            continue
        raise AssertionError("mismatched fixture accepted")


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in tests:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"{len(tests) - failed}/{len(tests)} verify_gate tests passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
