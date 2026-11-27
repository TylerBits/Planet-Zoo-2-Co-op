-- PZ2-Coop presence: see your friend in the zoo and walk around together.
-- Each player sends their camera pose as packet 0x10 (unreliable, newest only, docs/NETWORK_PROTOCOL.md):
--   c* = camera / eye position, p* = ground point (feet while walking, orbit centre while flying),
--   yaw = camera yaw (radians, vYPR:X()), m = 0 flying build camera / 1 walking / 2 walking third person.
-- Third-person & AAA locomotion polish (docs/AAA_AVATAR_LOCOMOTION_PLAN.md Phases 1-2):
--   - Dynamic sprint FOV kick (+6 deg), subtle over-the-shoulder offset (+0.30 m), sprint distance pullback,
--     stride cadence micro-bob, smooth occlusion recovery (instant snap-in, 6/s ease-out)
--   - Speed-scaled turn rate (13 rad/s slow -> 7 rad/s sprint), 180-deg sharp reversal pivot one-shots,
--     procedural corner banking + accel/swim pitch lean, exact ground raycast + water surface buoyancy
--   - Weather-reactive avatar posture (0.5 Hz poll of tWorldAPIs.weather), Photo Mode pose
--   - Velocity-predicted dead-reckoning + spring interpolation for silky-smooth friend movement
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

local Presence = module(...)

local c_nCursor = 0x10
local c_nAvatar = 0x12
local c_nSendInterval = 0.05 -- 20 Hz presence updates (matches CURSOR_TRANSFORM_20HZ)
local c_nAvatarReqInterval = 2.0 -- seconds between avatar_req retries while peer avatar is missing
local c_nFriendTimeout = 5.0
local c_nSmoothRate = 11.0 -- per second tracking rate toward velocity-predicted friend pose
local c_nMaxPredictSec = 0.08 -- bounded dead-reckoning horizon for 20 Hz peer updates
local c_nMaxPeerVel = 12.0 -- m/s clamp on inferred peer velocity
local c_nSnapDistance = 30.0 -- metres: farther jumps (teleport, mode switch) are not smoothed
local c_nSpawnTimeout = 5.0
local c_nAvatarTimeout = 15.0 -- seconds the avatar build coroutine may run (it waits for asset loading)
local c_nMaxAvatarParts = 24
local c_nMaxAvatarFields = 16
local c_nMaxAvatarStr = 64
local c_nLabelHeight = 2.1
local c_nThirdBack = 3.5 -- metres behind the eye
local c_nThirdUp = 0.4
local c_nShoulderOffset = 0.30 -- subtle right-shoulder framing offset (fades to 0 into first person)
local c_nSprintPullback = 0.35 -- extra camera distance while sprinting
local c_nSprintFovAdd = 0.105 -- +6 degrees FOV kick while sprinting
local c_nFovRate = 6.0
local c_nOcclRecoverRate = 6.0 -- smooth camera zoom-out after clearing wall/tree occlusion
local c_nCameraRadius = 0.2 -- kept this far from walls (thirdpersonvehiclecamera.lua nMinDistanceFromWall)
local c_nZoomMin, c_nZoomMax, c_nZoomStep = 1.5, 8.0, 0.85 -- mouse wheel: metres, factor per notch
local c_nFirstPersonSnap = 1.2 -- metres: zooming in closer than this slides into first person
local c_nZoomRate = 8.0 -- per second: how fast the camera distance eases toward the wheel target
local c_nBodyHideDist = 0.9 -- metres: closer than this the camera is near/inside the head, so hide head (or static body fallback)
local c_nFirstPersonBodyBack = 0.16 -- metres: subtle backward body offset in 1P so looking down shows chest/legs instead of hollow neck collar
local c_nFirstPersonSeatEyeFwd = 0.12 -- metres: subtle forward eye nudge while seated in 1P so looking down shows lap/legs cleanly
local c_nFirstPersonBodySlack = math.rad(35) -- standing shoulder glance slack in 1P before body pivots smoothly to follow look yaw
local c_nFollowRate = 12.0 -- per second: how fast the camera's follow point catches up with the player
local c_nFollowSnap = 10.0 -- metres: farther jumps (teleport, mode switch) are not eased
local c_nTurnRateSlow = 13.5 -- rad/s crisp turning while standing/slow walking
local c_nTurnRateFast = 6.0 -- rad/s weighted GTA-style turning arc while sprinting
local c_nTurnMinSpeed = 0.3 -- m/s: slower than this the body keeps its facing
local c_nPivotMinSpeed = 1.2 -- m/s threshold for 180-deg turn one-shot
local c_nSwimDepth = 0.75 -- metres of water above feet before switching to swimming (waist/chest deep)
local c_nSwimWaterlineOffset = 1.25 -- feet sit this far below lake surface so head/shoulders float naturally
local c_nSwimBobAmp = 0.04 -- gentle vertical wave bob in water
local c_nSwimBobFreq = 2.6
local c_nMaxStepUpM = 0.32 -- prevents stepping straight up over short/curved walls (stairs are <= 0.25 m)
local c_nSlopeSubstepM = 0.28 -- horizontal sampling stride when validating continuous uphill slopes/paths while sprinting
local c_nMaxSlopeTan = 1.05 -- ~46.4 deg max continuous walkable slope grade (covers 45 deg stairs/paths & < 49 deg normal limit)
local c_nMinWalkableNormalY = 0.65 -- ~49 deg max walkable slope; rejects steep curved wall faces/bevels
local c_nMinEyeAboveGround = 0.90 -- matches vanilla WalkingCamera HeightLow; prevents camera clipping into floor on sharp crests
local c_nBodyCapsuleRadius = 0.18 -- doorway-friendly body radius (fits single doors & opened habitat gates)
local c_nGateOpenHalfWidth = 1.15 -- passable half-width of an opened standard habitat gate doorway
local c_nGateSmallHalfWidth = 0.70 -- passable half-width of an opened small habitat gate doorway
local c_nGateGuestHalfWidth = 1.50 -- passable half-width of an opened walkthrough guest / glass-tunnel gate
local c_nGateWideHalfWidth = 2.50 -- passable half-width of an opened wide transport / ride airlock gate
local c_nGateOpenHalfDepth = 0.75 -- thickness around gate plane where opened doorway collider is skipped
local c_nGateWideHalfDepth = 1.20 -- deeper clearance for wide transport/ride airlock gates
local c_nGateOpenMinY = -0.35
local c_nGateOpenMaxY = 2.65
local c_nGateSmallMaxY = 2.15
local c_nGateWideMaxY = 3.80
local c_nStopDampRate = 18.0 -- rapid braking decay on vanilla WalkingCamera residual glide when WASD released
local c_nWeatherInterval = 2.0 -- 0.5 Hz weather query
local c_nGoSide = 1.5 -- "Go to friend" lands this far to the friend's right
local c_nExplorePreviewSmoothPos = 24.0 -- snappy cursor tracking for Explore placement avatar
local c_nExplorePreviewSnapDist = 12.0 -- metres: snap immediately on large cursor jumps or first valid hit
local c_nExplorePreviewTurnRate = 10.0 -- rad/s turning to face the overhead camera while held
local c_nExplorePreviewVelRate = 14.0 -- horizontal cursor velocity smoothing for pendulum dangle
local c_nExplorePreviewMaxSpeed = 14.0 -- m/s clamp on cursor sweep speed
local c_nExplorePreviewDangleGain = 0.036 -- rad per m/s cursor velocity (emulates Staff PickedUpDangle tilt)
local c_nExplorePreviewDangleMax = 0.30 -- ~17 deg max pendulum swing angle
local c_nExplorePreviewSpringOmega = 9.0 -- pendulum natural angular frequency (rad/s)
local c_nExplorePreviewSpringZeta = 0.62 -- lightly underdamped for natural swing settle on cursor stop
local c_nExplorePreviewLiftY = 0.0 -- ground-aligned like StaffPlacementMode & GuestPlacementMode ($PickedUp_Loop hovers at +3.1..4.4 m)
local c_nExplorePreviewPivotY = 4.15 -- shoulder suspension height in $PickedUp_Loop so pendulum swings feet below ring center
local c_nExplorePreviewDropWindow = 4.0 -- seconds after placing into Explore to play $PickedUp_Out landing
local c_tPickedUpInDur = {AF = 0.87, AM = 0.80, TF = 0.90, TM = 1.00} -- measured from Guests.ovl
local c_tPickedUpOutDur = {AF = 1.60, AM = 2.00, TF = 1.83, TM = 2.20} -- measured from Guests.ovl
local c_nPickedUpBlendOut = 0.15 -- overlap before end of $PickedUp_In to crossfade into $PickedUp_Loop
local c_nPickedUpLoopBlend = 0.18
local c_nExploreCamEaseDur = 1.60 -- smooth cubic ease-out camera transition from free-cam to third-person player
local c_nExploreDropHandoffTimeout = 1.5 -- safety timeout if WalkingCamera never activates after SetNewMode
local c_vHidden = Vector3:new(0, -1000, 0)
local c_sRing = "Char_Props_PlacementRing"
local c_tSwitchPrompt = {sLocString = "HUD_Controls_SwitchCamera", sLogicalControl = "GameCamera_ToggleThirdPerson",
  sLocation = "HUD_CenterPrompts"}

-- Kept in _G like the other modules' state: the game can re-run module files.
local s = rawget(global, "__PZ2CoopPresenceState")
if s == nil then
  s = {
    nClock = 0,
    nSendTimer = 0,
    nWeatherTimer = 0,
    sWeather = "clear",
    tFriend = nil, -- newest pose {cx,cy,cz, px,py,pz, yaw, m, nAge, vx, vy, vz, nRxAt}
    tShown = nil, -- smoothed pose actually drawn {x,y,z, yaw, ySmooth}
    tFriendRing = nil,
    tFriendAvatarData = nil, -- validated avatar table from packet 0x12
    tFriendBody = nil, -- {tParent = spawn record, oAvatar, co, nAge, nAvatar, bHidden, tAnim}
    tFriendPrev = nil, -- friend feet x/z last frame (for facing while walking)
    nFriendBodyYaw = nil,
    bFriendAvatarFailed = false,
    sAvatarPeerKey = nil, -- last peer/loopback key we sent 0x12 to
    tOwnBody = nil, -- {tParent = spawn record, oAvatar, co, nAge, nAvatar, tAnim}
    tOwnPose = nil, -- set by the third-person camera wrap {x,y,z (feet), yaw, bHidden}
    nOwnGroundY = nil, -- damped exact ground/water height for own avatar
    nOwnSpeed = 0, -- latest own raw horizontal speed
    nOwnSmoothSpeed = 0, -- smoothed own horizontal speed (drives camera FOV kick & cadence bob cleanly)
    nSprintBlend = 0, -- [0,1] smoothed sprint intensity for FOV kick & pullback
    nBobPhase = 0,
    nBobAmp = 0, -- eased stride bob amplitude (avoids vertical snaps on WASD start/stop)
    nOcclRatio = nil, -- smoothed [0,1] occlusion ratio after wall/terrain sweep
    bOwnUnavailable = false, -- avatar could not be built; stop retrying this session
    nCamDist = nil, -- current camera distance behind the eye (0 = first person), eases to nCamTarget
    nCamTarget = nil, -- wheel / C target distance
    nThirdDist = nil, -- last third-person distance (C returns to it)
    tFollow = nil, -- eased follow point {x,y,z} the camera orbits
    nBodyYaw = nil, -- own body facing (turns toward the walking direction)
    tOwnPrev = nil, -- feet x/z last frame
    bThirdPerson = true,
    bGoRequest = false,
    bViewRequest = false,
    bLabelShown = false,
    bLoggedRx = false,
    bPromptAdded = false,
    bKeyErrorLogged = false,
    bWasPhotoMode = false,
    -- Explore placement preview (Camera -> Explore / WalkingCameraInit: suspended avatar above placement ring)
    bExploreInitActive = false,
    tExplorePreview = nil,
    tExploreDrop = nil,
    tExploreCamEase = nil,
    nExploreDropBaseClearAt = nil,
    sExploreUIState = "idle",
    tPendingExploreExitHUD = nil,
    vExploreStartPos = nil,
    bExploreStartPosFresh = false,
    bPendingExploreDrop = false,
    nExploreDropUntil = 0,
    -- Open habitat gates & doors (local player + co-op friend + modular scenery doors) whose doorway collider lets the player pass
    nLocalOpenGate = nil,
    nRemoteOpenGate = nil,
    tOpenPortals = {},
    fnHasClosedDoorAt = nil,
    -- Hooks set by PZ2Coop.Actions & PZ2Coop.Vehicles (sitting, vehicle seats, arrival, emote wheel)
    tSeatOverride = nil, -- {x, y, z, yaw, eyeHeight}
    tFriendSeatOverride = nil,
    tVehicleOwnOverride = nil, -- {x, y, z, yaw, pitch, roll, camYaw, camPitch, seat, clip, bHidden}
    tVehicleFriendOverride = nil, -- {x, y, z, yaw, pitch, roll, seat, clip, bHidden}
    bOwnVehicleOverrideWasActive = false,
    bFriendVehicleOverrideWasActive = false,
    fnVehiclePromptProvider = nil,
    fnOnAvatarSent = nil,
    fnOnGoArrival = nil,
    fnIsWheelOpen = nil,
    fnIsWheelBlocking = nil,
  }
  rawset(global, "__PZ2CoopPresenceState", s)
end

local Log = function(_sMessage)
  Bridge.Log("presence: " .. _sMessage)
end

local PublishExploreUIState = function(_sState)
  if s.sExploreUIState == _sState then
    return
  end
  s.sExploreUIState = _sState
  if api.ui2 ~= nil and api.ui2.GetDataStoreContext ~= nil and api.ui2.SetDataStoreElement ~= nil then
    pcall(function()
      local ctx = api.ui2.GetDataStoreContext("ui")
      if ctx ~= nil then
        api.ui2.SetDataStoreElement(ctx, "pz2coopExploreUI", _sState)
      end
    end)
  end
end

local WorldAPIs = function()
  return api.world.GetWorldAPIs()
end

local Clamp = function(_n, _lo, _hi)
  if _n < _lo then return _lo end
  if _n > _hi then return _hi end
  return _n
end

local PoseTransform = function(_nX, _nY, _nZ, _nYaw, _nPitch, _nRoll)
  return TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(Vector3:new(_nYaw, _nPitch or 0, _nRoll or 0)),
    Vector3:new(_nX, _nY, _nZ))
end

local CurrentUIMode = function()
  local BaseUIMode = require("Editors.Shared.BaseUIMode")
  return WorldAPIs().ModeHelperComponent:GetCurrentModeName(BaseUIMode.GetModeHelperEntity())
end

-- Queries park weather at ~0.5 Hz via vanilla tWorldAPIs.weather (windows.mainhud.lua:167).
local PollWeather = function()
  local bOk, sW = pcall(function()
    local weather = WorldAPIs().weather
    if weather == nil or weather.GetCurrentWeatherTypeForUI == nil then
      return "clear"
    end
    local nType = weather:GetCurrentWeatherTypeForUI()
    if nType == weather.WeatherType_Rain or nType == weather.WeatherType_RainNight then
      return "rain"
    elseif nType == weather.WeatherType_Snow or nType == weather.WeatherType_SnowNight then
      return "snow"
    elseif nType == weather.WeatherType_HotSun then
      return "heat"
    end
    return "clear"
  end)
  s.sWeather = (bOk and type(sW) == "string") and sW or "clear"
end

-- Returns true when a solid wall, glass panel, or tunnel ceiling separates two vertical heights at (_nX, _nZ).
local HasBarrierBetween = function(_nX, _nYFrom, _nYTo, _nZ)
  if api.physics == nil or api.physics.RayCast == nil or _nYTo <= _nYFrom + 0.05 then
    return false
  end
  local bOk, bHit = pcall(function()
    local nPhys = api.entity.FindEntityByName("MainPhysicsWorld")
    if nPhys == nil then
      return false
    end
    local p = api.physics
    local nFlags = (p.Flag_Building or 0) | (p.Flag_Scenery or 0) |
      (p.Flag_FirstPersonObstruction or 0) | (p.Flag_Landscape or 0)
    if nFlags == 0 then
      return false
    end
    local tRes = p.RayCast(nPhys, Vector3:new(_nX, _nYFrom, _nZ), Vector3:new(_nX, _nYTo, _nZ), nFlags, 1)
    return type(tRes) == "table" and tRes[1] ~= nil
  end)
  return bOk and bHit == true
end

-- Returns (bDeep, nWaterSurfaceY) when feet are submerged at least c_nSwimDepth below an open lake/pond surface.
-- Uses exact vertical FindLake raycast at (_nX, _nZ) (zero horizontal bleed through aquarium glass walls!) and
-- verifies no solid ceiling/wall separates the player from the water surface (protects underwater viewing tunnels).
local IsInDeepWater = function(_nX, _nY, _nZ)
  local gt = WorldAPIs().gameterrain
  if gt == nil then
    return false, nil
  end
  local bOk, bDeep, nSurface = pcall(function()
    local nLakeID = nil
    local nSurf = nil
    if gt.FindLake ~= nil then
      local nRayTop = _nY + 30.0
      local nHitLake, nHitDist = gt:FindLake(Vector3:new(_nX, nRayTop, _nZ), Vector3:new(0, -1, 0), 31.5)
      if nHitLake ~= nil and type(nHitDist) == "number" and nHitDist >= 0 then
        nLakeID = nHitLake
        nSurf = nRayTop - nHitDist
      end
    elseif gt.FindLakesWithSphereCheck ~= nil then
      -- Legacy fallback only when FindLake is unavailable: tight 0.15 m radius never bleeds through aquarium walls.
      local tLakes = gt:FindLakesWithSphereCheck(Vector3:new(_nX, _nY + 0.85, _nZ), 0.15)
      if type(tLakes) == "table" then
        for _, id in pairs(tLakes) do
          nLakeID = id
          break
        end
      end
    end
    if nLakeID == nil then
      return false, nil
    end
    if gt.GetLakeAABB ~= nil then
      local vMin, vMax = gt:GetLakeAABB(nLakeID)
      if vMin ~= nil and vMax ~= nil then
        local minX = vMin.GetX and vMin:GetX() or vMin:X()
        local maxX = vMax.GetX and vMax:GetX() or vMax:X()
        local minZ = vMin.GetZ and vMin:GetZ() or vMin:Z()
        local maxZ = vMax.GetZ and vMax:GetZ() or vMax:Z()
        if _nX < minX or _nX > maxX or _nZ < minZ or _nZ > maxZ then
          return false, nil
        end
        if nSurf == nil then
          nSurf = vMax.GetY and vMax:GetY() or vMax:Y()
        end
      end
    end
    if nSurf == nil and gt.GetLakeSurfaceLevel ~= nil then
      nSurf = gt:GetLakeSurfaceLevel(nLakeID)
    end
    if type(nSurf) == "number" and (nSurf - _nY) >= c_nSwimDepth then
      if HasBarrierBetween(_nX, _nY + 0.85, nSurf + 0.05, _nZ) then
        return false, nil
      end
      return true, nSurf
    end
    return false, nil
  end)
  if bOk and bDeep == true then
    return true, nSurface
  end
  return false, nil
end

-- Exact ground contact raycast straight down via CameraUtils.FocusRaycast (matches vanilla WalkingCamera flags:
-- includes Flag_NavigationSource & Flag_Track, excludes Flag_Animal/Flag_DeadAnimal).
-- Returns (nGroundY_or_nil, bRaycastAvailable).
local TrySampleGroundY = function(_nX, _nFallbackY, _nZ, _nMaxUp, _nMaxDown)
  local nMaxUp = type(_nMaxUp) == "number" and _nMaxUp or 0.50
  local nMaxDown = type(_nMaxDown) == "number" and _nMaxDown or 0.60
  local bOk, nY, bAvail = pcall(function()
    local CameraUtils = require("Components.Cameras.CameraUtils")
    if type(CameraUtils) ~= "table" or CameraUtils.FocusRaycast == nil then
      return nil, false
    end
    local tWorld = WorldAPIs()
    if tWorld.CameraModeManager == nil or tWorld.CameraModeManager.GetVoxelTerrainID == nil then
      return nil, false
    end
    local nTerrainId = tWorld.CameraModeManager:GetVoxelTerrainID()
    if nTerrainId == nil then
      return nil, false
    end
    -- FocusRaycast_Physics skips the first 0.15 m (Camera.PhysicsRaycastMin), so start at least 0.15 m above nMaxUp.
    local nRayStartOffset = math.max(0.85, nMaxUp + 0.15)
    local vHit = CameraUtils.FocusRaycast(tWorld, nTerrainId, Vector3:new(_nX, _nFallbackY + nRayStartOffset, _nZ),
      Vector3:new(0, -1, 0), true, true, true)
    if vHit == nil then
      return nil, true
    end
    local hy = vHit.GetY and vHit:GetY() or vHit:Y()
    if type(hy) == "number" and hy == hy and hy >= _nFallbackY - nMaxDown and hy <= _nFallbackY + nMaxUp then
      return hy, true
    end
    return nil, true
  end)
  if not bOk then
    return nil, false
  end
  return (type(nY) == "number") and nY or nil, bAvail == true
end

local SampleGroundY = function(_nX, _nFallbackY, _nZ, _nMaxUp)
  local nY = TrySampleGroundY(_nX, _nFallbackY, _nZ, _nMaxUp or 0.50, 0.60)
  return nY ~= nil and nY or _nFallbackY
end

-- Smooths avatar vertical position: zero-lag ground tracking uphill (prevents feet clipping into slopes/sloped paths
-- while sprinting), fast easing on discrete tall steps & stair descent, and buoyant float in deep water.
local ComputeAvatarY = function(_nPrevY, _nX, _nFeetY, _nZ, _nDt, _bInWater, _nWaterSurface)
  local nTargetY = _nFeetY
  if _bInWater and type(_nWaterSurface) == "number" then
    local nFloatY = _nWaterSurface - c_nSwimWaterlineOffset
    local nBob = math.sin(s.nClock * c_nSwimBobFreq) * c_nSwimBobAmp
    nTargetY = math.max(_nFeetY, nFloatY) + nBob
  else
    nTargetY = SampleGroundY(_nX, _nFeetY, _nZ)
  end
  if _nPrevY == nil or math.abs(nTargetY - _nPrevY) > 4.0 or _nDt <= 0 then
    return nTargetY
  end
  if not _bInWater and nTargetY >= _nPrevY then
    if (nTargetY - _nPrevY) <= 0.18 then
      return nTargetY
    end
    return _nPrevY + (nTargetY - _nPrevY) * (1 - math.exp(-32.0 * _nDt))
  end
  local nRate = _bInWater and 8.0 or 24.0
  return _nPrevY + (nTargetY - _nPrevY) * (1 - math.exp(-nRate * _nDt))
end

-- ---- spawned entities ---------------------------------------------------------------------------
-- Record: {nId, token, sPrefab, nAge, bReady, bFailed}. _prefab is a prefab name or a prefab table.
-- Optional _nParent parents the spawned entity directly to an existing entity (e.g. a moving vehicle) in local space.
local Spawn = function(_prefab, _sName, _tProps, _transform, _nParent)
  local sPrefab = type(_prefab) == "string" and _prefab or _sName
  local token = api.entity.CreateRequestCompletionToken()
  local bLocal = _nParent ~= nil and true or nil
  local bOk, nId = pcall(api.entity.InstantiatePrefab, _prefab, _sName, token,
    _transform or TransformQ.Identity:WithPos(c_vHidden), _nParent, bLocal, _tProps)
  if not bOk or nId == nil then
    Log("spawn " .. sPrefab .. " failed: " .. tostring(nId))
    return {sPrefab = sPrefab, bFailed = true}
  end
  return {nId = nId, token = token, sPrefab = sPrefab, nAge = 0, bReady = false, bFailed = false}
end

local IsReady = function(_tRec, _nDt)
  if _tRec == nil or _tRec.bFailed then
    return false
  end
  if _tRec.bReady then
    return true
  end
  _tRec.nAge = _tRec.nAge + _nDt
  if api.entity.HaveRequestsCompleted(_tRec.token) and WorldAPIs().transform:HasTransform(_tRec.nId) == true then
    _tRec.bReady = true
  elseif _tRec.nAge > c_nSpawnTimeout then
    _tRec.bFailed = true
  end
  if _tRec.bReady or _tRec.bFailed then
    local bDone = api.entity.HaveRequestsCompleted(_tRec.token)
    local bTransform = WorldAPIs().transform:HasTransform(_tRec.nId)
    Log(string.format("body %s %s after %.1f s (id %s, request completed %s, has transform %s)", _tRec.sPrefab,
      _tRec.bReady and "ok" or "failed", _tRec.nAge, tostring(_tRec.nId), tostring(bDone), tostring(bTransform)))
  end
  return _tRec.bReady
end

