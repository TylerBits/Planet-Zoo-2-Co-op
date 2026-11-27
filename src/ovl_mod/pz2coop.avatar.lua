-- PZ2-Coop animated player & friend avatars using native guest animations (Guests.ovl).
-- Implements AAA locomotion polish (docs/AAA_AVATAR_LOCOMOTION_PLAN.md Phases 1-2) and prop/emote hooks
-- (docs/PLAYER_NPC_ACTIVITIES_PLAN.md):
--   - Asymmetric velocity-aware crossfade blending (fast start 0.14s, smooth gait 0.24s, weighty stop 0.34s)
--   - Living idle cycling (StandBaseIdle01/02/03), bored fidgets (StandCheckPhone / WalkReactYawn) with instant
--     move-cancel, sprint fatigue (StandTiredIdle01..03 after >10s sprint), and walk cycle variety
--   - Weather-reactive idle/walk posture (Rain: StandWet/WalkWetBase, Snow: StandCold/WalkColdBase, Heat: StandReactHeat)
--   - 180-degree pivot one-shots (WalkReactTurn180_L/R) on sharp movement reversals
--   - Procedural corner banking (roll lean into turns) and acceleration/deceleration + swim pitch lean
--   - Whitelisted hand-bone prop attachment (AttachPoint + bakedanimation:RequestAllBonesForCalculate)
local global = _G
local api = global.api
local math = global.math
local string = global.string
local table = global.table
local tostring = global.tostring
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local coroutine = global.coroutine
local require = global.require
local Vector3 = require("Vector3")
local TransformQ = require("TransformQ")
local Quaternion = require("Quaternion")
local Bridge = require("PZ2Coop.Bridge")

local Avatar = module(...)

local c_nSpeedSmoothRate = 12.0 -- per second exponential smoothing for horizontal speed
local c_nAccelSmoothRate = 6.5 -- GTA-style weighted speed ramp-up (idle -> walk -> jog -> sprint)
local c_nDecelSmoothRate = 26.0 -- snappy braking so run/jog stops cleanly without running in place
local c_nRemoteDecelSmoothRate = 8.5 -- gentler deceleration for networked peers to prevent mid-stride stutter
local c_nStopSnapDelay = 0.04 -- seconds of near-zero raw speed before snapping directly to idle
local c_nRemoteStopSnapDelay = 0.22 -- covers network packet jitter so remote peers don't blink to idle mid-walk
local c_nRateMin = 0.58
local c_nRateMax = 1.42
local c_nRateEpsilon = 0.04
local c_nMaxValidSpeed = 15.0 -- speeds above this are teleports/snaps, clamped to avoid false run spikes

-- Hysteresis thresholds (m/s): vanilla walking is ~2.0 m/s, sprinting ~5.6 m/s; gamepad stick hits intermediate speeds.
local c_nWalkEnter = 0.40
local c_nWalkExit = 0.30
local c_nJogEnter = 2.65
local c_nJogExit = 2.25
local c_nRunEnter = 4.25
local c_nRunExit = 3.75

-- Reference speeds for playback-rate stride matching per gait.
local c_tRefSpeed = {
  idle = nil,
  walk = 2.0,
  jog = 3.4,
  run = 5.5,
  swim = nil,
}

-- Asymmetric crossfade blend durations (seconds) passed as arg #5 to api.animationcontrol.SetBaseAnimation.
local c_nBlendStart = 0.14   -- Idle -> Walk/Jog/Run: snappy start
local c_nBlendGait = 0.24    -- Walk <-> Jog <-> Run: smooth stride transition
local c_nBlendStop = 0.20    -- Walk/Jog/Run -> Idle: crisp settle without running in place
local c_nBlendSwim = 0.35    -- Land <-> Swim
local c_nBlendIdleCycle = 0.45
local c_nBlendOverride = 0.22

-- Living idle / walk / fatigue / weather timings.
local c_nIdleCycleMin = 6.0
local c_nIdleCycleMax = 12.0
local c_nFidgetMin = 15.0
local c_nFidgetMax = 25.0
local c_nSprintFatigueThreshold = 10.0
local c_nTiredDuration = 3.5
local c_nWalkCycleInterval = 9.0
local c_nPivotCooldown = 0.8

-- Procedural banking, stride sway, slope posture & pitch spring tuning (GTA 5/6 grounded feel).
local c_nBankGain = 0.028
local c_nBankMax = 0.16        -- ~9 deg max lean into tight sprint curves
local c_nPitchBurstMax = 0.095 -- ~5.5 deg forward lean on sprint burst
local c_nPitchBrakeMin = -0.052 -- ~-3 deg upright brace on hard braking
local c_nSwimForwardPitch = 0.28 -- ~16 deg forward torso pitch while actively swimming
local c_nSlopeLeanMax = 0.14   -- ~8 deg uphill/downhill posture tilt
local c_nLeanStiffness = 14.0

-- Constrained third-person & co-op friend head tracking (anatomical neck limits + front-orbit dead-zone).
-- Limits & dynamic collar-tuck keep the rigid Head/Torso neckline seam sealed with zero hollow-body gap.
local c_nHeadYawMax = math.rad(48)          -- max neck-only horizontal turn without opening sloped collar seam
local c_nHeadYawGain = 0.85                 -- subtle softness inside active tracking cone
local c_nHeadHoldEnd = math.rad(100)        -- hold near max yaw when glancing over shoulder
local c_nHeadReturnEnd = math.rad(140)      -- smoothly relax to neutral by 140 deg (looking at self)
local c_nHeadPitchUpMax = math.rad(22)      -- negative pitch in PZ2 = looking up
local c_nHeadPitchDownMax = math.rad(18)    -- positive pitch in PZ2 = looking down
local c_nHeadPitchSwimDownMax = math.rad(10)-- keep face above waterline while swimming
local c_nHeadPitchGain = 0.80
local c_nHeadSpringOmega = 9.0              -- natural angular frequency (rad/s) for exact critically damped spring
local c_nHeadNeutralEps = 0.002
local c_nNeckSeamDrop = 0.045               -- shift pivot down from def_c_neck1_joint (1.369 m) to collar seam (~1.324 m)
local c_nCollarTuckPitch = 0.065            -- -Y collar tuck per sin(|pitch|) so lifted throat/nape rim stays inside shirt
local c_nCollarTuckYaw = 0.030              -- -Y collar tuck per (1 - cos(yaw)) for sloped neckline seam
local c_tFallbackNeckPivot = {0.0, 1.37, 0.08}

-- Upper/lower-body split for 1P strafing & backpedaling: twists Legs RenderGroup independently of Torso.
local c_nLegsTwistMax = math.rad(62)        -- max lower-body yaw twist relative to torso while strafing
local c_nLegsBackThreshold = math.rad(105)  -- beyond +/-105 deg from facing, treat as backpedaling (reverse stride)
local c_nLegsSpringOmega = 14.0             -- responsive critically damped spring for leg twist
local c_nLegsNeutralEps = 0.002
local c_bAllowReversePlayback = true        -- negative SetPlaybackRate on BakedAnimation for backwards stepping

-- Suffixes in Guests.ovl (baked .bani clips: AF, AM, TF, TM all ship these exact names).
local c_tClipSuffix = {
  idle = "$StandBaseIdle01",
  walk = "$WalkBase",
  jog = "$JogBase",
  run = "$RunBase",
  swim = "$CoasterCrash_TreadWater",
}

local c_tIdleVariants = {"$StandBaseIdle01", "$StandBaseIdle02", "$StandBaseIdle03"}
local c_tTiredVariants = {"$StandTiredIdle01", "$StandTiredIdle02", "$StandTiredIdle03"}
local c_tWalkVariants = {"$WalkBase", "$WalkBaseVariant01", "$WalkBaseVariantL", "$WalkBaseVariantR"}
local c_tBoredFidgets = {"$StandCheckPhone", "$WalkReactYawn"}

local c_tWeatherIdle = {
  rain = "$StandWet",
  snow = "$StandCold",
  heat = "$StandReactHeat",
}
local c_tWeatherWalk = {
  rain = "$WalkWetBase",
  snow = "$WalkColdBase",
  heat = "$WalkReactHeat",
}

-- Part ordering & BoundingScaler values matching vanilla PeepBase / Peep_Avatar.
local c_tPartOrder = {"Head", "Hair", "Torso", "Legs", "Accessory", "Beard"}
local c_tPartScaler = {
  Hair = 13,
  Head = 10,
  Legs = 2,
  Torso = 2,
  Accessory = 10,
  Beard = 10,
}

