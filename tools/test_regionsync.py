"""Offline smoke test for src/ovl_mod/pz2coop.regionsync.lua (run: python tools/test_regionsync.py).

Loads BuildSync + RegionSync in a stock Lua (lupa) with fake game APIs and drives one path edit and one
fence edit end to end: spatial change message -> settle -> query -> blueprint / fence data -> 0x22 packet,
then the same packets applied on the "friend's" side (shifted 50 m like solo mode): own content removed,
new content placed / rebuilt. Catches runtime errors the syntax check cannot. Needs: pip install lupa.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.BuildSync": (ROOT / "src" / "ovl_mod" / "pz2coop.buildsync.lua").read_text(encoding="utf-8"),
    "PZ2Coop.RegionSync": (ROOT / "src" / "ovl_mod" / "pz2coop.regionsync.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, packets, calls = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end,
    PlusY = function(self, d) return vec(x, y + d, z) end}
end
FLAG_PATH, FLAG_FENCE = 4096, 8192
-- world content: path chunks 11, 12 near x=10; a fence: posts 21, 22 joined by panel 31
local boxes = {[11] = {vec(9, 0, 0), vec(11, 0.2, 2)}, [12] = {vec(11, 0, 0), vec(13, 0.2, 2)},
  [13] = {vec(59, 0, 0), vec(61, 0.2, 2)}, [21] = {vec(5, 0, 5), vec(5.2, 2, 5.2)}, [22] = {vec(9, 0, 5), vec(9.2, 2, 5.2)}, [31] = {vec(5, 0, 5), vec(9, 2, 5.2)}}
local post21 = {data = {nEntityID = 21, vPos = vec(5.1, 0, 5.1), vDir = vec(1, 0, 0), nWorldHeight = 2, sBoundaryType = "Glass"}}
local post22 = {data = {nEntityID = 22, vPos = vec(9.1, 0, 5.1), vDir = vec(1, 0, 0), nWorldHeight = 2, sBoundaryType = "Glass"}}
local panel31 = {data = {nEntityID = 31, oStartControlPost = post21, oEndControlPost = post22,
  vBasePosStart = vec(5.1, 0, 5.1), vDirStart = vec(1, 0, 0), vBasePosEnd = vec(9.1, 0, 5.1), vDirEnd = vec(1, 0, 0),
  nWorldHeightStart = 2, nWorldHeightEnd = 2, nPanelMode = 1, sBoundaryType = "Glass", tSegmentData = {}}}
for _, o in ipairs({post21, post22, panel31}) do o.GetAllData = function(self) return self.data end end
local queryResult = {}
local tWorldAPIs = {
  spatial = {Flag_Path = FLAG_PATH, Flag_HabitatBoundary = FLAG_FENCE,
    CylinderQuery = function(_, b, t, r, flag) call("CylinderQuery", flag, b:GetX()) return queryResult[flag] or {} end,
    GetShapeAABB = function(_, e) if boxes[e] then return boxes[e][1], boxes[e][2] end end},
  -- path hits resolve to a parent that is NOT a chunk (as in retail): the raw hit must be used
  PlayerInteractionHandler = {HasParentEntityID = function() return false end,
    HasPlayerInteractionHandlerComponent = function(_, e) return not (e >= 11 and e <= 13) end},
  transform = {GetParent = function(_, e) return e + 1000 end},
  volumes = {GetVolumeIDFromEntityID = function(_, e) return (e >= 111 and e <= 113) and 1 or nil end,
    IsPool = function() return false end, IsEditableChunk = function() return true end},
  editors = {
    CreateMultiSelection = function()
      local ms = {list = {}, SelectionCategory_PathVolumeChunks = 7}
      ms.SetCanSelectPathVolumeChunks = function() end
      ms.GetSelectableAncestor = function(_, e) return (e >= 11 and e <= 13) and e + 100 or nil end
      ms.AddEntity = function(self, e) table.insert(self.list, e) end
      ms.CountCategory = function(self, c) return c == 7 and #self.list or 0 end
      ms.GetPathVolumeChunkEntity = function(self, i) return self.list[i] end
      return ms
    end,
    CreateUndoOperationsHierarchy = function()
      local cl = {bLimbo = false,
        AddControlPost = function(_, p) call("AddControlPost", p) end,
        AddPanel = function(_, p) call("AddPanel", p) end,
        RefreshAdjacentPosts = function() call("RefreshAdjacentPosts") end,
        IsLakesInLimboEnabled = function(self) return self.bLimbo end,
        SetLakesInLimboEnabled = function(self, b) self.bLimbo = b call("SetLakesInLimboEnabled", b) end}
      local h = {}
      h.SetBoundaryEditPreviewModeModifyVolumes = function(_, b) call("SetBoundaryEditPreviewModeModifyVolumes", b) end
      for _, n in ipairs({"SetPerformTerrainModificationsModifyVolumes",
          "BeginVolumeModificationsBlock", "EndVolumeModificationsBlock", "SetCanCommitResultModifyVolumes",
          "AddBlueprintToCompositeObject"}) do
        h[n] = function() end
      end
      h.GetTerrainEditOperation = function() return {} end
      h.GetFullUndoChangeList = function() return {} end
      h.GetHabitatBoundaryChangeList = function() return cl end
      h.IsLoadedBlueprintReadyForEditing = function() return true end
      h.CreateCompositeObject = function() return {Destroy = function() end,
        SetCompositeOriginToOBBCentre = function() end,
        SetTransform = function(_, t) call("SetTransform", t) end} end
      return h
    end,
  },
  worldserialisation = {CreateSaveSelection = function()
    return {AddEntityID = function(_, e) call("AddEntityID", e) end} end},
  habitatboundary = {
    GetBoundaryObjectFromEntity = function(_, e)
      if e == 21 then return true, nil, post21 elseif e == 22 then return true, nil, post22
      elseif e == 31 then return true, panel31, nil end
      return false
    end,
    GetPanelsConnectedToControlPost = function(_, p) return {panel31} end,
    GetHabitatsFromBoundaryObject = function() if openFence then return {} end return {[5] = true} end,
    GetRoof = function() return nil end,
    GetBoundaryObjectsForHabitat = function()
      return {tPanels = {[panel31] = true}, tControlPosts = {[post21] = true, [post22] = true}, tAttachableProps = {}}
    end,
    CreateNewControlPost = function() local o = {} o.FillData = function(self, t) self.t = t end return o end,
    CreateNewPanel = function() local o = {} o.FillData = function(self, t) self.t = t end return o end,
    DeleteMultiSelection = function(_, sel, data) call("DeleteMultiSelection", sel, data) end,
    AddCashDeltaOperation = function() end,
    GetMinHeight = function() return 0.5 end,
    IsLakesInLimboEnabled = function() return true end,
    NewFlexiColourDataForBoundaryType = function(_, sHabitat, sType) return {habitat = sHabitat, type = sType} end,
  },
  gameterrain = {SetTerrainEditOpCollisionFlags = function() end, SetTerrainEditOpGridRenderingEnabled = function() end,
    AddHabitatBoundaryLakesInLimboToChangeList = function() call("AddHabitatBoundaryLakesInLimboToChangeList") end,
    CheckLakesMode_WhenTerrainCollisionEnabled = 2},
  scenery_group = {TryGetBuildingGroupForPart = function() end, CalculateBuildingGroupAABB = function() error("x") end},
  placement = {GetPartResourceName = function() end},
  habitat = {GetEntityIDFromHabitatID = function(_, id) return id * 100 end},
  -- the active editor runs requested undo operations at once (editors.shared.baseeditmode.lua:155)
  ModeHelperComponent = {GetCurrentMode = function() return {
    HasRequestedChange = function() return false end,
    RequestUndoOperation = function(_, fn, _, post)
      call("RequestUndoOperation")
      fn(api.world.GetWorldAPIs().editors:CreateUndoOperationsHierarchy())
      if post then post() end
      return true
    end} end},
  facilities = {GetAllHabitatsEntityIDs = function() return {} end},
}
local token = {}
local receivers = {}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end},
  json = {GetArrayMetatable = function() return {} end},
  undo = {PreviewChangeList = function() return token, token end, IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end, CommitPreview = function() call("CommitPreview") return token end,
    CancelPreview = function() return token end, Checkpoint = function() end, ClearHistory = function() end,
    GetCommitFailReasons = function() return {} end,
    IsPreviewingChangeList = function() return false end, IsBusy = function() return false end},
  messaging = setmetatable({RegisterReceiver = function(n, fn)
      receivers[n] = receivers[n] or {} table.insert(receivers[n], fn) end,
    UnregisterReceiver = function() end}, {__index = function(_, k) return k end}),
  game = {GetEnvironment = function() return {RequireInterface = function() return {
    SaveBlueprintToFile = function(_, f) call("SaveBlueprintToFile", f) return true end,
    LoadBlueprintFromFile = function(_, f) call("LoadBlueprintFromFile", f) return true end} end} end},
}
applying = false
PZ2COOP_TEST_FENCES = true
local Bridge = {
  Log = function(s) table.insert(log, s) end, Flush = function() end,
  IsApplying = function() return applying end,
  BeginApply = function() applying = true end, EndApply = function() applying = false end,
  GetPrefix = function() return "/run/PZ2Coop/" end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {Identity = {WithPos = function(_, v) return v end}},
  Quaternion = {},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Scenery.SceneryEditHelper"] = {},
  ["Editors.Scenery.Utils.SceneryUtils"] = {StartDeletePathVolumeChunks = function(h, c, ms)
    call("StartDeletePathVolumeChunks", ms) end},
  ["Editors.Shared.BaseEditMode"] = {GetModeHelperEntity = function() return 1 end},
  ["Editors.HabitatBoundary.HabitatBoundaryEditMode"] = {NewBoundarySelection = function()
    return {tPanels = {}, tControlPosts = {}, tAttachableProps = {}, tRoofPillars = {}, tRoofs = {}} end},
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
local RegionSync = require("PZ2Coop.RegionSync")
"""

