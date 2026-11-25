#!/usr/bin/env python3
"""Build version.dll (src/proxy_dll) and run its selftest, on any Windows PC.

  python tools/build_dll.py

Uses the project's own CMake in tools/cmake/ (not in Git). The first run downloads the official portable
CMake zip from Kitware's GitHub releases and checks it against a pinned SHA-256, so every PC (and every
contributor) builds with the same CMake. If build/proxy_dll was configured by a CMake that no longer exists
(moved PC, uninstalled CMake), it is reconfigured from scratch.

Still needed on the PC: Visual Studio 2022 or its free "Build Tools" with the "Desktop development with C++"
workload (the C++ compiler cannot be shipped in the project).
"""
import hashlib
import io
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[1]
CMAKE_VERSION = "3.31.6"
CMAKE_ZIP = f"cmake-{CMAKE_VERSION}-windows-x86_64"
CMAKE_URL = f"https://github.com/Kitware/CMake/releases/download/v{CMAKE_VERSION}/{CMAKE_ZIP}.zip"
CMAKE_SHA256 = "d163cd3ab4959b0a53fa8988f2ddbd2e6c501658201e6a154386bad9dbe4f836"  # Kitware's SHA-256 list
CMAKE_DIR = REPO / "tools" / "cmake"
CMAKE_EXE = CMAKE_DIR / "bin" / "cmake.exe"
SRC = REPO / "src" / "proxy_dll"
BUILD = REPO / "build" / "proxy_dll"


def ensure_cmake() -> pathlib.Path:
    if CMAKE_EXE.is_file():
        return CMAKE_EXE
    print(f"[build_dll] downloading CMake {CMAKE_VERSION} into {CMAKE_DIR} (once, ~45 MB)")
    with urllib.request.urlopen(CMAKE_URL) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != CMAKE_SHA256:
        sys.exit(f"[build_dll] CMake download checksum mismatch ({digest}); nothing was installed")
    staging = CMAKE_DIR.with_name("cmake_partial")
    shutil.rmtree(staging, ignore_errors=True)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        archive.extractall(staging)
    shutil.rmtree(CMAKE_DIR, ignore_errors=True)
    (staging / CMAKE_ZIP).rename(CMAKE_DIR)
    shutil.rmtree(staging, ignore_errors=True)
    return CMAKE_EXE


def stale_cache() -> bool:
    """True when build/proxy_dll was configured with a CMake that is not this project's."""
    cache = BUILD / "CMakeCache.txt"
    if not cache.is_file():
        return False
    m = re.search(r"^CMAKE_COMMAND:INTERNAL=(.*)$", cache.read_text(encoding="utf-8", errors="replace"), re.M)
    return m is None or pathlib.Path(m.group(1)).resolve() != CMAKE_EXE.resolve()


def run(cmd: list) -> None:
    if subprocess.run([str(c) for c in cmd], cwd=REPO).returncode != 0:
        sys.exit(f"[build_dll] failed: {' '.join(str(c) for c in cmd)}")


def main() -> int:
    cmake = ensure_cmake()
    if stale_cache():
        print("[build_dll] build/proxy_dll was set up by another CMake; reconfiguring")
        (BUILD / "CMakeCache.txt").unlink()
        shutil.rmtree(BUILD / "CMakeFiles", ignore_errors=True)
    if not (BUILD / "CMakeCache.txt").is_file():
        run([cmake, "-S", SRC, "-B", BUILD, "-A", "x64"])
    run([cmake, "--build", BUILD, "--config", "Release"])
    run([BUILD / "Release" / "pz2coop_selftest.exe"])
    print(f"[build_dll] ok: {BUILD / 'Release' / 'version.dll'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
