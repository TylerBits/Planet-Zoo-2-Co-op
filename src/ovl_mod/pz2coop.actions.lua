-- Player NPC activities, Radial Emote Wheel, world object interactions, carried props, and co-op pair actions
-- (docs/PLAYER_NPC_ACTIVITIES_PLAN.md).
--   Pillar A: 3-page x 8-wedge Radial Emote Wheel (Social, Reactions, Props) triggered on foot via B / L3.
--   Pillar B: Proximity world interactions (Benches w/ 2 co-op seats, Picnic/Restaurant tables, Photo Boards,
--             Education Stations, Shops/Kiosks, Vending Machines, ATMs, Trash Bins, Restrooms, Donation Boxes,
--             Exhibit/Aquarium/Aviary reactions, Viewing Domes, Transport Rides) with native floating tooltip.
--   Pillar C: Hand-bone prop attachment (Main_SmallResources.ovl), auto-umbrella in rain/snow, balloon pop gag,
--             co-op Hold Hands walk pairing, and playful PickedUp Go-to-Friend arrival.
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
local pcall = global.pcall
local rawget = global.rawget
local rawset = global.rawset
local require = global.require
local Vector3 = require("Vector3")
local Bridge = require("PZ2Coop.Bridge")
local Avatar = require("PZ2Coop.Avatar")
local Presence = require("PZ2Coop.Presence")

local Actions = module(...)

local c_nActionPacket = 0x12
local c_nScanInterval = 0.2 -- 5 Hz proximity scanner
local c_nScanRadiusM = 3.2
local c_nExhibitIdleDelay = 4.5 -- seconds standing completely idle near an exhibit before smoothly watching it
local c_nExhibitBlendIn = 0.45 -- smooth crossfade into exhibit watching idle
local c_nExhibitBlendOut = 0.16 -- snappy crossfade out when moving away
local c_nHoldHandsRangeM = 1.2
local c_nHoldHandsOffsetM = 0.65
local c_nBenchSeatOffsetM = 0.45

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
  bench      = {label = "Sit",           enter = "$SitBenchIn",          idle = "$SitBenchIdle",     teenIdle = "$SitBenchIdle01", exit = "$SitBenchOut",   seat = true,  eyeHeight = 1.15},
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
  holdhands  = {label = "Hold Hands",    pair = true},
  pickedup   = {label = "Drop In",       enter = "$PickedUp_In",         loop = false},
}

