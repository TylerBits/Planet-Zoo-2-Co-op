"""Offline smoke test for src/ovl_mod/pz2coop.buildsync.lua (run: python tools/test_buildsync.py).

Loads the module in a stock Lua (lupa) with fake game APIs and checks one loose part end to end:
local place -> blueprint saved + place packet (k="p"), then a remote delete for that part is applied.
Catches runtime errors (nil fields, wrong names) that the syntax check cannot. Needs: pip install lupa.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src" / "ovl_mod" / "pz2coop.buildsync.lua").read_text(encoding="utf-8")

HARNESS = r"""
local log, packets, destroyed = {}, {}, {}
local function vec(x, y, z) return {GetX = function() return x end, GetY = function() return y end,
  GetZ = function() return z end} end
local parts = {[501] = {name = "Feeder_AquaticStation_Fish", pos = vec(10, 2, 30)}}
local receivers = {}
local hierarchyMT = {}
hierarchyMT.__index = hierarchyMT
for _, name in ipairs({"EditExistingPart", "EditExistingParts", "DestroyExistingPart", "DestroyExistingParts"}) do
  hierarchyMT[name] = function() return {} end
end
hierarchyMT.GetFullUndoChangeList = function() return {} end
hierarchyMT.CreateCompositeObject = function() return {Destroy = function() end, GetOBB = function() return nil end,
  SetCompositeOriginToOBBCentre = function() end, SetTransform = function() end} end
hierarchyMT.IsLoadedBlueprintReadyForEditing = function() return true end
hierarchyMT.AddBlueprintToCompositeObject = function() end
local tWorldAPIs = {
  scenery_group = {
    TryGetBuildingGroupForPart = function() return nil end,
    CalculateBuildingGroupAABB = function() error("not a group") end,
  },
  placement = {GetPartResourceName = function(_, id) return parts[id] and parts[id].name end},
  scenery_puppets = {PlacementIDToEntityID = function(_, id) return parts[id] and id + 1000 end},
  transform = {CalculateWorldTransform = function(_, e) return {GetPos = function() return parts[e - 1000].pos end,
    GetOr = function() return {ToYawPitchRoll = function() return vec(1.5, 0, 0) end} end} end},
  worldserialisation = {CreateSaveSelection = function() return {AddEntityID = function() end} end},
  scenery = {AddSceneryToBlueprintSelection = function() end, AddGroupToBlueprintSelection = function() end},
  editors = {CreateUndoOperationsHierarchy = function() return setmetatable({}, hierarchyMT) end},
  facilities = {GetAllHabitatsEntityIDs = function() return {} end},
  habitat = {GetHabitatIDFromEntityID = function() end},
  habitatboundary = {GetBoundaryObjectsForHabitat = function() end},
  money = {GetCash = function() end, ModifyCash = function() end},
  -- the active editor runs requested undo operations (editors.shared.baseeditmode.lua:155); here at once
  ModeHelperComponent = {GetCurrentMode = function() return editMode end},
}
editorBusy = false
editorRuns = 0
editMode = {
  HasRequestedChange = function() return editorBusy end,
  RequestUndoOperation = function(_, fn, _, post)
    editorRuns = editorRuns + 1
    fn(setmetatable({}, hierarchyMT))
    if post then post() end
    return true
  end,
}
local token = {}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end},
  undo = {
    PreviewChangeList = function() return token, token end, IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end, CommitPreview = function() return token end,
    CancelPreview = function() return token end, Checkpoint = function() end, ClearHistory = function() end,
    GetCommitFailReasons = function() return {} end,
    IsPreviewingChangeList = function() return previewing end, IsBusy = function() return false end,
  },
  messaging = setmetatable({
    RegisterReceiver = function(n, fn) receivers[n] = fn end, UnregisterReceiver = function() end,
  }, {__index = function(_, k) return k end}),
  game = {GetEnvironment = function() return {RequireInterface = function() return {
    SaveBlueprintToFile = function() return true end, LoadBlueprintFromFile = function() return true end} end} end},
}
local Bridge = {
  Log = function(s) table.insert(log, s) end, Flush = function() end,
  IsApplying = function() return Bridge_applying end,
  BeginApply = function() Bridge_applying = true end, EndApply = function() Bridge_applying = false end,
  GetPrefix = function() return "/run/PZ2Coop/" end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}
Bridge_applying = false
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {Identity = {WithPos = function(_, v) return v end},
    FromOrPos = function(q, v) return {q = q, pos = v} end},
  Quaternion = {FromYawPitchRoll = function(v) return {ypr = v} end},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Shared.BaseEditMode"] = {GetModeHelperEntity = function() return 1 end},
  ["Editors.Scenery.SceneryEditHelper"] = {
    Yielding_CreateNewPart_Scenery = function(_, name)
      created = {name = name}
      return {SetTransform = function(_, t) created.transform = t end}
    end,
    NonYielding_AddPartToDestroyIntoCompositeObject = function(_, _, id) table.insert(destroyed, id) end,
    Yielding_DestroyCompositeContents = function() end,
  },
}
require = function(name)
  if stubs[name] then return stubs[name] end
  error("module not stubbed: " .. name)
