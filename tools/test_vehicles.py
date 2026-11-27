"""Offline unit & integration tests for the 4-seat Research Vehicle system (src/ovl_mod/pz2coop.vehicles.lua).

Verifies:
  1) ComputeSeatOffsets: dynamic SeatDriver calibration (LHD & RHD) + VEH_Staff_Buggy.ovl fallback defaults.
  2) PickClosestSeat: closest-door selection across all 4 quadrants, occupied-seat fallback label, and full-cabin guard.
  3) NextAvailableSeat & SwapToSeat / SwapToNextSeat: 1->2->3->4->1 cycling, skipping occupied seats,
     Driver <-> Passenger SetPlayerControlled handoff, and 0.25 s cabin camera glide.
  4) ComputeExitCandidates: side-aware door ordering (own door -> opposite door -> rear tailgate).
  5) WalkingCameraUIMode._DriveVehicle closest-seat entry, PhotoUIMode seat preservation, & VehicleCamera 1P eye/glide/yaw.
  6) 3D bumper headlights (L) spawn/destroy + 0x12 sync, auto-open habitat gates (excluding aquarium doors),
     and Vehicle Recall (blocked when friend drives, near-player placement, and Return to Outpost).
  7) Trust-boundary validation on 0x13 VEHICLE_POSE_20HZ & 0x12 k="vehicle", remote pose interpolation,
     simultaneous seat-race resolution (client yields), OnPeerConnected/Disconnected, and HUD JSON state.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.Avatar": (ROOT / "src" / "ovl_mod" / "pz2coop.avatar.lua").read_text(encoding="utf-8"),
    "PZ2Coop.Presence": (ROOT / "src" / "ovl_mod" / "pz2coop.presence.lua").read_text(encoding="utf-8"),
    "PZ2Coop.Vehicles": (ROOT / "src" / "ovl_mod" / "pz2coop.vehicles.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, calls, packets = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end

local function makeVec(x, y, z)
  local v = {
    _x = x, _y = y, _z = z,
    GetX = function(self) return self._x end,
    GetY = function(self) return self._y end,
    GetZ = function(self) return self._z end,
    X = function(self) return self._x end,
    Y = function(self) return self._y end,
    Z = function(self) return self._z end,
    WithY = function(self, ny) return makeVec(self._x, ny, self._z) end,
    WithZ = function(self, nz) return makeVec(self._x, self._y, nz) end,
  }
  setmetatable(v, {
    __add = function(a, b) return makeVec(a._x + b._x, a._y + b._y, a._z + b._z) end,
    __sub = function(a, b) return makeVec(a._x - b._x, a._y - b._y, a._z - b._z) end,
    __mul = function(a, s) return makeVec(a._x * s, a._y * s, a._z * s) end,
  })
  return v
end

local function makeTransform(px, py, pz, yaw, pitch, roll)
  yaw = yaw or 0
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local rx, rz = cy, -sy
  local fx, fz = sy, cy
  return {
    GetPos = function() return makeVec(px, py, pz) end,
    Pos = function() return makeVec(px, py, pz) end,
    GetR = function() return makeVec(rx, 0, rz) end,
    GetU = function() return makeVec(0, 1, 0) end,
    GetF = function() return makeVec(fx, 0, fz) end,
    GetOr = function()
      return {ToYawPitchRoll = function() return makeVec(yaw, pitch or 0, roll or 0) end}
    end,
    ToWorldPos = function(_, v)
      local lx, ly, lz = v:GetX(), v:GetY(), v:GetZ()
      return makeVec(px + rx * lx + fx * lz, py + ly, pz + rz * lx + fz * lz)
    end,
    ToLocalPos = function(_, v)
      local dx, dy, dz = v:GetX() - px, v:GetY() - py, v:GetZ() - pz
      return makeVec(dx * rx + dz * rz, dy, dx * fx + dz * fz)
    end,
  }
end

local nextEntityId = 900
local uiMode = "WalkingCamera"
local role = "host"
local bLoopback = false
local bPeerConnected = true
local vehId = 700
local seatDriverId = 701
local fpCamId = 705
local headLightsGroupId = 702
local headLightLeftId = 703
local headLightRightId = 704
local driverAvatarId = 777
local driverHeadId = 778
local driverHairId = 779
local driverHatId = 780
local bDriverAvatarExists = true
local gateNormalId = 801
local gateAquariumId = 802
local vehPose = {x = 100.0, y = 0.0, z = 100.0, yaw = 0.0, pitch = 0.0, roll = 0.0}
local vehSpeed = 0.0
local vehSteer = 0.0
local playerPos = {100.0, 0.0, 100.0}
local playerYaw = 0.0
local entityTransforms = {}
local fpiEntities = {
  [700] = {sType = "Vehicle", nParentEntityID = 700},
}

local function refreshTransforms()
  entityTransforms[vehId] = makeTransform(vehPose.x, vehPose.y, vehPose.z, vehPose.yaw, vehPose.pitch, vehPose.roll)
  entityTransforms[seatDriverId] = makeTransform(vehPose.x - 0.42, vehPose.y + 0.54, vehPose.z + 0.12, vehPose.yaw, 0, 0)
  entityTransforms[fpCamId] = makeTransform(vehPose.x - 0.42, vehPose.y + 1.56, vehPose.z + 0.20, vehPose.yaw, 0, 0)
end
refreshTransforms()

local promptData = {
  Empty = {
    WalkingCamera = {tMouse = {}, tGamepad = {}},
    DriveVehicle = {tMouse = {{sLogicalControl = "Vehicle_ExitVehicle"}}, tGamepad = {{sLogicalControl = "Vehicle_ExitVehicle"}}},
  },
}

local activeCamMode = "Walking"
local modelHideRefCount = {}

local tWorldAPIs = {
  ModeHelperComponent = {GetCurrentModeName = function() return uiMode end},
  FirstPersonInteraction = {tEntities = fpiEntities},
  transform = {
    HasTransform = function(_, id) return entityTransforms[id] ~= nil end,
    CalculateWorldTransform = function(_, id) return entityTransforms[id] end,
    SetTransform = function(_, id, tr)
      call("SetTransform", id, tr)
      if id == vehId and tr and tr.v then
        vehPose.x, vehPose.y, vehPose.z = tr.v:GetX(), tr.v:GetY(), tr.v:GetZ()
        if tr.q and tr.q.GetX then
          vehPose.yaw, vehPose.pitch, vehPose.roll = tr.q:GetX(), tr.q:GetY(), tr.q:GetZ()
        end
        refreshTransforms()
      end
    end,
    SetPosition = function() end,
  },
  vehicles = {
    SetPlayerControlled = function(_, id, b) call("SetPlayerControlled", id, b) end,
    SetVehicleOccupiedByPlayer = function(_, id, b) call("SetVehicleOccupiedByPlayer", id, b) end,
    TeleportVehicleToSpawnPoint = function(_, id)
      call("TeleportVehicleToSpawnPoint", id)
      vehPose.x, vehPose.y, vehPose.z = 50.0, 0.0, 50.0
      refreshTransforms()
    end,
    GetVehicleSpeed = function() return vehSpeed end,
    GetSteeringWheel = function() return vehSteer end,
    GetVehicleFromSpawnPoint = function() return vehId end,
  },
  model = {
    SetHidden = function(_, id, b)
      modelHideRefCount[id] = (modelHideRefCount[id] or 0) + (b and 1 or -1)
      call("ModelSetHidden", id, b)
    end,
  },
  motiongraph = {
    SetVariable = function(_, id, k, v) call("MotionGraphSetVar", id, k, v) end,
  },
  attractions = {
    RequestHabitatGateOpen = function(_, id) call("RequestHabitatGateOpen", id) end,
    ReleaseHabitatGateOpenRequest = function(_, id) call("ReleaseHabitatGateOpenRequest", id) end,
  },
  gameaudio = {
    UpdateCameraPerspective = function(_, name, id) call("UpdateCameraPerspective", name, id) end,
    CameraTorchToggle = function(_, bOn) call("CameraTorchToggle", bOn) end,
  },
  CameraModeManager = {
    GetCurrentModeName = function() return activeCamMode end,
    GetPosYPRZoom = function() return makeVec(playerPos[1], playerPos[2] + 1.55, playerPos[3]), makeVec(playerYaw, 0, 0), 1 end,
    GetVoxelTerrainID = function() return 1 end,
    RequestMode = function(_, mode, t)
      activeCamMode = mode
      call("CameraRequestMode", mode, t)
    end,
  },
  placement = {
    GetPartResourceName = function(_, id)
      if id == gateAquariumId then return "AquariumEntrance_01" end
      return "Habitat_Gate_01"
    end,
  },
  billboardwidgets = {WidgetType_WidgetLabel = 7},
}

local toastQueue = {}
api = {
  world = {
    GetWorldAPIs = function() return tWorldAPIs end,
    GetActive = function() return 1 end,
    GetScript = function()
      return {
        tEnvironment = {
          RequestInterface = function(_, iface)
            if iface == "Interfaces.INotificationManager" then
              return {tTimelinePopOutQueue = toastQueue}
            end
            return nil
          end,
          RequireInterface = function()
            return {
              SetBillboardWidgetUIInfo = function() end,
              SetBillboardWidgetData = function() end,
              ClearBillboardWidgetData = function() end,
            }
          end,
        },
        GetHUD = function() return {ShowHelperTooltip = function() end, HideHelperTooltip = function() end} end,
      }
    end,
  },
  entity = {
    CreateRequestCompletionToken = function() return {} end,
    HaveRequestsCompleted = function() return true end,
    FindEntityByName = function(name, parent)
      if name == "SeatDriver" and parent == vehId then return seatDriverId end
      if name == "FirstPersonCamera" and parent == vehId then return fpCamId end
      if name == "HeadLights" and parent == vehId then return headLightsGroupId end
      if name == "Headlight_Left" and parent == headLightsGroupId then return headLightLeftId end
      if name == "Headlight_Right" and parent == headLightsGroupId then return headLightRightId end
      if name == "Avatar" and parent == seatDriverId then return bDriverAvatarExists and driverAvatarId or nil end
      if name == "Head" and parent == driverAvatarId then return driverHeadId end
      if name == "Hair" and parent == driverAvatarId then return driverHairId end
      if name == "Hat" and parent == driverHeadId then return driverHatId end
      return nil
    end,
    InstantiatePrefab = function(prefab, name, tok, tr, parent, b, props)
      nextEntityId = nextEntityId + 1
      call("InstantiatePrefab", prefab, name, parent, props)
      return nextEntityId
    end,
    DestroyEntity = function(id) call("DestroyEntity", id) end,
  },
  lighting = {
    SetEnable = function(id, bOn) call("LightingSetEnable", id, bOn) end,
    ClaimDisableLight = function(id) call("LightingClaimDisable", id) end,
    ReleaseDisableLight = function(id) call("LightingReleaseDisable", id) end,
  },
  audio = {
    SendGUIEvent = function(ev) call("Audio", ev) end,
  },
  player = {
    GetGameOwner = function() return 1 end,
  },
  json = {
    GetArrayMetatable = function() return {} end,
    Stringify = function() return true, "{}" end,
    Parse = function() return true, {} end,
  },
  time = {GetTotalTimeUnscaled = function() return 1 end},
}

local Bridge = {
  Log = function(s) table.insert(log, s) end,
  GetRole = function() return role end,
  IsPeerConnected = function() return bPeerConnected end,
  IsLoopback = function() return bLoopback end,
  GetSession = function() return {sSelf = "Alex", sPartner = "Sam", sPartnerId = "99"} end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}

local BaseUIMode = {
  GetModeHelperEntity = function() return 1 end,
  SetNewMode = function(name, params)
    call("SetNewMode", name, params)
    uiMode = name
  end,
}

local DriveVehicleUIMode = {
  TransitionIn = function(self, params)
    self.nVehicle = params.nVehicle
    self.nAvatar = 777
    self.bThirdPersonCamera = params.bThirdPersonCamera == true
    self.vehiclesAPI = tWorldAPIs.vehicles
    self.modelAPI = tWorldAPIs.model
    self.transformAPI = tWorldAPIs.transform
    self.cameraModeManager = tWorldAPIs.CameraModeManager
    self.inputManager = {
      CreateGamepadTemporaryContext = function(_, ctx) call("CreatePadCtx", ctx) end,
      RemoveGamepadTemporaryContext = function(_, ctx) call("RemovePadCtx", ctx) end,
    }
    call("OrigDriveTransitionIn", params)
  end,
  TransitionOut = function(self) call("OrigDriveTransitionOut") end,
  Advance = function(self) end,
  Run = function(self) end,
  SwitchCamera = function(self, bThird)
    self.bThirdPersonCamera = bThird
    call("OrigDriveSwitchCamera", bThird)
  end,
}

local VehicleCamera = {
  Advance = function(tData) call("OrigVehicleCameraAdvance", tData) end,
  StabilizeBaseTransform = function(tData) call("StabilizeBaseTransform", tData) end,
}

local PhotoUIMode = {
  Init = function(self, entityID, tParams)
    self.nVehicle = tParams and tParams.nVehicle or nil
    self.bThirdPersonCamera = tParams and tParams.bThirdPersonCamera or false
  end,
  ExitMode = function(self) call("OrigPhotoExitMode") end,
}

local WalkingCameraUIMode = {
  _DriveVehicle = function(self, nEntityID) call("OrigWalkDriveVehicle", nEntityID) end,
}

local CameraLogic = {
  ApplyFinal = function(tData) call("CameraApplyFinal", tData) end,
}

local CameraUtils = {
  FocusRaycast = function(_, _, origin) return makeVec(origin:GetX(), 0.25, origin:GetZ()) end,
}

local StartScreenAvatarStub = {
  AvatarVersionCheck = function(d) return d end,
  new = function(self)
    local o = {}
    setmetatable(o, {__index = self})
    return o
  end,
  Create = function(self, tAvatar, nParent, sRole, sState)
    call("StartScreenAvatarCreate", nParent, sRole, sState)
    coroutine.yield() -- simulate async asset loading yield (must NEVER fail across pcall!)
    bDriverAvatarExists = true
    self.nAnimatedEntityID = driverAvatarId
  end,
}

local stubs = {
  Vector3 = {new = function(_, x, y, z) return makeVec(x, y, z) end},
  TransformQ = {
    Identity = {WithPos = function(_, v) return {v = v} end},
    FromOrPos = function(q, v) return {q = q, v = v} end,
  },
  Quaternion = {Identity = {}, FromYawPitchRoll = function(v) return v end},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Shared.BaseUIMode"] = BaseUIMode,
  ["Editors.Vehicle.DriveVehicleUIMode"] = DriveVehicleUIMode,
  ["Components.Cameras.VehicleCamera"] = VehicleCamera,
  ["Components.Cameras.CameraLogic"] = CameraLogic,
  ["Components.Cameras.CameraUtils"] = CameraUtils,
  ["Components.Cameras.WalkingCamera"] = {
    GetDefaultWalkingHeight = function() return 1.55 end,
    Init = function(tData, _, tInit)
      -- Simulate vanilla WalkingCamera.Init setting vDispHint from trailing 3P vehicle cam to door exit pos
      tData.tDelta.vDispHint = tInit.vStartingPos - tData.tFinal.vCameraPos
    end,
    Advance = function() end,
  },
  ["Editors.Cameras.PhotoUIMode"] = PhotoUIMode,
  ["Editors.Cameras.WalkingCameraUIMode"] = WalkingCameraUIMode,
  ["StartScreen.Shared.StartScreenAvatar"] = StartScreenAvatarStub,
  ["Database.GameDatabase"] = {
    GetButtonPromptData = function(k) return promptData[k] end,
    GetPlayerKey = function() return 1 end,
    GetPlayer = function() return {GetMainAvatarData = function() return {tData = {group = "TMA", parts = {}}} end} end,
  },
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

local Presence = require("PZ2Coop.Presence")
local Vehicles = require("PZ2Coop.Vehicles")
"""