local Destroy = function(_tRec)
  if _tRec ~= nil and _tRec.nId ~= nil then
    pcall(api.entity.DestroyEntity, _tRec.nId)
  end
  return nil
end

local Place = function(_tRec, _nX, _nY, _nZ, _nYaw, _nPitch, _nRoll)
  WorldAPIs().transform:SetTransform(_tRec.nId, PoseTransform(_nX, _nY, _nZ, _nYaw, _nPitch, _nRoll))
end

-- ---- name label (shared WidgetType_WidgetLabel, as editors.volume.volumeedithelper.lua:599-608) ------
local LabelManager = function()
  local worldScript = api.world.GetScript(api.world.GetActive())
  return worldScript.tEnvironment:RequireInterface("Interfaces.IUIBillboardWidgetsManager"),
    WorldAPIs().billboardwidgets.WidgetType_WidgetLabel
end

local ShowLabel = function(_nX, _nY, _nZ)
  local manager, nType = LabelManager()
  local tSession = Bridge.GetSession()
  local sName = Bridge.IsLoopback() and "You (mirror)" or (tSession.sPartner or "Friend")
  -- BillboardedWidgetLabels parses sLabel through Frontier's localisation tag parser; plain strings
  -- like "TylerBits" trigger "Parse error in 'ylerbits'" unless wrapped in STRING_LITERAL.
  local sSafe = string.gsub(tostring(sName), "[|%[%]\r\n]", "")
  if sSafe == "" then
    sSafe = "Friend"
  end
  local tLabel = {sLabel = "[STRING_LITERAL:Value=|" .. sSafe .. "|]", vPos = Vector3:new(_nX, _nY, _nZ), nOpacity = 0.5}
  manager:SetBillboardWidgetUIInfo(nType, 1, tLabel)
  manager:SetBillboardWidgetData(nType, {tLabel})
  s.bLabelShown = true
end

local HideLabel = function()
  if s.bLabelShown then
    s.bLabelShown = false
    local manager, nType = LabelManager()
    manager:ClearBillboardWidgetData(nType)
  end
end

-- ---- own pose -> packet -------------------------------------------------------------------------
local WalkingHeight = function()
  local bOk, WalkingCamera = pcall(require, "Components.Cameras.WalkingCamera")
  return bOk and WalkingCamera.GetDefaultWalkingHeight() or 1.55
end

local SendPose = function()
  local cameraModeManager = WorldAPIs().CameraModeManager
  local vPos, vYPR = cameraModeManager:GetPosYPRZoom()
  if vPos == nil or vYPR == nil then
    return
  end
  local tPacket = {cx = vPos:GetX(), cy = vPos:GetY(), cz = vPos:GetZ(), yaw = vYPR:GetX(), pitch = vYPR:GetY()}
  if cameraModeManager:GetCurrentModeName() == "Walking" then
    tPacket.m = s.bThirdPerson and 2 or 1
    if s.tSeatOverride ~= nil then
      tPacket.px, tPacket.py, tPacket.pz = s.tSeatOverride.x, s.tSeatOverride.y, s.tSeatOverride.z
    else
      tPacket.px, tPacket.py, tPacket.pz = tPacket.cx, tPacket.cy - WalkingHeight(), tPacket.cz
    end
  elseif s.tVehicleOwnOverride ~= nil or CurrentUIMode() == "DriveVehicle" then
    tPacket.m = 2
    if s.tVehicleOwnOverride ~= nil then
      tPacket.px, tPacket.py, tPacket.pz = s.tVehicleOwnOverride.x, s.tVehicleOwnOverride.y, s.tVehicleOwnOverride.z
    else
      tPacket.px, tPacket.py, tPacket.pz = tPacket.cx, tPacket.cy - 1.2, tPacket.cz
    end
  else
    tPacket.m = 0
    local tFinal = cameraModeManager:GetCameraDataFinal()
    local vCentre = tFinal and tFinal.vCentrePos or vPos
    tPacket.px, tPacket.py, tPacket.pz = vCentre:GetX(), vCentre:GetY(), vCentre:GetZ()
  end
  Bridge.SendPacket(c_nCursor, nil, tPacket)
end

-- ---- friend avatar validation & sync (packet 0x12, trust boundary) ------------------------------
local IsFiniteNum = function(_v)
  return type(_v) == "number" and _v == _v and _v > -1e9 and _v < 1e9
end

local IsSafeIdent = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= c_nMaxAvatarStr and string.match(_v, "^[%w_%-]+$") ~= nil
end

local IsSafeColourStr = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= c_nMaxAvatarStr and string.match(_v, "^[#%w_%-%.,]+$") ~= nil
end

local ReadVec3 = function(_v)
  local sType = type(_v)
  if sType == "nil" or sType == "number" or sType == "string" or sType == "boolean" then
    return nil
  end
  local bOk, x, y, z = pcall(function()
    if _v.GetX ~= nil then
      return _v:GetX(), _v:GetY(), _v:GetZ()
    end
    return _v:X(), _v:Y(), _v:Z()
  end)
  if bOk and IsFiniteNum(x) and IsFiniteNum(y) and IsFiniteNum(z) then
    return x, y, z
  end
  return nil
end

local SanitizeColourVal = function(_v, _bForWire)
  local vx, vy, vz = ReadVec3(_v)
  if vx ~= nil then
    if _bForWire then
      local tArr = {vx, vy, vz}
      if api.json and api.json.GetArrayMetatable then
        setmetatable(tArr, api.json.GetArrayMetatable())
      end
      return tArr
    end
    return Vector3:new(vx, vy, vz)
  end
  if IsFiniteNum(_v) or type(_v) == "boolean" or IsSafeColourStr(_v) then
    return _v
  end
  if type(_v) ~= "table" then
    return nil
  end
  local tOut, nCount = {}, 0
  for k, val in pairs(_v) do
    nCount = nCount + 1
    if nCount > 4 then
      return nil
    end
    if not (IsFiniteNum(val) or type(val) == "boolean" or IsSafeColourStr(val)) then
      return nil
    end
    if type(k) == "number" and k >= 1 and k <= 4 and math.floor(k) == k then
      tOut[k] = val
    elseif type(k) == "string" and IsSafeIdent(k) then
      local nIdx = tonumber(k)
      if nIdx ~= nil and nIdx >= 1 and nIdx <= 4 and math.floor(nIdx) == nIdx then
        tOut[nIdx] = val
      else
        tOut[k] = val
      end
    else
      return nil
    end
  end
  if nCount == 3 and not _bForWire and IsFiniteNum(tOut[1]) and IsFiniteNum(tOut[2]) and IsFiniteNum(tOut[3]) then
    return Vector3:new(tOut[1], tOut[2], tOut[3])
  end
  return tOut
end

local SanitizeCustom = function(_tRaw, _bForWire)
  if type(_tRaw) ~= "table" then
    return nil, "custom not table"
  end
  local tOut, nKeys = {}, 0
  for k, v in pairs(_tRaw) do
    nKeys = nKeys + 1
    if nKeys > c_nMaxAvatarFields or not IsSafeIdent(k) then
      return nil, "custom key " .. tostring(k)
    end
    if k == "colours" or k == "colors" then
      if type(v) ~= "table" then
        return nil, "custom colours not table (" .. type(v) .. ")"
      end
      local tCols, nCols = {}, 0
      for ck, cv in pairs(v) do
        nCols = nCols + 1
        if nCols > 8 then
          return nil, "too many custom colours"
        end
        local nIdx = tonumber(ck)
        local keyOut = nil
        if nIdx ~= nil and nIdx >= 1 and nIdx <= 8 and math.floor(nIdx) == nIdx then
          keyOut = nIdx
        elseif IsSafeIdent(ck) then
          keyOut = ck
        else
          return nil, "bad colour key " .. tostring(ck)
        end
        local cleanCol = SanitizeColourVal(cv, _bForWire)
        if cleanCol == nil then
          return nil, "bad colour val at " .. tostring(ck) .. " (" .. type(cv) .. ")"
        end
        tCols[keyOut] = cleanCol
      end
      tOut[k] = tCols
    elseif IsFiniteNum(v) or type(v) == "boolean" or IsSafeIdent(v) then
      tOut[k] = v
    elseif type(v) == "table" then
      local cleanSub = SanitizeColourVal(v, _bForWire)
      if cleanSub == nil then
        return nil, "custom field " .. tostring(k) .. " (table)"
      end
      tOut[k] = cleanSub
    else
      return nil, "custom field " .. tostring(k) .. " (" .. type(v) .. ")"
    end
  end
  return tOut
end

local SanitizeAvatar = function(_tRaw, _bForWire)
  if type(_tRaw) ~= "table" then
    return nil, "not a table"
  end
  local sGroup = _tRaw.group
  if type(sGroup) ~= "string" or string.match(sGroup, "^%u%u%u?$") == nil then
    return nil, "invalid group"
  end
  local tOut = {group = sGroup}
  if _tRaw.version ~= nil then
    if not IsFiniteNum(_tRaw.version) or _tRaw.version < 4 or _tRaw.version > 6 or math.floor(_tRaw.version) ~= _tRaw.version then
      return nil, "invalid version"
    end
    tOut.version = _tRaw.version
  else
    tOut.version = 6
  end
  if _tRaw.actor ~= nil then
    if not (IsFiniteNum(_tRaw.actor) or IsSafeIdent(_tRaw.actor)) then
      return nil, "invalid actor"
    end
    tOut.actor = _tRaw.actor
  end
  if _tRaw.voice ~= nil then
    if not (IsFiniteNum(_tRaw.voice) or IsSafeIdent(_tRaw.voice)) then
      return nil, "invalid voice"
    end
    tOut.voice = _tRaw.voice
  end
  if _tRaw.skin ~= nil then
    if not (IsFiniteNum(_tRaw.skin) or IsSafeIdent(_tRaw.skin)) then
      return nil, "invalid skin"
    end
    tOut.skin = _tRaw.skin
  end
  if _tRaw.variant ~= nil then
    if not (IsFiniteNum(_tRaw.variant) or IsSafeIdent(_tRaw.variant)) then
      return nil, "invalid variant"
    end
    tOut.variant = _tRaw.variant
  end
  if _tRaw.parts ~= nil then
    if type(_tRaw.parts) ~= "table" then
      return nil, "invalid parts"
    end
    local tParts, nParts = {}, 0
    for sPartKey, tPart in pairs(_tRaw.parts) do
      nParts = nParts + 1
      if nParts > c_nMaxAvatarParts or not IsSafeIdent(sPartKey) or type(tPart) ~= "table" then
        return nil, "invalid part entry"
      end
      local tCleanPart, nFields = {}, 0
      for fk, fv in pairs(tPart) do
        nFields = nFields + 1
        if nFields > c_nMaxAvatarFields or not IsSafeIdent(fk) then
          return nil, "invalid part field"
        end
        if fk == "custom" then
          local tCleanCustom, sCustomErr = SanitizeCustom(fv, _bForWire)
          if tCleanCustom == nil then
            return nil, "invalid custom (" .. tostring(sCustomErr) .. ")"
          end
          tCleanPart.custom = tCleanCustom
        elseif IsFiniteNum(fv) or type(fv) == "boolean" or IsSafeIdent(fv) then
          tCleanPart[fk] = fv
        else
          return nil, "invalid part value"
        end
      end
      tParts[sPartKey] = tCleanPart
    end
    tOut.parts = tParts
  end
  if _tRaw.items ~= nil then
    if type(_tRaw.items) ~= "table" then
      return nil, "invalid items"
    end
    local tItems, nItems = {}, 0
    for sItemType, tItem in pairs(_tRaw.items) do
      nItems = nItems + 1
      if nItems > 8 or type(tItem) ~= "table" then
        return nil, "invalid item entry"
      end
      if sItemType == "Hats" then
        if not IsSafeIdent(tItem.prefab) then
          return nil, "invalid hat prefab"
        end
        tItems.Hats = {prefab = tItem.prefab}
      end
    end
    if next(tItems) ~= nil then
      tOut.items = tItems
    end
  end
  return tOut
end

-- ---- friend ------------------------------------------------------------------------------------
local DestroyFriendBody = function()
  if s.tFriendBody ~= nil then
    Avatar.DetachProp(s.tFriendBody.tAnim)
    Destroy(s.tFriendBody.tParent)
  end
  s.tFriendBody, s.tFriendPrev, s.nFriendBodyYaw = nil, nil, nil
end

local ForgetFriend = function()
  s.tFriendRing = Destroy(s.tFriendRing)
  DestroyFriendBody()
  s.tFriend = nil
  s.tShown = nil
  s.tFriendAvatarData = nil
  s.bFriendAvatarFailed = false
  s.tFriendSeatOverride = nil
  s.nRemoteOpenGate = nil
  pcall(HideLabel)
end

local WrapAngle = function(_n)
  return (_n + math.pi) % (2 * math.pi) - math.pi
end

-- Speed-scaled turn rate: crisp (13 rad/s) while standing/walking, heavier (7 rad/s) while sprinting.
-- Also detects sharp 180-deg movement reversals (dot < -0.65 above 1.2 m/s) and returns (yaw, nextPrev, speed, yawRate, bRev, bLeft).
local StepBodyYaw = function(_tPrev, _nCurYaw, _nX, _nZ, _nFallbackYaw, _nDt)
  local nYaw = _nCurYaw ~= nil and _nCurYaw or _nFallbackYaw
  local tNextPrev = {x = _nX, z = _nZ}
  if _tPrev == nil or _nDt <= 0 then
    return nYaw, tNextPrev, 0, 0, false, false
  end
  local dx, dz = _nX - _tPrev.x, _nZ - _tPrev.z
  local nDistSq = dx * dx + dz * dz
  local nDist = math.sqrt(nDistSq)
  if nDist > c_nSnapDistance then
    return _nFallbackYaw, tNextPrev, 0, 0, false, false
  end
  local nSpeed = nDist / _nDt
  if nDistSq <= (c_nTurnMinSpeed * _nDt) ^ 2 then
    return nYaw, tNextPrev, nSpeed, 0, false, false
  end
  local mx, mz = dx / nDist, dz / nDist
  local fx, fz = math.sin(nYaw), math.cos(nYaw)
  local nDot = fx * mx + fz * mz
  local nCross = fz * mx - fx * mz
  local bReverse = nSpeed >= c_nPivotMinSpeed and nDot < -0.65
  local bTurnLeft = nCross < 0

  local nSprintT = Clamp((nSpeed - 1.5) / 3.0, 0, 1)
  local nTurnRate = c_nTurnRateSlow + (c_nTurnRateFast - c_nTurnRateSlow) * nSprintT
  local nDiff = WrapAngle(math.atan(dx, dz) - nYaw)
  local nMax = nTurnRate * _nDt
  local nDelta = Clamp(nDiff, -nMax, nMax)
  return WrapAngle(nYaw + nDelta), tNextPrev, nSpeed, nDelta / _nDt, bReverse, bTurnLeft
end

local AdvanceFriendAvatar = function(_tBody, _nDt)
  if _tBody.co == nil then
    local tAvatar = s.tFriendAvatarData
    local bSSOk, StartScreenAvatar = pcall(require, "StartScreen.Shared.StartScreenAvatar")
    if bSSOk and type(StartScreenAvatar) == "table" and StartScreenAvatar.AvatarVersionCheck ~= nil then
      tAvatar = StartScreenAvatar.AvatarVersionCheck(tAvatar)
    end
    if tAvatar == nil then
      Log("friend avatar failed version check")
      s.bFriendAvatarFailed = true
      return
    end
    Log("building friend avatar (group " .. tostring(tAvatar.group) .. ")")
    _tBody.sGroup = tAvatar.group
    local sInitClip = (_tBody.nVehicleParent ~= nil and s.tVehicleFriendOverride ~= nil and s.tVehicleFriendOverride.clip) or nil
    _tBody.co = coroutine.create(function()
      local nAvatar, bAnimated, tMeta = Avatar.CreateAnimated(tAvatar, _tBody.tParent.nId, "friend", sInitClip)
      _tBody.nAvatar = nAvatar
      _tBody.tAnim = Avatar.CreateAnimState(tAvatar.group, bAnimated, tMeta, sInitClip)
      if sInitClip ~= nil and _tBody.tAnim ~= nil then
        _tBody.tAnim.sOverrideSuffix = sInitClip
      end
    end)
  end
  if coroutine.status(_tBody.co) ~= "dead" and _tBody.nAge < c_nAvatarTimeout then
    _tBody.nAge = _tBody.nAge + _nDt
    local bOk, sError = coroutine.resume(_tBody.co)
    if not bOk then
      Log("friend avatar build error: " .. tostring(sError))
      s.bFriendAvatarFailed = true
      return
    end
    if coroutine.status(_tBody.co) == "dead" then
      Log(string.format("friend avatar built after %.1f s (entity %s, animated %s)", _tBody.nAge,
        tostring(_tBody.nAvatar), tostring(_tBody.tAnim and _tBody.tAnim.bAnimated == true)))
    elseif _tBody.nAge >= c_nAvatarTimeout then
      Log("friend avatar build still waiting after " .. c_nAvatarTimeout .. " s, stopped resuming it")
    end
  end
end

local SetBodyHidden = function(_tBody, _bHidden)
  if _tBody ~= nil and _tBody.nAvatar ~= nil and _tBody.bHidden ~= _bHidden then
    _tBody.bHidden = _bHidden
    Avatar.SetHidden(_tBody.tAnim, _tBody.nAvatar, _bHidden)
  end
end

local UpdateFriend = function(_nDt)
  local t = s.tFriend
  if t == nil then
    return
  end
  t.nAge = t.nAge + _nDt
  if t.nAge > c_nFriendTimeout or not (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    Log("friend pose lost (no update for " .. string.format("%.1f", t.nAge) .. " s)")
    ForgetFriend()
    return
  end
  -- Velocity-predicted target with gentle decay after c_nMaxPredictSec so packet jitter never overshoots or stalls.
  local nPred
  if t.nAge <= c_nMaxPredictSec then
    nPred = t.nAge
  else
    nPred = c_nMaxPredictSec + (1 - math.exp(-6.0 * (t.nAge - c_nMaxPredictSec))) / 6.0 * 0.4
  end
  local nTargetX = t.px + (t.vx or 0) * nPred
  local nTargetY = t.py + (t.vy or 0) * nPred
  local nTargetZ = t.pz + (t.vz or 0) * nPred
  local nTargetYaw = t.yaw
  local nTargetPitch = t.pitch or 0
  local tVehFriend = s.tVehicleFriendOverride
  if tVehFriend ~= nil then
    nTargetX, nTargetY, nTargetZ = tVehFriend.x, tVehFriend.y, tVehFriend.z
  elseif s.tFriendSeatOverride ~= nil then
    nTargetX, nTargetY, nTargetZ = s.tFriendSeatOverride.x, s.tFriendSeatOverride.y, s.tFriendSeatOverride.z
  end

  local sh = s.tShown
  local dx, dy, dz = nTargetX - (sh and sh.x or 0), nTargetY - (sh and sh.y or 0), nTargetZ - (sh and sh.z or 0)
  if tVehFriend ~= nil then
    -- Lock friend avatar directly to the live interpolated vehicle seat transform (zero lag behind moving buggy).
    s.tShown = {x = nTargetX, y = nTargetY, z = nTargetZ, yaw = nTargetYaw, pitch = nTargetPitch, ySmooth = nTargetY}
    s.tFriendPrev = {x = nTargetX, z = nTargetZ}
    s.nFriendBodyYaw = tVehFriend.yaw or nTargetYaw
  elseif sh == nil or dx * dx + dy * dy + dz * dz > c_nSnapDistance * c_nSnapDistance then
    s.tShown = {x = nTargetX, y = nTargetY, z = nTargetZ, yaw = nTargetYaw, pitch = nTargetPitch, ySmooth = nTargetY}
    s.tFriendPrev = nil
    s.nFriendBodyYaw = s.tFriendSeatOverride ~= nil and s.tFriendSeatOverride.yaw or nTargetYaw
    if s.tFriendBody ~= nil then
      Avatar.ResetAnimSpeed(s.tFriendBody.tAnim, s.tFriendBody.nAvatar)
    end
  else
    local k = 1 - math.exp(-c_nSmoothRate * _nDt)
    sh.x, sh.y, sh.z = sh.x + dx * k, sh.y + dy * k, sh.z + dz * k
    sh.yaw = sh.yaw + WrapAngle(nTargetYaw - sh.yaw) * k
    sh.pitch = (sh.pitch or 0) + (nTargetPitch - (sh.pitch or 0)) * k
  end
  sh = s.tShown
  local bWalking = (t.m or 0) >= 1 or tVehFriend ~= nil
  local bAvatarDrawn = false
  if bWalking and s.tFriendAvatarData ~= nil and not s.bFriendAvatarFailed then
    local nWantVehParent = tVehFriend ~= nil and tVehFriend.nVehicle or nil
    if s.tFriendBody ~= nil and s.tFriendBody.nVehicleParent ~= nWantVehParent then
      DestroyFriendBody()
    end
    if s.tFriendBody == nil then
      if nWantVehParent ~= nil and type(tVehFriend.lx) == "number" then
        s.tFriendBody = {
          nAge = 0,
          nVehicleParent = nWantVehParent,
          tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopFriendBody", nil,
            PoseTransform(tVehFriend.lx, tVehFriend.ly, tVehFriend.lz, 0, 0, 0), nWantVehParent),
        }
      else
        s.tFriendBody = {
          nAge = 0,
          nVehicleParent = nil,
          tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopFriendBody", nil,
            PoseTransform(sh.x, sh.y, sh.z, sh.yaw)),
        }
      end
    end
    local tBody = s.tFriendBody
    if IsReady(tBody.tParent, _nDt) then
      local nFriendSpeed, nFriendYawRate
      if tVehFriend ~= nil then
        s.nFriendBodyYaw = tVehFriend.yaw or sh.yaw
        s.tFriendPrev = {x = sh.x, z = sh.z}
        nFriendSpeed, nFriendYawRate = 0, 0
      elseif s.tFriendSeatOverride ~= nil then
        s.nFriendBodyYaw = s.tFriendSeatOverride.yaw
        s.tFriendPrev = {x = sh.x, z = sh.z}
        nFriendSpeed, nFriendYawRate = 0, 0
      else
        s.nFriendBodyYaw, s.tFriendPrev, nFriendSpeed, nFriendYawRate =
          StepBodyYaw(s.tFriendPrev, s.nFriendBodyYaw, sh.x, sh.z, sh.yaw, _nDt)
        -- When a first-person friend (m == 1) stands still and turns past their shoulder, pivot their body to follow.
        if t.m == 1 and nFriendSpeed < c_nTurnMinSpeed and s.nFriendBodyYaw ~= nil and _nDt > 0 then
          local nLookDiff = WrapAngle(sh.yaw - s.nFriendBodyYaw)
          local nBodySlack = math.rad(55)
          if math.abs(nLookDiff) > nBodySlack then
            local nExcess = nLookDiff > 0 and (nLookDiff - nBodySlack) or (nLookDiff + nBodySlack)
            local nStep = Clamp(nExcess, -c_nTurnRateSlow * _nDt, c_nTurnRateSlow * _nDt)
            s.nFriendBodyYaw = WrapAngle(s.nFriendBodyYaw + nStep)
          end
        end
        -- Blend rendered speed with recent smoothed peer velocity so brief inter-packet troughs never stutter to idle.
        if t.nAge < 0.25 then
          local nPeerHoriz = math.sqrt((t.vx or 0) ^ 2 + (t.vz or 0) ^ 2)
          if nPeerHoriz > 0.45 and nFriendSpeed > 0.15 then
            nFriendSpeed = math.max(nFriendSpeed, nPeerHoriz * 0.85)
          end
        end
      end
      local bInWater, nWaterSurf = IsInDeepWater(sh.x, sh.y, sh.z)
      if tVehFriend ~= nil or s.tFriendSeatOverride ~= nil then
        sh.ySmooth = sh.y
        bInWater = false
      else
        sh.ySmooth = ComputeAvatarY(sh.ySmooth, sh.x, sh.y, sh.z, _nDt, bInWater, nWaterSurf)
      end
      local nPitch, nRoll = 0, 0
      if tVehFriend ~= nil then
        nPitch, nRoll = tVehFriend.pitch or 0, tVehFriend.roll or 0
      elseif tBody.tAnim ~= nil then
        nPitch, nRoll = Avatar.StepBodyLean(tBody.tAnim, nFriendYawRate, nFriendSpeed, _nDt, bInWater)
      end
      if tBody.nVehicleParent ~= nil and tVehFriend ~= nil and type(tVehFriend.lx) == "number" then
        -- Parented directly to the vehicle: only write local seat transform when seat/calibration changes (zero twitch).
        local bChanged = tBody.nLastLX == nil or math.abs(tBody.nLastLX - tVehFriend.lx) > 1e-4 or
          math.abs(tBody.nLastLY - tVehFriend.ly) > 1e-4 or math.abs(tBody.nLastLZ - tVehFriend.lz) > 1e-4
        if bChanged then
          tBody.nLastLX, tBody.nLastLY, tBody.nLastLZ = tVehFriend.lx, tVehFriend.ly, tVehFriend.lz
          Place(tBody.tParent, tVehFriend.lx, tVehFriend.ly, tVehFriend.lz, 0, 0, 0)
        end
      else
        Place(tBody.tParent, sh.x, sh.ySmooth, sh.z, s.nFriendBodyYaw, nPitch, nRoll)
      end
      local bOk, sError = pcall(AdvanceFriendAvatar, tBody, _nDt)
      if not bOk then
        Log("friend avatar error: " .. tostring(sError))
        s.bFriendAvatarFailed = true
      elseif tBody.nAvatar ~= nil then
        SetBodyHidden(tBody, tVehFriend ~= nil and tVehFriend.bHidden == true)
        if tVehFriend ~= nil then
          local sClip = tVehFriend.clip or "$OnRideSitIdle"
          if tBody.tAnim ~= nil and tBody.tAnim.sOverrideSuffix ~= sClip then
            Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sClip, 0.18)
          end
          s.bFriendVehicleOverrideWasActive = true
        elseif s.bFriendVehicleOverrideWasActive then
          s.bFriendVehicleOverrideWasActive = false
          if tBody.tAnim ~= nil and s.tFriendSeatOverride == nil then
            Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, 0.18)
          end
        end
        Avatar.UpdateAnimation(tBody.tAnim, tBody.nAvatar, nFriendSpeed, _nDt, bInWater, s.sWeather, true)
        local bFriendSeatedIdle = tVehFriend ~= nil or (s.tFriendSeatOverride ~= nil and
          (s.tFriendSeatOverride.phase == nil or s.tFriendSeatOverride.phase == "seated"))
        Avatar.UpdateHeadLook(tBody.tAnim, tBody.nAvatar, sh.yaw, sh.pitch or 0, s.nFriendBodyYaw, nPitch,
          _nDt, bInWater, bFriendSeatedIdle)
        bAvatarDrawn = true
      end
    elseif tBody.tParent.bFailed then
      s.bFriendAvatarFailed = true
    end
  elseif s.tFriendBody ~= nil then
    SetBodyHidden(s.tFriendBody, true)
    Avatar.ResetAnimSpeed(s.tFriendBody.tAnim, s.tFriendBody.nAvatar)
    s.tFriendPrev = nil
  end
  if bAvatarDrawn then
    if s.tFriendRing ~= nil and s.tFriendRing.bReady then
      Place(s.tFriendRing, c_vHidden:GetX(), c_vHidden:GetY(), c_vHidden:GetZ(), 0)
    end
  else
    if s.tFriendRing == nil then
      s.tFriendRing = Spawn(c_sRing, "PZ2CoopFriendRing", nil)
    end
    if IsReady(s.tFriendRing, _nDt) then
      Place(s.tFriendRing, sh.x, sh.y, sh.z, sh.yaw)
    end
  end
  local bLabel, sError = pcall(ShowLabel, sh.x, (sh.ySmooth or sh.y) + c_nLabelHeight, sh.z)
  if not bLabel and not s.bLabelErrorLogged then
    s.bLabelErrorLogged = true
    Log("name label error: " .. tostring(sError))
  end