-- Resource-name pattern matchers for placed park scenery / facilities (lowercase substring match).
local c_tObjectMatchers = {
  {pat = "picnic",       kind = "picnic"},
  {pat = "bench",        kind = "bench"},
  {pat = "restaurant",   kind = "restaurant"},
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

local c_tEmotePrompt = {sLocString = "[STRING_LITERAL:Value=|Emotes|]", sLogicalControl = "Editors_ToggleAlignToSuggestions",
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
    bHoldingHands = false,
    bFriendHoldingHands = false,
    sFriendProp = nil,
    tFriendSeat = nil,
    nScanTimer = 0,
    tHovered = nil, -- {kind, label, nEntityID, x, y, z, yaw, grantProp}
    nHighlightId = nil,
    bTooltipShown = false,
    bPromptAdded = false,
    tPopFx = {}, -- temporary pop VFX entities {nId, nUntil}
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

local SeatIdleClip = function(_sKind, _sGroup, _sPropId)
  local tInt = c_tInteractions[_sKind]
  if tInt == nil then
    return "$SitBenchIdle"
  end
  if _sKind == "picnic" then
    return PicnicClipForProp(_sPropId)
  end
  if _sKind == "bench" and (_sGroup == "TF" or _sGroup == "TM") and tInt.teenIdle ~= nil then
    return tInt.teenIdle
  end
  return tInt.idle or "$SitBenchIdle"
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
      if s.tActiveSeat == nil and s.sActiveLoopEmote == nil and not s.bHoldingHands then
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

local StandUp = function(_bNoSend)
  if s.tActiveSeat == nil then
    return
  end
  local tInt = c_tInteractions[s.tActiveSeat.kind]
  s.tActiveSeat = nil
  Presence.SetSeatOverride(nil)
  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
    if tInt ~= nil and tInt.exit ~= nil then
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, tInt.exit)
    end
  end
  if not _bNoSend then
    SendAction({op = "clear"})
  end
end

local StopHoldHands = function(_bNoSend)
  if not s.bHoldingHands then
    return
  end
  s.bHoldingHands = false
  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
  end
  if not _bNoSend then
    SendAction({op = "holdhands", on = false})
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
  StandUp(false)
  StopHoldHands(false)
  s.sExhibitIdleKind = nil
  s.nExhibitIdleTimer = 0
  local tBody = Presence.GetOwnBody()
  local bMoving = tBody ~= nil and tBody.tAnim ~= nil and (tBody.tAnim.nSmoothSpeed or 0) >= 0.35
  local sClip = (bMoving and tE.walkClip) or tE.clip
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    if tE.loop then
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

Actions.StartSeat = function(_sKind, _nX, _nY, _nZ, _nYaw)
  local tInt = c_tInteractions[_sKind]
  if tInt == nil or not tInt.seat then
    return false
  end
  StopHoldHands(false)
  s.sActiveLoopEmote = nil
  s.sExhibitIdleKind = nil
  s.nExhibitIdleTimer = 0
  local nSeatX, nSeatY, nSeatZ = _nX, _nY, _nZ
  local nSlot = 0
  -- 2-seat bench support: if friend is already sitting near slot 0, take slot 1 side-by-side!
  if _sKind == "bench" then
    local rx, rz = math.cos(_nYaw), -math.sin(_nYaw)
    local x0, z0 = _nX - rx * c_nBenchSeatOffsetM, _nZ - rz * c_nBenchSeatOffsetM
    local x1, z1 = _nX + rx * c_nBenchSeatOffsetM, _nZ + rz * c_nBenchSeatOffsetM
    if s.tFriendSeat ~= nil then
      local d0 = (s.tFriendSeat.x - x0) ^ 2 + (s.tFriendSeat.z - z0) ^ 2
      if d0 < 0.36 then
        nSlot = 1
      end
    end
    nSeatX, nSeatZ = (nSlot == 1) and x1 or x0, (nSlot == 1) and z1 or z0
  end
  s.tActiveSeat = {kind = _sKind, x = nSeatX, y = nSeatY, z = nSeatZ, yaw = _nYaw,
    eyeHeight = tInt.eyeHeight or 1.15, slot = nSlot}
  Presence.SetSeatOverride(s.tActiveSeat)
  local tBody = Presence.GetOwnBody()
  if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
    local sIdle = SeatIdleClip(_sKind, tBody.tAnim.sGroup, s.sActiveProp)
    Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sIdle, 0.25)
    if tInt.enter ~= nil then
      Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, tInt.enter)
    end
  end
  SendAction({op = "sit", id = _sKind, x = Cm(nSeatX), y = Cm(nSeatY), z = Cm(nSeatZ),
    yaw = math.floor(_nYaw * 1000 + 0.5)})
  Log("seated at " .. _sKind .. " (slot " .. nSlot .. ")")
  return true
end

Actions.TriggerInteraction = function(_tTarget)
  if type(_tTarget) ~= "table" then
    return false
  end
  local tInt = c_tInteractions[_tTarget.kind]
  if tInt == nil then
    return false
  end
  if tInt.pair then
    if s.bHoldingHands then
      StopHoldHands(false)
    else
      StandUp(false)
      s.bHoldingHands = true
      SendAction({op = "holdhands", on = true})
      Log("started holding hands with friend")
    end
    return true
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
local ClearHoverVisuals = function()
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
      return tM.kind, tM.grantProp
    end
  end
  return nil, nil
end

