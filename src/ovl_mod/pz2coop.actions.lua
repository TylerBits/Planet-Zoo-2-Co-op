-- Player NPC activities, Radial Emote Wheel, world object interactions, and carried props.
--   Pillar A: 3-page x 8-wedge Radial Emote Wheel (Social, Reactions, Props) triggered on foot via B / L3.
--   Pillar B: Proximity world interactions (Benches w/ 2 co-op seats, Picnic/Restaurant tables, Photo Boards,
--             Education Stations, Shops/Kiosks, Vending Machines, ATMs, Trash Bins, Restrooms, Donation Boxes,
--             Exhibit/Aquarium/Aviary reactions, Viewing Domes, Transport Rides) with native floating tooltip.
--   Pillar C: Hand-bone prop attachment (Main_SmallResources.ovl), balloon pop gag, and playful PickedUp
--             Go-to-Friend arrival.
--   Sync:     Reliable JSON packet 0x12 with k = "action". Strict local whitelists — peer packets NEVER pass
--             raw clip or prefab strings to the engine. Late-joiners receive persistent prop/seat state on connect.
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
local rawget = global.rawget
local rawset = global.rawset
local require = global.require
local Vector3 = require("Vector3")
local TransformQ = require("TransformQ")
local Quaternion = require("Quaternion")
local Bridge = require("PZ2Coop.Bridge")
local Avatar = require("PZ2Coop.Avatar")
local Presence = require("PZ2Coop.Presence")

local Actions = module(...)

local c_nActionPacket = 0x12
local c_nScanInterval = 0.15 -- proximity scanner
local c_nScanRadiusM = 3.4 -- spatial query radius covering standard props + wide transport/ride gates
local c_nDoorAnimDur = 0.40 -- seconds to smoothly swing/slide modular scenery doors open or closed
local c_nExhibitScanRadiusM = 3.2 -- idle exhibit viewing radius (never shows a hover popup)
local c_nExhibitIdleDelay = 4.5 -- seconds standing completely idle near an exhibit before smoothly watching it
local c_nExhibitBlendIn = 0.45 -- smooth crossfade into exhibit watching idle
local c_nExhibitBlendOut = 0.16 -- snappy crossfade out when moving away
local c_nBenchSeatOffsetM = 0.45
local c_nPicnicBenchDepthM = 0.72
local c_nSeatEntryOffsetM = 0.44
local c_nPicnicEntryOffsetM = 0.50
local c_nStandEyeHeight = 1.55
local c_nApproachWalkSpeed = 1.75 -- m/s natural NPC walk-up pace to chairs/benches
local c_nApproachTurnRate = 10.0 -- rad/s facing walk direction while approaching
local c_nAlignTurnRate = 8.5 -- rad/s turning in place to align with seat facing before sitting down
local c_nApproachTimeout = 3.0
local c_nTeenSitIdleSwap = 8.5 -- cycle SitBenchIdle01 <-> SitBenchIdle02 on teens while seated

-- Per-kind close proximity thresholds (horizontal metres from avatar feet to nearest interaction/seat point).
local c_tInteractionRange = {
  chair      = 1.55,
  bench      = 1.65,
  picnic     = 1.55,
  restaurant = 1.65,
  bin        = 1.50,
  atm        = 1.60,
  vending    = 1.60,
  donation   = 1.55,
  photoboard = 1.65,
  education  = 1.65,
  restroom   = 1.60,
  shop       = 1.95,
  dome       = 1.95,
  ride       = 2.00,
  door       = 2.05,
  gate       = 2.45,
  wide_gate  = 3.40,
}

-- Exact baked .bani clip durations (seconds) measured from Content0/Characters/Guests/Guests.ovl.
local c_tClipDuration = {
  ["$SitBenchIn"]        = {AF = 2.10, AM = 1.50, TF = 2.50, TM = 1.60},
  ["$SitBenchOut"]       = {AF = 1.53, AM = 1.53, TF = 1.37, TM = 1.27},
  ["$PicnicSitInNoFood"] = {AF = 2.53, AM = 2.07, TF = 2.10, TM = 2.97},
  ["$PicnicSitOut"]      = {AF = 3.40, AM = 3.43, TF = 2.77, TM = 2.43},
  ["$OnRideSitDown"]     = {AF = 1.97, AM = 1.47, TF = 1.03, TM = 2.10},
}

-- Non-seat scenery tokens that must never trigger Sit/Ride prompts (e.g. EA_PicnicCanopy, Feeder_AquaticStation).
local c_tNonSeatTokens = {
  "canopy", "roof", "sign", "lamp", "light", "pillar", "column", "wall",
  "fence", "arch", "banner", "statue", "feeder", "filter", "heater", "cooler", "speaker",
}

-- Strict local whitelist: Emotes (Pages 1 & 2) — every clip verified in Guests.ovl across AF/AM/TF/TM.
local c_tEmotes = {
  -- Page 1: Social
  cheer      = {page = 1, label = "Cheer",         clip = "$StandReactCheer",       walkClip = "$WalkReactCheer",   loop = false},
  clap       = {page = 1, label = "Clap",          clip = "$FireworkShow_Clap",     walkClip = nil,                 loop = false},
  point      = {page = 1, label = "Point",         clip = "$StandReactPoint",       walkClip = "$WalkReactPoint_L", loop = false},
  laugh      = {page = 1, label = "Laugh",         clip = "$StandReactLaugh",       walkClip = nil,                 loop = false},
  cute       = {page = 1, label = "Cute / Aww",    clip = "$StandReactCute",        walkClip = nil,                 loop = false},
  dance      = {page = 1, label = "Groove",        clip = "$StandReactMusic",       walkClip = nil,                 loop = true},
  phone      = {page = 1, label = "Check Phone",   clip = "$StandCheckPhone",       walkClip = nil,                 loop = false, tempProp = "acc_mobilephoneright", bone = "def_r_attach_joint"},
  photo      = {page = 1, label = "Take Photo",    clip = "$StandInteractTakePhoto01", walkClip = nil,              loop = false},
  -- Page 2: Reactions
  excited    = {page = 2, label = "Excited!",      clip = "$FireworkShowStand_Exc", walkClip = nil,                 loop = false},
  spooked    = {page = 2, label = "Spooked",       clip = "$StandReactSpooked",     walkClip = nil,                 loop = false},
  disapprove = {page = 2, label = "Disapprove",    clip = "$StandReactDisapproval", walkClip = nil,                 loop = false},
  bored      = {page = 2, label = "Bored / Yawn",  clip = "$StandReactBored",       walkClip = "$WalkReactYawn",    loop = false},
  sad        = {page = 2, label = "Sad",           clip = "$StandReactSad",         walkClip = nil,                 loop = false},
  taunt      = {page = 2, label = "Taunt Glass",   clip = "$StandAnnoyAnimal",      walkClip = nil,                 loop = false},
  calm       = {page = 2, label = "Calm Down",     clip = "$StandCalmDown",         walkClip = nil,                 loop = false},
  sick       = {page = 2, label = "Sick / Gag",    clip = "$StandVomit",            walkClip = nil,                 loop = false},
}

-- Strict local whitelist: Carried Props (Page 3) — prefabs verified in Main_SmallResources.ovl.
local c_tProps = {
  prop_umbrella = {label = "Umbrella",      prefab = "umbrella_blue",                  bone = "def_r_attach_joint", clip = "$Partial_WalkHoldUmbrellaR", kind = "umbrella"},
  prop_coffee   = {label = "Coffee",        prefab = "fad_coffeecup",                  bone = "def_l_attach_joint", clip = "$Partial_WalkHoldCup_ArmL",  kind = "cup"},
  prop_burger   = {label = "Burger",        prefab = "fad_burger",                     bone = "def_r_attach_joint", clip = "$Partial_WalkHoldFood_ArmR", kind = "food"},
  prop_icecream = {label = "Ice Cream",     prefab = "fad_icecream",                   bone = "def_r_attach_joint", clip = "$Partial_WalkEatIceR",       kind = "ice"},
  prop_slushie  = {label = "Slushie",       prefab = "fad_slushiecup_blue",            bone = "def_l_attach_joint", clip = "$Partial_WalkDrinkStrawL",   kind = "straw"},
  prop_balloon  = {label = "Animal Balloon",prefab = "mch_novelty_balloon_giraffe",    bone = "def_l_attach_joint", clip = "$Partial_WalkHoldItemL",     kind = "balloon", popFx = "mch_balloonpopfx_red"},
  prop_bag      = {label = "Shopping Bag",  prefab = "shoppingbag",                    bone = "def_r_attach_joint", clip = "$Partial_WalkWithBagR",      kind = "bag"},
}

-- Strict local whitelist: World Interactions (Pillar B & C).
local c_tInteractions = {
  bench      = {label = "Sit",           enter = "$SitBenchIn",          idle = "$SitBenchIdle",     teenIdle = "$SitBenchIdle01", teenIdle2 = "$SitBenchIdle02", exit = "$SitBenchOut",   seat = true,  eyeHeight = 1.15},
  chair      = {label = "Sit",           enter = "$SitBenchIn",          idle = "$SitBenchIdle",     teenIdle = "$SitBenchIdle01", teenIdle2 = "$SitBenchIdle02", exit = "$SitBenchOut",   seat = true,  eyeHeight = 1.15, singleSeat = true},
  picnic     = {label = "Sit at Table",  enter = "$PicnicSitInNoFood",   idle = "$PicnicSitNoFood",  exit = "$PicnicSitOut",       seat = true,  eyeHeight = 1.15},
  restaurant = {label = "Dine",          enter = "$PicnicSitInNoFood",   idle = "$SitRestaurantEat", exit = "$PicnicSitOut",       seat = true,  eyeHeight = 1.15},
  photoboard = {label = "Pose at Board", enter = "$StandInteractEducationStationPhotoBoard_Shark01", loop = false},
  education  = {label = "Read Info",     enter = "$StandLearn",          loop = false},
  shop       = {label = "Buy Item",      enter = "$StandInteractKioskNormalIn", loop = false, grantProp = "prop_coffee"},
  vending    = {label = "Use Vending",   enter = "$StandInteractVMInteractIn",  loop = false, grantProp = "prop_slushie"},
  atm        = {label = "Use ATM",       enter = "$StandInteractATMNormalIn",   loop = false},
  bin        = {label = "Toss Item",     enter = "$Partial_WalkBinRightR",      loop = false, clearProp = true},
  restroom   = {label = "Wash Hands",    enter = "$WashHands",                  loop = false},
  donation   = {label = "Donate",        enter = "$StandThrowItem",             loop = false},
  aquarium   = {label = "Watch Aquarium",enter = "$StandReactAquarium01",       idleWatch = true},
  aviary     = {label = "Watch Aviary",  enter = "$StandReactAviary01",         idleWatch = true},
  exhibit    = {label = "Watch Exhibit", enter = "$StandWatchExhibit",          idleWatch = true},
  dome       = {label = "Enter Dome",    enter = "$StandWatchExhibit",          loop = false, teleport = true},
  ride       = {label = "Board Ride",    enter = "$OnRideSitDown",       idle = "$OnRideSitIdle",    exit = "$SitBenchOut",        seat = true,  eyeHeight = 1.20},
  pickedup   = {label = "Drop In",       enter = "$PickedUp_In",         loop = false},
  door       = {label = "Open Door",     enter = "$StandInteractKioskNormalIn", loop = false, door = true},
  gate       = {label = "Open Gate",     enter = "$StandInteractKioskNormalIn", loop = false, door = true},
  wide_gate  = {label = "Open Gate",     enter = "$StandInteractKioskNormalIn", loop = false, door = true},
}

-- Resource-name pattern matchers for placed park scenery / facilities (lowercase substring match).
local c_tObjectMatchers = {
  {pat = "picnic",       kind = "picnic"},
  {pat = "bench",        kind = "bench"},
  {pat = "chair",        kind = "chair"},
  {pat = "stool",        kind = "chair"},
  {pat = "lounger",      kind = "chair"},
  {pat = "sofa",         kind = "bench"},
  {pat = "couch",        kind = "bench"},
  {pat = "pew",          kind = "bench"},
  {pat = "seating",      kind = "bench"},
  {pat = "seat",         kind = "chair"},
  {pat = "restaurant",   kind = "restaurant"},
  {pat = "table",        kind = "picnic"},
  {pat = "photoboard",   kind = "photoboard"},
  {pat = "photo_board",  kind = "photoboard"},
  {pat = "education",    kind = "education"},
  {pat = "vending",      kind = "vending"},
  {pat = "atm",          kind = "atm"},
  {pat = "bin",          kind = "bin"},
  {pat = "trash",        kind = "bin"},
  {pat = "toilet",       kind = "restroom"},
  {pat = "restroom",     kind = "restroom"},
  {pat = "donation",     kind = "donation"},
  {pat = "viewingdome",  kind = "dome"},
  {pat = "viewing_dome", kind = "dome"},
  {pat = "dome",         kind = "dome"},
  {pat = "shop",         kind = "shop"},
  {pat = "kiosk",        kind = "shop"},
  {pat = "coffee",       kind = "shop", grantProp = "prop_coffee"},
  {pat = "burger",       kind = "shop", grantProp = "prop_burger"},
  {pat = "icecream",     kind = "shop", grantProp = "prop_icecream"},
  {pat = "gelato",       kind = "shop", grantProp = "prop_icecream"},
  {pat = "balloon",      kind = "shop", grantProp = "prop_balloon"},
  {pat = "umbrella",     kind = "shop", grantProp = "prop_umbrella"},
  {pat = "gift",         kind = "shop", grantProp = "prop_bag"},
  {pat = "station",      kind = "ride"},
}

