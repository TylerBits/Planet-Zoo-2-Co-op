---
name: pz2-autotest
description: PZ2-Coop test loop runbook - orient with agent_status, iterate offline, iterate live with --warm/--case/--hot-logic, then mint the verify stamp with one clean cold run. Use before running, debugging or fixing anything with tools/test_live_game.py, or when a sync fix needs live proof.
---

# PZ2-Coop autotest loop

Each step is cheaper than the next. Do not move on until the current step passes.

## 1. Orient (1 call)
`python tools/agent_status.py`: git state, dirty production files, whether `build/verify_stamp.json` is valid for
the required plan(s), and the last autotest lines in diag.log. Need a function's location in a 70-170 KB module?
`python tools/agent_status.py --symbols <module_substr>` lists `file:line  signature`; then Read that line range
only. Edit large files with targeted Edit calls, never by rewriting them.

## 2. Offline (seconds)
`python tools/run_all_tests.py --quiet`: one line on PASS, failing checks with output on FAIL. Pure path/box logic
lives in `src/ovl_mod/pz2coop.regionsync_logic.lua` and is covered by `tools/test_regionsync.py` (including the
retail snapshot replay) and the mutation check (`tools/test_assertion_quality.py`). Reproduce a bug here first when
it can be expressed offline.

## Fixtures
`mirror_place` needs `<game>\PZ2Coop\test_path.bin` (a path blueprint) and `test_aquarium.bin`. Make the path
one once: host, draw one path, wait ~2 s, then `python tools/test_live_game.py --save-path-fixture` (newest
`path_*.bin` -> `test_path.bin`, backed up to `build/fixtures/`). Runs restore missing fixtures from that backup;
`build_ovl_mod.py --uninstall` deletes the whole `<game>\PZ2Coop` folder.

## 3. Live, hot (game stays open, never stamped)
Every run in this step prints `hot=1` in AUTOTEST_META and leaves the stamp alone. It is for finding the fix.
- First cold boot that keeps the game open: `python tools/dev_cycle.py --plan mirror_place --keep-open`.
- One failing case only: `python tools/test_live_game.py --plan mirror_place --case mp_path_undo --warm --keep-open`
  (case names: `mp_path_own`, `mp_path_editor`, `mp_aquarium_probe`, `mp_aquarium_own`, `mp_aquarium_editor`,
  `mp_path_undo`). Hot runs reset leftover sync state (queued jobs, echo areas, co-op undo journal) first.
- Changed only `pz2coop.regionsync_logic.lua`? Swap it into the open game, no reinstall:
  `python tools/test_live_game.py --hot-logic src/ovl_mod/pz2coop.regionsync_logic.lua --plan mirror_place
  --case mp_path_own --keep-open`. Refused when the file is over 14 KB or calls `api.*`, `require`, receivers,
  undo or coroutines. Changes to any other Lua file, UI JS or the DLL need a reinstall (step 4).
- Lua probes in the loaded park: `--eval "<lua>"` or `--eval-file tools/eval_probes/<probe>.lua` (<= 16 KB).
- Delegate long runs + log triage to the `pz2-tester` subagent; it returns a <= 30-line report with the verbatim
  `AUTOTEST_CHECK` lines.

## 4. Cold proof (mints the stamp)
`python tools/dev_cycle.py --plan mirror_place` (kill, build DLL if needed, install, full plan, cold). Only an
ALL PASSED cold run of the full plan writes `build/verify_stamp.json`; the runner prints `ALL PASSED (stamp
written)`. Quote the `AUTOTEST_CHECK ... PASS` lines in the reply (AGENTS.md rule 10). In a batch
(`--plan a,b`) only the first plan runs cold; run the required plan alone or first.
No live PASS? Say "offline only, NOT verified in game". Never loosen an assertion to get a PASS.

## Reading a FAIL
The runner prints `FAIL` problems, `SIGNATURES:` (deduplicated error lines with counts and first line), crash
frames, and `DIAG_SLICE: diag.log:L<a>-L<b>`. Read only that slice of
`<game>\PZ2Coop\diag.log`. Crash dumps: `python tools/crashdump_info.py <dmp>`.
