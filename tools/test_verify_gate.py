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


def test_other_sessions_edits_do_not_block():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.bridge.lua")  # another session's uncommitted work
        assert vg.write_session_baseline(r, "s-1") == ["src/ovl_mod/pz2coop.bridge.lua"]
        assert not blocked(r, {"session_id": "s-1"})
        assert blocked(r, {"session_id": "s-unknown"})  # no baseline for this session: fail closed
        assert blocked(r)  # no session id (e.g. release check): every dirty file counts
        edit(r, "src/ovl_mod/pz2coop.bridge.lua")  # this session touches it again
        assert blocked(r, {"session_id": "s-1"})
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.bridge.lua")
        vg.write_session_baseline(r, "s-2")
        edit(r, "src/proxy_dll/dllmain.cpp")  # new edit by this session
        assert blocked(r, {"session_id": "s-2"})
        (r / "src/ovl_mod/pz2coop.bridge.lua").unlink()  # deleting a baselined file is a change too
        vg.write_session_baseline(r, "s-2")  # compact/resume: baseline is never rewritten
        assert vg.session_dirty_files(r, "s-2") == ["src/ovl_mod/pz2coop.bridge.lua", "src/proxy_dll/dllmain.cpp"]


def test_honest_reply_passes_first_stop():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        for msg in ("Planning only. Offline only, NOT verified in game.",
                    "Nothing is fixed: offline only, NOT verified in game.",
                    'The gate counts the word "fixed" as a claim. NOT verified in game.'):
            assert not blocked(r, {"last_assistant_message": msg}), msg
        assert blocked(r, {"last_assistant_message": "Path sync is fixed. NOT verified in game."})


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


def test_modular_autotest_files_tracked_as_tests():
    with repo() as r:
        assert not vg.is_production("src/ovl_mod/pz2coop.at_vehicle_bounds.lua")
        h0 = vg.compute_test_hash(r)
        (r / "src/ovl_mod/pz2coop.at_demo.lua").write_text("-- demo\n", encoding="utf-8")
        h1 = vg.compute_test_hash(r)
        assert h1 != h0
        assert vg.dirty_production_files(r) == []


def test_failure_packet_signatures_and_slice():
    lines = [(10, "61187781 LOG  lua: region sync: job failed: entity 123 at 0x7ff00a"),
             (11, "61187790 LOG  lua: region sync: job failed: entity 456 at 0x7ff00b"),
             (12, "61187799 LOG  lua: AUTOTEST_CHECK mp_path_own PASS | ok"),
             (13, "61187800 LOG  lua: AUTOTEST_CHECK mp_path_undo FAIL | undoHits=3"),
             (14, "61187801 LOG  lua: path query: hits=4"),
             (15, "61190375 FILE CreateFileW FAIL \\\\?\\C:\\game\\Manifest.xml"),  # file-open trace: noise
             (16, "61190399 LOG  lua: AUTOTEST_SUMMARY pass=10 fail=1")]
    sigs = live.failure_signatures(lines)
    assert sigs[0] == ("lua: region sync: job failed: entity # at 0x#", 2, 10), sigs
    # the PASS check, the info line, the FILE trace and the summary are not buckets
    assert len(sigs) == 2 and sigs[1][1:] == (1, 13), sigs
    many = [(i, f"error kind{chr(65 + i)}") for i in range(20)]
    assert len(live.failure_signatures(many)) == 12
    assert live.diag_slice(5, [30, 40], 90) == "DIAG_SLICE: diag.log:L20-L90"
    assert live.diag_slice(25, [30], 90) == "DIAG_SLICE: diag.log:L25-L90"  # never before this run's first line
    assert live.diag_slice(25, [], 90) == "DIAG_SLICE: diag.log:L25-L90"
    assert len(live.signature("x" * 500)) == 110


def test_hot_runs_never_stamp():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        hot = passing_meta(r, "abc") | {"hot": "1"}
        assert "hot run" in vg.write_stamp(r, "mirror_place", "abc", hot, True)
        assert not (r / vg.STAMP_REL).exists() and blocked(r)
        assert vg.write_stamp(r, "mirror_place", "abc", passing_meta(r, "abc"), True) is None  # cold run still stamps
    coop = pathlib.Path(tempfile.mkdtemp(prefix="pz2coop_trig_"))
    try:
        assert live.build_trigger("full", "r1", coop, False) == "full,run.r1"
        assert live.build_trigger("full", "r1", coop, True, "mp_path_undo", True) == \
            "full,run.r1,case.mp_path_undo,hot,stopfail"
    finally:
        shutil.rmtree(coop, ignore_errors=True)