end

-- ---- third person ------------------------------------------------------------------------------
-- Smooth camera occlusion recovery: snaps IN instantly on wall/terrain hit, eases OUT at c_nOcclRecoverRate.
-- Tracks a [0, 1] occlusion ratio so unobstructed WASD/follow/zoom motion never fights occlusion recovery.
local SweepCamera = function(_vEye, _nX, _nY, _nZ, _nDt)
  local dx, dy, dz = _nX - _vEye:GetX(), _nY - _vEye:GetY(), _nZ - _vEye:GetZ()
  local nLength = math.sqrt(dx * dx + dy * dy + dz * dz)
  if nLength < 1e-3 then
    s.nOcclRatio = 1.0
    return _nX, _nY, _nZ
  end
  local nx, ny, nz = dx / nLength, dy / nLength, dz / nLength
  local tWorld = WorldAPIs()
  local nHit = tWorld.voxelterrain:SphereSweep(tWorld.CameraModeManager:GetVoxelTerrainID(), _vEye,
    Vector3:new(nx, ny, nz), nLength + c_nCameraRadius, c_nCameraRadius)
  local nTargetRatio = (type(nHit) == "number" and nHit < nLength) and math.max(0, nHit / nLength) or 1.0
  if s.nOcclRatio == nil or nTargetRatio < s.nOcclRatio then
    s.nOcclRatio = nTargetRatio -- snap in immediately: never clip inside a wall
  elseif s.nOcclRatio < nTargetRatio then
    local nDt = type(_nDt) == "number" and _nDt > 0 and _nDt or (1 / 60)
    s.nOcclRatio = s.nOcclRatio + (nTargetRatio - s.nOcclRatio) * (1 - math.exp(-c_nOcclRecoverRate * nDt))
    if nTargetRatio - s.nOcclRatio < 1e-4 then
      s.nOcclRatio = nTargetRatio
    end
  end
  if s.nOcclRatio >= 1.0 then
    return _nX, _nY, _nZ
  end
  return _vEye:GetX() + dx * s.nOcclRatio, _vEye:GetY() + dy * s.nOcclRatio, _vEye:GetZ() + dz * s.nOcclRatio
end

local HandleWheel = function()
  if CurrentUIMode() ~= "WalkingCamera" then
    return
  end
  if s.fnIsWheelOpen ~= nil and s.fnIsWheelOpen() then
    return -- mouse wheel switches emote wheel pages while the wheel is open
  end
  local tMouse = WorldAPIs().InputManager:GetMouseInput()
  local nWheel = tMouse and tMouse.RawZAxis
  if type(nWheel) ~= "number" or nWheel == 0 then
    return
  end
  if nWheel > 0 then
    if not s.bThirdPerson then
      return
    end
    local nTarget = (s.nCamTarget or c_nThirdBack) * c_nZoomStep
    if nTarget < c_nFirstPersonSnap then
      Presence.SetThirdPerson(false)
      return
    end
    s.nCamTarget, s.nThirdDist = nTarget, nTarget
  elseif not s.bThirdPerson then
    s.nThirdDist = c_nZoomMin
    Presence.SetThirdPerson(true)
  else
    local nTarget = math.min(c_nZoomMax, (s.nCamTarget or c_nThirdBack) / c_nZoomStep)
    s.nCamTarget, s.nThirdDist = nTarget, nTarget
  end
end

local DefaultFOV = function()
  local bOk, CameraUtils = pcall(require, "Components.Cameras.CameraUtils")
  if bOk and type(CameraUtils) == "table" and type(CameraUtils.nDefaultFOV) == "number" then
    return CameraUtils.nDefaultFOV
  end
  return math.pi / 3
end

-- Runs right after vanilla WalkingCamera.Advance.
-- Applies smooth zoom, over-the-shoulder framing, dynamic sprint FOV kick & pullback, stride cadence micro-bob,
-- and smooth occlusion recovery.
local ApplyThirdPerson = function(_tData, _nDt)
  local tFinal = _tData and _tData.tFinal
  if tFinal == nil or tFinal.vCameraPos == nil or tFinal.transformQ == nil then
    s.tOwnPose, s.tFollow, s.nOcclRatio, s.nBobAmp = nil, nil, nil, 0
    return
  end
  local nDt = type(_nDt) == "number" and _nDt > 0 and _nDt or 1 / 60
  HandleWheel()

  local tEase = s.tExploreCamEase
  if tEase ~= nil then
    local vDropEye = Vector3:new(tEase.dropX, tEase.dropEyeY, tEase.dropZ)
    tFinal.vCameraPos = vDropEye
    if type(_tData.tDelta) == "table" then
      _tData.tDelta.vDispHint = Vector3:new(0, 0, 0)
    end
  end

  -- Smooth sprint blend [0,1] for FOV kick + subtle pullback + elastic follow feel.
  local nSmoothSpeed = s.nOwnSmoothSpeed or 0
  local nSprintGoal = (s.tSeatOverride == nil and not s.bOwnInWater and nSmoothSpeed >= 4.0) and 1.0 or 0.0
  s.nSprintBlend = (s.nSprintBlend or 0) + (nSprintGoal - (s.nSprintBlend or 0)) * (1 - math.exp(-c_nFovRate * nDt))
  if tFinal.nCameraFOV ~= nil then
    local nBaseFov = DefaultFOV()
    tFinal.nCameraFOV = nBaseFov + c_nSprintFovAdd * s.nSprintBlend
  end

  local nTarget = s.bThirdPerson and (s.nCamTarget or c_nThirdBack) or 0
  local nDist = s.nCamDist or 0
  nDist = nDist + (nTarget - nDist) * (1 - math.exp(-c_nZoomRate * nDt))
  if math.abs(nTarget - nDist) < 0.01 then
    nDist = nTarget
  end
  s.nCamDist = nDist
  if nDist <= 0 then
    local vEyeFP, vYPRFP = tFinal.vCameraPos, tFinal.vCameraYPR
    local nYawFP = vYPRFP ~= nil and vYPRFP:GetX() or 0
    local nPitchFP = vYPRFP ~= nil and vYPRFP:GetY() or 0
    if s.tSeatOverride ~= nil then
      local nSeatYaw = s.tSeatOverride.yaw or nYawFP
      local vSeatEye = Vector3:new(
        s.tSeatOverride.x + math.sin(nSeatYaw) * c_nFirstPersonSeatEyeFwd,
        s.tSeatOverride.y + (s.tSeatOverride.eyeHeight or 1.15),
        s.tSeatOverride.z + math.cos(nSeatYaw) * c_nFirstPersonSeatEyeFwd)
      tFinal.transformQ = tFinal.transformQ:WithPos(vSeatEye)
      s.tOwnPose = {
        x = s.tSeatOverride.x, y = s.tSeatOverride.y, z = s.tSeatOverride.z,
        yaw = nSeatYaw, camYaw = nYawFP, pitch = nPitchFP,
        bHidden = false, bHeadHidden = true, bFirstPerson = true, nFpBodyBack = 0,
      }
    else
      if s.bOwnInWater and type(s.nOwnWaterSurface) == "number" then
        local nWaterEyeY = math.max(vEyeFP:GetY(), s.nOwnWaterSurface + 0.35)
        tFinal.transformQ = tFinal.transformQ:WithPos(Vector3:new(vEyeFP:GetX(), nWaterEyeY, vEyeFP:GetZ()))
      end
      s.tOwnPose = {
        x = vEyeFP:GetX(), y = vEyeFP:GetY() - WalkingHeight(), z = vEyeFP:GetZ(),
        yaw = nYawFP, camYaw = nYawFP, pitch = nPitchFP,
        bHidden = false, bHeadHidden = true, bFirstPerson = true, nFpBodyBack = c_nFirstPersonBodyBack,
      }
    end
    s.tFollow, s.nOcclRatio, s.nBobAmp = nil, nil, 0
    return
  end

  local vEye, vYPR = tFinal.vCameraPos, tFinal.vCameraYPR
  local nEyeX, nEyeY, nEyeZ = vEye:GetX(), vEye:GetY(), vEye:GetZ()
  if s.tSeatOverride ~= nil then
    nEyeX = s.tSeatOverride.x
    nEyeY = s.tSeatOverride.y + (s.tSeatOverride.eyeHeight or 1.15)
    nEyeZ = s.tSeatOverride.z
  elseif s.bOwnInWater and type(s.nOwnWaterSurface) == "number" then
    -- Lift third-person pivot to the waterline so the camera floats cleanly above deep lakes instead of underwater.
    nEyeY = math.max(nEyeY, s.nOwnWaterSurface + 0.35)
  end
  local f = s.tFollow
  local dx, dy, dz = nEyeX - (f and f.x or 0), nEyeY - (f and f.y or 0), nEyeZ - (f and f.z or 0)
  if f == nil or dx * dx + dy * dy + dz * dz > c_nFollowSnap * c_nFollowSnap then
    f = {x = nEyeX, y = nEyeY, z = nEyeZ}
    s.nOcclRatio = nil
  else
    -- GTA-style elastic camera follow: slightly looser during sprint acceleration for palpable velocity lag.
    local nEffFollow = c_nFollowRate - 3.5 * s.nSprintBlend
    local k = 1 - math.exp(-nEffFollow * nDt)
    f.x, f.y, f.z = f.x + dx * k, f.y + dy * k, f.z + dz * k
  end
  s.tFollow = f

  local nLag = math.min(1, nDist / c_nZoomMin)
  local nYaw, nPitch = vYPR:GetX(), vYPR:GetY()
  local fx, fy, fz = math.sin(nYaw) * math.cos(nPitch), -math.sin(nPitch), math.cos(nYaw) * math.cos(nPitch)
  local rx, rz = math.cos(nYaw), -math.sin(nYaw)
  local nShoulder = c_nShoulderOffset * nLag

  -- Smoothly ramped stride cadence micro-bob so tapping/releasing WASD never snaps vertically.
  local nBobTargetAmp = 0
  if s.tSeatOverride == nil and nSmoothSpeed > 0.35 then
    local nMoveT = Clamp((nSmoothSpeed - 0.35) / 0.65, 0, 1)
    local nBaseAmp = s.bOwnInWater and 0.022 or (0.012 + (0.025 - 0.012) * s.nSprintBlend)
    nBobTargetAmp = nBaseAmp * nMoveT
  end
  s.nBobAmp = (s.nBobAmp or 0) + (nBobTargetAmp - (s.nBobAmp or 0)) * (1 - math.exp(-8.0 * nDt))
  local nBobY = 0
  if s.nBobAmp < 1e-4 then
    s.nBobAmp = 0
    s.nBobPhase = 0
  else
    local nFreq = s.bOwnInWater and 3.6 or (8.5 + (12.5 - 8.5) * s.nSprintBlend)
    s.nBobPhase = (s.nBobPhase or 0) + nDt * nFreq
    nBobY = math.sin(s.nBobPhase) * s.nBobAmp * nLag
  end

  local nEffDist = nDist + c_nSprintPullback * s.nSprintBlend * nLag
  local px = nEyeX + (f.x - nEyeX) * nLag + rx * nShoulder
  local py = nEyeY + (f.y - nEyeY) * nLag + nBobY
  local pz = nEyeZ + (f.z - nEyeZ) * nLag + rz * nShoulder
  local nUp = c_nThirdUp * nDist / c_nThirdBack
  local vSweepStart = Vector3:new(nEyeX, nEyeY, nEyeZ)
  local x, y, z = SweepCamera(vSweepStart, px - fx * nEffDist, py - fy * nEffDist + nUp, pz - fz * nEffDist, nDt)
  if s.bOwnInWater and type(s.nOwnWaterSurface) == "number" then
    y = math.max(y, s.nOwnWaterSurface + 0.18)
  end
  if tEase ~= nil then
    tEase.nElapsed = tEase.nElapsed + nDt
    local u = Clamp(tEase.nElapsed / tEase.nDuration, 0, 1)
    local w = 1 - (1 - u) * (1 - u) * (1 - u)
    local cx = tEase.startX + (x - tEase.startX) * w
    local cy = tEase.startY + (y - tEase.startY) * w
    local cz = tEase.startZ + (z - tEase.startZ) * w
    local cyaw = WrapAngle(tEase.startYaw + WrapAngle(nYaw - tEase.startYaw) * w)
    local cpitch = tEase.startPitch + (nPitch - tEase.startPitch) * w
    local croll = tEase.startRoll * (1 - w)
    tFinal.transformQ = PoseTransform(cx, cy, cz, cyaw, cpitch, croll)
    if u >= 1 then
      s.tExploreCamEase = nil
      PublishExploreUIState("visible")
    end
  else
    tFinal.transformQ = tFinal.transformQ:WithPos(Vector3:new(x, y, z))
  end
  local nActualCamDist = math.sqrt((x - nEyeX) ^ 2 + (y - nEyeY) ^ 2 + (z - nEyeZ) ^ 2)
  local nCloseDist = math.min(nDist, nActualCamDist)
  local bCloseHeadHide = nCloseDist < c_nBodyHideDist
  local nFpBodyBack = (s.tSeatOverride == nil and bCloseHeadHide) and
    (c_nFirstPersonBodyBack * Clamp(1.0 - nCloseDist / c_nBodyHideDist, 0, 1)) or 0
  if s.tSeatOverride ~= nil then
    s.tOwnPose = {x = s.tSeatOverride.x, y = s.tSeatOverride.y, z = s.tSeatOverride.z, yaw = s.tSeatOverride.yaw,
      camYaw = nYaw, pitch = nPitch, bHidden = false, bHeadHidden = bCloseHeadHide,
      bFirstPerson = (not s.bThirdPerson) and bCloseHeadHide, nFpBodyBack = 0}
  else
    s.tOwnPose = {x = vEye:GetX(), y = vEye:GetY() - WalkingHeight(), z = vEye:GetZ(), yaw = nYaw,
      camYaw = nYaw, pitch = nPitch, bHidden = false, bHeadHidden = bCloseHeadHide,
      bFirstPerson = (not s.bThirdPerson) and bCloseHeadHide, nFpBodyBack = nFpBodyBack}
  end
end

local ResolveEntityName = function(_tWorld, _nEnt)
  if _tWorld == nil or _nEnt == nil then
    return nil
  end
  local puppets = _tWorld.scenery_puppets
  local placement = _tWorld.placement
  local trApi = _tWorld.transform
  local nCur = _nEnt
  for _ = 1, 4 do
    if nCur == nil then
      break
    end
    if puppets ~= nil and puppets.EntityIDToPlacementID ~= nil and placement ~= nil and placement.GetPartResourceName ~= nil then
      local bPOk, nPartID = pcall(puppets.EntityIDToPlacementID, puppets, nCur)
      if bPOk and nPartID ~= nil then
        local bROk, sRes = pcall(placement.GetPartResourceName, placement, nPartID)
        if bROk and type(sRes) == "string" and sRes ~= "" then
          return sRes
        end
      end
    end
    if trApi == nil or trApi.GetParent == nil then
      break
    end
    local bPar, nParent = pcall(trApi.GetParent, trApi, nCur)
    if not bPar or nParent == nil or nParent == nCur then
      break
    end
    nCur = nParent
  end
  if placement ~= nil and placement.GetPartResourceName ~= nil then
    local bROk, sRes = pcall(placement.GetPartResourceName, placement, _nEnt)
    if bROk and type(sRes) == "string" and sRes ~= "" then
      return sRes
    end
  end
  if api.entity ~= nil and api.entity.GetName ~= nil then
    local bNOk, sEntName = pcall(api.entity.GetName, _nEnt)
    if bNOk and type(sEntName) == "string" and sEntName ~= "" then
      return sEntName
    end
  end
  return nil
end

-- Returns true ONLY for Aquarium Staff Doors (AquariumEntrance, which open directly into flooded underwater tanks).
-- Explicitly allows GlassTunnelGate (dry underwater viewing tunnel entrance) and all standard/guest/wide doors.
local IsAquariumStaffDoorEntity = function(_nEntityID)
  if _nEntityID == nil then
    return false
  end
  local bOk, bRes = pcall(function()
    local tWorld = WorldAPIs()
    local sName = ResolveEntityName(tWorld, _nEntityID)
    if type(sName) == "string" and sName ~= "" then
      local sLow = string.lower(sName)
      if string.find(sLow, "glasstunnel", 1, true) ~= nil or string.find(sLow, "guestgate", 1, true) ~= nil then
        return false
      end
      if string.find(sLow, "aquariumentrance", 1, true) ~= nil or
        string.find(sLow, "aquariumdrydoor", 1, true) ~= nil or
        string.find(sLow, "aquariumwetdoor", 1, true) ~= nil then
        return true
      end
    end
    local hb = tWorld and tWorld.habitatboundary
    if hb ~= nil and hb.GetBoundaryObjectFromEntity ~= nil then
      local bHit, oPanel, _, oProp = hb:GetBoundaryObjectFromEntity(_nEntityID)
      if bHit then
        if oProp == nil and oPanel ~= nil and oPanel.GetAllData ~= nil then
          local dP = oPanel:GetAllData()
          oProp = type(dP) == "table" and dP.oAttachedProp or nil
        end
        if oProp ~= nil and oProp.GetAllData ~= nil then
          local dProp = oProp:GetAllData()
          if type(dProp) == "table" then
            for _, sField in ipairs({"sPropType", "sAttachablePropType", "sType", "sPrefabName", "sName"}) do
              local sVal = dProp[sField]
              if type(sVal) == "string" and sVal ~= "" then
                local sLow = string.lower(sVal)
                if string.find(sLow, "glasstunnel", 1, true) ~= nil or string.find(sLow, "guestgate", 1, true) ~= nil then
                  return false
                end
                if string.find(sLow, "aquariumentrance", 1, true) ~= nil or string.find(sLow, "aquarium", 1, true) ~= nil then
                  return true
                end
              end
            end
            if dProp.bIsGuestGate == true then
              return false
            end
          end
        end
        -- Fallback: staff gate attached to an Acrylic / Aquarium habitat without a tunnel/guest name
        local bIsAq = false
        local oAny = oProp or oPanel
        if oAny ~= nil and hb.GetHabitatsFromBoundaryObject ~= nil and tWorld.habitat ~= nil and
          tWorld.habitat.IsAquarium ~= nil and tWorld.habitat.GetEntityIDFromHabitatID ~= nil then
          for nHabId in pairs(hb:GetHabitatsFromBoundaryObject(oAny) or {}) do
            local nHabEnt = tWorld.habitat:GetEntityIDFromHabitatID(nHabId)
            if nHabEnt ~= nil and tWorld.habitat:IsAquarium(nHabEnt) == true then
              bIsAq = true
              break
            end
          end
        end
        if not bIsAq and oPanel ~= nil and oPanel.GetAllData ~= nil then
          local dP = oPanel:GetAllData()
          if type(dP) == "table" and dP.sBoundaryType == "Acrylic" then
            bIsAq = true
          end
        end
        if bIsAq then
          -- If we could not positively identify it as GlassTunnelGate, treat an Aquarium boundary gate as AquariumEntrance.
          if type(sName) == "string" and string.find(string.lower(sName), "tunnel", 1, true) ~= nil then
            return false
          end
          return true
        end
      end
    end
    return false
  end)
  return bOk and bRes == true
end

-- Classifies modular scenery wall cutouts, door frames, archways, tunnels, and open shutters that the player
-- should be able to walk straight through (even when placed across a non-aquarium habitat wall).
local ClassifyCutoutResource = function(_sResName)
  if type(_sResName) ~= "string" or _sResName == "" then
    return nil
  end
  local sLow = string.lower(_sResName)
  if string.find(sLow, "aquarium", 1, true) ~= nil then
    return nil
  end
  -- Reject non-walkthrough decorative/trim pieces & solid wall panels without openings
  for _, sSkip in ipairs({"_topper", "_top_", "canopy", "sign", "bracket", "_post", "_roller",
    "gate_trim", "brick_trim", "emissive", "wallpaper", "decorative_arch", "archfeature",
    "extention", "extension"}) do
    if string.find(sLow, sSkip, 1, true) ~= nil then
      return nil
    end
  end
  -- Wide open shutters & 3m door frames
  if string.find(sLow, "door_shutter_01_open", 1, true) ~= nil or
    string.find(sLow, "_door_frame_3m", 1, true) ~= nil then
    return {nHalfW = 1.55, nHalfDepth = 0.65, nMaxY = 2.85}
  end
  -- Double door wall cutouts & double door frames
  if string.find(sLow, "_door_double", 1, true) ~= nil or
    string.find(sLow, "_frame_double", 1, true) ~= nil or
    string.find(sLow, "_door_frame_2m", 1, true) ~= nil or
    string.find(sLow, "_door_frame_2x3", 1, true) ~= nil or
    string.find(sLow, "_door_4x4", 1, true) ~= nil or
    string.find(sLow, "_door_base_4x4", 1, true) ~= nil then
    return {nHalfW = 1.25, nHalfDepth = 0.55, nMaxY = 2.60}
  end
  -- Single door wall cutouts & single door frames
  if string.find(sLow, "_door_single", 1, true) ~= nil or
    string.find(sLow, "_frame_single", 1, true) ~= nil or
    string.find(sLow, "_door_frame_1m", 1, true) ~= nil then
    return {nHalfW = 0.65, nHalfDepth = 0.55, nMaxY = 2.35}
  end
  -- Archways, tunnel walls, and zoo entrance arch
  if string.find(sLow, "_arch_round", 1, true) ~= nil or
    string.find(sLow, "_arch_straight", 1, true) ~= nil or
    string.find(sLow, "_arch_half", 1, true) ~= nil or
    string.find(sLow, "_arch_tunnel", 1, true) ~= nil or
    string.find(sLow, "_arch_a", 1, true) ~= nil or
    string.find(sLow, "archway", 1, true) ~= nil or
    string.find(sLow, "tiger_arch", 1, true) ~= nil or
    string.find(sLow, "arbour_arch", 1, true) ~= nil or
    string.find(sLow, "_tunnel_round", 1, true) ~= nil or
    string.find(sLow, "_tunnel_straight", 1, true) ~= nil or
    string.find(sLow, "zooentrance", 1, true) ~= nil then
    return {nHalfW = 1.45, nHalfDepth = 0.75, nMaxY = 3.10}
  end
  return nil