CHECKS = r"""
local function findCalls(name)
  local out = {}
  for _, c in ipairs(calls) do
    if c.name == name then table.insert(out, c) end
  end
  return out
end
local function lastCall(name)
  local list = findCalls(name)
  return list[#list]
end
local function approx(a, b, eps) return math.abs((a or 0) - (b or 0)) <= (eps or 0.005) end

-- 1) ComputeSeatOffsets: LHD calibration, RHD calibration, and fallback defaults
local defOff = Vehicles.ComputeSeatOffsets(nil)
assert(approx(defOff[1].seat.x, -0.40) and approx(defOff[2].seat.x, 0.40), "default front seats must mirror around X=0")
assert(approx(defOff[3].seat.x, -0.40) and approx(defOff[4].seat.x, 0.40), "default rear seats must mirror around X=0")
assert(defOff[3].seat.z < defOff[1].seat.z and defOff[4].seat.z < defOff[2].seat.z, "rear row must sit behind front row")
assert(defOff[1].sideSign == -1 and defOff[2].sideSign == 1, "LHD sideSign mismatch")

local rhdOff = Vehicles.ComputeSeatOffsets({x = 0.42, y = 0.55, z = 0.14})
assert(approx(rhdOff[1].seat.x, 0.42) and approx(rhdOff[2].seat.x, -0.42), "RHD driver must mirror front passenger")
assert(rhdOff[1].sideSign == 1 and rhdOff[2].sideSign == -1, "RHD sideSign mismatch")

local badOff = Vehicles.ComputeSeatOffsets({x = 9.0, y = -3.0, z = 5.0})
assert(approx(badOff[1].seat.x, -0.40) and approx(badOff[1].seat.y, 0.56), "out-of-bounds SeatDriver must fall back to defaults")

-- 2) PickClosestSeat across all 4 quadrants + occupied fallback + full vehicle
local doors = {
  [1] = {x = 99.08, y = 1.21, z = 100.10},  -- Driver (front-left)
  [2] = {x = 100.92, y = 1.21, z = 100.10}, -- Front Passenger (front-right)
  [3] = {x = 99.08, y = 1.24, z = 99.26},   -- Back Left
  [4] = {x = 100.92, y = 1.24, z = 99.26},  -- Back Right
}
local p1 = Vehicles.PickClosestSeat(doors, 98.5, 0.0, 100.2, {}, "local")
assert(p1 and p1.nSeat == 1 and p1.sLabel == "Drive" and not p1.bFull, "front-left should pick Driver")
local p2 = Vehicles.PickClosestSeat(doors, 101.5, 0.0, 100.2, {}, "local")
assert(p2 and p2.nSeat == 2 and p2.sLabel == "Sit - Front Passenger", "front-right should pick Front Passenger")
local p3 = Vehicles.PickClosestSeat(doors, 98.5, 0.0, 99.0, {}, "local")
assert(p3 and p3.nSeat == 3 and p3.sLabel == "Sit - Back Left", "rear-left should pick Back Left")
local p4 = Vehicles.PickClosestSeat(doors, 101.5, 0.0, 99.0, {}, "local")
assert(p4 and p4.nSeat == 4 and p4.sLabel == "Sit - Back Right", "rear-right should pick Back Right")

-- Occupied closest seat falls back to nearest free seat and annotates label
local occDriver = {[1] = {peer = "friend", name = "Sam"}}
local pOcc = Vehicles.PickClosestSeat(doors, 98.5, 0.0, 100.2, occDriver, "local")
assert(pOcc and pOcc.nSeat == 3 and pOcc.nClosestSeat == 1 and string.find(pOcc.sLabel, "Driver Occupied", 1, true),
  "occupied Driver should fall back to Back Left with occupied hint, got " .. tostring(pOcc and pOcc.sLabel))

-- All 4 seats full
local occAll = {
  [1] = {peer = "p1", name = "A"}, [2] = {peer = "p2", name = "B"},
  [3] = {peer = "p3", name = "C"}, [4] = {peer = "p4", name = "D"},
}
local pFull = Vehicles.PickClosestSeat(doors, 98.5, 0.0, 100.2, occAll, "local")
assert(pFull and pFull.bFull == true and pFull.nSeat == nil and pFull.sLabel == "Vehicle Full", "full cabin mismatch")

-- Out of range returns nil
assert(Vehicles.PickClosestSeat(doors, 120.0, 0.0, 120.0, {}, "local") == nil, "far player must return nil")

-- 3) NextAvailableSeat cycling & skipping
assert(Vehicles.NextAvailableSeat(1, {}, "local") == 2)
assert(Vehicles.NextAvailableSeat(2, {}, "local") == 3)
assert(Vehicles.NextAvailableSeat(3, {}, "local") == 4)
assert(Vehicles.NextAvailableSeat(4, {}, "local") == 1)
assert(Vehicles.NextAvailableSeat(1, {[2] = {peer = "friend", name = "Sam"}}, "local") == 3, "must skip friend seat 2")
assert(Vehicles.NextAvailableSeat(1, {[2] = {peer = "f1"}, [3] = {peer = "f2"}, [4] = {peer = "f3"}}, "local") == nil, "all other seats full")

-- 4) ComputeExitCandidates side-aware ordering
local trZero = makeTransform(100, 0, 100, 0, 0, 0)
local exitsL = Vehicles.ComputeExitCandidates(1, defOff, trZero)
assert(#exitsL == 3 and exitsL[1].name == "own_door" and exitsL[1].x < 100, "left seat exits left first")
assert(exitsL[2].name == "opposite_door" and exitsL[2].x > 100, "left seat falls back to right door")
assert(exitsL[3].name == "rear_tailgate" and exitsL[3].z < 100, "left seat falls back to rear tailgate")
local exitsR = Vehicles.ComputeExitCandidates(2, defOff, trZero)
assert(exitsR[1].name == "own_door" and exitsR[1].x > 100, "right seat exits right first")
assert(exitsR[2].name == "opposite_door" and exitsR[2].x < 100, "right seat falls back to left door")

-- 5) Install & verify prompts (unbracketed STRING_LITERAL, Q-only GameCamera_Down) + closest-seat entry into Seat 2
Vehicles.Install()
Vehicles.Update(0.05, true)
local swapPrompt, lightsPrompt = nil, nil
for _, e in ipairs(promptData.Empty.DriveVehicle.tMouse) do
  if e.sLogicalControl == "GameCamera_Down" then swapPrompt = e end
  if e.sLogicalControl == "GameCamera_Torch" then lightsPrompt = e end
  assert(e.sLogicalControl ~= "GameCamera_Crouch", "Swap Seat must NOT use GameCamera_Crouch (bound to Ctrl)")
end
assert(swapPrompt and lightsPrompt, "DriveVehicle prompt bar must include Swap Seat (Q = GameCamera_Down) and Headlights (L)")
assert(swapPrompt.sLocString == "STRING_LITERAL:Value=|Swap Seat|",
  "Swap Seat prompt must omit outer brackets (ButtonPromptBar wraps in [...]), got " .. tostring(swapPrompt.sLocString))
assert(lightsPrompt.sLocString == "STRING_LITERAL:Value=|Headlights|",
  "Headlights prompt must omit outer brackets (ButtonPromptBar wraps in [...]), got " .. tostring(lightsPrompt.sLocString))
assert(Vehicles.GetHUDState == nil, "Custom VehicleHUD state publisher must be removed")

-- Verify passenger seat Y & Z calibration from real VEH_Staff_Buggy FirstPersonCamera + live TM sit neck
-- (matches Frontier's def_seatAttach01..04_joint at Z=-0.130 / -0.884, well clear of front backrest & rear bulkhead -1.163!)
local calOff = Vehicles.ComputeSeatOffsets({x = 0.250, y = 0.000, z = 0.000}, {x = 0.289, y = 1.586, z = -0.143}, {y = 0.506, z = 0.032})
assert(approx(calOff[2].eye.y, 1.586) and approx(calOff[2].seat.y, 0.920, 0.01),
  "passenger seat Y must align neck (eye - 0.16 - neckY) cleanly onto cushion, got " .. tostring(calOff[2].seat.y))
assert(approx(calOff[2].seat.z, -0.085, 0.01),
  "front passenger Z must sit forward off chair backrest near def_seatAttach02 (-0.085), got " .. tostring(calOff[2].seat.z))
assert(approx(calOff[3].seat.z, -0.839, 0.01) and approx(calOff[4].seat.z, -0.839, 0.01),
  "rear passenger Z must sit forward on rear seats near def_seatAttach03/04 (-0.839, clear of rear wall -1.163), got " .. tostring(calOff[3].seat.z))
assert(approx(calOff[3].seat.y, calOff[2].seat.y, 0.005),
  "rear row height must match front row (def_seatAttach Y=1.073 for all 4 seats)")
assert(calOff[2].eye.z > calOff[2].seat.z + 0.032 + 0.05 and calOff[3].eye.z > calOff[3].seat.z + 0.032 + 0.05,
  "1P passenger eyes must sit cleanly forward of live neck collar in both front and rear seats")

-- Hover front-right door and press E via WalkingCameraUIMode._DriveVehicle
local hovered = Vehicles.FindClosestSeatPrompt(vehId, 101.4, 0.0, 100.1)
assert(hovered and hovered.nSeat == 2 and hovered.nVehicle == vehId, "hovered seat must be Front Passenger (2)")
calls, packets = {}, {}
WalkingCameraUIMode._DriveVehicle({}, vehId)
local setMode = lastCall("SetNewMode")
assert(setMode and setMode.args[1] == "DriveVehicle" and setMode.args[2].nSeat == 2, "entry must pass nSeat=2")

-- Enter DriveVehicleUIMode in seat 2 (verify bFreeYaw == false & vehicle-parented zero-twitch local coords!)
local driveSelf = {}
calls, packets = {}, {}
DriveVehicleUIMode.TransitionIn(driveSelf, {nVehicle = vehId, nSeat = 2, bThirdPersonCamera = true})
assert(Vehicles.GetLocalSeat() == 2 and Vehicles.IsLocalPassenger() == true, "local player must be in seat 2")
local ctrlCall = lastCall("SetPlayerControlled")
assert(ctrlCall and ctrlCall.args[2] == false, "passenger must NOT hold driver control")
local camReq = lastCall("CameraRequestMode")
assert(camReq and camReq.args[1] == "ThirdPersonVehicle" and camReq.args[2].bFreeYaw == false,
  "passenger 3P camera MUST set bFreeYaw=false (prevents inverted endless spin)")
local hideCall = lastCall("ModelSetHidden")
assert(hideCall and hideCall.args[1] == driverAvatarId and hideCall.args[2] == true, "vanilla SeatDriver avatar must be hidden for passenger")
local pState = rawget(_G, "__PZ2CoopPresenceState")
assert(pState.tVehicleOwnOverride ~= nil and pState.tVehicleOwnOverride.seat == 2 and pState.tVehicleOwnOverride.clip == "$OnRideSitIdle",
  "own passenger avatar override must use $OnRideSitIdle (all 4 avatar groups AF/AM/TF/TM)")
assert(pState.tVehicleOwnOverride.nVehicle == vehId and type(pState.tVehicleOwnOverride.lx) == "number",
  "own passenger override must pass nVehicle + local (lx,ly,lz) for direct C++ vehicle parenting (zero twitch)")
assert(pState.tVehicleOwnOverride.bHidden == false and pState.tVehicleOwnOverride.bHeadHidden == false,
  "3P passenger body & head must both be visible")
assert(#packets == 1 and packets[1].n == 0x12 and packets[1].d.k == "vehicle" and packets[1].d.op == "seat" and packets[1].d.seat == 2)

-- Switch passenger to 1P: body MUST stay visible (bHidden=false) with ONLY head hidden (bHeadHidden=true)!
DriveVehicleUIMode.SwitchCamera(driveSelf, false)
assert(pState.tVehicleOwnOverride.bHidden == false and pState.tVehicleOwnOverride.bHeadHidden == true,
  "1P passenger must keep body visible and hide ONLY head")

-- Verify Avatar.SetHeadHidden & SetHidden are ref-count-safe and keep nHeadRig hidden in 1P
local Avatar = require("PZ2Coop.Avatar")
local mockAnim = {nHeadRig = 9101, tHeadParts = {9102}}
calls = {}
Avatar.SetHeadHidden(mockAnim, 9100, true)
Avatar.SetHeadHidden(mockAnim, 9100, true) -- duplicate must be ignored (no ref-count leak!)
assert(mockAnim.bHeadHidden == true)
assert((modelHideRefCount[9101] or 0) == 1 and (modelHideRefCount[9100] or 0) == 0,
  "Avatar.SetHeadHidden(true) must hide ONLY nHeadRig once and never root body 9100")
Avatar.SetHidden(mockAnim, 9100, true)
assert((modelHideRefCount[9100] or 0) == 1 and (modelHideRefCount[9101] or 0) == 1,
  "Avatar.SetHidden(true) must hide root once without double-hiding already-hidden nHeadRig")
Avatar.SetHidden(mockAnim, 9100, false)
assert((modelHideRefCount[9100] or 0) == 0 and (modelHideRefCount[9101] or 0) == 1,
  "Avatar.SetHidden(false) must unhide root body (0) while keeping nHeadRig hidden (1) in 1P")
Avatar.SetHeadHidden(mockAnim, 9100, false)
assert((modelHideRefCount[9100] or 0) == 0 and (modelHideRefCount[9101] or 0) == 0,
  "Avatar.SetHeadHidden(false) must restore nHeadRig ref-count to 0")

-- Switch back to 3P & swap seats: 2 -> 3 -> 4 -> 1 (Driver handoff + 0.25s glide + ref-counted unhide + NO camera reset!)
DriveVehicleUIMode.SwitchCamera(driveSelf, true)
assert(activeCamMode == "ThirdPersonVehicle")
calls, packets = {}, {}
assert(Vehicles.SwapToNextSeat() == true and Vehicles.GetLocalSeat() == 3)
assert(Vehicles.GetState().tCamGlide ~= nil, "seat swap must start 0.25 s cabin camera glide")
assert(#findCalls("CameraRequestMode") == 0, "swapping seats 2 -> 3 in 3P must NOT reset camera via RequestMode")
assert(Vehicles.SwapToNextSeat() == true and Vehicles.GetLocalSeat() == 4)
assert(#findCalls("CameraRequestMode") == 0, "swapping seats 3 -> 4 in 3P must NOT reset camera via RequestMode")
assert((modelHideRefCount[driverAvatarId] or 0) == 1,
  "repeated passenger seat swaps must NEVER double-increment ref-counted hide count, got " .. tostring(modelHideRefCount[driverAvatarId]))
calls = {}
assert(Vehicles.SwapToNextSeat() == true and Vehicles.GetLocalSeat() == 1 and Vehicles.IsLocalPassenger() == false)
assert(#findCalls("CameraRequestMode") == 0, "swapping seats 4 -> 1 in 3P must NOT reset camera via RequestMode")
ctrlCall = lastCall("SetPlayerControlled")
assert(ctrlCall and ctrlCall.args[2] == true, "swapping into seat 1 must grant driver control")
assert((modelHideRefCount[driverAvatarId] or 0) == 0,
  "swapping back into Driver seat in 3P must return ref-counted hide count to 0 (visible), got " .. tostring(modelHideRefCount[driverAvatarId]))
assert(pState.tVehicleOwnOverride == nil, "driver uses vanilla SeatDriver avatar, clearing own passenger override")

-- Verify passenger PZ2CoopOwnBody actually spawns PARENTED to vehId (NOT parent=nil at world origin!)
assert(Vehicles.SwapToSeat(2) == true)
calls = {}
Presence.Update(0.05, true)
local ownSpawn = nil
for _, c in ipairs(findCalls("InstantiatePrefab")) do
  if c.args[2] == "PZ2CoopOwnBody" then ownSpawn = c end
end
assert(ownSpawn ~= nil and ownSpawn.args[3] == vehId,
  "PZ2CoopOwnBody MUST be parented to vehId (arg #5 of InstantiatePrefab), got parent=" .. tostring(ownSpawn and ownSpawn.args[3]))
assert(Vehicles.SwapToSeat(1) == true)
Presence.Update(0.05, true)

-- Driver 1P: body (777) MUST stay visible (ref-count 0) while ONLY Head/Hair/Hat are hidden (ref-count 1), and steering animates!
calls = {}
DriveVehicleUIMode.SwitchCamera(driveSelf, false)
assert((modelHideRefCount[driverAvatarId] or 0) == 0 and
  (modelHideRefCount[driverHeadId] or 0) == 1 and
  (modelHideRefCount[driverHatId] or 0) == 1,
  "1P Driver must keep torso/legs visible (777 count=0) and hide Head & Hat only (count=1)")
vehSteer = -0.6
driveSelf.motiongraphAPI = tWorldAPIs.motiongraph
calls = {}
DriveVehicleUIMode.Advance(driveSelf, 0.016, 0.016)
local bSteerLeftSet = false
for _, c in ipairs(findCalls("MotionGraphSetVar")) do
  if c.args[1] == driverAvatarId and c.args[2] == "steerLeft" and approx(c.args[3], 0.6) then bSteerLeftSet = true end
end
assert(bSteerLeftSet, "1P Driver must still animate steering wheel arms")
vehSteer = 0.0
DriveVehicleUIMode.SwitchCamera(driveSelf, true)

-- Test BeginVehicleExit pre-builds walking avatar at door, adopts it seamlessly on the exact frame camera switches (zero pop-in!),
-- and WalkingCamera.Init snaps instantly outside door (zero slide from behind vehicle!)
Presence.Install()
Presence.SetThirdPerson(true)
local WalkingCamera = require("Components.Cameras.WalkingCamera")
local vExitPos = makeVec(98.55, 1.55, 100.10)
local vExitYpr = makeVec(0.0, 0.0, 0.0)
local bExitCallbackFired = false
calls = {}
Presence.BeginVehicleExit(vExitPos, vExitYpr, function()
  bExitCallbackFired = true
end)
assert(not bExitCallbackFired, "BeginVehicleExit in 3P must pre-build exit avatar before switching camera")
-- Make the spawned PZ2CoopExitBody transform ready & step Presence.Update so StartScreenAvatar fallback completes
local exitSpawn = lastCall("InstantiatePrefab")
assert(exitSpawn and exitSpawn.args[2] == "PZ2CoopExitBody", "must spawn PZ2CoopExitBody at exit spot")
entityTransforms[nextEntityId] = makeTransform(98.55, 0.0, 100.10, 0, 0, 0)
Presence.Update(0.05, true)
Presence.Update(0.05, true)
assert(bExitCallbackFired == true, "BeginVehicleExit must invoke camera switch callback the exact frame exit avatar is ready")
local adoptedBody = Presence.GetOwnBody()
assert(adoptedBody ~= nil and adoptedBody.nAvatar ~= nil and adoptedBody.nVehicleParent == nil,
  "BeginVehicleExit must seamlessly adopt pre-built exit avatar as s.tOwnBody (zero pop-in)")
-- Verify UpdateOwnBody preserves adopted body across the 1-frame mode transition before WalkingCamera activates
Presence.Update(0.05, true)
assert(Presence.GetOwnBody() == adoptedBody, "adopted exit body must survive the 1-frame DriveVehicle -> WalkingCamera switch")
local walkCamData = {
  tFinal = {vCameraPos = makeVec(100.0, 2.5, 94.5), vCameraYPR = makeVec(0.3, 0.2, 0)},
  tDelta = {vDispHint = makeVec(0, 0, 0), vDisplace = makeVec(0, 0, 0), vYPRCamera = makeVec(0, 0, 0)},
}
WalkingCamera.Init(walkCamData, tWorldAPIs, {vStartingPos = vExitPos, vStartingYPR = vExitYpr})
assert(approx(walkCamData.tFinal.vCameraPos:GetX(), 98.55) and approx(walkCamData.tFinal.vCameraPos:GetZ(), 100.10),
  "BeginVehicleExit must snap vCameraPos directly onto door exit position")
assert(approx(walkCamData.tDelta.vDispHint:GetX(), 0) and approx(walkCamData.tDelta.vDispHint:GetZ(), 0),
  "BeginVehicleExit must zero vDispHint so player never slides from behind vehicle")

-- Test entering Seat 3 FIRST when SeatDriver/Avatar does NOT exist yet, then swapping 3 -> 1 asynchronously!
DriveVehicleUIMode.TransitionOut(driveSelf)
bDriverAvatarExists = false
local freshSelf = {}
calls = {}
DriveVehicleUIMode.TransitionIn(freshSelf, {nVehicle = vehId, nSeat = 3, bThirdPersonCamera = true})
freshSelf.nAvatar = nil -- vanilla did not build SeatDriver avatar because we entered as passenger
assert(Vehicles.GetLocalSeat() == 3)
assert(Vehicles.SwapToSeat(1) == true and Vehicles.GetLocalSeat() == 1)
-- Step 2 frames so yielding StartScreenAvatar:Create coroutine completes cleanly with ZERO yield-across-pcall crash!
DriveVehicleUIMode.Advance(freshSelf, 0.016, 0.016)
DriveVehicleUIMode.Advance(freshSelf, 0.016, 0.016)
assert(freshSelf.nAvatar == driverAvatarId and bDriverAvatarExists == true,
  "swapping passenger -> driver when SeatDriver/Avatar was never built must async-create & show driver avatar")
driveSelf = freshSelf

-- Verify holding Q (GameCamera_Down) swaps ONLY ONCE, and Ctrl (GameCamera_Crouch / Car_Horn) NEVER swaps seats!
local keysHeld = {}
driveSelf.mainHUD = {GetFullScreenUIPause = function() return false end}
driveSelf.HandleBackButton = function() end
driveSelf.inputManager = {
  GetKeyPressed = function(_, k) return keysHeld[k] == true end,
  GetKeyDown = function(_, k) return keysHeld[k] == true end,
  GetGamepadButtonDown = function() return false end,
}
local coRun = coroutine.create(function() DriveVehicleUIMode.Run(driveSelf) end)
Vehicles.Update(0.5, true)
-- Press Ctrl (GameCamera_Crouch + Car_Horn) -> MUST NOT swap seat!
keysHeld["GameCamera_Crouch"] = true
keysHeld["Car_Horn"] = true
for _ = 1, 3 do
  Vehicles.Update(0.05, true)
  assert(coroutine.resume(coRun))
end
assert(Vehicles.GetLocalSeat() == 1, "pressing Ctrl (GameCamera_Crouch / Car_Horn) must NEVER swap seats")
keysHeld["GameCamera_Crouch"] = false
keysHeld["Car_Horn"] = false
assert(coroutine.resume(coRun))

-- Hold Q (GameCamera_Down) across 5 frames -> swaps ONLY ONCE (1 -> 2)
keysHeld["GameCamera_Down"] = true
for _ = 1, 5 do
  Vehicles.Update(0.05, true)
  assert(coroutine.resume(coRun))
end
assert(Vehicles.GetLocalSeat() == 2,
  "holding Q across 5 frames must swap ONLY ONCE (1 -> 2), got seat " .. tostring(Vehicles.GetLocalSeat()))
-- Release Q for one frame, wait cooldown, then press Q again -> swaps once (2 -> 3)
keysHeld["GameCamera_Down"] = false
Vehicles.Update(0.35, true)
assert(coroutine.resume(coRun))
keysHeld["GameCamera_Down"] = true
Vehicles.Update(0.05, true)
assert(coroutine.resume(coRun))
assert(Vehicles.GetLocalSeat() == 3, "releasing and re-pressing Q after cooldown must swap once (2 -> 3)")
-- While passenger in seat 3, pressing Ctrl (GameCamera_Crouch / Car_Horn) MUST NOT swap seats!
keysHeld["GameCamera_Down"] = false
assert(coroutine.resume(coRun))
keysHeld["GameCamera_Crouch"] = true
keysHeld["Car_Horn"] = true
Vehicles.Update(0.35, true)
assert(coroutine.resume(coRun))
assert(Vehicles.GetLocalSeat() == 3, "passenger pressing Ctrl must NEVER swap seats")
keysHeld["GameCamera_Crouch"] = false
keysHeld["Car_Horn"] = false
assert(coroutine.resume(coRun))

-- 6) VehicleCamera.Advance: 1P passenger eye anchor + glide + +/-115 deg yaw clamp
assert(Vehicles.SwapToSeat(2) == true)
local camData = {
  tVehicleData = {nVehicle = vehId, bPhoto = false},
  tFinal = {vCameraYPR = makeVec(math.rad(160), 0.1, 0)},
}
calls = {}
VehicleCamera.Advance(camData, tWorldAPIs, 0.016, 0.016)
assert(lastCall("CameraApplyFinal") ~= nil, "VehicleCamera wrap must apply final passenger eye transform")
assert(camData.tFinal.vCameraYPR:GetX() <= math.rad(115) + 0.001, "1P passenger yaw must clamp to +/-115 deg")

-- 7) PhotoUIMode preserves passenger seat (seat 3) on exit
assert(Vehicles.SwapToSeat(3) == true)
Vehicles.GetState().nPhotoReturnSeat = 3
Vehicles.GetState().bInPhotoFromVehicle = true
local photoSelf = {}
PhotoUIMode.Init(photoSelf, 1, {nVehicle = vehId, nSeat = 3, bThirdPersonCamera = false})
calls = {}
PhotoUIMode.ExitMode(photoSelf)
local retMode = lastCall("SetNewMode")
assert(retMode and retMode.args[1] == "DriveVehicle" and retMode.args[2].nSeat == 3,
  "PhotoUIMode exit must return passenger to seat 3")

-- 8) Native buggy headlights (L) control Headlight_Left & Headlight_Right via api.lighting (NO CameraTorch spawns)
calls, packets = {}, {}
assert(Vehicles.ToggleHeadlights() == true)
assert(#findCalls("InstantiatePrefab") == 0, "native headlights must NOT spawn custom CameraTorch prefabs")
local enCalls = findCalls("LightingSetEnable")
assert(#enCalls == 2 and enCalls[1].args[1] == headLightLeftId and enCalls[1].args[2] == true and
  enCalls[2].args[1] == headLightRightId and enCalls[2].args[2] == true,
  "turning headlights ON must call api.lighting.SetEnable(true) on Headlight_Left & Headlight_Right")
assert(lastCall("CameraTorchToggle") ~= nil and lastCall("CameraTorchToggle").args[1] == true, "must play torch toggle audio")
assert(#packets == 1 and packets[1].n == 0x12 and packets[1].d.op == "lights" and packets[1].d.on == true)

calls, packets = {}, {}
assert(Vehicles.ToggleHeadlights() == false)
local claimCalls = findCalls("LightingClaimDisable")
local offCalls = findCalls("LightingSetEnable")
assert(#claimCalls == 2 and #offCalls == 2 and offCalls[1].args[2] == false and offCalls[2].args[2] == false,
  "turning headlights OFF must ClaimDisableLight and SetEnable(false) on both native headlights")
assert(#packets == 1 and packets[1].d.op == "lights" and packets[1].d.on == false)

calls = {}
assert(Vehicles.ToggleHeadlights() == true)
local relCalls = findCalls("LightingReleaseDisable")
assert(#relCalls == 2, "turning headlights back ON must ReleaseDisableLight on both native headlights")
Vehicles.ToggleHeadlights(false, true)

-- 9) Auto-open habitat gates while driving (ignores Aquarium Staff Doors)
assert(Vehicles.SwapToSeat(1) == true)
entityTransforms[gateAquariumId] = makeTransform(100, 0, 102, 0, 0, 0)
entityTransforms[gateNormalId] = makeTransform(100, 0, 104, 0, 0, 0)
fpiEntities[gateAquariumId] = {sType = "HabitatGate", nParentEntityID = gateAquariumId}
fpiEntities[gateNormalId] = {sType = "HabitatGate", nParentEntityID = gateNormalId}
calls = {}
DriveVehicleUIMode.Advance(driveSelf, 0.05, 0.05)
local openCall = lastCall("RequestHabitatGateOpen")
assert(openCall and openCall.args[1] == gateNormalId, "auto-gate must open regular HabitatGate and ignore Aquarium Staff Door")
-- Drive past >7.5 m -> releases gate
vehPose.z = 115.0
refreshTransforms()
DriveVehicleUIMode.Advance(driveSelf, 0.05, 0.05)
local relCall = lastCall("ReleaseHabitatGateOpenRequest")
assert(relCall and relCall.args[1] == gateNormalId, "auto-gate must release once vehicle clears 7.5 m")

-- Exit vehicle cleanly
DriveVehicleUIMode.TransitionOut(driveSelf)
uiMode = "WalkingCamera"
assert(Vehicles.GetLocalSeat() == nil, "TransitionOut must clear local seat")

-- 11) Trust-boundary validation on 0x13 & 0x12
assert(Vehicles.ValidatePosePacket({k = "wrong", x = 1, y = 1, z = 1, yaw = 0, pitch = 0, roll = 0}) == nil)
assert(Vehicles.ValidatePosePacket({k = "vpose", x = 0/0, y = 1, z = 1, yaw = 0, pitch = 0, roll = 0}) == nil)
local vp = Vehicles.ValidatePosePacket({k = "vpose", x = 10, y = 1, z = 20, yaw = 0.5, pitch = 0.1, roll = -0.1, spd = 999, steer = -5})
assert(vp and vp.spd == 60 and vp.steer == -1, "ValidatePosePacket must clamp speed and steer")

assert(Vehicles.ValidateEventPacket({k = "vehicle", op = "seat", seat = 5}) == nil, "out-of-range seat rejected")
assert(Vehicles.ValidateEventPacket({k = "vehicle", op = "seat", seat = 1.5}) == nil, "fractional seat rejected")
assert(Vehicles.ValidateEventPacket({k = "vehicle", op = "evil"}) == nil, "unknown op rejected")
assert(Vehicles.ValidateEventPacket({k = "vehicle", op = "recall", x = 0/0, y = 0, z = 0}) == nil, "NaN recall rejected")
local ve = Vehicles.ValidateEventPacket({k = "vehicle", op = "seat", seat = 2})
assert(ve and ve.op == "seat" and ve.seat == 2)

-- 12) Remote friend driving: 0x12 seat=1 + 0x13 pose interpolation + Recall blocked while friend drives
assert(Vehicles.OnPacket({nType = 0x12, tData = {k = "vehicle", op = "seat", seat = 1}}) == true)
assert(Vehicles.RecallVehicle(false) == false, "RecallVehicle must be blocked when friend is driving")
assert(Vehicles.OnPacket({nType = 0x13, tData = {k = "vpose", x = 120.0, y = 0.0, z = 130.0, yaw = 1.0, pitch = 0, roll = 0, spd = 5, steer = 0}}) == true)
calls = {}
Vehicles.Update(0.05, true)
assert(lastCall("SetTransform") ~= nil, "remote driver 0x13 pose must move vehicle transform")
assert(pState.tVehicleFriendOverride ~= nil and pState.tVehicleFriendOverride.seat == 1 and pState.tVehicleFriendOverride.clip == "$OnRideSitIdle",
  "friend seat override must be updated with $OnRideSitIdle")

-- Simultaneous seat race: client in seat 2 yields to seat 3 when host claims seat 2
role = "client"
DriveVehicleUIMode.TransitionIn(driveSelf, {nVehicle = vehId, nSeat = 2, bThirdPersonCamera = true})
assert(Vehicles.GetLocalSeat() == 2)
Vehicles.OnPacket({nType = 0x12, tData = {k = "vehicle", op = "seat", seat = 2}})
assert(Vehicles.GetLocalSeat() == 3, "client must yield to next free seat on simultaneous seat claim, got " .. tostring(Vehicles.GetLocalSeat()))

-- OnPeerDisconnected clears friend seat & override
Vehicles.OnPeerDisconnected()
assert(pState.tVehicleFriendOverride == nil and Vehicles.GetState().tSeats[2] == nil, "disconnect must clear friend seat")
DriveVehicleUIMode.TransitionOut(driveSelf)
uiMode = "WalkingCamera"

-- RecallVehicle succeeds when no friend is driving (near player + outpost)
role = "host"
playerPos = {20.0, 0.0, 30.0}
playerYaw = 0.0
calls, packets = {}, {}
assert(Vehicles.RecallVehicle(false) == true)
assert(approx(vehPose.x, 20.0, 0.1) and approx(vehPose.z, 34.5, 0.1) and approx(vehPose.y, 0.40, 0.05),
  "near-player recall must park 4.5 m ahead snapped to raycast")
assert(#packets == 1 and packets[1].d.op == "recall" and packets[1].d.outpost == false)

calls, packets = {}, {}
assert(Vehicles.RecallVehicle(true) == true)
assert(lastCall("TeleportVehicleToSpawnPoint") ~= nil, "outpost recall must call TeleportVehicleToSpawnPoint")
assert(#packets == 1 and packets[1].d.op == "recall" and packets[1].d.outpost == true)

-- OnPeerConnected re-broadcasts seat & headlights
DriveVehicleUIMode.TransitionIn(driveSelf, {nVehicle = vehId, nSeat = 1, bThirdPersonCamera = true})
Vehicles.ToggleHeadlights(true, true)
packets = {}
Vehicles.OnPeerConnected()
local bSawSeat, bSawLights, bSawPose = false, false, false
for _, p in ipairs(packets) do
  if p.n == 0x12 and p.d.op == "seat" and p.d.seat == 1 then bSawSeat = true end
  if p.n == 0x12 and p.d.op == "lights" and p.d.on == true then bSawLights = true end
  if p.n == 0x13 and p.d.k == "vpose" then bSawPose = true end
end
assert(bSawSeat and bSawLights and bSawPose, "OnPeerConnected must sync seat, headlights, and driver pose")

print("ok: 4-seat research vehicle tests passed")
"""


def main() -> int:
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.globals().SOURCES = SOURCES
    rt.execute(HARNESS + "\n" + CHECKS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
