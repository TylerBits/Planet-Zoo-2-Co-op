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
local c_nSendInterval = 0.1
local c_nFriendTimeout = 5.0
local c_nSmoothRate = 12.0 -- per second spring/tracking rate toward velocity-predicted friend pose
local c_nMaxPredictSec = 0.12 -- bounded dead-reckoning horizon for 10 Hz peer updates
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
local c_nBodyHideDist = 0.9 -- metres: closer than this the camera is inside the body, so it is hidden
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
local c_nMinWalkableNormalY = 0.65 -- ~49 deg max walkable slope; rejects steep curved wall faces/bevels
local c_nBodyCapsuleRadius = 0.25 -- body collision radius for chest/waist wall sweeps
local c_nStopDampRate = 18.0 -- rapid braking decay on vanilla WalkingCamera residual glide when WASD released
local c_nWeatherInterval = 2.0 -- 0.5 Hz weather query
local c_nGoSide = 1.5 -- "Go to friend" lands this far to the friend's right
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
    bThirdPerson = false,
    bGoRequest = false,
    bViewRequest = false,
    bLabelShown = false,
    bLoggedRx = false,
    bPromptAdded = false,
    bKeyErrorLogged = false,
    bWasPhotoMode = false,
    -- Hooks set by PZ2Coop.Actions (sitting, hold-hands tether, arrival callback, emote wheel cursor release)
    tSeatOverride = nil, -- {x, y, z, yaw, eyeHeight}
    tFriendSeatOverride = nil,
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

-- Exact ground contact raycast straight down from (x, y + 0.45, z) via CameraUtils.FocusRaycast (fallback: _nFallbackY).
-- Tight vertical window [-0.60, +0.25] refines stair/slope contact without ever snapping up onto nearby curved walls/ledges.
local SampleGroundY = function(_nX, _nFallbackY, _nZ)
  local bOk, nY = pcall(function()
    local CameraUtils = require("Components.Cameras.CameraUtils")
    if type(CameraUtils) ~= "table" or CameraUtils.FocusRaycast == nil then
      return nil
    end
    local tWorld = WorldAPIs()
    if tWorld.CameraModeManager == nil or tWorld.CameraModeManager.GetVoxelTerrainID == nil then
      return nil
    end
    local nTerrainId = tWorld.CameraModeManager:GetVoxelTerrainID()
    if nTerrainId == nil then
      return nil
    end
    local vHit = CameraUtils.FocusRaycast(tWorld, nTerrainId, Vector3:new(_nX, _nFallbackY + 0.45, _nZ),
      Vector3:new(0, -1, 0), true, false, false)
    if vHit == nil then
      return nil
    end
    local hy = vHit.GetY and vHit:GetY() or vHit:Y()
    if type(hy) == "number" and hy == hy and hy >= _nFallbackY - 0.60 and hy <= _nFallbackY + 0.25 then
      return hy
    end
    return nil
  end)
  return (bOk and type(nY) == "number") and nY or _nFallbackY
end

-- Smooths avatar vertical position: fast downward snap on stairs, gentle upward easing, buoyant float in deep water.
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
  local nRate = _bInWater and 8.0 or (nTargetY < _nPrevY and 24.0 or 12.0)
  return _nPrevY + (nTargetY - _nPrevY) * (1 - math.exp(-nRate * _nDt))
end