-- Viewing-zone matchers: only trigger smoothly after the player stands idle beside an exhibit/aquarium/aviary.
local c_tViewingMatchers = {
  {pat = "aquarium", kind = "aquarium"},
  {pat = "aviary",   kind = "aviary"},
  {pat = "exhibit",  kind = "exhibit"},
}

local c_tEmotePrompt = {sLocString = "STRING_LITERAL:Value=|Emotes|", sLogicalControl = "Editors_ToggleAlignToSuggestions",
  sLocation = "HUD_CenterPrompts"}

local s = rawget(global, "__PZ2CoopActionsState")
if s == nil then
  s = {
    bInstalled = false,
    bWheelOpen = false,
    nWheelPage = 1,
    bWheelDirty = true,
    nWheelBlockUntil = 0,
    sActiveProp = nil,
    bAutoUmbrella = false,
    sActiveLoopEmote = nil,
    sExhibitIdleKind = nil,
    nExhibitIdleTimer = 0,
    tActiveSeat = nil, -- {kind, x, y, z, yaw, eyeHeight, slot}
    sFriendProp = nil,
    tFriendSeat = nil,
    nScanTimer = 0,
    tHovered = nil, -- {kind, label, nEntityID, x, y, z, yaw, grantProp}
    nHighlightId = nil,
    bTooltipShown = false,
    bPromptAdded = false,
    tPopFx = {}, -- temporary pop VFX entities {nId, nUntil}
    tOpenDoors = {}, -- nEntityID -> animated scenery door / non-FPI habitat gate state
    nClock = 0,
  }
  rawset(global, "__PZ2CoopActionsState", s)
end

local Log = function(_sMsg)
  Bridge.Log("actions: " .. _sMsg)
end

local WorldAPIs = function()
  return api.world.GetWorldAPIs()
end

local IsFinite = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

local Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

local Clamp = function(_n, _lo, _hi)
  if _n < _lo then return _lo end
  if _n > _hi then return _hi end
  return _n
end

local Smoothstep = function(_t)
  local t = Clamp(_t, 0, 1)
  return t * t * (3.0 - 2.0 * t)
end

local WrapAngle = function(_n)
  return (_n + math.pi) % (2 * math.pi) - math.pi
end

local ClipDuration = function(_sClipSuffix, _sGroup, _nFallback)
  local tByGroup = _sClipSuffix and c_tClipDuration[_sClipSuffix]
  if type(tByGroup) == "table" then
    local nDur = tByGroup[_sGroup or "AM"] or tByGroup.AM
    if type(nDur) == "number" and nDur > 0 then
      return nDur
    end
  end
  return _nFallback or 1.6
end

local CurrentPlayerPose = function()
  local tPose = Presence.GetOwnPose()
  if tPose ~= nil then
    local nBodyYaw = Presence.GetOwnBodyYaw and Presence.GetOwnBodyYaw() or nil
    return tPose.x, tPose.y, tPose.z, tPose.camYaw or tPose.yaw or 0, nBodyYaw or tPose.yaw or 0
  end
  local tWorld = WorldAPIs()
  if tWorld ~= nil and tWorld.CameraModeManager ~= nil then
    local vPos, vYPR = tWorld.CameraModeManager:GetPosYPRZoom()
    if vPos ~= nil then
      local nCamYaw = vYPR ~= nil and (vYPR.GetX and vYPR:GetX() or vYPR:X()) or 0
      return vPos:GetX(), vPos:GetY() - c_nStandEyeHeight, vPos:GetZ(), nCamYaw, nCamYaw
    end
  end
  return nil
end

local CurrentUIMode = function()
  local bOk, sMode = pcall(function()
    local BaseUIMode = require("Editors.Shared.BaseUIMode")
    return WorldAPIs().ModeHelperComponent:GetCurrentModeName(BaseUIMode.GetModeHelperEntity())
  end)
  return bOk and sMode or nil
end

local SendAction = function(_tPayload)
  if Bridge.GetRole() == "none" or not (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    return
  end
  local tOut = {k = "action"}
  for k, v in pairs(_tPayload) do
    tOut[k] = v
  end
  Bridge.SendPacket(c_nActionPacket, nil, tOut)
end

local PicnicClipForProp = function(_sPropId)
  local tP = _sPropId and c_tProps[_sPropId]
  if tP == nil then
    return "$PicnicSitNoFood"
  end
  if tP.kind == "food" then return "$PicnicSitHoldFoodR" end
  if tP.kind == "cup" then return "$PicnicSitHoldCupL" end
  if tP.kind == "straw" then return "$PicnicSitUseStrawL" end
  if tP.kind == "ice" then return "$PicnicSitUseIceL" end
  return "$PicnicSitNoFood"
end

local SeatIdleClip = function(_sKind, _sGroup, _sPropId, _nVariantIdx)
  local tInt = c_tInteractions[_sKind]
  if tInt == nil then
    return "$SitBenchIdle"
  end
  if _sKind == "picnic" then
    return PicnicClipForProp(_sPropId)
  end
  if (_sKind == "bench" or _sKind == "chair") and (_sGroup == "TF" or _sGroup == "TM") and tInt.teenIdle ~= nil then
    if _nVariantIdx == 2 and tInt.teenIdle2 ~= nil then
      return tInt.teenIdle2
    end
    return tInt.teenIdle
  end
  return tInt.idle or "$SitBenchIdle"
end

-- Computes exact (seatX, seatY, seatZ, seatYaw, entryX, entryY, entryZ, slot) for benches, chairs, and picnic tables.
local ComputeSeatGeometry = function(_sKind, _nX, _nY, _nZ, _nYaw, _nPlayerX, _nPlayerZ)
  local nYaw = _nYaw or 0
  local fx, fz = math.sin(nYaw), math.cos(nYaw)
  local rx, rz = math.cos(nYaw), -math.sin(nYaw)
  local nSeatX, nSeatY, nSeatZ = _nX, _nY, _nZ
  local nSeatYaw = nYaw
  local nEntryX, nEntryZ = _nX + fx * c_nSeatEntryOffsetM, _nZ + fz * c_nSeatEntryOffsetM
  local nSlot = 0

  if _sKind == "bench" then
    local x0, z0 = _nX - rx * c_nBenchSeatOffsetM, _nZ - rz * c_nBenchSeatOffsetM
    local x1, z1 = _nX + rx * c_nBenchSeatOffsetM, _nZ + rz * c_nBenchSeatOffsetM
    local bFriend0, bFriend1 = false, false
    if s.tFriendSeat ~= nil then
      local fsx = s.tFriendSeat.seatX or s.tFriendSeat.x
      local fsz = s.tFriendSeat.seatZ or s.tFriendSeat.z
      if fsx ~= nil and fsz ~= nil then
        bFriend0 = ((fsx - x0) ^ 2 + (fsz - z0) ^ 2) < 0.36
        bFriend1 = ((fsx - x1) ^ 2 + (fsz - z1) ^ 2) < 0.36
      end
    end
    if bFriend0 and not bFriend1 then
      nSlot = 1
    elseif bFriend1 and not bFriend0 then
      nSlot = 0
    elseif _nPlayerX ~= nil and _nPlayerZ ~= nil then
      local p0 = (_nPlayerX - x0) ^ 2 + (_nPlayerZ - z0) ^ 2
      local p1 = (_nPlayerX - x1) ^ 2 + (_nPlayerZ - z1) ^ 2
      nSlot = (p1 < p0) and 1 or 0
    end
    nSeatX, nSeatZ = (nSlot == 1) and x1 or x0, (nSlot == 1) and z1 or z0
    nEntryX, nEntryZ = nSeatX + fx * c_nSeatEntryOffsetM, nSeatZ + fz * c_nSeatEntryOffsetM
  elseif _sKind == "picnic" then
    -- Picnic tables have benches on both +Z and -Z sides facing inward toward the tabletop.
    local nSide = 1
    if _nPlayerX ~= nil and _nPlayerZ ~= nil then
      local nDot = (_nPlayerX - _nX) * fx + (_nPlayerZ - _nZ) * fz
      nSide = nDot >= 0 and 1 or -1
    end
    local cx, cz = _nX + nSide * fx * c_nPicnicBenchDepthM, _nZ + nSide * fz * c_nPicnicBenchDepthM
    local x0, z0 = cx - rx * c_nBenchSeatOffsetM, cz - rz * c_nBenchSeatOffsetM
    local x1, z1 = cx + rx * c_nBenchSeatOffsetM, cz + rz * c_nBenchSeatOffsetM
    if s.tFriendSeat ~= nil then
      local fsx = s.tFriendSeat.seatX or s.tFriendSeat.x
      local fsz = s.tFriendSeat.seatZ or s.tFriendSeat.z
      if fsx ~= nil and fsz ~= nil and ((fsx - x0) ^ 2 + (fsz - z0) ^ 2) < 0.36 then
        nSlot = 1
      end
    elseif _nPlayerX ~= nil and _nPlayerZ ~= nil then
      local p0 = (_nPlayerX - x0) ^ 2 + (_nPlayerZ - z0) ^ 2
      local p1 = (_nPlayerX - x1) ^ 2 + (_nPlayerZ - z1) ^ 2
      nSlot = (p1 < p0) and 1 or 0
    end
    nSeatX, nSeatZ = (nSlot == 1) and x1 or x0, (nSlot == 1) and z1 or z0
    nSeatYaw = (nSide > 0) and WrapAngle(nYaw + math.pi) or nYaw
    -- Step in/out from the OUTSIDE of the picnic bench (away from the tabletop).
    nEntryX = nSeatX + nSide * fx * c_nPicnicEntryOffsetM
    nEntryZ = nSeatZ + nSide * fz * c_nPicnicEntryOffsetM
  end

  return nSeatX, nSeatY, nSeatZ, nSeatYaw, nEntryX, _nY, nEntryZ, nSlot
end

-- ---- own avatar actions --------------------------------------------------------------------------
local ApplyOwnProp = function(_sPropId, _bManual, _bNoSend)
  local tBody = Presence.GetOwnBody()
  if _sPropId == nil or _sPropId == "prop_clear" then
    -- Balloon pop gag when clearing an equipped balloon!
    local tOld = s.sActiveProp and c_tProps[s.sActiveProp]
    if tOld ~= nil and tOld.popFx ~= nil and tBody ~= nil and tBody.nAvatar ~= nil then
      pcall(function()
        local tok = api.entity.CreateRequestCompletionToken()
        local nFx = api.entity.InstantiatePrefab(tOld.popFx, "PZ2CoopBalloonPop", tok, nil, tBody.nAvatar, true, nil)
        if nFx ~= nil then
          table.insert(s.tPopFx, {nId = nFx, nUntil = s.nClock + 1.5})
        end
      end)
    end
    s.sActiveProp = nil
    s.bAutoUmbrella = false
    s.bWheelDirty = true
    if tBody ~= nil and tBody.tAnim ~= nil then
      Avatar.DetachProp(tBody.tAnim)
      if s.tActiveSeat == nil and s.sActiveLoopEmote == nil then
        Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
      end
    end
    if not _bNoSend then
      SendAction({op = "prop", id = "prop_clear"})
    end
    return true
  end
  local tP = c_tProps[_sPropId]
  if tP == nil then
    return false
  end
  s.sActiveProp = _sPropId
  s.bAutoUmbrella = not _bManual
  s.bWheelDirty = true
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    Avatar.AttachProp(tBody.tAnim, tBody.nAvatar, tP.prefab, tP.bone)
  end
  if not _bNoSend then
    SendAction({op = "prop", id = _sPropId})
  end
  return true
end

local CancelSeatImmediate = function(_bNoSend)
  if s.tActiveSeat == nil then
    return
  end
  local bWasCommitted = s.tActiveSeat.phase ~= "approaching"
  s.tActiveSeat = nil
  Presence.SetSeatOverride(nil)
  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, 0.18)
  end
  if bWasCommitted and not _bNoSend then
    SendAction({op = "clear"})
  end
end

local BeginSeatExit = function(_tSeat, _bNoSend)
  if _tSeat == nil or _tSeat.phase == "exiting" then
    return
  end
  local tInt = c_tInteractions[_tSeat.kind]
  local tBody = Presence.GetOwnBody()
  local sGroup = tBody ~= nil and tBody.tAnim ~= nil and tBody.tAnim.sGroup or "AM"
  local sExitClip = tInt and tInt.exit or "$SitBenchOut"
  _tSeat.phase = "exiting"
  _tSeat.nPhaseTime = 0
  _tSeat.nWalkSpeed = 0
  _tSeat.nYawRate = 0
  _tSeat.exitStartX, _tSeat.exitStartY, _tSeat.exitStartZ = _tSeat.x, _tSeat.y, _tSeat.z
  _tSeat.exitStartEye = _tSeat.eyeHeight or _tSeat.sitEyeHeight or 1.15
  _tSeat.nExitDur = ClipDuration(sExitClip, sGroup, 1.50)
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil and sExitClip ~= nil then
    Avatar.CancelOneShot(tBody.tAnim, tBody.nAvatar)
    Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sExitClip, 0.15)
  end
  if not _bNoSend then
    SendAction({op = "clear"})
  end
  Log("standing up from " .. tostring(_tSeat.kind))
end

