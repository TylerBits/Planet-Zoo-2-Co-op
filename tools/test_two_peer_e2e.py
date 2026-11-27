#!/usr/bin/env python3
"""Two-Peer End-to-End Wire Simulator (run: python tools/test_two_peer_e2e.py).

Spins up TWO completely independent Lua VMs (Host and Guest), each running the real mod modules
(Bridge, BuildSync, RegionSync, WaterSync, StaffSync, Presence, PZ2CoopManager), connected over a
simulated Steam P2P wire that enforces:
  - real JSON serialization + deserialization on every packet (catching non-serializable tables/keys),
  - host-only enforcement (0x02, 0x03, 0x11 dropped if sent by guest),
  - echo-guard enforcement (CLAUDE.md rule 2: packets >= 0x20 dropped while applying),
  - zero echo loops across both peers.

Verifies end-to-end across Host <-> Guest:
  1. Session join + in-game notifications (Green on join, Red on disconnect, partner name preserved)
  2. Host-authoritative cash ledger (0x11) overwrites guest cash
  3. Presence (0x10) + Friend Avatar (0x12) both directions with custom colour int-key fixup
  4. Water lake add + remove (0x22) Host -> Guest with zero echo back
  5. Staff hire + fire (0x30) Host -> Guest matched by SyncUUID with zero echo back
  6. Trust-boundary rejection of malformed/malicious packets from a compromised peer
"""
import json
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
MOD_DIR = ROOT / "src" / "ovl_mod"

MODULE_FILES = {
    "PZ2Coop.Bridge": "pz2coop.bridge.lua",
    "PZ2Coop.BuildSync": "pz2coop.buildsync.lua",
    "PZ2Coop.RegionSync": "pz2coop.regionsync.lua",
    "PZ2Coop.RegionSync_Logic": "pz2coop.regionsync_logic.lua",
    "PZ2Coop.WaterSync": "pz2coop.watersync.lua",
    "PZ2Coop.TerrainSync": "pz2coop.terrainsync.lua",
    "PZ2Coop.StaffSync": "pz2coop.staffsync.lua",
    "PZ2Coop.AnimalSync": "pz2coop.animalsync.lua",
    "PZ2Coop.ResearchSync": "pz2coop.researchsync.lua",
    "PZ2Coop.CareerSync": "pz2coop.careersync.lua",
    "PZ2Coop.Avatar": "pz2coop.avatar.lua",
    "PZ2Coop.Presence": "pz2coop.presence.lua",
    "PZ2Coop.Actions": "pz2coop.actions.lua",
    "PZ2Coop.Vehicles": "pz2coop.vehicles.lua",
    "PZ2Coop.SaveGuard": "pz2coop.saveguard.lua",
    "Managers.PZ2CoopManager": "managers.pz2coopmanager.lua",
}

HOST_ONLY = {0x02, 0x03, 0x11}


def lua_to_py(val):
    if lupa.lua_type(val) != "table":
        return val
    keys = list(val.keys())
    if keys and all(isinstance(k, int) for k in keys):
        keys_sorted = sorted(keys)
        if keys_sorted == list(range(1, len(keys_sorted) + 1)):
            return [lua_to_py(val[k]) for k in keys_sorted]
    return {str(k): lua_to_py(v) for k, v in val.items()}


def py_to_lua(rt, val):
    if isinstance(val, list):
        t = rt.table()
        for i, item in enumerate(val, 1):
            t[i] = py_to_lua(rt, item)
        return t
    if isinstance(val, dict):
        t = rt.table()
        for k, v in val.items():
            t[k] = py_to_lua(rt, v)
        return t
    return val