CHECKS = r"""
local function has(p) for _, l in ipairs(log) do if string.find(l, p, 1, true) then return true end end return false end
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function dump() return table.concat(log, "\n") end
local function tick(n) for _ = 1, n or 1 do BuildSync.Update(0.1, true) RegionSync.Update(0.1, true) end end
local function spatial(flags, x0, x1)
  for _, fn in ipairs(receivers.MsgType_SpatialVolumeChangedMessage) do
    fn({{sType = "SpatialDatabase", nFlags = flags, vAABBMin = vec(x0, 0, 0), vAABBMax = vec(x1, 1, 6)}})
  end
end
local function lastCall(name) local r = nil for _, c in ipairs(calls) do if c.name == name then r = c end end return r end
BuildSync.Install(function() end)
RegionSync.Install()
assert(has("spatial flags Path=4096 HabitatBoundary=8192"), dump())
tick(60) -- past the startup window

-- 1) local path edit: render-piece hits -> chunks via the selectable ancestor -> blueprint + packet
queryResult[FLAG_PATH] = {11, 12}
spatial(FLAG_PATH + 2, 9, 13)
receivers.MsgType_UndoRedoCompletedMessage[1]()  -- something settles
tick(12)
assert(#packets == 1, "path packet missing:\n" .. dump())
assert(has("found{ancestor=2}"), "chunks not found through the selectable ancestor:\n" .. dump())
local pp = packets[1]
assert(pp.n == 0x22 and pp.d.k == "path" and pp.d.n == 2 and pp.f ~= nil, "path packet wrong")
assert(pp.d.cx == 1100 and pp.d.x0 == 850, "path content/region wrong " .. pp.d.cx .. " " .. pp.d.x0)
assert(lastCall("AddEntityID").args[1] == 112, "path blueprint must hold the chunk entities")

-- 2) local fence edit: the touched habitat (entity 500) is saved as a boundary blueprint, area covers it
calls = {}
queryResult[FLAG_FENCE] = {31}
spatial(FLAG_FENCE, 5, 9)
tick(20)
assert(#packets == 2, "fence packet missing:\n" .. dump())
local fp = packets[2]
assert(fp.d.k == "fence" and fp.d.n == 1 and fp.f ~= nil, "fence packet wrong:\n" .. dump())
assert(count("AddEntityID") == 1 and lastCall("AddEntityID").args[1] == 500, "habitat entity not saved")
assert(fp.d.cx == 710 and fp.d.cz == 510, "fence content centre wrong " .. fp.d.cx .. "," .. fp.d.cz)

-- 3) friend side, path: shifted 50 m, own chunks there removed, blueprint placed on the content centre
calls = {}
queryResult[FLAG_PATH] = {13}
pp.d.ox = 5000
RegionSync.OnPacket({nType = 0x22, sFile = "/run/PZ2Coop/" .. pp.f, tData = pp.d})
tick(30)
assert(count("StartDeletePathVolumeChunks") == 1 and count("LoadBlueprintFromFile") == 1 and count("CommitPreview") == 1,
  "path apply incomplete:\n" .. dump())
assert(lastCall("SetTransform").args[1]:GetX() == 61, "path not placed at x = 11 + 50")

-- 4) friend side, fence: own fence demolished (first commit), habitat blueprint placed (second commit)
calls = {}
fp.d.ox = 5000
RegionSync.OnPacket({nType = 0x22, sFile = "/run/PZ2Coop/" .. fp.f, tData = fp.d})
tick(30)
assert(count("DeleteMultiSelection") == 1 and count("LoadBlueprintFromFile") == 1 and count("CommitPreview") == 2,
  "fence apply incomplete:\n" .. dump())
assert(count("AddControlPost") == 0 and count("AddPanel") == 0, "fences must not be built by hand")
assert(math.abs(lastCall("SetTransform").args[1]:GetX() - 57.1) < 1e-9, "fence blueprint not placed at x = 7.1 + 50")
-- 5) open fence (no habitat record): pieces sent with vanilla new-piece fields, rebuilt via prepared fence change list
--    with LakesInLimbo + unshifted unit direction vectors (regression test for 2026-11-12 hang!)
calls = {}
openFence = true
queryResult[FLAG_FENCE] = {31}
spatial(FLAG_FENCE, 5, 9)
tick(20)
local op = packets[#packets]
assert(op.d.k == "fence" and op.d.mode == "pieces" and #op.d.posts == 2 and #op.d.panels == 1, "open fence packet wrong:" .. dump())
local pk = op.d.panels[1]
assert(pk.s and pk.e and pk.s ~= pk.e and pk.f.nEntityID == nil and pk.v.vBasePosStart[1] == 5.1, "panel packing wrong")
calls = {}
op.d.ox = 5000
RegionSync.OnPacket({nType = 0x22, tData = op.d})
tick(30)
assert(count("SetBoundaryEditPreviewModeModifyVolumes") == 1, "missing boundary preview volume mode:\n" .. dump())
assert(count("SetLakesInLimboEnabled") == 1 and count("AddHabitatBoundaryLakesInLimboToChangeList") == 1,
  "missing LakesInLimbo handling:\n" .. dump())
assert(count("DeleteMultiSelection") == 1 and count("AddControlPost") == 2 and count("AddPanel") == 1 and count("CommitPreview") == 1,
  "open fence rebuild wrong: del=" .. count("DeleteMultiSelection") .. " posts=" .. count("AddControlPost") ..
  " panels=" .. count("AddPanel") .. " commits=" .. count("CommitPreview") .. " | " .. dump())
local postCall = lastCall("AddControlPost").args[1]
assert(math.abs(postCall.t.vDir:GetX() - 1.0) < 1e-6 and math.abs(postCall.t.vDir:GetZ()) < 1e-6,
  "regression: vDir was corrupted by loopback shift! got x=" .. tostring(postCall.t.vDir:GetX()))
local np = lastCall("AddPanel").args[1]
assert(np.t.oStartControlPost and np.t.oStartControlPost.t and np.t.vBasePosStart:GetX() == 55.1, "rebuilt panel wrong")
assert(math.abs(np.t.vDirStart:GetX() - 1.0) < 1e-6 and math.abs(np.t.vDirEnd:GetX() - 1.0) < 1e-6,
  "regression: panel vDirStart/vDirEnd corrupted by loopback shift! got " .. tostring(np.t.vDirStart:GetX()))
assert(np.t.tFlexiColours and np.t.tFlexiColours.habitat == "Aquarium", "rebuilt panel has no colours")
assert(not has("job failed") and not has("error"), dump())
return "ok: " .. BuildSync.Summary()
"""


def main() -> int:
    lua = lupa.LuaRuntime()
    sources = lua.table()
    for name, text in SOURCES.items():
        sources[name] = text
    lua.globals().SOURCES = sources
    try:
        result = lua.execute(HARNESS + CHECKS)
    except lupa.LuaError as error:
        print("FAIL:", error)
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