local ScanNearbyInteraction = function()
  if s.tActiveSeat ~= nil then
    return nil
  end
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
  if px == nil then
    return nil
  end

  -- Check co-op friend proximity first for Hold Hands pair action.
  local tFriend = Presence.GetFriendPose()
  if tFriend ~= nil and (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    local fx, fy, fz = tFriend.x or tFriend.px, tFriend.y or tFriend.py, tFriend.z or tFriend.pz
    if fx ~= nil then
      local dx, dz = fx - px, fz - pz
      if dx * dx + dz * dz <= c_nHoldHandsRangeM * c_nHoldHandsRangeM then
        return {
          kind = "holdhands",
          label = s.bHoldingHands and "Let Go" or "Hold Hands",
          x = fx, y = (fy or py) + 1.0, z = fz, yaw = tFriend.yaw or 0,
        }
      end
    end
  end

  if tWorld.spatial == nil or tWorld.spatial.SphereQuery == nil then
    return nil
  end
  local nFlags = tWorld.spatial.Flag_Scenery or 0
  local bOk, tHits = pcall(tWorld.spatial.SphereQuery, tWorld.spatial, Vector3:new(px, py + 0.8, pz),
    c_nScanRadiusM, nFlags, 0, 32)
  if not bOk or type(tHits) ~= "table" then
    return nil
  end
  local nBestD2 = math.huge
  local tBest = nil
  for _, nEnt in ipairs(tHits) do
    local bRes, sName = pcall(function()
      if tWorld.placement ~= nil and tWorld.placement.GetPartResourceName ~= nil then
        return tWorld.placement:GetPartResourceName(nEnt)
      end
      return nil
    end)
    local sKind, sGrant = bRes and ClassifyResourceName(sName) or nil, nil
    if sKind ~= nil then
      if sKind == "bin" and s.sActiveProp == nil then
        sKind = nil -- only prompt trash bin when holding an item
      end
    end
    if sKind ~= nil then
      local bTr, tr = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, nEnt)
      if bTr and tr ~= nil then
        local vPos = tr.GetPos and tr:GetPos() or tr:Pos()
        local ex, ey, ez = vPos:GetX(), vPos:GetY(), vPos:GetZ()
        local d2 = (ex - px) ^ 2 + (ez - pz) ^ 2
        if d2 < nBestD2 then
          local nYaw = 0
          pcall(function()
            local vYpr = tr:GetOr():ToYawPitchRoll()
            nYaw = vYpr:GetX()
          end)
          nBestD2 = d2
          local tInt = c_tInteractions[sKind]
          tBest = {kind = sKind, label = tInt.label, nEntityID = nEnt, x = ex, y = ey, z = ez, yaw = nYaw,
            grantProp = sGrant}
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
    c_nScanRadiusM, nFlags, 0, 32)
  if not bOk or type(tHits) ~= "table" then
    return nil
  end
  for _, nEnt in ipairs(tHits) do
    local bRes, sName = pcall(function()
      if tWorld.placement ~= nil and tWorld.placement.GetPartResourceName ~= nil then
        return tWorld.placement:GetPartResourceName(nEnt)
      end
      return nil
    end)
    if bRes and type(sName) == "string" and sName ~= "" then
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

local UpdateHoverTooltip = function(_tTarget)
  if _tTarget == nil then
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
  pcall(function()
    local tWorld = WorldAPIs()
    local worldScript = api.world.GetScript(api.world.GetActive())
    local hud = worldScript and worldScript.GetHUD and worldScript:GetHUD()
    if hud == nil or hud.ShowHelperTooltip == nil or tWorld.camera == nil then
      return
    end
    local nCam = tWorld.camera:GetMainCameraID()
    local vUV = tWorld.camera:GetTopDownScreenUVFromWorldPosition(nCam,
      Vector3:new(_tTarget.x, _tTarget.y + 0.8, _tTarget.z))
    if vUV ~= nil then
      hud:ShowHelperTooltip({
        value = "[STRING_LITERAL:Value=|" .. _tTarget.label .. "|]",
        inputName = "GameCamera_EnterVehicle",
        type = "LocString",
        posX = vUV:X(),
        posY = vUV:Y(),
        noAutoHide = true,
        followMouse = false,
      })
      s.bTooltipShown = true
    end
    if _tTarget.nEntityID ~= s.nHighlightId then
      local EditorConfig = require("Editors.Shared.EditorConfig")
      if s.nHighlightId ~= nil then
        tWorld.model:SetHighlighted(s.nHighlightId, EditorConfig.HighlightChannel_Custom, false)
      end
      s.nHighlightId = _tTarget.nEntityID
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
    holdingHands = s.bHoldingHands,
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
    s.tFriendSeat = {kind = _tData.id, x = _tData.x / 100, y = _tData.y / 100, z = _tData.z / 100, yaw = nYaw}
    Presence.SetFriendSeatOverride(s.tFriendSeat)
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      local sIdle = SeatIdleClip(_tData.id, tBody.tAnim.sGroup, s.sFriendProp)
      Avatar.SetBaseOverride(tBody.tAnim, tBody.nAvatar, sIdle, 0.25)
      if tInt.enter ~= nil then
        Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, tInt.enter)
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
  elseif sOp == "holdhands" then
    s.bFriendHoldingHands = _tData.on == true
    if not s.bFriendHoldingHands and tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
    end
  elseif sOp == "clear" then
    local tOld = s.tFriendSeat
    s.tFriendSeat = nil
    Presence.SetFriendSeatOverride(nil)
    if tBody ~= nil and tBody.tAnim ~= nil and tBody.nAvatar ~= nil then
      Avatar.ClearBaseOverride(tBody.tAnim, tBody.nAvatar)
      if tOld ~= nil and c_tInteractions[tOld.kind] and c_tInteractions[tOld.kind].exit then
        Avatar.PlayOneShot(tBody.tAnim, tBody.nAvatar, c_tInteractions[tOld.kind].exit)
      end
    end
  end