local BeginSeatEnter = function(_tSeat)
  if _tSeat == nil or _tSeat.phase == "entering" then
    return
  end
  local tInt = c_tInteractions[_tSeat.kind]
  local tBody = Presence.GetOwnBody()
  local sGroup = tBody ~= nil and tBody.tAnim ~= nil and tBody.tAnim.sGroup or "AM"
  local sEnterClip = tInt and tInt.enter or "$SitBenchIn"
  _tSeat.phase = "entering"
  _tSeat.nPhaseTime = 0
  _tSeat.nWalkSpeed = 0
  _tSeat.nYawRate = 0
  _tSeat.enterStartX, _tSeat.enterStartY, _tSeat.enterStartZ = _tSeat.x, _tSeat.y, _tSeat.z
  _tSeat.enterStartYaw = _tSeat.yaw
  _tSeat.nEnterDur = ClipDuration(sEnterClip, sGroup, 1.80)
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil and sEnterClip ~= nil then
    Avatar.CancelOneShot(tBody.tAnim, tBody.nAvatar)
    Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sEnterClip, 0.18)
  end
  SendAction({op = "sit", id = _tSeat.kind, x = Cm(_tSeat.seatX), y = Cm(_tSeat.seatY), z = Cm(_tSeat.seatZ),
    yaw = math.floor(_tSeat.seatYaw * 1000 + 0.5)})
  Log("sitting down at " .. tostring(_tSeat.kind) .. " (slot " .. tostring(_tSeat.slot) .. ")")
end

local StandUp = function(_bNoSend, _bImmediate)
  if s.tActiveSeat == nil then
    return
  end
  if _bImmediate == true or s.tActiveSeat.phase == "approaching" then
    CancelSeatImmediate(_bNoSend)
    return
  end
  if s.tActiveSeat.phase == "entering" then
    s.tActiveSeat.bPendingExit = true
    return
  end
  if s.tActiveSeat.phase == "seated" then
    BeginSeatExit(s.tActiveSeat, _bNoSend)
  end
end

local StepOwnSeat = function(_nDt, _bMovePressed, _bActionPressed)
  local tSeat = s.tActiveSeat
  if tSeat == nil then
    return
  end
  local nDt = type(_nDt) == "number" and _nDt > 0 and math.min(_nDt, 0.1) or (1 / 60)
  local tInt = c_tInteractions[tSeat.kind]
  local tBody = Presence.GetOwnBody()
  local sGroup = tBody ~= nil and tBody.tAnim ~= nil and tBody.tAnim.sGroup or "AM"
  tSeat.nPhaseTime = (tSeat.nPhaseTime or 0) + nDt

  if tSeat.phase == "approaching" then
    -- Allow cancelling the walk-up cleanly with WASD (zero teleport: player stays right where they stopped).
    if _bMovePressed and tSeat.nPhaseTime >= 0.15 then
      CancelSeatImmediate(true)
      return
    end
    local dx = tSeat.entryX - tSeat.x
    local dz = tSeat.entryZ - tSeat.z
    local nDist = math.sqrt(dx * dx + dz * dz)
    if nDist > 0.06 and tSeat.nPhaseTime < c_nApproachTimeout then
      -- Natural NPC walk-up speed with smooth foot-plant deceleration over the final 25 cm.
      local nTargetSpeed = c_nApproachWalkSpeed
      if nDist < 0.25 then
        nTargetSpeed = 0.65 + (c_nApproachWalkSpeed - 0.65) * (nDist / 0.25)
      end
      local nStep = math.min(nDist, nTargetSpeed * nDt)
      local nFrac = nStep / nDist
      tSeat.x = tSeat.x + dx * nFrac
      tSeat.z = tSeat.z + dz * nFrac
      local nProgress = tSeat.nInitialDist > 1e-3 and Clamp(1.0 - (nDist - nStep) / tSeat.nInitialDist, 0, 1) or 1.0
      tSeat.y = tSeat.startY + (tSeat.entryY - tSeat.startY) * nProgress
      tSeat.eyeHeight = c_nStandEyeHeight
      local nMoveYaw = math.atan(dx, dz)
      local nYawDiff = WrapAngle(nMoveYaw - tSeat.yaw)
      local nYawStep = Clamp(nYawDiff, -c_nApproachTurnRate * nDt, c_nApproachTurnRate * nDt)
      tSeat.yaw = WrapAngle(tSeat.yaw + nYawStep)
      tSeat.nWalkSpeed = nStep / nDt
      tSeat.nYawRate = nYawStep / nDt
      return
    end
    -- Reached entry spot right in front of the seat: smoothly pivot to face seatYaw before playing SitBenchIn.
    tSeat.x, tSeat.y, tSeat.z = tSeat.entryX, tSeat.entryY, tSeat.entryZ
    tSeat.nWalkSpeed = 0
    local nAlignDiff = WrapAngle(tSeat.seatYaw - tSeat.yaw)
    if math.abs(nAlignDiff) > 0.10 and tSeat.nPhaseTime < c_nApproachTimeout then
      local nTurnStep = Clamp(nAlignDiff, -c_nAlignTurnRate * nDt, c_nAlignTurnRate * nDt)
      tSeat.yaw = WrapAngle(tSeat.yaw + nTurnStep)
      tSeat.nYawRate = nTurnStep / nDt
      return
    end
    tSeat.yaw = tSeat.seatYaw
    tSeat.nYawRate = 0
    BeginSeatEnter(tSeat)
    return
  end

  if tSeat.phase == "entering" then
    local sEnterClip = tInt and tInt.enter or "$SitBenchIn"
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil and tBody.tAnim.sOverrideSuffix ~= sEnterClip then
      Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sEnterClip, 0.18)
      tSeat.nEnterDur = ClipDuration(sEnterClip, tBody.tAnim.sGroup, tSeat.nEnterDur)
    end
    local nDur = tSeat.nEnterDur or 1.80
    local u = Smoothstep(tSeat.nPhaseTime / math.max(0.25, nDur * 0.78))
    tSeat.x = tSeat.enterStartX + (tSeat.seatX - tSeat.enterStartX) * u
    tSeat.y = tSeat.enterStartY + (tSeat.seatY - tSeat.enterStartY) * u
    tSeat.z = tSeat.enterStartZ + (tSeat.seatZ - tSeat.enterStartZ) * u
    tSeat.yaw = WrapAngle(tSeat.enterStartYaw + WrapAngle(tSeat.seatYaw - tSeat.enterStartYaw) * u)
    tSeat.eyeHeight = c_nStandEyeHeight + (tSeat.sitEyeHeight - c_nStandEyeHeight) * u
    if (_bMovePressed or _bActionPressed) and tSeat.nPhaseTime >= 0.25 then
      tSeat.bPendingExit = true
    end
    if tSeat.nPhaseTime >= math.max(0.20, nDur - 0.15) then
      tSeat.x, tSeat.y, tSeat.z = tSeat.seatX, tSeat.seatY, tSeat.seatZ
      tSeat.yaw = tSeat.seatYaw
      tSeat.eyeHeight = tSeat.sitEyeHeight
      if tSeat.bPendingExit then
        BeginSeatExit(tSeat, false)
        return
      end
      tSeat.phase = "seated"
      tSeat.nPhaseTime = 0
      tSeat.nIdleTimer = 0
      tSeat.nIdleVariantIdx = 1
      if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
        local sIdle = SeatIdleClip(tSeat.kind, sGroup, s.sActiveProp, tSeat.nIdleVariantIdx)
        Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sIdle, 0.22)
      end
    end
    return
  end

  if tSeat.phase == "seated" then
    tSeat.x, tSeat.y, tSeat.z = tSeat.seatX, tSeat.seatY, tSeat.seatZ
    tSeat.yaw = tSeat.seatYaw
    tSeat.eyeHeight = tSeat.sitEyeHeight
    tSeat.nWalkSpeed = 0
    tSeat.nYawRate = 0
    -- Subtle seated idle variety for teens (SitBenchIdle01 <-> SitBenchIdle02) & live prop updates at picnic tables.
    if (tSeat.kind == "bench" or tSeat.kind == "chair") and (sGroup == "TF" or sGroup == "TM") then
      tSeat.nIdleTimer = (tSeat.nIdleTimer or 0) + nDt
      if tSeat.nIdleTimer >= c_nTeenSitIdleSwap then
        tSeat.nIdleTimer = 0
        tSeat.nIdleVariantIdx = (tSeat.nIdleVariantIdx == 1) and 2 or 1
      end
    end
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      local sDesiredIdle = SeatIdleClip(tSeat.kind, sGroup, s.sActiveProp, tSeat.nIdleVariantIdx)
      if tBody.tAnim.sOverrideSuffix ~= sDesiredIdle then
        Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sDesiredIdle, 0.35)
      end
    end
    if (_bMovePressed or _bActionPressed) and tSeat.nPhaseTime >= 0.15 then
      BeginSeatExit(tSeat, false)
    end
    return
  end

  if tSeat.phase == "exiting" then
    local sExitClip = tInt and tInt.exit or "$SitBenchOut"
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil and tBody.tAnim.sOverrideSuffix ~= sExitClip then
      Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sExitClip, 0.15)
      tSeat.nExitDur = ClipDuration(sExitClip, tBody.tAnim.sGroup, tSeat.nExitDur)
    end
    local nDur = tSeat.nExitDur or 1.50
    local u = Smoothstep(tSeat.nPhaseTime / math.max(0.25, nDur * 0.85))
    tSeat.x = tSeat.exitStartX + (tSeat.entryX - tSeat.exitStartX) * u
    tSeat.y = tSeat.exitStartY + (tSeat.entryY - tSeat.exitStartY) * u
    tSeat.z = tSeat.exitStartZ + (tSeat.entryZ - tSeat.exitStartZ) * u
    tSeat.eyeHeight = tSeat.exitStartEye + (c_nStandEyeHeight - tSeat.exitStartEye) * u
    if tSeat.nPhaseTime >= math.max(0.20, nDur - 0.12) then
      s.tActiveSeat = nil
      Presence.SetSeatOverride(nil)
      if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
        Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, 0.18)
      end
      Log("finished standing up")
    end
  end
end

local StepFriendSeat = function(_nDt)
  local tF = s.tFriendSeat
  if tF == nil then
    return
  end
  local nDt = type(_nDt) == "number" and _nDt > 0 and math.min(_nDt, 0.1) or (1 / 60)
  local tInt = c_tInteractions[tF.kind]
  local tBody = Presence.GetFriendBody()
  local sGroup = tBody ~= nil and tBody.tAnim ~= nil and tBody.tAnim.sGroup or "AM"
  tF.nPhaseTime = (tF.nPhaseTime or 0) + nDt

  if tF.phase == "entering" then
    local nDur = tF.nEnterDur or ClipDuration(tInt and tInt.enter, sGroup, 1.80)
    if tF.nPhaseTime >= math.max(0.20, nDur - 0.15) then
      tF.phase = "seated"
      tF.nPhaseTime = 0
      if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
        local sIdle = SeatIdleClip(tF.kind, sGroup, s.sFriendProp, 1)
        Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sIdle, 0.22)
      end
    end
  elseif tF.phase == "exiting" then
    local nDur = tF.nExitDur or ClipDuration(tInt and tInt.exit, sGroup, 1.50)
    if tF.nPhaseTime >= math.max(0.20, nDur - 0.12) then
      s.tFriendSeat = nil
      Presence.SetFriendSeatOverride(nil)
      if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
        Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, 0.18)
      end
    end
  end
end

Actions.PlayEmote = function(_sId)
  if _sId == "prop_clear" or c_tProps[_sId] ~= nil then
    return ApplyOwnProp(_sId, true, false)
  end
  local tE = c_tEmotes[_sId]
  if tE == nil then
    return false
  end
  StandUp(false, true)
  s.sExhibitIdleKind = nil
  s.nExhibitIdleTimer = 0
  local tBody = Presence.GetOwnBody()
  local bVehiclePass = false
  pcall(function()
    local Vehicles = require("PZ2Coop.Vehicles")
    bVehiclePass = Vehicles ~= nil and Vehicles.IsLocalPassenger ~= nil and Vehicles.IsLocalPassenger() == true
  end)
  local bMoving = not bVehiclePass and tBody ~= nil and tBody.tAnim ~= nil and (tBody.tAnim.nSmoothSpeed or 0) >= 0.35
  local sClip = (bMoving and tE.walkClip) or tE.clip
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    if bVehiclePass then
      -- While seated inside the Research Vehicle, play emotes as one-shots so the avatar stays cleanly seated ($SitBenchIdle).
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, sClip)
    elseif tE.loop then
      s.sActiveLoopEmote = _sId
      Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sClip, 0.22)
    else
      s.sActiveLoopEmote = nil
      Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, sClip)
    end
  end
  SendAction({op = "emote", id = _sId, moving = bMoving})
  Log("played emote " .. _sId)
  return true
end

local ClearHoverVisuals

Actions.StartSeat = function(_sKind, _nX, _nY, _nZ, _nYaw)
  local tInt = c_tInteractions[_sKind]
  if tInt == nil or not tInt.seat then
    return false
  end
  if s.tActiveSeat ~= nil then
    return false
  end
  s.sActiveLoopEmote = nil
  s.sExhibitIdleKind = nil
  s.nExhibitIdleTimer = 0
  ClearHoverVisuals()
  s.tHovered = nil

  local px, py, pz, _, nBodyYaw = CurrentPlayerPose()
  local nSeatX, nSeatY, nSeatZ, nSeatYaw, nEntryX, nEntryY, nEntryZ, nSlot =
    ComputeSeatGeometry(_sKind, _nX, _nY, _nZ, _nYaw, px, pz)
  local nStartX = px ~= nil and px or nEntryX
  local nStartY = py ~= nil and py or nEntryY
  local nStartZ = pz ~= nil and pz or nEntryZ
  local nStartYaw = nBodyYaw ~= nil and nBodyYaw or nSeatYaw
  local nInitDist = math.sqrt((nEntryX - nStartX) ^ 2 + (nEntryZ - nStartZ) ^ 2)

  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    Avatar.CancelOneShot(tBody.tAnim, tBody.nAvatar)
    Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, 0.14)
  end

  s.tActiveSeat = {
    kind = _sKind,
    phase = "approaching",
    nPhaseTime = 0,
    x = nStartX, y = nStartY, z = nStartZ,
    yaw = nStartYaw,
    eyeHeight = c_nStandEyeHeight,
    nWalkSpeed = 0,
    nYawRate = 0,
    startY = nStartY,
    nInitialDist = nInitDist,
    entryX = nEntryX, entryY = nEntryY, entryZ = nEntryZ,
    seatX = nSeatX, seatY = nSeatY, seatZ = nSeatZ,
    seatYaw = nSeatYaw,
    sitEyeHeight = tInt.eyeHeight or 1.15,
    slot = nSlot,
    bPendingExit = false,
  }
  Presence.SetSeatOverride(s.tActiveSeat)

  -- If already standing right on the entry mark and facing the seat direction, sit down immediately;
  -- otherwise walk smoothly up to the entry mark first (never teleporting).
  if nInitDist <= 0.08 and math.abs(WrapAngle(nSeatYaw - nStartYaw)) <= 0.14 then
    BeginSeatEnter(s.tActiveSeat)
  else
    Log("walking up to " .. _sKind .. " (slot " .. nSlot .. ", dist " .. string.format("%.2f m", nInitDist) .. ")")
  end
  return true