end

local ExtractPortalBasis = function(_tr)
  if _tr == nil then
    return nil
  end
  local vPos = _tr.GetPos and _tr:GetPos() or (_tr.Pos and _tr:Pos())
  if vPos == nil then
    return nil
  end
  local gx = vPos.GetX and vPos:GetX() or vPos:X()
  local gy = vPos.GetY and vPos:GetY() or vPos:Y()
  local gz = vPos.GetZ and vPos:GetZ() or vPos:Z()
  local fx, fz = 0, 1
  if _tr.GetF ~= nil then
    local vF = _tr:GetF()
    if vF ~= nil then
      fx = vF.GetX and vF:GetX() or vF:X()
      fz = vF.GetZ and vF:GetZ() or vF:Z()
    end
  elseif _tr.GetOr ~= nil then
    local bY, vYpr = pcall(function() return _tr:GetOr():ToYawPitchRoll() end)
    if bY and vYpr ~= nil then
      local nYaw = vYpr.GetX and vYpr:GetX() or vYpr:X()
      fx, fz = math.sin(nYaw), math.cos(nYaw)
    end
  end
  local fLen = math.sqrt(fx * fx + fz * fz)
  if fLen > 1e-4 then
    fx, fz = fx / fLen, fz / fLen
  else
    fx, fz = 0, 1
  end
  return gx, gy, gz, fx, fz, fz, -fx
end

local IsNearOpenGate = function(_nX, _nY, _nZ)
  local tGates = s.tOpenGates
  if type(tGates) ~= "table" then
    return false
  end
  for _, g in pairs(tGates) do
    if type(g) == "table" and type(g.x) == "number" and type(g.z) == "number" then
      local dx, dz = _nX - g.x, _nZ - g.z
      local dy = math.abs((_nY or g.y or 0) - (g.y or 0))
      if dx * dx + dz * dz <= 2.3 * 2.3 and dy <= 2.8 then
        return true
      end
    end
  end
  return false
end

local IsPointInOpenGate = function(_tOpenGates, _nX, _nY, _nZ, _bRequireAcrylicPass)
  if _tOpenGates == nil then
    return false
  end
  for _, g in ipairs(_tOpenGates) do
    if not _bRequireAcrylicPass or g.bAllowAcrylic == true then
      local dx, dy, dz = _nX - g.gx, _nY - g.gy, _nZ - g.gz
      if dy >= (g.nMinY or c_nGateOpenMinY) and dy <= (g.nMaxY or c_nGateOpenMaxY) then
        if g.bRadial then
          if dx * dx + dz * dz <= g.nHalfW * g.nHalfW then
            return true
          end
        else
          local nDepth = math.abs(dx * g.fx + dz * g.fz)
          if nDepth <= (g.nHalfDepth or c_nGateOpenHalfDepth) then
            local nSide = math.abs(dx * g.rx + dz * g.rz)
            if nSide <= g.nHalfW then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

-- Spatial HabitatBoundary collision: habitat barriers live in tWorld.spatial (Flag_HabitatBoundary) and many
-- barrier types have no physics collider in MainPhysicsWorld. Slide smoothly along solid fence panels while
-- ignoring "Null" barriers and opened gate / door / cutout / archway openings (never bypassing Acrylic unless
-- explicitly allowed by a GlassTunnelGate portal).
local ResolveFenceCollision = function(_nSx, _nSy, _nSz, _nRx, _nRz, _tPassPortals)
  local tWorld = WorldAPIs()
  local sp = tWorld and tWorld.spatial
  local hb = tWorld and tWorld.habitatboundary
  if sp == nil or hb == nil or sp.CapsuleQuery == nil or sp.Flag_HabitatBoundary == nil or
    hb.GetBoundaryObjectFromEntity == nil then
    return _nRx, _nRz, false
  end
  local nWalkH = WalkingHeight()
  local nFeetY = _nSy - nWalkH
  local nMidY = nFeetY + 0.65
  local nPad = 0.24
  local bQOk, tHits = pcall(sp.CapsuleQuery, sp, Vector3:new(_nSx, nMidY, _nSz), Vector3:new(_nRx, nMidY, _nRz),
    nPad, sp.Flag_HabitatBoundary)
  if not bQOk or type(tHits) ~= "table" or #tHits == 0 then
    return _nRx, _nRz, false
  end
  local rx, rz = _nRx, _nRz
  local bHitFence = false
  local tSeen = {}
  for _, nEnt in ipairs(tHits) do
    local bObj, bHit, oPanel, oPost = pcall(hb.GetBoundaryObjectFromEntity, hb, nEnt)
    if bObj and bHit and oPanel ~= nil and not tSeen[oPanel] then
      tSeen[oPanel] = true
      local bData, d = pcall(oPanel.GetAllData, oPanel)
      if bData and type(d) == "table" and d.sBoundaryType ~= "Null" and
        d.vBasePosStart ~= nil and d.vBasePosEnd ~= nil then
        local bIsAcrylic = d.sBoundaryType == "Acrylic"
        local ax, ay, az = d.vBasePosStart:GetX(), d.vBasePosStart:GetY(), d.vBasePosStart:GetZ()
        local bx, by, bz = d.vBasePosEnd:GetX(), d.vBasePosEnd:GetY(), d.vBasePosEnd:GetZ()
        local nBaseMin = math.min(ay, by)
        local nTopMax = math.max(d.nWorldHeightStart or (ay + 2.0), d.nWorldHeightEnd or (by + 2.0))
        if nTopMax > nFeetY + 0.25 and nBaseMin < nFeetY + 1.65 then
          local abx, abz = bx - ax, bz - az
          local abLenSq = abx * abx + abz * abz
          if abLenSq > 1e-6 then
            -- Closest point on segment AB to candidate (rx, rz)
            local t = Clamp(((rx - ax) * abx + (rz - az) * abz) / abLenSq, 0, 1)
            local cx, cz = ax + abx * t, az + abz * t
            local bThroughPortal = _tPassPortals ~= nil and IsPointInOpenGate(_tPassPortals, cx, nMidY, cz, bIsAcrylic)
            if not bThroughPortal then
              local dx, dz = rx - cx, rz - cz
              local d2 = dx * dx + dz * dz
              -- Also check if segment (sx,sz)->(rx,rz) crossed AB completely in a single step
              local sSide = (abx * (_nSz - az) - abz * (_nSx - ax))
              local rSide = (abx * (rz - az) - abz * (rx - ax))
              local bCrossed = (sSide * rSide < 0) and (t > 0 and t < 1)
              if d2 < nPad * nPad or bCrossed then
                bHitFence = true
                local abLen = math.sqrt(abLenSq)
                -- Normal pointing toward the starting side (sx, sz)
                local nx, nz = -abz / abLen, abx / abLen
                if ((_nSx - cx) * nx + (_nSz - cz) * nz) < 0 then
                  nx, nz = -nx, -nz
                end
                -- Project candidate onto the safe side plane at distance nPad (smooth wall slide)
                local nSigned = (rx - cx) * nx + (rz - cz) * nz
                if nSigned < nPad then
                  rx = rx + nx * (nPad - nSigned)
                  rz = rz + nz * (nPad - nSigned)
                end
              end
            end
          end
        end
      end
    elseif bObj and bHit and oPost ~= nil and not tSeen[oPost] then
      tSeen[oPost] = true
      local bData, d = pcall(oPost.GetAllData, oPost)
      if bData and type(d) == "table" and d.sBoundaryType ~= "Null" and d.vPos ~= nil then
        local bIsAcrylic = d.sBoundaryType == "Acrylic"
        local px, py, pz = d.vPos:GetX(), d.vPos:GetY(), d.vPos:GetZ()
        local nTop = d.nWorldHeight or (py + 2.0)
        if nTop > nFeetY + 0.25 and py < nFeetY + 1.65 and
          not (_tPassPortals ~= nil and IsPointInOpenGate(_tPassPortals, px, nMidY, pz, bIsAcrylic)) then
          local dx, dz = rx - px, rz - pz
          local d2 = dx * dx + dz * dz
          local nPostPad = 0.22
          if d2 < nPostPad * nPostPad then
            bHitFence = true
            local nDist = math.sqrt(d2)
            if nDist > 1e-4 then
              rx = px + (dx / nDist) * nPostPad
              rz = pz + (dz / nDist) * nPostPad
            else
              rx, rz = _nSx, _nSz
            end
          end
        end
      end
    end
  end
  return rx, rz, bHitFence
end

-- ---- opened gate / door / cutout pass-through (vanilla RequestHabitatGateOpen animates GateModel open but
-- keeps the HabitatBoundary Flag_Building slab solid in MainPhysicsWorld; skip hits strictly inside opened
-- doorways and unobstructed wall cutouts/archways while keeping closed doors, side walls, and aquarium staff doors solid).
local GateDimensionsForEntity = function(_tWorld, _nGateID, _gy)
  local nHalfW, nHalfDepth, nMaxY = c_nGateOpenHalfWidth, c_nGateOpenHalfDepth, c_nGateOpenMaxY
  local bAllowAcrylic = false
  local sName = ResolveEntityName(_tWorld, _nGateID)
  if type(sName) == "string" and sName ~= "" then
    local sLow = string.lower(sName)
    if string.find(sLow, "trackairlock", 1, true) ~= nil or string.find(sLow, "transportgate", 1, true) ~= nil then
      return c_nGateWideHalfWidth, c_nGateWideHalfDepth, c_nGateWideMaxY, false
    elseif string.find(sLow, "glasstunnel", 1, true) ~= nil then
      return c_nGateGuestHalfWidth, 0.95, 2.85, true
    elseif string.find(sLow, "guestgate", 1, true) ~= nil then
      return c_nGateGuestHalfWidth, 0.90, 2.85, false
    elseif string.find(sLow, "small", 1, true) ~= nil then
      return c_nGateSmallHalfWidth, c_nGateOpenHalfDepth, c_nGateSmallMaxY, false
    end
  end
  local trApi = _tWorld and _tWorld.transform
  if trApi ~= nil and api.entity ~= nil and api.entity.FindEntityByName ~= nil then
    local bFpi, nFpi = pcall(api.entity.FindEntityByName, "FirstPersonInteraction", _nGateID)
    if bFpi and nFpi ~= nil then
      local bFt, ftr = pcall(trApi.CalculateWorldTransform, trApi, nFpi)
      local vFp = bFt and ftr ~= nil and (ftr.GetPos and ftr:GetPos() or (ftr.Pos and ftr:Pos()))
      if vFp ~= nil then
        local fy = vFp.GetY and vFp:GetY() or vFp:Y()
        if type(fy) == "number" and (fy - _gy) > 0.1 and (fy - _gy) < 1.2 then
          nHalfW, nMaxY = c_nGateSmallHalfWidth, c_nGateSmallMaxY
        end
      end
    end
  end
  return nHalfW, nHalfDepth, nMaxY, bAllowAcrylic
end

local CollectOpenGates = function()
  local nLocal, nRemote = s.nLocalOpenGate, s.nRemoteOpenGate
  local tPosGates = s.tOpenGates
  local tPortals = s.tOpenPortals
  local bHasPos = type(tPosGates) == "table" and next(tPosGates) ~= nil
  local bHasPortals = type(tPortals) == "table" and next(tPortals) ~= nil
  if nLocal == nil and nRemote == nil and not bHasPos and not bHasPortals then
    return nil
  end
  local bOk, tGates = pcall(function()
    local tWorld = WorldAPIs()
    local trApi = tWorld and tWorld.transform
    local tOut = {}
    local tIds = {}
    local tCoveredKeys = {}
    if nLocal ~= nil and not IsAquariumStaffDoorEntity(nLocal) then
      table.insert(tIds, {id = nLocal, key = "local"})
    end
    if nRemote ~= nil and nRemote ~= nLocal and not IsAquariumStaffDoorEntity(nRemote) then
      table.insert(tIds, {id = nRemote, key = "remote"})
    elseif nRemote ~= nil then
      tCoveredKeys["remote"] = true
    end
    if trApi ~= nil and trApi.CalculateWorldTransform ~= nil then
      for _, tEntry in ipairs(tIds) do
        local nGateID = tEntry.id
        local tr = trApi:CalculateWorldTransform(nGateID)
        local gx, gy, gz, fx, fz, rx, rz = ExtractPortalBasis(tr)
        if gx ~= nil then
          local nHalfW, nHalfDepth, nMaxY, bAllowAcrylic = GateDimensionsForEntity(tWorld, nGateID, gy)
          tCoveredKeys[tEntry.key] = true
          table.insert(tOut, {
            nId = nGateID,
            gx = gx, gy = gy, gz = gz,
            fx = fx, fz = fz,
            rx = rx, rz = rz,
            nHalfW = nHalfW,
            nHalfDepth = nHalfDepth,
            nMinY = c_nGateOpenMinY,
            nMaxY = nMaxY,
            bAllowAcrylic = bAllowAcrylic,
          })
        end
      end
    end
    if bHasPortals then
      for _, p in pairs(tPortals) do
        if type(p) == "table" and type(p.gx) == "number" and type(p.gz) == "number" then
          table.insert(tOut, p)
        end
      end
    end
    if bHasPos then
      for sKey, g in pairs(tPosGates) do
        if not tCoveredKeys[sKey] and type(g) == "table" and type(g.x) == "number" and type(g.z) == "number" then
          table.insert(tOut, {
            gx = g.x, gy = g.y or 0, gz = g.z,
            bRadial = true,
            nHalfW = g.nHalfW or c_nGateOpenHalfWidth,
            nMinY = c_nGateOpenMinY,
            nMaxY = g.nMaxY or c_nGateOpenMaxY,
          })
        end
      end
    end
    return #tOut > 0 and tOut or nil
  end)
  return bOk and tGates or nil
end

local CollectNearbyCutouts = function(_nX, _nY, _nZ, _tOut)
  local bOk, tRes = pcall(function()
    local tWorld = WorldAPIs()
    local sp = tWorld and tWorld.spatial
    local trApi = tWorld and tWorld.transform
    if sp == nil or sp.SphereQuery == nil or trApi == nil or trApi.CalculateWorldTransform == nil then
      return _tOut
    end
    local nFlags = (sp.Flag_Scenery or 0) | (sp.Flag_NonStaticScenery or 0) | (sp.Flag_Facility or 0)
    if nFlags == 0 then
      return _tOut
    end
    local tHits = sp:SphereQuery(Vector3:new(_nX, _nY, _nZ), 2.8, nFlags, 0, 24)
    if type(tHits) ~= "table" or #tHits == 0 then
      return _tOut
    end
    local tOut = _tOut
    for _, nEnt in ipairs(tHits) do
      local sName = ResolveEntityName(tWorld, nEnt)
      local tDim = ClassifyCutoutResource(sName)
      if tDim ~= nil then
        local tr = trApi:CalculateWorldTransform(nEnt)
        local gx, gy, gz, fx, fz, rx, rz = ExtractPortalBasis(tr)
        if gx ~= nil then
          local bBlockedByClosedDoor = s.fnHasClosedDoorAt ~= nil and s.fnHasClosedDoorAt(gx, gy, gz) == true
          if not bBlockedByClosedDoor then
            tOut = tOut or {}
            table.insert(tOut, {
              nId = nEnt,
              gx = gx, gy = gy, gz = gz,
              fx = fx, fz = fz,
              rx = rx, rz = rz,
              nHalfW = tDim.nHalfW,
              nHalfDepth = tDim.nHalfDepth,
              nMinY = c_nGateOpenMinY,
              nMaxY = tDim.nMaxY,
              bIsCutout = true,
            })
          end
        end
      end
    end
    return tOut
  end)
  return bOk and tRes or _tOut
end

-- Checks whether an uphill move from (sx, sy, sz) to (ex, ey, ez) follows a continuous walkable slope/path/stairs
-- (each <= 0.28 m sub-step rises <= c_nMaxStepUpM) rather than stepping abruptly onto a short wall or bench.
-- Returns (nVerifiedSweepClimb, bClimbAllowed).
local VerifyWalkableClimb = function(_nSx, _nSy, _nSz, _nEx, _nEy, _nEz, _nHorizDist, _nWalkH)
  local nClimb = _nEy - _nSy
  if nClimb <= 0 then
    return 0, true
  end
  if nClimb <= c_nMaxStepUpM then
    return nClimb, true
  end
  local nMaxClimb = math.max(c_nMaxStepUpM, _nHorizDist * c_nMaxSlopeTan)
  if nClimb > nMaxClimb then
    return 0, false
  end
  if _nHorizDist < 1e-4 then
    return 0, false
  end
  local nStartFeet = _nSy - _nWalkH
  local nStartGround, bAvail = TrySampleGroundY(_nSx, nStartFeet, _nSz, 0.60, 0.50)
  if not bAvail then
    return nClimb, true
  end
  -- Self-heal if vStartingPos dipped slightly below a crest/seam: anchor slope check to actual surface under feet.
  local nCurY = (nStartGround ~= nil and nStartGround > nStartFeet) and nStartGround or nStartFeet
  local nSteps = math.min(6, math.max(2, math.ceil(_nHorizDist / c_nSlopeSubstepM)))
  local dx, dz = _nEx - _nSx, _nEz - _nSz
  for i = 1, nSteps do
    local t = i / nSteps
    local nGy = TrySampleGroundY(_nSx + dx * t, nCurY, _nSz + dz * t, 0.95, 0.80)
    if nGy == nil then
      return 0, false
    end
    if (nGy - nCurY) > c_nMaxStepUpM then
      return 0, false
    end
    nCurY = nGy
  end
  return nClimb, true
end

local SweepAndSlideFiltered
SweepAndSlideFiltered = function(_nPhysWorld, _vStart, _vEnd, _nFlags, _nRadius, _nIters, _tOpenGates, _fnOrigSweep)
  if api.physics == nil or api.physics.SphereSweep == nil then
    return _fnOrigSweep(_nPhysWorld, _vStart, _vEnd, _nFlags, _nRadius, _nIters)
  end
  local sx = _vStart.GetX and _vStart:GetX() or _vStart:X()
  local sy = _vStart.GetY and _vStart:GetY() or _vStart:Y()
  local sz = _vStart.GetZ and _vStart:GetZ() or _vStart:Z()
  local ex = _vEnd.GetX and _vEnd:GetX() or _vEnd:X()
  local ey = _vEnd.GetY and _vEnd:GetY() or _vEnd:Y()
  local ez = _vEnd.GetZ and _vEnd:GetZ() or _vEnd:Z()
  local dx, dy, dz = ex - sx, ey - sy, ez - sz
  local nDist = math.sqrt(dx * dx + dy * dy + dz * dz)
  if nDist <= 1.192093e-7 then
    return _vStart
  end
  local vx, vy, vz = dx / nDist, dy / nDist, dz / nDist
  local nR = type(_nRadius) == "number" and _nRadius or 0.15
  local vSweepStart = Vector3:new(sx - vx * nR, sy - vy * nR, sz - vz * nR)
  local vSweepEnd = Vector3:new(ex + vx * nR, ey + vy * nR, ez + vz * nR)
  local tResults = api.physics.SphereSweep(_nPhysWorld, vSweepStart, vSweepEnd, nR, _nFlags, 8)
  local tClosest = nil
  if type(tResults) == "table" then
    for _, tRes in ipairs(tResults) do
      local vN = tRes.vNormal
      if vN ~= nil then
        local nx = vN.GetX and vN:GetX() or vN:X()
        local ny = vN.GetY and vN:GetY() or vN:Y()
        local nz = vN.GetZ and vN:GetZ() or vN:Z()
        -- Ignore walkable floor/ramp/sloped-path surfaces (ny >= c_nMinWalkableNormalY) so uphill sweeps never snag on floors.
        if ny < c_nMinWalkableNormalY and (nx * vx + ny * vy + nz * vz) < -0.001 then
          local vImp = tRes.vImpactPoint or tRes.vCentrePoint
          local hx, hy, hz
          if vImp ~= nil then
            hx = vImp.GetX and vImp:GetX() or vImp:X()
            hy = vImp.GetY and vImp:GetY() or vImp:Y()
            hz = vImp.GetZ and vImp:GetZ() or vImp:Z()
          else
            local nHitD = type(tRes.nDistance) == "number" and tRes.nDistance or 0
            hx, hy, hz = sx + vx * (nHitD - nR), sy + vy * (nHitD - nR), sz + vz * (nHitD - nR)
          end
          if _tOpenGates == nil or not IsPointInOpenGate(_tOpenGates, hx, hy, hz) then
            if tClosest == nil or (tRes.nDistance or math.huge) < (tClosest.nDistance or math.huge) then
              tClosest = tRes
            end
          end
        end
      end
    end
  end
  if tClosest == nil then
    return _vEnd
  end
  local nAdvance = Clamp((tClosest.nDistance or 0) - nR, 0, nDist)
  local ix, iy, iz = sx + vx * nAdvance, sy + vy * nAdvance, sz + vz * nAdvance
  local vN = tClosest.vNormal
  local nx = vN.GetX and vN:GetX() or vN:X()
  local ny = vN.GetY and vN:GetY() or vN:Y()
  local nz = vN.GetZ and vN:GetZ() or vN:Z()
  local hLen = math.sqrt(nx * nx + nz * nz)
  if hLen > 1e-4 then
    nx, ny, nz = nx / hLen, 0, nz / hLen
  end
  local penDot = (ix - ex) * nx + (iy - ey) * ny + (iz - ez) * nz
  local nPush = 0.01
  local vNextStart = Vector3:new(ix + nx * nPush, iy + ny * nPush, iz + nz * nPush)
  local vNextEnd = Vector3:new(ex + nx * (penDot + nPush), ey + ny * (penDot + nPush), ez + nz * (penDot + nPush))
  if (_nIters or 0) > 0 then
    return SweepAndSlideFiltered(_nPhysWorld, vNextStart, vNextEnd, _nFlags, nR, _nIters - 1, _tOpenGates, _fnOrigSweep)
  end
  return vNextStart
end

