"""Offline smoke test for AAA locomotion polish (pz2coop.avatar.lua) and player NPC activities (pz2coop.actions.lua).

Verifies:
  1) Asymmetric crossfade blends (Start 0.14s, Gait 0.24s, Stop 0.34s, Swim 0.35s).
  2) Living idle cycling (StandBaseIdle01 -> 02 -> 03), sprint fatigue (>10s sprint -> StandTiredIdle01),
     weather posture (Rain -> StandWet / WalkWetBase), 180-deg pivot one-shot, and procedural banking/pitch lean.
  3) Radial Emote Wheel state, whitelisted emotes (Cheer, Groove loop), move-cancel, and prop attachment + balloon pop.
  4) World object sitting (2-seat co-op bench auto-picks slot 1 when friend sits in slot 0!), picnic prop-aware clip,
     and auto-umbrella in rain.
  5) Multiplayer 0x12 action sync (trust boundary rejects unwhitelisted emote/prop/interaction IDs).
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.Bridge": (ROOT / "src" / "ovl_mod" / "pz2coop.bridge.lua").read_text(encoding="utf-8"),
    "PZ2Coop.Avatar": (ROOT / "src" / "ovl_mod" / "pz2coop.avatar.lua").read_text(encoding="utf-8"),
    "PZ2Coop.Presence": (ROOT / "src" / "ovl_mod" / "pz2coop.presence.lua").read_text(encoding="utf-8"),
    "PZ2Coop.Actions": (ROOT / "src" / "ovl_mod" / "pz2coop.actions.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, calls, packets = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end,
          X = function() return x end, Y = function() return y end, Z = function() return z end}
end
local nextId = 500
local uiMode = "WalkingCamera"
local currentWeather = 1
local bPressedB = false
local bMoveKeyDown = false
local nearbySpatialHits = {}
local partResourceNames = {}
local entityPosMap = {}
local playerPos = {10, 0, 10}
local playerYaw = 0
local tWorldAPIs = {
  ModeHelperComponent = {GetCurrentModeName = function() return uiMode end},
  InputManager = {
    GetKeyPressed = function(_, s) return bPressedB and s == "ToggleAlignToSuggestions" end,
    GetKeyDown = function(_, s) return bMoveKeyDown and s == "GameCamera_Forward" end,
    GetGamepadButtonDown = function() return false end,
    GetMouseInput = function() return {RawZAxis = 0} end,
  },
  weather = {
    WeatherType_TemperateSun = 1,
    WeatherType_Rain = 2,
    WeatherType_Snow = 3,
    WeatherType_HotSun = 4,
    GetCurrentWeatherTypeForUI = function() return currentWeather end,
  },
  bakedanimation = {RequestAllBonesForCalculate = function(_, id) call("RequestAllBones", id) end},
  gameterrain = {FindLakesWithSphereCheck = function() return {} end, GetLakeSurfaceLevel = function() return nil end},
  model = {SetHidden = function() end, SetHighlighted = function(_, id, ch, b) call("Highlight", id, b) end},
  spatial = {Flag_Scenery = 1, Flag_Exhibit = 2, Flag_HabitatBoundary = 4, SphereQuery = function() return nearbySpatialHits end},
  placement = {GetPartResourceName = function(_, id) return partResourceNames[id] end},
  transform = {HasTransform = function() return true end, SetTransform = function() end, SetPosition = function() end,
    CalculateWorldTransform = function(_, id)
      local p = entityPosMap[id] or {10, 0, 11, 0}
      return {
        GetPos = function() return vec(p[1], p[2], p[3]) end,
        GetOr = function() return {ToYawPitchRoll = function() return vec(p[4] or 0, 0, 0) end} end,
      }
    end},
  CameraModeManager = {
    GetCurrentModeName = function() return "Walking" end,
    GetPosYPRZoom = function() return vec(playerPos[1], playerPos[2] + 1.55, playerPos[3]), vec(playerYaw, 0, 0), 1 end,
    GetVoxelTerrainID = function() return 1 end,
    RequestMode = function(_, m, t) call("RequestMode", m, t) end,
  },
  billboardwidgets = {WidgetType_WidgetLabel = 7},
}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end, GetActive = function() return 1 end,
    GetScript = function() return {tEnvironment = {RequireInterface = function() return {
      SetBillboardWidgetUIInfo = function() end, SetBillboardWidgetData = function() end, ClearBillboardWidgetData = function() end,
    } end}, GetHUD = function() return {ShowHelperTooltip = function() end, HideHelperTooltip = function() end} end} end},
  entity = {
    CreateRequestCompletionToken = function() return {} end,
    HaveRequestsCompleted = function() return true end,
    InstantiatePrefab = function(p, name, tok, tr, parent, b, props)
      nextId = nextId + 1
      call("Spawn", p, name, parent, props)
      return nextId
    end,
    DestroyEntity = function(id) call("Destroy", id) end,
  },
  animationcontrol = {
    SetBaseAnimation = function(id, clip, rate, wait, blend, skip)
      call("SetBaseAnimation", id, clip, rate, blend)
    end,
    SetPlaybackRate = function(id, rate) call("SetPlaybackRate", id, rate) end,
    QueueOneShotAnimation = function(id, clip) call("QueueOneShot", id, clip) end,
    ClearOneShotQueueAndForceStopOneShot = function(id) call("CancelOneShot", id) end,
  },
  json = {Stringify = function() return true, "{}" end, Parse = function() return true, {} end},
  time = {GetTotalTimeUnscaled = function() return 1 end},
}
local Bridge = {
  Log = function(s) table.insert(log, s) end,
  GetRole = function() return "host" end,
  IsPeerConnected = function() return true end,
  IsLoopback = function() return false end,
  GetSession = function() return {sPartner = "Friend", sPartnerId = "99"} end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}
local promptData = {Empty = {WalkingCamera = {tMouse = {}, tGamepad = {}}}}
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {Identity = {WithPos = function(_, v) return {pos = v} end}, FromOrPos = function(q, v) return {q = q, v = v} end},
  Quaternion = {Identity = {}, FromYawPitchRoll = function(v) return v end},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Shared.BaseUIMode"] = {GetModeHelperEntity = function() return 1 end, SetNewMode = function() end},
  ["Editors.Shared.EditorConfig"] = {HighlightChannel_Custom = 1, Highlight_Hover = 2, SetChannelHighlightSettings = function() end},
  ["Database.GameDatabase"] = {GetButtonPromptData = function(k) return promptData[k] end},
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
local Avatar = require("PZ2Coop.Avatar")
local Presence = require("PZ2Coop.Presence")
local Actions = require("PZ2Coop.Actions")
"""

