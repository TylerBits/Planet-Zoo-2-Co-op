-- PZ2-Coop 4-seat Research Vehicle system:
--   1. All-zoo support: works with FAC_Wild_ResearchOutpost unlocked in Sandbox, Challenge, & Career zoos
--      (Franchise stays disabled per CLAUDE.md rule 6).
--   2. 4-seat cabin (1 Driver + 1 Front Passenger + 2 Back Passengers) calibrated dynamically from vanilla
--      SeatDriver with native baked ride-sit animations ($OnRideSitIdle across AF/AM/TF/TM) and head-look.
--   3. Closest-seat proximity popup prompts anchored at each door ([E] Drive / Sit - Front Passenger / Back L / R).
--   4. Debounced seat swapping via Q (GameCamera_Down — Q only, never Ctrl) / DPad Up (Vehicle_SwitchAmmo_Prev),
--      teleporting to the next unoccupied seat with a smooth 0.25 s cabin camera glide & seamless driver handoff.
--   5. Passenger 1P/3P cameras, Photo Mode (F) seat preservation, seated Emotes/Props (B), native buggy headlight
--      toggle (L), side-aware door exits with obstruction fallback, auto-open safari/habitat gates, vehicle recall,
--      & 20 Hz co-op sync.
local global = _G
local api = global.api
local math = global.math
local string = global.string
local table = global.table
local tostring = global.tostring
local tonumber = global.tonumber
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local next = global.next
local pcall = global.pcall
local coroutine = global.coroutine
local rawget = global.rawget
local rawset = global.rawset
local setmetatable = global.setmetatable
local require = global.require
local Vector3 = require("Vector3")
local TransformQ = require("TransformQ")
local Quaternion = require("Quaternion")
local Bridge = require("PZ2Coop.Bridge")
local Avatar = require("PZ2Coop.Avatar")
local Presence = require("PZ2Coop.Presence")

local Vehicles = module(...)

local c_nVehicleEventPacket = 0x12 -- reliable JSON (k = "vehicle")
local c_nVehiclePosePacket = 0x13  -- unreliable 20 Hz JSON (k = "vpose")
local c_nPoseSendInterval = 0.05   -- 20 Hz driver vehicle pose broadcast
local c_nPoseSmoothRate = 14.0     -- smooth tracking for remote-driven vehicle
local c_nPoseSnapDist = 25.0       -- metres: larger jumps snap immediately
local c_nPoseTimeout = 2.0         -- seconds before remote driving authority ages out
local c_nSeatPromptRange = 3.2     -- horizontal metres from door anchor to show seat prompt
local c_nSeatPromptMaxDY = 1.8     -- max vertical delta from vehicle to player feet
local c_nCamGlideDur = 0.25        -- seconds smooth cabin glide on seat swap
local c_nEyeAboveNeck = 0.16       -- anatomical eye height above def_c_neck1_joint
local c_nFrontNeckFwdFromEye = 0.09 -- aligns front passenger upright spine cleanly on def_seatAttach01/02 (-0.130)
local c_nPassengerEyeFwdOfNeck = 0.08 -- 1P eyes sit 8 cm forward of neck collar (clean body view, zero collar clip)
local c_nDefaultSitNeckY = 0.51    -- measured live TM $OnRideSitIdle def_c_neck1_joint Y before live bone sample
local c_nDefaultSitNeckZ = 0.03
local c_nPassengerYawClamp = math.rad(115) -- wide look-around arc for sightseeing & photography
local c_nAutoGateOpenDist = 6.0    -- metres perpendicular: auto-open guest/safari/habitat gates when approaching entrance
local c_nAutoGateCloseDist = 7.5   -- metres perpendicular: release auto-opened gate once cleared
local c_nMinPassableHalfW = 1.10   -- minimum doorway/cutout half-width (2.2 m wide) for vehicle pass-through
local c_nPortalPassPerp = 4.0      -- metres perpendicular from doorway plane (clears ~2 m front bumper + gate frame)
local c_nPortalPassLatPad = 0.85   -- lateral margin around doorway half-width before restoring wall collision
local c_nRecallForwardDist = 4.5   -- metres in front of player when recalling vehicle
local c_nSwapCooldown = 0.30       -- seconds debounce so holding/bouncing Q never cycles multiple seats
local c_nLightsCooldown = 0.25     -- seconds debounce on L headlight toggle
local c_nDriverAvatarTimeout = 15.0
local c_sSitClip = "$OnRideSitIdle" -- verified in Guests.ovl across AF, AM, TF, and TM
local c_tDriverHeadParts = {"Head", "Hair", "Beard", "Accessory"}

-- Seat metadata (1 = Driver, 2 = Front Passenger, 3 = Back Left, 4 = Back Right).
local c_tSeatDefs = {
  {id = 1, key = "driver",     label = "Driver",          short = "Driver", prompt = "Drive",                 side = -1},
  {id = 2, key = "front_pass", label = "Front Passenger", short = "Front",  prompt = "Sit - Front Passenger", side = 1},
  {id = 3, key = "rear_left",  label = "Back Left",       short = "Back L", prompt = "Sit - Back Left",       side = -1},
  {id = 4, key = "rear_right", label = "Back Right",      short = "Back R", prompt = "Sit - Back Right",      side = 1},
}

-- Default local seat/eye positions verified from VEH_Staff_Buggy.ovl skeleton (models.ms2 bone_info[0]):
--   def_seatAttach01/02_joint = (+-0.295, 1.073, -0.130), def_seatAttach03/04_joint = (+-0.295, 1.073, -0.884)
--   doors Y in [0.466, 1.165], Z in [-1.135, 0.541]; roof Y in [1.846, 2.042]; rear bulkhead Z <= -1.163.
local c_tDefaultDriverLocal = {x = -0.40, y = 0.56, z = 0.10}
local c_tDefaultEyeLocal = {x = -0.40, y = 1.58, z = -0.14}
local c_nRearRowZDelta = -0.754
local c_nRearRowYDelta = 0.00
local c_nDoorPromptOutX = 0.92
local c_nDoorPromptUpY = 0.65
local c_nExitSideDist = 1.45
local c_nExitRearDist = 2.70

-- Native ButtonPromptBar/ButtonPromptList wrap sLocString in '['..label..']' automatically, so omit outer brackets.
-- GameCamera_Down is bound ONLY to KB_Key_Q (key 17) in GameMain/Main.ovl -> gamecamera.logicalcontrols (NO Ctrl!),
-- leaving Ctrl exclusively for Car_Horn without swapping seats.
local c_tSwapPromptMouse = {
  sLocString = "STRING_LITERAL:Value=|Swap Seat|",
  sLogicalControl = "GameCamera_Down",
  sLocation = "HUD_CenterPrompts",
}
local c_tSwapPromptPad = {
  sLocString = "STRING_LITERAL:Value=|Swap Seat|",
  sLogicalControl = "Vehicle_SwitchAmmo_Prev",
  sLocation = "HUD_CenterPrompts",
}
local c_tLightsPrompt = {
  sLocString = "STRING_LITERAL:Value=|Headlights|",
  sLogicalControl = "GameCamera_Torch",
  sLocation = "HUD_CenterPrompts",
}

local s = rawget(global, "__PZ2CoopVehiclesState")
if s == nil then
  s = {
    bInstalled = false,
    nClock = 0,
    nVehicle = nil,           -- active/known vehicle entity ID
    nLocalSeat = nil,         -- nil = on foot / build cam, 1..4 = seated inside vehicle
    nPendingEnterSeat = nil,  -- seat chosen via closest-seat prompt before TransitionIn
    nPhotoReturnSeat = nil,   -- preserved seat index while in PhotoUIMode
    bInPhotoFromVehicle = false,
    bThirdPerson = true,
    tSeats = {},              -- [1..4] = {peer = "local"|"friend", name = string}
    tHoveredPrompt = nil,     -- latest closest-seat prompt while walking near a vehicle
    tDriveModeSelf = nil,     -- live DriveVehicleUIMode instance while active
    tSeatCache = {},          -- nVehicle -> {driverLocal, eyeLocal}
    tLiveSitNeck = nil,       -- {y, z, group} live def_c_neck1_joint offset measured in $OnRideSitIdle
    bCalibLogged = false,
    bNeckCalibLogged = false,
    tDriverAvatarBuild = nil, -- resumable coroutine builder for vanilla SeatDriver StartScreenAvatar
    tDriverHiddenState = {},  -- [nEntityID] = bool; guards Cobra's ref-counted model:SetHidden against double-hides
    tCamGlide = nil,          -- {fromX, fromY, fromZ, toX, toY, toZ, elapsed, dur}
    bHeadlightsOn = false,
    bHeadlightsManual = false,-- true once user/peer toggled L; reinforces native Light state vs NightLighting
    tDisabledLights = {},     -- nLightEntityID -> true while holding ClaimDisableLight
    tAutoOpenGate = nil,      -- {id, sMgVar, gx, gy, gz, fx, fz, rx, rz, nHalfW} auto-opened while driving
    bVehPortalGhost = false,  -- true while chassis collision is temporarily disabled crossing an open portal
    nVehPhysEnt = nil,        -- cached Flag_Car_OffTrack physics entity ID for active vehicle
    nVehPhysFor = nil,        -- vehicle root entity ID matching nVehPhysEnt
    nPoseSendTimer = 0,
    tRemotePose = nil,        -- {x, y, z, yaw, pitch, roll, spd, steer, rxAt}
    tSmoothPose = nil,        -- {x, y, z, yaw, pitch, roll}
    bPromptsAdded = false,
    bSwapKeyWasDown = false,
    bLightsKeyWasDown = false,
    bExitInFlight = false,
    nLastSwapAt = -10.0,
    nLastLightsAt = -10.0,
    tPendingCmd = nil,        -- deferred UI commands ({cmd, arg}) executed safely on Update
    nVehicleScanTimer = 0,
    bHasVehicle = false,
  }
  rawset(global, "__PZ2CoopVehiclesState", s)
end

local Log = function(_sMsg)
  Bridge.Log("vehicles: " .. tostring(_sMsg))
end

local WorldAPIs = function()
  return api.world and api.world.GetWorldAPIs and api.world.GetWorldAPIs() or nil
end

local IsFinite = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

local Clamp = function(_n, _lo, _hi)
  if _n < _lo then return _lo end
  if _n > _hi then return _hi end
  return _n
end

local WrapAngle = function(_n)
  return (_n + math.pi) % (2 * math.pi) - math.pi
end

local ReadVec3 = function(_v)
  if _v == nil then
    return nil
  end
  local bOk, x, y, z = pcall(function()
    if _v.GetX ~= nil then
      return _v:GetX(), _v:GetY(), _v:GetZ()
    end
    return _v:X(), _v:Y(), _v:Z()
  end)
  if bOk and IsFinite(x) and IsFinite(y) and IsFinite(z) then
    return x, y, z
  end
  return nil
end

local PoseTransform = function(_x, _y, _z, _yaw, _pitch, _roll)
  return TransformQ.FromOrPos(
    Quaternion.FromYawPitchRoll(Vector3:new(_yaw or 0, _pitch or 0, _roll or 0)),
    Vector3:new(_x, _y, _z))
end

local CurrentUIMode = function()
  local bOk, sMode = pcall(function()
    local BaseUIMode = require("Editors.Shared.BaseUIMode")
    return WorldAPIs().ModeHelperComponent:GetCurrentModeName(BaseUIMode.GetModeHelperEntity())
  end)
  return bOk and sMode or nil
end

local WalkingHeight = function()
  local bOk, WalkingCamera = pcall(require, "Components.Cameras.WalkingCamera")
  return bOk and WalkingCamera.GetDefaultWalkingHeight and WalkingCamera.GetDefaultWalkingHeight() or 1.55
end

