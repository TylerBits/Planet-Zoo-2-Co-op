"""Checks version.dll's runtime UI-overlay build against the Python reference (run: python tools/test_ui_overlay.py).

Needs the game installed and `python tools/build_dll.py` + `python tools/build_ovl_mod.py` run first.
Runs pz2coop_selftest --ui-overlay (the DLL's own build code) on a copy of build/ovl_mod/PZ2Coop/UI and compares
its PZ2CoopUI.ovl byte for byte with build/ovl_mod/check/PZ2CoopUI.ovl (tools/ui_overlay.py, already verified
with cobra-tools by the build). Also checks a broken patch makes the DLL fail cleanly and remove its output.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from extract_all_lua import find_game_dir  # noqa: E402
import build_ovl_mod  # noqa: E402
import ui_overlay  # noqa: E402

SELFTEST = ROOT / "build" / "proxy_dll" / "Release" / "pz2coop_selftest.exe"
PACK_UI = ROOT / "build" / "ovl_mod" / "PZ2Coop" / "UI"
REFERENCE = build_ovl_mod.TMP_ROOT / "check" / "PZ2CoopUI.ovl"


def run(game: Path, ui: Path) -> subprocess.CompletedProcess:
    return subprocess.run([str(SELFTEST), "--ui-overlay", str(game), str(ui)], capture_output=True, text=True)


def build_reference(game: Path) -> bytes:
    if REFERENCE.is_file():
        return REFERENCE.read_bytes()
    vanilla = build_ovl_mod.vanilla_ui_files(list(build_ovl_mod.UI_PATCHES))
    patched = {
        n: build_ovl_mod.apply_patch(ui_overlay.strip_source_map(vanilla[p]), build_ovl_mod.UI_DIR / patch).encode("utf-8")
        for n, (p, patch) in enumerate(build_ovl_mod.UI_PATCHES.items())
    }
    return ui_overlay.fill_template((PACK_UI / "PZ2CoopUI.template").read_bytes(), patched)


def main() -> int:
    game = find_game_dir()
    if game is None or not SELFTEST.is_file() or not (PACK_UI / "PZ2CoopUI.template").is_file():
        sys.exit("needs the game, build_dll.py and build_ovl_mod.py first")
    ref_bytes = build_reference(game)
    with tempfile.TemporaryDirectory(prefix="pz2coop_ui_test_") as tmp:
        work = Path(tmp) / "UI"
        shutil.copytree(PACK_UI, work)
        failures = 0

        result = run(game, work)
        out = work / "PZ2CoopUI.ovl"
        ok = result.returncode == 0 and out.is_file() and out.read_bytes() == ref_bytes
        print(("ok   " if ok else "FAIL ") + "DLL build matches the Python reference: " + result.stdout.strip())
        failures += not ok

        (work / "patch0.js").write_text("@@ after this anchor does not exist\nX\n", encoding="utf-8")
        result = run(game, work)
        ok = result.returncode != 0 and not out.exists() and "anchor not found" in result.stdout
        print(("ok   " if ok else "FAIL ") + "broken patch fails cleanly and removes the output: " + result.stdout.strip())
        failures += not ok

        print("all passed" if failures == 0 else f"{failures} failed")
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