end
-- The chunk fills the table module(...) returns; capture it.
local captured
module = function() captured = {} return captured end
load(SOURCE, "buildsync")()
local BuildSync = captured
"""

CHECKS = r"""
local function has(pattern) for _, l in ipairs(log) do if string.find(l, pattern, 1, true) then return true end end return false end
BuildSync.Install(function() end)
-- local placement of a loose part: commit message, then settle on the next update
receivers.MsgType_PlacementPartCommittedMessage({{nPlacementPartID = 501}})
BuildSync.Update(0.1, true)   -- settle -> Emit place -> packet (parts are sent as parameters, no file)
assert(has("local place part 501 (Feeder_AquaticStation_Fish)"), "local place not logged:\n" .. table.concat(log, "\n"))
assert(#packets == 1 and packets[1].n == 0x20 and packets[1].d.k == "p" and packets[1].f == nil,
  "place packet missing, wrong kind or has a file")
local d = packets[1].d
assert(d.n == "Feeder_AquaticStation_Fish" and d.x == 1000 and d.yaw == 1500, "place packet payload wrong")
-- the same packet arriving from the friend re-creates the part by name with position + rotation, handed
-- to the active editor once it is idle (own change lists crashed the engine for single parts)
editorBusy = true
BuildSync.OnPacket({nType = 0x20, tData = {x = 6000, y = 200, z = 3000, k = "p", n = d.n, yaw = d.yaw, pitch = 0, roll = 0}})
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(created == nil, "remote part was created while the editor was busy")
assert(has("waits for an idle editor"), "wait not logged")
editorBusy = false
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(has("handed to the active editor"), "not handed to the editor:\n" .. table.concat(log, "\n"))
assert(created and created.name == d.n, "remote part not created:\n" .. table.concat(log, "\n"))
assert(created.transform.pos.GetX() == 60 and created.transform.q.ypr.GetX() == 1.5, "remote part transform wrong")
-- remote delete of that part arrives
BuildSync.OnPacket({nType = 0x21, tData = {x = 1000, y = 200, z = 3000, r = 250, k = "p", n = "Feeder_AquaticStation_Fish"}})
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(destroyed[1] == 501, "remote part delete not applied:\n" .. table.concat(log, "\n"))
assert(has("remote part delete applied"), "remote delete not logged:\n" .. table.concat(log, "\n"))
-- own undo per player: the local place of part 501 is journaled; Ctrl+Z deletes it here AND tells the partner,
-- Ctrl+Y places it again here AND tells the partner
local nBefore, nDestroyed = #packets, #destroyed
created = nil
assert(BuildSync.HandleUndoRedo(true) == true, "undo not handled")
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(packets[nBefore + 1].n == 0x21 and packets[nBefore + 1].d.k == "p" and packets[nBefore + 1].d.n == "Feeder_AquaticStation_Fish",
  "undo did not send the delete")
assert(#destroyed == nDestroyed + 1 and destroyed[#destroyed] == 501, "undo did not delete the part locally")
assert(BuildSync.HandleUndoRedo(false) == true, "redo not handled")
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(packets[nBefore + 2].n == 0x20 and packets[nBefore + 2].d.yaw == 1500, "redo did not send the place")
assert(created and created.name == "Feeder_AquaticStation_Fish", "redo did not re-create the part locally")
assert(has("undo: undo of 1 change(s): 1 done") and has("undo: redo of 1 change(s): 1 done"), table.concat(log, "\n"))
assert(BuildSync.HandleUndoRedo(false) == true and has("undo: nothing to redo"), "empty redo not handled")
-- a friend's building arrives while this player holds an item (live preview): it goes through the
-- player's editor at once instead of waiting until the item is put down
previewing = true
local nRuns = editorRuns
BuildSync.OnPacket({nType = 0x20, sFile = "/run/PZ2Coop/rx_0.bin", tData = {x = 9000, y = 100, z = 4000}})
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(editorRuns == nRuns + 1 and has("group handed to the active editor"),
  "building did not go through the editor while previewing:\n" .. table.concat(log, "\n"))
assert(not has("remote action waits: player is previewing a change"), "building waited for the preview")
previewing = false
assert(not has("job failed"), "a job failed:\n" .. table.concat(log, "\n"))
local summary = BuildSync.Summary()
assert(string.find(summary, "parts seen=1", 1, true), "summary wrong: " .. summary)
return "ok: " .. summary
"""


def main() -> int:
    lua = lupa.LuaRuntime()
    lua.globals().SOURCE = SOURCE
    try:
        result = lua.execute(HARNESS + CHECKS)
    except lupa.LuaError as error:
        print("FAIL:", error)
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