PEER_HARNESS = r"""
log, outbox, calls, popouts = {}, {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end}
end

state = {
  cash = 5000.0,
  gameMode = PEER_MODE,
  scenarioCode = PEER_SCENARIO,
  gameDiff = PEER_DIFF,
  isWildArea = PEER_WILD,
  dlcBlocked = PEER_DLC_BLOCKED,
  simPaused = false,
  simSpeedIdx = 1,
  todHour = 14,
  todMinute = 30,
  camMode = "Walking",
  camPos = vec(10, 11.55, 20),
  camYPR = vec(0.5, 0, 0),
  avatarGroup = PEER_GROUP,
  lakes = {},
  staff = {},
  exhibits = {[50] = {pos = vec(40, 0, 50), animals = {}}},
  researchTiers = {Vet_Lion = 0},
  researchMaxTier = {Vet_Lion = 5},
  nextId = 100,
  transforms = {},
  hidden = {},
  autosaveSuspended = false,
  autosaveCleared = 0,
  returnedToStart = 0,
}

local receivers = {}
local tWorldAPIs = {
  money = {
    GetCash = function() return state.cash end,
    GetConservationCredits = function() return 100 end,
    HasUnlimitedCash = function() return false end,
    ModifyCash = function(_, delta) state.cash = state.cash + delta call("ModifyCash", delta) end,
  },
  park = {ExpenditureCategory_Rewards = 1, GetTimeOfDay = function() return state.todHour, state.todMinute end},
  wildterritory = {IsWildTerritoryCreationEnabled = function() return state.isWildArea == true end},
  exhibits = {
    AddAnimalToExhibit = function(_, exId, sp, bMale)
      call("AddAnimalToExhibit", exId, sp, bMale)
      if state.exhibits[exId] then
        table.insert(state.exhibits[exId].animals, {species = sp, male = bMale})
      end
    end,
    IsAnimalMale = function() return true end,
  },
  research = {
    GetPinnedResearch = function() return "Vet_Lion" end,
    GetCurrentTier = function(_, topic) return state.researchTiers[topic] or 0 end,
    IsResearchTopic = function(_, topic) return state.researchMaxTier[topic] ~= nil end,
    GetMaxTier = function(_, topic) return state.researchMaxTier[topic] or 0 end,
    SetTierForTopic = function(_, topic, tier)
      state.researchTiers[topic] = tier
      call("SetTierForTopic", topic, tier)
    end,
    ClearNotificationBlip = function(_, topic) call("ClearNotificationBlip", topic) end,
  },
  ModeHelperComponent = {GetCurrentModeName = function() return "WalkingCamera" end},
  InputManager = {GetKeyPressed = function() return false end, GetMouseInput = function() return {RawZAxis = 0} end},
  motiongraph = {SetVariable = function() end},
  bakedanimation = {RequestAllBonesForCalculate = function() end},
  model = {SetHidden = function(_, id, b) state.hidden[id] = b end},
  voxelterrain = {SphereSweep = function() return nil end},
  CameraModeManager = {
    GetVoxelTerrainID = function() return 1 end,
    GetPosYPRZoom = function() return state.camPos, state.camYPR, 10 end,
    GetCurrentModeName = function() return state.camMode end,
    GetCameraDataFinal = function() return {vCentrePos = state.camPos} end,
    RequestMode = function() end,
  },
  transform = {
    HasTransform = function(_, id) return state.transforms[id] ~= nil end,
    SetTransform = function(_, id, t) state.transforms[id] = t end,
    SetPosition = function(_, id, v)
      state.transforms[id] = {pos = v}
      if state.staff[id] then state.staff[id].pos = v end
    end,
    CalculateWorldTransform = function(_, id)
      local st = state.staff[id]
      if st then return {GetPos = function() return st.pos end, Pos = function() return st.pos end} end
      local ex = state.exhibits[id]
      if ex then return {GetPos = function() return ex.pos end, Pos = function() return ex.pos end} end
      return nil
    end,
    GetParent = function() return nil end,
  },
  billboardwidgets = {WidgetType_WidgetLabel = 7},
  spatial = {
    Flag_Path = 1,
    Flag_Exhibit = 2,
    Flag_HabitatBoundary = 524288,
    CylinderQuery = function() return {} end,
    SphereQuery = function(_, vPos, r, nFlag)
      if nFlag == 2 then
        local hits = {}
        for id, ex in pairs(state.exhibits) do
          local dx = ex.pos:GetX() - vPos:GetX()
          local dy = ex.pos:GetY() - vPos:GetY()
          local dz = ex.pos:GetZ() - vPos:GetZ()
          if dx*dx + dy*dy + dz*dz <= r*r then table.insert(hits, id) end
        end
        return hits
      end
      return {}
    end,
  },
  gameterrain = {
    GetAllLakes = function()
      local t = {}
      for id in pairs(state.lakes) do table.insert(t, id) end
      table.sort(t)
      return t
    end,
    FindLakeRefillPoint = function(_, id) return state.lakes[id] and state.lakes[id].fill end,
    GetLakeRespawnProperties = function(_, id) return state.lakes[id] and state.lakes[id].props end,
    PreviewLakeAddition = function(_, vFill, sPrefab, sSurf, sUnder, nClean, nTemp, tCol, tPart)
      state._pendingLake = {fill = vFill, props = {sPrefabName = sPrefab, sSurfaceMaterialName = sSurf,
        sUndersideMaterialName = sUnder, nCleanliness = nClean, nTemperature = nTemp,
        tColourData = tCol, tParticleData = tPart}}
      call("PreviewLakeAddition", vFill, sSurf)
    end,
    IsPreviewLakeAdditionDone = function() return true end,
    IsPreviewLakeAdditionCommitableInTheory = function() return true end,
    IsPreviewLakeAdditionCommitableInPractice = function() return true end,
    CreateLakeAddOperationFromLakePreview = function() return {kind = "add_lake"} end,
    ResetPreviewLakeAddition = function() state._pendingLake = nil end,
    FindLakesWithSphereCheck = function(_, vPos, r)
      local hits = {}
      for id, l in pairs(state.lakes) do
        local dx = l.fill:GetX() - vPos:GetX()
        local dy = l.fill:GetY() - vPos:GetY()
        local dz = l.fill:GetZ() - vPos:GetZ()
        if dx*dx + dy*dy + dz*dz <= r*r then table.insert(hits, id) end
      end
      return hits
    end,
    CreateLakeRemoveOperation = function(_, id) return {kind = "remove_lake", id = id} end,
  },
  staff = {
    GetAllStaffEntities = function()
      local t = {}
      for id in pairs(state.staff) do table.insert(t, id) end
      table.sort(t)
      return t
    end,
    GetStaffMemberType = function(_, id) return state.staff[id] and state.staff[id].type end,
    SetStaffMemberSuspended = function(_, id, b) call("SetStaffMemberSuspended", id, b) end,
    IncreasePriorityOfNearestApplicableJobInRange = function() end,
    FireStaffMember = function(_, id)
      state.staff[id] = nil
      call("FireStaffMember", id)
      for _, fn in ipairs(receivers.MsgType_StaffCreatedOrDestroyedMessage or {}) do
        fn({{staffEntityID = id, bCreated = false}})
      end
    end,
  },
  scenery_group = {TryGetBuildingGroupForPart = function() end, CalculateBuildingGroupAABB = function() end},
  placement = {GetPartResourceName = function() end},
  facilities = {GetAllHabitatsEntityIDs = function() return {} end},
  editors = {CreateUndoOperationsHierarchy = function() return {} end},
}

local notificationManager = {tTimelinePopOutQueue = popouts}
local labelManager = {SetBillboardWidgetUIInfo = function() end, SetBillboardWidgetData = function() end, ClearBillboardWidgetData = function() end}
local scenarioManager = {
  GetGameMode = function() return state.gameMode end,
  GetScenarioCode = function() return state.scenarioCode end,
  GetGameDifficulty = function() return state.gameDiff end,
  IsDLCBlockingParkLoad = function() return state.dlcBlocked == true end,
}
local nextWorldDataManager = {
  SetGameMode = function(_, m) call("SetGameMode", m) end,
  SetIsWildArea = function(_, b) call("SetIsWildArea", b) end,
  SetScenarioCode = function(_, c) call("SetScenarioCode", c) end,
  SetGameDifficulty = function(_, d) call("SetGameDifficulty", d) end,
}
local parkLoadSaveManager = {
  SaveParkToFile = function(_, path) call("SaveParkToFile", path) return true, "ok" end,
  RequestLoadParkFromFile = function(_, path) call("RequestLoadParkFromFile", path) return true, "ok" end,
  ClearAutosaveSlot = function() state.autosaveCleared = state.autosaveCleared + 1 end,
  SaveParkToSlot = function() call("SaveParkToSlot") return true, "ok" end,
  SaveParkToSaveToken = function() call("SaveParkToSaveToken") return true, "ok" end,
  SelectAppropriateAutosaveSlot = function() call("SelectAppropriateAutosaveSlot") end,
}
local mainHUD = {
  GetSimulationTimeSettings = function() return {bPaused = state.simPaused, nTimeScaleIndex = state.simSpeedIdx} end,
  ChangeSimulationSpeedSettings = function(_, bPause, nIdx)
    if bPause ~= nil then state.simPaused = bPause end
    if nIdx ~= nil then state.simSpeedIdx = nIdx end
    call("ChangeSimulationSpeedSettings", state.simPaused, state.simSpeedIdx)
  end,
  saveAgent = {
    OnPauseMenu_ReturnToStartScreen = function(_, _, bSuppress, bShot)
      state.returnedToStart = state.returnedToStart + 1
      call("ReturnToStartScreen", bSuppress, bShot)
    end,
  },
}
local tEnv = {
  RequestInterface = function(_, name)
    if name == "Interfaces.INotificationManager" then return notificationManager end
    if name == "Interfaces.IScenarioManager" then return scenarioManager end
    if name == "Interfaces.INextWorldDataManager" then return nextWorldDataManager end
    if name == "Interfaces.IParkLoadSaveManager" then return parkLoadSaveManager end
    return nil
  end,
  RequireInterface = function(_, name)
    if name == "Interfaces.IUIBillboardWidgetsManager" then return labelManager end
    if name == "Interfaces.INextWorldDataManager" then return nextWorldDataManager end
    if name == "Interfaces.IParkLoadSaveManager" then return parkLoadSaveManager end
    return nil
  end,
}

local activePreview = nil
local token = {}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end, GetActive = function() return 1 end,
    GetScript = function() return {tEnvironment = tEnv, GetHUD = function() return mainHUD end} end},
  game = {GetEnvironment = function() return tEnv end},
  player = {GetGameOwner = function() return 1 end},
  save = {
    ID_ZooAutosave = 2,
    GetIdentForSaveID = function() return "zooauto" end,
    CreateSaveSuspensionControl = function()
      return {
        SuspendAutosave = function() state.autosaveSuspended = true end,
        ResumeAutosave = function() state.autosaveSuspended = false end,
      }
    end,
  },
  api_anim = nil,
  animationcontrol = {
    SetBaseAnimation = function(id, clip) call("SetBaseAnimation", id, clip) end,
    SetPlaybackRate = function() end,
    QueueOneShotAnimation = function(id, clip) call("QueueOneShot", id, clip) end,
    ClearOneShotQueueAndForceStopOneShot = function() end,
  },
  json = {
    Stringify = function(t) return true, PY_JSON_DUMPS(t) end,
    Parse = function(s) return true, PY_JSON_LOADS(s) end,
    GetArrayMetatable = function() return {} end,
  },
  time = {GetDeltaTimeUnscaled = function() return 0.1 end, GetTotalTimeUnscaled = function() return 1 end},
  entity = {
    CreateRequestCompletionToken = function() return {} end,
    HaveRequestsCompleted = function() return true end,
    InstantiatePrefab = function(prefab, sName, tok, tr, parent, b, tProps)
      state.nextId = state.nextId + 1
      local id = state.nextId
      state.transforms[id] = tr or {}
      if type(prefab) == "string" and (prefab == "Keeper" or prefab == "Mechanic" or prefab == "Vet" or prefab == "Janitor" or prefab == "Vendor" or prefab == "Presenter") then
        state.staff[id] = {type = prefab, pos = vec(0, 0, 0)}
        for _, fn in ipairs(receivers.MsgType_StaffCreatedOrDestroyedMessage or {}) do
          fn({{staffEntityID = id, bCreated = true}})
        end
      end
      call("InstantiatePrefab", prefab, id)
      return id
    end,
    DestroyEntity = function(id) state.transforms[id] = nil end,
    FindEntityByName = function() return nil end,
  },
  undo = {
    PreviewChangeList = function(cl) activePreview = cl return token, token end,
    IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end,
    CommitPreview = function()
      if type(activePreview) == "table" then
        if activePreview.kind == "add_lake" and state._pendingLake then
          state.nextId = state.nextId + 1
          state.lakes[state.nextId] = state._pendingLake
          for _, fn in ipairs(receivers.MsgType_LakeUpdateMessage or {}) do fn({{nLakeID = state.nextId}}) end
        elseif activePreview.kind == "remove_lake" then
          state.lakes[activePreview.id] = nil
          for _, fn in ipairs(receivers.MsgType_LakeUpdateMessage or {}) do fn({{nLakeID = activePreview.id}}) end
        end
      end
      activePreview = nil
      return token
    end,
    CancelPreview = function() activePreview = nil return token end,
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

local StaffPlacementMode = {_CommitStaffMember = function() end}
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {Identity = {WithPos = function(_, v) return {pos = v} end},
    FromOrPos = function(q, v) return {pos = v, yaw = q.yaw} end},
  Quaternion = {Identity = {yaw = 0}, FromYawPitchRoll = function(v) return {yaw = v:GetX()} end},
  ["Environment.ModuleMutators"] = {Manager = function() return function(m) return m end end},
  ["Editors.Scenery.SceneryEditHelper"] = {},
  ["Editors.Shared.BaseUIMode"] = {GetModeHelperEntity = function() return 1 end, SetNewMode = function() end},
  ["Editors.Shared.BaseEditMode"] = {GetModeHelperEntity = function() return 1 end, SetNewMode = function() end},
  ["Editors.Staff.StaffPlacementMode"] = StaffPlacementMode,
  ["Helpers.StaffUtils"] = {GetStaffType = function(staffAPI, id) return staffAPI:GetStaffMemberType(id) end},
  ["Components.Cameras.WalkingCamera"] = {GetDefaultWalkingHeight = function() return 1.55 end, Advance = function() end},
  ["Components.Cameras.CameraModeManager"] = {TryRequestWalkingMode = function() return true end},
  ["Editors.Vehicle.DriveVehicleUIMode"] = {SwitchCamera = function() end, TransitionIn = function() end},
  ["Database.GameDatabase"] = {
    GetPlayerKey = function() return 1 end,
    GetPlayer = function() return {GetMainAvatarData = function()
      return {tData = {version = 6, group = state.avatarGroup, actor = 1, voice = 0, variant = 2, skin = 3,
        parts = {Heads = {model = 7, custom = {colours = {[1] = 10, [2] = 20}}}},
        items = {Hats = {prefab = "Hat_Explorer"}}}}
    end} end,
    GetButtonPromptData = function() return nil end,
  },
  ["StartScreen.Shared.StartScreenAvatar"] = {
    AvatarVersionCheck = function(t) return t end,
    new = function() return {Create = function(self, tAvatar, nParent, sType)
      coroutine.yield()
      self.nAnimatedEntityID = api.entity.InstantiatePrefab("Peep_Avatar_StartScreen", "Avatar", {}, nil, nParent, true, {})
      call("AvatarBuilt", tAvatar.group, sType, tAvatar.parts and tAvatar.parts.Heads and tAvatar.parts.Heads.custom.colours[1])
    end} end,
  },
}

local loaded = {}
require = function(name)
  if stubs[name] then return stubs[name] end
  if loaded[name] then return loaded[name] end
  if SOURCES[name] then
    local mod
    local prevModule = module
    module = function() mod = {} return mod end
    load(SOURCES[name], name)()
    module = prevModule
    loaded[name] = mod
    return mod
  end
  error("module not stubbed: " .. name)
end

Bridge = require("PZ2Coop.Bridge")
Bridge.Log = function(s) table.insert(log, s) end
Bridge.Open()
Bridge.SendPacket = function(nType, sFile, tData)
  if nType >= 0x20 and Bridge.IsApplying() then return false end
  table.insert(outbox, {nType = nType, sFile = sFile, json = PY_JSON_DUMPS(tData or {})})
  return true
end

ManagerMod = require("Managers.PZ2CoopManager")
mgr = setmetatable({}, {__index = ManagerMod})
mgr:Init({}, tEnv)
mgr:Advance(0.1) -- starts manager

function deliverEvent(tEvent)
  local s = __PZ2CoopBridgeState
  if tEvent.event == "status" then
    s.sRole = tEvent.role or s.sRole
    s.bPeerConnected = tEvent.connected == true
    Bridge.GetSession().sPartner = tEvent.partner_name
    Bridge.GetSession().sPartnerId = tEvent.partner_id
  elseif tEvent.event == "peer_connected" then
    s.bPeerConnected = true
  elseif tEvent.event == "peer_disconnected" then
    s.bPeerConnected = false
    Bridge.GetSession().sPartner = nil
  end
  if s.fnHandler ~= nil then
    s.fnHandler({sKind = "event", tData = tEvent})
  end
end

function deliverPacket(nType, sFile, sJson)
  local tData = PY_JSON_LOADS(sJson)
  -- Mirror Bridge.Pump handshake tracking before invoking park handler
  if nType == 0x01 and type(tData) == "table" then
    local s = __PZ2CoopBridgeState
    if Bridge.IsAllowedGameMode(tData.mode) then s.sHostMode = tData.mode end
    if type(tData.scenario) == "string" and #tData.scenario > 0 then s.sHostScenario = tData.scenario end
    if type(tData.diff) == "string" then s.sHostDifficulty = tData.diff end
    if tData.wild ~= nil then s.bHostWildArea = tData.wild == true end
    local localVer = Bridge.GetModVersion and Bridge.GetModVersion() or nil
    if type(tData.ver) == "string" and tData.ver ~= "" and localVer ~= nil and tData.ver ~= localVer then
      s.sVersionMismatch = "peer " .. string.sub(tData.ver, 1, 16) .. " vs local " .. localVer
    else
      s.sVersionMismatch = nil
    end
  end
  if __PZ2CoopBridgeState.fnHandler ~= nil then
    __PZ2CoopBridgeState.fnHandler({sKind = "packet", nType = nType, sFile = sFile, tData = tData})
  end
end

function tick(n)
  for _ = 1, n or 1 do mgr:Advance(0.1) end
end

function triggerLocalLakeAdd(x, y, z)
  state.nextId = state.nextId + 1
  local id = state.nextId
  state.lakes[id] = {fill = vec(x, y, z), props = {sPrefabName = "Lake", sSurfaceMaterialName = "CalmWaterSurface",
    sUndersideMaterialName = "CalmWaterUnderside", nCleanliness = 0.9, nTemperature = 22}}
  for _, fn in ipairs(receivers.MsgType_LakeUpdateMessage or {}) do fn({{nLakeID = id}}) end
  return id
end

function triggerLocalLakeRemove(id)
  state.lakes[id] = nil
  for _, fn in ipairs(receivers.MsgType_LakeUpdateMessage or {}) do fn({{nLakeID = id}}) end
end

function triggerLocalStaffHire(sType, x, y, z)
  state.nextId = state.nextId + 1
  local id = state.nextId
  state.staff[id] = {type = sType, pos = vec(x, y, z)}
  for _, fn in ipairs(receivers.MsgType_StaffCreatedOrDestroyedMessage or {}) do
    fn({{staffEntityID = id, bCreated = true}})
  end
  StaffPlacementMode._CommitStaffMember({staffEntityID = id, bCreateNew = true}, vec(x, y, z))
  return id
end

function triggerLocalStaffFire(id)
  state.staff[id] = nil
  for _, fn in ipairs(receivers.MsgType_StaffCreatedOrDestroyedMessage or {}) do
    fn({{staffEntityID = id, bCreated = false}})
  end
end

function triggerLocalResearchUnlock(sTopic, nTier)
  state.researchTiers[sTopic] = nTier
  for _, fn in ipairs(receivers.MsgType_ResearchUpdatedMessage or {}) do
    fn({{sTopic = sTopic, bOnLoad = false}})
  end
end

function triggerLocalExhibitAdd(nExhibitID, sSpecies)
  state.nextId = state.nextId + 1
  local id = state.nextId
  for _, fn in ipairs(receivers.MsgType_ExhibitAnimalAddedMessage or {}) do
    fn({{nAnimalID = id, nParentExhibitEntityID = nExhibitID, sSpecies = sSpecies}})
  end
  return id
end

function triggerLocalEmote(sId)
  local Actions = require("PZ2Coop.Actions")
  return Actions.PlayEmote(sId)
end

function drainOutbox()
  local out = outbox
  outbox = {}
  return out
end

function lakeCount()
  local n = 0
  for _ in pairs(state.lakes) do n = n + 1 end
  return n
end

function staffCount()
  local n = 0
  for _ in pairs(state.staff) do n = n + 1 end
  return n
end
"""


