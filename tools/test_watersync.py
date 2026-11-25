"""Offline smoke test for src/ovl_mod/pz2coop.watersync.lua (run: python tools/test_watersync.py).

Loads BuildSync + WaterSync in stock Lua (lupa) with fake game APIs and tests:
  1) Initial startup snapshot seeding (existing lakes not re-sent).
  2) Local lake add -> MsgType_LakeUpdateMessage -> quiet settle -> 0x22 water add packet with refill point,
     surface/underside materials, cleanliness, temperature, colour/particle data.
  3) Remote lake add (shifted +50 m via ox) -> PreviewLakeAddition -> IsPreviewLakeAdditionDone ->
     CreateLakeAddOperationFromLakePreview -> CommitPreview -> ResetPreviewLakeAddition, with echo suppression.
  4) Local lake remove -> 0x22 water remove packet.
  5) Remote lake remove -> FindLakesWithSphereCheck -> CreateLakeRemoveOperation -> CommitPreview.
  6) Untrusted / malformed water packets (invalid material/prefab names, missing coords) sanitized or dropped.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.BuildSync": (ROOT / "src" / "ovl_mod" / "pz2coop.buildsync.lua").read_text(encoding="utf-8"),
    "PZ2Coop.WaterSync": (ROOT / "src" / "ovl_mod" / "pz2coop.watersync.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, packets, calls = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end}
end
local lakes = {[1] = {
  fill = vec(0, 1, 0),
  props = {sPrefabName = "Lake", sSurfaceMaterialName = "CalmWaterSurface",
    sUndersideMaterialName = "CalmWaterUnderside", nCleanliness = 1.0, nTemperature = 20},
}}
local previewDone, canTheory, canPractice = true, true, true
local sphereHits = {}
local tWorldAPIs = {
  gameterrain = {
    GetAllLakes = function()
      local t = {}
      for id in pairs(lakes) do table.insert(t, id) end
      table.sort(t)
      return t
    end,
    FindLakeRefillPoint = function(_, id) return lakes[id] and lakes[id].fill end,
    GetLakeRespawnProperties = function(_, id) return lakes[id] and lakes[id].props end,
    PreviewLakeAddition = function(_, vPoint, sPrefab, sSurf, sUnder, nClean, nTemp, tCol, tPart)
      call("PreviewLakeAddition", vPoint, sPrefab, sSurf, sUnder, nClean, nTemp, tCol, tPart)
    end,
    IsPreviewLakeAdditionDone = function() return previewDone end,
    IsPreviewLakeAdditionCommitableInTheory = function() return canTheory end,
    IsPreviewLakeAdditionCommitableInPractice = function() return canPractice end,
    CreateLakeAddOperationFromLakePreview = function(_, bPaint)
      call("CreateLakeAddOperationFromLakePreview", bPaint)
      return {op = "add_lake"}
    end,
    ResetPreviewLakeAddition = function() call("ResetPreviewLakeAddition") end,
    FindLakesWithSphereCheck = function(_, vPos, r)
      call("FindLakesWithSphereCheck", vPos, r)
      return sphereHits
    end,
    CreateLakeRemoveOperation = function(_, id)
      call("CreateLakeRemoveOperation", id)
      return {op = "remove_lake", id = id}
    end,
  },
  scenery_group = {TryGetBuildingGroupForPart = function() end, CalculateBuildingGroupAABB = function() end},
  placement = {GetPartResourceName = function() end},
  facilities = {GetAllHabitatsEntityIDs = function() return {700} end},
  habitat = {
    IsAquarium = function(_, id) return id == 700 end,
    GetAquariumLake = function(_, id) return (id == 700 and aqFilled) and 99 or nil end,
    GetHabitatContainingPoint = function(_, vPos) return (vPos:GetX() > 75 and vPos:GetX() < 85) and 700 or nil end,
    FillAquarium = function(_, id) call("FillAquarium", id) aqFilled = true end,
    GetAquariumFillResult = function(_, id) return aqFilled end,
  },
  editors = {CreateUndoOperationsHierarchy = function() return {} end},
}
local token = {}
local receivers = {}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end},
  json = {GetArrayMetatable = function() return {} end},
  undo = {
    PreviewChangeList = function(cl) call("PreviewChangeList", cl) return token, token end,
    IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end,
    CommitPreview = function() call("CommitPreview") return token end,
    CancelPreview = function() call("CancelPreview") return token end,
    Checkpoint = function() end,
    ClearHistory = function() end,
    IsPreviewingChangeList = function() return false end,
    IsBusy = function() return false end,
  },
  messaging = setmetatable({
    RegisterReceiver = function(n, fn) receivers[n] = receivers[n] or {} table.insert(receivers[n], fn) end,
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
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {},
  Quaternion = {},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Scenery.SceneryEditHelper"] = {},
}
local loaded = {}
require = function(name)
  if stubs[name] then return stubs[name] end
  if loaded[name] then return loaded[name] end
  if SOURCES[name] then
    local captured
    module = function() captured = {} return captured end
    load(SOURCES[name], name)()
    loaded[name] = captured
    return captured
  end
  error("module not stubbed: " .. name)
end
local BuildSync = require("PZ2Coop.BuildSync")
local WaterSync = require("PZ2Coop.WaterSync")
"""