end

local ToggleDoor

Actions.TriggerInteraction = function(_tTarget)
  if type(_tTarget) ~= "table" then
    return false
  end
  local tInt = c_tInteractions[_tTarget.kind]
  if tInt == nil then
    return false
  end
  if tInt.door and ToggleDoor ~= nil then
    return ToggleDoor(_tTarget, false)
  end
  if tInt.seat then
    return Actions.StartSeat(_tTarget.kind, _tTarget.x, _tTarget.y, _tTarget.z, _tTarget.yaw or 0)
  end
  if tInt.teleport then
    -- Viewing dome: step smoothly inside the dome center.
    pcall(function()
      WorldAPIs().CameraModeManager:RequestMode("Walking", {
        vStartingPos = Vector3:new(_tTarget.x, _tTarget.y + 1.55, _tTarget.z),
        vStartingYPR = Vector3:new(_tTarget.yaw or 0, 0, 0),
        bIsWildArea = true, bMagnifyEnabled = false, bWalkingRotateLock = true,
      })
    end)
  end
  if tInt.clearProp then
    ApplyOwnProp("prop_clear", true, false)
  elseif _tTarget.grantProp or tInt.grantProp then
    ApplyOwnProp(_tTarget.grantProp or tInt.grantProp, true, false)
  end
  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil and tInt.enter ~= nil then
    Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, tInt.enter)
  end
  SendAction({op = "interact", id = _tTarget.kind})
  Log("triggered world interaction " .. _tTarget.kind)
  return true
end

-- ---- proximity scanner & native world tooltip (Pillar B) -----------------------------------------
ClearHoverVisuals = function()
  if s.nHighlightId ~= nil then
    pcall(function()
      local EditorConfig = require("Editors.Shared.EditorConfig")
      WorldAPIs().model:SetHighlighted(s.nHighlightId, EditorConfig.HighlightChannel_Custom, false)
    end)
    s.nHighlightId = nil
  end
  if s.bTooltipShown then
    s.bTooltipShown = false
    pcall(function()
      local worldScript = api.world.GetScript(api.world.GetActive())
      local hud = worldScript and worldScript.GetHUD and worldScript:GetHUD()
      if hud ~= nil and hud.HideHelperTooltip ~= nil then
        hud:HideHelperTooltip()
      end
    end)
  end
end

local ClassifyResourceName = function(_sResName)
  if type(_sResName) ~= "string" or _sResName == "" then
    return nil, nil
  end
  local sLow = string.lower(_sResName)
  for _, tM in ipairs(c_tObjectMatchers) do
    if string.find(sLow, tM.pat, 1, true) ~= nil then
      local tInt = c_tInteractions[tM.kind]
      if tInt ~= nil and tInt.seat then
        for _, sBad in ipairs(c_tNonSeatTokens) do
          if string.find(sLow, sBad, 1, true) ~= nil then
            return nil, nil
          end
        end
      end
      return tM.kind, tM.grantProp
    end
  end
  return nil, nil
end

-- Resolves a spatial hit EntityID to its placement resource name (converting EntityID -> PlacementPartID via
-- scenery_puppets:EntityIDToPlacementID as retail PZ2 requires, walking parents up to 3 hops, with fallbacks).
local ResolveEntityResourceName = function(_tWorld, _nEnt)
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
  -- Direct fallback (offline tests / part IDs matching entity IDs)
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

-- ---- universal doors & wide gates (scenery doors, paired double doors, shutters, guest/transport/glass-tunnel gates) --
local ClassifySceneryDoor = function(_sResName)
  if type(_sResName) ~= "string" or _sResName == "" then
    return nil
  end
  local sLow = string.lower(_sResName)
  if string.find(sLow, "aquarium", 1, true) ~= nil then
    return nil
  end
  -- Reject non-leaf door frames, toppers, canopies, signs, wall cutouts, archways, and open shutters
  for _, sSkip in ipairs({"_frame_", "_topper", "_top_", "canopy", "sign", "_wall_", "_panel_",
    "wallpaper", "emissive", "_open", "_post", "_roller", "_trim", "arch", "tunnel"}) do
    if string.find(sLow, sSkip, 1, true) ~= nil then
      return nil
    end
  end
  if string.find(sLow, "door_shutter_01_closed", 1, true) ~= nil then
    return {sKind = "door", sStyle = "shutter", nHalfW = 1.45, nHalfDepth = 0.75, nMaxY = 2.80, nSlideY = 2.25}
  end
  if string.find(sLow, "door_shutter_01_gate_2m", 1, true) ~= nil or
    string.find(sLow, "fence_05_door_2m", 1, true) ~= nil then
    return {sKind = "door", sStyle = "swing", nHalfW = 1.25, nHalfDepth = 0.75, nMaxY = 2.60, nHingeOffset = 0.95}
  end
  if string.find(sLow, "fence_05_door_3m", 1, true) ~= nil then
    return {sKind = "door", sStyle = "swing", nHalfW = 1.65, nHalfDepth = 0.75, nMaxY = 2.60, nHingeOffset = 1.40}
  end
  if string.find(sLow, "door_shutter_01_gate_1m", 1, true) ~= nil or
    string.find(sLow, "fence_05_door_1m", 1, true) ~= nil then
    return {sKind = "door", sStyle = "swing", nHalfW = 0.75, nHalfDepth = 0.65, nMaxY = 2.45, nHingeOffset = 0.48}
  end
  if string.find(sLow, "pl_hatch_wood", 1, true) ~= nil then
    return {sKind = "door", sStyle = "swing", nHalfW = 0.75, nHalfDepth = 0.65, nMaxY = 2.40, nHingeOffset = 0.45}
  end
  if string.find(sLow, "_door_0", 1, true) ~= nil or
    string.find(sLow, "_singledoor_", 1, true) ~= nil or
    string.find(sLow, "_olddoor", 1, true) ~= nil or
    string.sub(sLow, -5) == "_door" then
    return {sKind = "door", sStyle = "swing", nHalfW = 0.75, nHalfDepth = 0.65, nMaxY = 2.45, nHingeOffset = 0.52}
  end
  return nil
end

local IsVanillaFPIGate = function(_tWorld, _nGateId)
  local fpi = _tWorld and _tWorld.FirstPersonInteraction
  if fpi == nil or type(fpi.tEntities) ~= "table" then
    return false
  end
  for nEnt, tInfo in pairs(fpi.tEntities) do
    if type(tInfo) == "table" and tInfo.sType == "HabitatGate" and
      (tInfo.nParentEntityID == _nGateId or nEnt == _nGateId) then
      return true
    end
  end
  return false
end

local ClassifyHabitatBoundaryGate = function(_tWorld, _nEnt)
  if _tWorld == nil or _nEnt == nil then
    return nil
  end
  if Presence.IsAquariumStaffDoorEntity ~= nil and Presence.IsAquariumStaffDoorEntity(_nEnt) then
    return nil
  end
  local hb = _tWorld.habitatboundary
  if hb == nil or hb.GetBoundaryObjectFromEntity == nil then
    return nil
  end
  local bOk, bHit, oPanel, _, oProp = pcall(hb.GetBoundaryObjectFromEntity, hb, _nEnt)
  if not bOk or not bHit then
    return nil
  end
  if oProp == nil and oPanel ~= nil and oPanel.GetAllData ~= nil then
    local bP, dP = pcall(oPanel.GetAllData, oPanel)
    if bP and type(dP) == "table" then
      oProp = dP.oAttachedProp
    end
  end
  if oProp == nil then
    return nil
  end
  local nGateId = _nEnt
  local sPropName = nil
  if oProp.GetAllData ~= nil then
    local bD, dProp = pcall(oProp.GetAllData, oProp)
    if bD and type(dProp) == "table" then
      nGateId = dProp.nEntityID or nGateId
      sPropName = dProp.sPropType or dProp.sAttachablePropType or dProp.sType or dProp.sPrefabName or dProp.sName
    end
  end
  if Presence.IsAquariumStaffDoorEntity ~= nil and Presence.IsAquariumStaffDoorEntity(nGateId) then
    return nil
  end
  if IsVanillaFPIGate(_tWorld, nGateId) then
    return nil -- vanilla FirstPersonInteraction already owns this gate
  end
  if type(sPropName) ~= "string" or sPropName == "" then
    sPropName = ResolveEntityResourceName(_tWorld, nGateId) or ""
  end
  local sLow = string.lower(sPropName)
  if string.find(sLow, "aquariumentrance", 1, true) ~= nil then
    return nil
  end
  if string.find(sLow, "trackairlock", 1, true) ~= nil or string.find(sLow, "transportgate", 1, true) ~= nil then
    return {nEntityID = nGateId, sKind = "wide_gate", sStyle = "habitat_gate", sMgVar = "GateOpen",
      nHalfW = 2.50, nHalfDepth = 1.20, nMaxY = 3.80, bAllowAcrylic = false, bIsHabitatGate = true}
  elseif string.find(sLow, "glasstunnel", 1, true) ~= nil then
    return {nEntityID = nGateId, sKind = "gate", sStyle = "habitat_gate", sMgVar = "GateState",
      nHalfW = 1.50, nHalfDepth = 0.95, nMaxY = 2.85, bAllowAcrylic = true, bIsHabitatGate = true}
  elseif string.find(sLow, "guestgate", 1, true) ~= nil then
    return {nEntityID = nGateId, sKind = "gate", sStyle = "habitat_gate", sMgVar = "GateState",
      nHalfW = 1.50, nHalfDepth = 0.90, nMaxY = 2.85, bAllowAcrylic = false, bIsHabitatGate = true}
  elseif string.find(sLow, "small", 1, true) ~= nil then
    return {nEntityID = nGateId, sKind = "gate", sStyle = "habitat_gate", sMgVar = "GateState",
      nHalfW = 0.70, nHalfDepth = 0.75, nMaxY = 2.15, bAllowAcrylic = false, bIsHabitatGate = true}
  end
  return {nEntityID = nGateId, sKind = "gate", sStyle = "habitat_gate", sMgVar = "GateState",
    nHalfW = 1.15, nHalfDepth = 0.75, nMaxY = 2.65, bAllowAcrylic = false, bIsHabitatGate = true}
end

local ExtractTransformPose = function(_tr)
  if _tr == nil then
    return nil
  end
  local vPos = _tr.GetPos and _tr:GetPos() or (_tr.Pos and _tr:Pos())
  if vPos == nil then
    return nil
  end
  local x = vPos.GetX and vPos:GetX() or vPos:X()
  local y = vPos.GetY and vPos:GetY() or vPos:Y()
  local z = vPos.GetZ and vPos:GetZ() or vPos:Z()
  local nYaw, nPitch, nRoll = 0, 0, 0
  if _tr.GetOr ~= nil then
    pcall(function()
      local vYpr = _tr:GetOr():ToYawPitchRoll()
      if vYpr ~= nil then
        nYaw = vYpr.GetX and vYpr:GetX() or vYpr:X()
        nPitch = vYpr.GetY and vYpr:GetY() or vYpr:Y()
        nRoll = vYpr.GetZ and vYpr:GetZ() or vYpr:Z()
      end
    end)
  end
  local fx, fz = math.sin(nYaw), math.cos(nYaw)
  if _tr.GetF ~= nil then
    pcall(function()
      local vF = _tr:GetF()
      if vF ~= nil then
        local vx = vF.GetX and vF:GetX() or vF:X()
        local vz = vF.GetZ and vF:GetZ() or vF:Z()
        local nL = math.sqrt(vx * vx + vz * vz)
        if nL > 1e-4 then
          fx, fz = vx / nL, vz / nL
        end
      end
    end)
  end
  return x, y, z, nYaw, nPitch, nRoll, fx, fz, fz, -fx
end

local DriveHabitatGateAnim = function(_tWorld, _nGateId, _sMgVar, _bOpen)
  local attractions = _tWorld and _tWorld.attractions
  if attractions ~= nil then
    if _bOpen and attractions.RequestHabitatGateOpen ~= nil then
      pcall(attractions.RequestHabitatGateOpen, attractions, _nGateId)
    elseif not _bOpen and attractions.ReleaseHabitatGateOpenRequest ~= nil then
      pcall(attractions.ReleaseHabitatGateOpenRequest, attractions, _nGateId)
    end
  end
  local mg = _tWorld and _tWorld.motiongraph
  if mg ~= nil and mg.SetVariable ~= nil then
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

