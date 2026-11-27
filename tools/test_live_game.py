#!/usr/bin/env python3
"""Autonomous live-game smoke & feature test runner (run: python tools/test_live_game.py --plan <plan>).

Zero human intervention:
  1. Closes any running PlanetZoo2.exe, snapshots existing CrashDumps and rotates diag.log to diag.prev.log.
  2. Writes <game>\\PZ2Coop\\autotest.txt ("<plan>,run.<run_id>[,expref.<n>]") so version.dll + pz2coop.autotest.lua
     drive the game automatically. run_id is a fresh nonce per run.
  3. Launches the real PlanetZoo2.exe and tails <game>\\PZ2Coop\\diag.log until AUTOTEST_DONE or timeout. Only lines
     after "AUTOTEST_META run_id=<this run> build_hash=<hash> plan=<plan>" count, and build_hash must equal
     verify_gate.compute_mod_hash() of this workspace and test_hash compute_test_hash() (else: STALE BUILD, the
     run fails).
  4. Closes PlanetZoo2.exe, inspects CrashDumps, prints one line per AUTOTEST_CHECK (MEASURE lines for FAILs
     only) and one final line: ALL PASSED or FAILED (passed/total). Full detail stays in diag.log.
  5. Only an ALL PASSED run with a matching META writes build/verify_stamp.json (verify_gate.write_stamp).
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import uuid
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from extract_all_lua import find_game_dir  # noqa: E402
import verify_gate  # noqa: E402

CRASH_DIR = pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Temp" / "Frontier Developments" / "Planet Zoo 2" / "CrashDumps"
BLUEPRINT_MAGIC = b"[Darwin-Blueprint][COMP]"
# Each path volume chunk record in a saved blueprint's VolumeManager section ends with this tail.
CHUNK_TAIL = b"\x07\x08\x00\x01\x08\x00\x01\x08\x00"
# Count byte, then the first chunk header "<id=1> <type> 03" and its first coordinate tag 0xb3.
CHUNK_HEAD = re.compile(rb"(.)\x01.\x03\xb3", re.DOTALL)


def kill_game() -> None:
    subprocess.run(["taskkill", "/IM", "PlanetZoo2.exe", "/F"], capture_output=True)  # 128 = not running: fine


def is_game_running() -> bool:
    res = subprocess.run(["tasklist", "/FI", "IMAGENAME eq PlanetZoo2.exe", "/NH"], capture_output=True, text=True)
    return "PlanetZoo2.exe" in res.stdout


def list_dumps() -> set[pathlib.Path]:
    if not CRASH_DIR.is_dir():
        return set()
    return set(CRASH_DIR.glob("*.dmp"))


def fixture_chunk_count(data: bytes) -> int:
    """Path volume chunks serialized in a path blueprint (the unit RegionSync logs as "N chunks" when saving).
    Two independent signals must agree (the count field and the per-chunk record tails), else ValueError.
    Checked against 9 sender-logged saves (3..14 chunks, diag.log 2026-11-27)."""
    if not data.startswith(BLUEPRINT_MAGIC):
        raise ValueError("not a compressed Darwin blueprint")
    raw = zlib.decompressobj(-15).decompress(data[len(BLUEPRINT_MAGIC):])
    at = raw.find(b"VolumeManager\x00")
    if at < 0:
        raise ValueError("no VolumeManager section")
    vm = raw[at:]
    end = vm.find(b"VolumeSurfaceManager")
    vm = vm[:end] if end > 0 else vm
    head = CHUNK_HEAD.search(vm)
    tails = vm.count(CHUNK_TAIL)
    if head is None or head.group(1)[0] != tails or tails == 0:
        raise ValueError(f"chunk count fields disagree (count={head and head.group(1)[0]}, records={tails})")
    return tails


META_RE = re.compile(r"AUTOTEST_META (.*)$")


def parse_meta(line: str) -> dict | None:
    m = META_RE.search(line)
    if m is None:
        return None
    return dict(kv.split("=", 1) for kv in m.group(1).split() if "=" in kv)


def record_result(root: pathlib.Path, plan: str, run_id: str, meta: dict | None, all_ok: bool) -> bool:
    """Writes build/verify_stamp.json only for a passing run of this build; returns whether it was written."""
    why = verify_gate.write_stamp(root, plan, run_id, meta, all_ok)
    if why is None:
        print(f"[live_test] stamp written: {verify_gate.STAMP_REL} (plan={plan})")
        return True
    print(f"[live_test] stamp NOT written: {why}")
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Autonomous live Planet Zoo 2 feature test runner")
    parser.add_argument("--timeout", type=int, default=None, help="Max seconds to wait for AUTOTEST_DONE")
    parser.add_argument("--plan", default="full", help="Autotest plan name")
    parser.add_argument("--keep-open", action="store_true", help="Do not close PlanetZoo2.exe when finished")
    args = parser.parse_args()
    timeout = args.timeout or (420 if args.plan == "mirror_place" else 180)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.plan):
        sys.exit("plan name: letters, digits, _ and - only")

    game = find_game_dir()
    if game is None:
        sys.exit("Planet Zoo 2 installation not found")
    exe = game / "PlanetZoo2.exe"
    coop_dir = game / "PZ2Coop"
    diag_log = coop_dir / "diag.log"
    baseline = coop_dir / "PZ2Coop_Baseline.bin"
    if not baseline.is_file():
        print(f"[live_test] WARNING: {baseline} not found; park load test will fail until one Sandbox save is copied there")

    kill_game()
    time.sleep(2.0)
    dumps_before = list_dumps()

    coop_dir.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex
    trigger = f"{args.plan},run.{run_id}"
    if args.plan == "mirror_place":
        # Fixtures are the player's own blueprints saved by the mod (never in git). Copied once to fixed names
        # so the mod's clip_/path_ slot recycling cannot overwrite them.
        for fixture, sources in (("test_path.bin", ("path_6.bin",)), ("test_aquarium.bin", ("clip_12.bin",))):
            target = coop_dir / fixture
            if not target.is_file():
                src = next((coop_dir / n for n in sources if (coop_dir / n).is_file()), None)
                if src is None:
                    sys.exit(f"[live_test] fixture {fixture} missing and no source ({', '.join(sources)}) to copy")
                shutil.copyfile(src, target)
                print(f"[live_test] fixture {fixture} <- {src.name}")
        # Independent expectation: chunks serialized in the fixture, never measured from the build under test.
        try:
            exp_ref = fixture_chunk_count((coop_dir / "test_path.bin").read_bytes())
        except ValueError as exc:
            sys.exit(f"[live_test] cannot read chunk count from test_path.bin: {exc}")
        trigger += f",expref.{exp_ref}"
        print(f"[live_test] test_path.bin holds {exp_ref} path chunks")
    # Fresh log per run. If another process holds diag.log open (a stale Frontier crash_reporter.exe does), start
    # past its current end instead; the DLL truncates it on launch, which the reader below follows.
    start_pos = 0
    if diag_log.is_file():
        try:
            os.replace(diag_log, coop_dir / "diag.prev.log")
        except PermissionError:
            start_pos = diag_log.stat().st_size
            print(f"[live_test] diag.log is locked by another process; reading from byte {start_pos}")
    (coop_dir / "autotest.txt").write_text(trigger, encoding="utf-8")

    steam_exe = game.parent.parent.parent / "steam.exe"
    if steam_exe.is_file():
        print(f"[live_test] launching via Steam -applaunch 3219030 (plan={args.plan}, run_id={run_id}, timeout={timeout}s)")
        subprocess.Popen([str(steam_exe), "-applaunch", "3219030"])
    else:
        print(f"[live_test] launching {exe} (plan={args.plan}, run_id={run_id}, timeout={timeout}s)")
        subprocess.Popen([str(exe)], cwd=str(game))

    t0 = time.monotonic()
    pos = start_pos
    seen_running = False
    gone_since: float | None = None
    meta: dict | None = None
    meta_problem: str | None = None
    checks: list[tuple[str, str, str]] = []
    measures: dict[str, str] = {}
    errors: list[str] = []
    done = False
    milestones = {
        "ui_overlay": False,
        "lua_bridge": False,
        "steam_lock": False,
        "menu_listener": False,
        "no_port_27099": False,
    }
    checked_port = False

    try:
        while time.monotonic() - t0 < timeout:
            running = is_game_running()
            if running:
                seen_running = True
                gone_since = None
            elif seen_running:
                if gone_since is None:
                    gone_since = time.monotonic()
                elif time.monotonic() - gone_since > 20.0:
                    errors.append("PlanetZoo2.exe exited early")
                    break
            elif time.monotonic() - t0 > 35.0:
                errors.append("PlanetZoo2.exe did not start within 35s (is Steam logged in?)")
                break

            if diag_log.is_file():
                size = diag_log.stat().st_size
                if size < pos:
                    pos = 0  # game restarted (SteamAPI_RestartAppIfNecessary): follow the new log
                if size > pos:
                    with diag_log.open("r", encoding="utf-8", errors="replace") as fh:
                        fh.seek(pos)
                        chunk = fh.read()
                        pos = fh.tell()
                    for line in chunk.splitlines():
                        if "ui overlay: built" in line or "ui overlay: up to date" in line:
                            milestones["ui_overlay"] = True
                        elif "Lua bridge connected" in line:
                            milestones["lua_bridge"] = True
                            if not checked_port:
                                checked_port = True
                                ns = subprocess.run(["netstat", "-ano"], capture_output=True, text=True)
                                milestones["no_port_27099"] = ":27099" not in ns.stdout
                        elif "SteamAPI_RunCallbacks now shares our Steam lock" in line:
                            milestones["steam_lock"] = True
                        elif "main menu co-op listener: added" in line:
                            milestones["menu_listener"] = True
                        elif "AUTOTEST_META " in line:
                            got = parse_meta(line)
                            if got and got.get("run_id") == run_id:
                                meta = got
                                meta_problem = verify_gate.check_run_meta(ROOT, meta, run_id)
                                print(f"AUTOTEST_META run_id={meta.get('run_id')} build_hash={meta.get('build_hash')} "
                                      f"test_hash={meta.get('test_hash')} plan={meta.get('plan')} "
                                      f"({'match' if meta_problem is None else meta_problem})")
                        elif "lua: error in " in line or "ui overlay: FAILED" in line:
                            errors.append(line.strip())
                        elif meta is None:
                            continue  # nothing before this run's META counts
                        elif "AUTOTEST_CHECK " in line:
                            body = line.split("AUTOTEST_CHECK ", 1)[1]
                            parts = body.split(" | ", 1)
                            head = parts[0].split()
                            name = head[0] if len(head) >= 1 else "?"
                            status = head[1] if len(head) >= 2 and head[1] == "PASS" else "FAIL"
                            detail = parts[1] if len(parts) > 1 else ""
                            checks.append((name, status, detail))
                            print(f"AUTOTEST_CHECK {name} {status} {detail}".rstrip())
                            if status == "FAIL" and name in measures:
                                print(f"  MEASURE {name} {measures[name]}")
                        elif "MEASURE " in line:
                            rest = line.split("MEASURE ", 1)[1].split(" ", 1)
                            measures[rest[0]] = rest[1] if len(rest) > 1 else ""
                        if "AUTOTEST_DONE" in line and meta is not None:
                            done = True
                            break
            if done:
                break
            time.sleep(0.5)
    finally:
        (coop_dir / "autotest.txt").unlink(missing_ok=True)
        if not args.keep_open:
            kill_game()

    # Frontier's crashpad keeps an empty locked .dmp while running and deletes it on clean exit;
    # only treat non-empty dumps left behind when AUTOTEST_DONE was NOT reached as a crash.
    time.sleep(0.5)
    new_dumps = [] if done else sorted(
        p for p in (list_dumps() - dumps_before) if p.is_file() and p.stat().st_size > 0
    )
    problems: list[str] = []
    if meta is None:
        problems.append(f"no AUTOTEST_META for run_id={run_id} (STALE BUILD? run build_ovl_mod.py --install)")
    elif meta_problem:
        problems.append(meta_problem)
    if not done:
        problems.append(f"AUTOTEST_DONE not reached within {timeout}s")
    problems += [f"boot:{k}" for k, v in milestones.items() if not v]
    problems += [f"runtime error: {e}" for e in errors[:10]]
    if new_dumps:
        problems.append(f"new crash dump(s): {[d.name for d in new_dumps]}")
        for d in new_dumps:
            subprocess.run([sys.executable, str(ROOT / "tools" / "crashdump_info.py"), str(d)])
    for p in problems:
        print(f"FAIL {p}")

    passed = sum(1 for _, st, _ in checks if st == "PASS")
    all_ok = not problems and len(checks) > 0 and passed == len(checks)
    record_result(ROOT, args.plan, run_id, meta, all_ok)
    print("ALL PASSED" if all_ok else f"FAILED ({passed}/{len(checks)})")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