local InstallCameraWrap = function()
  local bOk, WalkingCamera = pcall(require, "Components.Cameras.WalkingCamera")
  if not bOk or type(WalkingCamera) ~= "table" or rawget(WalkingCamera, "__PZ2CoopOriginalAdvance") ~= nil then
    return
  end
  -- Fix vanilla short-wall, chair/prop, and fence walkthroughs: WalkingCamera.AdvanceWalkingWASD only sweeps a
  -- 15 cm sphere at EYE height (1.55 m) and omits Flag_Prop and spatial HabitatBoundary walls. Wrapping SweepAndSlide
  -- runs body capsule sweeps at head/chest/waist/knee (following verified walkable slopes/paths while staying flat on
  -- abrupt wall/bench steps, plus ignoring walkable floor normals and opened habitat gate doorways) and smooth 2D
  -- HabitatBoundary wall-sliding, then validates vertical step-up at the post-collision (rx, rz).
  if type(WalkingCamera.SweepAndSlide) == "function" and rawget(WalkingCamera, "__PZ2CoopOriginalSweep") == nil then
    local fnOrigSweep = WalkingCamera.SweepAndSlide
    rawset(WalkingCamera, "__PZ2CoopOriginalSweep", fnOrigSweep)
    local bSweepDepth = false
    WalkingCamera.SweepAndSlide = function(_nPhysWorld, _vStart, _vEnd, _nFlags, _nRadius, _nIters)
      if bSweepDepth or _vStart == nil or _vEnd == nil then
        return fnOrigSweep(_nPhysWorld, _vStart, _vEnd, _nFlags, _nRadius, _nIters)
      end
      bSweepDepth = true
      local bOkSweep, vBest = pcall(function()
        local sx, sy, sz = _vStart:GetX(), _vStart:GetY(), _vStart:GetZ()
        local ex, ey, ez = _vEnd:GetX(), _vEnd:GetY(), _vEnd:GetZ()
        local dx0, dz0 = ex - sx, ez - sz
        local nGoalLenSq = dx0 * dx0 + dz0 * dz0
        if nGoalLenSq < 1e-8 then
          return Vector3:new(sx, math.min(ey, sy), sz)
        end
        local nWalkH = WalkingHeight()
        local nGoalDist = math.sqrt(nGoalLenSq)
        local nSweepClimb, bClimbAllowed = VerifyWalkableClimb(sx, sy, sz, ex, ey, ez, nGoalDist, nWalkH)
        -- Include Flag_Prop so chairs, benches, tables, and scenery props are solid, EXCEPT when stepping
        -- through an opened gate/door doorway, unobstructed cutout/archway, or sitting on a seat.
        local bNearGate = IsNearOpenGate(sx, sy, sz) or IsNearOpenGate(ex, sy, ez)
        local tOpenGates = CollectOpenGates()
        local nMidFeetY = sy - nWalkH + 0.85
        tOpenGates = CollectNearbyCutouts((sx + ex) * 0.5, nMidFeetY, (sz + ez) * 0.5, tOpenGates)
        local bInPortal = bNearGate or
          (tOpenGates ~= nil and (IsPointInOpenGate(tOpenGates, sx, nMidFeetY, sz) or
            IsPointInOpenGate(tOpenGates, ex, nMidFeetY, ez)))
        local nBandFlags = type(_nFlags) == "number" and _nFlags or 0
        if not bInPortal and s.tSeatOverride == nil and api.physics ~= nil and type(api.physics.Flag_Prop) == "number" then
          nBandFlags = nBandFlags | api.physics.Flag_Prop
        end
        local nHeadR = math.max(type(_nRadius) == "number" and _nRadius or 0.15, 0.16)
        -- Sweep all body bands parallel to verified walkable slopes/paths, or strictly horizontally (nSweepClimb = 0)
        -- on flat ground, downhill, and abrupt wall/bench steps so walls/props are never ramped diagonally upward.
        local vBandGoal = Vector3:new(ex, sy + nSweepClimb, ez)
        local vRes = SweepAndSlideFiltered(_nPhysWorld, _vStart, vBandGoal, _nFlags, nHeadR, _nIters, tOpenGates, fnOrigSweep)
        local rx, rz = vRes:GetX(), vRes:GetZ()
        local nBestProj = (rx - sx) * dx0 + (rz - sz) * dz0
        local bBlocked = ((rx - ex) ^ 2 + (rz - ez) ^ 2) > 2.5e-5
        -- Chest (-0.50 m), waist (-0.90 m), and knee (-1.25 m) catch low benches, chairs, tables, and short walls
        -- while still fitting cleanly through standard doorways, cutouts, and opened habitat gates.
        for _, tBand in ipairs({{0.50, c_nBodyCapsuleRadius}, {0.90, 0.16}, {1.25, 0.16}}) do
          local nDrop, nBandR = tBand[1], tBand[2]
          local vLowStart = Vector3:new(sx, sy - nDrop, sz)
          local vLowEnd = Vector3:new(ex, sy + nSweepClimb - nDrop, ez)
          local vLowRes = SweepAndSlideFiltered(_nPhysWorld, vLowStart, vLowEnd, nBandFlags, nBandR, _nIters, tOpenGates, fnOrigSweep)
          if vLowRes ~= nil then
            local lx, lz = vLowRes:GetX(), vLowRes:GetZ()
            if ((lx - ex) ^ 2 + (lz - ez) ^ 2) > 2.5e-5 then
              bBlocked = true
            end
            local nProj = (lx - sx) * dx0 + (lz - sz) * dz0
            if nProj < nBestProj - 1e-4 then
              nBestProj = nProj
              rx, rz = lx, lz
            end
          end
        end
        -- Solid habitat barrier fences (Flag_HabitatBoundary) with smooth wall-sliding & portal-aware pass-through.
        if s.tSeatOverride == nil then
          local fx, fz, bFence = ResolveFenceCollision(sx, sy, sz, rx, rz, tOpenGates)
          if bFence then
            rx, rz = fx, fz
            bBlocked = true
          end
        end
        -- Resolve vertical Y strictly at the post-collision (rx, rz) so wall hits never ratchet the player upward,
        -- while continuous uphill slopes/paths (including wall-sliding along handrails) climb without clipping.
        local ry = ey
        if bBlocked then
          if ry > sy then
            local nMovedDist = math.sqrt((rx - sx) ^ 2 + (rz - sz) ^ 2)
            if nMovedDist < 0.01 then
              ry = sy
            else
              local nSlideMaxClimb = math.max(c_nMaxStepUpM, nMovedDist * c_nMaxSlopeTan)
              local nHitY, bAvail = TrySampleGroundY(rx, sy - nWalkH, rz, nSlideMaxClimb, 0.60)
              if nHitY ~= nil then
                local nCandY = math.min(nHitY + nWalkH, sy + nSlideMaxClimb)
                local _, bSlideOk = VerifyWalkableClimb(sx, sy, sz, rx, nCandY, rz, nMovedDist, nWalkH)
                ry = bSlideOk and nCandY or sy
              elseif bAvail then
                ry = sy
              else
                ry = sy
              end
            end
          end
        elseif not bClimbAllowed then
          -- Unblocked sheer cliff / unclimbable ledge: stop at start instead of walking horizontally underground at sy.
          return Vector3:new(sx, sy, sz)
        end
        -- Reject climbing steep curved wall faces / bevels (surface normal.y < 0.65 => steeper than ~49 deg).
        if ry > sy + 0.02 and api.physics ~= nil and api.physics.RayCast ~= nil then
          local nTargetFeetY = ry - nWalkH
          local bOnElevatedPath = false
          pcall(function()
            local tWorld = WorldAPIs()
            if tWorld and tWorld.volumes and tWorld.volumes.GetNavPartFromRay then
              local oNav, vNavHit = tWorld.volumes:GetNavPartFromRay(Vector3:new(rx, nTargetFeetY + 0.50, rz),
                Vector3:new(0, -1, 0))
              if oNav ~= nil and not oNav:IsGrounded() and vNavHit ~= nil then
                local nNavY = vNavHit.GetY and vNavHit:GetY() or vNavHit:Y()
                if type(nNavY) == "number" and math.abs(nNavY - nTargetFeetY) <= 0.25 then
                  bOnElevatedPath = true
                end
              end
            end
          end)
          if not bOnElevatedPath then
            local nCheckFlags = nBandFlags
            if type(api.physics.Flag_Landscape) == "number" then
              nCheckFlags = nCheckFlags | api.physics.Flag_Landscape
            end
            local nRayTop = math.max(sy, ry) - 0.15
            local nRayBottom = math.min(sy - 2.0, nTargetFeetY - 0.50)
            local tHits = api.physics.RayCast(_nPhysWorld, Vector3:new(rx, nRayTop, rz),
              Vector3:new(rx, nRayBottom, rz), nCheckFlags, 1)
            local tHit = type(tHits) == "table" and tHits[1] or nil
            if tHit ~= nil and tHit.vNormal ~= nil then
              local bNearFeet = true
              local nHitY = nil
              if tHit.vImpactPoint ~= nil then
                nHitY = tHit.vImpactPoint.GetY and tHit.vImpactPoint:GetY() or tHit.vImpactPoint:Y()
              elseif type(tHit.nDistance) == "number" then
                nHitY = nRayTop - tHit.nDistance
              end
              if type(nHitY) == "number" and nHitY == nHitY then
                bNearFeet = nHitY >= nTargetFeetY - 0.35 and nHitY <= nTargetFeetY + 0.35
              end
              if bNearFeet then
                local vN = tHit.vNormal
                local ny = vN.GetY and vN:GetY() or (vN.Y and vN:Y() or 1.0)
                if type(ny) == "number" and ny < c_nMinWalkableNormalY then
                  if tOpenGates ~= nil and IsPointInOpenGate(tOpenGates, rx, nTargetFeetY, rz) then
                    ry = sy
                  else
                    rx, ry, rz = sx, sy, sz
                  end
                end
              end
            end
          end
        end
        return Vector3:new(rx, ry, rz)
      end)
      bSweepDepth = false
      if bOkSweep and vBest ~= nil then
        return vBest
      end
      return fnOrigSweep(_nPhysWorld, _vStart, _vEnd, _nFlags, _nRadius, _nIters)
    end
    Log("walking collision wrapped (slope-aware capsule sweeps + curved-wall anti-climb)")
  end

  -- Snap WalkingCamera immediately onto door exit position when exiting a vehicle (eliminates vanilla's
  -- vDispHint slide from the trailing 3P vehicle camera 5.5 m behind the buggy into the side door!).
  if type(WalkingCamera.Init) == "function" and rawget(WalkingCamera, "__PZ2CoopOriginalInit") == nil then
    local fnOrigInit = WalkingCamera.Init
    rawset(WalkingCamera, "__PZ2CoopOriginalInit", fnOrigInit)
    WalkingCamera.Init = function(_tData, _tWorldAPIs, _tInitTable, ...)
      local r = fnOrigInit(_tData, _tWorldAPIs, _tInitTable, ...)
      local tExit = s.tPendingVehicleExit
      if tExit ~= nil and type(_tData) == "table" and type(_tData.tFinal) == "table" then
        s.tPendingVehicleExit = nil
        local vPos = (_tInitTable and _tInitTable.vStartingPos) or tExit.vPos
        local vYPR = (_tInitTable and _tInitTable.vStartingYPR) or tExit.vYPR
        if vPos ~= nil then
          _tData.tFinal.vCameraPos = vPos
          if _tData.tFinal.transformQ ~= nil and _tData.tFinal.transformQ.WithPos ~= nil then
            _tData.tFinal.transformQ = _tData.tFinal.transformQ:WithPos(vPos)
          end
          local ex, ey, ez = ReadVec3(vPos)
          if ex ~= nil then
            s.tFollow = {x = ex, y = ey, z = ez}
            s.tOwnPrev = {x = ex, z = ez}
            s.nOwnGroundY = ey - WalkingHeight()
            s.nOcclRatio = nil
          end
        end
        if vYPR ~= nil then
          local eyaw, epitch = ReadVec3(vYPR)
          if eyaw ~= nil then
            _tData.tFinal.vCameraYPR = Vector3:new(eyaw, epitch or 0, 0)
            s.nBodyYaw = eyaw
          end
        end
        if type(_tData.tDelta) == "table" then
          _tData.tDelta.vDispHint = Vector3:new(0, 0, 0)
          _tData.tDelta.vDisplace = Vector3:new(0, 0, 0)
          _tData.tDelta.vYPRCamera = Vector3:new(0, 0, 0)
        end
        s.nCamDist = s.bThirdPerson and (s.nCamTarget or c_nThirdBack) or 0
      end
      return r
    end
  end

  local fnOriginal = WalkingCamera.Advance
  rawset(WalkingCamera, "__PZ2CoopOriginalAdvance", fnOriginal)
  local bErrorLogged = false
  WalkingCamera.Advance = function(_tData, _tWorldAPIs, _nUnscaledDeltaTime, ...)
    -- When the Radial Emote Wheel is open, release WalkingCamera's cursor capture and pause walking/look input
    -- so the player gets a free visible cursor to pick wedges & switch pages without spinning the camera.
    if s.fnIsWheelOpen ~= nil and s.fnIsWheelOpen() then
      if type(_tData) == "table" then
        pcall(function()
          local CameraLogic = require("Components.Cameras.CameraLogic")
          if CameraLogic.ReleaseCursorRequest ~= nil then
            CameraLogic.ReleaseCursorRequest(_tData, _tWorldAPIs)
          end
          if CameraLogic.ZeroDeltas ~= nil then
            CameraLogic.ZeroDeltas(_tData)
          end
        end)
        if _tData.cursorRequest ~= nil then
          pcall(function() _tData.cursorRequest:Release() end)
          _tData.cursorRequest = nil
        end
        _tData.nDragType = 0
        _tData.nPrevDragType = 0
      end
      local bApplied, sError = pcall(ApplyThirdPerson, _tData, _nUnscaledDeltaTime)
      if not bApplied and not bErrorLogged then
        bErrorLogged = true
        Log("third person error: " .. tostring(sError))
      end
      return
    end
    local tWalk = type(_tData) == "table" and _tData.tWalkingData
    if tWalk ~= nil then
      local bCrouchPressed = _tWorldAPIs ~= nil and _tWorldAPIs.InputManager ~= nil and
        _tWorldAPIs.InputManager:GetKeyPressed("GameCamera_Crouch")
      if bCrouchPressed then
        tWalk.nWalkingHeightIndex = 1
      elseif tWalk.nWalkingHeightIndex == 1 then
        tWalk.nWalkingHeightIndex = 2
      end
    end
    -- Damp vanilla WalkingCamera's ~0.7 s residual horizontal glide tail when all movement input is released
    -- so ending a sprint halts crisply without ice-skating or lingering run animations.
    if type(_tData) == "table" and type(_tData.tDelta) == "table" and _tData.tDelta.vDisplace ~= nil and
      _tWorldAPIs ~= nil and _tWorldAPIs.InputManager ~= nil then
      pcall(function()
        local inp = _tWorldAPIs.InputManager
        local bMoveKey = inp.GetKeyDown ~= nil and (
          inp:GetKeyDown("GameCamera_Forward") or inp:GetKeyDown("GameCamera_Backward") or
          inp:GetKeyDown("GameCamera_Left") or inp:GetKeyDown("GameCamera_Right"))
        local nStickR = inp.GetGamepadControlValue ~= nil and (inp:GetGamepadControlValue("GameCamera_LeftRightValue") or 0) or 0
        local nStickF = inp.GetGamepadControlValue ~= nil and (inp:GetGamepadControlValue("GameCamera_ForwardBackwardValue") or 0) or 0
        if not bMoveKey and math.abs(nStickR) < 0.05 and math.abs(nStickF) < 0.05 then
          local vD = _tData.tDelta.vDisplace
          local dx = vD.GetX and vD:GetX() or vD:X()
          local dy = vD.GetY and vD:GetY() or vD:Y()
          local dz = vD.GetZ and vD:GetZ() or vD:Z()
          local nDt = type(_nUnscaledDeltaTime) == "number" and _nUnscaledDeltaTime > 0 and _nUnscaledDeltaTime or (1 / 60)
          local nDecay = math.exp(-c_nStopDampRate * nDt)
          dx, dz = dx * nDecay, dz * nDecay
          if dx * dx + dz * dz < 0.06 * 0.06 then
            dx, dz = 0, 0
          end
          _tData.tDelta.vDisplace = Vector3:new(dx, dy, dz)
        end
      end)
    end
    -- In first person, disable sprinting while moving backwards (S / S+A / S+D) or pure sideways strafing (A / D),
    -- matching AAA FPS locomotion (full sprint only on forward & forward-diagonals W / W+A / W+D).
    local tAdvanceWorld = _tWorldAPIs
    if not s.bThirdPerson and _tWorldAPIs ~= nil and _tWorldAPIs.InputManager ~= nil then
      local bBlockSprint = false
      pcall(function()
        local inp = _tWorldAPIs.InputManager
        local bFwd = inp.GetKeyDown ~= nil and inp:GetKeyDown("GameCamera_Forward") == true
        local bBack = inp.GetKeyDown ~= nil and inp:GetKeyDown("GameCamera_Backward") == true
        local bLeft = inp.GetKeyDown ~= nil and inp:GetKeyDown("GameCamera_Left") == true
        local bRight = inp.GetKeyDown ~= nil and inp:GetKeyDown("GameCamera_Right") == true
        local nStickF = inp.GetGamepadControlValue ~= nil and (inp:GetGamepadControlValue("GameCamera_ForwardBackwardValue") or 0) or 0
        local nStickR = inp.GetGamepadControlValue ~= nil and (inp:GetGamepadControlValue("GameCamera_LeftRightValue") or 0) or 0
        local nFwdAxis = (bFwd and 1 or 0) - (bBack and 1 or 0) + nStickF
        local nSideAxis = (bRight and 1 or 0) - (bLeft and 1 or 0) + nStickR
        if nFwdAxis < -0.15 or (nFwdAxis <= 0.15 and math.abs(nSideAxis) > 0.15) then
          bBlockSprint = true
        end
      end)
      if bBlockSprint then
        local origInp = _tWorldAPIs.InputManager
        local tInpProxy = setmetatable({}, {
          __index = function(_, _k)
            if _k == "GetKeyDown" then
              return function(_, _sKey)
                if _sKey == "GameCamera_SpeedMod" then
                  return false
                end
                return origInp:GetKeyDown(_sKey)
              end
            end
            local v = origInp[_k]
            if type(v) == "function" then
              return function(_, ...)
                return v(origInp, ...)
              end
            end
            return v
          end,
        })
        tAdvanceWorld = setmetatable({InputManager = tInpProxy}, {__index = _tWorldAPIs})
      end
    end
    fnOriginal(_tData, tAdvanceWorld, _nUnscaledDeltaTime, ...)
    if tWalk ~= nil and tWalk.nWalkingHeightIndex == 1 then
      tWalk.nWalkingHeightIndex = 2
    end
    -- Keep WalkingCamera's underlying position locked to the seat choreography (walk-up, sit-down, seated, stand-up)
    -- so mouse/stick orbit stays free while releasing control after standing up never teleports back.
    if s.tSeatOverride ~= nil and type(_tData) == "table" and type(_tData.tFinal) == "table" then
      _tData.tFinal.vCameraPos = Vector3:new(s.tSeatOverride.x, s.tSeatOverride.y + WalkingHeight(), s.tSeatOverride.z)
      if type(_tData.tDelta) == "table" then
        _tData.tDelta.vDisplace = Vector3:new(0, 0, 0)
        _tData.tDelta.vDispHint = Vector3:new(0, 0, 0)
      end
    elseif not s.bOwnInWater and type(_tData) == "table" and type(_tData.tFinal) == "table" and
      _tData.tFinal.vCameraPos ~= nil then
      -- Ironclad floor-clip guard: if smoothing over a sharp slope crest or angled path seam ever dips the eye
      -- below ground + c_nMinEyeAboveGround (0.90 m, vanilla HeightLow), lift it back above the floor.
      -- Passing nMaxUp = nWalkH starts the ray at cy + 0.15 and accepts only hy <= cy (never hits ceilings above eye).
      local vEye = _tData.tFinal.vCameraPos
      local cx, cy, cz = vEye:GetX(), vEye:GetY(), vEye:GetZ()
      local nWalkH = WalkingHeight()
      local nFloorY = TrySampleGroundY(cx, cy - nWalkH, cz, nWalkH, 0.50)
      if nFloorY ~= nil and cy < nFloorY + c_nMinEyeAboveGround then
        local vSafe = Vector3:new(cx, nFloorY + c_nMinEyeAboveGround, cz)
        _tData.tFinal.vCameraPos = vSafe
        if _tData.tFinal.transformQ ~= nil and _tData.tFinal.transformQ.WithPos ~= nil then
          _tData.tFinal.transformQ = _tData.tFinal.transformQ:WithPos(vSafe)
        end
      end
    end
    local bApplied, sError = pcall(ApplyThirdPerson, _tData, _nUnscaledDeltaTime)
    if not bApplied and not bErrorLogged then
      bErrorLogged = true
      Log("third person error: " .. tostring(sError))
    end
  end
  Log("walking camera wrapped (third person available)")
end

-- ---- own avatar body ----------------------------------------------------------------------------
local ReadOwnAvatar = function()
  local GameDatabase = require("Database.GameDatabase")
  local StartScreenAvatar = require("StartScreen.Shared.StartScreenAvatar")
  local tPlayer = GameDatabase.GetPlayer(GameDatabase.GetPlayerKey(api.player.GetGameOwner()))
  local tSaved = tPlayer and tPlayer:GetMainAvatarData()
  return tSaved and StartScreenAvatar.AvatarVersionCheck(tSaved.tData), StartScreenAvatar
end

local DestroyOwnBody = function()
  if s.tOwnBody ~= nil then
    Avatar.DetachProp(s.tOwnBody.tAnim)
    Destroy(s.tOwnBody.tParent)
  end
  s.tOwnBody, s.tOwnPrev, s.nBodyYaw, s.nOwnGroundY, s.nOwnSpeed, s.nOwnSmoothSpeed = nil, nil, nil, nil, 0, 0
  s.nOwnYawRate, s.bOwnInWater, s.nOwnWaterSurface, s.nBobAmp = 0, false, nil, 0
end

local TurnBody = function(_t, _nDt)
  if s.tSeatOverride ~= nil then
    s.nBodyYaw = s.tSeatOverride.yaw
    s.tOwnPrev = {x = _t.x, z = _t.z}
    local nSeatSpeed = type(s.tSeatOverride.nWalkSpeed) == "number" and s.tSeatOverride.nWalkSpeed or 0
    local nSeatYawRate = type(s.tSeatOverride.nYawRate) == "number" and s.tSeatOverride.nYawRate or 0
    return nSeatSpeed, nSeatYawRate, false, false
  end
  if _t.bFirstPerson == true then
    local nCurYaw = s.nBodyYaw ~= nil and s.nBodyYaw or _t.yaw
    local tNextPrev = {x = _t.x, z = _t.z}
    local nSpeed = 0
    local nRelMoveAngle = nil
    if s.tOwnPrev ~= nil and _nDt > 0 then
      local dx, dz = _t.x - s.tOwnPrev.x, _t.z - s.tOwnPrev.z
      local nDist = math.sqrt(dx * dx + dz * dz)
      if nDist <= c_nSnapDistance then
        nSpeed = nDist / _nDt
        if nDist > 1e-4 then
          nRelMoveAngle = WrapAngle(math.atan(dx, dz) - nCurYaw)
        end
      end
    end
    local nYawRate = 0
    if _nDt > 0 then
      local nLookDiff = WrapAngle(_t.yaw - nCurYaw)
      if nSpeed >= c_nTurnMinSpeed then
        local nMax = c_nTurnRateSlow * _nDt
        local nDelta = Clamp(nLookDiff, -nMax, nMax)
        nCurYaw = WrapAngle(nCurYaw + nDelta)
        nYawRate = nDelta / _nDt
      elseif math.abs(nLookDiff) > c_nFirstPersonBodySlack then
        local nExcess = nLookDiff > 0 and (nLookDiff - c_nFirstPersonBodySlack) or (nLookDiff + c_nFirstPersonBodySlack)
        local nMax = c_nTurnRateSlow * _nDt
        local nDelta = Clamp(nExcess, -nMax, nMax)
        nCurYaw = WrapAngle(nCurYaw + nDelta)
        nYawRate = nDelta / _nDt
      end
    end
    s.nBodyYaw = nCurYaw
    s.tOwnPrev = tNextPrev
    return nSpeed, nYawRate, false, false, nRelMoveAngle
  end
  local nNextYaw, tNextPrev, nSpeed, nYawRate, bRev, bLeft =
    StepBodyYaw(s.tOwnPrev, s.nBodyYaw, _t.x, _t.z, _t.yaw, _nDt)
  s.nBodyYaw = nNextYaw
  s.tOwnPrev = tNextPrev
  return nSpeed, nYawRate, bRev, bLeft
end

local AdvanceOwnAvatar = function(_tBody, _nDt)
  if _tBody.co == nil then
    local bOk, tAvatar = pcall(ReadOwnAvatar)
    if not bOk or tAvatar == nil then
      Log("own avatar not readable: " .. tostring(bOk and "no saved avatar" or tAvatar))
      s.bOwnUnavailable = true
      return
    end
    Log("building own avatar (group " .. tostring(tAvatar.group) .. ")")
    _tBody.sGroup = tAvatar.group
    local sInitClip = (_tBody.nVehicleParent ~= nil and s.tVehicleOwnOverride ~= nil and s.tVehicleOwnOverride.clip) or nil
    _tBody.co = coroutine.create(function()
      local nAvatar, bAnimated, tMeta = Avatar.CreateAnimated(tAvatar, _tBody.tParent.nId, "player", sInitClip)
      _tBody.nAvatar = nAvatar
      _tBody.tAnim = Avatar.CreateAnimState(tAvatar.group, bAnimated, tMeta, sInitClip)
      if sInitClip ~= nil and _tBody.tAnim ~= nil then
        _tBody.tAnim.sOverrideSuffix = sInitClip
      end
    end)
  end
  if coroutine.status(_tBody.co) ~= "dead" and _tBody.nAge < c_nAvatarTimeout then
    _tBody.nAge = _tBody.nAge + _nDt
    local bOk, sError = coroutine.resume(_tBody.co)
    if not bOk then
      Log("own avatar build error: " .. tostring(sError))
      s.bOwnUnavailable = true
      return
    end
    if coroutine.status(_tBody.co) == "dead" then
      Log(string.format("own avatar built after %.1f s (entity %s, animated %s)", _tBody.nAge,
        tostring(_tBody.nAvatar), tostring(_tBody.tAnim and _tBody.tAnim.bAnimated == true)))
    elseif _tBody.nAge >= c_nAvatarTimeout then
      Log("own avatar build still waiting after " .. c_nAvatarTimeout .. " s, stopped resuming it")
    end
  end
end

local DestroyVehicleExitPrebuild = function()
  local tPre = s.tVehicleExitPrebuild
  s.tVehicleExitPrebuild = nil
  if tPre ~= nil and not tPre.bAdopted then
    if tPre.tAnim ~= nil then
      Avatar.DetachProp(tPre.tAnim)
    end
    Destroy(tPre.tParent)
  end