local ApplySceneryDoorPose = function(_tWorld, _tRec, _nT)
  local trApi = _tWorld and _tWorld.transform
  local nEased = Smoothstep(_nT)
  if _tRec.bHiddenFallback then
    if _tWorld and _tWorld.model and _tWorld.model.SetHidden then
      pcall(_tWorld.model.SetHidden, _tWorld.model, _tRec.nEntityID, _nT > 0.05)
    end
    return
  end
  if trApi == nil or trApi.SetTransform == nil then
    _tRec.bHiddenFallback = true
    if _tWorld and _tWorld.model and _tWorld.model.SetHidden then
      pcall(_tWorld.model.SetHidden, _tWorld.model, _tRec.nEntityID, _nT > 0.05)
    end
    return
  end
  local trNew
  if _nT <= 0.001 and _tRec.origTr ~= nil then
    trNew = _tRec.origTr
  elseif _tRec.sStyle == "shutter" then
    local nLift = (_tRec.nSlideY or 2.25) * nEased
    local vNew = Vector3:new(_tRec.gx, _tRec.gy + nLift, _tRec.gz)
    if _tRec.origTr ~= nil and _tRec.origTr.WithPos ~= nil then
      trNew = _tRec.origTr:WithPos(vNew)
    else
      trNew = TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(Vector3:new(_tRec.nYaw, _tRec.nPitch or 0, _tRec.nRoll or 0)), vNew)
    end
  else
    -- Swing around hinge edge (offset along local right axis by nHingeDir * nHingeOffset)
    local nAngle = (_tRec.nSwingSign or 1) * (math.pi * 0.5) * nEased
    local nOff = (_tRec.nHingeDir or 1) * (_tRec.nHingeOffset or 0.52)
    local hx = _tRec.gx + _tRec.rx * nOff
    local hz = _tRec.gz + _tRec.rz * nOff
    local dx0, dz0 = _tRec.gx - hx, _tRec.gz - hz
    local nCos, nSin = math.cos(nAngle), math.sin(nAngle)
    local nx = hx + dx0 * nCos + dz0 * nSin
    local nz = hz - dx0 * nSin + dz0 * nCos
    local nNewYaw = WrapAngle(_tRec.nYaw + nAngle)
    trNew = TransformQ.FromOrPos(
      Quaternion.FromYawPitchRoll(Vector3:new(nNewYaw, _tRec.nPitch or 0, _tRec.nRoll or 0)),
      Vector3:new(nx, _tRec.gy, nz))
  end
  local bOk = pcall(trApi.SetTransform, trApi, _tRec.nEntityID, trNew)
  if not bOk then
    _tRec.bHiddenFallback = true
    if _tWorld and _tWorld.model and _tWorld.model.SetHidden then
      pcall(_tWorld.model.SetHidden, _tWorld.model, _tRec.nEntityID, _nT > 0.05)
    end
  end
end

local FindPairedDoorLeaf = function(_tWorld, _nEnt, _gx, _gy, _gz, _fx, _fz, _rx, _rz)
  local sp = _tWorld and _tWorld.spatial
  local trApi = _tWorld and _tWorld.transform
  if sp == nil or sp.SphereQuery == nil or trApi == nil or trApi.CalculateWorldTransform == nil then
    return nil
  end
  local nFlags = (sp.Flag_Scenery or 0) | (sp.Flag_NonStaticScenery or 0)
  if nFlags == 0 then
    return nil
  end
  local bQ, tHits = pcall(sp.SphereQuery, sp, Vector3:new(_gx, _gy + 0.8, _gz), 2.1, nFlags, 0, 24)
  if not bQ or type(tHits) ~= "table" then
    return nil
  end
  local nBestSide, tBest = math.huge, nil
  for _, nOther in ipairs(tHits) do
    if nOther ~= _nEnt then
      local sName = ResolveEntityResourceName(_tWorld, nOther)
      local tInfo = ClassifySceneryDoor(sName)
      if tInfo ~= nil and tInfo.sStyle == "swing" then
        local bTr, tr = pcall(trApi.CalculateWorldTransform, trApi, nOther)
        if bTr and tr ~= nil then
          local ox, oy, oz, oYaw, oPitch, oRoll, ofx, ofz, orx, orz = ExtractTransformPose(tr)
          if ox ~= nil and math.abs(oy - _gy) <= 0.45 then
            local dx, dz = ox - _gx, oz - _gz
            local nDepth = math.abs(dx * _fx + dz * _fz)
            local nSide = dx * _rx + dz * _rz
            local nAbsSide = math.abs(nSide)
            local nFaceDot = math.abs(_fx * ofx + _fz * ofz)
            if nDepth <= 0.45 and nAbsSide >= 0.55 and nAbsSide <= 1.85 and nFaceDot >= 0.80 and nAbsSide < nBestSide then
              nBestSide = nAbsSide
              tBest = {
                nEntityID = nOther, origTr = tr, tInfo = tInfo,
                gx = ox, gy = oy, gz = oz, nYaw = oYaw, nPitch = oPitch, nRoll = oRoll,
                fx = ofx, fz = ofz, rx = orx, rz = orz, nSideOffset = nSide,
              }
            end
          end
        end
      end
    end
  end
  return tBest
end

local RegisterDoorPortal = function(_tRec, _tPair)
  if Presence.SetOpenPortal == nil then
    return
  end
  local sKey = "door_" .. tostring(_tRec.nEntityID)
  if not _tRec.bOpen then
    Presence.SetOpenPortal(sKey, nil)
    return
  end
  if _tPair ~= nil then
    local mx = (_tRec.gx + _tPair.gx) * 0.5
    local my = math.min(_tRec.gy, _tPair.gy)
    local mz = (_tRec.gz + _tPair.gz) * 0.5
    local nSpan = math.sqrt((_tPair.gx - _tRec.gx) ^ 2 + (_tPair.gz - _tRec.gz) ^ 2)
    Presence.SetOpenPortal(sKey, {
      nId = _tRec.nEntityID,
      gx = mx, gy = my, gz = mz,
      fx = _tRec.fx, fz = _tRec.fz,
      rx = _tRec.rx, rz = _tRec.rz,
      nHalfW = math.max(1.35, nSpan * 0.5 + 0.65),
      nHalfDepth = math.max(_tRec.nHalfDepth or 0.75, 0.80),
      nMinY = -0.35,
      nMaxY = math.max(_tRec.nMaxY or 2.55, 2.60),
      bAllowAcrylic = _tRec.bAllowAcrylic == true,
    })
  else
    Presence.SetOpenPortal(sKey, {
      nId = _tRec.nEntityID,
      gx = _tRec.gx, gy = _tRec.gy, gz = _tRec.gz,
      fx = _tRec.fx, fz = _tRec.fz,
      rx = _tRec.rx, rz = _tRec.rz,
      nHalfW = _tRec.nHalfW or 0.75,
      nHalfDepth = _tRec.nHalfDepth or 0.70,
      nMinY = -0.35,
      nMaxY = _tRec.nMaxY or 2.50,
      bAllowAcrylic = _tRec.bAllowAcrylic == true,
    })
  end
end

local SetDoorOpenState = function(_tTarget, _bOpen, _bRemote)
  if type(_tTarget) ~= "table" or _tTarget.nEntityID == nil then
    return false
  end
  local nEnt = _tTarget.nEntityID
  if Presence.IsAquariumStaffDoorEntity ~= nil and Presence.IsAquariumStaffDoorEntity(nEnt) then
    return false
  end
  local tWorld = WorldAPIs()
  local trApi = tWorld and tWorld.transform
  s.tOpenDoors = s.tOpenDoors or {}
  local tRec = s.tOpenDoors[nEnt]
  if tRec == nil then
    local origTr = trApi ~= nil and trApi.CalculateWorldTransform ~= nil and trApi:CalculateWorldTransform(nEnt) or nil
    local gx, gy, gz, nYaw, nPitch, nRoll, fx, fz, rx, rz = ExtractTransformPose(origTr)
    if gx == nil then
      gx, gy, gz = _tTarget.x or 0, _tTarget.y or 0, _tTarget.z or 0
      nYaw, nPitch, nRoll = _tTarget.yaw or 0, 0, 0
      fx, fz = math.sin(nYaw), math.cos(nYaw)
      rx, rz = fz, -fx
    end
    tRec = {
      nEntityID = nEnt,
      sKind = _tTarget.kind or "door",
      sStyle = _tTarget.sStyle or "swing",
      sMgVar = _tTarget.sMgVar,
      bIsHabitatGate = _tTarget.bIsHabitatGate == true,
      bAllowAcrylic = _tTarget.bAllowAcrylic == true,
      nHalfW = _tTarget.nHalfW or 0.75,
      nHalfDepth = _tTarget.nHalfDepth or 0.70,
      nMaxY = _tTarget.nMaxY or 2.50,
      nHingeOffset = _tTarget.nHingeOffset or 0.52,
      nHingeDir = 1,
      nSlideY = _tTarget.nSlideY or 2.25,
      origTr = origTr,
      gx = gx, gy = gy, gz = gz,
      nYaw = nYaw, nPitch = nPitch, nRoll = nRoll,
      fx = fx, fz = fz, rx = rx, rz = rz,
      bOpen = false,
      nProgress = 0,
      nTarget = 0,
      nSwingSign = 1,
    }
    s.tOpenDoors[nEnt] = tRec
  end

  local bNextOpen = (_bOpen == true)
  tRec.bOpen = bNextOpen
  tRec.nTarget = bNextOpen and 1.0 or 0.0

  if tRec.bIsHabitatGate then
    DriveHabitatGateAnim(tWorld, nEnt, tRec.sMgVar, bNextOpen)
    RegisterDoorPortal(tRec, nil)
    if not bNextOpen then
      s.tOpenDoors[nEnt] = nil
    end
  else
    -- Swing away from the player when opening a swinging scenery door
    if bNextOpen and tRec.sStyle == "swing" then
      local px, _, pz = CurrentPlayerPose()
      local nSideDot = (px ~= nil) and ((px - tRec.gx) * tRec.fx + (pz - tRec.gz) * tRec.fz) or 1
      local nAwaySign = nSideDot >= 0 and -1 or 1
      -- Detect paired second leaf in a double doorway and swing both leaves outward away from player!
      local tPair = nil
      if tRec.nPairedId ~= nil and s.tOpenDoors[tRec.nPairedId] ~= nil then
        tPair = s.tOpenDoors[tRec.nPairedId]
      else
        local tFound = FindPairedDoorLeaf(tWorld, nEnt, tRec.gx, tRec.gy, tRec.gz, tRec.fx, tRec.fz, tRec.rx, tRec.rz)
        if tFound ~= nil then
          tPair = s.tOpenDoors[tFound.nEntityID] or {
            nEntityID = tFound.nEntityID,
            sKind = "door",
            sStyle = "swing",
            nHalfW = tFound.tInfo.nHalfW or 0.75,
            nHalfDepth = tFound.tInfo.nHalfDepth or 0.70,
            nMaxY = tFound.tInfo.nMaxY or 2.50,
            nHingeOffset = tFound.tInfo.nHingeOffset or 0.52,
            origTr = tFound.origTr,
            gx = tFound.gx, gy = tFound.gy, gz = tFound.gz,
            nYaw = tFound.nYaw, nPitch = tFound.nPitch, nRoll = tFound.nRoll,
            fx = tFound.fx, fz = tFound.fz, rx = tFound.rx, rz = tFound.rz,
            bOpen = false, nProgress = 0, nTarget = 0,
            nPairedId = nEnt,
          }
          s.tOpenDoors[tFound.nEntityID] = tPair
          tRec.nPairedId = tFound.nEntityID
          -- Place each leaf's hinge on its OUTER edge (away from the partner leaf)
          local nRelSide = (tFound.gx - tRec.gx) * tRec.rx + (tFound.gz - tRec.gz) * tRec.rz
          tRec.nHingeDir = nRelSide >= 0 and -1 or 1
          local nPairRel = (tRec.gx - tPair.gx) * tPair.rx + (tRec.gz - tPair.gz) * tPair.rz
          tPair.nHingeDir = nPairRel >= 0 and -1 or 1
        end
      end
      if tPair ~= nil then
        tRec.nSwingSign = nAwaySign * tRec.nHingeDir
        tPair.bOpen = true
        tPair.nTarget = 1.0
        local nPairDot = (px ~= nil) and ((px - tPair.gx) * tPair.fx + (pz - tPair.gz) * tPair.fz) or 1
        local nPairAway = nPairDot >= 0 and -1 or 1
        tPair.nSwingSign = nPairAway * (tPair.nHingeDir or -1)
        RegisterDoorPortal(tRec, tPair)
      else
        tRec.nHingeDir = 1
        tRec.nSwingSign = nAwaySign
        RegisterDoorPortal(tRec, nil)
      end
    else
      -- Closing (or shutter): also close paired leaf if any
      if tRec.nPairedId ~= nil and s.tOpenDoors[tRec.nPairedId] ~= nil then
        local tPair = s.tOpenDoors[tRec.nPairedId]
        tPair.bOpen = bNextOpen
        tPair.nTarget = bNextOpen and 1.0 or 0.0
        if Presence.SetOpenPortal ~= nil then
          Presence.SetOpenPortal("door_" .. tostring(tPair.nEntityID), nil)
        end
      end
      RegisterDoorPortal(tRec, nil)
    end
  end

  if not _bRemote then
    local tBody = Presence.GetOwnBody()
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, "$StandInteractKioskNormalIn")
    end
    local sWireKind = tRec.bIsHabitatGate and (tRec.sKind == "wide_gate" and "wide_gate" or "gate") or
      (tRec.sStyle == "shutter" and "shutter" or "scenery_door")
    SendAction({
      op = "door",
      open = bNextOpen,
      kind = sWireKind,
      x = Cm(tRec.gx),
      y = Cm(tRec.gy),
      z = Cm(tRec.gz),
    })
    Log((bNextOpen and "opened " or "closed ") .. sWireKind .. " (id=" .. tostring(nEnt) .. ")")
  end
  return true