def test_path_fixture_save_backup_restore():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="pz2coop_fx_"))
    coop, backup = tmp / "PZ2Coop", tmp / "fixtures"
    coop.mkdir()
    try:
        (coop / "path_3.bin").write_bytes(blueprint(2, 2))
        newest = coop / "path_9.bin"
        newest.write_bytes(blueprint(4, 4))
        import os
        os.utime(coop / "path_3.bin", (1, 1))  # older
        msg = live.save_path_fixture(coop, backup)
        assert "path_9.bin (4 chunks" in msg, msg
        assert (coop / "test_path.bin").read_bytes() == newest.read_bytes() == (backup / "test_path.bin").read_bytes()
        (coop / "test_path.bin").unlink()  # e.g. build_ovl_mod.py --uninstall wiped <game>/PZ2Coop
        (coop / "clip_12.bin").write_bytes(b"aquarium")
        live.ensure_fixtures("mirror_place", coop, backup)
        assert live.fixture_chunk_count((coop / "test_path.bin").read_bytes()) == 4  # restored from backup
        assert (backup / "test_aquarium.bin").read_bytes() == b"aquarium"  # every used fixture gets a backup
        newest.write_bytes(b"not a blueprint")
        os.utime(newest, None)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                live.save_path_fixture(coop, backup)
        except SystemExit as exc:
            assert "not a usable path blueprint" in str(exc)
        else:
            raise AssertionError("broken path blueprint accepted as fixture")
        assert live.fixture_chunk_count((backup / "test_path.bin").read_bytes()) == 4  # backup untouched
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_agent_status_is_short_and_read_only():
    import agent_status
    before = vg.git_changed(ROOT)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        saved, sys.argv = sys.argv, ["agent_status.py"]
        try:
            assert agent_status.main() == 0
        finally:
            sys.argv = saved
    out = buf.getvalue().splitlines()
    assert 3 <= len(out) <= agent_status.MAX_LINES and out[0].startswith("git: "), out
    assert vg.git_changed(ROOT) == before  # wrote nothing
    sym = agent_status.symbols(ROOT, "regionsync_logic")
    assert any("Logic.PlanPathChunks = function(" in s for s in sym), sym


def test_hot_logic_guard():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="pz2coop_hot_"))
    try:
        good = tmp / "pz2coop.demo_logic.lua"
        good.write_text("-- no api.* calls, no undo\nlocal L = {}\nL.F = function(a) return a + 1 end\nreturn L\n",
                        encoding="utf-8")
        assert live.check_hot_logic(good) is None
        assert "pairs(L)" in live.hot_logic_eval(good)
        for body in ("api.messaging.RegisterReceiver(1, f)", "local U = api.undo", "local B = require('x')",
                     "coroutine.yield()"):
            bad = tmp / "pz2coop.bad_logic.lua"
            bad.write_text("local L = {}\n" + body + "\nreturn L\n", encoding="utf-8")
            assert live.check_hot_logic(bad) is not None, body
        big = tmp / "pz2coop.big_logic.lua"
        big.write_text("local L = {}\n" + "-- pad\n" * 3000 + "return L\n", encoding="utf-8")
        assert "bytes >" in live.check_hot_logic(big)
        hooked = tmp / "pz2coop.regionsync.lua"
        hooked.write_text("return {}\n", encoding="utf-8")
        assert "only src/ovl_mod/pz2coop.*_logic.lua" in live.check_hot_logic(hooked)
        real = ROOT / "src" / "ovl_mod" / "pz2coop.regionsync_logic.lua"
        assert live.check_hot_logic(real) is None, live.check_hot_logic(real)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_offline_stamp_allows_only_when_live_cannot_run():
    with repo() as r:
        edit(r, "src/ovl_mod/pz2coop.regionsync.lua")
        saved = vg.live_blocker
        try:
            vg.live_blocker = lambda plans, game_dir=None: "live fixture(s) missing"
            assert blocked(r)  # no offline stamp yet
            vg.write_offline_stamp(r)
            code, msg = vg.gate(r, {})
            assert code == 0 and "NOT verified in game" in msg, msg
            edit(r, "src/ovl_mod/pz2coop.regionsync.lua")  # code changed after the offline run
            assert blocked(r)
            vg.write_offline_stamp(r)
            vg.live_blocker = lambda plans, game_dir=None: None  # live plan can run here: only a live PASS counts
            assert blocked(r)
        finally:
            vg.live_blocker = saved
        game, backup = r / "game", r / "backup"
        assert "game not installed" not in (vg.live_blocker(["mirror_place"], game, backup) or "")
        assert "test_path.bin" in vg.live_blocker(["mirror_place"], game, backup)
        (game / "PZ2Coop").mkdir(parents=True)
        (game / "PZ2Coop" / "path_6.bin").write_bytes(b"x")  # a stray path_<n>.bin is not the fixture
        (game / "PZ2Coop" / "test_aquarium.bin").write_bytes(b"x")
        assert "test_path.bin" in vg.live_blocker(["mirror_place"], game, backup)
        backup.mkdir()
        (backup / "test_path.bin").write_bytes(b"x")  # restorable from the build/fixtures backup
        assert vg.live_blocker(["mirror_place"], game, backup) is None
        assert vg.guard_stamp(r, {"tool_input": {"file_path": "build/offline_stamp.json"}})[0] == 2


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