local Log = function(_sMessage)
  Bridge.Log("avatar: " .. _sMessage)
end

local WorldAPIs = function()
  return api.world.GetWorldAPIs()
end

local Clamp = function(_n, _lo, _hi)
  if _n < _lo then return _lo end
  if _n > _hi then return _hi end
  return _n
end

local WrapAngle = function(_n)
  return (_n + math.pi) % (2 * math.pi) - math.pi
end

-- Classifies PeepBodyPart children that rotate rigidly with the head around def_c_neck1_joint.
-- Excludes torso-mounted accessories (backpacks, audio guides) if ever present in the Accessory slot.
local IsHeadLookPart = function(_sPartName, _sModelName)
  if _sPartName == "Head" or _sPartName == "Hair" or _sPartName == "Beard" then
    return true
  end
  if _sPartName == "Accessory" then
    if type(_sModelName) == "string" then
      local sLow = string.lower(_sModelName)
      if string.find(sLow, "backpack", 1, true) ~= nil or string.find(sLow, "audioguide", 1, true) ~= nil then
        return false
      end
    end
    return true
  end
  return false
end

Avatar.IsHeadLookPart = IsHeadLookPart

-- Maps avatar group ("TMA", "AFA", "TM", etc.) to its 2-letter animation prefix ("AF", "AM", "TF", "TM").
Avatar.GroupPrefix = function(_sGroup)
  if type(_sGroup) == "string" and #_sGroup >= 2 then
    local sPrefix = string.upper(string.sub(_sGroup, 1, 2))
    if sPrefix == "AF" or sPrefix == "AM" or sPrefix == "TF" or sPrefix == "TM" then
      return sPrefix
    end
  end
  return "AM"
end

Avatar.GetClipName = function(_sGroup, _sState)
  local sSuffix = c_tClipSuffix[_sState] or c_tClipSuffix.idle
  return Avatar.GroupPrefix(_sGroup) .. sSuffix
end

Avatar.CreateAnimState = function(_sGroup, _bAnimated, _tMeta, _sInitialClipSuffix)
  local tMeta = type(_tMeta) == "table" and _tMeta or nil
  local sPrefix = Avatar.GroupPrefix(_sGroup)
  local sInitClip = (type(_sInitialClipSuffix) == "string" and _sInitialClipSuffix ~= "")
    and (sPrefix .. _sInitialClipSuffix) or Avatar.GetClipName(sPrefix, "idle")
  return {
    sGroup = sPrefix,
    bAnimated = _bAnimated == true,
    sState = "idle",
    sClip = sInitClip,
    nSmoothSpeed = 0,
    nPrevSmoothSpeed = 0,
    nStopTime = 0,
    nRate = 1.0,
    bErrorLogged = false,
    -- Living idle / walk / fatigue / fidget state
    nClock = 0,
    nIdleTimer = 0,
    nNextIdleSwap = 8.0,
    nIdleVariantIdx = 1,
    nStationaryTime = 0,
    nNextFidget = 18.0,
    nFidgetIdx = 1,
    bOneShotActive = false,
    nOneShotUntil = 0,
    nSprintAccum = 0,
    bSprintFatigueArmed = false,
    nTiredRemain = 0,
    nWalkTimer = 0,
    nWalkVariantIdx = 1,
    nLastPivotAt = -10.0,
    sWeather = "clear",
    -- Action / emote base override (sit, dance, photo, prop pose)
    sOverrideSuffix = nil,
    -- Procedural lean springs
    nRoll = 0,
    nRollVel = 0,
    nPitch = 0,
    nPitchVel = 0,
    -- Constrained head-look spring, dedicated HeadRig RenderGroup entity, & live neck pivot AttachPoint
    nHeadYaw = 0,
    nHeadYawVel = 0,
    nHeadPitch = 0,
    nHeadPitchVel = 0,
    bHeadNeutral = true,
    nHeadRig = tMeta and tMeta.nHeadRig or nil,
    tHeadParts = tMeta and tMeta.tHeadParts or nil,
    nNeckAttach = tMeta and tMeta.nNeckAttach or nil,
    -- Lower-body LegsRig RenderGroup & twist spring (1P strafing / diagonal / backpedal upper-lower split)
    nLegsRig = tMeta and tMeta.nLegsRig or nil,
    nLegsYaw = 0,
    nLegsYawVel = 0,
    bLegsNeutral = true,
    -- Attached hand-bone prop
    tProp = nil, -- {nAttachId, nPropId, sPrefab, sBone}
  }
end

-- Computes next gait state from smoothed speed (and water immersion) with hysteresis to prevent boundary flicker.
Avatar.PickState = function(_sCurrent, _nSpeed, _bInWater)
  if _bInWater == true then
    return "swim"
  end
  if _sCurrent == "run" then
    if _nSpeed < c_nWalkExit then
      return "idle"
    elseif _nSpeed < c_nJogExit then
      return "walk"
    elseif _nSpeed < c_nRunExit then
      return "jog"
    end
    return "run"
  elseif _sCurrent == "jog" then
    if _nSpeed >= c_nRunEnter then
      return "run"
    elseif _nSpeed < c_nWalkExit then
      return "idle"
    elseif _nSpeed < c_nJogExit then
      return "walk"
    end
    return "jog"
  elseif _sCurrent == "walk" then
    if _nSpeed >= c_nRunEnter then
      return "run"
    elseif _nSpeed >= c_nJogEnter then
      return "jog"
    elseif _nSpeed < c_nWalkExit then
      return "idle"
    end
    return "walk"
  else
    if _nSpeed >= c_nRunEnter then
      return "run"
    elseif _nSpeed >= c_nJogEnter then
      return "jog"
    elseif _nSpeed >= c_nWalkEnter then
      return "walk"
    end
    return "idle"
  end
end

Avatar.PickBlendTime = function(_sFrom, _sTo)
  if _sFrom == "swim" or _sTo == "swim" then
    return c_nBlendSwim
  end
  if _sFrom == "idle" and _sTo ~= "idle" then
    return c_nBlendStart
  end
  if _sFrom ~= "idle" and _sTo == "idle" then
    return c_nBlendStop
  end
  if _sFrom == "idle" and _sTo == "idle" then
    return c_nBlendIdleCycle
  end
  return c_nBlendGait
end

-- Applies a base animation clip with native crossfade blending via api.animationcontrol:
-- SetBaseAnimation(nEntityID, sAnimName, nPlaybackRate=1.0, bWaitForCurrent=false, nBlendTime=0.0, bSkipIfPlaying=true).
local ApplyBaseAnimation = function(_nAvatarID, _sClip, _nRate, _nBlendTime)
  local ac = api.animationcontrol
  if ac == nil or ac.SetBaseAnimation == nil then
    return false, "api.animationcontrol.SetBaseAnimation unavailable"
  end
  local bOk, sErr = pcall(ac.SetBaseAnimation, _nAvatarID, _sClip, _nRate or 1.0, false, _nBlendTime or c_nBlendStop, true)
  if not bOk then
    return false, tostring(sErr)
  end
  return true
end

local ApplyPlaybackRate = function(_nAvatarID, _nRate)
  local ac = api.animationcontrol
  if ac == nil or ac.SetPlaybackRate == nil then
    return false
  end
  local bOk = pcall(ac.SetPlaybackRate, _nAvatarID, _nRate)
  return bOk
end

Avatar.PlayOneShot = function(_tAnim, _nAvatarID, _sClipSuffix)
  if _tAnim == nil or not _tAnim.bAnimated or _nAvatarID == nil or type(_sClipSuffix) ~= "string" then
    return false
  end
  local ac = api.animationcontrol
  if ac == nil or ac.QueueOneShotAnimation == nil then
    return false
  end
  local sClip = _tAnim.sGroup .. _sClipSuffix
  local bOk = pcall(ac.QueueOneShotAnimation, _nAvatarID, sClip)
  if bOk then
    _tAnim.bOneShotActive = true
    _tAnim.nOneShotUntil = (_tAnim.nClock or 0) + 2.5
  end
  return bOk
end

Avatar.CancelOneShot = function(_tAnim, _nAvatarID)
  if _tAnim == nil or not _tAnim.bAnimated or _nAvatarID == nil then
    return
  end
  _tAnim.bOneShotActive = false
  _tAnim.nOneShotUntil = 0
  local ac = api.animationcontrol
  if ac == nil then
    return
  end
  if ac.ClearOneShotQueueAndForceStopOneShot ~= nil then
    pcall(ac.ClearOneShotQueueAndForceStopOneShot, _nAvatarID)
  elseif ac.ForceStopOneShot ~= nil then
    pcall(ac.ForceStopOneShot, _nAvatarID)
  end