end

ToggleDoor = function(_tTarget, _bRemote)
  if type(_tTarget) ~= "table" or _tTarget.nEntityID == nil then
    return false
  end
  local tExisting = s.tOpenDoors and s.tOpenDoors[_tTarget.nEntityID]
  local bNextOpen = not (tExisting ~= nil and tExisting.bOpen == true)
  return SetDoorOpenState(_tTarget, bNextOpen, _bRemote)
end

local StepAnimatedDoors = function(_nDt)
  if type(s.tOpenDoors) ~= "table" or next(s.tOpenDoors) == nil then
    return
  end
  local nDt = type(_nDt) == "number" and _nDt > 0 and _nDt or (1 / 60)
  local tWorld = WorldAPIs()
  local tRemove = nil
  for nEnt, tRec in pairs(s.tOpenDoors) do
    if not tRec.bIsHabitatGate then
      local nTarget = tRec.nTarget or 0
      local nCur = tRec.nProgress or 0
      if math.abs(nTarget - nCur) > 1e-4 then
        local nStep = nDt / c_nDoorAnimDur
        if nTarget > nCur then
          nCur = math.min(nTarget, nCur + nStep)
        else
          nCur = math.max(nTarget, nCur - nStep)
        end
        tRec.nProgress = nCur
        ApplySceneryDoorPose(tWorld, tRec, nCur)
      end
      if not tRec.bOpen and (tRec.nProgress or 0) <= 1e-4 then
        tRemove = tRemove or {}
        table.insert(tRemove, nEnt)
      end
    end
  end
  if tRemove ~= nil then
    for _, nEnt in ipairs(tRemove) do
      if Presence.SetOpenPortal ~= nil then
        Presence.SetOpenPortal("door_" .. tostring(nEnt), nil)
      end
      s.tOpenDoors[nEnt] = nil
    end
  end
end

local RestoreAllDoors = function()
  if type(s.tOpenDoors) ~= "table" then
    return
  end
  local tWorld = WorldAPIs()
  for nEnt, tRec in pairs(s.tOpenDoors) do
    if tRec.bIsHabitatGate then
      DriveHabitatGateAnim(tWorld, nEnt, tRec.sMgVar, false)
    else
      tRec.bOpen = false
      tRec.nProgress = 0
      tRec.nTarget = 0
      ApplySceneryDoorPose(tWorld, tRec, 0)
    end
    if Presence.SetOpenPortal ~= nil then
      Presence.SetOpenPortal("door_" .. tostring(nEnt), nil)
    end
  end
  s.tOpenDoors = {}
end

-- Returns true if a CLOSED interactive modular scenery door sits at (x, y, z) so wall cutouts stay solid until opened.
local HasClosedDoorAt = function(_x, _y, _z)
  local bOk, bClosed = pcall(function()
    local tWorld = WorldAPIs()
    local sp = tWorld and tWorld.spatial
    local trApi = tWorld and tWorld.transform
    if sp == nil or sp.SphereQuery == nil or trApi == nil or trApi.CalculateWorldTransform == nil then
      return false
    end
    local nFlags = (sp.Flag_Scenery or 0) | (sp.Flag_NonStaticScenery or 0)
    if nFlags == 0 then
      return false
    end
    local tHits = sp:SphereQuery(Vector3:new(_x, _y + 0.8, _z), 1.15, nFlags, 0, 16)
    if type(tHits) ~= "table" then
      return false
    end
    for _, nEnt in ipairs(tHits) do
      local sName = ResolveEntityResourceName(tWorld, nEnt)
      if ClassifySceneryDoor(sName) ~= nil then
        local tRec = s.tOpenDoors and s.tOpenDoors[nEnt]
        if tRec == nil or not tRec.bOpen then
          local tr = trApi:CalculateWorldTransform(nEnt)
          local vPos = tr and (tr.GetPos and tr:GetPos() or tr:Pos())
          if vPos ~= nil then
            local dx = (vPos.GetX and vPos:GetX() or vPos:X()) - _x
            local dz = (vPos.GetZ and vPos:GetZ() or vPos:Z()) - _z
            if dx * dx + dz * dz <= 1.05 * 1.05 then
              return true
            end
          end
        end
      end
    end
    return false
  end)
  return bOk and bClosed == true
end

-- Returns horizontal squared distance from player feet (px, pz) to the closest seat/interaction point on an object.
local NearestInteractionDistSq = function(_sKind, _ex, _ez, _nYaw, _px, _pz)
  local dx0, dz0 = _ex - _px, _ez - _pz
  local nBest = dx0 * dx0 + dz0 * dz0
  if _sKind == "bench" then
    local rx, rz = math.cos(_nYaw), -math.sin(_nYaw)
    for _, nSign in ipairs({-1, 1}) do
      local sx, sz = _ex + nSign * rx * c_nBenchSeatOffsetM, _ez + nSign * rz * c_nBenchSeatOffsetM
      local d2 = (sx - _px) ^ 2 + (sz - _pz) ^ 2
      if d2 < nBest then nBest = d2 end
    end
  elseif _sKind == "picnic" then
    local fx, fz = math.sin(_nYaw), math.cos(_nYaw)
    local rx, rz = math.cos(_nYaw), -math.sin(_nYaw)
    for _, nSide in ipairs({-1, 1}) do
      local cx, cz = _ex + nSide * fx * c_nPicnicBenchDepthM, _ez + nSide * fz * c_nPicnicBenchDepthM
      for _, nSign in ipairs({-1, 1}) do
        local sx, sz = cx + nSign * rx * c_nBenchSeatOffsetM, cz + nSign * rz * c_nBenchSeatOffsetM
        local d2 = (sx - _px) ^ 2 + (sz - _pz) ^ 2
        if d2 < nBest then nBest = d2 end
      end
    end
  end
  return nBest
end

local ScanNearbyInteraction = function()
  if s.tActiveSeat ~= nil then
    return nil
  end
  local px, py, pz, nCamYaw = CurrentPlayerPose()
  local tWorld = WorldAPIs()
  if px == nil then
    return nil
  end
  local camFx, camFz = math.sin(nCamYaw or 0), math.cos(nCamYaw or 0)

  if tWorld.spatial == nil or tWorld.spatial.SphereQuery == nil then
    return nil
  end
  -- Benches, chairs, bins, and donation boxes placed on paths live under Flag_PathExtra;
  -- shops/restrooms/ATMs under Flag_Facility; custom chairs/benches/doors under Flag_Scenery / Flag_NonStaticScenery;
  -- guest gates, wide transport gates, and glass tunnel gates under Flag_HabitatBoundary.
  local nFlags = (tWorld.spatial.Flag_Scenery or 0) | (tWorld.spatial.Flag_PathExtra or 0) |
    (tWorld.spatial.Flag_Facility or 0) | (tWorld.spatial.Flag_NonStaticScenery or 0) |
    (tWorld.spatial.Flag_HabitatBoundary or 0)
  local bOk, tHits = pcall(tWorld.spatial.SphereQuery, tWorld.spatial, Vector3:new(px, py + 0.8, pz),
    c_nScanRadiusM, nFlags, 0, 64)
  if not bOk or type(tHits) ~= "table" then
    return nil
  end
  local nBestD2 = math.huge
  local tBest = nil
  local tSeenEnt = {}
  for _, nEnt in ipairs(tHits) do
    local sName = ResolveEntityResourceName(tWorld, nEnt)
    local tDoorInfo = ClassifySceneryDoor(sName)
    local tGateInfo = tDoorInfo == nil and ClassifyHabitatBoundaryGate(tWorld, nEnt) or nil
    local sKind, sGrant = nil, nil
    local nTargetId = nEnt
    if tDoorInfo ~= nil then
      sKind = tDoorInfo.sKind
    elseif tGateInfo ~= nil then
      sKind = tGateInfo.sKind
      nTargetId = tGateInfo.nEntityID or nEnt
    else
      sKind, sGrant = ClassifyResourceName(sName)
      if sKind == "bin" and s.sActiveProp == nil then
        sKind = nil -- only prompt trash bin when holding an item
      end
    end
    if sKind ~= nil and not tSeenEnt[nTargetId] then
      tSeenEnt[nTargetId] = true
      local bTr, tr = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, nTargetId)
      if bTr and tr ~= nil then
        local vPos = tr.GetPos and tr:GetPos() or tr:Pos()
        local ex, ey, ez = vPos:GetX(), vPos:GetY(), vPos:GetZ()
        local nMaxDY = (sKind == "wide_gate") and 2.4 or 1.4
        if math.abs(ey - py) <= nMaxDY then
          local nYaw = 0
          pcall(function()
            local vYpr = tr:GetOr():ToYawPitchRoll()
            nYaw = vYpr:GetX()
          end)
          local nMaxR = c_tInteractionRange[sKind] or 1.65
          local d2 = NearestInteractionDistSq(sKind, ex, ez, nYaw, px, pz)
          if d2 <= nMaxR * nMaxR then
            -- Only show popup when close right beside the object (<= 0.95 m) or roughly in front of the camera.
            local cdx, cdz = ex - px, ez - pz
            local nCenterDist = math.sqrt(cdx * cdx + cdz * cdz)
            local nCloseR = (sKind == "wide_gate") and 1.8 or 0.95
            local bFacing = nCenterDist <= nCloseR or ((cdx * camFx + cdz * camFz) / nCenterDist) >= -0.05
            if bFacing and d2 < nBestD2 then
              nBestD2 = d2
              local tInt = c_tInteractions[sKind]
              local sLabel = tInt.label
              local tMeta = tDoorInfo or tGateInfo
              if tMeta ~= nil then
                local bIsOpen = s.tOpenDoors ~= nil and s.tOpenDoors[nTargetId] ~= nil and s.tOpenDoors[nTargetId].bOpen == true
                if tMeta.bIsHabitatGate then
                  sLabel = bIsOpen and "Close Gate" or "Open Gate"
                else
                  sLabel = bIsOpen and "Close Door" or "Open Door"
                end
              end
              tBest = {
                kind = sKind,
                label = sLabel,
                nEntityID = nTargetId,
                x = ex, y = ey, z = ez, yaw = nYaw,
                grantProp = sGrant,
                sStyle = tMeta and tMeta.sStyle or nil,
                sMgVar = tMeta and tMeta.sMgVar or nil,
                bIsHabitatGate = tMeta and tMeta.bIsHabitatGate == true or false,
                bAllowAcrylic = tMeta and tMeta.bAllowAcrylic == true or false,
                nHalfW = tMeta and tMeta.nHalfW or nil,
                nHalfDepth = tMeta and tMeta.nHalfDepth or nil,
                nMaxY = tMeta and tMeta.nMaxY or nil,
                nHingeOffset = tMeta and tMeta.nHingeOffset or nil,
                nSlideY = tMeta and tMeta.nSlideY or nil,
              }
            end
          end
        end
      end
    end
  end
  return tBest
end

-- Detects nearby exhibit / aquarium / aviary ONLY when the player has stood idle beside it (never highlights or prompts).
local ScanNearbyViewingKind = function()
  local tPose = Presence.GetOwnPose()
  local tWorld = WorldAPIs()
  local px, py, pz
  if tPose ~= nil then
    px, py, pz = tPose.x, tPose.y, tPose.z
  elseif tWorld.CameraModeManager ~= nil then
    local vPos = tWorld.CameraModeManager:GetPosYPRZoom()
    if vPos ~= nil then
      px, py, pz = vPos:GetX(), vPos:GetY() - 1.55, vPos:GetZ()
    end
  end
  if px == nil or tWorld.spatial == nil or tWorld.spatial.SphereQuery == nil then
    return nil
  end
  local nFlags = (tWorld.spatial.Flag_Exhibit or 0) | (tWorld.spatial.Flag_HabitatBoundary or 0) |
    (tWorld.spatial.Flag_Scenery or 0)
  local bOk, tHits = pcall(tWorld.spatial.SphereQuery, tWorld.spatial, Vector3:new(px, py + 0.8, pz),
    c_nExhibitScanRadiusM, nFlags, 0, 32)
  if not bOk or type(tHits) ~= "table" then
    return nil
  end
  for _, nEnt in ipairs(tHits) do
    local sName = ResolveEntityResourceName(tWorld, nEnt)
    if type(sName) == "string" and sName ~= "" then
      local sLow = string.lower(sName)
      for _, tM in ipairs(c_tViewingMatchers) do
        if string.find(sLow, tM.pat, 1, true) ~= nil then
          return tM.kind
        end
      end
    end
  end
  return nil
end

local ClearExhibitIdle = function(_bNoSend, _nBlendOut)
  if s.sExhibitIdleKind == nil then
    return
  end
  s.sExhibitIdleKind = nil
  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, _nBlendOut or c_nExhibitBlendOut)
  end
  if not _bNoSend then
    SendAction({op = "clear"})
  end
end

