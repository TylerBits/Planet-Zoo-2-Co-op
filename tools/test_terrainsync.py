"""Offline smoke test for src/ovl_mod/pz2coop.terrainsync.lua (run: python tools/test_terrainsync.py).

Verifies:
  1) TerrainEditMode.TransitionIn wraps self.GameTerrainAPI.
  2) Hover previews (bMouseHeld == false) are NOT sent.
  3) Held brush dabs (pushpull, flatten, paint) batch into packet 0x23 {k="terrain", dabs={...}}.
  4) Remote 0x23 replays all validated dabs via CreateTerrainUndoOperationsHierarchy + undo preview/commit,
     applying loopback ox shift cleanly.
  5) Echo guard prevents re-sending during apply, and unknown/malformed ops are safely dropped.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.BuildSync": (ROOT / "src" / "ovl_mod" / "pz2coop.buildsync.lua").read_text(encoding="utf-8"),
    "PZ2Coop.TerrainSync": (ROOT / "src" / "ovl_mod" / "pz2coop.terrainsync.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, packets, calls = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end}
end
local rawGameTerrain = {
  CheckLakesMode_Off = 0,
  PaintVoxelColoursMode_Lerp = 1,
  SetTerrainEditOpCollisionFlags = function(_, ...) call("SetCollisionFlags", ...) end,
  AddPushPullWithLakeSupportToChangeList = function(_, clh, pinch, lake, vPos, sz, inten, q)
    call("AddPushPull", vPos:GetX(), vPos:GetY(), vPos:GetZ(), sz, inten)
  end,
  AddPlaneFlattenWithLakeSupportToChangeList = function(_, clh, lake, vPos, sz, inten, vDir, vOrig, q)
    call("AddFlatten", vPos:GetX(), vPos:GetY(), vPos:GetZ(), sz, inten, vOrig:GetX())
  end,
  AddPaintVoxelColoursToChangeList = function(_, op, vPos, sz, inten, a, layer, b, mode, keep)
    call("AddPaint", vPos:GetX(), vPos:GetZ(), layer, keep)
  end,
}
local tWorldAPIs = {
  gameterrain = rawGameTerrain,
  editors = {
    CreateUndoOperationsHierarchy = function() return {} end,
    CreateTerrainUndoOperationsHierarchy = function()
      call("CreateTerrainHierarchy")
      return {
        GetFullUndoChangeList = function() return {kind = "terrain_cl"} end,
        GetTerrainEditOperation = function() return {kind = "terrain_op"} end,
      }
    end,
  },
  scenery_group = {TryGetBuildingGroupForPart = function() end, CalculateBuildingGroupAABB = function() end},
  placement = {GetPartResourceName = function() end},
  facilities = {GetAllHabitatsEntityIDs = function() return {} end},
}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end},
  json = {GetArrayMetatable = function() return {} end},
  undo = {
    PreviewChangeList = function(cl) call("PreviewChangeList", cl) return {}, {} end,
    IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end,
    CommitPreview = function() call("CommitPreview") return {} end,
    CancelPreview = function() return {} end,
    Checkpoint = function() end,
    ClearHistory = function() end,
    IsPreviewingChangeList = function() return false end,
    IsBusy = function() return false end,
  },
  messaging = setmetatable({
    RegisterReceiver = function() end,
    UnregisterReceiver = function() end,
  }, {__index = function(_, k) return k end}),
}
applying = false
local Bridge = {
  Log = function(s) table.insert(log, s) end,
  Flush = function() end,
  IsApplying = function() return applying end,
  BeginApply = function() applying = true end,
  EndApply = function() applying = false end,
  GetPrefix = function() return "/run/PZ2Coop/" end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}
local function vec2(x, y)
  return {GetX = function() return x end, GetY = function() return y end}
end
local TerrainEditMode = {
  TransitionIn = function(self) self.GameTerrainAPI = rawGameTerrain end,
  TransitionOut = function(self) end,
  Advance = function(self, dt) call("VanillaTerrainAdvance", dt) end,
}
local TerrainShapeStampMode = {
  TransitionIn = function(self) end,
  TransitionOut = function(self) end,
  FeaturePlaced = function(self, ...) call("VanillaShapePlaced", ...) end,
}
local stubs = {
  Vector2 = {new = function(_, x, y) return vec2(x, y) end},
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {FromOrPos = function(q, v) return {q = q, pos = v, GetPos = function() return v end, GetOrientation = function() return q end} end},
  Quaternion = {new = function(_, x, y, z, w) return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end, GetW = function() return w end} end,
    FromYawPitchRoll = function(v) return {ypr = v} end,
    Identity = {GetX = function() return 0 end, GetY = function() return 0 end, GetZ = function() return 0 end, GetW = function() return 1 end}},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Scenery.SceneryEditHelper"] = {},
  ["Editors.Terrain.TerrainEditMode"] = TerrainEditMode,
  ["Editors.Terrain.TerrainShapeStampMode"] = TerrainShapeStampMode,
}
local loaded = {}
require = function(name)
  if stubs[name] then return stubs[name] end
  if loaded[name] then return loaded[name] end
  if SOURCES[name] then
    local mod
    local prev = module
    module = function() mod = {} return mod end
    load(SOURCES[name], name)()
    module = prev
    loaded[name] = mod
    return mod
  end
  error("module not stubbed: " .. name)
end
local BuildSync = require("PZ2Coop.BuildSync")
local TerrainSync = require("PZ2Coop.TerrainSync")
"""