CHECKS = r"""
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function lastCall(name) local r = nil for _, c in ipairs(calls) do if c.name == name then r = c end end return r end

-- 1) Asymmetric crossfade blends
assert(math.abs(Avatar.PickBlendTime("idle", "walk") - 0.14) < 0.001, "start blend should be 0.14s")
assert(math.abs(Avatar.PickBlendTime("walk", "run") - 0.24) < 0.001, "gait blend should be 0.24s")
assert(math.abs(Avatar.PickBlendTime("run", "idle") - 0.20) < 0.001, "stop blend should be 0.20s")
assert(math.abs(Avatar.PickBlendTime("walk", "swim") - 0.35) < 0.001, "swim blend should be 0.35s")

-- 2) Living idles, sprint fatigue, weather posture, 180-deg pivot, procedural lean
local anim = Avatar.CreateAnimState("TMA", true)
-- Sprint for 11 seconds -> stop -> tired idle!
for _ = 1, 110 do Avatar.UpdateAnimation(anim, 77, 5.5, 0.1, false, "clear") end
assert(anim.sState == "run" and anim.nSprintAccum >= 10.0)
for _ = 1, 15 do Avatar.UpdateAnimation(anim, 77, 0.0, 0.1, false, "clear") end
assert(anim.sState == "idle" and string.find(anim.sClip, "StandTiredIdle", 1, true), "expected tired idle, got " .. anim.sClip)

-- Weather rain switches idle -> StandWet and walk -> WalkWetBase
anim.nTiredRemain = 0
Avatar.UpdateAnimation(anim, 77, 0.0, 0.1, false, "rain")
assert(anim.sClip == "TM$StandWet", "expected rain idle TM$StandWet, got " .. anim.sClip)
for _ = 1, 10 do Avatar.UpdateAnimation(anim, 77, 2.0, 0.1, false, "rain") end
assert(anim.sClip == "TM$WalkWetBase", "expected rain walk TM$WalkWetBase, got " .. anim.sClip)

-- 180-deg pivot one-shot
calls = {}
assert(Avatar.TriggerPivot180(anim, 77, true) == true)
assert(lastCall("QueueOneShot").args[2] == "TM$WalkReactTurn180_L", "expected left 180 turn clip")
-- Cooldown prevents immediate double trigger
assert(Avatar.TriggerPivot180(anim, 77, false) == false)

-- Procedural corner banking, hill slope lean & swim forward pitch
local pitch, roll = Avatar.StepBodyLean(anim, 2.0, 5.0, 0.05, false, 0.25)
assert(roll < 0, "turning left/positive yaw rate should bank right/negative roll")
assert(pitch > 0, "uphill slope should pitch character forward")
local spitch, _ = Avatar.StepBodyLean(anim, 0, 2.0, 0.1, true, 0)
assert(spitch > 0, "swimming forward should pitch torso forward")

-- 3) Actions: wire fake own + friend bodies into Presence state
local pState = rawget(_G, "__PZ2CoopPresenceState")
local ownAnim = Avatar.CreateAnimState("TM", true)
local friendAnim = Avatar.CreateAnimState("AF", true)
pState.tOwnBody = {nAvatar = 101, tAnim = ownAnim}
pState.tFriendBody = {nAvatar = 202, tAnim = friendAnim}
Actions.Install()

-- Emote wheel via B key (ToggleAlignToSuggestions) + PlayEmote (Cheer) + packet sent
bPressedB = true
Actions.Update(0.05, true)
bPressedB = false
assert(Actions.GetWheelState().open == true and Actions.IsWheelOpen() == true and Actions.IsWheelBlockingInput() == true,
  "B (ToggleAlignToSuggestions) must open emote wheel and block walking input")
Actions.SetWheelPage(2)
local ws = Actions.GetWheelState()
assert(ws.open == true and ws.page == 2, "wheel state mismatch")
Actions.SetWheelOpen(false)
assert(Actions.IsWheelOpen() == false and Actions.IsWheelBlockingInput() == true,
  "closing wheel must hold short input-blocking grace period so clicks do not exit Explore on Foot")
Actions.Update(0.25, true)
assert(Actions.IsWheelBlockingInput() == false, "grace period must expire cleanly after 0.20 s")
calls, packets = {}, {}
assert(Actions.PlayEmote("cheer") == true)
assert(lastCall("QueueOneShot").args[2] == "TM$StandReactCheer")
assert(#packets == 1 and packets[1].n == 0x12 and packets[1].d.k == "action" and packets[1].d.op == "emote" and packets[1].d.id == "cheer")

-- Prop attachment (atomic identity wrapper, NO AttachPoint double-transform) + balloon pop gag
calls, packets = {}, {}
assert(Actions.PlayEmote("prop_balloon") == true)
assert(ownAnim.tProp ~= nil and ownAnim.tProp.sPrefab == "mch_novelty_balloon_giraffe" and ownAnim.tProp.nWrapperId ~= nil)
local lastSpawn = lastCall("Spawn")
assert(type(lastSpawn.args[1]) == "table" and lastSpawn.args[1].Children.Prop.Prefab == "mch_novelty_balloon_giraffe",
  "prop must spawn via identity wrapper matching vanilla ../.. BoneTransform hierarchy")
assert(packets[1].d.op == "prop" and packets[1].d.id == "prop_balloon")
calls = {}
assert(Actions.PlayEmote("prop_clear") == true)
assert(ownAnim.tProp == nil, "prop not cleared")
local bPopped = false
for _, c in ipairs(calls) do if c.name == "Spawn" and c.args[1] == "mch_balloonpopfx_red" then bPopped = true end end
assert(bPopped, "balloon pop VFX not spawned")

-- 4) 2-seat bench + full 4-phase NPC sitting (walk-up -> $SitBenchIn -> $SitBenchIdle -> $SitBenchOut -> stand):
--    Friend takes slot 0 -> plays $SitBenchIn first, then settles into $SitBenchIdle.
Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "sit", id = "bench", x = 955, y = 0, z = 1000, yaw = 0}})
assert(friendAnim.sOverrideSuffix == "$SitBenchIn", "friend must play $SitBenchIn first, got " .. tostring(friendAnim.sOverrideSuffix))
for _ = 1, 24 do Actions.Update(0.1, true) end
assert(friendAnim.sOverrideSuffix == "$SitBenchIdle", "friend seated idle mismatch: " .. tostring(friendAnim.sOverrideSuffix))

-- Local player standing 1.2 m in front of bench (10.45, 0, 11.2): StartSeat picks slot 1 beside friend,
-- walks up smoothly (NEVER teleports!), plays $SitBenchIn, transitions into $SitBenchIdle01, then on WASD
-- plays the full $SitBenchOut get-up animation before releasing!
playerPos = {10.45, 0, 11.2}
playerYaw = math.pi
assert(Actions.StartSeat("bench", 10.0, 0.0, 10.0, 0) == true)
local aState = rawget(_G, "__PZ2CoopActionsState")
assert(aState.tActiveSeat.slot == 1, "local player should take bench slot 1 beside friend, got " .. tostring(aState.tActiveSeat.slot))
assert(aState.tActiveSeat.phase == "approaching", "sitting must start by walking up, not teleporting: " .. tostring(aState.tActiveSeat.phase))
assert(math.abs(aState.tActiveSeat.z - 11.2) < 0.01, "start of approach must NOT teleport player to seat")
-- Step approach frames: avatar walks smoothly toward entry spot (z=10.44) with non-zero walk speed
local bSawWalkSpeed = false
for _ = 1, 25 do
  Actions.Update(0.05, true)
  if aState.tActiveSeat and aState.tActiveSeat.phase == "approaching" and (aState.tActiveSeat.nWalkSpeed or 0) > 0.5 then
    bSawWalkSpeed = true
  end
  if aState.tActiveSeat and aState.tActiveSeat.phase == "entering" then break end
end
assert(bSawWalkSpeed, "approaching chair must drive walk locomotion speed")
assert(aState.tActiveSeat and aState.tActiveSeat.phase == "entering",
  "after walking up & aligning, must enter sit-down animation, got " .. tostring(aState.tActiveSeat and aState.tActiveSeat.phase))
assert(ownAnim.sOverrideSuffix == "$SitBenchIn", "entering phase must play $SitBenchIn, got " .. tostring(ownAnim.sOverrideSuffix))
-- Advance through full TM $SitBenchIn (1.60 s) -> transitions smoothly into teen seated idle $SitBenchIdle01
for _ = 1, 20 do Actions.Update(0.1, true) end
assert(aState.tActiveSeat and aState.tActiveSeat.phase == "seated",
  "must reach seated phase after $SitBenchIn, got " .. tostring(aState.tActiveSeat and aState.tActiveSeat.phase))
assert(ownAnim.sOverrideSuffix == "$SitBenchIdle01", "teen bench idle should use $SitBenchIdle01, got " .. tostring(ownAnim.sOverrideSuffix))
assert(math.abs(aState.tActiveSeat.x - 10.45) < 0.02 and math.abs(aState.tActiveSeat.z - 10.0) < 0.02,
  "seated avatar must settle onto slot 1 seat coordinates")
-- Hold W (WASD) to stand up -> must play FULL $SitBenchOut get-up animation instead of cancelling/teleporting!
Actions.Update(0.2, true) -- past 0.15 s seated debounce
bMoveKeyDown = true
Actions.Update(0.05, true)
assert(aState.tActiveSeat ~= nil and aState.tActiveSeat.phase == "exiting",
  "pressing WASD while seated must enter exiting phase, got " .. tostring(aState.tActiveSeat and aState.tActiveSeat.phase))
assert(ownAnim.sOverrideSuffix == "$SitBenchOut", "exiting must play $SitBenchOut, got " .. tostring(ownAnim.sOverrideSuffix))
-- Mid-way through get-up while STILL holding W: $SitBenchOut must keep playing (not cancelled!)
Actions.Update(0.4, true)
assert(aState.tActiveSeat ~= nil and aState.tActiveSeat.phase == "exiting" and ownAnim.sOverrideSuffix == "$SitBenchOut",
  "holding W mid get-up must NOT cancel $SitBenchOut")
-- Finish full TM $SitBenchOut (1.27 s) -> cleanly released onto standing spot in front of bench!
for _ = 1, 12 do Actions.Update(0.1, true) end
bMoveKeyDown = false
assert(aState.tActiveSeat == nil and pState.tSeatOverride == nil, "after $SitBenchOut finishes, seat override must clear")
assert(ownAnim.sOverrideSuffix == nil, "base override must clear back to locomotion after standing up")
-- Friend receives clear -> plays $SitBenchOut, then clears cleanly
Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "clear"}})
assert(friendAnim.sOverrideSuffix == "$SitBenchOut", "friend stand-up must play $SitBenchOut, got " .. tostring(friendAnim.sOverrideSuffix))
for _ = 1, 18 do Actions.Update(0.1, true) end
assert(aState.tFriendSeat == nil and friendAnim.sOverrideSuffix == nil, "friend seat must clear after $SitBenchOut")
playerPos = {10, 0, 10}
playerYaw = 0

-- 5) Automatic umbrella in rain/snow is REMOVED; manual umbrella via prop wheel still works
Actions.Reset()
Actions.Install()
pState.sWeather = "rain"
Actions.Update(0.5, true)
assert(aState.sActiveProp == nil and ownAnim.tProp == nil, "rain must NOT auto-equip umbrella in player hand")
pState.sWeather = "snow"
Actions.Update(0.5, true)
assert(aState.sActiveProp == nil and ownAnim.tProp == nil, "snow must NOT auto-equip umbrella in player hand")
pState.sWeather = "clear"

-- 5b) Exhibit animations: walking up to an exhibit does NOT highlight/prompt or animate immediately,
--     but going idle beside an exhibit (>= 4.5 s) smoothly blends (0.45 s) into Watch Exhibit and exits on move!
Actions.Reset()
Actions.Install()
ownAnim.sState = "idle"
ownAnim.nSmoothSpeed = 0
ownAnim.sOverrideSuffix = nil
nearbySpatialHits = {777}
partResourceNames[777] = "Exhibit_Snake_01"
calls, packets = {}, {}
-- Walking up (W held) near exhibit: no hover prompt, no exhibit idle animation
bMoveKeyDown = true
for _ = 1, 10 do Actions.Update(0.2, true) end
assert(aState.tHovered == nil, "walking up to exhibit must NOT show hover prompt/highlight")
assert(aState.sExhibitIdleKind == nil and ownAnim.sOverrideSuffix == nil, "walking near exhibit must NOT play exhibit idle")
-- Stop and stand idle for 4.0 s: still not triggered yet
bMoveKeyDown = false
for _ = 1, 20 do Actions.Update(0.2, true) end
assert(aState.sExhibitIdleKind == nil and ownAnim.sOverrideSuffix == nil, "brief pause beside exhibit must wait for idle delay")
-- Cross 4.5 s stationary idle threshold -> smoothly blends into $StandWatchExhibit (0.45 s) & syncs to friend
for _ = 1, 4 do Actions.Update(0.2, true) end
assert(aState.sExhibitIdleKind == "exhibit" and ownAnim.sOverrideSuffix == "$StandWatchExhibit",
  "standing idle beside exhibit must smoothly play $StandWatchExhibit, got " .. tostring(ownAnim.sOverrideSuffix))
local exAnimCall = lastCall("SetBaseAnimation")
assert(exAnimCall and math.abs(exAnimCall.args[4] - 0.45) < 0.001, "exhibit idle must use smooth 0.45 s crossfade")
assert(#packets >= 1 and packets[#packets].d.op == "exhibit_idle" and packets[#packets].d.id == "exhibit",
  "exhibit_idle action packet not sent")
-- Friend receives exhibit_idle packet cleanly
Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "exhibit_idle", id = "aquarium"}})
assert(friendAnim.sOverrideSuffix == "$StandReactAquarium01", "friend exhibit_idle sync failed")
-- Moving cancels exhibit idle smoothly right away
bMoveKeyDown = true
Actions.Update(0.05, true)
bMoveKeyDown = false
assert(aState.sExhibitIdleKind == nil and ownAnim.sOverrideSuffix == nil, "moving must exit exhibit idle immediately")
nearbySpatialHits = {}
partResourceNames = {}

-- 5c) Chair/bench PathExtra detection via EntityIDToPlacementID + tooltip rendering + E to sit
tWorldAPIs.spatial.Flag_PathExtra = 8
tWorldAPIs.spatial.Flag_Facility = 16
tWorldAPIs.spatial.Flag_NonStaticScenery = 32
tWorldAPIs.scenery_puppets = {
  EntityIDToPlacementID = function(_, ent) return ent == 880 and 9901 or nil end,
}
tWorldAPIs.transform.GetParent = function(_, ent) return ent == 881 and 880 or nil end
tWorldAPIs.camera = {
  GetMainCameraID = function() return 1 end,
  GetTopDownScreenUVFromWorldPosition = function() return vec(0.5, 0.5, 0) end,
}
local lastTooltip = nil
local origGetScript = api.world.GetScript
api.world.GetScript = function()
  return {
    tEnvironment = {RequireInterface = function() return {
      SetBillboardWidgetUIInfo = function() end, SetBillboardWidgetData = function() end, ClearBillboardWidgetData = function() end,
    } end},
    GetHUD = function() return {
      ShowHelperTooltip = function(_, t) lastTooltip = t end,
      HideHelperTooltip = function() lastTooltip = nil end,
    } end,
  }
end
nearbySpatialHits = {881} -- child entity whose parent 880 maps to part 9901 ("Wooden_Chair_01")
partResourceNames = {[9901] = "Wooden_Chair_01"}
-- Close-range popup gating: chair 2.6 m away must NOT show Sit popup; chair behind player at 1.2 m must NOT show popup!
entityPosMap[881] = {10, 0, 12.6, 0}
Actions.Reset()
Actions.Install()
Actions.Update(0.2, true)
assert(aState.tHovered == nil and lastTooltip == nil, "chair 2.6 m away must NOT show Sit popup")
entityPosMap[881] = {10, 0, 8.8, 0} -- 1.2 m directly behind camera facing +Z
Actions.Update(0.2, true)
assert(aState.tHovered == nil and lastTooltip == nil, "chair behind player at 1.2 m must NOT show Sit popup")
-- Non-seat false positive ("EA_PicnicCanopy") right in front at 1.0 m must NOT show Sit popup
entityPosMap[881] = {10, 0, 11.0, 0}
partResourceNames = {[9901] = "EA_PicnicCanopy"}
Actions.Update(0.2, true)
assert(aState.tHovered == nil and lastTooltip == nil, "EA_PicnicCanopy must NOT trigger Sit popup")
-- Chair close in front at 1.0 m -> shows [E] Sit tooltip!
partResourceNames = {[9901] = "Wooden_Chair_01"}
Actions.Update(0.2, true)
assert(aState.tHovered ~= nil and aState.tHovered.kind == "chair" and aState.tHovered.label == "Sit",
  "chair via EntityIDToPlacementID parent lookup not detected: " .. tostring(aState.tHovered and aState.tHovered.kind))
assert(lastTooltip ~= nil and lastTooltip.value == "[STRING_LITERAL:Value=|Sit|]",
  "chair Sit tooltip not shown: " .. tostring(lastTooltip and lastTooltip.value))
-- Press E (GameCamera_EnterVehicle) -> begins smooth walk-up (approaching) and hides Sit tooltip while walking!
local origKeyPressed = tWorldAPIs.InputManager.GetKeyPressed
tWorldAPIs.InputManager.GetKeyPressed = function(_, s) return s == "GameCamera_EnterVehicle" end
Actions.Update(0.05, true)
tWorldAPIs.InputManager.GetKeyPressed = origKeyPressed
assert(aState.tActiveSeat ~= nil and aState.tActiveSeat.kind == "chair" and aState.tActiveSeat.phase == "approaching",
  "pressing E must start walking up to hovered chair, got " .. tostring(aState.tActiveSeat and aState.tActiveSeat.phase))
assert(lastTooltip == nil, "tooltip must hide while walking up to chair")
api.world.GetScript = origGetScript
nearbySpatialHits = {}
partResourceNames = {}
entityPosMap = {}

-- 6) Trust boundary: untrusted peer emote/prop IDs rejected cleanly, and removed holdhands is ignored
calls = {}
assert(Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "emote", id = "../evil_clip"}}) == true)
assert(Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "prop", id = "evil_prefab"}}) == true)
assert(Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "holdhands", on = true}}) == true)
assert(count("QueueOneShot") == 0 and count("Spawn") == 0, "untrusted action IDs must be dropped")
local _, _, tCatInt = Actions.GetCatalog()
assert(tCatInt.holdhands == nil, "holdhands interaction must be removed")
pState.tFriend = {x = 10.2, y = 0, z = 10.2, yaw = 0, m = 2}
Actions.Update(0.2, true)
assert(aState.tHovered == nil, "standing next to friend must NOT show Hold Hands prompt")
pState.tFriend = nil

-- 7) Universal doors, paired double doors, shutters, wide transport gates, GlassTunnelGate & AquariumEntrance exclusion
do
  local setTransforms = {}
  local mgVars = {}
  local gateRequests = {}
  local origSetTr = tWorldAPIs.transform.SetTransform
  tWorldAPIs.transform.SetTransform = function(_, id, tr) setTransforms[id] = tr end
  tWorldAPIs.motiongraph = {SetVariable = function(_, id, k, v) mgVars[id] = {k = k, v = v} end}
  tWorldAPIs.attractions = {
    RequestHabitatGateOpen = function(_, id) gateRequests[id] = true end,
    ReleaseHabitatGateOpenRequest = function(_, id) gateRequests[id] = false end,
  }
  local boundaryProps = {
    [9101] = {GetAllData = function() return {nEntityID = 9101, sPropType = "TrackAirlock"} end},
    [9102] = {GetAllData = function() return {nEntityID = 9102, sPropType = "AquariumEntrance"} end},
    [9103] = {GetAllData = function() return {nEntityID = 9103, sPropType = "GlassTunnelGate"} end},
  }
  tWorldAPIs.habitatboundary = {
    GetBoundaryObjectFromEntity = function(_, e)
      return boundaryProps[e] ~= nil, nil, nil, boundaryProps[e]
    end,
  }

  -- 7a) Single scenery door (PL_Door_01): hovered with "Open Door", toggles open via SetTransform + portal + 0x12 sync
  Actions.Reset()
  Actions.Install()
  playerPos = {10, 0, 10}
  playerYaw = 0
  nearbySpatialHits = {9001}
  partResourceNames = {[9001] = "PL_Door_01"}
  entityPosMap = {[9001] = {10, 0, 11.2, 0}}
  packets = {}
  Actions.Update(0.2, true)
  assert(aState.tHovered ~= nil and aState.tHovered.kind == "door" and aState.tHovered.label == "Open Door",
    "PL_Door_01 must hover with Open Door, got " .. tostring(aState.tHovered and aState.tHovered.label))
  -- Closed door blocks cutout check!
  assert(pState.fnHasClosedDoorAt(10, 0, 11.2) == true, "closed PL_Door_01 must report closed door at cutout")
  assert(Actions.TriggerInteraction(aState.tHovered) == true)
  assert(pState.tOpenPortals["door_9001"] ~= nil, "opening PL_Door_01 must register pass-through portal")
  assert(pState.fnHasClosedDoorAt(10, 0, 11.2) == false, "opened PL_Door_01 must clear closed-door cutout guard")
  assert(#packets >= 1 and packets[#packets].d.op == "door" and packets[#packets].d.open == true and packets[#packets].d.kind == "scenery_door",
    "opening PL_Door_01 must broadcast 0x12 op=door packet")
  for _ = 1, 10 do Actions.Update(0.05, true) end
  assert(setTransforms[9001] ~= nil, "opening PL_Door_01 must animate transform")
  -- Close door again: restores transform and clears portal
  Actions.Update(0.2, true)
  assert(aState.tHovered ~= nil and aState.tHovered.label == "Close Door", "opened door must show Close Door")
  assert(Actions.TriggerInteraction(aState.tHovered) == true)
  for _ = 1, 12 do Actions.Update(0.05, true) end
  assert(pState.tOpenPortals["door_9001"] == nil, "closing PL_Door_01 must clear pass-through portal")

  -- 7b) Paired double scenery doors (EA_Door_01 + EA_Door_01 side-by-side 1.1 m apart): opens BOTH together!
  setTransforms = {}
  nearbySpatialHits = {9010, 9011}
  partResourceNames = {[9010] = "EA_Door_01", [9011] = "EA_Door_01"}
  entityPosMap = {[9010] = {9.45, 0, 11.2, 0}, [9011] = {10.55, 0, 11.2, 0}}
  Actions.Update(0.2, true)
  assert(aState.tHovered ~= nil and aState.tHovered.kind == "door")
  assert(Actions.TriggerInteraction(aState.tHovered) == true)
  for _ = 1, 10 do Actions.Update(0.05, true) end
  assert(setTransforms[9010] ~= nil and setTransforms[9011] ~= nil, "paired double door must swing BOTH leaves")
  local dblPortal = pState.tOpenPortals["door_9010"] or pState.tOpenPortals["door_9011"]
  assert(dblPortal ~= nil and dblPortal.nHalfW >= 1.2, "paired double door must register wide combined portal")
  Actions.Reset()
  Actions.Install()

  -- 7c) Rolling shutter (PL_Door_Shutter_01_Closed) slides upward; non-leaf frame (PL_Door_01_Frame_Single) never prompts
  setTransforms = {}
  nearbySpatialHits = {9020}
  partResourceNames = {[9020] = "PL_Door_01_Frame_Single"}
  entityPosMap = {[9020] = {10, 0, 11.0, 0}}
  Actions.Update(0.2, true)
  assert(aState.tHovered == nil, "door frame must NOT prompt Open Door")
  nearbySpatialHits = {9021}
  partResourceNames = {[9021] = "PL_Door_Shutter_01_Closed"}
  entityPosMap = {[9021] = {10, 0, 11.2, 0}}
  Actions.Update(0.2, true)
  assert(aState.tHovered ~= nil and aState.tHovered.sStyle == "shutter", "shutter must be detected as shutter")
  assert(Actions.TriggerInteraction(aState.tHovered) == true)
  for _ = 1, 10 do Actions.Update(0.05, true) end
  assert(setTransforms[9021] ~= nil, "shutter must slide upward via SetTransform")
  Actions.Reset()
  Actions.Install()

  -- 7d) Wide TrackAirlock (9101), GlassTunnelGate (9103), and excluded AquariumEntrance (9102)
  nearbySpatialHits = {9102}
  partResourceNames = {}
  entityPosMap = {[9102] = {10, 0, 11.2, 0}}
  Actions.Update(0.2, true)
  assert(aState.tHovered == nil, "AquariumEntrance staff door must NEVER prompt")
  -- Remote packet targeting AquariumEntrance must be rejected at trust boundary
  gateRequests = {}
  Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "door", open = true, kind = "gate", x = 1000, y = 0, z = 1120}})
  assert(gateRequests[9102] == nil, "remote op=door must NEVER open AquariumEntrance")

  -- Wide TrackAirlock (9101): opens with GateOpen=true and wide halfW=2.50
  nearbySpatialHits = {9101}
  entityPosMap = {[9101] = {10, 0, 12.4, 0}}
  Actions.Update(0.2, true)
  assert(aState.tHovered ~= nil and aState.tHovered.kind == "wide_gate" and aState.tHovered.label == "Open Gate",
    "TrackAirlock must hover as wide_gate, got " .. tostring(aState.tHovered and aState.tHovered.kind))
  assert(Actions.TriggerInteraction(aState.tHovered) == true)
  assert(gateRequests[9101] == true and mgVars[9101] ~= nil and mgVars[9101].k == "GateOpen" and mgVars[9101].v == true,
    "TrackAirlock must request gate open and set MotionGraph GateOpen=true")
  assert(pState.tOpenPortals["door_9101"] ~= nil and pState.tOpenPortals["door_9101"].nHalfW >= 2.4,
    "TrackAirlock must register wide pass-through portal")

  -- GlassTunnelGate (9103): allowed & sets bAllowAcrylic=true
  nearbySpatialHits = {9103}
  entityPosMap = {[9103] = {10, 0, 11.5, 0}}
  Actions.Update(0.2, true)
  assert(aState.tHovered ~= nil and aState.tHovered.kind == "gate" and aState.tHovered.bAllowAcrylic == true,
    "GlassTunnelGate must be interactive with bAllowAcrylic=true")
  assert(Actions.TriggerInteraction(aState.tHovered) == true)
  assert(pState.tOpenPortals["door_9103"] ~= nil and pState.tOpenPortals["door_9103"].bAllowAcrylic == true,
    "GlassTunnelGate portal must allow passing Acrylic wall")

  -- 7e) Remote friend op=door sync opens a local scenery door and registers portal
  Actions.Reset()
  Actions.Install()
  nearbySpatialHits = {9050}
  partResourceNames = {[9050] = "NO_Door_01"}
  entityPosMap = {[9050] = {15, 0, 15, 0}}
  Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "door", open = true, kind = "scenery_door", x = 1500, y = 0, z = 1500}})
  assert(pState.tOpenPortals["door_9050"] ~= nil, "remote op=door must open local scenery door and register portal")

  tWorldAPIs.transform.SetTransform = origSetTr
  tWorldAPIs.motiongraph = nil
  tWorldAPIs.attractions = nil
  tWorldAPIs.habitatboundary = nil
  nearbySpatialHits = {}
  partResourceNames = {}
  entityPosMap = {}
end

return "ok: AAA locomotion & player actions"
"""


def main() -> int:
    lua = lupa.LuaRuntime()
    sources = lua.table()
    for name, text in SOURCES.items():
        sources[name] = text
    lua.globals().SOURCES = sources
    try:
        print(lua.execute(HARNESS + CHECKS))
    except lupa.LuaError as error:
        print("FAIL:", error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