-- Called both from UpdateHoverTooltip and from our wrapped FirstPersonInteraction._UpdateTooltip so vanilla
-- never erases our [E] Sit / world-interaction tooltip on the next frame.
local RenderHoverTooltip = function(_uiHUD)
  local tTarget = s.tHovered
  if s.tActiveSeat ~= nil then
    if s.tActiveSeat.phase == "seated" then
      tTarget = {label = "Stand Up", x = s.tActiveSeat.seatX or s.tActiveSeat.x,
        y = s.tActiveSeat.seatY or s.tActiveSeat.y, z = s.tActiveSeat.seatZ or s.tActiveSeat.z}
    else
      -- Hide tooltip cleanly while walking up, sitting down, or standing up.
      tTarget = nil
    end
  end
  if tTarget == nil or s.bWheelOpen then
    return false
  end
  local bShown = false
  pcall(function()
    local tWorld = WorldAPIs()
    local hud = _uiHUD
    if hud == nil then
      local worldScript = api.world.GetScript(api.world.GetActive())
      hud = worldScript and worldScript.GetHUD and worldScript:GetHUD()
    end
    if hud == nil or hud.ShowHelperTooltip == nil or tWorld.camera == nil then
      return
    end
    local nCam = tWorld.camera:GetMainCameraID()
    local vUV = tWorld.camera:GetTopDownScreenUVFromWorldPosition(nCam,
      Vector3:new(tTarget.x, tTarget.y + 0.85, tTarget.z))
    if vUV ~= nil then
      local ux = vUV.GetX and vUV:GetX() or vUV:X()
      local uy = vUV.GetY and vUV:GetY() or vUV:Y()
      if ux >= 0.02 and ux <= 0.98 and uy >= 0.02 and uy <= 0.98 then
        hud:ShowHelperTooltip({
          value = "[STRING_LITERAL:Value=|" .. tTarget.label .. "|]",
          inputName = "GameCamera_EnterVehicle",
          type = "LocString",
          posX = ux,
          posY = uy,
          noAutoHide = true,
          followMouse = false,
        })
        s.bTooltipShown = true
        bShown = true
      end
    end
  end)
  return bShown
end

local UpdateHoverTooltip = function(_tTarget)
  local bSeatedPrompt = s.tActiveSeat ~= nil and s.tActiveSeat.phase == "seated"
  if _tTarget == nil and not bSeatedPrompt then
    ClearHoverVisuals()
    return
  end
  -- Never overwrite a vanilla FirstPersonInteraction target (buggy / habitat gate).
  local bVanillaActive = false
  pcall(function()
    local fpi = WorldAPIs().FirstPersonInteraction
    local tSel = fpi and fpi:GetSelection()
    bVanillaActive = type(tSel) == "table" and tSel.nEntityID ~= nil
  end)
  if bVanillaActive then
    ClearHoverVisuals()
    return
  end
  RenderHoverTooltip(nil)
  pcall(function()
    local tWorld = WorldAPIs()
    local nTargetId = _tTarget and _tTarget.nEntityID or nil
    if nTargetId ~= s.nHighlightId then
      local EditorConfig = require("Editors.Shared.EditorConfig")
      if s.nHighlightId ~= nil then
        tWorld.model:SetHighlighted(s.nHighlightId, EditorConfig.HighlightChannel_Custom, false)
      end
      s.nHighlightId = nTargetId
      if s.nHighlightId ~= nil then
        EditorConfig.SetChannelHighlightSettings(EditorConfig.HighlightChannel_Custom, EditorConfig.Highlight_Hover)
        tWorld.model:SetHighlighted(s.nHighlightId, EditorConfig.HighlightChannel_Custom, true)
      end
    end
  end)
end

-- ---- emote wheel UI state & prompt bar -----------------------------------------------------------
Actions.SetWheelOpen = function(_bOpen)
  local bNext = _bOpen == true
  if s.bWheelOpen ~= bNext then
    s.bWheelOpen = bNext
    s.bWheelDirty = true
    if not bNext then
      -- Hold a short grace period so the click/right-click that closed the wheel never leaks into WalkingCameraUIMode.
      s.nWheelBlockUntil = (s.nClock or 0) + 0.20
    end
    Log("emote wheel " .. (bNext and "opened" or "closed"))
  end
end

Actions.IsWheelOpen = function()
  return s.bWheelOpen == true
end

Actions.IsWheelBlockingInput = function()
  return s.bWheelOpen == true or (s.nClock or 0) < (s.nWheelBlockUntil or 0)
end

Actions.SetWheelPage = function(_nPage)
  local nP = tonumber(_nPage)
  if nP ~= nil and nP >= 1 and nP <= 3 then
    s.nWheelPage = math.floor(nP)
    s.bWheelDirty = true
  end
end

Actions.GetWheelState = function()
  return {
    open = s.bWheelOpen,
    page = s.nWheelPage,
    activeProp = s.sActiveProp,
    activeEmote = s.sActiveLoopEmote,
    seated = s.tActiveSeat ~= nil,
  }
end

Actions.ConsumeWheelDirty = function()
  local bD = s.bWheelDirty
  s.bWheelDirty = false
  return bD
end

local AddEmotePrompt = function()
  local GameDatabase = require("Database.GameDatabase")
  local tEmpty = GameDatabase.GetButtonPromptData("Empty")
  local tWalking = type(tEmpty) == "table" and tEmpty.WalkingCamera
  if type(tWalking) ~= "table" then
    return false
  end
  for _, sList in ipairs({"tMouse", "tGamepad"}) do
    local tList = tWalking[sList]
    if tList ~= nil then
      local bHas = false
      for _, tEntry in ipairs(tList) do
        if tEntry.sLogicalControl == c_tEmotePrompt.sLogicalControl then
          bHas = true
        end
      end
      if not bHas then
        local tEntry = {}
        for k, v in pairs(c_tEmotePrompt) do
          tEntry[k] = v
        end
        table.insert(tList, math.max(1, #tList), tEntry)
      end
    end
  end
  return true
end

-- ---- remote friend action application (trust boundary: whitelists only!) -------------------------
local ApplyFriendAction = function(_tData)
  local tBody = Presence.GetFriendBody()
  local sOp = _tData.op
  if sOp == "prop" then
    local sId = _tData.id
    if sId == "prop_clear" then
      s.sFriendProp = nil
      if tBody ~= nil and tBody.tAnim ~= nil then
        Avatar.DetachProp(tBody.tAnim)
      end
    elseif c_tProps[sId] ~= nil then
      s.sFriendProp = sId
      if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
        local tP = c_tProps[sId]
        Avatar.AttachProp(tBody.tAnim, tBody.nAvatar, tP.prefab, tP.bone)
      end
    end
  elseif sOp == "emote" then
    local tE = c_tEmotes[_tData.id]
    if tE == nil then
      return
    end
    s.tFriendSeat = nil
    Presence.SetFriendSeatOverride(nil)
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      local sClip = (_tData.moving == true and tE.walkClip) or tE.clip
      if tE.loop then
        Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sClip, 0.22)
      else
        Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
        Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, sClip)
      end
    end
  elseif sOp == "sit" then
    local tInt = c_tInteractions[_tData.id]
    if tInt == nil or not tInt.seat or not (IsFinite(_tData.x) and IsFinite(_tData.y) and IsFinite(_tData.z)) then
      return
    end
    local nYaw = IsFinite(_tData.yaw) and (_tData.yaw / 1000) or 0
    local bImmediate = _tData.immediate == true
    local sGroup = tBody ~= nil and tBody.tAnim ~= nil and tBody.tAnim.sGroup or "AM"
    local sx, sy, sz = _tData.x / 100, _tData.y / 100, _tData.z / 100
    s.tFriendSeat = {
      kind = _tData.id,
      phase = bImmediate and "seated" or "entering",
      nPhaseTime = 0,
      x = sx, y = sy, z = sz,
      seatX = sx, seatY = sy, seatZ = sz,
      yaw = nYaw,
      nEnterDur = ClipDuration(tInt.enter, sGroup, 1.80),
      nExitDur = ClipDuration(tInt.exit, sGroup, 1.50),
    }
    Presence.SetFriendSeatOverride(s.tFriendSeat)
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.CancelOneShot(tBody.tAnim, tBody.nAvatar)
      if bImmediate or tInt.enter == nil then
        local sIdle = SeatIdleClip(_tData.id, tBody.tAnim.sGroup, s.sFriendProp, 1)
        Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sIdle, 0.22)
      else
        Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, tInt.enter, 0.18)
      end
    end
  elseif sOp == "interact" then
    local tInt = c_tInteractions[_tData.id]
    if tInt ~= nil and tInt.enter ~= nil and tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, tInt.enter)
    end
  elseif sOp == "exhibit_idle" then
    local tInt = c_tInteractions[_tData.id]
    if tInt ~= nil and tInt.idleWatch and tInt.enter ~= nil and tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, tInt.enter, c_nExhibitBlendIn)
    end
  elseif sOp == "door" then
    if not (IsFinite(_tData.x) and IsFinite(_tData.y) and IsFinite(_tData.z)) then
      return
    end
    local sWireKind = _tData.kind
    if sWireKind ~= "scenery_door" and sWireKind ~= "shutter" and sWireKind ~= "gate" and sWireKind ~= "wide_gate" then
      return
    end
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, "$StandInteractKioskNormalIn")
    end
    pcall(function()
      local tWorld = WorldAPIs()
      local sp = tWorld and tWorld.spatial
      local trApi = tWorld and tWorld.transform
      if sp == nil or sp.SphereQuery == nil or trApi == nil or trApi.CalculateWorldTransform == nil then
        return
      end
      local gx, gy, gz = _tData.x / 100, _tData.y / 100, _tData.z / 100
      local nFlags = (sp.Flag_Scenery or 0) | (sp.Flag_NonStaticScenery or 0) | (sp.Flag_HabitatBoundary or 0)
      local tHits = sp:SphereQuery(Vector3:new(gx, gy + 0.8, gz), 2.6, nFlags, 0, 48)
      if type(tHits) ~= "table" then
        return
      end
      local nBestD2, tBest = 2.6 * 2.6, nil
      for _, nEnt in ipairs(tHits) do
        local sName = ResolveEntityResourceName(tWorld, nEnt)
        local tMeta = (sWireKind == "scenery_door" or sWireKind == "shutter") and ClassifySceneryDoor(sName) or
          ClassifyHabitatBoundaryGate(tWorld, nEnt)
        if tMeta ~= nil then
          local nId = tMeta.nEntityID or nEnt
          if not (Presence.IsAquariumStaffDoorEntity ~= nil and Presence.IsAquariumStaffDoorEntity(nId)) then
            local tr = trApi:CalculateWorldTransform(nId)
            local vPos = tr and (tr.GetPos and tr:GetPos() or tr:Pos())
            if vPos ~= nil then
              local dx, dy, dz = vPos:GetX() - gx, vPos:GetY() - gy, vPos:GetZ() - gz
              local d2 = dx * dx + dy * dy + dz * dz
              if d2 < nBestD2 then
                nBestD2 = d2
                tBest = {
                  kind = tMeta.sKind,
                  nEntityID = nId,
                  x = vPos:GetX(), y = vPos:GetY(), z = vPos:GetZ(),
                  sStyle = tMeta.sStyle,
                  sMgVar = tMeta.sMgVar,
                  bIsHabitatGate = tMeta.bIsHabitatGate == true,
                  bAllowAcrylic = tMeta.bAllowAcrylic == true,
                  nHalfW = tMeta.nHalfW,
                  nHalfDepth = tMeta.nHalfDepth,
                  nMaxY = tMeta.nMaxY,
                  nHingeOffset = tMeta.nHingeOffset,
                  nSlideY = tMeta.nSlideY,
                }
              end
            end
          end
        end
      end
      if tBest ~= nil then
        SetDoorOpenState(tBest, _tData.open == true, true)
      end
    end)
  elseif sOp == "gate" then
    if not (IsFinite(_tData.x) and IsFinite(_tData.y) and IsFinite(_tData.z)) then
      return
    end
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, "$StandInteractKioskNormalIn")
    end
    pcall(function()
      local tWorld = WorldAPIs()
      local attractions = tWorld.attractions
      local fpi = tWorld.FirstPersonInteraction
      if attractions == nil then
        return
      end
      local gx, gy, gz = _tData.x / 100, _tData.y / 100, _tData.z / 100
      local nBestGate, nBestD2 = nil, 4.0 * 4.0
      if fpi ~= nil and type(fpi.tEntities) == "table" and tWorld.transform ~= nil then
        for nEnt, tInfo in pairs(fpi.tEntities) do
          if type(tInfo) == "table" and tInfo.sType == "HabitatGate" then
            local nGateId = tInfo.nParentEntityID or nEnt
            local tr = tWorld.transform:CalculateWorldTransform(nGateId)
            local vPos = tr and (tr.GetPos and tr:GetPos() or tr:Pos())
            if vPos ~= nil then
              local dx, dy, dz = vPos:GetX() - gx, vPos:GetY() - gy, vPos:GetZ() - gz
              local d2 = dx * dx + dy * dy + dz * dz
              if d2 < nBestD2 then
                nBestD2 = d2
                nBestGate = nGateId
              end
            end
          end
        end
      end
      if nBestGate == nil and tWorld.facilities ~= nil and tWorld.facilities.GetAllHabitatsEntityIDs ~= nil and tWorld.transform ~= nil then
        for _, nHabEnt in pairs(tWorld.facilities:GetAllHabitatsEntityIDs() or {}) do
          local tr = tWorld.transform:CalculateWorldTransform(nHabEnt)
          local vPos = tr and (tr.GetPos and tr:GetPos() or tr:Pos())
          if vPos ~= nil then
            local dx, dy, dz = vPos:GetX() - gx, vPos:GetY() - gy, vPos:GetZ() - gz
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 < nBestD2 then
              nBestD2 = d2
              nBestGate = nHabEnt
            end
          end
        end
      end
      if nBestGate ~= nil and not (Presence.IsAquariumStaffDoorEntity ~= nil and Presence.IsAquariumStaffDoorEntity(nBestGate)) then
        if _tData.open == true then
          if s.nRemoteOpenGate ~= nil and s.nRemoteOpenGate ~= nBestGate and attractions.ReleaseHabitatGateOpenRequest ~= nil then
            attractions:ReleaseHabitatGateOpenRequest(s.nRemoteOpenGate)
          end
          s.nRemoteOpenGate = nBestGate
          if Presence.SetOpenGatePos ~= nil then
            Presence.SetOpenGatePos("remote", {x = gx, y = gy, z = gz})
          end
          if Presence.SetRemoteOpenGate ~= nil then
            Presence.SetRemoteOpenGate(nBestGate)
          end
          if attractions.RequestHabitatGateOpen ~= nil then
            attractions:RequestHabitatGateOpen(nBestGate)
          end
        else
          if attractions.ReleaseHabitatGateOpenRequest ~= nil then
            attractions:ReleaseHabitatGateOpenRequest(nBestGate)
          end
          if s.nRemoteOpenGate == nBestGate then
            s.nRemoteOpenGate = nil
          end
          if Presence.SetOpenGatePos ~= nil then
            Presence.SetOpenGatePos("remote", nil)
          end
          if Presence.SetRemoteOpenGate ~= nil then
            Presence.SetRemoteOpenGate(s.nRemoteOpenGate)
          end
        end
      end
    end)
  elseif sOp == "clear" then
    local tOld = s.tFriendSeat
    local tInt = tOld ~= nil and c_tInteractions[tOld.kind] or nil
    if tOld ~= nil and tOld.phase ~= "exiting" and tInt ~= nil and tInt.exit ~= nil and
      tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      tOld.phase = "exiting"
      tOld.nPhaseTime = 0
      tOld.nExitDur = ClipDuration(tInt.exit, tBody.tAnim.sGroup, 1.50)
      Avatar.CancelOneShot(tBody.tAnim, tBody.nAvatar)
      Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, tInt.exit, 0.15)
    else
      s.tFriendSeat = nil
      Presence.SetFriendSeatOverride(nil)
      if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
        Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar, 0.18)
      end
    end
  end