end

Avatar.SetBaseOverride = function(_tAnim, _nAvatarID, _sClipSuffix, _nBlendTime)
  if _tAnim == nil then
    return false
  end
  _tAnim.sOverrideSuffix = _sClipSuffix
  if _tAnim.bAnimated and _nAvatarID ~= nil and type(_sClipSuffix) == "string" then
    local sClip = _tAnim.sGroup .. _sClipSuffix
    if sClip ~= _tAnim.sClip then
      local bOk = ApplyBaseAnimation(_nAvatarID, sClip, 1.0, _nBlendTime or c_nBlendOverride)
      if bOk then
        _tAnim.sClip = sClip
        _tAnim.nRate = 1.0
      end
      return bOk
    end
  end
  return true
end

Avatar.ClearBaseOverride = function(_tAnim, _nAvatarID, _nBlendTime)
  if _tAnim == nil or _tAnim.sOverrideSuffix == nil then
    return
  end
  _tAnim.sOverrideSuffix = nil
  if _tAnim.bAnimated and _nAvatarID ~= nil then
    local sClip = Avatar.GetClipName(_tAnim.sGroup, _tAnim.sState)
    if ApplyBaseAnimation(_nAvatarID, sClip, 1.0, _nBlendTime or c_nBlendOverride) then
      _tAnim.sClip = sClip
      _tAnim.nRate = 1.0
    end
  end
end

-- Triggers native 180-degree turn one-shot when reversing direction sharply while moving (> 1.2 m/s).
Avatar.TriggerPivot180 = function(_tAnim, _nAvatarID, _bTurnLeft)
  if _tAnim == nil or not _tAnim.bAnimated or _nAvatarID == nil or _tAnim.sOverrideSuffix ~= nil then
    return false
  end
  if _tAnim.sState == "swim" or _tAnim.nClock - _tAnim.nLastPivotAt < c_nPivotCooldown then
    return false
  end
  _tAnim.nLastPivotAt = _tAnim.nClock
  return Avatar.PlayOneShot(_tAnim, _nAvatarID, _bTurnLeft and "$WalkReactTurn180_L" or "$WalkReactTurn180_R")
end

-- Critically damped spring step for procedural banking roll & accel/swim pitch lean.
local StepSpring = function(_nVal, _nVel, _nTarget, _nStiff, _nDt)
  local nF = _nStiff * (_nTarget - _nVal) - 2.0 * math.sqrt(_nStiff) * _nVel
  _nVel = _nVel + nF * _nDt
  _nVal = _nVal + _nVel * _nDt
  return _nVal, _nVel
end

-- Computes procedural body (pitch, roll) in radians from angular velocity, acceleration, slope, stride sway, and swim state.
Avatar.StepBodyLean = function(_tAnim, _nYawRate, _nSpeed, _nDt, _bInWater, _nSlopeRad)
  if _tAnim == nil then
    return 0, 0
  end
  local nDt = type(_nDt) == "number" and _nDt > 0 and math.min(_nDt, 0.1) or (1 / 60)
  local nSpeed = _nSpeed or _tAnim.nSmoothSpeed or 0
  local nAccel = (_tAnim.nSmoothSpeed - (_tAnim.nPrevSmoothSpeed or _tAnim.nSmoothSpeed)) / nDt
  local nTargetRoll = 0
  local nTargetPitch = 0
  if _tAnim.sOverrideSuffix == nil then
    if _bInWater then
      -- Upright treading when still, pitched forward (+16 deg) with gentle stroke roll when swimming forward.
      local nSwimT = Clamp((nSpeed - 0.2) / 1.8, 0, 1)
      nTargetPitch = c_nSwimForwardPitch * nSwimT
      _tAnim.nStridePhase = (_tAnim.nStridePhase or 0) + nDt * (3.2 + nSwimT * 3.0)
      local nStrokeRoll = math.sin(_tAnim.nStridePhase) * 0.045 * nSwimT
      nTargetRoll = Clamp(-(_nYawRate or 0) * nSpeed * (c_nBankGain * 0.5) + nStrokeRoll, -0.10, 0.10)
    else
      -- GTA 5/6 grounded body lean: corner banking + subtle gait shoulder sway + accel/brake + hill slope lean.
      local nSway = 0
      if nSpeed > 0.35 then
        local nCadence = nSpeed >= 4.0 and 11.5 or (nSpeed >= 2.6 and 9.5 or 7.5)
        local nSwayAmp = nSpeed >= 4.0 and 0.028 or 0.016
        _tAnim.nStridePhase = (_tAnim.nStridePhase or 0) + nDt * nCadence
        nSway = math.sin(_tAnim.nStridePhase) * nSwayAmp
      end
      local nSlopeLean = Clamp((_nSlopeRad or 0) * 0.45, -c_nSlopeLeanMax * 0.6, c_nSlopeLeanMax)
      nTargetRoll = Clamp(-(_nYawRate or 0) * nSpeed * c_nBankGain + nSway, -c_nBankMax, c_nBankMax)
      nTargetPitch = Clamp(nAccel * 0.018 + nSlopeLean, c_nPitchBrakeMin - 0.04, c_nPitchBurstMax + c_nSlopeLeanMax)
    end
  end
  _tAnim.nRoll, _tAnim.nRollVel = StepSpring(_tAnim.nRoll or 0, _tAnim.nRollVel or 0, nTargetRoll, c_nLeanStiffness, nDt)
  _tAnim.nPitch, _tAnim.nPitchVel = StepSpring(_tAnim.nPitch or 0, _tAnim.nPitchVel or 0, nTargetPitch, c_nLeanStiffness, nDt)
  return _tAnim.nPitch, _tAnim.nRoll
end

-- Computes constrained target (yaw, pitch, weight) for head tracking given body-relative camera angles.
--   - 0..65 deg: smooth tracking (0.9x gain, clamped to +/-62 deg)
--   - 65..100 deg: holds naturally near +/-62 deg shoulder limit
--   - 100..140 deg: smoothstep falloff 1 -> 0 so orbiting in front to look at oneself relaxes to neutral
--   - 140..180 deg: neutral (0, 0) with zero snap when crossing +/-180 deg
Avatar.ComputeHeadLookTarget = function(_nRelYaw, _nRelPitch, _bInWater, _bSuppress)
  if _bSuppress == true then
    return 0, 0, 0
  end
  local nRelYaw = (type(_nRelYaw) == "number" and _nRelYaw == _nRelYaw) and WrapAngle(_nRelYaw) or 0
  local nRelPitch = (type(_nRelPitch) == "number" and _nRelPitch == _nRelPitch) and _nRelPitch or 0
  local nAbsYaw = math.abs(nRelYaw)
  local nWeight = 1.0
  if nAbsYaw >= c_nHeadReturnEnd then
    nWeight = 0.0
  elseif nAbsYaw > c_nHeadHoldEnd then
    local t = (nAbsYaw - c_nHeadHoldEnd) / (c_nHeadReturnEnd - c_nHeadHoldEnd)
    nWeight = 1.0 - t * t * (3.0 - 2.0 * t)
  end
  if nWeight <= 0 then
    return 0, 0, 0
  end
  local nRawYaw = Clamp(nRelYaw * c_nHeadYawGain, -c_nHeadYawMax, c_nHeadYawMax)
  local nDownMax = _bInWater == true and c_nHeadPitchSwimDownMax or c_nHeadPitchDownMax
  local nRawPitch = Clamp(nRelPitch * c_nHeadPitchGain, -c_nHeadPitchUpMax, nDownMax)
  return nRawYaw * nWeight, nRawPitch * nWeight, nWeight
end

-- Exact Cobra YPR rotation matching CameraUtils.RedoYPR & Quaternion.FromYawPitchRoll:
-- pitch around +X first (+pitch tilts +Z down toward -Y and +Y forward toward +Z), then yaw around +Y (+Z toward +X).
local RotateVecYPR = function(_nX, _nY, _nZ, _nYaw, _nPitch)
  local cp, sp = math.cos(_nPitch), math.sin(_nPitch)
  local cy, sy = math.cos(_nYaw), math.sin(_nYaw)
  local x1 = _nX
  local y1 = _nY * cp - _nZ * sp
  local z1 = _nY * sp + _nZ * cp
  return x1 * cy + z1 * sy, y1, -x1 * sy + z1 * cy