local SendVehicleEvent = function(_tPayload)
  if Bridge.GetRole() == "none" or not (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    return
  end
  local tOut = {k = "vehicle"}
  for k, v in pairs(_tPayload) do
    tOut[k] = v
  end
  Bridge.SendPacket(c_nVehicleEventPacket, nil, tOut)
end

local PlayUiSound = function(_sEvent)
  if api.audio ~= nil and api.audio.SendGUIEvent ~= nil then
    pcall(api.audio.SendGUIEvent, _sEvent)
  end
end

local ShowToast = function(_sText, _sColour)
  local sSafe = string.gsub(tostring(_sText or ""), "[|%[%]]", "")
  if sSafe == "" then
    return
  end
  pcall(function()
    local worldScript = api.world.GetScript(api.world.GetActive())
    local nm = worldScript and worldScript.tEnvironment and
      worldScript.tEnvironment:RequestInterface("Interfaces.INotificationManager")
    if nm ~= nil and type(nm.tTimelinePopOutQueue) == "table" then
      table.insert(nm.tTimelinePopOutQueue, {
        nTimeShown = 0,
        bActionable = false,
        sColour = _sColour,
        tEntry = {
          sTimelineEntryName = "VIPEntered",
          sNotificationString = "[STRING_LITERAL:Value=|" .. sSafe .. "|]",
        },
      })
    end
  end)
end

-- ---- seat geometry & calibration (pure math helpers exported for offline tests) ------------------

-- Computes calibrated 4-seat local offsets (driver SeatDriver, passenger $OnRideSitIdle root, door prompt, 1P eye,
-- exit side) given optional measured SeatDriver, FirstPersonCamera, and live $OnRideSitIdle def_c_neck1_joint coords.
Vehicles.ComputeSeatOffsets = function(_tDriverLocal, _tEyeLocal, _tSitNeck)
  local dx = (_tDriverLocal and IsFinite(_tDriverLocal.x) and math.abs(_tDriverLocal.x) >= 0.15 and
    math.abs(_tDriverLocal.x) <= 0.75) and _tDriverLocal.x or c_tDefaultDriverLocal.x
  local dy = (_tDriverLocal and IsFinite(_tDriverLocal.y) and _tDriverLocal.y >= 0.10 and
    _tDriverLocal.y <= 1.50) and _tDriverLocal.y or c_tDefaultDriverLocal.y
  local dz = (_tDriverLocal and IsFinite(_tDriverLocal.z) and _tDriverLocal.z >= -0.80 and
    _tDriverLocal.z <= 0.80) and _tDriverLocal.z or c_tDefaultDriverLocal.z
  local nDriverSign = dx >= 0 and 1 or -1

  -- Calibrate 1P eye position directly from vanilla FirstPersonCamera when available so passenger eye height & depth
  -- match the driver's exact artist-authored cabin view.
  local fpx = (_tEyeLocal and IsFinite(_tEyeLocal.x) and math.abs(_tEyeLocal.x) >= 0.15 and
    math.abs(_tEyeLocal.x) <= 0.75) and _tEyeLocal.x or dx
  local fpy = (_tEyeLocal and IsFinite(_tEyeLocal.y) and _tEyeLocal.y >= 1.00 and
    _tEyeLocal.y <= 2.00) and _tEyeLocal.y or math.max(dy + 0.98, c_tDefaultEyeLocal.y)
  local fpz = (_tEyeLocal and IsFinite(_tEyeLocal.z) and _tEyeLocal.z >= -0.60 and
    _tEyeLocal.z <= 0.90) and _tEyeLocal.z or (dz + 0.08)

  -- Align $OnRideSitIdle passenger avatar root so:
  --   Y: neck (def_c_neck1_joint) sits at fpy - 0.16 (exact match to FirstPersonCamera eye height, zero roof/floor clip).
  --   Z: front passenger root sits near def_seatAttach02_joint (-0.085..-0.100, +19 cm forward of chair backrest),
  --      and rear row sits exact def_seatAttach row spacing (-0.754 m behind front, ~24 cm clear of rear bulkhead -1.163).
  --   1P Passenger eye Z sits 8 cm forward of live neck collar so looking down shows full torso/lap with zero collar clip.
  local nNeckY = (_tSitNeck and IsFinite(_tSitNeck.y) and _tSitNeck.y >= 0.15 and _tSitNeck.y <= 1.25)
    and _tSitNeck.y or c_nDefaultSitNeckY
  local nNeckZ = (_tSitNeck and IsFinite(_tSitNeck.z) and math.abs(_tSitNeck.z) <= 0.60)
    and _tSitNeck.z or c_nDefaultSitNeckZ
  local nPassY = Clamp((fpy - c_nEyeAboveNeck) - nNeckY, 0.25, fpy - 0.45)
  local nPassZ = Clamp((fpz + c_nFrontNeckFwdFromEye) - nNeckZ, fpz - 0.20, fpz + 0.25)
  local nPassX = (_tEyeLocal and IsFinite(_tEyeLocal.x) and math.abs(_tEyeLocal.x) >= 0.15 and
    math.abs(_tEyeLocal.x) <= 0.75) and _tEyeLocal.x or dx
  local nDoorBaseY = math.max(dy, c_tDefaultDriverLocal.y)
  local nFrontPassEyeZ = nPassZ + nNeckZ + c_nPassengerEyeFwdOfNeck

  local nRearPassY = nPassY + c_nRearRowYDelta
  local nRearPassZ = nPassZ + c_nRearRowZDelta
  local nRearEyeY = fpy + c_nRearRowYDelta
  local nRearEyeZ = nFrontPassEyeZ + c_nRearRowZDelta
  local nRearDoorY = nDoorBaseY + c_nRearRowYDelta + c_nDoorPromptUpY
  local nRearDoorZ = nPassZ + c_nRearRowZDelta
  return {
    [1] = {
      id = 1, key = "driver", label = "Driver", short = "Driver", prompt = "Drive",
      seat = {x = dx, y = dy, z = dz},
      passSeat = {x = nPassX, y = nPassY, z = nPassZ},
      door = {x = nDriverSign * c_nDoorPromptOutX, y = nDoorBaseY + c_nDoorPromptUpY, z = nPassZ},
      eye  = {x = fpx, y = fpy, z = fpz},
      sideSign = nDriverSign,
    },
    [2] = {
      id = 2, key = "front_pass", label = "Front Passenger", short = "Front", prompt = "Sit - Front Passenger",
      seat = {x = -nPassX, y = nPassY, z = nPassZ},
      passSeat = {x = -nPassX, y = nPassY, z = nPassZ},
      door = {x = -nDriverSign * c_nDoorPromptOutX, y = nDoorBaseY + c_nDoorPromptUpY, z = nPassZ},
      eye  = {x = -fpx, y = fpy, z = nFrontPassEyeZ},
      sideSign = -nDriverSign,
    },
    [3] = {
      id = 3, key = "rear_left", label = "Back Left", short = "Back L", prompt = "Sit - Back Left",
      seat = {x = nPassX, y = nRearPassY, z = nRearPassZ},
      passSeat = {x = nPassX, y = nRearPassY, z = nRearPassZ},
      door = {x = nDriverSign * c_nDoorPromptOutX, y = nRearDoorY, z = nRearDoorZ},
      eye  = {x = fpx, y = nRearEyeY, z = nRearEyeZ},
      sideSign = nDriverSign,
    },
    [4] = {
      id = 4, key = "rear_right", label = "Back Right", short = "Back R", prompt = "Sit - Back Right",
      seat = {x = -nPassX, y = nRearPassY, z = nRearPassZ},
      passSeat = {x = -nPassX, y = nRearPassY, z = nRearPassZ},
      door = {x = -nDriverSign * c_nDoorPromptOutX, y = nRearDoorY, z = nRearDoorZ},
      eye  = {x = -fpx, y = nRearEyeY, z = nRearEyeZ},
      sideSign = -nDriverSign,
    },
  }
end

local MeasureVehicleChildLocal = function(_nVehicle, _sChildName)
  local tResult = nil
  pcall(function()
    local tWorld = WorldAPIs()
    local trApi = tWorld and tWorld.transform
    if trApi == nil or api.entity == nil or api.entity.FindEntityByName == nil then
      return
    end
    local nChild = api.entity.FindEntityByName(_sChildName, _nVehicle)
    if nChild == nil then
      return
    end
    local trVeh = trApi:CalculateWorldTransform(_nVehicle)
    local trChild = trApi:CalculateWorldTransform(nChild)
    if trVeh ~= nil and trChild ~= nil and trVeh.ToLocalPos ~= nil then
      local vPos = trChild.GetPos and trChild:GetPos() or trChild:Pos()
      local vLoc = vPos ~= nil and trVeh:ToLocalPos(vPos) or nil
      local lx, ly, lz = ReadVec3(vLoc)
      if lx ~= nil then
        tResult = {x = lx, y = ly, z = lz}
      end
    end
  end)
  return tResult
end

local GetSeatOffsetsForVehicle = function(_nVehicle)
  local tCached = _nVehicle ~= nil and s.tSeatCache[_nVehicle] or nil
  if tCached == nil and _nVehicle ~= nil then
    local tDriverLocal = MeasureVehicleChildLocal(_nVehicle, "SeatDriver")
    local tEyeLocal = MeasureVehicleChildLocal(_nVehicle, "FirstPersonCamera")
    if tDriverLocal ~= nil or tEyeLocal ~= nil then
      tCached = {driverLocal = tDriverLocal, eyeLocal = tEyeLocal}
      s.tSeatCache[_nVehicle] = tCached
      if not s.bCalibLogged then
        s.bCalibLogged = true
        Log(string.format("calibrated SeatDriver=(%s) FirstPersonCamera=(%s)",
          tDriverLocal and string.format("%.3f,%.3f,%.3f", tDriverLocal.x, tDriverLocal.y, tDriverLocal.z) or "default",
          tEyeLocal and string.format("%.3f,%.3f,%.3f", tEyeLocal.x, tEyeLocal.y, tEyeLocal.z) or "default"))
      end
    end
  end
  return Vehicles.ComputeSeatOffsets(
    tCached and tCached.driverLocal or nil,
    tCached and tCached.eyeLocal or nil,
    s.tLiveSitNeck)
end

-- Transforms a local point (lx, ly, lz) on a vehicle transform into world coordinates.
local LocalToWorldPoint = function(_trVehicle, _lx, _ly, _lz)
  if _trVehicle == nil then
    return nil
  end
  if _trVehicle.ToWorldPos ~= nil then
    local bOk, vW = pcall(_trVehicle.ToWorldPos, _trVehicle, Vector3:new(_lx, _ly, _lz))
    if bOk and vW ~= nil then
      local wx, wy, wz = ReadVec3(vW)
      if wx ~= nil then
        return wx, wy, wz, vW
      end
    end
  end
  -- Fallback via GetPos + GetR/GetU/GetF
  local vx, vy, vz = ReadVec3(_trVehicle.GetPos and _trVehicle:GetPos() or (_trVehicle.Pos and _trVehicle:Pos()))
  if vx == nil then
    return nil
  end
  local rx, ry, rz = ReadVec3(_trVehicle.GetR and _trVehicle:GetR())
  local ux, uy, uz = ReadVec3(_trVehicle.GetU and _trVehicle:GetU())
  local fx, fy, fz = ReadVec3(_trVehicle.GetF and _trVehicle:GetF())
  if rx == nil or ux == nil or fx == nil then
    rx, ry, rz = 1, 0, 0
    ux, uy, uz = 0, 1, 0
    fx, fy, fz = 0, 0, 1
  end
  local wx = vx + rx * _lx + ux * _ly + fx * _lz
  local wy = vy + ry * _lx + uy * _ly + fy * _lz
  local wz = vz + rz * _lx + uz * _ly + fz * _lz
  return wx, wy, wz, Vector3:new(wx, wy, wz)
end

local ExtractTransformYPR = function(_tr)
  if _tr == nil or _tr.GetOr == nil then
    return 0, 0, 0
  end
  local bOk, yaw, pitch, roll = pcall(function()
    local vYpr = _tr:GetOr():ToYawPitchRoll()
    return ReadVec3(vYpr)
  end)
  if bOk and yaw ~= nil then
    return yaw, pitch or 0, roll or 0
  end
  return 0, 0, 0
end

-- ---- seat occupancy registry (supports 1..4 players) --------------------------------------------

local IsSeatOccupiedByOther = function(_nSeat, _sSelfPeer)
  local sSelf = _sSelfPeer or "local"
  local tOcc = s.tSeats[_nSeat]
  return tOcc ~= nil and tOcc.peer ~= sSelf
end

local ClearPeerFromSeats = function(_sPeer)
  local bChanged = false
  for i = 1, 4 do
    if s.tSeats[i] ~= nil and s.tSeats[i].peer == _sPeer then
      s.tSeats[i] = nil
      bChanged = true
    end
  end
  return bChanged
end

local AssignPeerToSeat = function(_sPeer, _nSeat, _sName)
  ClearPeerFromSeats(_sPeer)
  if type(_nSeat) == "number" and _nSeat >= 1 and _nSeat <= 4 and math.floor(_nSeat) == _nSeat then
    s.tSeats[_nSeat] = {peer = _sPeer, name = _sName or (_sPeer == "local" and "You" or "Friend")}
    return true
  end
  return false
end

-- Pure helper: returns next unoccupied seat index cycling clockwise/sequentially (1->2->3->4->1), or nil if none.
Vehicles.NextAvailableSeat = function(_nCurrentSeat, _tSeats, _sSelfPeer)
  local tOcc = _tSeats or s.tSeats
  local sSelf = _sSelfPeer or "local"
  local nCur = (type(_nCurrentSeat) == "number" and _nCurrentSeat >= 1 and _nCurrentSeat <= 4) and
    math.floor(_nCurrentSeat) or 0
  for step = 1, 4 do
    local nCand = ((nCur - 1 + step) % 4) + 1
    if nCand ~= nCur then
      local tEntry = tOcc[nCand]
      if tEntry == nil or tEntry.peer == sSelf then
        return nCand
      end
    end
  end
  return nil
end

-- Pure helper: picks closest seat from 4 world-space door anchors, falling back to nearest unoccupied seat if occupied.
Vehicles.PickClosestSeat = function(_tDoorWorldPositions, _px, _py, _pz, _tSeats, _sSelfPeer)
  if type(_tDoorWorldPositions) ~= "table" then
    return nil
  end
  local tOcc = _tSeats or s.tSeats
  local sSelf = _sSelfPeer or "local"
  local nBestAllD2, nBestAllSeat = math.huge, nil
  local nBestFreeD2, nBestFreeSeat = math.huge, nil
  local nMaxR2 = c_nSeatPromptRange * c_nSeatPromptRange

  for i = 1, 4 do
    local tDoor = _tDoorWorldPositions[i]
    if tDoor ~= nil and IsFinite(tDoor.x) and IsFinite(tDoor.y) and IsFinite(tDoor.z) then
      local dy = math.abs(tDoor.y - (_py + 1.0))
      local dx, dz = tDoor.x - _px, tDoor.z - _pz
      local d2 = dx * dx + dz * dz
      if d2 <= nMaxR2 and dy <= c_nSeatPromptMaxDY then
        if d2 < nBestAllD2 then
          nBestAllD2 = d2
          nBestAllSeat = i
        end
        local tEntry = tOcc[i]
        if (tEntry == nil or tEntry.peer == sSelf) and d2 < nBestFreeD2 then
          nBestFreeD2 = d2
          nBestFreeSeat = i
        end
      end
    end
  end

  if nBestAllSeat == nil then
    return nil
  end
  local tClosestDef = c_tSeatDefs[nBestAllSeat]
  local tClosestDoor = _tDoorWorldPositions[nBestAllSeat]
  if nBestFreeSeat == nil then
    return {
      nSeat = nil,
      nClosestSeat = nBestAllSeat,
      bFull = true,
      sLabel = "Vehicle Full",
      x = tClosestDoor.x, y = tClosestDoor.y, z = tClosestDoor.z,
      nDistSq = nBestAllD2,
    }
  end
  local tFreeDef = c_tSeatDefs[nBestFreeSeat]
  local tFreeDoor = _tDoorWorldPositions[nBestFreeSeat]
  local sLabel = tFreeDef.prompt
  if nBestFreeSeat ~= nBestAllSeat then
    sLabel = tFreeDef.prompt .. " (" .. tClosestDef.short .. " Occupied)"
  end
  return {
    nSeat = nBestFreeSeat,
    nClosestSeat = nBestAllSeat,
    bFull = false,
    sLabel = sLabel,
    x = tFreeDoor.x, y = tFreeDoor.y, z = tFreeDoor.z,
    nDistSq = nBestFreeD2,
  }
end

-- Pure helper: ordered side-aware exit positions (own door side -> opposite side -> behind tailgate).
Vehicles.ComputeExitCandidates = function(_nSeat, _tOffsets, _trVehicle)
  local tOff = _tOffsets and _tOffsets[_nSeat or 1] or Vehicles.ComputeSeatOffsets(nil)[_nSeat or 1]
  local nSide = tOff.sideSign or -1
  local nZ = tOff.seat and tOff.seat.z or 0.0
  local tLocalSpecs = {
    {name = "own_door",      lx = nSide * c_nExitSideDist,  ly = 0.0, lz = nZ},
    {name = "opposite_door", lx = -nSide * c_nExitSideDist, ly = 0.0, lz = nZ},
    {name = "rear_tailgate", lx = 0.0,                      ly = 0.0, lz = -c_nExitRearDist},
  }
  local tOut = {}
  for _, spec in ipairs(tLocalSpecs) do
    local wx, wy, wz, vPos = LocalToWorldPoint(_trVehicle, spec.lx, spec.ly, spec.lz)
    if wx ~= nil then
      table.insert(tOut, {name = spec.name, x = wx, y = wy, z = wz, vPos = vPos, lx = spec.lx, lz = spec.lz})
    end
  end
  return tOut
end

-- ---- vehicle discovery ---------------------------------------------------------------------------

local IsValidVehicleEntity = function(_nEnt)
  if _nEnt == nil then
    return false
  end
  local bOk, bValid = pcall(function()
    local tWorld = WorldAPIs()
    return tWorld ~= nil and tWorld.transform ~= nil and tWorld.transform:HasTransform(_nEnt) == true
  end)
  return bOk and bValid == true
end

local DiscoverVehicleEntity = function()
  if s.nVehicle ~= nil and IsValidVehicleEntity(s.nVehicle) then
    s.bHasVehicle = true
    return s.nVehicle
  end
  local nFound = nil
  pcall(function()
    local tWorld = WorldAPIs()
    if tWorld == nil then
      return
    end
    -- 1. Check active FirstPersonInteraction vehicle entries (works in both Reserves & normal Zoos)
    local fpi = tWorld.FirstPersonInteraction
    if fpi ~= nil and type(fpi.tEntities) == "table" then
      for nEnt, tInfo in pairs(fpi.tEntities) do
        if type(tInfo) == "table" and tInfo.sType == "Vehicle" then
          local nVeh = tInfo.nParentEntityID or nEnt
          if IsValidVehicleEntity(nVeh) then
            nFound = nVeh
            return
          end
        end
      end
    end
    -- 2. Check Research Outpost -> VehicleSpawnPoint -> GetVehicleFromSpawnPoint
    if tWorld.research ~= nil and tWorld.research.GetResearchOutpost ~= nil and
      tWorld.vehicles ~= nil and tWorld.vehicles.GetVehicleFromSpawnPoint ~= nil and
      api.entity ~= nil and api.entity.FindEntityByName ~= nil then
      local nOutpost = tWorld.research:GetResearchOutpost()
      if nOutpost ~= nil then
        local nSpawn = api.entity.FindEntityByName("VehicleSpawnPoint", nOutpost)
        if nSpawn ~= nil then
          local nVeh = tWorld.vehicles:GetVehicleFromSpawnPoint(nSpawn)
          if IsValidVehicleEntity(nVeh) then
            nFound = nVeh
          end
        end
      end
    end
  end)
  if nFound ~= nil then
    s.nVehicle = nFound
    s.bHasVehicle = true
    return nFound
  end
  s.bHasVehicle = false
  return nil
end

-- ---- native vehicle headlights (L) ---------------------------------------------------------------
-- Controls the buggy's built-in HeadLights/Headlight_Left & Headlight_Right Light components via api.lighting
-- (SetEnable + ClaimDisableLight / ReleaseDisableLight so manual toggle works cleanly both day and night).

local FindVehicleHeadlightEntities = function(_nVehicle)
  local tLights = {}
  if _nVehicle == nil or api.entity == nil or api.entity.FindEntityByName == nil then
    return tLights
  end
  local tSeen = {}
  local AddUnique = function(_nId)
    if _nId ~= nil and not tSeen[_nId] then
      tSeen[_nId] = true
      table.insert(tLights, _nId)
    end
  end
  pcall(function()
    local nGroup = api.entity.FindEntityByName("HeadLights", _nVehicle) or
      api.entity.FindEntityByName("Headlights", _nVehicle)
    if nGroup ~= nil then
      AddUnique(api.entity.FindEntityByName("Headlight_Left", nGroup))
      AddUnique(api.entity.FindEntityByName("Headlight_Right", nGroup))
    end
    if #tLights == 0 then
      AddUnique(api.entity.FindEntityByName("Headlight_Left", _nVehicle))
      AddUnique(api.entity.FindEntityByName("Headlight_Right", _nVehicle))
    end
    if #tLights == 0 and nGroup ~= nil then
      AddUnique(nGroup)
    end
  end)
  return tLights
end

local ReleaseHeadlightDisableClaims = function()
  if type(s.tDisabledLights) ~= "table" then
    s.tDisabledLights = {}
    return
  end
  local lighting = api.lighting
  for nLightId in pairs(s.tDisabledLights) do
    if lighting ~= nil and lighting.ReleaseDisableLight ~= nil then
      pcall(lighting.ReleaseDisableLight, nLightId)
    end
  end
  s.tDisabledLights = {}
end

local SetNativeLightState = function(_nLightId, _bOn)
  local lighting = api.lighting
  if lighting == nil or _nLightId == nil then
    return
  end
  if _bOn then
    if s.tDisabledLights[_nLightId] then
      s.tDisabledLights[_nLightId] = nil
      if lighting.ReleaseDisableLight ~= nil then
        pcall(lighting.ReleaseDisableLight, _nLightId)
      end
    end
    if lighting.SetEnable ~= nil then
      pcall(lighting.SetEnable, _nLightId, true)
    end
  else
    if not s.tDisabledLights[_nLightId] then
      s.tDisabledLights[_nLightId] = true
      if lighting.ClaimDisableLight ~= nil then
        pcall(lighting.ClaimDisableLight, _nLightId)
      end
    end
    if lighting.SetEnable ~= nil then
      pcall(lighting.SetEnable, _nLightId, false)
    end
  end
end

local ApplyHeadlights = function(_bOn, _nVehicle)
  local bNext = _bOn == true
  s.bHeadlightsOn = bNext
  s.bHeadlightsManual = true
  local nVeh = _nVehicle or DiscoverVehicleEntity()
  if nVeh == nil then
    return
  end
  local tLights = FindVehicleHeadlightEntities(nVeh)
  for _, nLightId in ipairs(tLights) do
    SetNativeLightState(nLightId, bNext)
  end
  Log("native headlights " .. (bNext and "ON" or "OFF") .. " (toggled " .. tostring(#tLights) .. " lights)")
end

local StepNativeHeadlights = function(_nVehicle)
  if not s.bHeadlightsManual or not s.bHeadlightsOn or _nVehicle == nil then
    return
  end
  local lighting = api.lighting
  if lighting == nil or lighting.SetEnable == nil then
    return
  end
  -- Reinforce SetEnable(true) when user explicitly switched headlights ON so NightLighting doesn't turn them off in daytime.
  local tLights = FindVehicleHeadlightEntities(_nVehicle)
  for _, nLightId in ipairs(tLights) do
    pcall(lighting.SetEnable, nLightId, true)
  end
end

Vehicles.ToggleHeadlights = function(_bForceState, _bNoSend)
  local bNext = (_bForceState ~= nil) and (_bForceState == true) or (not s.bHeadlightsOn)
  ApplyHeadlights(bNext, s.nVehicle)
  local bAudio = false
  pcall(function()
    local ga = WorldAPIs() and WorldAPIs().gameaudio
    if ga ~= nil and ga.CameraTorchToggle ~= nil then
      ga:CameraTorchToggle(bNext)
      bAudio = true
    end
  end)
  if not bAudio then
    PlayUiSound("gui_click")
  end
  if not _bNoSend then
    SendVehicleEvent({op = "lights", on = bNext})
  end
  return bNext
end

-- ---- auto-open guest/safari/habitat gates & wide doorway/cutout pass-through ---------------------

local ExtractPortalBasis = function(_tr)
  if _tr == nil then
    return nil
  end
  local vPos = _tr.GetPos and _tr:GetPos() or (_tr.Pos and _tr:Pos())
  local gx, gy, gz = ReadVec3(vPos)
  if gx == nil then
    return nil
  end
  local fx, fz = 0, 1
  if _tr.GetF ~= nil then
    local vF = _tr:GetF()
    local vx, _, vz = ReadVec3(vF)
    if vx ~= nil then
      local nLen = math.sqrt(vx * vx + vz * vz)
      if nLen > 1e-4 then
        fx, fz = vx / nLen, vz / nLen
      end
    end
  else
    local nYaw = ExtractTransformYPR(_tr)
    fx, fz = math.sin(nYaw), math.cos(nYaw)
  end
  return gx, gy, gz, fx, fz, fz, -fx
end

local ResolveEntityResourceName = function(_tWorld, _nEnt)
  if _tWorld == nil or _nEnt == nil then
    return nil
  end
  local placement = _tWorld.placement
  local trApi = _tWorld.transform
  local nCur = _nEnt
  for _ = 1, 4 do
    if nCur == nil then
      break
    end
    if placement ~= nil and placement.GetPartResourceName ~= nil then
      local bOk, sRes = pcall(placement.GetPartResourceName, placement, nCur)
      if bOk and type(sRes) == "string" and sRes ~= "" then
        return sRes
      end
    end
    if api.entity ~= nil and api.entity.GetName ~= nil then
      local bNOk, sName = pcall(api.entity.GetName, nCur)
      if bNOk and type(sName) == "string" and sName ~= "" and sName ~= "GateModel" and sName ~= "DoorModel" then
        return sName
      end
    end
    if trApi == nil or trApi.GetParent == nil then
      break
    end
    local bP, nPar = pcall(trApi.GetParent, trApi, nCur)
    if not bP or nPar == nil or nPar == nCur then
      break
    end
    nCur = nPar
  end
  return nil
end

local ClassifyVehicleAutoGate = function(_tWorld, _nEnt)
  if _tWorld == nil or _nEnt == nil then
    return nil
  end
  if Presence.IsAquariumStaffDoorEntity ~= nil and Presence.IsAquariumStaffDoorEntity(_nEnt) then
    return nil
  end
  local nGateId = _nEnt
  local sPropName = nil
  local hb = _tWorld.habitatboundary
  if hb ~= nil and hb.GetBoundaryObjectFromEntity ~= nil then
    local bOk, bHit, oPanel, _, oProp = pcall(hb.GetBoundaryObjectFromEntity, hb, _nEnt)
    if bOk and bHit then
      if oProp == nil and oPanel ~= nil and oPanel.GetAllData ~= nil then
        local bP, dP = pcall(oPanel.GetAllData, oPanel)
        if bP and type(dP) == "table" then
          oProp = dP.oAttachedProp
        end
      end
      if oProp == nil then
        return nil
      end
      if oProp.GetAllData ~= nil then
        local bD, dProp = pcall(oProp.GetAllData, oProp)
        if bD and type(dProp) == "table" then
          nGateId = dProp.nEntityID or nGateId
          sPropName = dProp.sPropType or dProp.sAttachablePropType or dProp.sType or dProp.sPrefabName or dProp.sName
        end
      end
    end
  end
  if Presence.IsAquariumStaffDoorEntity ~= nil and Presence.IsAquariumStaffDoorEntity(nGateId) then
    return nil
  end
  if type(sPropName) ~= "string" or sPropName == "" then
    sPropName = ResolveEntityResourceName(_tWorld, nGateId) or ""
  end
  local sLow = string.lower(sPropName)
  if string.find(sLow, "aquariumentrance", 1, true) ~= nil or string.find(sLow, "small", 1, true) ~= nil then
    return nil
  end
  if string.find(sLow, "trackairlock", 1, true) ~= nil or string.find(sLow, "transportgate", 1, true) ~= nil then
    return {id = nGateId, sMgVar = "GateOpen", nHalfW = 2.50, bIsGuest = false}
  elseif string.find(sLow, "glasstunnel", 1, true) ~= nil then
    return {id = nGateId, sMgVar = "GateState", nHalfW = 1.85, bIsGuest = true}
  elseif string.find(sLow, "guestgate", 1, true) ~= nil then
    return {id = nGateId, sMgVar = "GateState", nHalfW = 1.85, bIsGuest = true}
  end
  return {id = nGateId, sMgVar = "GateState", nHalfW = 1.75, bIsGuest = false}
end

local DriveAutoGateVisual = function(_tWorld, _nGateId, _sMgVar, _bOpen)
  local attractions = _tWorld and _tWorld.attractions
  local bUsedAttractions = false
  if attractions ~= nil then
    if _bOpen and attractions.RequestHabitatGateOpen ~= nil then
      bUsedAttractions = pcall(attractions.RequestHabitatGateOpen, attractions, _nGateId)
    elseif not _bOpen and attractions.ReleaseHabitatGateOpenRequest ~= nil then
      bUsedAttractions = pcall(attractions.ReleaseHabitatGateOpenRequest, attractions, _nGateId)
    end
  end
  -- Only drive motiongraph directly for track airlocks ("GateOpen") or if attractions API is absent;
  -- forcing "GateState"="FullOpen" on standard habitat/guest gates desyncs visuals from gate physics.
  local mg = _tWorld and _tWorld.motiongraph
  if mg ~= nil and mg.SetVariable ~= nil and (_sMgVar == "GateOpen" or not bUsedAttractions) then
    local val = (_sMgVar == "GateOpen") and (_bOpen == true) or (_bOpen and "FullOpen" or "Closed")
    pcall(mg.SetVariable, mg, _nGateId, _sMgVar or "GateState", val)
    if api.entity ~= nil and api.entity.FindEntityByName ~= nil then
      for _, sChild in ipairs({"GateModel", "DoorModel", "Model"}) do
        local bC, nChild = pcall(api.entity.FindEntityByName, sChild, _nGateId)
        if bC and nChild ~= nil then
          pcall(mg.SetVariable, mg, nChild, _sMgVar or "GateState", val)
        end
      end
    end
  end
end

-- Pure helper (exported for offline tests): returns true only when the vehicle is approaching / facing
-- the door entrance (perpendicular to the wall & aimed toward the doorway), NOT when driving past parallel.
Vehicles.ShouldAutoOpenDoor = function(_tVeh, _tDoor, _bCurrentlyOpen)
  if type(_tVeh) ~= "table" or type(_tDoor) ~= "table" then
    return false
  end
  local vx, vy, vz = _tVeh.x, _tVeh.y, _tVeh.z
  local gx, gy, gz = _tDoor.gx, _tDoor.gy, _tDoor.gz
  if not (IsFinite(vx) and IsFinite(vy) and IsFinite(vz) and IsFinite(gx) and IsFinite(gy) and IsFinite(gz)) then
    return false
  end
  local nHalfW = _tDoor.nHalfW or 1.50
  local gfx, gfz = _tDoor.fx or 0, _tDoor.fz or 1
  local grx, grz = _tDoor.rx or gfz, _tDoor.rz or (-gfx)
  local dx, dz = vx - gx, vz - gz
  local nPerp = math.abs(dx * gfx + dz * gfz)
  local nLat = math.abs(dx * grx + dz * grz)

  if _bCurrentlyOpen then
    -- Hysteresis: keep open while passing through until well clear.
    return math.abs(vy - gy) <= 3.0 and nPerp <= c_nAutoGateCloseDist and nLat <= (nHalfW + 3.0)
  end

  if math.abs(vy - gy) > 2.5 or nPerp > c_nAutoGateOpenDist or nLat > (nHalfW + 1.0) then
    return false
  end
  local vfx, vfz = _tVeh.fx or 0, _tVeh.fz or 1
  -- Anti-parallel check: vehicle heading must align with the doorway's through-axis, not parallel to the wall.
  local nAxisDot = math.abs(vfx * gfx + vfz * gfz)
  if nAxisDot < 0.55 then
    return false
  end
  -- Already right in the doorway threshold.
  if nPerp <= 1.6 then
    return true
  end
  -- Facing toward the entrance (or reversing toward it).
  local nDist = math.sqrt(dx * dx + dz * dz)
  if nDist < 1e-4 then
    return true
  end
  local nToDot = (vfx * (-dx) + vfz * (-dz)) / nDist
  if nToDot >= 0.50 then
    return true
  end
  if (_tVeh.spd or 0) < -0.3 and (-nToDot) >= 0.50 then
    return true
  end
  return false
end

-- Pure helper (exported for offline tests): true when vehicle is centered in an open wide doorway or cutout corridor.
Vehicles.IsVehicleInPortalCorridor = function(_tVeh, _tPortal)
  if type(_tVeh) ~= "table" or type(_tPortal) ~= "table" then
    return false
  end
  local nHalfW = _tPortal.nHalfW or 0
  if nHalfW < c_nMinPassableHalfW then
    return false
  end
  local vx, vy, vz = _tVeh.x, _tVeh.y, _tVeh.z
  local gx, gy, gz = _tPortal.gx, _tPortal.gy, _tPortal.gz
  if not (IsFinite(vx) and IsFinite(vy) and IsFinite(vz) and IsFinite(gx) and IsFinite(gy) and IsFinite(gz)) then
    return false
  end
  if math.abs(vy - gy) > 2.5 then
    return false
  end
  local dx, dz = vx - gx, vz - gz
  if _tPortal.bRadial then
    local nR = nHalfW + c_nPortalPassLatPad
    return (dx * dx + dz * dz) <= (nR * nR)
  end
  local fx, fz = _tPortal.fx or 0, _tPortal.fz or 1
  local rx, rz = _tPortal.rx or fz, _tPortal.rz or (-fx)
  local nPerp = math.abs(dx * fx + dz * fz)
  local nLat = math.abs(dx * rx + dz * rz)
  return nPerp <= c_nPortalPassPerp and nLat <= (nHalfW + c_nPortalPassLatPad)
end

local RestoreVehicleIgnoredCollisions = function(_nVehicle)
  if s.bVehPortalGhost and s.nVehPhysEnt ~= nil then
    local p = api.physics
    if p ~= nil and p.SetCollisionEnabled ~= nil then
      pcall(p.SetCollisionEnabled, s.nVehPhysEnt, true)
    end
  end
  s.bVehPortalGhost = false
  if _nVehicle == nil or _nVehicle == s.nVehPhysFor then
    s.nVehPhysEnt = nil
    s.nVehPhysFor = nil
  end
end

local ReleaseAutoGate = function(_sReason)
  if s.tAutoOpenGate == nil then
    return
  end
  local tG = s.tAutoOpenGate
  s.tAutoOpenGate = nil
  pcall(function()
    local tWorld = WorldAPIs()
    DriveAutoGateVisual(tWorld, tG.id, tG.sMgVar, false)
    if (Bridge.IsPeerConnected() or Bridge.IsLoopback()) and IsFinite(tG.gx) then
      Bridge.SendPacket(c_nVehicleEventPacket, nil, {
        k = "action", op = "gate", open = false,
        x = math.floor(tG.gx * 100 + 0.5), y = math.floor(tG.gy * 100 + 0.5), z = math.floor(tG.gz * 100 + 0.5),
      })
    end
    if _sReason ~= nil then
      Log("released gate id=" .. tostring(tG.id) .. " (" .. tostring(_sReason) .. ")")
    end
  end)
end

local StepAutoGates = function(_nVehicle)
  if s.nLocalSeat ~= 1 or _nVehicle == nil then
    ReleaseAutoGate()
    return
  end
  pcall(function()
    local tWorld = WorldAPIs()
    local trApi = tWorld and tWorld.transform
    if trApi == nil then
      return
    end
    local trVeh = trApi:CalculateWorldTransform(_nVehicle)
    local vx, vy, vz, vfx, vfz = ExtractPortalBasis(trVeh)
    if vx == nil then
      return
    end
    local nSpd = (tWorld.vehicles and tWorld.vehicles.GetVehicleSpeed and tWorld.vehicles:GetVehicleSpeed(_nVehicle)) or 0
    local tVeh = {x = vx, y = vy, z = vz, fx = vfx, fz = vfz, spd = nSpd}

    -- Keep currently auto-opened gate open until vehicle clears its corridor.
    -- Periodically renew the attractions gate-open request (release + re-request to keep refcount balanced)
    -- so creeping slowly or waiting in front of the door never lets the gate's physics blocker re-engage.
    if s.tAutoOpenGate ~= nil then
      if Vehicles.ShouldAutoOpenDoor(tVeh, s.tAutoOpenGate, true) then
        local nNow = s.nClock or 0
        if (nNow - (s.tAutoOpenGate.nRenewAt or 0)) >= 3.0 then
          s.tAutoOpenGate.nRenewAt = nNow
          local attractions = tWorld and tWorld.attractions
          if attractions ~= nil and attractions.RequestHabitatGateOpen ~= nil then
            if attractions.ReleaseHabitatGateOpenRequest ~= nil then
              pcall(attractions.ReleaseHabitatGateOpenRequest, attractions, s.tAutoOpenGate.id)
            end
            pcall(attractions.RequestHabitatGateOpen, attractions, s.tAutoOpenGate.id)
          end
        end
        return
      end
      local g = s.tAutoOpenGate
      local dx, dz = vx - (g.gx or 0), vz - (g.gz or 0)
      local nPerp = math.abs(dx * (g.fx or 0) + dz * (g.fz or 1))
      local nLat = math.abs(dx * (g.rx or 1) + dz * (g.rz or 0))
      ReleaseAutoGate(string.format("cleared perp=%.2f lat=%.2f dy=%.2f", nPerp, nLat, math.abs(vy - (g.gy or 0))))
    end

    local tCandidates = {}
    local tSeen = {}
    local AddCandidate = function(_nEnt)
      if _nEnt == nil or tSeen[_nEnt] then
        return
      end
      local tInfo = ClassifyVehicleAutoGate(tWorld, _nEnt)
      if tInfo == nil or tSeen[tInfo.id] then
        return
      end
      tSeen[_nEnt] = true
      tSeen[tInfo.id] = true
      local trG = trApi:CalculateWorldTransform(tInfo.id)
      local gx, gy, gz, gfx, gfz, grx, grz = ExtractPortalBasis(trG)
      if gx ~= nil then
        tInfo.gx, tInfo.gy, tInfo.gz = gx, gy, gz
        tInfo.fx, tInfo.fz, tInfo.rx, tInfo.rz = gfx, gfz, grx, grz
        table.insert(tCandidates, tInfo)
      end
    end

    -- 1. Spatial Flag_HabitatBoundary query catches GuestGate, GlassTunnelGate, TrackAirlock, TransportGate, etc.
    local sp = tWorld.spatial
    if sp ~= nil and sp.SphereQuery ~= nil and sp.Flag_HabitatBoundary ~= nil then
      local bQ, tHits = pcall(sp.SphereQuery, sp, Vector3:new(vx, vy + 1.0, vz), c_nAutoGateOpenDist + 2.0,
        sp.Flag_HabitatBoundary, 0, 32)
      if bQ and type(tHits) == "table" then
        for _, nEnt in ipairs(tHits) do
          AddCandidate(nEnt)
        end
      end
    end

    -- 2. Vanilla FirstPersonInteraction HabitatGate entries.
    local fpi = tWorld.FirstPersonInteraction
    if fpi ~= nil and type(fpi.tEntities) == "table" then
      for nEnt, tInfo in pairs(fpi.tEntities) do
        if type(tInfo) == "table" and tInfo.sType == "HabitatGate" then
          AddCandidate(tInfo.nParentEntityID or nEnt)
        end
      end
    end

    local tBest, nBestD2 = nil, math.huge
    for _, tDoor in ipairs(tCandidates) do
      if Vehicles.ShouldAutoOpenDoor(tVeh, tDoor, false) then
        local d2 = (tDoor.gx - vx) ^ 2 + (tDoor.gz - vz) ^ 2
        if d2 < nBestD2 then
          nBestD2 = d2
          tBest = tDoor
        end
      end
    end

    if tBest ~= nil then
      tBest.nRenewAt = s.nClock or 0
      s.tAutoOpenGate = tBest
      DriveAutoGateVisual(tWorld, tBest.id, tBest.sMgVar, true)
      if Bridge.IsPeerConnected() or Bridge.IsLoopback() then
        Bridge.SendPacket(c_nVehicleEventPacket, nil, {
          k = "action", op = "gate", open = true,
          x = math.floor(tBest.gx * 100 + 0.5),
          y = math.floor(tBest.gy * 100 + 0.5),
          z = math.floor(tBest.gz * 100 + 0.5),
        })
      end
      Log(string.format("auto-opened %s (id=%s pos=(%.1f,%.1f) f=(%.2f,%.2f) halfW=%.2f)",
        tBest.bIsGuest and "guest door" or "habitat gate", tostring(tBest.id),
        tBest.gx or 0, tBest.gz or 0, tBest.fx or 0, tBest.fz or 1, tBest.nHalfW or 0))
    end
  end)
end

-- Allows the driving vehicle to pass cleanly through opened large doors / guest doors and wide entrance
-- cutouts on habitat walls by temporarily disabling collision on the vehicle's own chassis physics body
-- (wheels still support the buggy on terrain via Flag_Landscape raycasts!) strictly while aligned inside
-- the opening corridor, and restoring it immediately once cleared. Closed doors, solid side walls, and
-- animal habitat containment remain 100% solid.
local StepVehiclePortalPassThrough = function(_nVehicle)
  if s.nLocalSeat ~= 1 or _nVehicle == nil then
    RestoreVehicleIgnoredCollisions(_nVehicle)
    return
  end
  local p = api.physics
  if p == nil or p.SetCollisionEnabled == nil then
    return
  end
  pcall(function()
    local tWorld = WorldAPIs()
    local trApi = tWorld and tWorld.transform
    if trApi == nil then
      return
    end
    local trVeh = trApi:CalculateWorldTransform(_nVehicle)
    local vx, vy, vz, vfx, vfz = ExtractPortalBasis(trVeh)
    if vx == nil then
      return
    end
    -- Resolve and cache the vehicle's own Flag_Car_OffTrack physics body while collision is enabled.
    if s.nVehPhysFor ~= _nVehicle then
      RestoreVehicleIgnoredCollisions(s.nVehPhysFor)
      s.nVehPhysFor = _nVehicle
      s.nVehPhysEnt = nil
    end
    if s.nVehPhysEnt == nil and not s.bVehPortalGhost and p.SphereSweep ~= nil then
      local nPhys = api.entity ~= nil and api.entity.FindEntityByName ~= nil and
        api.entity.FindEntityByName("MainPhysicsWorld") or nil
      local nCarFlag = p.Flag_Car_OffTrack or 0
      if nPhys ~= nil and nCarFlag ~= 0 then
        local bV, tVHits = pcall(p.SphereSweep, nPhys,
          Vector3:new(vx, vy + 4.5, vz), Vector3:new(vx, vy + 0.1, vz), 0.35, nCarFlag, 4)
        if bV and type(tVHits) == "table" and #tVHits > 0 and type(tVHits[1]) == "table" then
          s.nVehPhysEnt = tVHits[1].nEntityID or tVHits[1].entityID
        end
      end
    end

    local tVeh = {x = vx, y = vy, z = vz, fx = vfx, fz = vfz}
    local bInPortal = false

    -- 1. Auto-opened gate/guest door.
    if s.tAutoOpenGate ~= nil and Vehicles.IsVehicleInPortalCorridor(tVeh, s.tAutoOpenGate) then
      bInPortal = true
    end

    -- 2. Manually opened large doors / guest gates registered in Presence.
    if not bInPortal then
      local tOpenPortals = Presence.GetOpenPortals and Presence.GetOpenPortals() or nil
      if type(tOpenPortals) == "table" then
        for _, tP in pairs(tOpenPortals) do
          if Vehicles.IsVehicleInPortalCorridor(tVeh, tP) then
            bInPortal = true
            break
          end
        end
      end
    end

    -- 3. Wide entrance cutouts / archways / door frames on or near habitat walls (not blocked by a closed door).
    if not bInPortal then
      local sp = tWorld.spatial
      if sp ~= nil and sp.SphereQuery ~= nil and Presence.ClassifyCutoutResource ~= nil then
        local nFlags = (sp.Flag_Scenery or 0) | (sp.Flag_NonStaticScenery or 0) | (sp.Flag_Facility or 0)
        if nFlags ~= 0 then
          local bQ, tHits = pcall(sp.SphereQuery, sp, Vector3:new(vx, vy + 1.0, vz), 6.5, nFlags, 0, 24)
          if bQ and type(tHits) == "table" then
            for _, nEnt in ipairs(tHits) do
              local sName = ResolveEntityResourceName(tWorld, nEnt)
              local tDim = Presence.ClassifyCutoutResource(sName)
              if tDim ~= nil and (tDim.nHalfW or 0) >= c_nMinPassableHalfW then
                local trC = trApi:CalculateWorldTransform(nEnt)
                local gx, gy, gz, fx, fz, rx, rz = ExtractPortalBasis(trC)
                if gx ~= nil and not (Presence.HasClosedDoorAt ~= nil and Presence.HasClosedDoorAt(gx, gy, gz)) then
                  local tCut = {
                    gx = gx, gy = gy, gz = gz,
                    fx = fx, fz = fz, rx = rx, rz = rz,
                    nHalfW = tDim.nHalfW, nHalfDepth = tDim.nHalfDepth,
                  }
                  if Vehicles.IsVehicleInPortalCorridor(tVeh, tCut) then
                    bInPortal = true
                    break
                  end
                end
              end
            end
          end
        end
      end
    end

    if s.nVehPhysEnt ~= nil then
      if bInPortal then
        -- Re-assert every frame while inside an open portal corridor so engine physics/vehicle ticks
        -- cannot silently restore collision when creeping slowly or waiting in front of an open door.
        pcall(p.SetCollisionEnabled, s.nVehPhysEnt, false)
      end
      if bInPortal ~= s.bVehPortalGhost then
        s.bVehPortalGhost = bInPortal
        if not bInPortal then
          pcall(p.SetCollisionEnabled, s.nVehPhysEnt, true)
        end
        Log("portal pass-through chassis collision " .. (bInPortal and "DISABLED" or "RESTORED") ..
          " (vehPhys=" .. tostring(s.nVehPhysEnt) .. ")")
      end
    end
  end)
end

-- ---- closest-seat proximity prompt provider (called from Presence FPI wrap) ----------------------

Vehicles.FindClosestSeatPrompt = function(_nVehicle, _px, _py, _pz)
  if _nVehicle == nil or _px == nil then
    return nil
  end
  local bOk, tPrompt = pcall(function()
    local tWorld = WorldAPIs()
    local trApi = tWorld and tWorld.transform
    if trApi == nil then
      return nil
    end
    local trVeh = trApi:CalculateWorldTransform(_nVehicle)
    if trVeh == nil then
      return nil
    end
    local tOffsets = GetSeatOffsetsForVehicle(_nVehicle)
    local tDoors = {}
    for i = 1, 4 do
      local d = tOffsets[i].door
      local wx, wy, wz, vPos = LocalToWorldPoint(trVeh, d.x, d.y, d.z)
      if wx ~= nil then
        tDoors[i] = {x = wx, y = wy, z = wz, vPos = vPos}
      end
    end
    local tRes = Vehicles.PickClosestSeat(tDoors, _px, _py, _pz, s.tSeats, "local")
    if tRes ~= nil then
      tRes.nVehicle = _nVehicle
      tRes.vPos = Vector3:new(tRes.x, tRes.y, tRes.z)
    end
    return tRes
  end)
  if bOk and tPrompt ~= nil then
    s.nVehicle = _nVehicle
    s.bHasVehicle = true
    s.tHoveredPrompt = tPrompt
    return tPrompt
  end
  s.tHoveredPrompt = nil
  return nil
end

-- ---- seat override pose updates (own passenger & remote friend occupant) -------------------------

-- Samples live def_c_neck1_joint local height once own passenger avatar is playing $OnRideSitIdle so seat Y/Z
-- self-calibrates for any avatar group (AF/AM/TF/TM) directly against the buggy's FirstPersonCamera height.
local SampleOwnSitNeckOffset = function()
  if Avatar.GetLocalNeckPivot == nil or Presence.GetOwnBody == nil then
    return
  end
  local tBody = Presence.GetOwnBody()
  if tBody == nil or tBody.nAvatar == nil or tBody.tAnim == nil or not tBody.tAnim.bAnimated then
    return
  end
  if tBody.tAnim.sOverrideSuffix ~= c_sSitClip or (tBody.tAnim.nClock or 0) < 0.25 then
    return
  end
  if type(tBody.tAnim.sClip) ~= "string" or string.sub(tBody.tAnim.sClip, -#c_sSitClip) ~= c_sSitClip then
    return
  end
  local _, ny, nz, bLive = Avatar.GetLocalNeckPivot(tBody.tAnim, tBody.nAvatar)
  if not bLive or not IsFinite(ny) or ny < 0.15 or ny > 1.25 then
    return
  end
  local sGrp = tBody.tAnim.sGroup or "AM"
  local bUpdate = s.tLiveSitNeck == nil or s.tLiveSitNeck.group ~= sGrp or
    math.abs(s.tLiveSitNeck.y - ny) > 0.015 or math.abs(s.tLiveSitNeck.z - (nz or 0)) > 0.015
  if bUpdate then
    s.tLiveSitNeck = {y = ny, z = nz or 0, group = sGrp}
    if not s.bNeckCalibLogged then
      s.bNeckCalibLogged = true
      Log(string.format("live %s sit neck=(y=%.3f, z=%.3f) calibrated against FirstPersonCamera",
        tostring(sGrp), ny, nz or 0))
    end
  end
end

local SyncOwnPassengerAvatar = function(_nVehicle)
  if Presence.SetVehicleOwnOverride == nil then
    return
  end
  if s.nLocalSeat == nil or s.nLocalSeat == 1 or _nVehicle == nil then
    Presence.SetVehicleOwnOverride(nil)
    return
  end
  SampleOwnSitNeckOffset()
  pcall(function()
    local tWorld = WorldAPIs()
    local trVeh = tWorld and tWorld.transform and tWorld.transform:CalculateWorldTransform(_nVehicle)
    if trVeh == nil then
      return
    end
    local tOffsets = GetSeatOffsetsForVehicle(_nVehicle)
    local tOff = tOffsets[s.nLocalSeat]
    if tOff == nil then
      return
    end
    local tLoc = tOff.passSeat or tOff.seat
    local sx, sy, sz = LocalToWorldPoint(trVeh, tLoc.x, tLoc.y, tLoc.z)
    if sx == nil then
      return
    end
    local nVehYaw, nVehPitch, nVehRoll = ExtractTransformYPR(trVeh)
    local nCamYaw, nCamPitch = nVehYaw, 0
    if tWorld.CameraModeManager ~= nil and tWorld.CameraModeManager.GetPosYPRZoom ~= nil then
      local _, vYpr = tWorld.CameraModeManager:GetPosYPRZoom()
      local cy, cp = ReadVec3(vYpr)
      if cy ~= nil then
        nCamYaw, nCamPitch = cy, cp or 0
      end
    end
    Presence.SetVehicleOwnOverride({
      nVehicle = _nVehicle,
      lx = tLoc.x, ly = tLoc.y, lz = tLoc.z,
      x = sx, y = sy, z = sz,
      yaw = nVehYaw, pitch = nVehPitch, roll = nVehRoll,
      camYaw = nCamYaw, camPitch = nCamPitch,
      seat = s.nLocalSeat,
      clip = c_sSitClip,
      bHidden = false,
      bHeadHidden = not s.bThirdPerson,
    })
  end)
end

local SyncFriendVehicleAvatar = function(_nVehicle)
  if Presence.SetVehicleFriendOverride == nil then
    return
  end
  local nFriendSeat = nil
  for i = 1, 4 do
    if s.tSeats[i] ~= nil and s.tSeats[i].peer == "friend" then
      nFriendSeat = i
      break
    end
  end
  if nFriendSeat == nil or _nVehicle == nil then
    Presence.SetVehicleFriendOverride(nil)
    return
  end
  pcall(function()
    local tWorld = WorldAPIs()
    local trVeh = tWorld and tWorld.transform and tWorld.transform:CalculateWorldTransform(_nVehicle)
    if trVeh == nil then
      return
    end
    local tOffsets = GetSeatOffsetsForVehicle(_nVehicle)
    local tOff = tOffsets[nFriendSeat]
    if tOff == nil then
      return
    end
    local tLoc = tOff.passSeat or tOff.seat
    local sx, sy, sz = LocalToWorldPoint(trVeh, tLoc.x, tLoc.y, tLoc.z)
    if sx == nil then
      return
    end
    local nVehYaw, nVehPitch, nVehRoll = ExtractTransformYPR(trVeh)
    Presence.SetVehicleFriendOverride({
      nVehicle = _nVehicle,
      lx = tLoc.x, ly = tLoc.y, lz = tLoc.z,
      x = sx, y = sy, z = sz,
      yaw = nVehYaw, pitch = nVehPitch, roll = nVehRoll,
      seat = nFriendSeat,
      clip = c_sSitClip,
      bHidden = false,
    })
  end)
end

-- ---- seat swapping & camera transitions ----------------------------------------------------------

local StartCabinGlide = function(_nFromSeat, _nToSeat, _nVehicle)
  local tOffsets = GetSeatOffsetsForVehicle(_nVehicle)
  local tFrom = tOffsets[_nFromSeat or 1]
  local tTo = tOffsets[_nToSeat or 1]
  if tFrom == nil or tTo == nil then
    s.tCamGlide = nil
    return
  end
  s.tCamGlide = {
    fromX = tFrom.eye.x, fromY = tFrom.eye.y, fromZ = tFrom.eye.z,
    toX = tTo.eye.x,     toY = tTo.eye.y,     toZ = tTo.eye.z,
    elapsed = 0,
    dur = c_nCamGlideDur,
  }
end

local ReadOwnerAvatarForDriver = function()
  local GameDatabase = require("Database.GameDatabase")
  local StartScreenAvatar = require("StartScreen.Shared.StartScreenAvatar")
  local nPlayerKey = GameDatabase.GetPlayerKey(api.player.GetGameOwner())
  local tPlayerTable = GameDatabase.GetPlayer(nPlayerKey)
  local tSavedData = tPlayerTable and tPlayerTable:GetMainAvatarData()
  if not tSavedData then
    return nil, StartScreenAvatar
  end
  return StartScreenAvatar.AvatarVersionCheck(tSavedData.tData), StartScreenAvatar
end

local ShouldDriverKeepHairHidden = function()
  local bOk, bHide = pcall(function()
    local tAvatar = ReadOwnerAvatarForDriver()
    if tAvatar == nil or not (tAvatar.items and tAvatar.items.Hats) then
      return false
    end
    if api.multipart2 == nil or api.multipart2.GetProperties == nil or
      api.playeravatar == nil or api.playeravatar.GetHatHairForAvatarHairModel == nil then
      return false
    end
    local _, tProps = api.multipart2.GetProperties(tAvatar)
    local sHairModel = type(tProps) == "table" and tProps["Hair/ModelName"] or nil
    if type(sHairModel) == "string" and sHairModel ~= "" then
      local sHatHair = api.playeravatar.GetHatHairForAvatarHairModel(sHairModel)
      return sHatHair == ""
    end
    return false
  end)
  return bOk and bHide == true
end

-- Cobra's modelAPI:SetHidden is reference-counted (matching StartScreenEntity._SetHiddenOnModel & tHiddenEntities).
-- Never call SetHidden(id, true) or SetHidden(id, false) twice in a row for the same entity.
local SetModelHiddenTracked = function(_mApi, _nEntityId, _bHide)
  if _mApi == nil or _mApi.SetHidden == nil or _nEntityId == nil then
    return
  end
  if type(s.tDriverHiddenState) ~= "table" then
    s.tDriverHiddenState = {}
  end
  local bWant = _bHide == true
  if (s.tDriverHiddenState[_nEntityId] == true) == bWant then
    return
  end
  s.tDriverHiddenState[_nEntityId] = bWant
  pcall(_mApi.SetHidden, _mApi, _nEntityId, bWant)
end

-- Controls vanilla SeatDriver avatar visibility with full 1P body support:
--   - _bVisible = false: hides entire driver avatar (when local player is a passenger or exited vehicle).
--   - _bVisible = true, _bHeadOnlyHidden = false (3P Driver): unhides body AND head parts (respecting hat hair).
--   - _bVisible = true, _bHeadOnlyHidden = true  (1P Driver): keeps Torso & Legs visible, hides ONLY Head/Hat/Hair/Beard/Accessory!
local SetDriverAvatarState = function(_oDriveSelf, _bVisible, _bHeadOnlyHidden)
  if _oDriveSelf == nil then
    return false
  end
  local tWorld = WorldAPIs()
  local mApi = _oDriveSelf.modelAPI or (tWorld and tWorld.model)
  if mApi == nil or mApi.SetHidden == nil then
    return false
  end
  local nAvatar = _oDriveSelf.nAvatar
  if nAvatar == nil and _oDriveSelf.nVehicle ~= nil and api.entity ~= nil and api.entity.FindEntityByName ~= nil then
    pcall(function()
      local nSeatEnt = api.entity.FindEntityByName("SeatDriver", _oDriveSelf.nVehicle)
      if nSeatEnt ~= nil then
        nAvatar = api.entity.FindEntityByName("Avatar", nSeatEnt)
        if nAvatar ~= nil then
          _oDriveSelf.nAvatar = nAvatar
        end
      end
    end)
  end
  if nAvatar == nil then
    return false
  end
  local bVis = _bVisible == true
  local bHideHead = _bHeadOnlyHidden == true
  if bVis then
    -- Ensure local transform is zeroed on SeatDriver (protects against any interrupted StartScreenAvatar spawn at y=-1000).
    local trApi = _oDriveSelf.transformAPI or (tWorld and tWorld.transform)
    if trApi ~= nil and trApi.SetPosition ~= nil then
      pcall(trApi.SetPosition, trApi, nAvatar, Vector3:new(0, 0, 0))
    end
    local mgApi = _oDriveSelf.motiongraphAPI or (tWorld and tWorld.motiongraph)
    if mgApi ~= nil and mgApi.SetVariable ~= nil then
      pcall(mgApi.SetVariable, mgApi, nAvatar, "isBuggyDriver", true)
      pcall(mgApi.SetVariable, mgApi, nAvatar, "Ready", true)
    end
  end
  SetModelHiddenTracked(mApi, nAvatar, not bVis)
  if bVis and api.entity ~= nil and api.entity.FindEntityByName ~= nil then
    local bKeepHairHidden = (not bHideHead) and ShouldDriverKeepHairHidden()
    for _, sPart in ipairs(c_tDriverHeadParts) do
      local bOkP, nPartId = pcall(api.entity.FindEntityByName, sPart, nAvatar)
      if bOkP and nPartId ~= nil then
        local bPartHide = bHideHead or (sPart == "Hair" and bKeepHairHidden)
        SetModelHiddenTracked(mApi, nPartId, bPartHide)
        if sPart == "Head" then
          local bOkHat, nHatId = pcall(api.entity.FindEntityByName, "Hat", nPartId)
          if bOkHat and nHatId ~= nil then
            SetModelHiddenTracked(mApi, nHatId, bHideHead)
          end
        end
      end
    end
  end
  return true
end

-- Finds existing SeatDriver/Avatar or launches a safe resumable coroutine builder (NEVER yielding inside pcall!).
local EnsureDriverAvatar = function(_oDriveSelf)
  if _oDriveSelf == nil or _oDriveSelf.nVehicle == nil then
    return
  end
  local bHeadHide = not (_oDriveSelf.bThirdPersonCamera == true)
  if SetDriverAvatarState(_oDriveSelf, true, bHeadHide) then
    return
  end
  if s.tDriverAvatarBuild ~= nil and s.tDriverAvatarBuild.nVehicle == _oDriveSelf.nVehicle then
    return
  end
  if api.entity == nil or api.entity.FindEntityByName == nil then
    return
  end
  local bOkSeat, nSeatEnt = pcall(api.entity.FindEntityByName, "SeatDriver", _oDriveSelf.nVehicle)
  if not bOkSeat or nSeatEnt == nil then
    return
  end
  local bOkAv, tAvatar, StartScreenAvatar = pcall(ReadOwnerAvatarForDriver)
  if not bOkAv or tAvatar == nil or type(StartScreenAvatar) ~= "table" then
    return
  end
  local nVeh = _oDriveSelf.nVehicle
  local oBuild = {
    nVehicle = nVeh,
    nAge = 0,
    nAvatar = nil,
  }
  oBuild.co = coroutine.create(function()
    local oSSA = StartScreenAvatar:new()
    oSSA:Create(tAvatar, nSeatEnt, "driver", "Static")
    oBuild.nAvatar = oSSA.nAnimatedEntityID
  end)
  s.tDriverAvatarBuild = oBuild
  Log("building driver avatar asynchronously on SeatDriver")
end

local StepDriverAvatarBuild = function(_oDriveSelf, _nDt)
  local oBuild = s.tDriverAvatarBuild
  if oBuild == nil then
    return
  end
  local nDt = (type(_nDt) == "number" and _nDt > 0) and _nDt or (1 / 60)
  oBuild.nAge = (oBuild.nAge or 0) + nDt
  if oBuild.nAge >= c_nDriverAvatarTimeout then
    Log("driver avatar build timed out after " .. tostring(c_nDriverAvatarTimeout) .. " s")
    s.tDriverAvatarBuild = nil
    return
  end
  local bOk, sErr = coroutine.resume(oBuild.co)
  if not bOk then
    Log("driver avatar build error: " .. tostring(sErr))
    s.tDriverAvatarBuild = nil
    return
  end
  if coroutine.status(oBuild.co) == "dead" then
    local nCreated = oBuild.nAvatar
    s.tDriverAvatarBuild = nil
    local oSelf = _oDriveSelf or s.tDriveModeSelf
    if oSelf ~= nil and oSelf.nVehicle == oBuild.nVehicle then
      if nCreated ~= nil then
        oSelf.nAvatar = nCreated
        -- StartScreenAvatar:Create finishes with nAvatar visible (hide count 0) and Hair hidden only if hat needs it.
        s.tDriverHiddenState = s.tDriverHiddenState or {}
        s.tDriverHiddenState[nCreated] = false
        if api.entity ~= nil and api.entity.FindEntityByName ~= nil then
          local bKeepHair = ShouldDriverKeepHairHidden()
          for _, sPart in ipairs(c_tDriverHeadParts) do
            local bOkP, nPartId = pcall(api.entity.FindEntityByName, sPart, nCreated)
            if bOkP and nPartId ~= nil then
              s.tDriverHiddenState[nPartId] = (sPart == "Hair" and bKeepHair)
              if sPart == "Head" then
                local bOkHat, nHatId = pcall(api.entity.FindEntityByName, "Hat", nPartId)
                if bOkHat and nHatId ~= nil then
                  s.tDriverHiddenState[nHatId] = false
                end
              end
            end
          end
        end
      end
      local bIsDriver = s.nLocalSeat == 1
      SetDriverAvatarState(oSelf, bIsDriver, not (oSelf.bThirdPersonCamera == true))
      Log("driver avatar ready (entity " .. tostring(oSelf.nAvatar) .. ", driver=" .. tostring(bIsDriver) .. ")")
    end
  end
end

local ApplyLocalSeatMode = function(_oDriveSelf, _nPrevSeat, _nNewSeat, _bForceCamRequest)
  if _oDriveSelf == nil or _oDriveSelf.nVehicle == nil then
    return
  end
  local nVeh = _oDriveSelf.nVehicle
  local vApi = _oDriveSelf.vehiclesAPI or (WorldAPIs() and WorldAPIs().vehicles)
  local bIsDriver = _nNewSeat == 1

  -- Toggle vehicle control cleanly for driver vs passenger.
  if vApi ~= nil then
    pcall(vApi.SetPlayerControlled, vApi, nVeh, bIsDriver)
    if bIsDriver then
      pcall(vApi.SetVehicleOccupiedByPlayer, vApi, nVeh, true)
    else
      -- Keep occupied flag false for passengers so remote driver or coast-to-stop works cleanly.
      pcall(vApi.SetVehicleOccupiedByPlayer, vApi, nVeh, false)
    end
  end

  local bThird = _oDriveSelf.bThirdPersonCamera == true
  s.bThirdPerson = bThird

  -- Only request a camera mode switch when entering the vehicle, toggling 1P <-> 3P, or when the active mode
  -- differs from desired. Skipping redundant RequestMode on seat swaps preserves the player's current camera angle!
  -- ALWAYS use bFreeYaw = false in ThirdPersonVehicle (bFreeYaw=true causes inverted endless spin).
  pcall(function()
    local cmm = _oDriveSelf.cameraModeManager or (WorldAPIs() and WorldAPIs().CameraModeManager)
    local audio = WorldAPIs() and WorldAPIs().gameaudio
    if cmm ~= nil then
      local sDesiredCam = bThird and "ThirdPersonVehicle" or "Vehicle"
      local sCurCam = cmm.GetCurrentModeName ~= nil and cmm:GetCurrentModeName() or nil
      if _bForceCamRequest == true or _nPrevSeat == nil or sCurCam ~= sDesiredCam then
        if bThird then
          cmm:RequestMode("ThirdPersonVehicle", {
            nVehicle = nVeh, bFreeYaw = false, bFreeOrbit = false,
            bSmoothTransition = false, bIgnoreAnimalCollisions = false,
          })
          if audio ~= nil and audio.UpdateCameraPerspective ~= nil then
            audio:UpdateCameraPerspective("ThirdPersonVehicle", nVeh)
          end
        else
          if bIsDriver then
            cmm:RequestMode("Vehicle", {nVehicle = nVeh})
          else
            cmm:RequestMode("Vehicle", {nVehicle = nVeh, nSeat = _nNewSeat})
          end
          if audio ~= nil and audio.UpdateCameraPerspective ~= nil then
            audio:UpdateCameraPerspective("FirstPersonVehicle", nVeh)
          end
        end
      end
    end
  end)

  if bIsDriver then
    if Presence.SetVehicleOwnOverride ~= nil then
      Presence.SetVehicleOwnOverride(nil)
    end
    EnsureDriverAvatar(_oDriveSelf)
  else
    SetDriverAvatarState(_oDriveSelf, false, false)
    SyncOwnPassengerAvatar(nVeh)
  end

  if _nPrevSeat ~= nil and _nPrevSeat ~= _nNewSeat then
    StartCabinGlide(_nPrevSeat, _nNewSeat, nVeh)
  end
end

Vehicles.SwapToSeat = function(_nTargetSeat)
  local nTarget = tonumber(_nTargetSeat)
  if nTarget == nil or nTarget < 1 or nTarget > 4 or math.floor(nTarget) ~= nTarget then
    return false
  end
  if s.nLocalSeat == nil or s.nVehicle == nil then
    return false
  end
  if nTarget == s.nLocalSeat then
    return true
  end
  if s.bExitInFlight then
    s.bExitInFlight = false
    if Presence.CancelVehicleExit ~= nil then
      Presence.CancelVehicleExit()
    end
  end
  if IsSeatOccupiedByOther(nTarget, "local") then
    PlayUiSound("Staff_Invalid_Placement")
    local tOcc = s.tSeats[nTarget]
    ShowToast((c_tSeatDefs[nTarget].label) .. " is occupied by " .. tostring(tOcc and tOcc.name or "your friend"), "Red")
    return false
  end
  local nPrev = s.nLocalSeat
  s.nLocalSeat = nTarget
  local tSession = Bridge.GetSession()
  AssignPeerToSeat("local", nTarget, tSession and tSession.sSelf or "You")
  if nPrev == 1 then
    ReleaseAutoGate()
    RestoreVehicleIgnoredCollisions(s.nVehicle)
  end
  ApplyLocalSeatMode(s.tDriveModeSelf, nPrev, nTarget)
  PlayUiSound("gui_click")
  SendVehicleEvent({op = "seat", seat = nTarget})
  Log("swapped seat " .. tostring(nPrev) .. " -> " .. tostring(nTarget) .. " (" .. c_tSeatDefs[nTarget].label .. ")")
  return true
end

Vehicles.SwapToNextSeat = function()
  if s.nLocalSeat == nil or s.nVehicle == nil then
    return false
  end
  local nNext = Vehicles.NextAvailableSeat(s.nLocalSeat, s.tSeats, "local")
  if nNext == nil then
    PlayUiSound("Staff_Invalid_Placement")
    ShowToast("All other vehicle seats are occupied", "Red")
    return false
  end
  return Vehicles.SwapToSeat(nNext)
end

-- ---- vehicle recall (on foot or Co-op menu) ------------------------------------------------------

Vehicles.RecallVehicle = function(_bToOutpost)
  local nVeh = DiscoverVehicleEntity()
  if nVeh == nil then
    ShowToast("Place a Research Outpost (Facilities -> Transport) first", "Red")
    return false
  end
  if IsSeatOccupiedByOther(1, "local") then
    PlayUiSound("Staff_Invalid_Placement")
    ShowToast("Your friend is currently driving the vehicle", "Red")
    return false
  end
  local tWorld = WorldAPIs()
  if tWorld == nil then
    return false
  end

  local bMovedNearPlayer = false
  local nNewX, nNewY, nNewZ, nNewYaw = nil, nil, nil, 0
  if not _bToOutpost and s.nLocalSeat == nil then
    pcall(function()
      local tPose = Presence.GetOwnPose and Presence.GetOwnPose() or nil
      local px, py, pz, nYaw = nil, nil, nil, 0
      if tPose ~= nil then
        px, py, pz, nYaw = tPose.x, tPose.y, tPose.z, tPose.camYaw or tPose.yaw or 0
      elseif tWorld.CameraModeManager ~= nil then
        local vPos, vYpr = tWorld.CameraModeManager:GetPosYPRZoom()
        local cx, cy, cz = ReadVec3(vPos)
        local cyaw = ReadVec3(vYpr)
        if cx ~= nil then
          px, py, pz, nYaw = cx, cy - WalkingHeight(), cz, cyaw or 0
        end
      end
      if px == nil then
        return
      end
      local fx, fz = math.sin(nYaw), math.cos(nYaw)
      local tx = px + fx * c_nRecallForwardDist
      local tz = pz + fz * c_nRecallForwardDist
      local ty = py
      -- Snap to terrain/path surface via CameraUtils.FocusRaycast
      local bCu, CameraUtils = pcall(require, "Components.Cameras.CameraUtils")
      if bCu and type(CameraUtils) == "table" and CameraUtils.FocusRaycast ~= nil and
        tWorld.CameraModeManager ~= nil and tWorld.CameraModeManager.GetVoxelTerrainID ~= nil then
        local nTerr = tWorld.CameraModeManager:GetVoxelTerrainID()
        if nTerr ~= nil then
          local vHit = CameraUtils.FocusRaycast(tWorld, nTerr, Vector3:new(tx, py + 4.0, tz),
            Vector3:new(0, -1, 0), true, true, true)
          local _, hy = ReadVec3(vHit)
          if hy ~= nil and math.abs(hy - py) <= 4.0 then
            ty = hy
          end
        end
      end
      -- Park perpendicular to the player facing right so the driver door faces them
      nNewX, nNewY, nNewZ = tx, ty + 0.15, tz
      nNewYaw = WrapAngle(nYaw + math.pi * 0.5)
      if tWorld.transform ~= nil and tWorld.transform.SetTransform ~= nil then
        tWorld.transform:SetTransform(nVeh, PoseTransform(nNewX, nNewY, nNewZ, nNewYaw, 0, 0))
        bMovedNearPlayer = true
      end
    end)
  end

  if not bMovedNearPlayer then
    if tWorld.vehicles ~= nil and tWorld.vehicles.TeleportVehicleToSpawnPoint ~= nil then
      pcall(tWorld.vehicles.TeleportVehicleToSpawnPoint, tWorld.vehicles, nVeh)
      local tr = tWorld.transform and tWorld.transform:CalculateWorldTransform(nVeh)
      nNewX, nNewY, nNewZ = ReadVec3(tr and (tr.GetPos and tr:GetPos() or tr:Pos()))
      nNewYaw = ExtractTransformYPR(tr)
    end
  end

  PlayUiSound("gui_click")
  ShowToast(bMovedNearPlayer and "Research Vehicle recalled nearby" or "Research Vehicle returned to Outpost", "Green")
  if nNewX ~= nil then
    SendVehicleEvent({
      op = "recall",
      outpost = not bMovedNearPlayer,
      x = math.floor(nNewX * 100 + 0.5),
      y = math.floor(nNewY * 100 + 0.5),
      z = math.floor(nNewZ * 100 + 0.5),
      yaw = math.floor(nNewYaw * 1000 + 0.5),
    })
  end
  Log("recalled vehicle (" .. (bMovedNearPlayer and "near player" or "to outpost") .. ")")
  return true
end

-- ---- side-aware exit clearance check -------------------------------------------------------------

local CheckExitClear = function(_oDriveSelf, _vEyePos)
  if _oDriveSelf == nil or _vEyePos == nil then
    return false
  end
  local bOk, bClear = pcall(function()
    local CameraUtils = require("Components.Cameras.CameraUtils")
    local WalkingCamera = require("Components.Cameras.WalkingCamera")
    local trVeh = _oDriveSelf.transformAPI:CalculateWorldTransform(_oDriveSelf.nVehicle)
    local vVehCenter = trVeh:GetPos() + trVeh:GetU() * WalkingHeight()
    local vDelta = _vEyePos - vVehCenter
    local dx, dy, dz = ReadVec3(vDelta)
    if dx == nil then
      return false
    end
    local nLen = math.sqrt(dx * dx + dy * dy + dz * dz)
    if nLen < 0.05 then
      return true
    end
    local vDir = Vector3:new(dx / nLen, dy / nLen, dz / nLen)
    local nRadius = (CameraUtils.tweakableRadius and CameraUtils.tweakableRadius:GetValue()) or 0.2
    local nPhys = api.entity.FindEntityByName("MainPhysicsWorld")
    if nPhys ~= nil and api.physics ~= nil and api.physics.SphereSweep ~= nil then
      local nFlags = WalkingCamera.GetCollisionFlags(false)
      local tRes = api.physics.SphereSweep(nPhys, vVehCenter, _vEyePos, nRadius, nFlags, 4)
      if type(tRes) == "table" and #tRes > 0 then
        return false
      end
    end
    if _oDriveSelf.voxelterrainAPI ~= nil and _oDriveSelf.cameraModeManager ~= nil then
      local nTerr = _oDriveSelf.cameraModeManager:GetVoxelTerrainID()
      local nHit = _oDriveSelf.voxelterrainAPI:SphereSweep(nTerr, vVehCenter, vDir, nLen, nRadius)
      if nHit ~= nil then
        return false
      end
    end
    return true
  end)
  return bOk and bClear == true
end

local ResolveSeatExitPose = function(_oDriveSelf, _nSeat)
  if _oDriveSelf == nil or _oDriveSelf.nVehicle == nil then
    return nil, nil
  end
  local trVeh = _oDriveSelf.transformAPI and _oDriveSelf.transformAPI:CalculateWorldTransform(_oDriveSelf.nVehicle)
  if trVeh == nil then
    return nil, nil
  end
  local tOffsets = GetSeatOffsetsForVehicle(_oDriveSelf.nVehicle)
  local tCands = Vehicles.ComputeExitCandidates(_nSeat or 1, tOffsets, trVeh)
  local nWalkH = WalkingHeight()
  local nVehYaw = ExtractTransformYPR(trVeh)
  local vYPR = Vector3:new(nVehYaw, 0, 0)
  for _, c in ipairs(tCands) do
    local vEye = Vector3:new(c.x, c.y + nWalkH, c.z)
    if CheckExitClear(_oDriveSelf, vEye) then
      return vEye, vYPR
    end
  end
  return nil, nil
end

-- ---- vanilla wraps: DriveVehicleUIMode, VehicleCamera, PhotoUIMode, WalkingCameraUIMode ----------

local AddVehiclePrompts = function()
  local GameDatabase = require("Database.GameDatabase")
  local tEmpty = GameDatabase.GetButtonPromptData("Empty")
  local tDrive = type(tEmpty) == "table" and tEmpty.DriveVehicle
  if type(tDrive) ~= "table" then
    return false
  end
  local EnsurePrompt = function(_tList, _tPrompt)
    if type(_tList) ~= "table" then
      return
    end
    for _, tE in ipairs(_tList) do
      if tE.sLogicalControl == _tPrompt.sLogicalControl then
        return
      end
    end
    local tCopy = {}
    for k, v in pairs(_tPrompt) do
      tCopy[k] = v
    end
    table.insert(_tList, math.max(1, #_tList), tCopy)
  end
  EnsurePrompt(tDrive.tMouse, c_tSwapPromptMouse)
  EnsurePrompt(tDrive.tMouse, c_tLightsPrompt)
  EnsurePrompt(tDrive.tGamepad, c_tSwapPromptPad)
  EnsurePrompt(tDrive.tGamepad, c_tLightsPrompt)
  Log("added Swap Seat (Q / DPad Up) and Headlights (L) prompts to DriveVehicle")
  return true
end

local InstallDriveModeWrap = function()
  local bOk, DriveVehicleUIMode = pcall(require, "Editors.Vehicle.DriveVehicleUIMode")
  if not bOk or type(DriveVehicleUIMode) ~= "table" or
    rawget(DriveVehicleUIMode, "__PZ2CoopVehOrigIn") ~= nil then
    return
  end
  local fnOrigIn = DriveVehicleUIMode.TransitionIn
  local fnOrigOut = DriveVehicleUIMode.TransitionOut
  local fnOrigAdv = DriveVehicleUIMode.Advance
  local fnOrigRun = DriveVehicleUIMode.Run
  local fnOrigSwitch = DriveVehicleUIMode.SwitchCamera
  rawset(DriveVehicleUIMode, "__PZ2CoopVehOrigIn", fnOrigIn)
  rawset(DriveVehicleUIMode, "__PZ2CoopVehOrigOut", fnOrigOut)
  rawset(DriveVehicleUIMode, "__PZ2CoopVehOrigAdv", fnOrigAdv)
  rawset(DriveVehicleUIMode, "__PZ2CoopVehOrigRun", fnOrigRun)
  rawset(DriveVehicleUIMode, "__PZ2CoopVehOrigSwitch", fnOrigSwitch)

  DriveVehicleUIMode.TransitionIn = function(self, _tParams, ...)
    local tParams = type(_tParams) == "table" and _tParams or {}
    local nSeat = tonumber(tParams.nSeat) or s.nPendingEnterSeat or 1
    s.nPendingEnterSeat = nil
    if nSeat < 1 or nSeat > 4 or math.floor(nSeat) ~= nSeat then
      nSeat = 1
    end
    if IsSeatOccupiedByOther(nSeat, "local") then
      local nAlt = Vehicles.NextAvailableSeat(nSeat, s.tSeats, "local")
      if nAlt == nil then
        ShowToast("Vehicle is full", "Red")
        pcall(function() require("Editors.Shared.BaseUIMode").SetNewMode("WalkingCamera", {}) end)
        return
      end
      nSeat = nAlt
    end
    if tParams.bThirdPersonCamera == nil and Presence.IsThirdPerson ~= nil then
      tParams.bThirdPersonCamera = Presence.IsThirdPerson()
    end

    -- Temporarily mark desired seat BEFORE fnOrigIn calls SwitchCamera.
    s.nLocalSeat = nSeat
    s.nVehicle = tParams.nVehicle
    s.bHasVehicle = tParams.nVehicle ~= nil
    s.tDriveModeSelf = self
    s.bInPhotoFromVehicle = false
    s.bSwapKeyWasDown = false
    s.bLightsKeyWasDown = false
    local tSession = Bridge.GetSession()
    AssignPeerToSeat("local", nSeat, tSession and tSession.sSelf or "You")

    local r = fnOrigIn(self, tParams, ...)

    -- Register gamepad DPad Up context for Swap Seat.
    if self.inputManager ~= nil and self.inputManager.CreateGamepadTemporaryContext ~= nil then
      pcall(self.inputManager.CreateGamepadTemporaryContext, self.inputManager, "PZ2CoopVehiclePad", {
        tButtons = {Vehicle_SwitchAmmo_Prev = "Vehicle_SwitchAmmo_Prev"},
      }, 41)
    end

    -- Apply exact seat mode, camera, & 1P/3P body visibility (keeps driver body visible in 1P with head-only hidden).
    if nSeat ~= 1 then
      ApplyLocalSeatMode(self, nil, nSeat)
    else
      s.bThirdPerson = self.bThirdPersonCamera == true
      EnsureDriverAvatar(self)
    end

    SendVehicleEvent({op = "seat", seat = nSeat})
    Log("entered vehicle " .. tostring(self.nVehicle) .. " in seat " .. tostring(nSeat) ..
      " (" .. c_tSeatDefs[nSeat].label .. ")")
    return r
  end

  DriveVehicleUIMode.TransitionOut = function(self, ...)
    if self.inputManager ~= nil and self.inputManager.RemoveGamepadTemporaryContext ~= nil then
      pcall(self.inputManager.RemoveGamepadTemporaryContext, self.inputManager, "PZ2CoopVehiclePad")
    end
    s.tDriverAvatarBuild = nil
    -- Hide driver avatar ONCE via ref-count tracker; clear self.nAvatar across fnOrigOut so vanilla doesn't double-hide!
    SetDriverAvatarState(self, false, false)
    local nSavedAvatar = self.nAvatar
    self.nAvatar = nil
    local bToPhoto = s.bInPhotoFromVehicle == true
    if not bToPhoto then
      ReleaseAutoGate()
      RestoreVehicleIgnoredCollisions(self.nVehicle)
      if Presence.SetVehicleOwnOverride ~= nil then
        Presence.SetVehicleOwnOverride(nil)
      end
      ClearPeerFromSeats("local")
      s.nLocalSeat = nil
      s.tCamGlide = nil
      SendVehicleEvent({op = "seat", seat = 0})
    end
    s.bSwapKeyWasDown = false
    s.bLightsKeyWasDown = false
    s.bExitInFlight = false
    s.tDriveModeSelf = nil
    local r = fnOrigOut(self, ...)
    self.nAvatar = nSavedAvatar
    return r
  end

  DriveVehicleUIMode.SwitchCamera = function(self, _bThirdPersonCamera, ...)
    local bThird = _bThirdPersonCamera == true
    s.bThirdPerson = bThird
    self.bThirdPersonCamera = bThird
    if Presence.SetThirdPerson ~= nil and (Presence.IsThirdPerson == nil or Presence.IsThirdPerson() ~= bThird) then
      Presence.SetThirdPerson(bThird)
    end
    local nSeat = s.nLocalSeat or 1
    ApplyLocalSeatMode(self, nSeat, nSeat, true)
  end

  DriveVehicleUIMode.Advance = function(self, _nDeltaTime, _nUnscaledDeltaTime, ...)
    local r = fnOrigAdv(self, _nDeltaTime, _nUnscaledDeltaTime, ...)
    pcall(function()
      -- Step asynchronous SeatDriver StartScreenAvatar builder if running.
      StepDriverAvatarBuild(self, _nUnscaledDeltaTime)
      -- Vanilla Advance only drives steering arm animations in 3P; also drive them in 1P since driver body is visible!
      if s.nLocalSeat == 1 and self.nAvatar ~= nil and not self.bThirdPersonCamera and
        self.vehiclesAPI ~= nil and self.motiongraphAPI ~= nil then
        local nSteering = self.vehiclesAPI:GetSteeringWheel(self.nVehicle) or 0
        if nSteering < 0 then
          self.motiongraphAPI:SetVariable(self.nAvatar, "steerLeft", -nSteering)
          self.motiongraphAPI:SetVariable(self.nAvatar, "steerRight", 0)
        elseif nSteering > 0 then
          self.motiongraphAPI:SetVariable(self.nAvatar, "steerLeft", 0)
          self.motiongraphAPI:SetVariable(self.nAvatar, "steerRight", nSteering)
        else
          self.motiongraphAPI:SetVariable(self.nAvatar, "steerLeft", 0)
          self.motiongraphAPI:SetVariable(self.nAvatar, "steerRight", 0)
        end
      end
      -- Advance cabin camera glide timer.
      if s.tCamGlide ~= nil then
        local nDt = (type(_nUnscaledDeltaTime) == "number" and _nUnscaledDeltaTime > 0) and _nUnscaledDeltaTime or (1 / 60)
        s.tCamGlide.elapsed = s.tCamGlide.elapsed + nDt
        if s.tCamGlide.elapsed >= s.tCamGlide.dur then
          s.tCamGlide = nil
        end
      end
      -- Keep passenger avatar seated smoothly at vehicle's local seat transform & live-calibrate neck height.
      if s.nLocalSeat ~= nil and s.nLocalSeat ~= 1 then
        SyncOwnPassengerAvatar(self.nVehicle)
      end
      -- Auto-open guest/safari/habitat gates when facing the entrance & enable portal pass-through.
      StepAutoGates(self.nVehicle)
      StepVehiclePortalPassThrough(self.nVehicle)
      -- Reinforce manual ON headlight state vs daytime NightLighting.
      StepNativeHeadlights(self.nVehicle)
    end)
    return r
  end

  -- Replace Run coroutine to add rising-edge debounced Q (GameCamera_Down ONLY, never Ctrl!) / DPad Up seat swap,
  -- L native headlights toggle, passenger Photo Mode seat handoff, side-aware door exits, and emote-wheel click-blocking.
  DriveVehicleUIMode.Run = function(self)
    local BaseUIMode = require("Editors.Shared.BaseUIMode")
    while true do
      local bPaused = self.mainHUD ~= nil and self.mainHUD:GetFullScreenUIPause()
      local bWheelBlocked = false
      pcall(function()
        local Actions = require("PZ2Coop.Actions")
        if Actions ~= nil and Actions.IsWheelBlockingInput ~= nil then
          bWheelBlocked = Actions.IsWheelBlockingInput()
        end
      end)
      if not bPaused and not bWheelBlocked and self.inputManager ~= nil then
        local inp = self.inputManager
        local bSwapDown = false
        local bLightsDown = false
        pcall(function()
          local bHornDown = (inp.GetKeyDown ~= nil and inp:GetKeyDown("Car_Horn") == true) or
            (inp.GetKeyPressed ~= nil and inp:GetKeyPressed("Car_Horn") == true)
          local bQDown = (inp:GetKeyPressed("GameCamera_Down") == true) or
            (inp.GetKeyDown ~= nil and inp:GetKeyDown("GameCamera_Down") == true)
          local bPadSwap = inp.GetGamepadButtonDown ~= nil and inp:GetGamepadButtonDown("Vehicle_SwitchAmmo_Prev") == true
          bSwapDown = (bQDown and not bHornDown) or bPadSwap
          bLightsDown = (inp:GetKeyPressed("GameCamera_Torch") == true) or
            (inp.GetKeyDown ~= nil and inp:GetKeyDown("GameCamera_Torch") == true)
        end)
        local nNow = s.nClock or 0
        local bSwapTrigger = bSwapDown and not s.bSwapKeyWasDown and (nNow - (s.nLastSwapAt or -10)) >= c_nSwapCooldown
        local bLightsTrigger = bLightsDown and not s.bLightsKeyWasDown and (nNow - (s.nLastLightsAt or -10)) >= c_nLightsCooldown
        s.bSwapKeyWasDown = bSwapDown
        s.bLightsKeyWasDown = bLightsDown

        if bSwapTrigger then
          s.nLastSwapAt = nNow
          Vehicles.SwapToNextSeat()
        elseif bLightsTrigger then
          s.nLastLightsAt = nNow
          Vehicles.ToggleHeadlights()
        elseif inp:GetKeyPressed("GameCamera_PhotoMode") then
          s.nPhotoReturnSeat = s.nLocalSeat or 1
          s.bInPhotoFromVehicle = true
          BaseUIMode.SetNewMode("Photo", {
            nVehicle = self.nVehicle,
            nSeat = s.nLocalSeat or 1,
            bThirdPersonCamera = self.bThirdPersonCamera,
          })
        elseif inp:GetKeyPressed("Vehicle_Respawn") then
          if s.nLocalSeat == 1 or not IsSeatOccupiedByOther(1, "local") then
            self.vehiclesAPI:TeleportVehicleToSpawnPoint(self.nVehicle)
            self:SwitchCamera(self.bThirdPersonCamera)
            SendVehicleEvent({op = "respawn"})
          else
            PlayUiSound("Staff_Invalid_Placement")
            ShowToast("Only the driver can respawn the vehicle", "Red")
          end
        elseif inp:GetKeyPressed("Vehicle_ExitVehicle") then
          if not s.bExitInFlight then
            local vStartPos, vStartYPR = ResolveSeatExitPose(self, s.nLocalSeat or 1)
            if vStartPos == nil then
              -- Fallback to vanilla ExitPoint check
              local nExitEntity = api.entity.FindEntityByName("ExitPoint", self.nVehicle)
              if nExitEntity ~= nil then
                local exitTr = self.transformAPI:CalculateWorldTransform(nExitEntity)
                local vPos = exitTr:GetPos() + exitTr:GetU() * WalkingHeight()
                if self:ExitVehicle(vPos) then
                  vStartPos = vPos
                  vStartYPR = exitTr:GetOr():ToYawPitchRoll():WithY(0):WithZ(0)
                end
              end
            end
            if vStartPos ~= nil then
              s.bExitInFlight = true
              local fnSwitchToWalk = function()
                s.bExitInFlight = false
                if s.nLocalSeat ~= nil then
                  BaseUIMode.SetNewMode("WalkingCamera", {vStartingPos = vStartPos, vStartingYPR = vStartYPR})
                end
              end
              if Presence.BeginVehicleExit ~= nil then
                Presence.BeginVehicleExit(vStartPos, vStartYPR, fnSwitchToWalk)
              else
                if Presence.PrepareVehicleExit ~= nil then
                  Presence.PrepareVehicleExit(vStartPos, vStartYPR)
                end
                fnSwitchToWalk()
              end
            elseif self.cashSpentPopupManager ~= nil then
              self.cashSpentPopupManager:CreateFailurePopup({bObstructed = true})
            end
          end
        elseif inp:GetKeyPressed("GameCamera_ToggleThirdPerson") then
          self:SwitchCamera(not self.bThirdPersonCamera)
        else
          self:HandleBackButton()
        end
      end
      coroutine.yield()
    end
  end

  Log("DriveVehicleUIMode wrapped (4-seat passenger mode, Q swap, L headlights, side-aware exits)")
end

-- Wraps VehicleCamera.Advance to anchor 1P passenger camera at the seat's cabin eye position with smooth seat-swap glide.
local InstallVehicleCameraWrap = function()
  local bOk, VehicleCamera = pcall(require, "Components.Cameras.VehicleCamera")
  if not bOk or type(VehicleCamera) ~= "table" or rawget(VehicleCamera, "__PZ2CoopVehOrigAdvance") ~= nil then
    return
  end
  local fnOrigAdv = VehicleCamera.Advance
  rawset(VehicleCamera, "__PZ2CoopVehOrigAdvance", fnOrigAdv)
  VehicleCamera.Advance = function(_tData, _tWorldAPIs, _nUnscaledDt, _nDt)
    fnOrigAdv(_tData, _tWorldAPIs, _nUnscaledDt, _nDt)
    if _tData == nil or _tData.tVehicleData == nil or _tData.tFinal == nil then
      return
    end
    local nVeh = _tData.tVehicleData.nVehicle
    local nSeat = s.nLocalSeat
    if nVeh == nil or nSeat == nil then
      return
    end
    if nSeat == 1 and s.tCamGlide == nil then
      return -- vanilla Driver 1P camera with no active glide
    end
    pcall(function()
      local trApi = _tWorldAPIs and _tWorldAPIs.transform
      if trApi == nil or not trApi:HasTransform(nVeh) then
        return
      end
      local trVeh = trApi:CalculateWorldTransform(nVeh)
      local tOffsets = GetSeatOffsetsForVehicle(nVeh)
      local tOff = tOffsets[nSeat]
      if trVeh == nil or tOff == nil then
        return
      end
      local lx, ly, lz = tOff.eye.x, tOff.eye.y, tOff.eye.z
      if s.tCamGlide ~= nil then
        local u = Clamp(s.tCamGlide.elapsed / math.max(0.01, s.tCamGlide.dur), 0, 1)
        local w = 1 - (1 - u) * (1 - u) * (1 - u) -- cubic ease-out
        lx = s.tCamGlide.fromX + (s.tCamGlide.toX - s.tCamGlide.fromX) * w
        ly = s.tCamGlide.fromY + (s.tCamGlide.toY - s.tCamGlide.fromY) * w
        lz = s.tCamGlide.fromZ + (s.tCamGlide.toZ - s.tCamGlide.fromZ) * w
      end
      local wx, wy, wz = LocalToWorldPoint(trVeh, lx, ly, lz)
      if wx == nil then
        return
      end
      local tFinal = _tData.tFinal
      tFinal.baseTransQ = TransformQ.FromOrPos(trVeh:GetOr(), Vector3:new(wx, wy, wz))
      if VehicleCamera.StabilizeBaseTransform ~= nil then
        VehicleCamera.StabilizeBaseTransform(_tData)
      end
      -- Allow wide passenger sightseeing look-around (+/-115 deg) in 1P cabin view.
      if nSeat ~= 1 and not _tData.tVehicleData.bPhoto and tFinal.vCameraYPR ~= nil then
        local cy, cp, cr = ReadVec3(tFinal.vCameraYPR)
        if cy ~= nil then
          tFinal.vCameraYPR = Vector3:new(Clamp(cy, -c_nPassengerYawClamp, c_nPassengerYawClamp), cp or 0, cr or 0)
        end
      end
      local CameraLogic = require("Components.Cameras.CameraLogic")
      if CameraLogic ~= nil and CameraLogic.ApplyFinal ~= nil then
        CameraLogic.ApplyFinal(_tData, _tWorldAPIs)
      end
    end)
  end
  Log("VehicleCamera wrapped (per-seat 1P cabin camera + 0.25s glide)")
end

-- Wraps PhotoUIMode so entering Photo Mode (F) from a passenger seat returns cleanly to that same seat.
local InstallPhotoModeWrap = function()
  local bOk, PhotoUIMode = pcall(require, "Editors.Cameras.PhotoUIMode")
  if not bOk or type(PhotoUIMode) ~= "table" or rawget(PhotoUIMode, "__PZ2CoopVehOrigInit") ~= nil then
    return
  end
  local fnOrigInit = PhotoUIMode.Init
  local fnOrigExit = PhotoUIMode.ExitMode
  rawset(PhotoUIMode, "__PZ2CoopVehOrigInit", fnOrigInit)
  rawset(PhotoUIMode, "__PZ2CoopVehOrigExit", fnOrigExit)

  PhotoUIMode.Init = function(self, _entityID, _tParams, ...)
    local r = fnOrigInit(self, _entityID, _tParams, ...)
    if type(_tParams) == "table" and _tParams.nSeat ~= nil then
      self.nSeat = _tParams.nSeat
    elseif s.nPhotoReturnSeat ~= nil then
      self.nSeat = s.nPhotoReturnSeat
    end
    return r
  end

  PhotoUIMode.ExitMode = function(self, ...)
    if self.bSummaryOpen then
      return
    end
    if self.nVehicle ~= nil and self.nSeat ~= nil then
      s.nPendingEnterSeat = self.nSeat
      s.nPhotoReturnSeat = nil
      s.bInPhotoFromVehicle = false
      require("Editors.Shared.BaseUIMode").SetNewMode("DriveVehicle", {
        nVehicle = self.nVehicle,
        nSeat = self.nSeat,
        bThirdPersonCamera = self.bThirdPersonCamera,
      })
      return
    end
    return fnOrigExit(self, ...)
  end
  Log("PhotoUIMode wrapped (preserves passenger seat on exit)")
end

-- Wraps WalkingCameraUIMode._DriveVehicle so pressing E near a specific seat enters THAT exact seat.
local InstallWalkEntryWrap = function()
  local bOk, WalkingCameraUIMode = pcall(require, "Editors.Cameras.WalkingCameraUIMode")
  if not bOk or type(WalkingCameraUIMode) ~= "table" or
    rawget(WalkingCameraUIMode, "__PZ2CoopVehOrigDrive") ~= nil then
    return
  end
  local fnOrigDrive = WalkingCameraUIMode._DriveVehicle
  rawset(WalkingCameraUIMode, "__PZ2CoopVehOrigDrive", fnOrigDrive)
  WalkingCameraUIMode._DriveVehicle = function(self, _nEntityID, ...)
    local tHover = s.tHoveredPrompt
    if tHover ~= nil and tHover.nVehicle == _nEntityID then
      if tHover.bFull then
        PlayUiSound("Staff_Invalid_Placement")
        ShowToast("Vehicle is full", "Red")
        return
      end
      s.nPendingEnterSeat = tHover.nSeat or 1
      require("Editors.Shared.BaseUIMode").SetNewMode("DriveVehicle", {
        nVehicle = _nEntityID,
        nSeat = tHover.nSeat or 1,
        bThirdPersonCamera = Presence.IsThirdPerson and Presence.IsThirdPerson() or nil,
      })
      return
    end
    return fnOrigDrive(self, _nEntityID, ...)
  end
  Log("WalkingCameraUIMode._DriveVehicle wrapped (enters closest hovered seat)")
end

-- ---- 20 Hz co-op vehicle sync & trust-boundary packet validation ---------------------------------

Vehicles.ValidatePosePacket = function(_d)
  if type(_d) ~= "table" or _d.k ~= "vpose" then
    return nil
  end
  if not (IsFinite(_d.x) and IsFinite(_d.y) and IsFinite(_d.z) and
    IsFinite(_d.yaw) and IsFinite(_d.pitch) and IsFinite(_d.roll)) then
    return nil
  end
  local nSpd = IsFinite(_d.spd) and Clamp(_d.spd, -40, 60) or 0
  local nSteer = IsFinite(_d.steer) and Clamp(_d.steer, -1, 1) or 0
  return {
    x = _d.x, y = _d.y, z = _d.z,
    yaw = WrapAngle(_d.yaw),
    pitch = Clamp(_d.pitch, -1.5, 1.5),
    roll = Clamp(_d.roll, -1.5, 1.5),
    spd = nSpd,
    steer = nSteer,
  }
end

Vehicles.ValidateEventPacket = function(_d)
  if type(_d) ~= "table" or _d.k ~= "vehicle" or type(_d.op) ~= "string" then
    return nil
  end
  local sOp = _d.op
  if sOp == "seat" then
    local nSeat = tonumber(_d.seat)
    if nSeat == nil or math.floor(nSeat) ~= nSeat or nSeat < 0 or nSeat > 4 then
      return nil
    end
    return {op = "seat", seat = nSeat}
  elseif sOp == "lights" then
    return {op = "lights", on = _d.on == true}
  elseif sOp == "respawn" then
    return {op = "respawn"}
  elseif sOp == "recall" then
    if not (IsFinite(_d.x) and IsFinite(_d.y) and IsFinite(_d.z)) then
      return nil
    end
    local nYaw = IsFinite(_d.yaw) and WrapAngle(_d.yaw / 1000) or 0
    return {op = "recall", outpost = _d.outpost == true, x = _d.x / 100, y = _d.y / 100, z = _d.z / 100, yaw = nYaw}
  end
  return nil
end

local SendDriverPose = function()
  if s.nLocalSeat ~= 1 or s.nVehicle == nil then
    return
  end
  if Bridge.GetRole() == "none" or not (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    return
  end
  pcall(function()
    local tWorld = WorldAPIs()
    local trVeh = tWorld and tWorld.transform and tWorld.transform:CalculateWorldTransform(s.nVehicle)
    if trVeh == nil then
      return
    end
    local x, y, z = ReadVec3(trVeh.GetPos and trVeh:GetPos() or trVeh:Pos())
    if x == nil then
      return
    end
    local yaw, pitch, roll = ExtractTransformYPR(trVeh)
    local nSpd = tWorld.vehicles and tWorld.vehicles.GetVehicleSpeed and tWorld.vehicles:GetVehicleSpeed(s.nVehicle) or 0
    local nSteer = tWorld.vehicles and tWorld.vehicles.GetSteeringWheel and tWorld.vehicles:GetSteeringWheel(s.nVehicle) or 0
    Bridge.SendPacket(c_nVehiclePosePacket, nil, {
      k = "vpose",
      x = x, y = y, z = z,
      yaw = yaw, pitch = pitch, roll = roll,
      spd = nSpd, steer = nSteer,
    })
  end)
end

local StepRemoteVehiclePose = function(_nDt, _nVehicle)
  if s.nLocalSeat == 1 or s.tRemotePose == nil or _nVehicle == nil then
    return
  end
  local nAge = (s.nClock or 0) - (s.tRemotePose.rxAt or 0)
  if nAge > c_nPoseTimeout then
    s.tRemotePose = nil
    s.tSmoothPose = nil
    return
  end
  local rp = s.tRemotePose
  local sp = s.tSmoothPose
  if sp == nil or ((rp.x - sp.x) ^ 2 + (rp.y - sp.y) ^ 2 + (rp.z - sp.z) ^ 2) > (c_nPoseSnapDist * c_nPoseSnapDist) then
    s.tSmoothPose = {x = rp.x, y = rp.y, z = rp.z, yaw = rp.yaw, pitch = rp.pitch, roll = rp.roll}
  else
    local nDt = (type(_nDt) == "number" and _nDt > 0) and math.min(_nDt, 0.1) or (1 / 60)
    local k = 1 - math.exp(-c_nPoseSmoothRate * nDt)
    sp.x = sp.x + (rp.x - sp.x) * k
    sp.y = sp.y + (rp.y - sp.y) * k
    sp.z = sp.z + (rp.z - sp.z) * k
    sp.yaw = WrapAngle(sp.yaw + WrapAngle(rp.yaw - sp.yaw) * k)
    sp.pitch = sp.pitch + (rp.pitch - sp.pitch) * k
    sp.roll = sp.roll + (rp.roll - sp.roll) * k
  end
  sp = s.tSmoothPose
  pcall(function()
    local trApi = WorldAPIs() and WorldAPIs().transform
    if trApi ~= nil and trApi.SetTransform ~= nil then
      trApi:SetTransform(_nVehicle, PoseTransform(sp.x, sp.y, sp.z, sp.yaw, sp.pitch, sp.roll))
    end
  end)
end

-- ---- UI recall commands --------------------------------------------------------------------------

Vehicles.QueueUICommand = function(_sCmd, _sArg)
  s.tPendingCmd = {cmd = _sCmd, arg = _sArg}
end

-- ---- lifecycle & packet dispatch -----------------------------------------------------------------

Vehicles.Install = function()
  if s.bInstalled then
    return
  end
  s.bInstalled = true
  InstallDriveModeWrap()
  InstallVehicleCameraWrap()
  InstallPhotoModeWrap()
  InstallWalkEntryWrap()
  if Presence.SetVehiclePromptProvider ~= nil then
    Presence.SetVehiclePromptProvider(Vehicles.FindClosestSeatPrompt)
  end
  -- Remove car-specific forced boundaries (4..25 m lookahead auto-brake & habitat keep-out)
  -- in Sandbox/Challenge/Career parks while leaving real physical wall collisions intact.
  if Bridge.SendCommand ~= nil then
    Bridge.SendCommand("veh_bounds", {remove = "1"})
  end
  Log("installed")
end

Vehicles.Uninstall = function()
  if Bridge.SendCommand ~= nil then
    Bridge.SendCommand("veh_bounds", {remove = "0"})
  end
  ReleaseAutoGate()
  RestoreVehicleIgnoredCollisions(s.nVehicle)
  ReleaseHeadlightDisableClaims()
  if Presence.SetVehiclePromptProvider ~= nil then
    Presence.SetVehiclePromptProvider(nil)
  end
  if Presence.SetVehicleOwnOverride ~= nil then
    Presence.SetVehicleOwnOverride(nil)
  end
  if Presence.SetVehicleFriendOverride ~= nil then
    Presence.SetVehicleFriendOverride(nil)
  end
  s.bInstalled = false
  s.nLocalSeat = nil
  s.tSeats = {}
  s.tDriveModeSelf = nil
  s.tDriverAvatarBuild = nil
  s.tDriverHiddenState = {}
  s.tLiveSitNeck = nil
  s.tHoveredPrompt = nil
  s.tRemotePose = nil
  s.tSmoothPose = nil
  s.bHeadlightsOn = false
  s.bHeadlightsManual = false
  s.bSwapKeyWasDown = false
  s.bLightsKeyWasDown = false
  s.bExitInFlight = false
end

Vehicles.Reset = function()
  ReleaseAutoGate()
  RestoreVehicleIgnoredCollisions(s.nVehicle)
  ReleaseHeadlightDisableClaims()
  s.nVehicle = nil
  s.bHasVehicle = false
  s.nLocalSeat = nil
  s.nPendingEnterSeat = nil
  s.nPhotoReturnSeat = nil
  s.bInPhotoFromVehicle = false
  s.tSeats = {}
  s.tSeatCache = {}
  s.tLiveSitNeck = nil
  s.bCalibLogged = false
  s.bNeckCalibLogged = false
  s.tDriverAvatarBuild = nil
  s.tDriverHiddenState = {}
  s.tHoveredPrompt = nil
  s.tDriveModeSelf = nil
  s.tCamGlide = nil
  s.bHeadlightsOn = false
  s.bHeadlightsManual = false
  s.tRemotePose = nil
  s.tSmoothPose = nil
  s.bPromptsAdded = false
  s.bSwapKeyWasDown = false
  s.bLightsKeyWasDown = false
  s.nLastSwapAt = -10.0
  s.nLastLightsAt = -10.0
  s.tPendingCmd = nil
  if Presence.SetVehicleOwnOverride ~= nil then
    Presence.SetVehicleOwnOverride(nil)
  end
  if Presence.SetVehicleFriendOverride ~= nil then
    Presence.SetVehicleFriendOverride(nil)
  end
end

Vehicles.OnPeerConnected = function()
  if s.nLocalSeat ~= nil then
    SendVehicleEvent({op = "seat", seat = s.nLocalSeat})
  end
  if s.bHeadlightsManual then
    SendVehicleEvent({op = "lights", on = s.bHeadlightsOn})
  end
  if s.nLocalSeat == 1 then
    SendDriverPose()
  end
end

Vehicles.OnPeerDisconnected = function()
  ClearPeerFromSeats("friend")
  s.tRemotePose = nil
  s.tSmoothPose = nil
  if Presence.SetVehicleFriendOverride ~= nil then
    Presence.SetVehicleFriendOverride(nil)
  end
end

Vehicles.Update = function(_nDt, _bActive)
  if not s.bInstalled then
    return
  end
  local nDt = type(_nDt) == "number" and _nDt > 0 and _nDt or (1 / 60)
  s.nClock = (s.nClock or 0) + nDt

  if not s.bPromptsAdded then
    local bOk, bAdded = pcall(AddVehiclePrompts)
    s.bPromptsAdded = bOk and bAdded == true
  end

  -- Periodically discover Research Outpost / Vehicle presence so Co-op Recall stays accurate.
  s.nVehicleScanTimer = (s.nVehicleScanTimer or 0) - nDt
  if s.nVehicleScanTimer <= 0 then
    s.nVehicleScanTimer = 1.0
    DiscoverVehicleEntity()
  end

  -- Execute deferred Co-op menu commands (vehicle recall).
  if s.tPendingCmd ~= nil then
    local tCmd = s.tPendingCmd
    s.tPendingCmd = nil
    if tCmd.cmd == "vrecall" then
      Vehicles.RecallVehicle(tCmd.arg == "outpost")
    end
  end

  local nVeh = s.nVehicle or (s.bHasVehicle and DiscoverVehicleEntity() or nil)

  -- Broadcast 20 Hz vehicle pose while we are driving.
  if _bActive and s.nLocalSeat == 1 and nVeh ~= nil then
    s.nPoseSendTimer = (s.nPoseSendTimer or 0) - nDt
    if s.nPoseSendTimer <= 0 then
      s.nPoseSendTimer = c_nPoseSendInterval
      SendDriverPose()
    end
  end

  -- Apply remote driver's interpolated vehicle pose, friend occupant avatar placement, & manual native headlights.
  StepDriverAvatarBuild(s.tDriveModeSelf, nDt)
  if nVeh ~= nil then
    StepRemoteVehiclePose(nDt, nVeh)
    SyncFriendVehicleAvatar(nVeh)
    StepNativeHeadlights(nVeh)
  end
end

Vehicles.OnPacket = function(_tMsg)
  if type(_tMsg) ~= "table" or type(_tMsg.tData) ~= "table" then
    return false
  end
  -- Unreliable 20 Hz vehicle pose (0x13)
  if _tMsg.nType == c_nVehiclePosePacket then
    local tPose = Vehicles.ValidatePosePacket(_tMsg.tData)
    if tPose == nil then
      return true
    end
    -- Never override our own vehicle while we are driving (incl. solo loopback).
    if s.nLocalSeat == 1 then
      return true
    end
    tPose.rxAt = s.nClock or 0
    s.tRemotePose = tPose
    return true
  end
  -- Reliable vehicle events on 0x12 (k = "vehicle")
  if _tMsg.nType == c_nVehicleEventPacket and _tMsg.tData.k == "vehicle" then
    local tEv = Vehicles.ValidateEventPacket(_tMsg.tData)
    if tEv == nil then
      return true
    end
    -- In solo loopback, never treat our own echoed seat packet as a separate friend locking our seat.
    if Bridge.IsLoopback() and tEv.op == "seat" then
      return true
    end
    local nVeh = DiscoverVehicleEntity()
    if tEv.op == "seat" then
      if tEv.seat == 0 then
        ClearPeerFromSeats("friend")
        s.tRemotePose = nil
        s.tSmoothPose = nil
        if Presence.SetVehicleFriendOverride ~= nil then
          Presence.SetVehicleFriendOverride(nil)
        end
        Log("friend exited vehicle")
      else
        local tSession = Bridge.GetSession()
        local sName = (tSession and tSession.sPartner and tSession.sPartner ~= "") and tSession.sPartner or "Friend"
        -- If friend somehow claimed the seat we're in (simultaneous race), non-host yields to next free seat.
        if s.nLocalSeat == tEv.seat and Bridge.GetRole() == "client" then
          local nNext = Vehicles.NextAvailableSeat(s.nLocalSeat, s.tSeats, "local")
          if nNext ~= nil then
            Vehicles.SwapToSeat(nNext)
          end
        end
        AssignPeerToSeat("friend", tEv.seat, sName)
        Log("friend entered seat " .. tostring(tEv.seat) .. " (" .. c_tSeatDefs[tEv.seat].label .. ")")
      end
    elseif tEv.op == "lights" then
      ApplyHeadlights(tEv.on, nVeh)
    elseif tEv.op == "respawn" then
      if nVeh ~= nil then
        pcall(function()
          local tWorld = WorldAPIs()
          if tWorld ~= nil and tWorld.vehicles ~= nil and tWorld.vehicles.TeleportVehicleToSpawnPoint ~= nil then
            tWorld.vehicles:TeleportVehicleToSpawnPoint(nVeh)
          end
        end)
      end
      s.tRemotePose = nil
      s.tSmoothPose = nil
    elseif tEv.op == "recall" then
      if nVeh ~= nil and s.nLocalSeat ~= 1 then
        pcall(function()
          local tWorld = WorldAPIs()
          if tEv.outpost and tWorld ~= nil and tWorld.vehicles ~= nil and
            tWorld.vehicles.TeleportVehicleToSpawnPoint ~= nil then
            tWorld.vehicles:TeleportVehicleToSpawnPoint(nVeh)
          elseif tWorld ~= nil and tWorld.transform ~= nil and tWorld.transform.SetTransform ~= nil then
            tWorld.transform:SetTransform(nVeh, PoseTransform(tEv.x, tEv.y, tEv.z, tEv.yaw, 0, 0))
          end
        end)
      end
      s.tRemotePose = nil
      s.tSmoothPose = nil
    end
    return true
  end
  return false
end

-- ---- public queries ------------------------------------------------------------------------------

Vehicles.HasVehicle = function()
  return s.bHasVehicle == true
end

Vehicles.IsLocalInVehicle = function()
  return s.nLocalSeat ~= nil
end

Vehicles.IsLocalPassenger = function()
  return s.nLocalSeat ~= nil and s.nLocalSeat >= 2 and s.nLocalSeat <= 4
end

Vehicles.GetLocalSeat = function()
  return s.nLocalSeat
end

Vehicles.GetState = function()
  return s
end

Vehicles.GetSeatDefs = function()
  return c_tSeatDefs
end