CHECKS = r"""
local function has(p) for _, l in ipairs(log) do if string.find(l, p, 1, true) then return true end end return false end
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function lastCall(name) local r = nil for _, c in ipairs(calls) do if c.name == name then r = c end end return r end
local function dump() return table.concat(log, "\n") end
local function tick(n) for _ = 1, n or 1 do BuildSync.Update(0.1, true) WaterSync.Update(0.1, true) end end
local function fireLakeUpdate()
  for _, fn in ipairs(receivers.MsgType_LakeUpdateMessage) do fn({{nLakeID = 2}}) end
end

BuildSync.Install(function() end)
WaterSync.Install()
tick(60) -- past startup window, seeds lake 1
assert(#packets == 0, "existing lake must not be sent at startup:\n" .. dump())

-- 1) local lake added
lakes[2] = {
  fill = vec(12.5, 2.0, -8.25),
  props = {
    sPrefabName = "Lake",
    sSurfaceMaterialName = "RoughWaterSurface",
    sUndersideMaterialName = "RoughWaterUnderside",
    nCleanliness = 0.85,
    nTemperature = 18.5,
    tColourData = {bUseNaturalColour = false, vAbsorptionColour = vec(0.3, 0.9, 1.0), nAbsorption = 0.5},
    tParticleData = {vMistColour = vec(1, 1, 1), nMotes = 0.25},
  },
}
fireLakeUpdate()
tick(10)
assert(#packets == 1, "lake add packet missing:\n" .. dump())
local pAdd = packets[1]
assert(pAdd.n == 0x22 and pAdd.d.k == "water" and pAdd.d.op == "add", "bad water add packet")
assert(pAdd.d.x == 1250 and pAdd.d.y == 200 and pAdd.d.z == -825, "bad water coords")
assert(pAdd.d.surf == "RoughWaterSurface" and pAdd.d.clean == 0.85 and pAdd.d.temp == 18.5, "bad water props")
assert(pAdd.d.col.vAbsorptionColour[2] == 0.9 and pAdd.d.part.nMotes == 0.25, "colour/particle packing wrong")

-- 2) remote lake add with +50 m loopback shift
calls = {}
pAdd.d.ox = 5000
assert(WaterSync.OnPacket({nType = 0x22, tData = pAdd.d}) == true, "water packet not handled")
tick(10)
assert(count("PreviewLakeAddition") == 1 and count("CreateLakeAddOperationFromLakePreview") == 1, "lake add apply missing:\n" .. dump())
assert(count("CommitPreview") == 1 and count("ResetPreviewLakeAddition") == 1, "lake commit/reset missing")
local pv = lastCall("PreviewLakeAddition")
assert(math.abs(pv.args[1]:GetX() - 62.5) < 1e-6 and math.abs(pv.args[1]:GetZ() - (-8.25)) < 1e-6, "shifted fill pos wrong")
assert(pv.args[3] == "RoughWaterSurface" and pv.args[7].vAbsorptionColour:GetY() == 0.9, "unpacked args wrong")

-- 3) echo suppression: a lake appearing at the remote point right after apply is not sent back
lakes[3] = {fill = vec(62.5, 2.0, -8.25), props = lakes[2].props}
fireLakeUpdate()
tick(25)
assert(#packets == 1, "remote lake echoed back:\n" .. dump())

-- 4) local lake removed
lakes[2] = nil
fireLakeUpdate()
tick(10)
assert(#packets == 2, "lake remove packet missing:\n" .. dump())
local pRem = packets[2]
assert(pRem.d.k == "water" and pRem.d.op == "remove" and pRem.d.x == 1250, "bad water remove packet")

-- 5) remote lake remove
calls = {}
sphereHits = {3}
pRem.d.ox = 5000
WaterSync.OnPacket({nType = 0x22, tData = pRem.d})
tick(10)
assert(count("FindLakesWithSphereCheck") == 1 and count("CreateLakeRemoveOperation") == 1 and count("CommitPreview") == 1,
  "lake remove apply missing:\n" .. dump())
assert(lastCall("CreateLakeRemoveOperation").args[1] == 3, "wrong lake id removed")

-- 6) untrusted material/prefab strings fall back to safe defaults; missing coords dropped
calls = {}
WaterSync.OnPacket({nType = 0x22, tData = {k = "water", op = "add", x = 100, y = 0, z = 100,
  prefab = "../../evil", surf = "bad/name", under = "x.y"}})
WaterSync.OnPacket({nType = 0x22, tData = {k = "water", op = "add"}})
tick(10)
local pv2 = lastCall("PreviewLakeAddition")
assert(pv2.args[2] == "Lake" and pv2.args[3] == "CalmWaterSurface" and pv2.args[4] == "CalmWaterUnderside",
  "untrusted water names were not sanitized")
assert(has("water packet without position dropped"), dump())

-- 7) aquarium water sync: aquarium lake sets aq=true and replays via FillAquarium
tick(20) -- past ignore window from step 6
calls = {}
aqFilled = true
lakes[99] = {fill = vec(30.0, 2.0, 10.0), props = lakes[1].props}
fireLakeUpdate()
tick(10)
local pAq = packets[#packets]
assert(pAq.d.k == "water" and pAq.d.op == "add" and pAq.d.aq == true, "aquarium flag missing:\n" .. dump())
calls = {}
aqFilled = false
pAq.d.ox = 5000
WaterSync.OnPacket({nType = 0x22, tData = pAq.d})
tick(10)
assert(count("FillAquarium") == 1 and lastCall("FillAquarium").args[1] == 700, "FillAquarium not called:\n" .. dump())
assert(not has("error") and not has("failed"), dump())
return "ok: water sync"
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