def make_peer(role: str, group: str, mode: str = "Sandbox", scenario=None, diff=None, wild: bool = False, dlc_blocked: bool = False):
    rt = lupa.LuaRuntime()
    sources = rt.table()
    for mod_name, filename in MODULE_FILES.items():
        sources[mod_name] = (MOD_DIR / filename).read_text(encoding="utf-8")
    rt.globals().SOURCES = sources
    rt.globals().PEER_GROUP = group
    rt.globals().PEER_MODE = mode
    rt.globals().PEER_SCENARIO = scenario
    rt.globals().PEER_DIFF = diff
    rt.globals().PEER_WILD = wild
    rt.globals().PEER_DLC_BLOCKED = dlc_blocked
    rt.globals().PY_JSON_DUMPS = lambda t: json.dumps(lua_to_py(t))
    rt.globals().PY_JSON_LOADS = lambda s: py_to_lua(rt, json.loads(s))
    rt.execute(PEER_HARNESS)
    return rt


def pump_wire(host, guest, rounds=10):
    sent_h, sent_g = [], []
    for _ in range(rounds):
        host.globals().tick(1)
        guest.globals().tick(1)
        for pkt in list(host.globals().drainOutbox().values()):
            n_type = int(pkt["nType"])
            s_file = pkt["sFile"]
            s_json = pkt["json"]
            sent_h.append((n_type, s_file, json.loads(s_json)))
            if n_type == 0x02:
                # Simulate DLL reassembling baseline save -> 0x03 load commit
                guest.globals().deliverPacket(0x03, "/run/PZ2Coop/rx_save.bin", "{}")
            else:
                guest.globals().deliverPacket(n_type, s_file and ("/run/PZ2Coop/" + s_file), s_json)
        for pkt in list(guest.globals().drainOutbox().values()):
            n_type = int(pkt["nType"])
            s_file = pkt["sFile"]
            s_json = pkt["json"]
            if n_type in HOST_ONLY:
                continue  # DLL enforces host-only
            sent_g.append((n_type, s_file, json.loads(s_json)))
            host.globals().deliverPacket(n_type, s_file and ("/run/PZ2Coop/" + s_file), s_json)
    return sent_h, sent_g