end

-- Computes local TransformQ rotating head-group meshes by (_nYaw, _nPitch) around avatar-local neck-seam pivot
-- (_nPx, _nPy, _nPz) with optional downward collar-tuck sink (_nSinkY) so the neckline rim stays tucked inside the torso.
Avatar.ComputePivotTransform = function(_nYaw, _nPitch, _nPx, _nPy, _nPz, _nSinkY)
  local qHead = Quaternion.FromYawPitchRoll(Vector3:new(_nYaw, _nPitch, 0))
  local rx, ry, rz = nil, nil, nil
  local trRot = TransformQ.FromOrPos(qHead, Vector3:new(0, 0, 0))
  if trRot ~= nil and trRot.ToWorldPos ~= nil then
    local bOk, vRot = pcall(trRot.ToWorldPos, trRot, Vector3:new(_nPx, _nPy, _nPz))
    if bOk and vRot ~= nil then
      local bC, x, y, z = pcall(function()
        return vRot.GetX and vRot:GetX() or vRot:X(),
          vRot.GetY and vRot:GetY() or vRot:Y(),
          vRot.GetZ and vRot:GetZ() or vRot:Z()
      end)
      if bC and type(x) == "number" and x == x then
        rx, ry, rz = x, y, z
      end
    end
  end
  if rx == nil then
    rx, ry, rz = RotateVecYPR(_nPx, _nPy, _nPz, _nYaw, _nPitch)
  end
  local nSink = type(_nSinkY) == "number" and _nSinkY or 0
  return TransformQ.FromOrPos(qHead, Vector3:new(_nPx - rx, _nPy - ry - nSink, _nPz - rz))
end

local ApplyHeadPartsTransform = function(_tAnim, _trLocal)
  if _tAnim == nil then
    return
  end
  local tWorld = WorldAPIs()
  local tr = tWorld and tWorld.transform
  if tr == nil or tr.SetTransform == nil then
    return
  end
  -- Primary path: rotate the dedicated HeadRig RenderGroup parent so GPU RenderGroupMember
  -- (UseGroupBackendEntry) renders Head, Hair, Beard, Glasses, and child Hat with the exact transform.
  if _tAnim.nHeadRig ~= nil then
    pcall(tr.SetTransform, tr, _tAnim.nHeadRig, _trLocal)
    return
  end
  local tParts = _tAnim.tHeadParts
  if type(tParts) ~= "table" or #tParts == 0 then
    return
  end
  for _, nPartID in ipairs(tParts) do
    pcall(tr.SetTransform, tr, nPartID, _trLocal)
  end
end

-- Hides/shows both the avatar root RenderGroup and the dedicated HeadRig RenderGroup together.
-- Cobra's model:SetHidden is reference-counted, so track bRootHidden & bHeadRigHidden to never double-call.
-- Respects _tAnim.bHeadHidden so unhiding the body in 1P keeps the head hidden.
Avatar.SetHidden = function(_tAnim, _nAvatarID, _bHidden)
  local tWorld = WorldAPIs()
  local model = tWorld and tWorld.model
  if model == nil or model.SetHidden == nil then
    return
  end
  local bHideRoot = _bHidden == true
  if _nAvatarID ~= nil then
    if _tAnim == nil or (_tAnim.bRootHidden == true) ~= bHideRoot then
      if _tAnim ~= nil then
        _tAnim.bRootHidden = bHideRoot
      end
      pcall(model.SetHidden, model, _nAvatarID, bHideRoot)
    end
  end
  local bHideHead = bHideRoot or (_tAnim ~= nil and _tAnim.bHeadHidden == true)
  if _tAnim ~= nil and (_tAnim.bHeadRigHidden == true) ~= bHideHead then
    _tAnim.bHeadRigHidden = bHideHead
    if _tAnim.nHeadRig ~= nil then
      pcall(model.SetHidden, model, _tAnim.nHeadRig, bHideHead)
    elseif type(_tAnim.tHeadParts) == "table" then
      for _, nPartID in ipairs(_tAnim.tHeadParts) do
        pcall(model.SetHidden, model, nPartID, bHideHead)
      end
    end
  end
  if _tAnim ~= nil and _tAnim.nLegsRig ~= nil and (_tAnim.bLegsRigHidden == true) ~= bHideRoot then
    _tAnim.bLegsRigHidden = bHideRoot
    pcall(model.SetHidden, model, _tAnim.nLegsRig, bHideRoot)
  end
end

-- Hides/shows ONLY the head-group RenderGroup (Head, Hat, Hair, Beard, Glasses) while keeping the body visible (1P view).
Avatar.SetHeadHidden = function(_tAnim, _nAvatarID, _bHidden)
  if _tAnim == nil then
    return
  end
  local bHide = _bHidden == true
  _tAnim.bHeadHidden = bHide
  local tWorld = WorldAPIs()
  local model = tWorld and tWorld.model
  if model == nil or model.SetHidden == nil then
    return
  end
  local bEffHide = bHide or (_tAnim.bRootHidden == true)
  if (_tAnim.bHeadRigHidden == true) == bEffHide then
    return
  end
  _tAnim.bHeadRigHidden = bEffHide
  if _tAnim.nHeadRig ~= nil then
    pcall(model.SetHidden, model, _tAnim.nHeadRig, bEffHide)
    return
  end
  if type(_tAnim.tHeadParts) == "table" then
    for _, nPartID in ipairs(_tAnim.tHeadParts) do
      pcall(model.SetHidden, model, nPartID, bEffHide)
    end
  end
end

local ReadLocalNeckPivot = function(_tAnim, _nAvatarID)
  local nNeck = _tAnim and _tAnim.nNeckAttach
  if nNeck ~= nil and _nAvatarID ~= nil then
    local bOk, px, py, pz = pcall(function()
      local tr = WorldAPIs().transform
      if tr == nil or tr.CalculateWorldTransform == nil then
        return nil
      end
      local trAvatar = tr:CalculateWorldTransform(_nAvatarID)
      local trNeck = tr:CalculateWorldTransform(nNeck)
      if trAvatar == nil or trNeck == nil or trAvatar.ToLocalPos == nil then
        return nil
      end
      local vNeckWorld = trNeck.GetPos and trNeck:GetPos() or (trNeck.Pos and trNeck:Pos())
      if vNeckWorld == nil then
        return nil
      end
      local vLocal = trAvatar:ToLocalPos(vNeckWorld)
      if vLocal == nil then
        return nil
      end
      local lx = vLocal.GetX and vLocal:GetX() or vLocal:X()
      local ly = vLocal.GetY and vLocal:GetY() or vLocal:Y()
      local lz = vLocal.GetZ and vLocal:GetZ() or vLocal:Z()
      if type(lx) == "number" and lx == lx and type(ly) == "number" and ly == ly and type(lz) == "number" and lz == lz and
        ly >= 0.15 and ly <= 2.2 and math.abs(lx) <= 0.8 and math.abs(lz) <= 0.8 then
        return lx, ly, lz
      end
      return nil
    end)
    if bOk and px ~= nil then
      return px, py, pz, true
    end
  end
  return c_tFallbackNeckPivot[1], c_tFallbackNeckPivot[2], c_tFallbackNeckPivot[3], false
end

Avatar.GetLocalNeckPivot = ReadLocalNeckPivot

Avatar.ResetHeadLook = function(_tAnim)
  if _tAnim == nil then
    return
  end
  _tAnim.nHeadYaw, _tAnim.nHeadYawVel = 0, 0
  _tAnim.nHeadPitch, _tAnim.nHeadPitchVel = 0, 0
  if not _tAnim.bHeadNeutral then
    _tAnim.bHeadNeutral = true
    ApplyHeadPartsTransform(_tAnim, TransformQ.Identity)
  end
end

-- Exact analytical critically damped spring (unconditionally stable at any dt / framerate, zero overshoot).
local StepDampedSpring = function(_nVal, _nVel, _nTarget, _nOmega, _nDt)
  local nDiff = _nVal - _nTarget
  local nB = _nVel + _nOmega * nDiff
  local nExp = math.exp(-_nOmega * _nDt)
  return _nTarget + (nDiff + nB * _nDt) * nExp, (_nVel - nB * _nOmega * _nDt) * nExp
end