end

-- Pre-builds the walking own avatar at the vehicle door exit spot before switching the camera to WalkingCamera,
-- then adopts it seamlessly as s.tOwnBody on the exact same frame the camera moves (zero pop-in!).
local UpdateVehicleExitPrebuild = function(_nDt)
  local tPre = s.tVehicleExitPrebuild
  if tPre == nil then
    return
  end
  local nDt = (type(_nDt) == "number" and _nDt > 0) and math.min(_nDt, 0.1) or (1 / 60)
  tPre.nWaitTime = (tPre.nWaitTime or 0) + nDt

  local CommitExit = function(_bAdopt)
    s.tVehicleExitPrebuild = nil
    s.tPendingVehicleExit = {vPos = tPre.vPos, vYPR = tPre.vYPR}
    if _bAdopt and tPre.nAvatar ~= nil then
      tPre.bAdopted = true
      if s.tOwnBody ~= nil then
        DestroyOwnBody()
      end
      local bStartHeadHide = not s.bThirdPerson
      if bStartHeadHide and tPre.tAnim ~= nil and Avatar.SetHeadHidden ~= nil then
        Avatar.SetHeadHidden(tPre.tAnim, tPre.nAvatar, true)
      end
      s.tOwnBody = {
        nAge = tPre.nAge or 0,
        co = tPre.co,
        sGroup = tPre.sGroup,
        tParent = tPre.tParent,
        nAvatar = tPre.nAvatar,
        tAnim = tPre.tAnim,
        bHidden = false,
        bHeadHidden = bStartHeadHide,
        nVehicleParent = nil,
      }
      s.nBodyYaw = tPre.yaw
      s.tOwnPrev = {x = tPre.x, z = tPre.z}
      s.nOwnGroundY = tPre.y
      s.tVehicleOwnOverride = nil
      s.bOwnVehicleOverrideWasActive = false
      s.nVehicleExitAdoptUntil = (s.nClock or 0) + 0.75
      Log("adopted pre-built vehicle exit avatar seamlessly (zero pop-in)")
    else
      if tPre.tAnim ~= nil then
        Avatar.DetachProp(tPre.tAnim)
      end
      Destroy(tPre.tParent)
    end
    if type(tPre.fnOnReady) == "function" then
      pcall(tPre.fnOnReady)
    end
  end

  if s.bOwnUnavailable or tPre.nWaitTime >= 0.80 then
    CommitExit(false)
    return
  end
  if not IsReady(tPre.tParent, nDt) then
    if tPre.tParent.bFailed then
      CommitExit(false)
    end
    return
  end
  local bOk, sErr = pcall(AdvanceOwnAvatar, tPre, nDt)
  if not bOk then
    Log("vehicle exit prebuild avatar error: " .. tostring(sErr))
    CommitExit(false)
    return
  end
  if tPre.nAvatar ~= nil and tPre.co ~= nil and coroutine.status(tPre.co) == "dead" then
    local nPreBack = (not s.bThirdPerson) and c_nFirstPersonBodyBack or 0
    Place(tPre.tParent, tPre.x - math.sin(tPre.yaw) * nPreBack, tPre.y, tPre.z - math.cos(tPre.yaw) * nPreBack, tPre.yaw, 0, 0)
    CommitExit(true)
  end
end

local UpdateOwnBody = function(_nDt)
  local tVehOwn = s.tVehicleOwnOverride
  if tVehOwn ~= nil and not s.bOwnUnavailable then
    local nWantVehParent = tVehOwn.nVehicle
    if s.tOwnBody ~= nil and s.tOwnBody.nVehicleParent ~= nWantVehParent then
      DestroyOwnBody()
    end
    if s.tOwnBody == nil then
      if nWantVehParent ~= nil and type(tVehOwn.lx) == "number" then
        s.tOwnBody = {
          nAge = 0,
          nVehicleParent = nWantVehParent,
          tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopOwnBody", nil,
            PoseTransform(tVehOwn.lx, tVehOwn.ly, tVehOwn.lz, 0, 0, 0), nWantVehParent),
        }
      else
        s.tOwnBody = {
          nAge = 0,
          nVehicleParent = nil,
          tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopOwnBody", nil,
            PoseTransform(tVehOwn.x, tVehOwn.y, tVehOwn.z, tVehOwn.yaw, tVehOwn.pitch, tVehOwn.roll)),
        }
      end
    end
    local tBody = s.tOwnBody
    if not IsReady(tBody.tParent, _nDt) then
      if tBody.tParent.bFailed then
        s.bOwnUnavailable = true
      end
      return
    end
    s.nBodyYaw = tVehOwn.yaw or 0
    s.nOwnGroundY = tVehOwn.y
    s.nOwnSpeed, s.nOwnSmoothSpeed, s.nOwnYawRate = 0, 0, 0
    s.bOwnInWater, s.nOwnWaterSurface = false, nil
    if tBody.nVehicleParent ~= nil and type(tVehOwn.lx) == "number" then
      -- Parented directly to the vehicle: update local TransformQ only when seat or calibration changes (zero twitch).
      local bChanged = tBody.nLastLX == nil or math.abs(tBody.nLastLX - tVehOwn.lx) > 1e-4 or
        math.abs(tBody.nLastLY - tVehOwn.ly) > 1e-4 or math.abs(tBody.nLastLZ - tVehOwn.lz) > 1e-4
      if bChanged then
        tBody.nLastLX, tBody.nLastLY, tBody.nLastLZ = tVehOwn.lx, tVehOwn.ly, tVehOwn.lz
        Place(tBody.tParent, tVehOwn.lx, tVehOwn.ly, tVehOwn.lz, 0, 0, 0)
      end
    else
      Place(tBody.tParent, tVehOwn.x, tVehOwn.y, tVehOwn.z, tVehOwn.yaw or 0, tVehOwn.pitch or 0, tVehOwn.roll or 0)
    end
    local bOk, sError = pcall(AdvanceOwnAvatar, tBody, _nDt)
    if not bOk then
      Log("own avatar error: " .. tostring(sError))
      s.bOwnUnavailable = true
      return
    end
    if tBody.nAvatar ~= nil then
      local sClip = tVehOwn.clip or "$OnRideSitIdle"
      if tBody.tAnim ~= nil and tBody.tAnim.sOverrideSuffix ~= sClip then
        Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sClip, 0.18)
      end
      s.bOwnVehicleOverrideWasActive = true
      Avatar.UpdateAnimation(tBody.tAnim, tBody.nAvatar, 0, _nDt, false, s.sWeather)
      Avatar.ResetLegsTwist(tBody.tAnim)
      -- Keep CPU neck bone fresh so Vehicles can read exact $OnRideSitIdle neck height in both 1P and 3P.
      if tBody.tAnim ~= nil and tBody.tAnim.nNeckAttach ~= nil then
        pcall(function()
          local baked = WorldAPIs().bakedanimation
          if baked ~= nil and baked.RequestAllBonesForCalculate ~= nil then
            baked:RequestAllBonesForCalculate(tBody.nAvatar)
          end
        end)
      end
      local bHeadHide = tVehOwn.bHeadHidden == true
      if tVehOwn.bHidden == true or bHeadHide then
        Avatar.ResetHeadLook(tBody.tAnim)
      else
        Avatar.UpdateHeadLook(tBody.tAnim, tBody.nAvatar, tVehOwn.camYaw or tVehOwn.yaw or 0,
          tVehOwn.camPitch or 0, tVehOwn.yaw or 0, tVehOwn.pitch or 0, _nDt, false, true)
      end
      if tBody.bHeadHidden ~= bHeadHide then
        tBody.bHeadHidden = bHeadHide
        if Avatar.SetHeadHidden ~= nil then
          Avatar.SetHeadHidden(tBody.tAnim, tBody.nAvatar, bHeadHide)
        end
      end
      if tBody.bHidden ~= (tVehOwn.bHidden == true) then
        tBody.bHidden = tVehOwn.bHidden == true
        Avatar.SetHidden(tBody.tAnim, tBody.nAvatar, tBody.bHidden)
      end
    end
    return
  elseif s.bOwnVehicleOverrideWasActive then
    s.bOwnVehicleOverrideWasActive = false
    if s.tOwnBody ~= nil and s.tOwnBody.nVehicleParent ~= nil then
      DestroyOwnBody()
    elseif s.tOwnBody ~= nil and s.tOwnBody.tAnim ~= nil and s.tOwnBody.nAvatar ~= nil then
      if s.tOwnBody.bHeadHidden then
        s.tOwnBody.bHeadHidden = false
        if Avatar.SetHeadHidden ~= nil then
          Avatar.SetHeadHidden(s.tOwnBody.tAnim, s.tOwnBody.nAvatar, false)
        end
      end
      if s.tSeatOverride == nil then
        Avatar.ClearBaseOverride(s.tOwnBody.tAnim, s.tOwnBody.nAvatar, 0.18)
      end
    end
  end
  local bWalking = WorldAPIs().CameraModeManager:GetCurrentModeName() == "Walking"
  local t = s.tOwnPose
  if not (bWalking and t ~= nil) or s.bOwnUnavailable then
    if s.tExploreDrop ~= nil and s.tExploreDrop.bHandedOff then
      return
    end
    -- Preserve pre-built vehicle exit body across the 1-frame DriveVehicle -> WalkingCamera mode switch.
    if not s.bOwnUnavailable and s.tOwnBody ~= nil and s.tOwnBody.nVehicleParent == nil and
      s.nVehicleExitAdoptUntil ~= nil and (s.nClock or 0) <= s.nVehicleExitAdoptUntil then
      return
    end
    s.nVehicleExitAdoptUntil = nil
    if not bWalking then
      s.tOwnPose = nil
    end
    DestroyOwnBody()
    return
  end
  s.nVehicleExitAdoptUntil = nil
  if s.tOwnBody == nil and s.tExploreDrop ~= nil and s.tExploreDrop.bHandedOff and
    s.tExplorePreview ~= nil and s.tExplorePreview.nAvatar ~= nil then
    local tPrev = s.tExplorePreview
    s.tOwnBody = {
      nAge = tPrev.nAge or 0,
      co = tPrev.co,
      sGroup = tPrev.sGroup,
      tParent = tPrev.tParent,
      nAvatar = tPrev.nAvatar,
      tAnim = tPrev.tAnim,
      bHidden = tPrev.bHidden == true,
    }
    s.nBodyYaw = tPrev.yaw or t.yaw
    s.tOwnPrev = {x = tPrev.x or t.x, z = tPrev.z or t.z}
    s.nOwnGroundY = tPrev.y or t.y
    s.tExplorePreview = nil
    s.tExploreDrop = nil
    s.vExploreStartPos = nil
    s.bExploreStartPosFresh = false
    Log("adopted explore drop avatar seamlessly as own body")
  end
  if s.tOwnBody == nil then
    s.tOwnBody = {nAge = 0, tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopOwnBody", nil,
      PoseTransform(t.x, t.y, t.z, t.yaw))}
  end
  local tBody = s.tOwnBody
  if not IsReady(tBody.tParent, _nDt) then
    if tBody.tParent.bFailed then
      s.bOwnUnavailable = true
    end
    return
  end
  local nOwnSpeed, nYawRate, bRev, bLeft, nRelMoveAngle = TurnBody(t, _nDt)
  s.nOwnSpeed = nOwnSpeed
  s.nOwnYawRate = nYawRate
  local nClampedSpeed = (type(nOwnSpeed) == "number" and nOwnSpeed <= 15.0) and nOwnSpeed or 0
  local nSpdDt = type(_nDt) == "number" and _nDt > 0 and _nDt or (1 / 60)
  s.nOwnSmoothSpeed = (s.nOwnSmoothSpeed or 0) + (nClampedSpeed - (s.nOwnSmoothSpeed or 0)) * (1 - math.exp(-10.0 * nSpdDt))
  if s.nOwnSmoothSpeed < 0.01 then
    s.nOwnSmoothSpeed = 0
  end
  local bInWater, nWaterSurf = IsInDeepWater(t.x, t.y, t.z)
  if s.tSeatOverride ~= nil and s.tSeatOverride.phase ~= "approaching" then
    s.nOwnGroundY = t.y
    bInWater, nWaterSurf = false, nil
  else
    s.nOwnGroundY = ComputeAvatarY(s.nOwnGroundY, t.x, t.y, t.z, _nDt, bInWater, nWaterSurf)
  end
  if bInWater ~= (s.bOwnInWater == true) then
    s.bOwnInWater = bInWater
    Log(bInWater and string.format("entered deep water (surface %.2f, feet %.2f)", nWaterSurf or 0, t.y) or "exited water")
  end
  s.nOwnWaterSurface = nWaterSurf
  -- Sample slope 0.55 m ahead in facing direction so character leans subtly uphill/downhill.
  local nSlopeRad = 0
  if not bInWater and s.tSeatOverride == nil and nOwnSpeed > 0.35 and s.nBodyYaw ~= nil then
    local nAheadX = t.x + math.sin(s.nBodyYaw) * 0.55
    local nAheadZ = t.z + math.cos(s.nBodyYaw) * 0.55
    local nAheadY = SampleGroundY(nAheadX, s.nOwnGroundY, nAheadZ)
    nSlopeRad = math.atan(nAheadY - s.nOwnGroundY, 0.55)
  end
  local nPitch, nRoll = 0, 0
  if tBody.tAnim ~= nil then
    nPitch, nRoll = Avatar.StepBodyLean(tBody.tAnim, nYawRate, nOwnSpeed, _nDt, bInWater, nSlopeRad)
    if t.bFirstPerson == true and nPitch > 0.08 then
      nPitch = 0.08
    end
  end
  local nBack = (type(t.nFpBodyBack) == "number" and t.nFpBodyBack > 0) and t.nFpBodyBack or 0
  local nPlaceYaw = s.nBodyYaw or t.yaw or 0
  Place(tBody.tParent, t.x - math.sin(nPlaceYaw) * nBack, s.nOwnGroundY, t.z - math.cos(nPlaceYaw) * nBack,
    nPlaceYaw, nPitch, nRoll)
  local bOk, sError = pcall(AdvanceOwnAvatar, tBody, _nDt)
  if not bOk then
    Log("own avatar error: " .. tostring(sError))
    s.bOwnUnavailable = true
    return
  end
  if tBody.nAvatar ~= nil then
    if s.nExploreDropBaseClearAt ~= nil and tBody.tAnim ~= nil and tBody.tAnim.sOverrideSuffix == "$PickedUp_Loop" then
      if (s.nClock or 0) >= s.nExploreDropBaseClearAt or nOwnSpeed >= 0.4 then
        s.nExploreDropBaseClearAt = nil
        Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, nOwnSpeed >= 0.4 and 0.15 or 0.0)
      end
    end
    if s.bPendingExploreDrop then
      s.bPendingExploreDrop = false
      if (s.nClock or 0) <= (s.nExploreDropUntil or 0) and s.tSeatOverride == nil and not bInWater and nOwnSpeed < 0.4 then
        Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, "$PickedUp_Out")
        Log("explore drop-in landing animation ($PickedUp_Out)")
      end
    end
    -- Photo Mode pose sync: when entering Photo UI mode on foot, strike StandInteractTakePhoto01.
    local bPhoto = CurrentUIMode() == "Photo"
    if bPhoto and not s.bWasPhotoMode then
      s.bWasPhotoMode = true
      Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, "$StandInteractTakePhoto01", 0.2)
    elseif not bPhoto and s.bWasPhotoMode then
      s.bWasPhotoMode = false
      if tBody.tAnim.sOverrideSuffix == "$StandInteractTakePhoto01" then
        Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
      end
    end
    if bRev then
      Avatar.TriggerPivot180(tBody.tAnim, tBody.nAvatar, bLeft)
    end
    local bUseLegsSplit = (t.bFirstPerson == true) and (not bInWater) and (s.tSeatOverride == nil)
    local _, bReverseStride = Avatar.UpdateLegsTwist(tBody.tAnim, nRelMoveAngle, nOwnSpeed, _nDt, bUseLegsSplit)
    Avatar.UpdateAnimation(tBody.tAnim, tBody.nAvatar, nOwnSpeed, _nDt, bInWater, s.sWeather, false, bReverseStride)
    local bWantHeadHide = t.bHeadHidden == true
    local bCanHideHeadOnly = tBody.tAnim ~= nil and
      (tBody.tAnim.nHeadRig ~= nil or (type(tBody.tAnim.tHeadParts) == "table" and #tBody.tAnim.tHeadParts > 0))
    local bWantBodyHide = (t.bHidden == true) or (bWantHeadHide and not bCanHideHeadOnly)
    local bEffHeadHide = bWantHeadHide and bCanHideHeadOnly
    if bWantBodyHide or bEffHeadHide then
      Avatar.ResetHeadLook(tBody.tAnim)
    else
      local bOwnSeatedIdle = s.tSeatOverride ~= nil and
        (s.tSeatOverride.phase == nil or s.tSeatOverride.phase == "seated")
      Avatar.UpdateHeadLook(tBody.tAnim, tBody.nAvatar, t.camYaw or t.yaw, t.pitch or 0, s.nBodyYaw, nPitch,
        _nDt, bInWater, bOwnSeatedIdle)
    end
    if tBody.bHeadHidden ~= bEffHeadHide then
      tBody.bHeadHidden = bEffHeadHide
      if Avatar.SetHeadHidden ~= nil then
        Avatar.SetHeadHidden(tBody.tAnim, tBody.nAvatar, bEffHeadHide)
      end
    end
    if tBody.bHidden ~= bWantBodyHide then
      tBody.bHidden = bWantBodyHide
      Avatar.SetHidden(tBody.tAnim, tBody.nAvatar, tBody.bHidden)
    end
  end
end

-- C on foot toggles third person (the vehicle handles the same key itself, see InstallVehicleWrap).
local HandleToggleKey = function()
  if CurrentUIMode() == "WalkingCamera" and WorldAPIs().InputManager:GetKeyPressed("GameCamera_ToggleThirdPerson") then
    Presence.SetThirdPerson(not s.bThirdPerson)
  end
end

-- ---- explore placement preview (Camera -> Explore / WalkingCameraInit) --------------------------
-- Shows the player's own avatar hovering above vanilla's Char_Props_PlacementRing using the same
-- system/animations as PZ2's staff hiring & guest pickup ($PickedUp_In -> $PickedUp_Loop with
-- cursor-velocity pendulum dangle sway, facing the overhead camera, and $PickedUp_Out on drop-in).
local StepUnderdampedSpring = function(_nVal, _nVel, _nTarget, _nOmega, _nZeta, _nDt)
  local nSteps = math.max(1, math.ceil(_nDt / 0.02))
  local h = _nDt / nSteps
  local nVal, nVel = _nVal or 0, _nVel or 0
  local nW2 = _nOmega * _nOmega
  local nDamp = 2.0 * _nZeta * _nOmega
  for _ = 1, nSteps do
    local nAcc = nW2 * (_nTarget - nVal) - nDamp * nVel
    nVel = nVel + nAcc * h
    nVal = nVal + nVel * h
  end
  return nVal, nVel
end

local DestroyExplorePreview = function()
  if s.tExplorePreview ~= nil then
    if s.tExplorePreview.tAnim ~= nil then
      Avatar.DetachProp(s.tExplorePreview.tAnim)
    end
    Destroy(s.tExplorePreview.tParent)
    s.tExplorePreview = nil
  end
  s.tExploreDrop = nil
  s.nExploreDropBaseClearAt = nil
  s.vExploreStartPos = nil
  s.bExploreStartPosFresh = false
end

local AdvanceExplorePreviewAvatar = function(_tPrev, _nDt)
  if _tPrev.co == nil then
    local bOk, tAvatar = pcall(ReadOwnAvatar)
    if not bOk or tAvatar == nil then
      Log("explore preview avatar not readable: " .. tostring(bOk and "no saved avatar" or tAvatar))
      s.bOwnUnavailable = true
      return
    end
    Log("building explore preview avatar (group " .. tostring(tAvatar.group) .. ")")
    _tPrev.sGroup = tAvatar.group
    _tPrev.co = coroutine.create(function()
      local nAvatar, bAnimated, tMeta = Avatar.CreateAnimated(tAvatar, _tPrev.tParent.nId, "player", "$PickedUp_In")
      _tPrev.nAvatar = nAvatar
      _tPrev.tAnim = Avatar.CreateAnimState(tAvatar.group, bAnimated, tMeta, "$PickedUp_In")
    end)
  end
  if coroutine.status(_tPrev.co) ~= "dead" and _tPrev.nAge < c_nAvatarTimeout then
    _tPrev.nAge = _tPrev.nAge + _nDt
    local bOk, sError = coroutine.resume(_tPrev.co)
    if not bOk then
      Log("explore preview avatar build error: " .. tostring(sError))
      s.bOwnUnavailable = true
      return
    end
    if coroutine.status(_tPrev.co) == "dead" then
      Log(string.format("explore preview avatar built after %.1f s (entity %s, animated %s)", _tPrev.nAge,
        tostring(_tPrev.nAvatar), tostring(_tPrev.tAnim and _tPrev.tAnim.bAnimated == true)))
    elseif _tPrev.nAge >= c_nAvatarTimeout then
      Log("explore preview avatar build still waiting after " .. c_nAvatarTimeout .. " s, stopped resuming it")
    end
  end
end

local UpdateExplorePreview = function(_nDt)
  local nDt = (type(_nDt) == "number" and _nDt > 0) and math.min(_nDt, 0.1) or (1 / 60)
  if s.tExploreDrop ~= nil then
    local tDrop = s.tExploreDrop
    local tPrev = s.tExplorePreview
    if tPrev == nil or s.bOwnUnavailable then
      s.tExploreDrop = nil
      DestroyExplorePreview()
      return
    end
    -- Keep the avatar planted at the drop spot while WalkingCameraInit transitions into WalkingCamera.
    Place(tPrev.tParent, tPrev.x, tPrev.y, tPrev.z, tPrev.yaw, 0, 0)
    if tPrev.nAvatar ~= nil then
      SetBodyHidden(tPrev, false)
    end
    tDrop.nHandoffTimeout = (tDrop.nHandoffTimeout or c_nExploreDropHandoffTimeout) - nDt
    if tDrop.nHandoffTimeout <= 0 then
      Log("explore drop handoff timed out; cleaning up preview")
      DestroyExplorePreview()
    end
    return
  end
  local bActive = s.bExploreInitActive == true or CurrentUIMode() == "WalkingCameraInit"
  if not bActive or s.bOwnUnavailable then
    if s.tExplorePreview ~= nil then
      DestroyExplorePreview()
    end
    return
  end
  if s.tExplorePreview == nil then
    s.tExplorePreview = {
      nAge = 0,
      sPhase = "in",
      nPhaseTime = 0,
      bHasPos = false,
      bHidden = false,
      x = 0, y = -1000, z = 0, yaw = 0,
      tx = 0, ty = -1000, tz = 0,
      vx = 0, vz = 0,
      pitch = 0, pitchVel = 0,
      roll = 0, rollVel = 0,
      tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopExplorePreview", nil,
        TransformQ.Identity:WithPos(c_vHidden)),
    }
  end
  local tPrev = s.tExplorePreview
  if not IsReady(tPrev.tParent, nDt) then
    if tPrev.tParent.bFailed then
      s.bOwnUnavailable = true
      DestroyExplorePreview()
    end
    return
  end

  local bAvOk, sAvErr = pcall(AdvanceExplorePreviewAvatar, tPrev, nDt)
  if not bAvOk then
    Log("explore preview avatar error: " .. tostring(sAvErr))
    s.bOwnUnavailable = true
    DestroyExplorePreview()
    return
  end

  local vStart = nil
  if s.bExploreStartPosFresh then
    vStart = s.vExploreStartPos
    s.bExploreStartPosFresh = false
  else
    local bPosOk, vPos = pcall(function()
      local cmm = WorldAPIs().CameraModeManager
      return cmm and cmm.GetWalkingStartPos and cmm:GetWalkingStartPos() or nil
    end)
    if bPosOk then
      vStart = vPos
    end
  end

  if vStart == nil then
    Place(tPrev.tParent, c_vHidden:GetX(), c_vHidden:GetY(), c_vHidden:GetZ(), 0, 0, 0)
    SetBodyHidden(tPrev, true)
    tPrev.bHasPos = false
    tPrev.vx, tPrev.vz = 0, 0
    tPrev.pitch, tPrev.pitchVel = 0, 0
    tPrev.roll, tPrev.rollVel = 0, 0
    return
  end

  local nTargetX = vStart.GetX and vStart:GetX() or vStart:X()
  local nTargetY = (vStart.GetY and vStart:GetY() or vStart:Y()) - WalkingHeight() + c_nExplorePreviewLiftY
  local nTargetZ = vStart.GetZ and vStart:GetZ() or vStart:Z()

  local nDesiredYaw = tPrev.yaw or 0
  pcall(function()
    local cmm = WorldAPIs().CameraModeManager
    if cmm ~= nil and cmm.GetPosYPRZoom ~= nil then
      local vCamPos, vCamYPR = cmm:GetPosYPRZoom()
      if vCamPos ~= nil then
        local cx = vCamPos.GetX and vCamPos:GetX() or vCamPos:X()
        local cz = vCamPos.GetZ and vCamPos:GetZ() or vCamPos:Z()
        local dcx, dcz = cx - nTargetX, cz - nTargetZ
        if dcx * dcx + dcz * dcz > 1e-4 then
          nDesiredYaw = math.atan(dcx, dcz)
          return
        end
      end
      if vCamYPR ~= nil then
        local cy = vCamYPR.GetX and vCamYPR:GetX() or vCamYPR:X()
        nDesiredYaw = WrapAngle(cy + math.pi)
      end
    end
  end)

  local dxJump = nTargetX - tPrev.x
  local dyJump = nTargetY - tPrev.y
  local dzJump = nTargetZ - tPrev.z
  if not tPrev.bHasPos or (dxJump * dxJump + dyJump * dyJump + dzJump * dzJump) > (c_nExplorePreviewSnapDist ^ 2) then
    tPrev.x, tPrev.y, tPrev.z = nTargetX, nTargetY, nTargetZ
    tPrev.tx, tPrev.ty, tPrev.tz = nTargetX, nTargetY, nTargetZ
    tPrev.yaw = nDesiredYaw
    tPrev.vx, tPrev.vz = 0, 0
    tPrev.bHasPos = true
  else
    local rawVx = Clamp((nTargetX - tPrev.tx) / nDt, -c_nExplorePreviewMaxSpeed, c_nExplorePreviewMaxSpeed)
    local rawVz = Clamp((nTargetZ - tPrev.tz) / nDt, -c_nExplorePreviewMaxSpeed, c_nExplorePreviewMaxSpeed)
    local kVel = 1 - math.exp(-c_nExplorePreviewVelRate * nDt)
    tPrev.vx = tPrev.vx + (rawVx - tPrev.vx) * kVel
    tPrev.vz = tPrev.vz + (rawVz - tPrev.vz) * kVel
    tPrev.tx, tPrev.ty, tPrev.tz = nTargetX, nTargetY, nTargetZ

    local kPos = 1 - math.exp(-c_nExplorePreviewSmoothPos * nDt)
    tPrev.x = tPrev.x + (nTargetX - tPrev.x) * kPos
    tPrev.y = tPrev.y + (nTargetY - tPrev.y) * kPos
    tPrev.z = tPrev.z + (nTargetZ - tPrev.z) * kPos

    local nYawDiff = WrapAngle(nDesiredYaw - tPrev.yaw)
    local nMaxStep = c_nExplorePreviewTurnRate * nDt
    tPrev.yaw = WrapAngle(tPrev.yaw + Clamp(nYawDiff, -nMaxStep, nMaxStep))
  end

  local nDangleWeight = 1.0
  if tPrev.sPhase == "in" then
    local sPrefixIn = Avatar.GroupPrefix(tPrev.sGroup)
    local nInDurW = math.max(0.1, (c_tPickedUpInDur[sPrefixIn] or 0.90) - c_nPickedUpBlendOut)
    nDangleWeight = Clamp((tPrev.nPhaseTime or 0) / nInDurW, 0, 1)
  end
  local fx, fz = math.sin(tPrev.yaw), math.cos(tPrev.yaw)
  local rx, rz = math.cos(tPrev.yaw), -math.sin(tPrev.yaw)
  local nVelFwd = tPrev.vx * fx + tPrev.vz * fz
  local nVelRight = tPrev.vx * rx + tPrev.vz * rz
  local nTargetPitch = Clamp(nVelFwd * c_nExplorePreviewDangleGain * nDangleWeight,
    -c_nExplorePreviewDangleMax, c_nExplorePreviewDangleMax)
  local nTargetRoll = Clamp(-nVelRight * c_nExplorePreviewDangleGain * nDangleWeight,
    -c_nExplorePreviewDangleMax, c_nExplorePreviewDangleMax)
  tPrev.pitch, tPrev.pitchVel = StepUnderdampedSpring(tPrev.pitch, tPrev.pitchVel, nTargetPitch,
    c_nExplorePreviewSpringOmega, c_nExplorePreviewSpringZeta, nDt)
  tPrev.roll, tPrev.rollVel = StepUnderdampedSpring(tPrev.roll, tPrev.rollVel, nTargetRoll,
    c_nExplorePreviewSpringOmega, c_nExplorePreviewSpringZeta, nDt)

  -- Pivot the pendulum rotation around the suspended shoulder point (0, c_nExplorePreviewPivotY, 0) so the
  -- character stays centered directly above the placement ring while their feet swing smoothly behind cursor motion.
  local nPlaceX, nPlaceY, nPlaceZ = tPrev.x, tPrev.y, tPrev.z
  local nPivotH = c_nExplorePreviewPivotY * nDangleWeight
  if nPivotH > 0.01 and (math.abs(tPrev.pitch) > 1e-4 or math.abs(tPrev.roll) > 1e-4) then
    local px, py, pz = nil, nil, nil
    local trRot = PoseTransform(0, 0, 0, tPrev.yaw, tPrev.pitch, tPrev.roll)
    if trRot ~= nil and trRot.ToWorldPos ~= nil then
      local bOkP, vRot = pcall(trRot.ToWorldPos, trRot, Vector3:new(0, nPivotH, 0))
      if bOkP and vRot ~= nil then
        local vx, vy, vz = ReadVec3(vRot)
        if vx ~= nil then
          px, py, pz = vx, vy, vz
        end
      end
    end
    if px == nil then
      -- Fallback YPR rotation of (0, nPivotH, 0): roll (+Z) -> pitch (+X) -> yaw (+Y)
      local sr, cr = math.sin(tPrev.roll), math.cos(tPrev.roll)
      local sp, cp = math.sin(tPrev.pitch), math.cos(tPrev.pitch)
      local sy, cy = math.sin(tPrev.yaw), math.cos(tPrev.yaw)
      local x1, y1, z1 = -nPivotH * sr, nPivotH * cr, 0
      local x2, y2, z2 = x1, y1 * cp - z1 * sp, y1 * sp + z1 * cp
      px, py, pz = x2 * cy + z2 * sy, y2, -x2 * sy + z2 * cy
    end
    nPlaceX = nPlaceX - px
    nPlaceY = nPlaceY + nPivotH - py
    nPlaceZ = nPlaceZ - pz
  end

  Place(tPrev.tParent, nPlaceX, nPlaceY, nPlaceZ, tPrev.yaw, tPrev.pitch, tPrev.roll)

  if tPrev.nAvatar ~= nil then
    SetBodyHidden(tPrev, false)
    if tPrev.sPhase == "in" then
      tPrev.nPhaseTime = (tPrev.nPhaseTime or 0) + nDt
      local sPrefix = Avatar.GroupPrefix(tPrev.sGroup)
      local nInDur = (c_tPickedUpInDur[sPrefix] or 0.90) - c_nPickedUpBlendOut
      if tPrev.nPhaseTime >= nInDur then
        tPrev.sPhase = "loop"
        Avatar.SetBaseOverride(tPrev.tAnim, tPrev.nAvatar, "$PickedUp_Loop", c_nPickedUpLoopBlend)
      end
    end
  end
