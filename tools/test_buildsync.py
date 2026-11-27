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
  GetFlattenTerrainToggleState = function() return 2 end, CompositeAlignmentType_ItemAligned = 1,
  DecayCompositeAlignmentType = function() end, AlignCompositeRotation = function() end,
  SetCompositeOriginToOBBCentre = function() end, SetTransform = function(_, t) lastTransform = t end} end
hierarchyMT.IsLoadedBlueprintReadyForEditing = function() return true end
hierarchyMT.GetTerrainEditOperation = function() return {} end
hierarchyMT.AddBlueprintToCompositeObject = function() end
hierarchyMT.SetPerformTerrainModificationsModifyVolumes = function(_, b) terrainEdits = b end
local tWorldAPIs = {
  scenery_group = {
    TryGetBuildingGroupForPart = function() return nil end,
    CalculateBuildingGroupAABB = function() error("not a group") end,
  },
  placement = {GetPartResourceName = function(_, id) return parts[id] and parts[id].name end},
  scenery_puppets = {
    PlacementIDToEntityID = function(_, id) return parts[id] and id + 1000 end,
    EntityIDToPlacementID = function(_, e) return (e and parts[e - 1000]) and (e - 1000) or nil end,
  },
  spatial = {
    Flag_Scenery = 2,
    Flag_Enrichment = 16,
    SphereQuery = function(_, vPos, nRadius)
      local hits = {}
      for id, p in pairs(parts) do
        local dx = p.pos:GetX() - vPos:GetX()
        local dy = p.pos:GetY() - vPos:GetY()
        local dz = p.pos:GetZ() - vPos:GetZ()
        if dx*dx + dy*dy + dz*dz <= nRadius*nRadius then
          table.insert(hits, id + 1000)
        end
      end
      return hits
    end,
  },
  transform = {
    CalculateWorldTransform = function(_, e)
      local p = parts[e - 1000]
      if not p then return nil end
      return {GetPos = function() return p.pos end,
        GetOr = function() return {ToYawPitchRoll = function() return vec(1.5, 0, 0) end} end}
    end,
    GetParent = function() return nil end,
  },
  worldserialisation = {CreateSaveSelection = function() return {AddEntityID = function() end} end},
  scenery = {AddSceneryToBlueprintSelection = function() end, AddGroupToBlueprintSelection = function() end},
  editors = {
    CreateUndoOperationsHierarchy = function() return setmetatable({}, hierarchyMT) end,
    FlattenTerrain_LockedNeverFlatten = 1, TerrainActionType_PathJoinPartFlatten = 3, TerrainActionType_None = 0,
    SetTerrainActionOnMoveObject = function(_, _, nAction) terrainAction = nAction end,
    GetIsTutorialActive = function() return tutorialActive end,
    SetIsTutorialActive = function(_, b) tutorialActive = b end,
  },
  facilities = {GetAllHabitatsEntityIDs = function() return {} end},
  gameterrain = {SetTerrainEditOpCollisionFlags = function() end, CheckLakesMode_Off = 0,
    SetTerrainEditOpGridRenderingEnabled = function(_, _, b) gridOn = b end,
    ClearPreviewRenderGeometry = function(_, e) previewCleared = e end},
  voxelterrain = {GetPrimaryVoxelTerrainEntityID = function() return 77 end},
  habitat = {GetHabitatIDFromEntityID = function() end},
  habitatboundary = {GetBoundaryObjectsForHabitat = function() end},
  money = {GetCash = function() end, ModifyCash = function() end},
  -- the active editor runs requested undo operations (editors.shared.baseeditmode.lua:155); here at once
  ModeHelperComponent = {GetCurrentMode = function() return editMode end},
}
editorBusy = false
editorRuns = 0
tutorialActive = false
tutorialActiveDuringEditorRun = nil
editorRefuse = false
editMode = {
  HasRequestedChange = function() return editorBusy end,
  RequestUndoOperation = function(_, fn, _, post)
    editorRuns = editorRuns + 1
    fn(setmetatable({}, hierarchyMT))
    tutorialActiveDuringEditorRun = tutorialActive
    if not editorRefuse and post then post() end
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
    CanUndo = function() return false end, CanRedo = function() return false end,
  },
  messaging = setmetatable({
    RegisterReceiver = function(n, fn) receivers[n] = fn end, UnregisterReceiver = function() end,
  }, {__index = function(_, k) return k end}),
  game = {GetEnvironment = function() return {RequireInterface = function() return {
    SaveBlueprintToFile = function() return true end,
    LoadBlueprintFromFile = function(_, f) loaded = f return true end} end} end},
}
local Bridge = {
  Log = function(s) table.insert(log, s) end, Flush = function() end,
  IsApplying = function() return Bridge_applying end,
  BeginApply = function() Bridge_applying = true end, EndApply = function() Bridge_applying = false end,
  GetPrefix = function() return "/run/PZ2Coop/" end,
  GetRole = function() return "host" end,
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
  -- the HUD greys out undo/redo (and Ctrl+Z) from api.undo.CanUndo/CanRedo (windows.mainhud.lua:1792)
  ["Windows.MainHUD"] = {RequestUndoRedo = function() end,
    UpdateDisplay = function() hudCanUndo, hudCanRedo = api.undo.CanUndo(), api.undo.CanRedo() end},
  ["Editors.Scenery.SceneryEditHelper"] = {
    Yielding_CreateNewPart_Scenery = function(_, name)
      created = {name = name}
      return {SetTransform = function(_, t) created.transform = t end}
    end,
    NonYielding_AddPartToDestroyIntoCompositeObject = function(_, _, id) table.insert(destroyed, id) end,
    Yielding_DestroyCompositeContents = function() end,
  },
  -- vanilla methods the premade hook wraps (editors.blueprint.blueprintplacementmode.lua)
  ["Editors.Blueprint.BlueprintPlacementMode"] = {
    Init = function() end, Shutdown = function() end, OnTryCommitCheck = function() end,
    OnFailedCommit = function() end, FeaturePlaced = function() end,
    _GetBlueprintFileFromDatabase = function(_, id) return id == 42 and "Blueprints/Aviary42.bp" or nil end,
  },
  ["Editors.Scenery.Utils.SceneryUtils"] = {SetInitialBoundingBoxPlacement = function() end},
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
-- remote applies clear the game's history; the HUD must still offer undo from our own journal (1 entry now),
-- while editor code outside the HUD keeps seeing the game's real answer
local MainHUD = require("Windows.MainHUD")
MainHUD.UpdateDisplay(MainHUD)
assert(hudCanUndo == true and hudCanRedo == false, "HUD undo not enabled from the journal")
assert(api.undo.CanUndo() == false, "CanUndo override leaked outside the HUD")
-- a friend's building arrives while this player holds an item (live preview): it goes through the
-- player's editor at once instead of waiting until the item is put down
previewing = true
local nRuns = editorRuns
BuildSync.OnPacket({nType = 0x20, sFile = "/run/PZ2Coop/rx_0.bin", tData = {x = 9000, y = 100, z = 4000}})
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(editorRuns == nRuns + 1 and has("group handed to the active editor"),
  "building did not go through the editor while previewing:\n" .. table.concat(log, "\n"))
assert(not has("remote action waits: player is previewing a change"), "building waited for the preview")
assert(terrainEdits == true, "remote building placed with terrain edits off (no ground flatten/paint)")
assert(terrainAction == 3, "remote building skipped the vanilla flatten/join terrain action (got " .. tostring(terrainAction) .. ")")
previewing = false
assert(not has("job failed"), "a job failed:\n" .. table.concat(log, "\n"))
-- Pre-existing save parts (never seen in s.tSeen) are discovered via spatial:SphereQuery on remote delete
parts[777] = {name = "pl_gutter_01_straight_2m", pos = vec(52.18, 0.17, 121.16)}
tutorialActive = true
local nDesBefore = #destroyed
BuildSync.OnPacket({nType = 0x21, tData = {h = 0, x = 5218, y = 17, z = 12116, r = 250, k = "p", n = "pl_gutter_01_straight_2m"}})
for _ = 1, 10 do BuildSync.Update(0.1, true) end
assert(#destroyed == nDesBefore + 1 and destroyed[#destroyed] == 777,
  "pre-existing save part not found/deleted via spatial query:\n" .. table.concat(log, "\n"))
assert(tutorialActiveDuringEditorRun == false and tutorialActive == true,
  "tutorial restriction must be suspended during remote apply and restored after")
-- Batch Demolish (DestroyExistingParts with a BuildingPartSet) captures ALL parts via GetPartIDCollection()
parts[801] = {name = "pl_barrel_01", pos = vec(53.95, -0.01, 125.48)}
parts[802] = {name = "pl_spade", pos = vec(55.59, -0.03, 126.60)}
parts[803] = {name = "pl_rope_02_pile", pos = vec(52.86, -0.01, 123.45)}
local fakePartSet = {
  GetPartIDCollection = function() return {801, 802, 803} end,
  GetOnePartID = function() return 801 end,
}
local clh = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
clh:DestroyExistingParts(fakePartSet)
parts[801], parts[802], parts[803] = nil, nil, nil
local nPktsBeforeBatch = #packets
receivers.MsgType_PlacementPartCommittedMessage({
  {nPlacementPartID = 801}, {nPlacementPartID = 802}, {nPlacementPartID = 803},
})
BuildSync.Update(0.1, true)
assert(#packets == nPktsBeforeBatch + 3,
  "batch demolish should send all 3 deleted parts, got " .. tostring(#packets - nPktsBeforeBatch))
-- Refused editor commit exits promptly (within 3 ticks) instead of blocking for 30 s
editorRefuse = true
BuildSync.OnPacket({nType = 0x20, tData = {x = 6000, y = 200, z = 3000, k = "p", n = "HB_Nest_WaterPlatform_Large", yaw = 0, pitch = 0, roll = 0}})
-- It first waits 1 s after the batch demolish commit above (c_nAfterLocalCommit: a remote part handed over
-- mid-commit crashed the engine), then must exit within a few ticks
for _ = 1, 5 do BuildSync.Update(0.1, true) end
assert(not has("refused by the active editor"), "remote editor op ran right after the player's own commit")
for _ = 1, 10 do BuildSync.Update(0.1, true) end
editorRefuse = false
assert(has("refused by the active editor"), "refused editor op did not exit promptly:\n" .. table.concat(log, "\n"))
assert(tutorialActive == true and not Bridge.IsApplying(), "guards leaked after refused editor commit")
local summary = BuildSync.Summary()
assert(string.find(summary, "parts seen=4", 1, true), "summary wrong: " .. summary)
-- Premade (game database) blueprint: sent ONCE as id + transform; its pieces are not sent one by one
-- (an aviary got mirrored several times, half the copies without decoration, none with its terrain edits)
local BPM = require("Editors.Blueprint.BlueprintPlacementMode")
for _ = 1, 20 do BuildSync.Update(0.1, true) end -- past the refused op's remote-commit grace window
local mode ={tGameBlueprint = {blueprintID = 42}}
BPM.Init(mode)
local mo = {GetTransform = function() return {GetPosition = function() return vec(100.5, 2, -30.25) end,
  GetOrientation = function() return {ToYawPitchRoll = function() return vec(0.785398, 0, 0) end} end} end}
local nP = #packets
BPM.OnTryCommitCheck(mode, mo)
parts[901] = {name = "pl_aviary_perch", pos = vec(101, 2, -30)}
receivers.MsgType_PlacementPartCommittedMessage({{nPlacementPartID = 901}})
BuildSync.Update(0.1, true)
assert(#packets == nP, "premade piece was sent on its own")
assert(has("is part of premade blueprint 42, not sent separately"), table.concat(log, "\n"))
BPM.FeaturePlaced(mode)
local bp = packets[nP + 1]
assert(#packets == nP + 1 and bp.n == 0x20 and bp.f == nil and bp.d.k == "bp" and bp.d.id == 42 and
  bp.d.x == 10050 and bp.d.y == 200 and bp.d.z == -3025 and bp.d.yaw == 0.785398 and bp.d.pitch == 0,
  "premade packet missing or wrong")
assert(BuildSync.IsPremadeQuiet(), "premade window not open after placement")
for _ = 1, 40 do BuildSync.Update(0.1, true) end
assert(not BuildSync.IsPremadeQuiet(), "premade window never closed")
-- refused commit: nothing sent, window closed at once
BPM.OnTryCommitCheck(mode, mo)
BPM.OnFailedCommit(mode)
BPM.FeaturePlaced(mode)
assert(#packets == nP + 1 and not BuildSync.IsPremadeQuiet(), "refused premade commit sent or kept the window")
-- own (local save) blueprint: no k = "bp", pieces go as before
local mLocal = {tLocalBlueprint = {saveToken = 1}}
BPM.OnTryCommitCheck(mLocal, mo)
parts[902] = {name = "pl_rock_01", pos = vec(103, 2, -31)}
receivers.MsgType_PlacementPartCommittedMessage({{nPlacementPartID = 902}})
BuildSync.Update(0.1, true)
BPM.FeaturePlaced(mLocal)
assert(#packets == nP + 2 and packets[nP + 2].d.k == "p" and packets[nP + 2].d.n == "pl_rock_01",
  "own-save blueprint piece not sent as before")
BPM.Shutdown(mode) -- the tool closes after placing; remote blueprints wait for the shared slot until then
-- receiver: loads the SAME database file and commits it on the sender's transform with the vanilla terrain step
loaded, lastTransform, terrainEdits, terrainAction, gridOn, previewCleared = nil, nil, nil, nil, nil, nil
BuildSync.OnPacket({nType = 0x20, tData = {k = "bp", id = 42, x = 15050, y = 200, z = -3025, yaw = 0.785398, pitch = 0, roll = 0}})
for _ = 1, 20 do BuildSync.Update(0.1, true) end
assert(loaded == "Blueprints/Aviary42.bp", "premade not loaded from the database file: " .. tostring(loaded) ..
  "\n" .. table.concat(log, "\n"))
assert(lastTransform and lastTransform.pos.GetX() == 150.5 and lastTransform.pos.GetZ() == -30.25 and
  lastTransform.q.ypr.GetX() == 0.785398, "premade transform wrong")
assert(terrainEdits == true and terrainAction == 3, "premade committed without the vanilla terrain step")
-- the terrain grid preview stayed drawn over the mirrored premade's repainted ground until the next preview
assert(gridOn == false and previewCleared == 77, "terrain grid preview left on after the remote premade")
assert(has("remote premade blueprint 42 applied"), table.concat(log, "\n"))
assert(BuildSync.IsPremadeQuiet(), "receiver does not absorb its own premade echoes")
for _ = 1, 40 do BuildSync.Update(0.1, true) end
-- bad ids never load anything (the path always comes from the local database)
loaded = nil
for _, bad in ipairs({"42", -1, 7, 4.5}) do
  BuildSync.OnPacket({nType = 0x20, tData = {k = "bp", id = bad, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0}})
end
BuildSync.OnPacket({nType = 0x20, tData = {k = "bp", id = 42, x = 0, y = 0, z = 0, yaw = 0 / 0, pitch = 0, roll = 0}})
for _ = 1, 20 do BuildSync.Update(0.1, true) end
assert(loaded == nil and has("not in the local database"), "bad premade id loaded something")
assert(not has("job failed"), "a job failed:\n" .. table.concat(log, "\n"))
return "ok: " .. BuildSync.Summary()
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
