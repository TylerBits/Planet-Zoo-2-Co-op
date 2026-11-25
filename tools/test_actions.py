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
    CalculateWorldTransform = function() return {GetPos = function() return vec(10, 0, 11) end, GetOr = function() return {ToYawPitchRoll = function() return vec(0, 0, 0) end} end} end},
  CameraModeManager = {
    GetCurrentModeName = function() return "Walking" end,
    GetPosYPRZoom = function() return vec(10, 1.55, 10), vec(0, 0, 0), 1 end,
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

-- 4) 2-seat bench: friend takes slot 0 -> local player automatically takes slot 1 side-by-side!
Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "sit", id = "bench", x = 955, y = 0, z = 1000, yaw = 0}})
assert(friendAnim.sOverrideSuffix == "$SitBenchIdle", "friend seated idle mismatch: " .. tostring(friendAnim.sOverrideSuffix))
assert(Actions.StartSeat("bench", 10.0, 0.0, 10.0, 0) == true)
local aState = rawget(_G, "__PZ2CoopActionsState")
assert(aState.tActiveSeat.slot == 1, "local player should take bench slot 1 beside friend, got " .. tostring(aState.tActiveSeat.slot))
assert(ownAnim.sOverrideSuffix == "$SitBenchIdle01", "teen bench idle should use $SitBenchIdle01")

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

-- 6) Trust boundary: untrusted peer emote/prop IDs rejected cleanly
calls = {}
assert(Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "emote", id = "../evil_clip"}}) == true)
assert(Actions.OnPacket({nType = 0x12, tData = {k = "action", op = "prop", id = "evil_prefab"}}) == true)
assert(count("QueueOneShot") == 0 and count("Spawn") == 0, "untrusted action IDs must be dropped")

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