def main() -> int:
    host = make_peer("host", "TM")
    guest = make_peer("client", "AF")

    # Advance past 5 s startup windows on both peers
    host.globals().tick(60)
    guest.globals().tick(60)

    # 1. Connect peers: host status + peer_connected -> handshake 0x01 + baseline save + Green notifications + speed sync
    host.globals().state["cash"] = 12345.0
    host.globals().state["simSpeedIdx"] = 3  # 5x speed
    guest.globals().state["cash"] = 5000.0
    guest.globals().state["simSpeedIdx"] = 1
    host.globals().deliverEvent(py_to_lua(host, {"event": "status", "role": "host", "connected": True, "partner_name": "GuestPlayer", "partner_id": "222"}))
    guest.globals().deliverEvent(py_to_lua(guest, {"event": "status", "role": "client", "connected": True, "partner_name": "HostPlayer", "partner_id": "111"}))
    host.globals().deliverEvent(py_to_lua(host, {"event": "peer_connected"}))
    guest.globals().deliverEvent(py_to_lua(guest, {"event": "peer_connected"}))

    sent_h, sent_g = pump_wire(host, guest, rounds=15)

    # Check handshake 0x01, notifications, baseline, ledger cash + simulation speed sync
    assert any(t == 0x01 and d.get("mode") == "Sandbox" and d.get("ver") for t, _, d in sent_h), "host handshake 0x01 missing"
    h_pop = lua_to_py(host.globals().popouts)
    g_pop = lua_to_py(guest.globals().popouts)
    assert any("GuestPlayer joined your zoo" in p["tEntry"]["sNotificationString"] for p in h_pop), f"host join notify missing: {h_pop}"
    assert any("Connected to HostPlayer's zoo" in p["tEntry"]["sNotificationString"] for p in g_pop), f"guest join notify missing: {g_pop}"

    assert any(t == 0x02 for t, _, _ in sent_h), "host never sent baseline 0x02"
    assert abs(guest.globals().state["cash"] - 12345.0) < 0.05, f"guest cash not synced: {guest.globals().state['cash']}"
    assert guest.globals().state["simSpeedIdx"] == 3, f"guest sim speed not synced to 5x: {guest.globals().state['simSpeedIdx']}"
    assert any(t == 0x11 and abs(d.get("tod", 0) - 14.5) < 0.05 for t, _, d in sent_h), "time of day not carried in ledger"

    # Host pauses -> guest pauses
    host.globals().state["simPaused"] = True
    pump_wire(host, guest, rounds=12)
    assert guest.globals().state["simPaused"] is True, "guest did not pause with host"

    # Host resync button -> sends a fresh 0x02 baseline
    host.globals().Bridge.RequestResync()
    sent_h, _ = pump_wire(host, guest, rounds=5)
    assert any(t == 0x02 for t, _, _ in sent_h), "host resync did not send baseline 0x02"

    # Check 0x12 friend avatar built on BOTH peers with JSON int-key colour fixup intact
    h_calls = lua_to_py(host.globals().calls)
    g_calls = lua_to_py(guest.globals().calls)
    assert any(c["name"] == "AvatarBuilt" and c["args"] == ["AF", "friend", 10] for c in h_calls), f"host missing guest avatar: {h_calls}"
    assert any(c["name"] == "AvatarBuilt" and c["args"] == ["TM", "friend", 10] for c in g_calls), f"guest missing host avatar: {g_calls}"

    # 2. Water lake add + remove Host -> Guest (zero echo back to Host)
    lake_id = host.globals().triggerLocalLakeAdd(15.0, 2.0, 25.0)
    sent_h, sent_g = pump_wire(host, guest, rounds=25)
    assert any(t == 0x22 and d.get("k") == "water" and d.get("op") == "add" for t, _, d in sent_h), "water add not sent"
    assert guest.globals().lakeCount() == 1, f"guest lake not created: {guest.globals().lakeCount()}"
    assert not any(t == 0x22 and d.get("k") == "water" for t, _, d in sent_g), f"guest echoed water back: {sent_g}"

    host.globals().triggerLocalLakeRemove(lake_id)
    sent_h, sent_g = pump_wire(host, guest, rounds=25)
    assert any(t == 0x22 and d.get("k") == "water" and d.get("op") == "remove" for t, _, d in sent_h), "water remove not sent"
    assert guest.globals().lakeCount() == 0, f"guest lake not removed: {guest.globals().lakeCount()}"
    assert not any(t == 0x22 and d.get("k") == "water" for t, _, d in sent_g), "guest echoed water remove"

    # 3. Staff hire + fire Host -> Guest (zero echo back)
    staff_id = host.globals().triggerLocalStaffHire("Keeper", 30.0, 0.0, 40.0)
    sent_h, sent_g = pump_wire(host, guest, rounds=15)
    assert any(t == 0x30 and d.get("k") == "staff" and d.get("op") == "hire" for t, _, d in sent_h), "staff hire not sent"
    assert guest.globals().staffCount() == 1, f"guest staff not hired: {guest.globals().staffCount()}"
    assert not any(t == 0x30 and d.get("k") == "staff" for t, _, d in sent_g), f"guest echoed staff hire: {sent_g}"

    host.globals().triggerLocalStaffFire(staff_id)
    sent_h, sent_g = pump_wire(host, guest, rounds=15)
    assert any(t == 0x30 and d.get("k") == "staff" and d.get("op") == "fire" for t, _, d in sent_h), "staff fire not sent"
    assert guest.globals().staffCount() == 0, f"guest staff not fired: {guest.globals().staffCount()}"
    assert not any(t == 0x30 and d.get("k") == "staff" for t, _, d in sent_g), "guest echoed staff fire"

    # 3b. Research tier unlock (0x30 k="research") Host -> Guest + zero echo + invalid topic rejected
    host.globals().triggerLocalResearchUnlock("Vet_Lion", 2)
    sent_h, sent_g = pump_wire(host, guest, rounds=15)
    assert any(t == 0x30 and d.get("k") == "research" and d.get("topic") == "Vet_Lion" and d.get("tier") == 2 for t, _, d in sent_h), (
        f"research unlock not sent: {sent_h}"
    )
    assert guest.globals().state["researchTiers"]["Vet_Lion"] == 2, (
        f"guest research tier not synced: {guest.globals().state['researchTiers']['Vet_Lion']}"
    )
    assert not any(t == 0x30 and d.get("k") == "research" for t, _, d in sent_g), f"guest echoed research unlock: {sent_g}"
    guest.globals().deliverPacket(0x30, None, json.dumps({"k": "research", "topic": "../../evil", "tier": 5}))
    pump_wire(host, guest, rounds=5)
    assert guest.globals().state["researchTiers"]["../../evil"] is None, "malicious research topic was applied!"

    # 3c. Exhibit animal add (0x30 k="exhibit") Host -> Guest + zero echo + invalid species rejected
    host.globals().triggerLocalExhibitAdd(50, "BoaConstrictor")
    sent_h, sent_g = pump_wire(host, guest, rounds=15)
    assert any(t == 0x30 and d.get("k") == "exhibit" and d.get("op") == "add" and d.get("s") == "BoaConstrictor" for t, _, d in sent_h), (
        f"exhibit animal add not sent: {sent_h}"
    )
    g_ex_animals = lua_to_py(guest.globals().state["exhibits"][50]["animals"])
    assert any(a["species"] == "BoaConstrictor" for a in g_ex_animals), f"guest exhibit animal not added: {g_ex_animals}"
    assert not any(t == 0x30 and d.get("k") == "exhibit" for t, _, d in sent_g), f"guest echoed exhibit add: {sent_g}"
    guest.globals().deliverPacket(0x30, None, json.dumps({"k": "exhibit", "op": "add", "s": "../bad", "x": 4000, "y": 0, "z": 5000}))
    pump_wire(host, guest, rounds=5)
    assert len(lua_to_py(guest.globals().state["exhibits"][50]["animals"])) == 1, "malicious exhibit species was added!"

    # 3d. Emote & Held Prop (0x12 k="action") Host -> Guest + zero echo + trust boundary rejects unknown IDs
    guest.execute('local P = require("PZ2Coop.Presence"); local b = P.GetFriendBody(); if b and b.tAnim then b.tAnim.bAnimated = true end')
    assert host.globals().triggerLocalEmote("cheer") is True, "host failed to play cheer emote"
    assert host.globals().triggerLocalEmote("prop_umbrella") is True, "host failed to equip umbrella prop"
    sent_h, sent_g = pump_wire(host, guest, rounds=10)
    assert any(t == 0x12 and d.get("k") == "action" and d.get("op") == "emote" and d.get("id") == "cheer" for t, _, d in sent_h), (
        f"emote packet not sent: {sent_h}"
    )
    assert any(t == 0x12 and d.get("k") == "action" and d.get("op") == "prop" and d.get("id") == "prop_umbrella" for t, _, d in sent_h), (
        f"prop packet not sent: {sent_h}"
    )
    assert not any(t == 0x12 and d.get("k") == "action" for t, _, d in sent_g), f"guest echoed action packet: {sent_g}"
    g_calls_act = lua_to_py(guest.globals().calls)
    assert any(c["name"] == "QueueOneShot" and str(c["args"][1]).endswith("$StandReactCheer") for c in g_calls_act), (
        f"guest did not play remote cheer animation: {g_calls_act}"
    )
    assert any(
        c["name"] == "InstantiatePrefab" and isinstance(c["args"][0], dict)
        and c["args"][0].get("Children", {}).get("Prop", {}).get("Prefab") == "umbrella_blue"
        for c in g_calls_act
    ), f"guest did not spawn remote umbrella prop: {g_calls_act}"
    before_spawns = sum(1 for c in g_calls_act if c["name"] == "InstantiatePrefab")
    guest.globals().deliverPacket(0x12, None, json.dumps({"k": "action", "op": "prop", "id": "Peep_Avatar"}))
    pump_wire(host, guest, rounds=5)
    after_spawns = sum(1 for c in lua_to_py(guest.globals().calls) if c["name"] == "InstantiatePrefab")
    assert after_spawns == before_spawns, "malicious prop ID spawned a prefab!"

    # 3e. Mod-version mismatch warning (0x01 HANDSHAKE_HELLO) -> Red notification once (deduped)
    guest.globals().deliverPacket(0x01, None, json.dumps({"mode": "Sandbox", "ver": "9.9.9-bad"}))
    guest.globals().deliverPacket(0x01, None, json.dumps({"mode": "Sandbox", "ver": "9.9.9-bad"}))
    g_pop_mm = [p for p in lua_to_py(guest.globals().popouts) if "Mod version mismatch" in p["tEntry"]["sNotificationString"]]
    assert len(g_pop_mm) == 1 and g_pop_mm[0]["sColour"] == "Red", f"version mismatch warning missing or duplicated: {g_pop_mm}"

    # 4. Trust boundary: malicious packets from compromised guest are dropped by host
    host.globals().deliverPacket(0x12, None, json.dumps({"group": "TM", "items": {"Hats": {"prefab": "../../evil"}}}))
    host.globals().deliverPacket(0x30, None, json.dumps({"k": "staff", "op": "hire", "t": "Peep_Avatar", "x": 0, "y": 0, "z": 0}))
    pump_wire(host, guest, rounds=5)
    assert host.globals().staffCount() == 0, "malicious staff prefab was spawned!"

    # 5. Disconnect notification preserves partner name + clean reconnect re-handshakes & syncs cash
    host.globals().deliverEvent(py_to_lua(host, {"event": "peer_disconnected"}))
    guest.globals().deliverEvent(py_to_lua(guest, {"event": "peer_disconnected"}))
    h_pop2 = lua_to_py(host.globals().popouts)
    assert any("GuestPlayer left the co-op session" in p["tEntry"]["sNotificationString"] and p["sColour"] == "Red" for p in h_pop2), (
        f"host disconnect notify missing: {h_pop2}"
    )
    host.globals().state["cash"] = 54321.0
    host.globals().deliverEvent(py_to_lua(host, {"event": "status", "role": "host", "connected": True, "partner_name": "GuestPlayer", "partner_id": "222"}))
    guest.globals().deliverEvent(py_to_lua(guest, {"event": "status", "role": "client", "connected": True, "partner_name": "HostPlayer", "partner_id": "111"}))
    host.globals().deliverEvent(py_to_lua(host, {"event": "peer_connected"}))
    guest.globals().deliverEvent(py_to_lua(guest, {"event": "peer_connected"}))
    sent_h_re, _ = pump_wire(host, guest, rounds=15)
    assert any(t == 0x01 for t, _, _ in sent_h_re), "reconnect did not send fresh 0x01 handshake"
    assert any(t == 0x02 for t, _, _ in sent_h_re), "reconnect did not send fresh 0x02 baseline"
    assert abs(guest.globals().state["cash"] - 54321.0) < 0.05, f"cash not synced after reconnect: {guest.globals().state['cash']}"

    # 6. Franchise lockout (CLAUDE.md rule 6): park manager stays disabled even when already in a lobby
    franchise = make_peer("host", "TM", mode="Franchise")
    assert franchise.globals().Bridge.IsSyncedPark() is False, "Franchise park must not be synced"
    franchise.globals().deliverEvent(py_to_lua(franchise, {"event": "status", "role": "client", "connected": True, "partner_name": "Host", "partner_id": "111"}))
    franchise.globals().deliverEvent(py_to_lua(franchise, {"event": "peer_connected"}))
    franchise.globals().deliverPacket(0x11, None, json.dumps({"cash": 999999.0, "cc": 9999}))
    franchise.globals().deliverPacket(0x22, None, json.dumps({"k": "water", "op": "add", "x": 100, "y": 100, "z": 100}))
    franchise.globals().deliverPacket(0x30, None, json.dumps({"k": "staff", "op": "hire", "t": "Keeper", "x": 100, "y": 0, "z": 100}))
    franchise.globals().tick(20)
    assert len(list(franchise.globals().drainOutbox().values())) == 0, "Franchise park sent packets!"
    assert abs(franchise.globals().state["cash"] - 5000.0) < 0.01, "Franchise park cash was modified by remote packet!"
    assert franchise.globals().lakeCount() == 0, "Franchise park lake was created by remote packet!"
    assert franchise.globals().staffCount() == 0, "Franchise park staff was hired by remote packet!"

    # 7. ScenarioCareer & ScenarioChallenge co-op + guest autosave suppression + DLC block respect
    sc_host = make_peer("host", "TM", mode="ScenarioCareer", scenario="Scenario_01", diff="Hard", wild=True)
    sc_guest = make_peer("client", "AF", mode="Sandbox")
    assert sc_host.globals().Bridge.IsSyncedPark() is True, "ScenarioCareer park must be synced"
    sc_host.globals().deliverEvent(py_to_lua(sc_host, {"event": "status", "role": "host", "connected": True, "partner_name": "Guest", "partner_id": "222"}))
    sc_guest.globals().deliverEvent(py_to_lua(sc_guest, {"event": "status", "role": "client", "connected": True, "partner_name": "Host", "partner_id": "111"}))
    sc_host.globals().deliverEvent(py_to_lua(sc_host, {"event": "peer_connected"}))
    sc_guest.globals().deliverEvent(py_to_lua(sc_guest, {"event": "peer_connected"}))
    sent_sh, _ = pump_wire(sc_host, sc_guest, rounds=10)
    assert any(
        t == 0x01 and d.get("mode") == "ScenarioCareer" and d.get("scenario") == "Scenario_01"
        and d.get("diff") == "Hard" and d.get("wild") is True
        for t, _, d in sent_sh
    ), f"ScenarioCareer handshake metadata missing: {sent_sh}"
    sc_guest_calls = lua_to_py(sc_guest.globals().calls)
    assert any(c["name"] == "SetGameMode" and c["args"] == ["ScenarioCareer"] for c in sc_guest_calls), f"guest mode not set: {sc_guest_calls}"
    assert any(c["name"] == "SetScenarioCode" and c["args"] == ["Scenario_01"] for c in sc_guest_calls), f"guest scenario not set: {sc_guest_calls}"
    assert any(c["name"] == "SetGameDifficulty" and c["args"] == ["Hard"] for c in sc_guest_calls), f"guest diff not set: {sc_guest_calls}"
    assert any(c["name"] == "SetIsWildArea" and c["args"] == [True] for c in sc_guest_calls), f"guest wild not set: {sc_guest_calls}"
    assert sc_guest.globals().state["autosaveSuspended"] is True, "guest autosave must be suspended in ScenarioCareer"
    assert sc_host.globals().state["autosaveSuspended"] is False, "host autosave must NOT be suspended"

    sc_chall = make_peer("host", "TM", mode="ScenarioChallenge", scenario="Timed_01", diff="Default")
    assert sc_chall.globals().Bridge.IsSyncedPark() is True, "ScenarioChallenge park must be synced"

    dlc_blocked = make_peer("client", "AF", mode="ScenarioCareer", scenario="DLC_01", dlc_blocked=True)
    assert dlc_blocked.globals().Bridge.IsSyncedPark() is False, "DLC-blocked scenario must not be synced"

    # 8. Host leaves career world -> guest receives disconnect and automatically returns to start screen without saving
    sc_guest.globals().deliverEvent(py_to_lua(sc_guest, {"event": "peer_disconnected"}))
    sc_guest.globals().tick(25)  # > 2.0 s return-to-menu timer
    assert sc_guest.globals().state["returnedToStart"] == 1, (
        f"guest stayed stuck in host career world after host left: {sc_guest.globals().state['returnedToStart']}"
    )
    sc_g_calls = lua_to_py(sc_guest.globals().calls)
    assert any(c["name"] == "ReturnToStartScreen" and c["args"] == [True, False] for c in sc_g_calls), (
        f"guest return to start screen must suppress save: {sc_g_calls}"
    )

    print("ok: two-peer E2E (handshake+ver-mismatch, reconnect, scenarios, saveguard, host-exit kick, speed+ToD, resync, avatars+emotes+props 0x12, water 0x22, staff+research+exhibit 0x30, notifications, Franchise lockout)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