-- ---- spawned entities ---------------------------------------------------------------------------
-- Record: {nId, token, sPrefab, nAge, bReady, bFailed}. _prefab is a prefab name or a prefab table.
local Spawn = function(_prefab, _sName, _tProps, _transform)
  local sPrefab = type(_prefab) == "string" and _prefab or _sName
  local token = api.entity.CreateRequestCompletionToken()
  local bOk, nId = pcall(api.entity.InstantiatePrefab, _prefab, _sName, token,
    _transform or TransformQ.Identity:WithPos(c_vHidden), nil, nil, _tProps)
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
  local tLabel = {sLabel = sName, vPos = Vector3:new(_nX, _nY, _nZ), nOpacity = 0.5}
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
  local tPacket = {cx = vPos:GetX(), cy = vPos:GetY(), cz = vPos:GetZ(), yaw = vYPR:GetX()}
  if cameraModeManager:GetCurrentModeName() == "Walking" then
    tPacket.m = s.bThirdPerson and 2 or 1
    if s.tSeatOverride ~= nil then
      tPacket.px, tPacket.py, tPacket.pz = s.tSeatOverride.x, s.tSeatOverride.y, s.tSeatOverride.z
      tPacket.yaw = s.tSeatOverride.yaw
    else
      tPacket.px, tPacket.py, tPacket.pz = tPacket.cx, tPacket.cy - WalkingHeight(), tPacket.cz
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
    _tBody.co = coroutine.create(function()
      local nAvatar, bAnimated = Avatar.CreateAnimated(tAvatar, _tBody.tParent.nId, "friend")
      _tBody.nAvatar = nAvatar
      _tBody.tAnim = Avatar.CreateAnimState(tAvatar.group, bAnimated)
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
    WorldAPIs().model:SetHidden(_tBody.nAvatar, _bHidden)
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
  -- Velocity-predicted target (bounded dead-reckoning up to 120 ms) for silky-smooth 60+ FPS interpolation.
  local nPred = math.min(t.nAge, c_nMaxPredictSec)
  local nTargetX = t.px + (t.vx or 0) * nPred
  local nTargetY = t.py + (t.vy or 0) * nPred
  local nTargetZ = t.pz + (t.vz or 0) * nPred
  local nTargetYaw = t.yaw
  if s.tFriendSeatOverride ~= nil then
    nTargetX, nTargetY, nTargetZ = s.tFriendSeatOverride.x, s.tFriendSeatOverride.y, s.tFriendSeatOverride.z
    nTargetYaw = s.tFriendSeatOverride.yaw
  end

  local sh = s.tShown
  local dx, dy, dz = nTargetX - (sh and sh.x or 0), nTargetY - (sh and sh.y or 0), nTargetZ - (sh and sh.z or 0)
  if sh == nil or dx * dx + dy * dy + dz * dz > c_nSnapDistance * c_nSnapDistance then
    s.tShown = {x = nTargetX, y = nTargetY, z = nTargetZ, yaw = nTargetYaw, ySmooth = nTargetY}
    s.tFriendPrev = nil
    s.nFriendBodyYaw = nTargetYaw
    if s.tFriendBody ~= nil then
      Avatar.ResetAnimSpeed(s.tFriendBody.tAnim, s.tFriendBody.nAvatar)
    end
  else
    local k = 1 - math.exp(-c_nSmoothRate * _nDt)
    sh.x, sh.y, sh.z = sh.x + dx * k, sh.y + dy * k, sh.z + dz * k
    sh.yaw = sh.yaw + WrapAngle(nTargetYaw - sh.yaw) * k
  end
  sh = s.tShown
  local bWalking = (t.m or 0) >= 1
  local bAvatarDrawn = false
  if bWalking and s.tFriendAvatarData ~= nil and not s.bFriendAvatarFailed then
    if s.tFriendBody == nil then
      s.tFriendBody = {nAge = 0, tParent = Spawn({Components = {Transform = {}}}, "PZ2CoopFriendBody", nil,
        PoseTransform(sh.x, sh.y, sh.z, sh.yaw))}
    end
    local tBody = s.tFriendBody
    if IsReady(tBody.tParent, _nDt) then
      local nFriendSpeed, nFriendYawRate, bRev, bLeft
      if s.tFriendSeatOverride ~= nil then
        s.nFriendBodyYaw = s.tFriendSeatOverride.yaw
        s.tFriendPrev = {x = sh.x, z = sh.z}
        nFriendSpeed, nFriendYawRate, bRev, bLeft = 0, 0, false, false
      else
        s.nFriendBodyYaw, s.tFriendPrev, nFriendSpeed, nFriendYawRate, bRev, bLeft =
          StepBodyYaw(s.tFriendPrev, s.nFriendBodyYaw, sh.x, sh.z, sh.yaw, _nDt)
      end
      local bInWater, nWaterSurf = IsInDeepWater(sh.x, sh.y, sh.z)
      if s.tFriendSeatOverride ~= nil then
        sh.ySmooth = sh.y
        bInWater = false
      else
        sh.ySmooth = ComputeAvatarY(sh.ySmooth, sh.x, sh.y, sh.z, _nDt, bInWater, nWaterSurf)
      end
      local nPitch, nRoll = 0, 0
      if tBody.tAnim ~= nil then
        nPitch, nRoll = Avatar.StepBodyLean(tBody.tAnim, nFriendYawRate, nFriendSpeed, _nDt, bInWater)
      end
      Place(tBody.tParent, sh.x, sh.ySmooth, sh.z, s.nFriendBodyYaw, nPitch, nRoll)
      local bOk, sError = pcall(AdvanceFriendAvatar, tBody, _nDt)
      if not bOk then
        Log("friend avatar error: " .. tostring(sError))
        s.bFriendAvatarFailed = true
      elseif tBody.nAvatar ~= nil then
        SetBodyHidden(tBody, false)
        if bRev then
          Avatar.TriggerPivot180(tBody.tAnim, tBody.nAvatar, bLeft)
        end
        Avatar.UpdateAnimation(tBody.tAnim, tBody.nAvatar, nFriendSpeed, _nDt, bInWater, s.sWeather)
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
    if s.tSeatOverride ~= nil then
      local vSeatEye = Vector3:new(s.tSeatOverride.x, s.tSeatOverride.y + (s.tSeatOverride.eyeHeight or 1.15), s.tSeatOverride.z)
      tFinal.transformQ = tFinal.transformQ:WithPos(vSeatEye)
    elseif s.bOwnInWater and type(s.nOwnWaterSurface) == "number" then
      local vEyeFP = tFinal.vCameraPos
      local nWaterEyeY = math.max(vEyeFP:GetY(), s.nOwnWaterSurface + 0.35)
      tFinal.transformQ = tFinal.transformQ:WithPos(Vector3:new(vEyeFP:GetX(), nWaterEyeY, vEyeFP:GetZ()))
    end
    s.tOwnPose, s.tFollow, s.nOcclRatio, s.nBobAmp = nil, nil, nil, 0
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
  tFinal.transformQ = tFinal.transformQ:WithPos(Vector3:new(x, y, z))
  if s.tSeatOverride ~= nil then
    s.tOwnPose = {x = s.tSeatOverride.x, y = s.tSeatOverride.y, z = s.tSeatOverride.z, yaw = s.tSeatOverride.yaw,
      bHidden = nDist < c_nBodyHideDist}
  else
    s.tOwnPose = {x = vEye:GetX(), y = vEye:GetY() - WalkingHeight(), z = vEye:GetZ(), yaw = nYaw,
      bHidden = nDist < c_nBodyHideDist}
  end
end

local InstallCameraWrap = function()
  local bOk, WalkingCamera = pcall(require, "Components.Cameras.WalkingCamera")
  if not bOk or type(WalkingCamera) ~= "table" or rawget(WalkingCamera, "__PZ2CoopOriginalAdvance") ~= nil then
    return
  end
  -- Fix vanilla short-wall & curved-wall climbing: WalkingCamera.AdvanceWalkingWASD raycasts downward at the
  -- pre-collision target (ex, ez) and only sweeps a 15 cm sphere at EYE height (1.55 m). Wrapping SweepAndSlide
  -- runs flat horizontal capsule sweeps at head/chest/waist (including Flag_Prop) FIRST, then validates vertical
  -- step-up strictly at the post-collision (rx, rz) and rejects steep curved-wall normals (normal.y < 0.65).
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
        local nBandFlags = type(_nFlags) == "number" and _nFlags or 0
        if api.physics ~= nil and type(api.physics.Flag_Prop) == "number" then
          nBandFlags = nBandFlags | api.physics.Flag_Prop
        end
        local nHeadR = math.max(type(_nRadius) == "number" and _nRadius or 0.15, 0.22)
        -- Sweep all 3 body bands HORIZONTALLY at flat sy so walls are never ramped diagonally upward.
        local vFlatGoal = Vector3:new(ex, sy, ez)
        local vRes = fnOrigSweep(_nPhysWorld, _vStart, vFlatGoal, _nFlags, nHeadR, _nIters)
        local rx, rz = vRes:GetX(), vRes:GetZ()
        local nBestProj = (rx - sx) * dx0 + (rz - sz) * dz0
        local bBlocked = ((rx - ex) ^ 2 + (rz - ez) ^ 2) > 2.5e-5
        -- Chest (-0.50 m, r=0.25) and waist/knee (-0.95 m, r=0.22 -> bottom at feet+0.38 m) clear normal stair
        -- risers (<= 0.25 m) while solidly blocking short/curved walls and aquarium barriers.
        for _, tBand in ipairs({{0.50, c_nBodyCapsuleRadius}, {0.95, 0.22}}) do
          local nDrop, nBandR = tBand[1], tBand[2]
          local vLowStart = Vector3:new(sx, sy - nDrop, sz)
          local vLowEnd = Vector3:new(ex, sy - nDrop, ez)
          local vLowRes = fnOrigSweep(_nPhysWorld, vLowStart, vLowEnd, nBandFlags, nBandR, _nIters)
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
        -- Resolve vertical Y strictly at the post-collision (rx, rz) so wall hits never ratchet the player upward.
        local ry = ey
        if (ry - sy) > c_nMaxStepUpM then
          ry = sy
        end
        if bBlocked and ry > sy then
          local nMovedSq = (rx - sx) ^ 2 + (rz - sz) ^ 2
          if nMovedSq < 1e-4 then
            ry = sy
          else
            local nWalkH = WalkingHeight()
            local nGroundY = SampleGroundY(rx, sy - nWalkH, rz)
            ry = math.min(nGroundY + nWalkH, sy + c_nMaxStepUpM)
          end
        end
        -- Reject climbing steep curved wall faces / bevels (surface normal.y < 0.65 => steeper than ~49 deg).
        if ry > sy + 0.02 and api.physics ~= nil and api.physics.RayCast ~= nil then
          local nCheckFlags = nBandFlags
          if type(api.physics.Flag_Landscape) == "number" then
            nCheckFlags = nCheckFlags | api.physics.Flag_Landscape
          end
          local tHits = api.physics.RayCast(_nPhysWorld, Vector3:new(rx, sy - 0.15, rz),
            Vector3:new(rx, sy - 2.0, rz), nCheckFlags, 1)
          local tHit = type(tHits) == "table" and tHits[1] or nil
          if tHit ~= nil and tHit.vNormal ~= nil then
            local vN = tHit.vNormal
            local ny = vN.GetY and vN:GetY() or (vN.Y and vN:Y() or 1.0)
            if type(ny) == "number" and ny < c_nMinWalkableNormalY then
              rx, ry, rz = sx, sy, sz
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
    Log("walking collision wrapped (flat capsule sweeps + curved-wall anti-climb)")
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
    fnOriginal(_tData, _tWorldAPIs, _nUnscaledDeltaTime, ...)
    if tWalk ~= nil and tWalk.nWalkingHeightIndex == 1 then
      tWalk.nWalkingHeightIndex = 2
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
    return 0, 0, false, false
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
    _tBody.co = coroutine.create(function()
      local nAvatar, bAnimated = Avatar.CreateAnimated(tAvatar, _tBody.tParent.nId, "player")
      _tBody.nAvatar = nAvatar
      _tBody.tAnim = Avatar.CreateAnimState(tAvatar.group, bAnimated)
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

local UpdateOwnBody = function(_nDt)
  local bWalking = WorldAPIs().CameraModeManager:GetCurrentModeName() == "Walking"
  local t = s.tOwnPose
  if not (bWalking and t ~= nil) or s.bOwnUnavailable then
    DestroyOwnBody()
    return
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
  local nOwnSpeed, nYawRate, bRev, bLeft = TurnBody(t, _nDt)
  s.nOwnSpeed = nOwnSpeed
  s.nOwnYawRate = nYawRate
  local nClampedSpeed = (type(nOwnSpeed) == "number" and nOwnSpeed <= 15.0) and nOwnSpeed or 0
  local nSpdDt = type(_nDt) == "number" and _nDt > 0 and _nDt or (1 / 60)
  s.nOwnSmoothSpeed = (s.nOwnSmoothSpeed or 0) + (nClampedSpeed - (s.nOwnSmoothSpeed or 0)) * (1 - math.exp(-10.0 * nSpdDt))
  if s.nOwnSmoothSpeed < 0.01 then
    s.nOwnSmoothSpeed = 0
  end
  local bInWater, nWaterSurf = IsInDeepWater(t.x, t.y, t.z)
  if s.tSeatOverride ~= nil then
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
  end
  Place(tBody.tParent, t.x, s.nOwnGroundY, t.z, s.nBodyYaw, nPitch, nRoll)
  local bOk, sError = pcall(AdvanceOwnAvatar, tBody, _nDt)
  if not bOk then
    Log("own avatar error: " .. tostring(sError))
    s.bOwnUnavailable = true
    return
  end
  if tBody.nAvatar ~= nil then
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
    Avatar.UpdateAnimation(tBody.tAnim, tBody.nAvatar, nOwnSpeed, _nDt, bInWater, s.sWeather)
  end
  if tBody.nAvatar ~= nil and tBody.bHidden ~= (t.bHidden == true) then
    tBody.bHidden = t.bHidden == true
    WorldAPIs().model:SetHidden(tBody.nAvatar, tBody.bHidden)
  end
end

-- C on foot toggles third person (the vehicle handles the same key itself, see InstallVehicleWrap).
local HandleToggleKey = function()
  if CurrentUIMode() == "WalkingCamera" and WorldAPIs().InputManager:GetKeyPressed("GameCamera_ToggleThirdPerson") then
    Presence.SetThirdPerson(not s.bThirdPerson)
  end
end

-- ---- native explore on foot --------------------------------------------------------------------
local EnterNativeExplore = function(_self)
  if CurrentUIMode() == "WalkingCamera" then
    return nil
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
  Log("walking UI mode wrapped (emote wheel clicks stay on foot)")
end

-- ---- module API --------------------------------------------------------------------------------
Presence.Install = function()
  InstallCameraWrap()
  InstallExploreWrap()
  InstallVehicleWrap()
  InstallWalkingUIModeWrap()
end

local SendOwnAvatarIfNeeded = function()
  local tSession = Bridge.GetSession()
  local sPeerKey = Bridge.IsLoopback() and "loopback" or (tSession.sPartnerId or "peer")
  if s.sAvatarPeerKey == sPeerKey then
    return
  end
  s.sAvatarPeerKey = sPeerKey
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
    SendOwnAvatarIfNeeded()
    s.nSendTimer = s.nSendTimer - _nDt
    if s.nSendTimer <= 0 then
      s.nSendTimer = c_nSendInterval
      SendPose()
    end
  else
    s.sAvatarPeerKey = nil
  end
  UpdateFriend(_nDt)
  UpdateOwnBody(_nDt)
end

-- Returns true when the packet was a presence packet.
-- Leaves 0x12 action packets (d.k == "action") unhandled so PZ2Coop.Actions processes them.
Presence.OnPacket = function(_tMsg)
  local d = _tMsg.tData
  if _tMsg.nType == c_nAvatar then
    if type(d) == "table" and d.k == "action" then
      return false
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
    if dt >= 0.02 and dt <= 1.0 then
      local ddx, ddy, ddz = d.px - tOld.px, d.py - tOld.py, d.pz - tOld.pz
      local nDist = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
      if nDist < c_nSnapDistance then
        vx = Clamp(ddx / dt, -c_nMaxPeerVel, c_nMaxPeerVel)
        vy = Clamp(ddy / dt, -c_nMaxPeerVel, c_nMaxPeerVel)
        vz = Clamp(ddz / dt, -c_nMaxPeerVel, c_nMaxPeerVel)
      end
    end
  end
  s.tFriend = {cx = d.cx, cy = d.cy, cz = d.cz, px = d.px, py = d.py, pz = d.pz, yaw = d.yaw, m = d.m,
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

Presence.GetFriendBody = function()
  return s.tFriendBody
end

Presence.GetOwnPose = function()
  return s.tOwnPose
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

Presence.SetActionHooks = function(_fnOnAvatarSent, _fnOnGoArrival)
  s.fnOnAvatarSent = _fnOnAvatarSent
  s.fnOnGoArrival = _fnOnGoArrival
end

Presence.SetWheelOpenCheck = function(_fnOpen, _fnBlocking)
  s.fnIsWheelOpen = _fnOpen
  s.fnIsWheelBlocking = _fnBlocking or _fnOpen
end

Presence.SetThirdPerson = function(_bOn)
  s.bThirdPerson = _bOn == true
  s.nCamTarget = s.bThirdPerson and (s.nThirdDist or c_nThirdBack) or 0
  Log("third person " .. (s.bThirdPerson and "on" or "off"))
end

Presence.Shutdown = function()
  pcall(ForgetFriend)
  DestroyOwnBody()
  s.tOwnPose = nil
  s.sAvatarPeerKey = nil
  s.bLoggedRx = false
  s.tSeatOverride = nil
  s.tFriendSeatOverride = nil
end

Presence.Reset = function()
  s.tFriendRing, s.tFriendBody, s.tOwnBody = nil, nil, nil
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
end