end

-- Late-join sync: whenever Presence sends our 0x12 avatar on peer connect, also transmit persistent prop/seat.
local SyncPersistentState = function()
  if s.sActiveProp ~= nil then
    SendAction({op = "prop", id = s.sActiveProp})
  end
  if s.tActiveSeat ~= nil then
    SendAction({op = "sit", id = s.tActiveSeat.kind, x = Cm(s.tActiveSeat.x), y = Cm(s.tActiveSeat.y),
      z = Cm(s.tActiveSeat.z), yaw = math.floor(s.tActiveSeat.yaw * 1000 + 0.5)})
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
  Log("installed")
end

Actions.Uninstall = function()
  ClearHoverVisuals()
  ClearExhibitIdle(true)
  StandUp(true)
  StopHoldHands(true)
  Actions.SetWheelOpen(false)
  Presence.SetActionHooks(nil, nil)
  if Presence.SetWheelOpenCheck ~= nil then
    Presence.SetWheelOpenCheck(nil, nil)
  end
  s.bInstalled = false
end

Actions.Reset = function()
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
  s.bHoldingHands = false
  s.bFriendHoldingHands = false
  s.sFriendProp = nil
  s.tFriendSeat = nil
  s.tHovered = nil
  s.bPromptAdded = false
  s.tPopFx = {}
end

Actions.Update = function(_nDt, _bActive)
  if not s.bInstalled then
    return
  end
  s.nClock = (s.nClock or 0) + (_nDt or 0)

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
  if not bOnFoot then
    if s.bWheelOpen then
      Actions.SetWheelOpen(false)
    end
    ClearHoverVisuals()
    s.nExhibitIdleTimer = 0
    ClearExhibitIdle(false)
    if s.tActiveSeat ~= nil then
      StandUp(false)
    end
    if s.bHoldingHands then
      StopHoldHands(false)
    end
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
  --   WASD / ToggleRotationSnap (Space) -> cancel seated/loop emotes
  --   GameCamera_EnterVehicle = E -> trigger hovered world interaction / stand up
  local inp = WorldAPIs().InputManager
  local bMoved = false
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
        if s.tActiveSeat ~= nil then
          StandUp(false)
        end
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
      if bOkE and bPressedE then
        if s.tActiveSeat ~= nil then
          StandUp(false)
        elseif s.tHovered ~= nil then
          Actions.TriggerInteraction(s.tHovered)
        end
      end
    end
  end

  -- Exhibit/aquarium/aviary watching animations ONLY play after the player genuinely goes idle beside them.
  local bCanExhibitIdle = not bMoved and tOwn ~= nil and tOwn.tAnim ~= nil and tOwn.nAvatar ~= nil and
    tOwn.tAnim.sState == "idle" and (tOwn.tAnim.nSmoothSpeed or 0) < 0.15 and
    s.tActiveSeat == nil and s.sActiveLoopEmote == nil and not s.bHoldingHands
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

  -- Co-op Hold Hands pair walk animation while tethered near friend.
  if s.bHoldingHands then
    local tF = Presence.GetFriendPose()
    if tF == nil then
      StopHoldHands(false)
    elseif tOwn ~= nil and tOwn.tAnim ~= nil and tOwn.nAvatar ~= nil then
      local sFriendGroup = (tFriendBody and tFriendBody.tAnim and tFriendBody.tAnim.sGroup) or "AM"
      local sClip = "$WalkRightHoldHandsWith" .. sFriendGroup
      Avatar.SetBaseOverride(tOwn.tAnim, tOwn.nAvatar, sClip, 0.25)
    end
  end

  -- 5 Hz proximity scanner for world object interactions.
  s.nScanTimer = (s.nScanTimer or 0) + (_nDt or 0)
  if s.nScanTimer >= c_nScanInterval then
    s.nScanTimer = 0
    s.tHovered = ScanNearbyInteraction()
    UpdateHoverTooltip(s.tHovered)
  end
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