-- Smoothly rotates the HeadRig RenderGroup (Head [+ child Hat], Hair, Beard, Glasses) to follow camera look.
Avatar.UpdateHeadLook = function(_tAnim, _nAvatarID, _nCamYaw, _nCamPitch, _nBodyYaw, _nBodyPitch, _nDt, _bInWater, _bSeated)
  if _tAnim == nil or not _tAnim.bAnimated or _nAvatarID == nil or
    (_tAnim.nHeadRig == nil and (type(_tAnim.tHeadParts) ~= "table" or #_tAnim.tHeadParts == 0)) then
    return 0, 0
  end
  local nDt = (type(_nDt) == "number" and _nDt > 0) and math.min(_nDt, 0.1) or (1 / 60)
  -- Keep live CPU neck bone transform updated each frame when using BakedAnimation.
  if _tAnim.nNeckAttach ~= nil then
    pcall(function()
      local baked = WorldAPIs().bakedanimation
      if baked ~= nil and baked.RequestAllBonesForCalculate ~= nil then
        baked:RequestAllBonesForCalculate(_nAvatarID)
      end
    end)
  end
  local bSuppress = _tAnim.bOneShotActive == true or (_tAnim.sOverrideSuffix ~= nil and _bSeated ~= true)
  local nRelYaw = (type(_nCamYaw) == "number" and type(_nBodyYaw) == "number") and WrapAngle(_nCamYaw - _nBodyYaw) or 0
  local nRelPitch = (type(_nCamPitch) == "number" and _nCamPitch == _nCamPitch and _nCamPitch or 0) -
    (type(_nBodyPitch) == "number" and _nBodyPitch == _nBodyPitch and _nBodyPitch or 0)
  local nTargetYaw, nTargetPitch = Avatar.ComputeHeadLookTarget(nRelYaw, nRelPitch, _bInWater == true, bSuppress)
  _tAnim.nHeadYaw, _tAnim.nHeadYawVel = StepDampedSpring(_tAnim.nHeadYaw or 0, _tAnim.nHeadYawVel or 0, nTargetYaw, c_nHeadSpringOmega, nDt)
  _tAnim.nHeadPitch, _tAnim.nHeadPitchVel = StepDampedSpring(_tAnim.nHeadPitch or 0, _tAnim.nHeadPitchVel or 0, nTargetPitch, c_nHeadSpringOmega, nDt)

  local bSettledNeutral = math.abs(_tAnim.nHeadYaw) < c_nHeadNeutralEps and math.abs(_tAnim.nHeadPitch) < c_nHeadNeutralEps and
    math.abs(nTargetYaw) < c_nHeadNeutralEps and math.abs(nTargetPitch) < c_nHeadNeutralEps
  if bSettledNeutral then
    _tAnim.nHeadYaw, _tAnim.nHeadYawVel = 0, 0
    _tAnim.nHeadPitch, _tAnim.nHeadPitchVel = 0, 0
    if not _tAnim.bHeadNeutral then
      _tAnim.bHeadNeutral = true
      ApplyHeadPartsTransform(_tAnim, TransformQ.Identity)
    end
    return 0, 0
  end

  _tAnim.bHeadNeutral = false
  local px, py, pz = ReadLocalNeckPivot(_tAnim, _nAvatarID)
  -- Pivot right at the bottom collar seam (4.5 cm below def_c_neck1_joint) and tuck slightly down into the
  -- torso collar as pitch/yaw increase (0 cm at neutral) so the hollow torso interior never shows through.
  local nSeamY = py - c_nNeckSeamDrop
  local nSinkY = c_nCollarTuckPitch * math.sin(math.abs(_tAnim.nHeadPitch)) +
    c_nCollarTuckYaw * (1.0 - math.cos(_tAnim.nHeadYaw))
  local trHead = Avatar.ComputePivotTransform(_tAnim.nHeadYaw, _tAnim.nHeadPitch, px, nSeamY, pz, nSinkY)
  ApplyHeadPartsTransform(_tAnim, trHead)
  return _tAnim.nHeadYaw, _tAnim.nHeadPitch
end

local ApplyLegsTransform = function(_tAnim, _trLocal)
  if _tAnim == nil or _tAnim.nLegsRig == nil then
    return
  end
  local tWorld = WorldAPIs()
  local tr = tWorld and tWorld.transform
  if tr == nil or tr.SetTransform == nil then
    return
  end
  pcall(tr.SetTransform, tr, _tAnim.nLegsRig, _trLocal)
end

-- Computes target lower-body yaw twist (radians) and whether to play the stride clip in reverse
-- from the body-relative horizontal movement angle (_nRelMoveAngle, 0 = forward, +/-pi/2 = strafe, +/-pi = backward).
Avatar.ComputeLegsTwistTarget = function(_nRelMoveAngle, _nSpeed, _bEnable)
  if _bEnable ~= true or type(_nRelMoveAngle) ~= "number" or _nRelMoveAngle ~= _nRelMoveAngle or
    type(_nSpeed) ~= "number" or _nSpeed < c_nWalkExit then
    return 0, false
  end
  local nRel = WrapAngle(_nRelMoveAngle)
  if math.abs(nRel) > c_nLegsBackThreshold then
    local nBackAngle = WrapAngle(nRel + math.pi)
    return Clamp(nBackAngle, -c_nLegsTwistMax, c_nLegsTwistMax), true
  end
  return Clamp(nRel, -c_nLegsTwistMax, c_nLegsTwistMax), false
end

Avatar.ResetLegsTwist = function(_tAnim)
  if _tAnim == nil then
    return
  end
  _tAnim.nLegsYaw, _tAnim.nLegsYawVel = 0, 0
  if not _tAnim.bLegsNeutral then
    _tAnim.bLegsNeutral = true
    ApplyLegsTransform(_tAnim, TransformQ.Identity)
  end
end

-- Smoothly twists the dedicated LegsRig RenderGroup into the strafe/diagonal travel direction in 1P
-- while keeping the Torso aligned with the camera. Returns (nLegsYaw, bReverseStride).
Avatar.UpdateLegsTwist = function(_tAnim, _nRelMoveAngle, _nSpeed, _nDt, _bEnable)
  if _tAnim == nil or not _tAnim.bAnimated or _tAnim.nLegsRig == nil then
    local _, bRev = Avatar.ComputeLegsTwistTarget(_nRelMoveAngle, _nSpeed, _bEnable)
    return 0, bRev
  end
  local nDt = (type(_nDt) == "number" and _nDt > 0) and math.min(_nDt, 0.1) or (1 / 60)
  local bActive = _bEnable == true and _tAnim.sOverrideSuffix == nil and _tAnim.bOneShotActive ~= true
  local nTargetYaw, bReverse = Avatar.ComputeLegsTwistTarget(_nRelMoveAngle, _nSpeed, bActive)
  _tAnim.nLegsYaw, _tAnim.nLegsYawVel = StepDampedSpring(_tAnim.nLegsYaw or 0, _tAnim.nLegsYawVel or 0,
    nTargetYaw, c_nLegsSpringOmega, nDt)
  local bSettledNeutral = math.abs(_tAnim.nLegsYaw) < c_nLegsNeutralEps and math.abs(nTargetYaw) < c_nLegsNeutralEps
  if bSettledNeutral then
    _tAnim.nLegsYaw, _tAnim.nLegsYawVel = 0, 0
    if not _tAnim.bLegsNeutral then
      _tAnim.bLegsNeutral = true
      ApplyLegsTransform(_tAnim, TransformQ.Identity)
    end
    return 0, bReverse
  end
  _tAnim.bLegsNeutral = false
  local trLegs = TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(Vector3:new(_tAnim.nLegsYaw, 0, 0)),
    Vector3:new(0, 0, 0))
  ApplyLegsTransform(_tAnim, trLegs)
  return _tAnim.nLegsYaw, bReverse
end

-- Attaches a whitelisted prop prefab (from Main_SmallResources.ovl) onto the avatar's hand bone.
-- Vanilla prop prefabs (umbrella_blue, fad_coffeecup, fad_burger, shoppingbag, mch_novelty_balloon_giraffe, ...)
-- already include their own BoneTransform with AnimEntity = "../.." (grandparent = avatar with ModelSkeleton).
-- Spawning a plain identity Transform wrapper with the prop as its child matches the exact vanilla hierarchy in
-- one atomic InstantiatePrefab call with zero double-transform offset (never wrap in AttachPoint!).
Avatar.DetachProp = function(_tAnim)
  if _tAnim == nil or _tAnim.tProp == nil then
    return
  end
  local tP = _tAnim.tProp
  _tAnim.tProp = nil
  if tP.nWrapperId ~= nil then
    pcall(api.entity.DestroyEntity, tP.nWrapperId)
  end
end

Avatar.AttachProp = function(_tAnim, _nAvatarID, _sPrefab, _sBoneName)
  if _tAnim == nil or _nAvatarID == nil or type(_sPrefab) ~= "string" or _sPrefab == "" then
    return false
  end
  local sBone = (_sBoneName == "def_l_attach_joint") and "def_l_attach_joint" or "def_r_attach_joint"
  if _tAnim.tProp ~= nil and _tAnim.tProp.sPrefab == _sPrefab and _tAnim.tProp.sBone == sBone then
    return true
  end
  Avatar.DetachProp(_tAnim)
  local bOk, nWrapperId = pcall(function()
    local tok = api.entity.CreateRequestCompletionToken()
    local tWrapper = {
      Components = {Transform = {}},
      Children = {
        Prop = {Prefab = _sPrefab},
      },
    }
    local nId = api.entity.InstantiatePrefab(tWrapper, "PZ2CoopHeldProp", tok, TransformQ.Identity, _nAvatarID, true, nil)
    local tWorld = WorldAPIs()
    if nId ~= nil and tWorld.bakedanimation and tWorld.bakedanimation.RequestAllBonesForCalculate then
      tWorld.bakedanimation:RequestAllBonesForCalculate(_nAvatarID)
    end
    return nId
  end)
  if bOk and nWrapperId ~= nil then
    _tAnim.tProp = {nWrapperId = nWrapperId, sPrefab = _sPrefab, sBone = sBone}
    return true
  end
  return false
end

local TargetPlaybackRate = function(_sState, _nSmoothSpeed)
  if _sState == "swim" then
    -- Gentle treading while still (~0.85x), vigorous swimming strokes while moving through water (up to 1.42x).
    return math.max(0.85, math.min(c_nRateMax, 0.85 + _nSmoothSpeed * 0.22))
  end
  local nRef = c_tRefSpeed[_sState]
  if nRef ~= nil and nRef > 0 then
    return math.max(c_nRateMin, math.min(c_nRateMax, _nSmoothSpeed / nRef))
  end
  return 1.0
end

local ResolveDesiredClip = function(_tAnim, _sState)
  if _tAnim.sOverrideSuffix ~= nil then
    return _tAnim.sGroup .. _tAnim.sOverrideSuffix
  end
  if _sState == "idle" then
    if _tAnim.nTiredRemain > 0 then
      local idx = ((_tAnim.nIdleVariantIdx - 1) % #c_tTiredVariants) + 1
      return _tAnim.sGroup .. c_tTiredVariants[idx]
    end
    local sW = c_tWeatherIdle[_tAnim.sWeather]
    if sW ~= nil then
      return _tAnim.sGroup .. sW
    end
    return _tAnim.sGroup .. c_tIdleVariants[_tAnim.nIdleVariantIdx]
  elseif _sState == "walk" then
    local sW = c_tWeatherWalk[_tAnim.sWeather]
    if sW ~= nil then
      return _tAnim.sGroup .. sW
    end
    return _tAnim.sGroup .. c_tWalkVariants[_tAnim.nWalkVariantIdx]
  end
  return Avatar.GetClipName(_tAnim.sGroup, _sState)
end

-- Advances smoothed speed, selects gait/swim/weather/fatigue/idle-variety clip with asymmetric crossfade & stride rate.
Avatar.UpdateAnimation = function(_tAnim, _nAvatarID, _nSpeed, _nDt, _bInWater, _sWeather, _bIsRemote, _bReverse)
  if _tAnim == nil or not _tAnim.bAnimated or _nAvatarID == nil then
    return
  end
  local nDt = type(_nDt) == "number" and _nDt > 0 and _nDt or (1 / 60)
  _tAnim.nClock = (_tAnim.nClock or 0) + nDt
  if type(_sWeather) == "string" then
    _tAnim.sWeather = _sWeather
  end

  -- Keep CPU hand-bone transforms synced every frame while a prop is attached.
  if _tAnim.tProp ~= nil then
    pcall(function()
      local baked = WorldAPIs().bakedanimation
      if baked ~= nil and baked.RequestAllBonesForCalculate ~= nil then
        baked:RequestAllBonesForCalculate(_nAvatarID)
      end
    end)
  end

  local nRawSpeed = (type(_nSpeed) == "number" and _nSpeed == _nSpeed and _nSpeed >= 0) and _nSpeed or 0
  if nRawSpeed > c_nMaxValidSpeed then
    nRawSpeed = 0
  end
  _tAnim.nPrevSmoothSpeed = _tAnim.nSmoothSpeed
  if nRawSpeed < c_nWalkExit then
    _tAnim.nStopTime = (_tAnim.nStopTime or 0) + nDt
  else
    _tAnim.nStopTime = 0
  end
  -- Asymmetric GTA-style momentum smoothing: progressive acceleration, snappy local stop, jitter-tolerant remote stop.
  local nDecelRate = _bIsRemote == true and c_nRemoteDecelSmoothRate or c_nDecelSmoothRate
  local nStopDelay = _bIsRemote == true and c_nRemoteStopSnapDelay or c_nStopSnapDelay
  local nSmoothRate = (nRawSpeed > _tAnim.nSmoothSpeed) and c_nAccelSmoothRate or nDecelRate
  local k = 1 - math.exp(-nSmoothRate * nDt)
  _tAnim.nSmoothSpeed = _tAnim.nSmoothSpeed + (nRawSpeed - _tAnim.nSmoothSpeed) * k
  if _tAnim.nStopTime >= nStopDelay or _tAnim.nSmoothSpeed < 0.01 then
    _tAnim.nSmoothSpeed = 0
  end

  -- Auto-expire one-shot flag once clip completes so standing still after a gate/fidget never pins head-look off.
  if _tAnim.bOneShotActive and _tAnim.nOneShotUntil ~= nil and _tAnim.nOneShotUntil > 0 and
    _tAnim.nClock >= _tAnim.nOneShotUntil then
    _tAnim.bOneShotActive = false
    _tAnim.nOneShotUntil = 0
  end

  -- Instant move-cancel for stationary one-shot fidgets/emotes when the character starts moving.
  if _tAnim.bOneShotActive and (_tAnim.nSmoothSpeed >= c_nWalkEnter or nRawSpeed >= c_nWalkEnter) and _tAnim.sOverrideSuffix == nil then
    Avatar.CancelOneShot(_tAnim, _nAvatarID)
  end

  local sPrevState = _tAnim.sState
  local sNextState = Avatar.PickState(sPrevState, _tAnim.nSmoothSpeed, _bInWater == true)
  -- Never play JogBase or RunBase in reverse: cap backwards locomotion cleanly to WalkBase.
  if _bReverse == true and (sNextState == "jog" or sNextState == "run") then
    sNextState = "walk"
  end

  -- Track sprint duration for post-sprint fatigue, idle variety cycling, bored fidgets, and walk variety.
  if sNextState == "run" then
    _tAnim.nSprintAccum = (_tAnim.nSprintAccum or 0) + nDt
    if _tAnim.nSprintAccum >= c_nSprintFatigueThreshold then
      _tAnim.bSprintFatigueArmed = true
    end
    _tAnim.nTiredRemain = 0
  elseif sNextState == "idle" then
    if _tAnim.bSprintFatigueArmed then
      _tAnim.bSprintFatigueArmed = false
      _tAnim.nTiredRemain = c_nTiredDuration
    end
    _tAnim.nSprintAccum = 0
    if _tAnim.nTiredRemain > 0 then
      _tAnim.nTiredRemain = math.max(0, _tAnim.nTiredRemain - nDt)
    end
  else
    _tAnim.nSprintAccum = math.max(0, (_tAnim.nSprintAccum or 0) - nDt * 2.0)
    _tAnim.nTiredRemain = 0
  end

  if sNextState == "idle" and _tAnim.sOverrideSuffix == nil then
    _tAnim.nIdleTimer = (_tAnim.nIdleTimer or 0) + nDt
    _tAnim.nStationaryTime = (_tAnim.nStationaryTime or 0) + nDt
    if _tAnim.nIdleTimer >= (_tAnim.nNextIdleSwap or c_nIdleCycleMin) then
      _tAnim.nIdleTimer = 0
      _tAnim.nIdleVariantIdx = (_tAnim.nIdleVariantIdx % #c_tIdleVariants) + 1
      _tAnim.nNextIdleSwap = c_nIdleCycleMin + ((_tAnim.nIdleVariantIdx * 2.3) % (c_nIdleCycleMax - c_nIdleCycleMin))
    end
    if _tAnim.nTiredRemain <= 0 and _tAnim.sWeather == "clear" and
      _tAnim.nStationaryTime >= (_tAnim.nNextFidget or c_nFidgetMin) then
      _tAnim.nStationaryTime = 0
      local sFidget = c_tBoredFidgets[_tAnim.nFidgetIdx]
      _tAnim.nFidgetIdx = (_tAnim.nFidgetIdx % #c_tBoredFidgets) + 1
      _tAnim.nNextFidget = c_nFidgetMin + ((_tAnim.nFidgetIdx * 4.7) % (c_nFidgetMax - c_nFidgetMin))
      Avatar.PlayOneShot(_tAnim, _nAvatarID, sFidget)
    end
  else
    _tAnim.nIdleTimer = 0
    _tAnim.nStationaryTime = 0
  end

  if sNextState == "walk" and _tAnim.sOverrideSuffix == nil then
    _tAnim.nWalkTimer = (_tAnim.nWalkTimer or 0) + nDt
    if _tAnim.nWalkTimer >= c_nWalkCycleInterval then
      _tAnim.nWalkTimer = 0
      _tAnim.nWalkVariantIdx = (_tAnim.nWalkVariantIdx % #c_tWalkVariants) + 1
    end
  else
    _tAnim.nWalkTimer = 0
    _tAnim.nWalkVariantIdx = 1
  end

  local sTargetClip = ResolveDesiredClip(_tAnim, sNextState)
  local nTargetRate = _tAnim.sOverrideSuffix ~= nil and 1.0 or TargetPlaybackRate(sNextState, _tAnim.nSmoothSpeed)
  if c_bAllowReversePlayback and _bReverse == true and _tAnim.sOverrideSuffix == nil and
    sNextState ~= "idle" and sNextState ~= "swim" then
    nTargetRate = -nTargetRate
  end

  if sNextState ~= sPrevState or sTargetClip ~= _tAnim.sClip then
    local nBlend = _tAnim.sOverrideSuffix ~= nil and c_nBlendOverride or Avatar.PickBlendTime(sPrevState, sNextState)
    local bOk, sErr = ApplyBaseAnimation(_nAvatarID, sTargetClip, nTargetRate, nBlend)
    if bOk then
      _tAnim.sState = sNextState
      _tAnim.sClip = sTargetClip
      _tAnim.nRate = nTargetRate
    elseif not _tAnim.bErrorLogged then
      _tAnim.bErrorLogged = true
      Log("SetBaseAnimation(" .. tostring(sTargetClip) .. ") failed: " .. tostring(sErr))
    end
  elseif math.abs(nTargetRate - _tAnim.nRate) >= c_nRateEpsilon then
    if ApplyPlaybackRate(_nAvatarID, nTargetRate) then
      _tAnim.nRate = nTargetRate
    end
  end
end

-- Resets speed smoothing to idle (e.g. after a teleport or when hiding/re-showing the avatar).
Avatar.ResetAnimSpeed = function(_tAnim, _nAvatarID)
  if _tAnim == nil then
    return
  end
  _tAnim.nSmoothSpeed = 0
  _tAnim.nPrevSmoothSpeed = 0
  _tAnim.nStopTime = 0
  _tAnim.nSprintAccum = 0
  _tAnim.nTiredRemain = 0
  _tAnim.nRoll, _tAnim.nRollVel = 0, 0
  _tAnim.nPitch, _tAnim.nPitchVel = 0, 0
  Avatar.ResetHeadLook(_tAnim)
  Avatar.ResetLegsTwist(_tAnim)
  if _tAnim.bAnimated and _nAvatarID ~= nil and _tAnim.sOverrideSuffix == nil and _tAnim.sState ~= "idle" then
    local sClip = Avatar.GetClipName(_tAnim.sGroup, "idle")
    if ApplyBaseAnimation(_nAvatarID, sClip, 1.0, c_nBlendStop) then
      _tAnim.sState = "idle"
      _tAnim.sClip = sClip
      _tAnim.nRate = 1.0
    end
  end
end

-- Splits flat multipart2 properties ("Part/Prop" -> tPartProps[Part][Prop]) and applies hair/hat fixups.
local SplitMultipartProps = function(_tAvatar, _tProps)
  local bNeedToHideHair = false
  if _tAvatar.items and _tAvatar.items.Hats and api.playeravatar and api.playeravatar.GetHatHairForAvatarHairModel then
    local sHairModel = _tProps["Hair/ModelName"]
    if type(sHairModel) == "string" and sHairModel ~= "" then
      local bOk, sHatHair = pcall(api.playeravatar.GetHatHairForAvatarHairModel, sHairModel)
      if bOk and type(sHatHair) == "string" and sHatHair ~= "" then
        _tProps["Hair/ModelName"] = sHatHair
      elseif bOk then
        bNeedToHideHair = true
      end
    end
  end

  local tByPart = {}
  for sKey, value in pairs(_tProps) do
    local nSlash = string.find(sKey, "/", 1, true)
    if nSlash and nSlash > 1 and nSlash < #sKey then
      local sPart = string.sub(sKey, 1, nSlash - 1)
      local sProp = string.sub(sKey, nSlash + 1)
      if tByPart[sPart] == nil then
        tByPart[sPart] = {}
      end
      tByPart[sPart][sProp] = value
    end
  end

  -- Match vanilla StartScreenAvatar: mirror Hair/Slot* colours onto Head when present.
  if tByPart.Head ~= nil and tByPart.Hair ~= nil then
    for sProp, value in pairs(tByPart.Hair) do
      if string.sub(sProp, 1, 4) == "Slot" then
        tByPart.Head[sProp] = value
      end
    end
  end

  return tByPart, bNeedToHideHair
end

-- Builds a clean Lua prefab table for the animated avatar root (BakedAnimation + AnimationControl, no crowd/MotionGraph).
Avatar.BuildRootPrefab = function(_sSkeletonName, _sDefaultAnim)
  return {
    Components = {
      Transform = {},
      AssetPackageLoader = {PackageNames = {"CharacterPatterns", "Guests"}},
      AssetPackageProvider = {},
      ModelSkeleton = {ModelName = _sSkeletonName},
      BakedAnimation = {AnimName = _sDefaultAnim},
      AnimationControl = {BaseAnimName = _sDefaultAnim, BasePlaybackRate = 1.0},
      LevelOfDetail = {},
      RenderBoundingVolume = {LocalCentre = Vector3:new(0, 1, 0)},
      RenderGroup = {LodGroupName = "Characters"},
    },
  }
end

-- Builds a dedicated child RenderGroup entity for head-group PeepBodyParts (Head, Hair, Beard, Glasses, Hat).
-- Because PeepBodyPart sets RenderGroupMember.TransformFlags={"UseGroupBackendEntry"}, parenting head parts under
-- this RenderGroup ensures SetTransform(nHeadRigID, trHead) directly rotates their GPU render matrix while
-- AnimationProxy (AnimationEntity="../..") continues skinning from the avatar root's BakedAnimation.
Avatar.BuildHeadRigPrefab = function()
  return {
    Components = {
      Transform = {},
      AssetPackageProvider = {LoaderPath = ".."},
      LevelOfDetail = {},
      RenderBoundingVolume = {LocalCentre = Vector3:new(0, 1.5, 0)},
      RenderGroup = {LodGroupName = "Characters"},
    },
  }
end

-- Dedicated child RenderGroup for the Legs PeepBodyPart so 1P strafing/diagonals twist lower-body yaw independently
-- of Torso while AnimationProxy (AnimationEntity="../..") continues skinning from the avatar root's BakedAnimation.
Avatar.BuildLegsRigPrefab = function()
  return {
    Components = {
      Transform = {},
      AssetPackageProvider = {LoaderPath = ".."},
      LevelOfDetail = {},
      RenderBoundingVolume = {LocalCentre = Vector3:new(0, 0.5, 0)},
      RenderGroup = {LodGroupName = "Characters"},
    },
  }
end

local WaitToken = function(_token)
  while not api.entity.HaveRequestsCompleted(_token) do
    coroutine.yield()
  end
end

-- Coroutine worker: builds a native animated avatar under _nParentID using Guests.ovl baked clips.
-- Returns (nAvatarID, bAnimated). Falls back cleanly to StartScreenAvatar ("Static") if needed.
Avatar.CreateAnimated = function(_tAvatar, _nParentID, _sRole, _sInitialClipSuffix)
  local sPrefix = Avatar.GroupPrefix(_tAvatar.group)
  local sDefaultAnim = (type(_sInitialClipSuffix) == "string" and _sInitialClipSuffix ~= "")
    and (sPrefix .. _sInitialClipSuffix) or Avatar.GetClipName(sPrefix, "idle")

  local bHasControl = api.animationcontrol ~= nil and api.animationcontrol.SetBaseAnimation ~= nil
  local bGotProps, sPrefab, tProps = false, nil, nil
  if bHasControl and api.multipart2 ~= nil and api.multipart2.GetProperties ~= nil then
    bGotProps, sPrefab, tProps = pcall(api.multipart2.GetProperties, _tAvatar)
  end
  if bHasControl and bGotProps and type(tProps) == "table" and type(tProps.SkeletonName) == "string" and tProps.SkeletonName ~= "" then
    local tRootPrefab = Avatar.BuildRootPrefab(tProps.SkeletonName, sDefaultAnim)
    local token = api.entity.CreateRequestCompletionToken()
    local bRootOk, nAvatarID = pcall(api.entity.InstantiatePrefab, tRootPrefab, "Avatar", token,
      TransformQ.FromOrPos(Quaternion.Identity, Vector3:new(0, -1000, 0)), _nParentID, true, nil)
    if bRootOk and nAvatarID ~= nil then
      local tWorld = WorldAPIs()
      pcall(tWorld.model.SetHidden, tWorld.model, nAvatarID, true)
      WaitToken(token)

      local tByPart, bNeedToHideHair = SplitMultipartProps(_tAvatar, tProps)
      local nHeadID = nil
      local nHairID = nil
      local tHeadParts = {}
      local nPartsSpawned = 0

      -- Spawn dedicated HeadRig and LegsRig RenderGroup children under nAvatarID so head & legs obey SetTransform on GPU.
      local nHeadRigID = nil
      local headRigToken = api.entity.CreateRequestCompletionToken()
      local bRigOk, nRigId = pcall(api.entity.InstantiatePrefab, Avatar.BuildHeadRigPrefab(), "PZ2CoopHeadRig",
        headRigToken, TransformQ.Identity, nAvatarID, true, nil)
      if bRigOk and nRigId ~= nil then
        nHeadRigID = nRigId
        pcall(tWorld.model.SetHidden, tWorld.model, nHeadRigID, true)
        WaitToken(headRigToken)
      else
        Log(_sRole .. " HeadRig spawn failed: " .. tostring(nRigId))
      end

      local nLegsRigID = nil
      local legsRigToken = api.entity.CreateRequestCompletionToken()
      local bLegsOk, nLegsId = pcall(api.entity.InstantiatePrefab, Avatar.BuildLegsRigPrefab(), "PZ2CoopLegsRig",
        legsRigToken, TransformQ.Identity, nAvatarID, true, nil)
      if bLegsOk and nLegsId ~= nil then
        nLegsRigID = nLegsId
        pcall(tWorld.model.SetHidden, tWorld.model, nLegsRigID, true)
        WaitToken(legsRigToken)
      else
        Log(_sRole .. " LegsRig spawn failed: " .. tostring(nLegsId))
      end

      local partsToken = api.entity.CreateRequestCompletionToken()

      for _, sPartName in ipairs(c_tPartOrder) do
        local tPartProps = tByPart[sPartName]
        if tPartProps ~= nil and type(tPartProps.ModelName) == "string" and tPartProps.ModelName ~= "" then
          local bHeadPart = IsHeadLookPart(sPartName, tPartProps.ModelName)
          local bLegsPart = (not bHeadPart) and sPartName == "Legs"
          local nPartParent = nAvatarID
          if bHeadPart and nHeadRigID ~= nil then
            nPartParent = nHeadRigID
          elseif bLegsPart and nLegsRigID ~= nil then
            nPartParent = nLegsRigID
          end
          local tPartComponents = {
            Model = {BoundingScaler = c_tPartScaler[sPartName] or 10},
          }
          if nPartParent ~= nAvatarID then
            tPartComponents.AnimationProxy = {AnimationEntity = "../.."}
            tPartComponents.AssetPackageProvider = {LoaderPath = "../.."}
          end
          local tPartPrefab = {
            Prefab = "PeepBodyPart",
            Components = tPartComponents,
          }
          local bPartOk, nPartID = pcall(api.entity.InstantiatePrefab, tPartPrefab, sPartName, partsToken, nil,
            nPartParent, true, tPartProps)
          if bPartOk and nPartID ~= nil then
            nPartsSpawned = nPartsSpawned + 1
            if bHeadPart then
              table.insert(tHeadParts, nPartID)
            end
            if sPartName == "Head" then
              nHeadID = nPartID
            elseif sPartName == "Hair" then
              nHairID = nPartID
            end
          else
            Log(_sRole .. " part " .. sPartName .. " spawn failed: " .. tostring(nPartID))
          end
        end
      end

      if nPartsSpawned > 0 then
        local nNeckAttach = nil
        local bNeckOk, nNeckID = pcall(api.entity.InstantiatePrefab, "AttachPoint", "PZ2CoopNeckPivot", partsToken,
          nil, nAvatarID, true, {AttachBone = "def_c_neck1_joint"})
        if bNeckOk and nNeckID ~= nil then
          nNeckAttach = nNeckID
        end
        WaitToken(partsToken)
        if _tAvatar.items and _tAvatar.items.Hats and type(_tAvatar.items.Hats.prefab) == "string" and nHeadID ~= nil then
          local hatToken = api.entity.CreateRequestCompletionToken()
          local tHatPrefab = {
            Prefab = _tAvatar.items.Hats.prefab,
            Components = {
              ViewFilter = {ShadowCascade0 = true, ShadowCascade1 = true, ShadowCascade2 = true,
                ShadowCascade3 = true, ShadowCascade4to7 = true},
            },
          }
          pcall(api.entity.InstantiatePrefab, tHatPrefab, "Hat", hatToken, nil, nHeadID, nil, nil)
          WaitToken(hatToken)
          if bNeedToHideHair and nHairID ~= nil then
            pcall(tWorld.model.SetHidden, tWorld.model, nHairID, true)
          end
        end
        pcall(tWorld.transform.SetPosition, tWorld.transform, nAvatarID, Vector3:new(0, 0, 0))
        pcall(tWorld.model.SetHidden, tWorld.model, nAvatarID, false)
        if nHeadRigID ~= nil then
          pcall(tWorld.model.SetHidden, tWorld.model, nHeadRigID, false)
        end
        if nLegsRigID ~= nil then
          pcall(tWorld.model.SetHidden, tWorld.model, nLegsRigID, false)
        end
        Log(string.format("%s animated avatar ready (id=%s, headRig=%s, legsRig=%s, group=%s, parts=%d, headParts=%d, clip=%s, base=%s)",
          tostring(_sRole), tostring(nAvatarID), tostring(nHeadRigID), tostring(nLegsRigID), sPrefix, nPartsSpawned, #tHeadParts, sDefaultAnim, tostring(sPrefab)))
        return nAvatarID, true, {nHeadRig = nHeadRigID, nLegsRig = nLegsRigID, tHeadParts = tHeadParts, nNeckAttach = nNeckAttach}
      else
        Log(_sRole .. " animated avatar spawned 0 parts; falling back to StartScreenAvatar")
        pcall(api.entity.DestroyEntity, nAvatarID)
      end
    else
      Log(_sRole .. " animated root spawn failed: " .. tostring(nAvatarID) .. "; falling back to StartScreenAvatar")
    end
  else
    Log(string.format("%s animated avatar skipped (control=%s props=%s skel=%s); using StartScreenAvatar",
      tostring(_sRole), tostring(bHasControl), tostring(bGotProps),
      tostring(type(tProps) == "table" and tProps.SkeletonName or nil)))
  end

  -- Safe fallback: vanilla StartScreenAvatar ("Static") recipe (proven in retail parks).
  local bSSOk, StartScreenAvatar = pcall(require, "StartScreen.Shared.StartScreenAvatar")
  if not bSSOk or type(StartScreenAvatar) ~= "table" then
    error("StartScreenAvatar unavailable")
  end
  local oAvatar = StartScreenAvatar:new()
  oAvatar:Create(_tAvatar, _nParentID, _sRole, "Static")
  local nFallbackID = oAvatar.nAnimatedEntityID
  if nFallbackID ~= nil then
    local nLights = api.entity.FindEntityByName("Lights", nFallbackID)
    if nLights then
      api.entity.DestroyEntity(nLights)
    end
  end
  return nFallbackID, false
end