end

local InstallExploreInitWrap = function()
  local bOk, WalkingCameraInitUIMode = pcall(require, "Editors.Cameras.WalkingCameraInitUIMode")
  if not bOk or type(WalkingCameraInitUIMode) ~= "table" or
    rawget(WalkingCameraInitUIMode, "__PZ2CoopOriginalTransitionIn") ~= nil then
    return
  end
  local fnOrigIn = WalkingCameraInitUIMode.TransitionIn
  local fnOrigOut = WalkingCameraInitUIMode.TransitionOut
  local fnOrigAdv = WalkingCameraInitUIMode.Advance
  rawset(WalkingCameraInitUIMode, "__PZ2CoopOriginalTransitionIn", fnOrigIn)
  WalkingCameraInitUIMode.TransitionIn = function(self, ...)
    local r = fnOrigIn(self, ...)
    s.bExploreInitActive = true
    s.vExploreStartPos = nil
    s.bExploreStartPosFresh = false
    Log("explore placement started (showing suspended player avatar)")
    return r
  end
  if type(fnOrigOut) == "function" then
    rawset(WalkingCameraInitUIMode, "__PZ2CoopOriginalTransitionOut", fnOrigOut)
    WalkingCameraInitUIMode.TransitionOut = function(self, ...)
      s.bExploreInitActive = false
      if s.tExploreDrop == nil or not s.tExploreDrop.bHandedOff then
        DestroyExplorePreview()
      end
      return fnOrigOut(self, ...)
    end
  end
  if type(fnOrigAdv) == "function" then
    rawset(WalkingCameraInitUIMode, "__PZ2CoopOriginalAdvance", fnOrigAdv)
    WalkingCameraInitUIMode.Advance = function(self, ...)
      pcall(function()
        local tW = self.tWorldAPIs
        local cmm = tW and tW.CameraModeManager
        if cmm ~= nil and cmm.GetWalkingStartPos ~= nil then
          local vStart = cmm:GetWalkingStartPos()
          s.vExploreStartPos = vStart
          s.bExploreStartPosFresh = true
          if vStart == nil and tW.InputManager ~= nil and api.audio ~= nil and api.audio.SendGUIEvent ~= nil then
            local tMouse = tW.InputManager:GetMouseInput()
            local bClick = (tW.InputManager.GetGamepadButtonDown ~= nil and
              tW.InputManager:GetGamepadButtonDown("Gamepad_Select")) or
              (tMouse ~= nil and tMouse.Button == "mouseleft" and tMouse.Action == "click")
            if bClick then
              api.audio.SendGUIEvent("Staff_Invalid_Placement")
            end
          end
        end
      end)
      return fnOrigAdv(self, ...)
    end
  end
  Log("explore placement UI mode wrapped (hiring-style suspended player preview)")
end

-- ---- native explore on foot --------------------------------------------------------------------
local EnterNativeExplore = function(_self)
  if CurrentUIMode() == "WalkingCamera" then
    return nil
  end
  if s.tExploreDrop ~= nil then
    return false
  end
  local tData = _self.mainEntityID and _self.tEntities[_self.mainEntityID]
  if tData == nil then
    return nil
  end
  local WalkingCamera = require("Components.Cameras.WalkingCamera")
  local vStartingPos = WalkingCamera.GetStartingPos(tData.tModeData, _self.tWorldAPIs)
  if vStartingPos == nil then
    return nil
  end
  local tPrev = s.tExplorePreview
  if s.bThirdPerson then
    s.nCamDist = s.nCamTarget or s.nThirdDist or c_nThirdBack
  else
    s.nCamDist = 0
  end
  if CurrentUIMode() == "WalkingCameraInit" and tPrev ~= nil and tPrev.nAvatar ~= nil and tPrev.tAnim ~= nil then
    local nDropX = vStartingPos.GetX and vStartingPos:GetX() or vStartingPos:X()
    local nDropEyeY = vStartingPos.GetY and vStartingPos:GetY() or vStartingPos:Y()
    local nDropY = nDropEyeY - WalkingHeight()
    local nDropZ = vStartingPos.GetZ and vStartingPos:GetZ() or vStartingPos:Z()
    local cmmCam = (_self.GetPosYPRZoom ~= nil and _self) or (_self.tWorldAPIs and _self.tWorldAPIs.CameraModeManager) or
      WorldAPIs().CameraModeManager
    if cmmCam ~= nil and cmmCam.GetPosYPRZoom ~= nil then
      local bCamOk, vCamPos, vCamYPR = pcall(cmmCam.GetPosYPRZoom, cmmCam)
      if bCamOk and vCamPos ~= nil and vCamYPR ~= nil then
        local sx, sy, sz = ReadVec3(vCamPos)
        local syaw, spitch, sroll = ReadVec3(vCamYPR)
        if sx ~= nil and syaw ~= nil then
          s.tExploreCamEase = {
            nElapsed = 0,
            nDuration = c_nExploreCamEaseDur,
            startX = sx, startY = sy, startZ = sz,
            startYaw = syaw, startPitch = spitch, startRoll = sroll or 0,
            dropX = nDropX, dropY = nDropY, dropZ = nDropZ, dropEyeY = nDropEyeY,
          }
        end
      end
    end
    tPrev.x, tPrev.y, tPrev.z = nDropX, nDropY, nDropZ
    tPrev.tx, tPrev.ty, tPrev.tz = nDropX, nDropY, nDropZ
    tPrev.vx, tPrev.vz = 0, 0
    tPrev.pitch, tPrev.pitchVel, tPrev.roll, tPrev.rollVel = 0, 0, 0, 0
    tPrev.sPhase = "out"
    tPrev.nPhaseTime = 0
    -- Play $PickedUp_Out as a non-looping one-shot over $PickedUp_Loop, then clear the base layer
    -- to $StandBaseIdle01 once the one-shot is at full weight (never loops back to the sky).
    Avatar.PlayOneShot(tPrev.tAnim, tPrev.nAvatar, "$PickedUp_Out")
    s.nExploreDropBaseClearAt = (s.nClock or 0) + 0.15
    s.tExploreDrop = {
      bHandedOff = true,
      nHandoffTimeout = c_nExploreDropHandoffTimeout,
    }
    PublishExploreUIState("entering")
    Log("explore drop-in ($PickedUp_Out) with simultaneous smooth camera ease-out")
    require("Editors.Shared.BaseUIMode").SetNewMode("WalkingCamera", {vStartingPos = vStartingPos})
    return false
  end
  s.bPendingExploreDrop = true
  s.nExploreDropUntil = (s.nClock or 0) + c_nExplorePreviewDropWindow
  require("Editors.Shared.BaseUIMode").SetNewMode("WalkingCamera", {vStartingPos = vStartingPos})
  return false
end

local InstallExploreWrap = function()
  local bOk, CameraModeManager = pcall(require, "Components.Cameras.CameraModeManager")
  if not bOk or type(CameraModeManager) ~= "table" or rawget(CameraModeManager, "__PZ2CoopOriginalTryWalk") ~= nil then
    return
  end
  local fnOriginal = CameraModeManager.TryRequestWalkingMode
  rawset(CameraModeManager, "__PZ2CoopOriginalTryWalk", fnOriginal)
  CameraModeManager.TryRequestWalkingMode = function(self, ...)
    local bRan, bResult = pcall(EnterNativeExplore, self)
    if not bRan then
      Log("native explore error: " .. tostring(bResult))
    elseif bResult ~= nil then
      return bResult
    end
    return fnOriginal(self, ...)
  end
  Log("explore button opens native explore on foot")
end

local InstallVehicleWrap = function()
  local bOk, DriveVehicleUIMode = pcall(require, "Editors.Vehicle.DriveVehicleUIMode")
  if not bOk or type(DriveVehicleUIMode) ~= "table" or rawget(DriveVehicleUIMode, "__PZ2CoopOriginalSwitch") ~= nil then
    return
  end
  local fnSwitch, fnTransitionIn = DriveVehicleUIMode.SwitchCamera, DriveVehicleUIMode.TransitionIn
  rawset(DriveVehicleUIMode, "__PZ2CoopOriginalSwitch", fnSwitch)
  DriveVehicleUIMode.SwitchCamera = function(self, ...)
    local r = fnSwitch(self, ...)
    if (self.bThirdPersonCamera == true) ~= s.bThirdPerson then
      Presence.SetThirdPerson(self.bThirdPersonCamera == true)
    end
    return r
  end
  DriveVehicleUIMode.TransitionIn = function(self, _tParams, ...)
    if type(_tParams) == "table" and _tParams.bThirdPersonCamera == nil then
      _tParams.bThirdPersonCamera = s.bThirdPerson
    end
    return fnTransitionIn(self, _tParams, ...)
  end
end

