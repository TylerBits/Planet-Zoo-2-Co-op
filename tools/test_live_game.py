#!/usr/bin/env python3
"""Autonomous live-game smoke & feature test runner (run: python tools/test_live_game.py --plan <plan>).

Zero human intervention:
  - Supports --auto (change-detected build_dll + build_ovl_mod --install + run_all_tests.py --quiet) in 1 turn.
  - Passes -nointro -skipScenarioIntro -disablehelppopup -skipComms to skip intro movies/legal screens.
  - Supports --warm (reuse an already-running park) and --plan a,b,c (multi-plan batching in one game session).
  - Auto-kills crash_reporter.exe (prevents diag.log/.dmp locks) and auto-retries transient Steam early exits.
  - PASS prints only AUTOTEST_META / AUTOTEST_CHECK / TIMING lines and ALL PASSED. FAIL adds a failure packet:
    deduplicated error signatures with counts, top crash frames and a DIAG_SLICE line range into diag.log.
  - --case <name> runs one mirror_place case; --hot-logic <file> swaps a pure *_logic.lua module into the
    running game through the eval bridge first. Both, and --warm, are hot runs (META hot=1): never stamped.
  - Writes build/verify_stamp.json only for an ALL PASSED cold run whose AUTOTEST_META matches this workspace.
"""
from __future__ import annotations

import argparse
import hashlib
import json
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
INSTALL_HASH_FILE = ROOT / "build" / "last_install_hashes.json"
BLUEPRINT_MAGIC = b"[Darwin-Blueprint][COMP]"
CHUNK_TAIL = b"\x07\x08\x00\x01\x08\x00\x01\x08\x00"
CHUNK_HEAD = re.compile(rb"(.)\x01.\x03\xb3", re.DOTALL)
META_RE = re.compile(r"AUTOTEST_META (.*)$")
TIMING_RE = re.compile(r"AUTOTEST_TIMING (.*)$")
SIGNATURE_RE = re.compile(r"(error|fail|warn|crash|exception|timed out|dropped|refused)", re.IGNORECASE)
FAST_BOOT_ARGS = ["-nointro", "-skipScenarioIntro", "-disablehelppopup", "-skipComms"]
CASE_PLANS = ("mirror_place",)  # plans whose module honours ,case.<name>
HOT_LOGIC_MAX = 14 * 1024  # leaves room for the wrapper inside the 16 KB eval bridge
HOT_LOGIC_FORBIDDEN = (r"\bapi\s*\.", r"RegisterReceiver", r"\brequire\b", r"\bundo\b", r"\bcoroutine\b")


def kill_crash_reporter() -> None:
    subprocess.run(["taskkill", "/IM", "crash_reporter.exe", "/F"], capture_output=True)


def kill_game() -> None:
    subprocess.run(["taskkill", "/IM", "PlanetZoo2.exe", "/F"], capture_output=True)
    kill_crash_reporter()


def is_game_running() -> bool:
    res = subprocess.run(["tasklist", "/FI", "IMAGENAME eq PlanetZoo2.exe", "/NH"], capture_output=True, text=True)
    return "PlanetZoo2.exe" in res.stdout


def list_dumps() -> set[pathlib.Path]:
    if not CRASH_DIR.is_dir():
        return set()
    return set(CRASH_DIR.glob("*.dmp"))


def fixture_chunk_count(data: bytes) -> int:
    """Path volume chunks serialized in a path blueprint (independent expectation for mirror_place)."""
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


def parse_meta(line: str) -> dict | None:
    m = META_RE.search(line)
    if m is None:
        return None
    return dict(kv.split("=", 1) for kv in m.group(1).split() if "=" in kv)


def record_result(root: pathlib.Path, plan: str, run_id: str, meta: dict | None, all_ok: bool) -> bool:
    """Writes build/verify_stamp.json only for a passing run of this build; returns whether it was written.
    Prints only when the stamp is refused (the reason matters then)."""
    why = verify_gate.write_stamp(root, plan, run_id, meta, all_ok)
    if why is not None:
        print(f"[live_test] stamp NOT written: {why}")
    return why is None


