#!/usr/bin/env python3
"""Autonomous live-game smoke & feature test runner (run: python tools/test_live_game.py).

Zero human intervention:
  1. Closes any running PlanetZoo2.exe and snapshots existing CrashDumps.
  2. Writes <game>\\PZ2Coop\\autotest.txt so version.dll + pz2coop.autotest.lua drive the game automatically
     (main menu -> overlay check -> load Sandbox baseline zoo -> Host room -> loopback mirror ->
      notifications -> explore on foot + third person + own & friend 0x12 avatar -> water APIs ->
      staff hire & fire -> ledger -> leave).
  3. Launches the real PlanetZoo2.exe, tails <game>\\PZ2Coop\\diag.log live until AUTOTEST_DONE or timeout.
  4. Closes PlanetZoo2.exe cleanly, inspects CrashDumps for any new crash dumps (running crashdump_info.py
     automatically if one appeared), and prints a full PASS/FAIL report.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from extract_all_lua import find_game_dir  # noqa: E402

CRASH_DIR = pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Temp" / "Frontier Developments" / "Planet Zoo 2" / "CrashDumps"


def kill_game() -> None:
    subprocess.run(["taskkill", "/IM", "PlanetZoo2.exe", "/F"], capture_output=True)


def is_game_running() -> bool:
    res = subprocess.run(["tasklist", "/FI", "IMAGENAME eq PlanetZoo2.exe", "/NH"], capture_output=True, text=True)
    return "PlanetZoo2.exe" in res.stdout


def list_dumps() -> set[pathlib.Path]:
    if not CRASH_DIR.is_dir():
        return set()
    return set(CRASH_DIR.glob("*.dmp"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Autonomous live Planet Zoo 2 feature test runner")
    parser.add_argument("--timeout", type=int, default=180, help="Max seconds to wait for AUTOTEST_DONE")
    parser.add_argument("--plan", default="full", help="Autotest plan name")
    parser.add_argument("--keep-open", action="store_true", help="Do not close PlanetZoo2.exe when finished")
    args = parser.parse_args()

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
    # Record existing diag.log mtime so we know when the new launch opens a fresh log
    old_mtime = diag_log.stat().st_mtime if diag_log.is_file() else 0.0
    (coop_dir / "autotest.txt").write_text(args.plan, encoding="utf-8")

    steam_exe = game.parent.parent.parent / "steam.exe"
    if steam_exe.is_file():
        print(f"[live_test] launching via Steam: {steam_exe} -applaunch 3219030 (plan={args.plan}, timeout={args.timeout}s)")
        subprocess.Popen([str(steam_exe), "-applaunch", "3219030"])
    else:
        print(f"[live_test] launching {exe} (plan={args.plan}, timeout={args.timeout}s)")
        subprocess.Popen([str(exe)], cwd=str(game))

    t0 = time.monotonic()
    pos = 0
    seen_fresh_log = False
    seen_running = False
    gone_since: float | None = None
    checks: list[tuple[str, str, str]] = []
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
        while time.monotonic() - t0 < args.timeout:
            running = is_game_running()
            if running:
                if not seen_running:
                    print(f"[live_test] PlanetZoo2.exe is running ({time.monotonic() - t0:.1f}s)")
                seen_running = True
                gone_since = None
            elif seen_running:
                if gone_since is None:
                    gone_since = time.monotonic()
                elif time.monotonic() - gone_since > 20.0:
                    print("[live_test] PlanetZoo2.exe exited early")
                    break
            elif time.monotonic() - t0 > 35.0:
                print("[live_test] PlanetZoo2.exe did not start within 35s (is Steam logged in?)")
                break

            if diag_log.is_file():
                st = diag_log.stat()
                if not seen_fresh_log and st.st_mtime > old_mtime:
                    seen_fresh_log = True
                    pos = 0
                elif seen_fresh_log and st.st_size < pos:
                    # Game restarted (e.g. SteamAPI_RestartAppIfNecessary): follow the new log
                    pos = 0
                if seen_fresh_log and st.st_size > pos:
                    with diag_log.open("r", encoding="utf-8", errors="replace") as fh:
                        fh.seek(pos)
                        chunk = fh.read()
                        pos = fh.tell()
                    for line in chunk.splitlines():
                        if "ui overlay: built" in line or "ui overlay: up to date" in line:
                            milestones["ui_overlay"] = True
                            print(f"  [boot] {line}")
                        elif "Lua bridge connected" in line:
                            milestones["lua_bridge"] = True
                            print(f"  [boot] {line}")
                            if not checked_port:
                                checked_port = True
                                ns = subprocess.run(["netstat", "-ano"], capture_output=True, text=True)
                                milestones["no_port_27099"] = ":27099" not in ns.stdout
                                print(f"  [boot] netstat port 27099 absent: {milestones['no_port_27099']}")
                        elif "SteamAPI_RunCallbacks now shares our Steam lock" in line:
                            milestones["steam_lock"] = True
                            print(f"  [boot] {line}")
                        elif "main menu co-op listener: added" in line:
                            milestones["menu_listener"] = True
                            print(f"  [boot] {line}")
                        elif "AUTOTEST_CHECK " in line:
                            body = line.split("AUTOTEST_CHECK ", 1)[1]
                            parts = body.split(" | ", 1)
                            head = parts[0].split()
                            name = head[0] if len(head) >= 1 else "?"
                            status = head[1] if len(head) >= 2 else "FAIL"
                            detail = parts[1] if len(parts) > 1 else ""
                            checks.append((name, status, detail))
                            print(f"  [{status}] {name:20s} {detail}")
                        elif "AUTOTEST_SUMMARY" in line or "lua: autotest:" in line:
                            print(f"  [info] {line}")
                        elif "lua: error in " in line or "ui overlay: FAILED" in line:
                            errors.append(line)
                            print(f"  [ERR ] {line}")
                        if "AUTOTEST_DONE" in line:
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
    print("\n--- Live-Game Report ---")
    for k, v in milestones.items():
        print(f"  {'PASS' if v else 'FAIL'} boot:{k}")
    for name, status, detail in checks:
        print(f"  {status:4s} {name:20s} {detail}")
    if errors:
        print(f"  FAIL runtime errors logged ({len(errors)}):")
        for e in errors[:10]:
            print(f"    {e}")
    if new_dumps:
        print(f"  FAIL new crash dump(s): {[d.name for d in new_dumps]}")
        for d in new_dumps:
            subprocess.run([sys.executable, str(ROOT / "tools" / "crashdump_info.py"), str(d)])

    all_ok = (
        done
        and all(milestones.values())
        and len(checks) > 0
        and all(st == "PASS" for _, st, _ in checks)
        and not errors
        and not new_dumps
    )
    print(f"\nLIVE GAME RESULT: {'ALL PASSED' if all_ok else 'FAILED'} ({time.monotonic() - t0:.1f}s)")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