local AddSwitchPrompt = function()
  local GameDatabase = require("Database.GameDatabase")
  local tEmpty = GameDatabase.GetButtonPromptData("Empty")
  local tWalking = type(tEmpty) == "table" and tEmpty.WalkingCamera
  if type(tWalking) ~= "table" then
    return false
  end
  for _, sList in ipairs({"tMouse", "tGamepad"}) do
    local tList = tWalking[sList]
    if tList ~= nil then
      for i = #tList, 1, -1 do
        if tList[i] ~= nil and tList[i].sLogicalControl == "GameCamera_Crouch" then
          table.remove(tList, i)
        end
      end
      local bHas = false
      for _, tEntry in ipairs(tList) do
        bHas = bHas or tEntry.sLogicalControl == c_tSwitchPrompt.sLogicalControl
      end
      if not bHas then
        local tEntry = {}
        for k, v in pairs(c_tSwitchPrompt) do
          tEntry[k] = v
        end
        table.insert(tList, math.max(1, #tList), tEntry)
      end
    end
  end
  Log("switch camera prompt added and crouch prompt removed on foot")
  return true
end

-- ---- go to friend ------------------------------------------------------------------------------
local GoToFriend = function()
  local t = s.tFriend
  if t == nil then
    Log("go to friend: no recent friend position")
    return
  end
  local nHeight = WalkingHeight()
  local vStart = Vector3:new(t.px + math.cos(t.yaw) * c_nGoSide, t.py + nHeight, t.pz - math.sin(t.yaw) * c_nGoSide)
  local vYPR = Vector3:new(t.yaw, 0, 0)
  if CurrentUIMode() == "WalkingCamera" then
    WorldAPIs().CameraModeManager:RequestMode("Walking", {vStartingPos = vStart, vStartingYPR = vYPR,
      bIsWildArea = true, bMagnifyEnabled = false, bWalkingRotateLock = true})
  else
    require("Editors.Shared.BaseUIMode").SetNewMode("WalkingCamera", {vStartingPos = vStart, vStartingYPR = vYPR})
  end
  if s.fnOnGoArrival ~= nil then
    pcall(s.fnOnGoArrival)
  end
  Log(string.format("go to friend: walking from %.1f, %.1f, %.1f", vStart:GetX(), vStart:GetY(), vStart:GetZ()))
end

local ViewFriend = function()
  local t = s.tFriend
  if t == nil then
    Log("view friend: no recent friend position")
    return
  end
  local nTarget = (s.tFriendBody and s.tFriendBody.tParent and s.tFriendBody.tParent.bReady and s.tFriendBody.tParent.nId)
    or (s.tFriendRing and s.tFriendRing.bReady and s.tFriendRing.nId)
  if CurrentUIMode() == "WalkingCamera" then
    pcall(function()
      require("Editors.Shared.BaseUIMode").SetNewMode("Select")
    end)
  end
  if nTarget ~= nil then
    WorldAPIs().CameraModeManager:RequestMode("Orbit", {targetEntityID = nTarget, bLocate = true})
    Log("view friend: orbiting entity " .. tostring(nTarget))
  else
    Log("view friend: no friend entity ready yet")
  end
end

local InstallWalkingUIModeWrap = function()
  local bOk, WalkingCameraUIMode = pcall(require, "Editors.Cameras.WalkingCameraUIMode")
  if not bOk or type(WalkingCameraUIMode) ~= "table" or rawget(WalkingCameraUIMode, "__PZ2CoopOriginalAdvance") ~= nil then
    return
  end
  local fnOriginal = WalkingCameraUIMode.Advance
  rawset(WalkingCameraUIMode, "__PZ2CoopOriginalAdvance", fnOriginal)
  WalkingCameraUIMode.Advance = function(self, ...)
    -- Prevent left/right clicks on the Emote Wheel from triggering world interactions or exiting Explore on Foot.
    if s.fnIsWheelBlocking ~= nil and s.fnIsWheelBlocking() then
      return
    end
    return fnOriginal(self, ...)
  end
  if type(WalkingCameraUIMode.TransitionOut) == "function" and
    rawget(WalkingCameraUIMode, "__PZ2CoopOriginalTransitionOut") == nil then
    local fnOrigOut = WalkingCameraUIMode.TransitionOut
    rawset(WalkingCameraUIMode, "__PZ2CoopOriginalTransitionOut", fnOrigOut)
    WalkingCameraUIMode.TransitionOut = function(self, ...)
      local mainHUD = self.mainHUD
      local r = fnOrigOut(self, ...)
      local sNextMode = CurrentUIMode()
      if mainHUD ~= nil and sNextMode ~= "Photo" and sNextMode ~= "DriveVehicle" then
        pcall(function() mainHUD:SetExplorerModeEnabled(true) end)
        s.tPendingExploreExitHUD = {mainHUD = mainHUD, untilClock = (s.nClock or 0) + 0.25}
        PublishExploreUIState("exiting")
      else
        s.tPendingExploreExitHUD = nil
        PublishExploreUIState("idle")
      end
      return r
    end
  end
  -- Sync habitat gate open/close across peers & trigger door-opening avatar animation.
  if type(WalkingCameraUIMode._ToggleHabitatGate) == "function" and
    rawget(WalkingCameraUIMode, "__PZ2CoopOriginalToggleGate") == nil then
    local fnOrigGate = WalkingCameraUIMode._ToggleHabitatGate
    rawset(WalkingCameraUIMode, "__PZ2CoopOriginalToggleGate", fnOrigGate)
    WalkingCameraUIMode._ToggleHabitatGate = function(self, _nEntityID, ...)
      -- Never open Aquarium Staff Doors (AquariumEntrance) which open into flooded underwater tanks.
      if _nEntityID ~= nil and IsAquariumStaffDoorEntity(_nEntityID) then
        Log("blocked opening aquarium staff door (id=" .. tostring(_nEntityID) .. ")")
        return
      end
      local nPrev = self.nOpenedHabitatGate
      local r = fnOrigGate(self, _nEntityID, ...)
      local nNow = self.nOpenedHabitatGate
      s.nLocalOpenGate = nNow
      if nPrev ~= nNow then
        pcall(function()
          local nTarget = nNow or nPrev
          local bOpened = nNow ~= nil
          Log("habitat gate " .. (bOpened and "opened" or "closed") .. " (id=" .. tostring(nTarget) .. ")")
          if s.tOwnBody ~= nil and s.tOwnBody.tAnim ~= nil and s.tOwnBody.nAvatar ~= nil then
            Avatar.PlayOneShot(s.tOwnBody.tAnim, s.tOwnBody.nAvatar, "$StandInteractKioskNormalIn")
          end
          local vPos = nil
          if nTarget ~= nil and WorldAPIs().transform ~= nil then
            local tr = WorldAPIs().transform:CalculateWorldTransform(nTarget)
            vPos = tr and (tr.GetPos and tr:GetPos() or tr:Pos())
          end
          s.tOpenGates = s.tOpenGates or {}
          if bOpened and vPos ~= nil then
            s.tOpenGates["local"] = {x = vPos:GetX(), y = vPos:GetY(), z = vPos:GetZ()}
          else
            s.tOpenGates["local"] = nil
          end
          if nTarget ~= nil and vPos ~= nil and (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
            Bridge.SendPacket(c_nAvatar, nil, {
              k = "action",
              op = "gate",
              open = bOpened,
              x = math.floor(vPos:GetX() * 100 + 0.5),
              y = math.floor(vPos:GetY() * 100 + 0.5),
              z = math.floor(vPos:GetZ() * 100 + 0.5),
            })
          end
        end)
      end
      return r
    end
  end
  Log("walking UI mode wrapped (emote wheel clicks stay on foot + gate sync)")
end

-- In third-person mode, the camera sits 3.5 m behind the player, which pushed HabitatGates outside vanilla's
-- 5 m FirstPersonInteraction.SelectionDistance check. Extend selection in third person to match player proximity.
local InstallFirstPersonInteractionWrap = function()
  local bOk, FPI = pcall(require, "Components.FirstPersonInteraction")
  if not bOk or type(FPI) ~= "table" or rawget(FPI, "__PZ2CoopOriginalChoose") ~= nil then
    return
  end
  local fnOrigChoose = FPI._ChooseSelection
  if type(fnOrigChoose) ~= "function" then
    return
  end
  rawset(FPI, "__PZ2CoopOriginalChoose", fnOrigChoose)
  FPI._ChooseSelection = function(self, ...)
    fnOrigChoose(self, ...)
    -- Exclude Aquarium Staff Doors (AquariumEntrance) in both first-person and third-person.
    if self.tSelection ~= nil and self.tSelection.sEntityType == "HabitatGate" and
      IsAquariumStaffDoorEntity(self.tSelection.nEntityID) then
      self.tSelection = {}
    end
    -- Apply closest-seat prompt targeting whenever walking near a Research Vehicle (in both 1P and 3P).
    if s.fnVehiclePromptProvider ~= nil then
      pcall(function()
        local px, py, pz
        if s.tOwnPose ~= nil then
          px, py, pz = s.tOwnPose.x, s.tOwnPose.y, s.tOwnPose.z
        elseif WorldAPIs().CameraModeManager ~= nil then
          local vPos = WorldAPIs().CameraModeManager:GetPosYPRZoom()
          if vPos ~= nil then
            px, py, pz = vPos:GetX(), vPos:GetY() - WalkingHeight(), vPos:GetZ()
          end
        end
        if px == nil then
          return
        end
        local nVehCand = nil
        if self.tSelection ~= nil and self.tSelection.sEntityType == "Vehicle" and self.tSelection.nEntityID ~= nil then
          nVehCand = self.tSelection.nEntityID
        elseif type(self.tEntities) == "table" then
          local nBestD2 = math.huge
          for nEnt, tData in pairs(self.tEntities) do
            if type(tData) == "table" and tData.sType == "Vehicle" then
              local nParentId = tData.nParentEntityID or nEnt
              local vPos = self.transformAPI and self.transformAPI:CalculateWorldPosition(nParentId)
              if vPos ~= nil then
                local dx, dz = vPos:GetX() - px, vPos:GetZ() - pz
                local d2 = dx * dx + dz * dz
                if d2 < nBestD2 and d2 <= 4.5 * 4.5 then
                  nBestD2 = d2
                  nVehCand = nParentId
                end
              end
            end
          end
        end
        if nVehCand ~= nil then
          local tPrompt = s.fnVehiclePromptProvider(nVehCand, px, py, pz)
          if tPrompt ~= nil then
            self.tSelection = {
              nEntityID = nVehCand,
              sEntityType = "Vehicle",
              sActionType = "Drive",
              vInteractionPosition = tPrompt.vPos,
              sCustomVehicleLabel = tPrompt.sLabel,
              bVehicleFull = tPrompt.bFull == true,
              nSeat = tPrompt.nSeat,
            }
          elseif self.tSelection ~= nil and self.tSelection.sEntityType == "Vehicle" then
            self.tSelection = {}
          end
        end
      end)
    end
    if not s.bThirdPerson or s.tOwnPose == nil then
      return
    end
    pcall(function()
      local px, py, pz = s.tOwnPose.x, s.tOwnPose.y + 1.0, s.tOwnPose.z
      local nCamYaw = s.tOwnPose.camYaw or s.tOwnPose.yaw or 0
      local fx, fz = math.sin(nCamYaw), math.cos(nCamYaw)
      local MaxDistForType = function(_sType)
        if _sType == "Vehicle" then
          return 2.8
        end
        return 2.6
      end
      -- Reject vanilla selections that are only close to the trailing camera, not close to the player's avatar.
      if self.tSelection ~= nil and self.tSelection.nEntityID ~= nil and self.tSelection.vInteractionPosition ~= nil then
        local vP = self.tSelection.vInteractionPosition
        local dx, dy, dz = vP:GetX() - px, vP:GetY() - py, vP:GetZ() - pz
        local nMaxD = MaxDistForType(self.tSelection.sEntityType)
        if (dx * dx + dz * dz) > (nMaxD * nMaxD) or math.abs(dy) > 1.8 then
          self.tSelection = {}
        end
      end
      if self.tSelection ~= nil and self.tSelection.nEntityID ~= nil then
        return
      end
      local tEntities = self.tEntities
      if type(tEntities) ~= "table" or self.transformAPI == nil then
        return
      end
      local nBestD2 = math.huge
      local tBest = nil
      for nEntityID, tData in pairs(tEntities) do
        if type(tData) == "table" and (tData.sType == "HabitatGate" or tData.sType == "Vehicle") then
          local nParentId = tData.nParentEntityID or nEntityID
          if tData.sType ~= "HabitatGate" or not IsAquariumStaffDoorEntity(nParentId) then
            local vPos = self.transformAPI:CalculateWorldPosition(nEntityID)
            if vPos ~= nil then
              local dx, dy, dz = vPos:GetX() - px, vPos:GetY() - py, vPos:GetZ() - pz
              local nHorizD2 = dx * dx + dz * dz
              local nMaxD = MaxDistForType(tData.sType)
              if nHorizD2 <= (nMaxD * nMaxD) and math.abs(dy) <= 1.8 then
                local nDist = math.sqrt(nHorizD2)
                local bInView = nDist <= 0.9 or ((dx * fx + dz * fz) / nDist) >= -0.1
                if bInView and nHorizD2 < nBestD2 then
                  nBestD2 = nHorizD2
                  tBest = {
                    nEntityID = nParentId,
                    sEntityType = tData.sType,
                    sActionType = tData.sType == "Vehicle" and "Drive" or "HabitatGateFrontToBack",
                    vInteractionPosition = vPos,
                  }
                end
              end
            end
          end
        end
      end
      if tBest ~= nil then
        self.tSelection = tBest
      end
    end)
  end
  -- Wrap _UpdateTooltip so:
  --   1) HabitatGate displays an [E] Open / Close Gate tooltip (vanilla only shows a tooltip for Drive!).
  --   2) When no vanilla gate/vehicle is selected, our custom chair/bench/world-interaction tooltip from Actions
  --      is drawn instead of vanilla calling HideHelperTooltip() every frame and wiping it out!
  if type(FPI._UpdateTooltip) == "function" and rawget(FPI, "__PZ2CoopOriginalTooltip") == nil then
    local fnOrigTooltip = FPI._UpdateTooltip
    rawset(FPI, "__PZ2CoopOriginalTooltip", fnOrigTooltip)
    FPI._UpdateTooltip = function(self, ...)
      if self.tSelection ~= nil and self.tSelection.nEntityID ~= nil then
        if self.tSelection.sEntityType == "Vehicle" and self.tSelection.sCustomVehicleLabel ~= nil and
          self.uiHUD ~= nil and self.cameraAPI ~= nil and self.tSelection.vInteractionPosition ~= nil then
          local bOkVehTip = pcall(function()
            local nCam = self.cameraAPI:GetMainCameraID()
            local vUV = self.cameraAPI:GetTopDownScreenUVFromWorldPosition(nCam, self.tSelection.vInteractionPosition)
            if vUV ~= nil then
              local ux = vUV.GetX and vUV:GetX() or vUV:X()
              local uy = vUV.GetY and vUV:GetY() or vUV:Y()
              if ux >= 0.02 and ux <= 0.98 and uy >= 0.02 and uy <= 0.98 then
                self.uiHUD:ShowHelperTooltip({
                  value = "[STRING_LITERAL:Value=|" .. tostring(self.tSelection.sCustomVehicleLabel) .. "|]",
                  inputName = self.tSelection.bVehicleFull and nil or "GameCamera_EnterVehicle",
                  type = self.tSelection.bVehicleFull and "LocStringWarning" or "LocString",
                  posX = ux,
                  posY = uy,
                  noAutoHide = true,
                  followMouse = false,
                })
              end
            end
          end)
          if bOkVehTip then
            return
          end
        end
        if self.tSelection.sEntityType == "HabitatGate" and self.uiHUD ~= nil and self.cameraAPI ~= nil and
          self.tSelection.vInteractionPosition ~= nil then
          local bOkTip = pcall(function()
            local nCam = self.cameraAPI:GetMainCameraID()
            local vUV = self.cameraAPI:GetTopDownScreenUVFromWorldPosition(nCam, self.tSelection.vInteractionPosition)
            if vUV ~= nil then
              local ux = vUV.GetX and vUV:GetX() or vUV:X()
              local uy = vUV.GetY and vUV:GetY() or vUV:Y()
              if ux >= 0.02 and ux <= 0.98 and uy >= 0.02 and uy <= 0.98 then
                local bThisOpen = (s.nLocalOpenGate ~= nil and s.nLocalOpenGate == self.tSelection.nEntityID) or
                  (s.nLocalOpenGate == nil and s.tOpenGates ~= nil and s.tOpenGates["local"] ~= nil)
                local sGateLabel = bThisOpen and "Close Gate" or "Open Gate"
                self.uiHUD:ShowHelperTooltip({
                  value = "[STRING_LITERAL:Value=|" .. sGateLabel .. "|]",
                  inputName = "GameCamera_EnterVehicle",
                  type = "LocString",
                  posX = ux,
                  posY = uy,
                  noAutoHide = true,
                  followMouse = false,
                })
              end
            end
          end)
          if bOkTip then
            return
          end
        end
        return fnOrigTooltip(self, ...)
      end
      if s.fnCustomTooltip ~= nil then
        local bOk, bShown = pcall(s.fnCustomTooltip, self.uiHUD)
        if bOk and bShown == true then
          return
        end
      end
      return fnOrigTooltip(self, ...)
    end
  end
  Log("first-person interaction wrapped (third-person reach + gate/custom tooltips)")
end

-- ---- module API --------------------------------------------------------------------------------
Presence.Install = function()
  InstallCameraWrap()
  InstallExploreWrap()
  InstallExploreInitWrap()
  InstallVehicleWrap()
  InstallWalkingUIModeWrap()
  InstallFirstPersonInteractionWrap()
  -- Hydrate friend avatar from Bridge cache immediately after a main-menu join or resync reload.
  if s.tFriendAvatarData == nil and Bridge.GetCachedPeerAvatar ~= nil then
    local tCached = Bridge.GetCachedPeerAvatar()
    if type(tCached) == "table" then
      local tClean = SanitizeAvatar(tCached)
      if tClean ~= nil then
        s.tFriendAvatarData = tClean
        s.bFriendAvatarFailed = false
        Log("restored cached friend avatar (group " .. tostring(tClean.group) .. ")")
      end
    end
  end
end

local SendOwnAvatarIfNeeded = function()
  local tSession = Bridge.GetSession()
  local sPeerKey = Bridge.IsLoopback() and "loopback" or (tSession.sPartnerId or "peer")
  if s.sAvatarPeerKey == sPeerKey then
    return
  end
  s.sAvatarPeerKey = sPeerKey
  s.nAvatarSentAt = s.nClock
  local bOk, tAvatar = pcall(ReadOwnAvatar)
  if not bOk or tAvatar == nil then
    Log("own avatar not sent: " .. tostring(bOk and "no saved avatar" or tAvatar))
    return
  end
  local tClean, sWhy = SanitizeAvatar(tAvatar, true)
  if tClean == nil then
    Log("own avatar not sent (rejected by sanitizer: " .. tostring(sWhy) .. ")")
    return
  end
  Bridge.SendPacket(c_nAvatar, nil, tClean)
  Log("sent own avatar (group " .. tostring(tClean.group) .. ")")
  if s.fnOnAvatarSent ~= nil then
    pcall(s.fnOnAvatarSent)
  end
end

Presence.Update = function(_nDt, _bActive)
  s.nClock = (s.nClock or 0) + (_nDt or 0)
  s.nWeatherTimer = (s.nWeatherTimer or 0) - (_nDt or 0)
  if s.nWeatherTimer <= 0 then
    s.nWeatherTimer = c_nWeatherInterval
    PollWeather()
  end
  if s.bGoRequest then
    s.bGoRequest = false
    GoToFriend()
  end
  if s.bViewRequest then
    s.bViewRequest = false
    ViewFriend()
  end
  if not s.bPromptAdded then
    local bOk, bAdded = pcall(AddSwitchPrompt)
    s.bPromptAdded = bOk and bAdded == true
  end
  local bKey, sKeyError = pcall(HandleToggleKey)
  if not bKey and not s.bKeyErrorLogged then
    s.bKeyErrorLogged = true
    Log("third person key error: " .. tostring(sKeyError))
  end
  if _bActive and (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    -- Hydrate from Bridge cache if a peer avatar arrived during loading/resync before this park started.
    if s.tFriendAvatarData == nil and Bridge.GetCachedPeerAvatar ~= nil then
      local tCached = Bridge.GetCachedPeerAvatar()
      if type(tCached) == "table" then
        local tClean = SanitizeAvatar(tCached)
        if tClean ~= nil then
          s.tFriendAvatarData = tClean
          s.bFriendAvatarFailed = false
          Log("restored cached friend avatar (group " .. tostring(tClean.group) .. ")")
        end
      end
    end
    SendOwnAvatarIfNeeded()
    -- If we are receiving friend poses but still lack their avatar look, ask them to re-send it.
    if s.tFriend ~= nil and s.tFriendAvatarData == nil and not Bridge.IsLoopback() then
      s.nAvatarReqTimer = (s.nAvatarReqTimer or 0) - (_nDt or 0)
      if s.nAvatarReqTimer <= 0 then
        s.nAvatarReqTimer = c_nAvatarReqInterval
        Bridge.SendPacket(c_nAvatar, nil, {k = "avatar_req"})
        Log("requested missing friend avatar")
      end
    end
    s.nSendTimer = s.nSendTimer - _nDt
    if s.nSendTimer <= 0 then
      s.nSendTimer = c_nSendInterval
      SendPose()
    end
  else
    s.sAvatarPeerKey = nil
    s.nAvatarReqTimer = 0
  end
  UpdateFriend(_nDt)
  UpdateExplorePreview(_nDt)
  UpdateVehicleExitPrebuild(_nDt)
  UpdateOwnBody(_nDt)
  if s.tPendingExploreExitHUD ~= nil then
    local sMode = CurrentUIMode()
    if sMode == "WalkingCamera" or sMode == "Photo" or sMode == "DriveVehicle" then
      s.tPendingExploreExitHUD = nil
      PublishExploreUIState("idle")
    elseif (s.nClock or 0) >= s.tPendingExploreExitHUD.untilClock then
      local mainHUD = s.tPendingExploreExitHUD.mainHUD
      s.tPendingExploreExitHUD = nil
      pcall(function() mainHUD:SetExplorerModeEnabled(false) end)
      PublishExploreUIState("idle")
    end
  end
end

-- Returns true when the packet was a presence packet.
-- Leaves 0x12 action packets (d.k == "action") unhandled so PZ2Coop.Actions processes them.
Presence.OnPacket = function(_tMsg)
  local d = _tMsg.tData
  if _tMsg.nType == c_nAvatar then
    if type(d) == "table" and (d.k == "action" or d.k == "vehicle") then
      return false
    end
    if type(d) == "table" and d.k == "avatar_req" then
      s.sAvatarPeerKey = nil
      SendOwnAvatarIfNeeded()
      return true
    end
    local tClean, sWhy = SanitizeAvatar(d)
    if tClean == nil then
      Log("dropped friend avatar packet (" .. tostring(sWhy) .. ")")
      return true
    end
    DestroyFriendBody()
    s.tFriendAvatarData = tClean
    s.bFriendAvatarFailed = false
    Log("received friend avatar (group " .. tostring(tClean.group) .. ")")
    -- If the peer just finished loading and sent their avatar while ours was sent earlier, re-send ours too.
    if not Bridge.IsLoopback() and s.nAvatarSentAt ~= nil and (s.nClock - s.nAvatarSentAt) > 2.0 then
      s.sAvatarPeerKey = nil
    end
    return true
  end
  if _tMsg.nType ~= c_nCursor then
    return false
  end
  for _, sKey in ipairs({"cx", "cy", "cz", "px", "py", "pz", "yaw", "m"}) do
    if type(d[sKey]) ~= "number" then
      return true
    end
  end
  local vx, vy, vz = 0, 0, 0
  local tOld = s.tFriend
  if tOld ~= nil and tOld.nRxAt ~= nil then
    local dt = s.nClock - tOld.nRxAt
    if dt >= 0.01 and dt <= 1.0 then
      local ddx, ddy, ddz = d.px - tOld.px, d.py - tOld.py, d.pz - tOld.pz
      local nDist = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
      if nDist < c_nSnapDistance then
        -- Clamp dt floor to 0.04 s so bursty packet arrivals never spike inferred velocity, then EMA-smooth.
        local effDt = Clamp(dt, 0.04, 0.35)
        local rawVx = Clamp(ddx / effDt, -c_nMaxPeerVel, c_nMaxPeerVel)
        local rawVy = Clamp(ddy / effDt, -c_nMaxPeerVel, c_nMaxPeerVel)
        local rawVz = Clamp(ddz / effDt, -c_nMaxPeerVel, c_nMaxPeerVel)
        if nDist < 0.015 then
          vx = (tOld.vx or 0) * 0.45
          vy = (tOld.vy or 0) * 0.45
          vz = (tOld.vz or 0) * 0.45
        else
          vx = (tOld.vx or rawVx) * 0.55 + rawVx * 0.45
          vy = (tOld.vy or rawVy) * 0.55 + rawVy * 0.45
          vz = (tOld.vz or rawVz) * 0.55 + rawVz * 0.45
        end
      end
    end
  end
  local nPitch = (type(d.pitch) == "number" and d.pitch == d.pitch) and d.pitch or 0
  s.tFriend = {cx = d.cx, cy = d.cy, cz = d.cz, px = d.px, py = d.py, pz = d.pz, yaw = d.yaw, pitch = nPitch, m = d.m,
    nAge = 0, vx = vx, vy = vy, vz = vz, nRxAt = s.nClock}
  if not s.bLoggedRx then
    s.bLoggedRx = true
    Log("first friend pose received (mode " .. tostring(d.m) .. ")")
  end
  return true
end

Presence.RequestGoToFriend = function()
  s.bGoRequest = true
end

Presence.RequestViewFriend = function()
  s.bViewRequest = true
end

Presence.HasFriend = function()
  return s.tFriend ~= nil
end

Presence.GetOwnBody = function()
  return s.tOwnBody
end

Presence.GetExplorePreview = function()
  return s.tExplorePreview
end

Presence.GetFriendBody = function()
  return s.tFriendBody
end

Presence.GetOwnPose = function()
  return s.tOwnPose
end

Presence.GetOwnBodyYaw = function()
  return s.nBodyYaw
end

Presence.GetFriendPose = function()
  return s.tShown or s.tFriend
end

Presence.GetWeather = function()
  return s.sWeather or "clear"
end

Presence.SetSeatOverride = function(_tSeat)
  s.tSeatOverride = _tSeat
end

Presence.SetFriendSeatOverride = function(_tSeat)
  s.tFriendSeatOverride = _tSeat
end

Presence.SetVehicleOwnOverride = function(_tPose)
  s.tVehicleOwnOverride = _tPose
end

Presence.SetVehicleFriendOverride = function(_tPose)
  s.tVehicleFriendOverride = _tPose
end

Presence.SetVehiclePromptProvider = function(_fn)
  s.fnVehiclePromptProvider = _fn
end

Presence.PrepareVehicleExit = function(_vPos, _vYPR)
  s.tPendingVehicleExit = {vPos = _vPos, vYPR = _vYPR}
end

Presence.CancelVehicleExit = function()
  DestroyVehicleExitPrebuild()
  s.tPendingVehicleExit = nil
  s.nVehicleExitAdoptUntil = nil
end

-- Pre-spawns the walking own avatar at the door exit spot (in 3P and 1P) before switching to WalkingCamera so the player
-- is already standing cleanly at the door on the exact frame the camera moves (zero pop-in!).
Presence.BeginVehicleExit = function(_vPos, _vYPR, _fnOnReady)
  DestroyVehicleExitPrebuild()
  if s.bOwnUnavailable or _vPos == nil then
    s.tPendingVehicleExit = {vPos = _vPos, vYPR = _vYPR}
    if type(_fnOnReady) == "function" then
      pcall(_fnOnReady)
    end
    return
  end
  local ex, ey, ez = ReadVec3(_vPos)
  if ex == nil then
    s.tPendingVehicleExit = {vPos = _vPos, vYPR = _vYPR}
    if type(_fnOnReady) == "function" then
      pcall(_fnOnReady)
    end
    return
  end
  local eyaw = 0
  if _vYPR ~= nil then
    local y = ReadVec3(_vYPR)
    if y ~= nil then
      eyaw = y
    end
  end
  local nFeetY = SampleGroundY(ex, ey - WalkingHeight(), ez)
  s.tVehicleExitPrebuild = {
    nAge = 0,
    nWaitTime = 0,
    x = ex, y = nFeetY, z = ez, yaw = eyaw,
    vPos = _vPos, vYPR = _vYPR,
    fnOnReady = _fnOnReady,
    bAdopted = false,
    tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopExitBody", nil,
      PoseTransform(ex, nFeetY, ez, eyaw)),
  }
end

Presence.IsThirdPerson = function()
  return s.bThirdPerson == true
end

Presence.SetRemoteOpenGate = function(_nGateID)
  s.nRemoteOpenGate = _nGateID
end

Presence.SetLocalOpenGate = function(_nGateID)
  s.nLocalOpenGate = _nGateID
end

Presence.SetActionHooks = function(_fnOnAvatarSent, _fnOnGoArrival)
  s.fnOnAvatarSent = _fnOnAvatarSent
  s.fnOnGoArrival = _fnOnGoArrival
end

Presence.SetWheelOpenCheck = function(_fnOpen, _fnBlocking)
  s.fnIsWheelOpen = _fnOpen
  s.fnIsWheelBlocking = _fnBlocking or _fnOpen
end

Presence.SetCustomTooltipProvider = function(_fn)
  s.fnCustomTooltip = _fn
end

Presence.SetOpenGatePos = function(_sKey, _tPos)
  s.tOpenGates = s.tOpenGates or {}
  s.tOpenGates[_sKey] = _tPos
end

Presence.SetOpenPortal = function(_sKey, _tPortal)
  s.tOpenPortals = s.tOpenPortals or {}
  s.tOpenPortals[_sKey] = _tPortal
end

Presence.ClearOpenPortals = function()
  s.tOpenPortals = {}
end

Presence.SetClosedDoorCheck = function(_fn)
  s.fnHasClosedDoorAt = _fn
end

Presence.IsAquariumStaffDoorEntity = IsAquariumStaffDoorEntity

Presence.ClassifyCutoutResource = ClassifyCutoutResource

Presence.SetThirdPerson = function(_bOn)
  s.bThirdPerson = _bOn == true
  s.nCamTarget = s.bThirdPerson and (s.nThirdDist or c_nThirdBack) or 0
  Log("third person " .. (s.bThirdPerson and "on" or "off"))
end

Presence.Shutdown = function()
  pcall(ForgetFriend)
  DestroyExplorePreview()
  DestroyVehicleExitPrebuild()
  DestroyOwnBody()
  s.bExploreInitActive = false
  s.tExploreDrop = nil
  s.tExploreCamEase = nil
  s.nExploreDropBaseClearAt = nil
  s.tPendingExploreExitHUD = nil
  PublishExploreUIState("idle")
  s.bPendingExploreDrop = false
  s.nExploreDropUntil = 0
  s.tOwnPose = nil
  s.sAvatarPeerKey = nil
  s.bLoggedRx = false
  s.tSeatOverride = nil
  s.tFriendSeatOverride = nil
  s.tVehicleOwnOverride = nil
  s.tVehicleFriendOverride = nil
  s.tPendingVehicleExit = nil
  s.tVehicleExitPrebuild = nil
  s.nVehicleExitAdoptUntil = nil
  s.bOwnVehicleOverrideWasActive = false
  s.bFriendVehicleOverrideWasActive = false
  s.tOpenGates = {}
  s.tOpenPortals = {}
  s.nLocalOpenGate = nil
  s.nRemoteOpenGate = nil
end

Presence.Reset = function()
  s.tFriendRing, s.tFriendBody, s.tOwnBody = nil, nil, nil
  s.bExploreInitActive, s.tExplorePreview, s.tExploreDrop, s.tExploreCamEase, s.nExploreDropBaseClearAt,
    s.tPendingExploreExitHUD, s.vExploreStartPos, s.bExploreStartPosFresh = false, nil, nil, nil, nil, nil, nil, false
  s.sExploreUIState = "idle"
  s.bPendingExploreDrop, s.nExploreDropUntil = false, 0
  s.tFriend, s.tShown, s.tOwnPose = nil, nil, nil
  s.tFriendAvatarData, s.tFriendPrev, s.nFriendBodyYaw = nil, nil, nil
  s.bFriendAvatarFailed = false
  s.sAvatarPeerKey = nil
  s.tFollow, s.tOwnPrev, s.nBodyYaw, s.nOwnGroundY, s.nOwnSpeed, s.nOwnSmoothSpeed = nil, nil, nil, nil, 0, 0
  s.nOwnYawRate, s.bOwnInWater, s.nOwnWaterSurface = 0, false, nil
  s.nSprintBlend, s.nBobPhase, s.nBobAmp, s.nOcclRatio = 0, 0, 0, nil
  s.bOwnUnavailable = false
  s.bLabelShown = false
  s.bPromptAdded = false
  s.bWasPhotoMode = false
  s.tSeatOverride = nil
  s.tFriendSeatOverride = nil
  s.tVehicleOwnOverride = nil
  s.tVehicleFriendOverride = nil
  s.tPendingVehicleExit = nil
  s.tVehicleExitPrebuild = nil
  s.nVehicleExitAdoptUntil = nil
  s.bOwnVehicleOverrideWasActive = false
  s.bFriendVehicleOverrideWasActive = false
  s.tOpenGates = {}
  s.tOpenPortals = {}
  s.nLocalOpenGate = nil
  s.nRemoteOpenGate = nil
end