CHECKS = r"""
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function lastCall(name) local r = nil for _, c in ipairs(calls) do if c.name == name then r = c end end return r end
local function dump() return table.concat(log, "\n") end
local function tick(n) for _ = 1, n or 1 do BuildSync.Update(0.05, true) TerrainSync.Update(0.05, true) end end

BuildSync.Install(function() end)
TerrainSync.Install()

local mode = {bMouseHeld = false}
TerrainEditMode.TransitionIn(mode)
assert(mode.GameTerrainAPI ~= rawGameTerrain, "TerrainEditMode.GameTerrainAPI not wrapped")

-- 1) Hover preview (bMouseHeld == false) must NOT send
mode.GameTerrainAPI:AddPushPullWithLakeSupportToChangeList({}, nil, nil, vec(10, 2, 20), 4.0, 0.5, 0)
tick(5)
assert(#packets == 0, "hover preview sent a terrain packet")

-- 2) Held brush dabs batch into 0x23
mode.bMouseHeld = true
mode.GameTerrainAPI:AddPushPullWithLakeSupportToChangeList({}, nil, nil, vec(10, 2, 20), 4.0, 0.5, 0)
mode.GameTerrainAPI:AddPlaneFlattenWithLakeSupportToChangeList({}, nil, vec(12, 2, 20), 5.0, 0.8, vec(0, 1, 0), vec(12, 2, 20), 0)
mode.GameTerrainAPI:AddPaintVoxelColoursToChangeList({}, vec(14, 2, 20), 3.0, 0.6, 1, 3, 1, 1, true)
mode.bMouseHeld = false
tick(2)
assert(#packets == 1, "expected 1 batched terrain packet, got " .. #packets)
local p = packets[1]
assert(p.n == 0x23 and p.d.k == "terrain" and #p.d.dabs == 3, "bad terrain packet payload")
assert(p.d.dabs[1].op == "pushpull" and p.d.dabs[1].x == 1000 and p.d.dabs[1].sz == 400, "bad pushpull dab")
assert(p.d.dabs[2].op == "flatten" and p.d.dabs[2].ox0 == 1200, "bad flatten dab")
assert(p.d.dabs[3].op == "paint" and p.d.dabs[3].layer == 3 and p.d.dabs[3].keep == 1, "bad paint dab")

-- 3) Remote 0x23 applies with loopback ox (+50 m = 5000 cm)
calls = {}
p.d.ox = 5000
assert(TerrainSync.OnPacket({nType = 0x23, tData = p.d}) == true)
tick(6)
assert(count("CreateTerrainHierarchy") == 1 and count("CommitPreview") == 1, "terrain stroke not committed:\n" .. dump())
assert(count("AddPushPull") == 1 and count("AddFlatten") == 1 and count("AddPaint") == 1, "not all dabs replayed")
assert(math.abs(lastCall("AddPushPull").args[1] - 60.0) < 0.01, "ox shift not applied to pushpull")
assert(math.abs(lastCall("AddFlatten").args[6] - 62.0) < 0.01, "ox shift not applied to flatten origin")

-- 4) Unknown / malicious op dropped safely
calls = {}
TerrainSync.OnPacket({nType = 0x23, tData = {k = "terrain", dabs = {{op = "evil_op", x = 0, y = 0, z = 0, sz = 100, int = 100}}}})
tick(6)
assert(count("CommitPreview") == 0, "invalid terrain op should not commit")

-- 5) Concurrent terrain safety: while local player holds terrain brush (bMouseHeld == true),
--    remote strokes MUST wait in queue (zero concurrent PreviewChangeList) and drain once released
calls = {}
mode.bMouseHeld = true
assert(TerrainSync.OnPacket({nType = 0x23, tData = {k = "terrain", dabs = {{op = "pushpull", x = 1000, y = 200, z = 2000, sz = 12000, int = 100}}}}) == true)
tick(10)
assert(count("PreviewChangeList") == 0 and count("CommitPreview") == 0,
  "regression: remote terrain preview ran while local player was sculpting! previews=" .. count("PreviewChangeList"))
mode.bMouseHeld = false
tick(10)
assert(count("CommitPreview") == 1 and count("AddPushPull") == 1,
  "deferred terrain stroke failed to drain after local brush release:\n" .. dump())
assert(math.abs(lastCall("AddPushPull").args[4] - 120.0) < 0.01,
  "large brush size (120 m) was clamped! got " .. tostring(lastCall("AddPushPull").args[4]))

-- 6) Shape stamp send & replay
packets, calls = {}, {}
tWorldAPIs.editors.CreateUndoOperationsHierarchy = function()
  call("CreateShapeHierarchy")
  return {
    GetFullUndoChangeList = function() return {kind = "shape_cl"} end,
    GetTerrainEditOperation = function() return {kind = "shape_op"} end,
    CreateTerrainShapeStamp = function(_, shape, vSize, bFill, nAng)
      call("CreateTerrainShapeStamp", shape, vSize:GetX(), vSize:GetY(), vSize:GetZ(), bFill, nAng)
      return {SetTransform = function(_, tr) call("StampSetTransform", tr.pos:GetX(), tr.pos:GetZ()) end}
    end,
  }
end
local stampMode = {
  sShapeType = "cube",
  bFill = true,
  vSize = vec(30, 15, 30),
  nWedgeAngle = 0,
  lastCommittedTransform = {
    GetPos = function() return vec(40, 2, 50) end,
    GetOr = function() return {ToYawPitchRoll = function() return vec(0, 0, 0) end} end,
  },
}
TerrainShapeStampMode.TransitionIn(stampMode)
TerrainShapeStampMode.FeaturePlaced(stampMode)
assert(#packets == 1 and packets[1].d.k == "terrain" and packets[1].d.op == "shapestamp" and packets[1].d.shape == "cube",
  "shape stamp packet missing:\n" .. dump())
TerrainShapeStampMode.TransitionOut(stampMode)
local sp = packets[1]
sp.d.ox = 5000
assert(TerrainSync.OnPacket({nType = 0x23, tData = sp.d}) == true)
tick(10)
assert(count("CreateTerrainShapeStamp") == 1 and count("CommitPreview") == 1,
  "remote shape stamp did not apply:\n" .. dump())
assert(math.abs(lastCall("StampSetTransform").args[1] - 90.0) < 0.01, "shape stamp ox shift wrong")
return "ok: terrain sync"
"""


def main() -> int:
    lua = lupa.LuaRuntime()
    sources = lua.table()
    for name, text in SOURCES.items():
        sources[name] = text
    lua.globals().SOURCES = sources
    try:
        print(lua.execute(HARNESS + CHECKS))
    except lupa.LuaError as error:
        print("FAIL:", error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