def _hash_tree(paths: list[pathlib.Path]) -> str:
    h = hashlib.sha256()
    for p in sorted(set(paths)):
        if p.is_file():
            rel = p.relative_to(ROOT).as_posix()
            h.update(rel.encode("utf-8") + b"\0" + p.read_bytes().replace(b"\r\n", b"\n") + b"\n")
    return h.hexdigest()


def compute_dll_hash() -> str:
    d = ROOT / "src" / "proxy_dll"
    files = [p for p in d.rglob("*") if p.is_file() and (
        p.name == "CMakeLists.txt" or p.suffix.lower() in verify_gate.PROXY_SUFFIXES
    ) and not any(part in ("build", "out", "x64", "Release", "Debug") for part in p.parts)]
    return _hash_tree(files)


def compute_ovl_hash() -> str:
    files: list[pathlib.Path] = []
    for sub in ("src/ovl_mod", "src/ovl_ui"):
        d = ROOT / sub
        if d.is_dir():
            files += [p for p in d.rglob("*") if p.is_file() and p.name != verify_gate.GENERATED_META]
    b = ROOT / "tools" / "build_ovl_mod.py"
    if b.is_file():
        files.append(b)
    return _hash_tree(files)


def _load_install_hashes() -> dict:
    try:
        return json.loads(INSTALL_HASH_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save_install_hashes(data: dict) -> None:
    INSTALL_HASH_FILE.parent.mkdir(parents=True, exist_ok=True)
    INSTALL_HASH_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _run_quiet_step(cmd: list[str]) -> tuple[bool, float, str]:
    t0 = time.monotonic()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    dt = time.monotonic() - t0
    combined = ((res.stdout or "").strip() + "\n" + (res.stderr or "").strip()).strip()
    return res.returncode == 0, dt, combined


def run_pre_steps(args: argparse.Namespace) -> tuple[bool, bool]:
    """Runs requested build/install/offline steps quietly. Returns (ok, reinstalled)."""
    want_dll = args.build_dll
    want_install = args.install
    want_offline = args.offline or args.auto
    reinstalled = False

    prev = _load_install_hashes()
    cur_dll = compute_dll_hash()
    cur_ovl = compute_ovl_hash()
    cur_test = verify_gate.compute_test_hash(ROOT)
    dll_built = (ROOT / "build" / "proxy_dll" / "Release" / "version.dll").is_file()

    if args.auto:
        if prev.get("dll") != cur_dll or not dll_built:
            want_dll = True
            want_install = True
        if prev.get("ovl") != cur_ovl or prev.get("test") != cur_test:
            want_install = True

    if not (want_dll or want_install or want_offline):
        return True, False

    parts: list[str] = []
    py = sys.executable

    if want_dll:
        kill_game()
        time.sleep(0.5)
        ok, dt, out = _run_quiet_step([py, str(ROOT / "tools" / "build_dll.py")])
        if not ok:
            print(f"FAIL pre:build_dll ({dt:.1f}s)")
            print("\n".join(out.splitlines()[-25:]))
            return False, False
        parts.append(f"build_dll=ok({dt:.1f}s)")
    elif args.auto:
        parts.append("build_dll=skip")

    if want_install:
        kill_game()
        time.sleep(0.5)
        ok, dt, out = _run_quiet_step([py, str(ROOT / "tools" / "build_ovl_mod.py"), "--install"])
        if not ok:
            print(f"FAIL pre:build_ovl ({dt:.1f}s)")
            print("\n".join(out.splitlines()[-25:]))
            return False, False
        _save_install_hashes({"dll": cur_dll, "ovl": cur_ovl, "test": cur_test})
        reinstalled = True
        parts.append(f"build_ovl=ok({dt:.1f}s)")
    elif args.auto:
        parts.append("build_ovl=skip")

    if want_offline:
        ok, dt, out = _run_quiet_step([py, str(ROOT / "tools" / "run_all_tests.py"), "--quiet"])
        last = out.splitlines()[-1] if out else f"exit={int(not ok)}"
        if not ok:
            print(f"FAIL pre:offline ({dt:.1f}s)")
            print("\n".join(out.splitlines()[-25:]))
            return False, reinstalled
        parts.append(f"offline={last.replace('PASS: ', '').split(' ')[0]}({dt:.1f}s)")

    print("pre: " + " ".join(parts))
    return True, reinstalled


def signature(line: str, max_len: int = 110) -> str:
    """diag.log line -> bucket key: no tick/tag prefix, numbers and hex ids folded, bounded length."""
    s = re.sub(r"^﻿?\d+\s+[A-Z]+\s+", "", line.strip())
    s = re.sub(r"0x[0-9a-fA-F]+", "\0", s)
    s = re.sub(r"\d+(\.\d+)?", "#", s).replace("\0", "0x#")
    return s if len(s) <= max_len else s[: max_len - 3] + "..."


def is_problem_line(text: str) -> bool:
    """Error-like diag.log line. Not: FILE trace lines (the DLL's file-open log, misses are normal), passing
    checks, the pass/fail summary."""
    if re.match(r"^﻿?\d+\s+FILE\s", text) or "AUTOTEST_SUMMARY" in text:
        return False
    if "AUTOTEST_CHECK " in text and " PASS" in text:
        return False
    return SIGNATURE_RE.search(text) is not None


def failure_signatures(lines: list[tuple[int, str]], limit: int = 12) -> list[tuple[str, int, int]]:
    """(line no, text) -> [(signature, count, first line no)] for error-like lines, first-seen order, <= limit."""
    buckets: dict[str, list[int]] = {}
    for n, text in lines:
        if is_problem_line(text):
            buckets.setdefault(signature(text), [0, n])[0] += 1
    return [(k, v[0], v[1]) for k, v in list(buckets.items())[:limit]]


def diag_slice(first_line: int, sig_lines: list[int], last_line: int, context: int = 10) -> str:
    """The diag.log window a reader needs: from shortly before the first problem line to the end of the run."""
    start = max(first_line, min(sig_lines) - context) if sig_lines else first_line
    return f"DIAG_SLICE: diag.log:L{start}-L{max(start, last_line)}"


def check_hot_logic(path: pathlib.Path) -> str | None:
    """None when path is a pure logic module that may be hot swapped, else why not."""
    if not re.fullmatch(r"pz2coop\.[a-z0-9_]+_logic\.lua", path.name):
        return f"{path.name}: only src/ovl_mod/pz2coop.*_logic.lua modules can be hot swapped"
    if not path.is_file():
        return f"{path}: not found"
    data = path.read_bytes()
    if len(data) > HOT_LOGIC_MAX:
        return f"{path.name}: {len(data)} bytes > {HOT_LOGIC_MAX} (eval bridge limit)"
    code = re.sub(r"--[^\n]*", "", data.decode("utf-8"))
    hits = [p for p in HOT_LOGIC_FORBIDDEN if re.search(p, code)]
    return f"{path.name}: hooks/engine calls not allowed in a hot logic module: {hits}" if hits else None


def hot_logic_eval(path: pathlib.Path) -> str:
    """Eval payload: re-runs the module without a module name (it refills its shared _G table in place)."""
    return ("local L = (function(...)\n" + path.read_text(encoding="utf-8") + "\nend)()\n"
            "local n = 0 for _ in pairs(L) do n = n + 1 end\n"
            "return 'hot-logic " + path.name + " swapped ' .. n .. ' fields'\n")


def ensure_fixtures(plan: str, coop_dir: pathlib.Path, backup_dir: pathlib.Path | None = None) -> None:
    """Every fixture the plan needs is in coop_dir (restored from the build/fixtures backup, else copied from a
    listed source) and backed up there, so --uninstall or a lost <game>/PZ2Coop folder never loses it."""
    backup_dir = backup_dir or ROOT / verify_gate.FIXTURE_BACKUP_REL
    for fixture, sources in verify_gate.LIVE_FIXTURES.get(plan, ()):
        target, backup = coop_dir / fixture, backup_dir / fixture
        if not target.is_file():
            src = backup if backup.is_file() else next((coop_dir / n for n in sources if (coop_dir / n).is_file()), None)
            if src is None:
                hint = " (python tools/test_live_game.py --save-path-fixture)" if fixture == "test_path.bin" else ""
                sys.exit(f"[live_test] fixture {fixture} missing in {coop_dir} and {backup_dir}{hint}")
            shutil.copyfile(src, target)
        if not backup.is_file() or backup.read_bytes() != target.read_bytes():
            backup_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(target, backup)


def save_path_fixture(coop_dir: pathlib.Path, backup_dir: pathlib.Path | None = None) -> str:
    """Newest valid path_<n>.bin (a path the player drew while hosting) -> test_path.bin + build/fixtures backup."""
    backup_dir = backup_dir or ROOT / verify_gate.FIXTURE_BACKUP_REL
    found = sorted(coop_dir.glob("path_*.bin"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not found:
        sys.exit(f"[live_test] no path_*.bin in {coop_dir}: host, draw one path, wait ~2 s, then run this again")
    newest = found[0]
    try:
        chunks = fixture_chunk_count(newest.read_bytes())
    except ValueError as exc:
        sys.exit(f"[live_test] {newest.name} is not a usable path blueprint: {exc}")
    shutil.copyfile(newest, coop_dir / "test_path.bin")
    backup_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(newest, backup_dir / "test_path.bin")
    age = time.time() - newest.stat().st_mtime
    return (f"[live_test] test_path.bin <- {newest.name} ({chunks} chunks, saved {age:.0f}s ago); "
            f"backup {backup_dir / 'test_path.bin'}")


def build_trigger(plan: str, run_id: str, coop_dir: pathlib.Path, stop_on_fail: bool,
                  case: str | None = None, hot: bool = False) -> str:
    trigger = f"{plan},run.{run_id}"
    if plan == "mirror_place":
        ensure_fixtures(plan, coop_dir)
        try:
            exp_ref = fixture_chunk_count((coop_dir / "test_path.bin").read_bytes())
        except ValueError as exc:
            sys.exit(f"[live_test] cannot read chunk count from test_path.bin: {exc}")
        trigger += f",expref.{exp_ref}"
    if case:
        trigger += f",case.{case}"
    if hot:
        trigger += ",hot"
    if stop_on_fail:
        trigger += ",stopfail"
    return trigger


def run_single_plan(
    game: pathlib.Path,
    plan: str,
    timeout: int,
    warm: bool,
    keep_open: bool,
    stop_on_fail: bool,
    fast_boot: bool,
    max_retries: int,
    eval_code: str | None = None,
    case: str | None = None,
    hot: bool = False,
) -> tuple[bool, bool]:
    """Runs one plan (with auto-retry on transient Steam early-exit). Returns (all_ok, game_left_open)."""
    exe = game / "PlanetZoo2.exe"
    coop_dir = game / "PZ2Coop"
    diag_log = coop_dir / "diag.log"
    steam_exe = game.parent.parent.parent / "steam.exe"
    coop_dir.mkdir(parents=True, exist_ok=True)

    use_warm = warm and is_game_running()
    attempts = 1 if use_warm else (max_retries + 1)

    for attempt in range(1, attempts + 1):
        if not use_warm:
            kill_game()
            time.sleep(1.5)
        dumps_before = list_dumps()
        run_id = uuid.uuid4().hex
        # A reused game (warm) is hot too: earlier runs' state is still in it.
        run_hot = hot or use_warm
        trigger = build_trigger(plan, run_id, coop_dir, stop_on_fail, case, run_hot)

        start_pos = 0
        if use_warm:
            start_pos = diag_log.stat().st_size if diag_log.is_file() else 0
        else:
            if diag_log.is_file():
                try:
                    os.replace(diag_log, coop_dir / "diag.prev.log")
                except PermissionError:
                    start_pos = diag_log.stat().st_size
            boot_args = FAST_BOOT_ARGS if fast_boot else []
            if steam_exe.is_file():
                subprocess.Popen([str(steam_exe), "-applaunch", "3219030", *boot_args])
            else:
                subprocess.Popen([str(exe), *boot_args], cwd=str(game))
        # Line number of the first byte this run reads (diag.log lines are 1-based).
        line_no = 0
        if start_pos and diag_log.is_file():
            with diag_log.open("rb") as fh:
                line_no = fh.read(start_pos).count(b"\n")
        first_line = line_no + 1

        if eval_code is not None:
            (coop_dir / "autotest_eval.lua").write_text(eval_code, encoding="utf-8")
        (coop_dir / "autotest.txt").write_text(trigger, encoding="utf-8")

        t0 = time.monotonic()
        pos = start_pos
        seen_running = use_warm
        saw_log_growth = False
        gone_since: float | None = None
        meta: dict | None = None
        meta_problem: str | None = None
        timing_str: str | None = None
        checks: list[tuple[str, str, str]] = []
        measures: dict[str, str] = {}
        errors: list[str] = []
        diag_lines: list[tuple[int, str]] = []  # (line no, text) of this run, for the failure packet
        carry = ""  # a line the game had not finished writing yet
        done = False
        milestones = {
            "ui_overlay": use_warm,
            "lua_bridge": use_warm,
            "steam_lock": use_warm,
            "menu_listener": use_warm or (plan != "full"),
            "no_port_27099": use_warm,
        }
        checked_port = use_warm

        try:
            while time.monotonic() - t0 < timeout:
                running = is_game_running()
                if running:
                    seen_running = True
                    gone_since = None
                elif seen_running:
                    if gone_since is None:
                        gone_since = time.monotonic()
                    grace = 6.0 if saw_log_growth else 15.0
                    if time.monotonic() - gone_since > grace:
                        errors.append("PlanetZoo2.exe exited early")
                        break
                elif time.monotonic() - t0 > 35.0:
                    errors.append("PlanetZoo2.exe did not start within 35s (is Steam logged in?)")
                    break

                if diag_log.is_file():
                    size = diag_log.stat().st_size
                    if size < pos:
                        pos, line_no, carry = 0, 0, ""
                    if size > pos:
                        saw_log_growth = True
                        with diag_log.open("rb") as fh:
                            fh.seek(pos)
                            raw = fh.read()
                            pos = fh.tell()
                        parts = (carry + raw.decode("utf-8", errors="replace")).split("\n")
                        carry = parts.pop()
                        for line in parts:
                            line = line.rstrip("\r")
                            line_no += 1
                            diag_lines.append((line_no, line))
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
                                    hot_tag = " hot=1" if meta.get("hot") == "1" else ""
                                    case_tag = f" case={meta['case']}" if meta.get("case") else ""
                                    print(f"AUTOTEST_META run_id={meta.get('run_id')} build_hash={meta.get('build_hash')} "
                                          f"test_hash={meta.get('test_hash')} plan={meta.get('plan')}{hot_tag}{case_tag} "
                                          f"({'match' if meta_problem is None else meta_problem})")
                            elif "lua: error in " in line or "ui overlay: FAILED" in line:
                                errors.append(line.strip())
                            elif meta is None:
                                continue
                            elif "AUTOTEST_TIMING " in line:
                                m_t = TIMING_RE.search(line)
                                if m_t:
                                    timing_str = m_t.group(1)
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
            (coop_dir / "autotest_eval.lua").unlink(missing_ok=True)
            if not keep_open:
                kill_game()

        elapsed = time.monotonic() - t0
        time.sleep(0.5)
        kill_crash_reporter()
        new_dumps = [] if done else sorted(
            p for p in (list_dumps() - dumps_before) if p.is_file() and p.stat().st_size > 0
        )

        # Auto-retry transient Steam -applaunch early exit (no META, no crash dump, no Lua errors).
        is_transient_early_exit = (
            not use_warm
            and not done
            and meta is None
            and not new_dumps
            and elapsed < 35.0
            and errors == ["PlanetZoo2.exe exited early"]
        )
        if is_transient_early_exit and attempt < attempts:
            print(f"[live_test] transient Steam early-exit ({elapsed:.1f}s, 0 dumps); cooling down 6s and retrying...")
            time.sleep(6.0)
            continue

        problems: list[str] = []
        if meta is None:
            problems.append(f"no AUTOTEST_META for run_id={run_id} (STALE BUILD? run --auto or build_ovl_mod.py --install)")
        elif meta_problem:
            problems.append(meta_problem)
        if not done:
            problems.append(f"AUTOTEST_DONE not reached within {timeout}s")
        problems += [f"boot:{k}" for k, v in milestones.items() if not v]
        problems += [f"runtime error: {e}" for e in errors[:5]]
        if new_dumps:
            problems.append(f"new crash dump(s): {[d.name for d in new_dumps]}")

        passed = sum(1 for _, st, _ in checks if st == "PASS")
        all_ok = not problems and len(checks) > 0 and passed == len(checks)

        if timing_str:
            print(f"AUTOTEST_TIMING {timing_str} wall={elapsed:.1f}s")
        if not all_ok:
            # Failure packet: what failed, grouped error lines, crash frames, and where to read more.
            for p in problems:
                print(f"FAIL {p}")
            sigs = failure_signatures(diag_lines)
            if sigs:
                print("SIGNATURES:")
                for sig, n, first in sigs:
                    print(f"  [x{n}] L{first} {sig}")
            for d in new_dumps:
                print(f"CRASH {d.name}:")
                subprocess.run([sys.executable, str(ROOT / "tools" / "crashdump_info.py"), "--max-refs", "8", str(d)])
            last_line = diag_lines[-1][0] if diag_lines else first_line
            fail_lines = [n for n, t in diag_lines if is_problem_line(t)]
            print(diag_slice(first_line, fail_lines, last_line))

        stamp_note = ""
        if plan == "eval":
            pass
        elif run_hot:
            stamp_note = " (hot run: stamp not written)" if all_ok else ""
        elif all_ok:
            stamp_note = " (stamp written)" if record_result(ROOT, plan, run_id, meta, all_ok) else " (stamp NOT written)"
        print(f"ALL PASSED{stamp_note}" if all_ok else f"FAILED ({passed}/{len(checks)})")
        return all_ok, (keep_open and is_game_running())

    return False, False


def main() -> int:
    parser = argparse.ArgumentParser(description="Autonomous live Planet Zoo 2 feature test runner")
    parser.add_argument("--timeout", type=int, default=None, help="Max seconds to wait for AUTOTEST_DONE per plan")
    parser.add_argument("--plan", default="full", help="Autotest plan name or comma-separated list (e.g. a,b)")
    parser.add_argument("--keep-open", action="store_true", help="Do not close PlanetZoo2.exe when finished")
    parser.add_argument("--warm", action="store_true", help="Reuse an already-running park if PlanetZoo2.exe is open")
    parser.add_argument("--auto", action="store_true", help="Auto-build changed DLL/OVL, install, run offline tests, then live test")
    parser.add_argument("--build-dll", action="store_true", help="Rebuild version.dll before installing/running")
    parser.add_argument("--install", action="store_true", help="Run build_ovl_mod.py --install before running")
    parser.add_argument("--offline", action="store_true", help="Run run_all_tests.py --quiet before running")
    parser.add_argument("--retries", type=int, default=2, help="Auto-retries on transient Steam early exit (default: 2)")
    parser.add_argument("--stop-on-fail", action="store_true", help="Abort plan immediately on first FAIL check")
    parser.add_argument("--with-intro", action="store_true", help="Do not pass -nointro fast-boot flags")
    parser.add_argument("--eval", dest="eval_code", default=None, help="Run an inline Lua probe inside the loaded park")
    parser.add_argument("--eval-file", default=None, help="Run a Lua probe file (<=16 KB) inside the loaded park")
    parser.add_argument("--case", default=None, help="Run only this case of the plan (hot run: never stamped)")
    parser.add_argument("--hot-logic", default=None,
                        help="Swap a pure src/ovl_mod/pz2coop.*_logic.lua into the running game, then run --plan")
    parser.add_argument("--save-path-fixture", action="store_true",
                        help="Newest <game>/PZ2Coop/path_*.bin -> test_path.bin + build/fixtures backup, then exit")
    args = parser.parse_args()

    if args.save_path_fixture:
        game = find_game_dir()
        if game is None:
            sys.exit("Planet Zoo 2 installation not found")
        print(save_path_fixture(pathlib.Path(game) / "PZ2Coop"))
        return 0

    eval_code: str | None = args.eval_code
    if args.eval_file:
        eval_code = pathlib.Path(args.eval_file).read_text(encoding="utf-8")
    if args.hot_logic and eval_code is not None:
        sys.exit("[live_test] --hot-logic and --eval/--eval-file are separate runs")
    if args.hot_logic:
        why = check_hot_logic(pathlib.Path(args.hot_logic))
        if why:
            sys.exit(f"[live_test] --hot-logic refused: {why}")
        eval_code = hot_logic_eval(pathlib.Path(args.hot_logic))
    if eval_code is not None and len(eval_code.encode("utf-8")) > 16384:
        sys.exit("[live_test] --eval payload exceeds 16 KB limit")
    plans = [p.strip() for p in args.plan.split(",") if p.strip()]
    if args.hot_logic:
        plans = ["eval", *plans]
    elif eval_code is not None:
        plans = ["eval"]
    if not plans or any(not re.fullmatch(r"[A-Za-z0-9_-]+", p) for p in plans):
        sys.exit("plan name: letters, digits, _ and - only (comma-separated for batch)")
    if args.case is not None:
        if not re.fullmatch(r"[A-Za-z0-9_]+", args.case):
            sys.exit("case name: letters, digits and _ only")
        if any(p not in CASE_PLANS and p != "eval" for p in plans):
            sys.exit(f"--case is supported by: {', '.join(CASE_PLANS)}")
    hot = bool(args.warm or args.case or args.hot_logic)

    game = find_game_dir()
    if game is None:
        sys.exit("Planet Zoo 2 installation not found")

    ok_pre, reinstalled = run_pre_steps(args)
    if not ok_pre:
        return 1

    warm = (args.warm or eval_code is not None) and not reinstalled
    all_plans_ok = True
    try:
        for idx, plan in enumerate(plans):
            is_last = idx == len(plans) - 1
            plan_timeout = args.timeout or (420 if plan == "mirror_place" else 180)
            ok, left_open = run_single_plan(
                game=game,
                plan=plan,
                timeout=plan_timeout,
                warm=warm,
                keep_open=(not is_last) or args.keep_open,
                stop_on_fail=args.stop_on_fail,
                fast_boot=not args.with_intro,
                max_retries=args.retries,
                eval_code=eval_code if plan == "eval" else None,
                case=args.case if plan != "eval" else None,
                hot=hot,
            )
            if not ok:
                all_plans_ok = False
                break
            warm = left_open
    finally:
        if not args.keep_open:
            kill_game()

    return 0 if all_plans_ok else 1


if __name__ == "__main__":
    sys.exit(main())