end

-- Late-join sync: whenever Presence sends our 0x12 avatar on peer connect, also transmit persistent prop/seat.
local SyncPersistentState = function()
  if s.sActiveProp ~= nil then
    SendAction({op = "prop", id = s.sActiveProp})
  end
  if s.tActiveSeat ~= nil and (s.tActiveSeat.phase == "seated" or s.tActiveSeat.phase == "entering") then
    SendAction({op = "sit", id = s.tActiveSeat.kind,
      x = Cm(s.tActiveSeat.seatX or s.tActiveSeat.x),
      y = Cm(s.tActiveSeat.seatY or s.tActiveSeat.y),
      z = Cm(s.tActiveSeat.seatZ or s.tActiveSeat.z),
      yaw = math.floor((s.tActiveSeat.seatYaw or s.tActiveSeat.yaw) * 1000 + 0.5),
      immediate = s.tActiveSeat.phase == "seated"})
  end
end

local OnGoToFriendArrival = function()
  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, "$PickedUp_In")
  end
  SendAction({op = "interact", id = "pickedup"})
end

-- ---- module API ----------------------------------------------------------------------------------
Actions.Install = function()
  if s.bInstalled then
    return
  end
  s.bInstalled = true
  Presence.SetActionHooks(SyncPersistentState, OnGoToFriendArrival)
  if Presence.SetWheelOpenCheck ~= nil then
    Presence.SetWheelOpenCheck(Actions.IsWheelOpen, Actions.IsWheelBlockingInput)
  end
  if Presence.SetCustomTooltipProvider ~= nil then
    Presence.SetCustomTooltipProvider(RenderHoverTooltip)
  end
  if Presence.SetClosedDoorCheck ~= nil then
    Presence.SetClosedDoorCheck(HasClosedDoorAt)
  end
  Log("installed")
end

Actions.Uninstall = function()
  RestoreAllDoors()
  ClearHoverVisuals()
  ClearExhibitIdle(true)
  StandUp(true, true)
  Actions.SetWheelOpen(false)
  Presence.SetActionHooks(nil, nil)
  if Presence.SetWheelOpenCheck ~= nil then
    Presence.SetWheelOpenCheck(nil, nil)
  end
  if Presence.SetCustomTooltipProvider ~= nil then
    Presence.SetCustomTooltipProvider(nil)
  end
  if Presence.SetClosedDoorCheck ~= nil then
    Presence.SetClosedDoorCheck(nil)
  end
  s.bInstalled = false
end

Actions.Reset = function()
  RestoreAllDoors()
  ClearHoverVisuals()
  s.bWheelOpen = false
  s.bWheelDirty = true
  s.nWheelBlockUntil = 0
  s.sActiveProp = nil
  s.bAutoUmbrella = false
  s.sActiveLoopEmote = nil
  s.sExhibitIdleKind = nil
  s.nExhibitIdleTimer = 0
  s.tActiveSeat = nil
  s.sFriendProp = nil
  s.tFriendSeat = nil
  s.tHovered = nil
  s.bPromptAdded = false
  s.tPopFx = {}
  s.tOpenDoors = {}
end

Actions.Update = function(_nDt, _bActive)
  if not s.bInstalled then
    return
  end
  s.nClock = (s.nClock or 0) + (_nDt or 0)
  StepAnimatedDoors(_nDt)

  -- Clean up temporary balloon-pop VFX entities.
  for i = #s.tPopFx, 1, -1 do
    if s.nClock >= s.tPopFx[i].nUntil then
      pcall(api.entity.DestroyEntity, s.tPopFx[i].nId)
      table.remove(s.tPopFx, i)
    end
  end

  if not s.bPromptAdded then
    local bOk, bAdded = pcall(AddEmotePrompt)
    s.bPromptAdded = bOk and bAdded == true
  end

  local bOnFoot = CurrentUIMode() == "WalkingCamera"
  local bVehiclePass = false
  pcall(function()
    local Vehicles = require("PZ2Coop.Vehicles")
    bVehiclePass = Vehicles ~= nil and Vehicles.IsLocalPassenger ~= nil and Vehicles.IsLocalPassenger() == true
  end)
  if not bOnFoot then
    if not bVehiclePass and s.bWheelOpen then
      Actions.SetWheelOpen(false)
    end
    ClearHoverVisuals()
    s.nExhibitIdleTimer = 0
    ClearExhibitIdle(false)
    if s.tActiveSeat ~= nil then
      StandUp(false, true)
    end
    -- Allow passengers in seats 2..4 to open the Emote Wheel (B / L3) and equip held props while riding!
    if bVehiclePass then
      local tOwnPass = Presence.GetOwnBody()
      if tOwnPass ~= nil and tOwnPass.tAnim ~= nil and tOwnPass.nAvatar ~= nil and s.sActiveProp ~= nil and tOwnPass.tAnim.tProp == nil then
        local tP = c_tProps[s.sActiveProp]
        if tP ~= nil then
          Avatar.AttachProp(tOwnPass.tAnim, tOwnPass.nAvatar, tP.prefab, tP.bone)
        end
      end
      local inpPass = WorldAPIs().InputManager
      if inpPass ~= nil then
        local bKeyB, bPressedB = pcall(inpPass.GetKeyPressed, inpPass, "ToggleAlignToSuggestions")
        local bPadL3, bPressedL3 = pcall(inpPass.GetGamepadButtonDown, inpPass, "Gamepad_LeftStickPress")
        if (bKeyB and bPressedB) or (bPadL3 and bPressedL3) then
          Actions.SetWheelOpen(not s.bWheelOpen)
        end
      end
    end
    StepFriendSeat(_nDt)
    return
  end

  -- Re-attach held props once avatar entity finishes spawning asynchronously.
  local tOwn = Presence.GetOwnBody()
  if tOwn ~= nil and tOwn.tAnim ~= nil and tOwn.nAvatar ~= nil and s.sActiveProp ~= nil and tOwn.tAnim.tProp == nil then
    local tP = c_tProps[s.sActiveProp]
    if tP ~= nil then
      Avatar.AttachProp(tOwn.tAnim, tOwn.nAvatar, tP.prefab, tP.bone)
    end
  end
  local tFriendBody = Presence.GetFriendBody()
  if tFriendBody ~= nil and tFriendBody.tAnim ~= nil and tFriendBody.nAvatar ~= nil and
    s.sFriendProp ~= nil and tFriendBody.tAnim.tProp == nil then
    local tP = c_tProps[s.sFriendProp]
    if tP ~= nil then
      Avatar.AttachProp(tFriendBody.tAnim, tFriendBody.nAvatar, tP.prefab, tP.bone)
    end
  end

  -- Input checks (keys MUST exist in components.input.keyinput.lua tButtons):
  --   ToggleAlignToSuggestions = B (keyboard), Gamepad_LeftStickPress = L3 (gamepad) -> toggle Emote Wheel
  --   WASD / ToggleRotationSnap (Space) -> cancel seated/loop emotes (triggers full stand-up animation when seated)
  --   GameCamera_EnterVehicle = E -> trigger hovered world interaction / stand up
  local inp = WorldAPIs().InputManager
  local bMoved = false
  local bActionPressed = false
  if inp ~= nil then
    local bKeyB, bPressedB = pcall(inp.GetKeyPressed, inp, "ToggleAlignToSuggestions")
    local bPadL3, bPressedL3 = pcall(inp.GetGamepadButtonDown, inp, "Gamepad_LeftStickPress")
    if (bKeyB and bPressedB) or (bPadL3 and bPressedL3) then
      Actions.SetWheelOpen(not s.bWheelOpen)
    end

    if not s.bWheelOpen then
      local bOkMove, bMoveNow = pcall(function()
        return (inp.GetKeyDown and (inp:GetKeyDown("GameCamera_Forward") or inp:GetKeyDown("GameCamera_Backward") or
          inp:GetKeyDown("GameCamera_Left") or inp:GetKeyDown("GameCamera_Right"))) or
          (inp.GetKeyPressed and inp:GetKeyPressed("ToggleRotationSnap"))
      end)
      bMoved = bOkMove and bMoveNow == true
      if bMoved then
        if s.sExhibitIdleKind ~= nil then
          s.nExhibitIdleTimer = 0
          ClearExhibitIdle(false, c_nExhibitBlendOut)
        end
        if s.sActiveLoopEmote ~= nil and tOwn ~= nil and tOwn.tAnim ~= nil then
          s.sActiveLoopEmote = nil
          Avatar.ClearBaseOverride(tOwn.tAnim, tOwn.nAvatar, c_nExhibitBlendOut)
          SendAction({op = "clear"})
        end
      end

      local bOkE, bPressedE = pcall(inp.GetKeyPressed, inp, "GameCamera_EnterVehicle")
      local bVanillaSel = false
      local bClickUse = false
      pcall(function()
        local fpi = WorldAPIs().FirstPersonInteraction
        local tSel = fpi and fpi:GetSelection()
        bVanillaSel = type(tSel) == "table" and tSel.nEntityID ~= nil
        local tM = inp.GetMouseInput and inp:GetMouseInput()
        if not bVanillaSel and tM ~= nil and tM.Button == "mouseleft" and tM.Action == "click" then
          bClickUse = true
        end
      end)
      bActionPressed = (bOkE and bPressedE and not bVanillaSel) or bClickUse
      if bActionPressed and s.tActiveSeat == nil and s.tHovered ~= nil then
        Actions.TriggerInteraction(s.tHovered)
        bActionPressed = false -- consume E/click so it never doubles into StepOwnSeat on the start frame
      end
    end
  end

  -- Advance 4-phase sitting choreography (walk-up -> sit-down -> seated idle -> stand-up) for own & friend avatars.
  StepOwnSeat(_nDt, bMoved, bActionPressed)
  StepFriendSeat(_nDt)

  -- Exhibit/aquarium/aviary watching animations ONLY play after the player genuinely goes idle beside them.
  local bCanExhibitIdle = not bMoved and tOwn ~= nil and tOwn.tAnim ~= nil and tOwn.nAvatar ~= nil and
    tOwn.tAnim.sState == "idle" and (tOwn.tAnim.nSmoothSpeed or 0) < 0.15 and
    s.tActiveSeat == nil and s.sActiveLoopEmote == nil
  if bCanExhibitIdle then
    s.nExhibitIdleTimer = (s.nExhibitIdleTimer or 0) + (_nDt or 0)
    if s.sExhibitIdleKind == nil and s.nExhibitIdleTimer >= c_nExhibitIdleDelay then
      local sViewKind = ScanNearbyViewingKind()
      local tInt = sViewKind and c_tInteractions[sViewKind]
      if tInt ~= nil and tInt.idleWatch and tInt.enter ~= nil then
        s.sExhibitIdleKind = sViewKind
        Avatar.SetBaseOverride(tOwn.tAnim, tOwn.nAvatar, tInt.enter, c_nExhibitBlendIn)
        SendAction({op = "exhibit_idle", id = sViewKind})
        Log("entered idle viewing animation " .. sViewKind)
      else
        -- Re-check gently once per second if still idle without re-scanning every frame.
        s.nExhibitIdleTimer = c_nExhibitIdleDelay - 1.0
      end
    end
  else
    s.nExhibitIdleTimer = 0
    if s.sExhibitIdleKind ~= nil then
      ClearExhibitIdle(false, c_nExhibitBlendOut)
    end
  end

  -- Proximity scanner for world object interactions (refresh tooltip UV smoothly every frame while hovered).
  s.nScanTimer = (s.nScanTimer or 0) + (_nDt or 0)
  if s.nScanTimer >= c_nScanInterval then
    s.nScanTimer = 0
    s.tHovered = ScanNearbyInteraction()
  end
  UpdateHoverTooltip(s.tHovered)
end

Actions.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nActionPacket or type(_tMsg.tData) ~= "table" or _tMsg.tData.k ~= "action" then
    return false
  end
  local bOk, sErr = pcall(ApplyFriendAction, _tMsg.tData)
  if not bOk then
    Log("friend action error: " .. tostring(sErr))
  end
  return true
end

Actions.GetCatalog = function()
  return c_tEmotes, c_tProps, c_tInteractions
end
