# `.ovl` Unpacking & Lua Decompilation Pipeline (`docs/LUA_EXTRACTION_GUIDE.md`)

## 1. Pre-Install vs. Post-Install Handling
Because the *Planet Zoo 2* installation (`\Win64\ovldata\`) may still be downloading on Steam when `tools/extract_all_lua.py` is created:
1. The script MUST check default Steam library locations (`C:\Program Files (x86)\Steam\steamapps\common\Planet Zoo 2\Win64\ovldata`) and accept a `--game-dir` CLI override.
2. If the directory does not exist or contains no `.ovl` archives yet, the script must exit gracefully with code `0` and print a clear status message instructing the user to re-run once the Steam download completes.
3. **CRITICAL:** Claude Code must NOT generate `docs/LUA_API_MAP.md` until `decompiled_lua/vanilla/` contains actual extracted `.lua` files.

## 2. Unpacking & Bytecode Decompilation Steps
When `\Win64\ovldata\` is present, `tools/extract_all_lua.py` executes:
1. **Scan for Script Archives:** Walk `\Win64\ovldata\` recursively for `.ovl` archives likely containing scripts (`Main.ovl`, `Game.ovl`, `UI.ovl`, `Lua*.ovl`, `Archives*.ovl`).
2. **Extract via `cobra-tools`:** Invoke `cobra-tools`'s `ovl_util` Python API in-process to extract `.lua`, `.luac`, `.xml`, `.html`, and `.js` files into `./decompiled_lua/raw/`.
3. **Detect & Decompile `.luac` Bytecode:**
   - Read the first 4 bytes of every extracted `.lua`/`.luac` file.
   - If the header matches `\x1bLua` (`0x1B 0x4C 0x75 0x61`), run:
     `java -jar ./tools/unluac.jar <raw_file> > ./decompiled_lua/vanilla/<relative_path>.lua`
   - If the file is already plain ASCII/UTF-8 text, copy it directly to `./decompiled_lua/vanilla/`.
4. **Generate `docs/LUA_API_MAP.md`:**
   - Parse all decompiled `.lua` and `.js` files for global table registrations, `engine.on` / `engine.trigger` UI events, Save/Load managers, Path/Stamp controllers, and Animal/Finance dispatchers.
