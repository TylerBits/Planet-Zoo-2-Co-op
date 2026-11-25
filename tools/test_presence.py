"""Offline smoke test for src/ovl_mod/pz2coop.presence.lua (run: python tools/test_presence.py).

Loads the real Bridge + Presence in a stock Lua (lupa) with fake game APIs and drives solo mode end to end:
own pose -> 0x10 packet -> loopback mirror (+50 m) -> friend drawn as the ring (orbit centre while flying, feet
while walking) with a name label, third-person camera pulled back behind the eye and stopped by terrain, own
avatar built the vehicle-driver way (StartScreenAvatar:Create in a coroutine on a parent we move) that turns toward
its walking direction while the camera orbits freely, hidden when the camera is inside it, eased mouse-wheel zoom that slides between first and third person, eased
follow, C toggles the view on foot, the vehicle shares it, the Explore button opens native explore on foot, the prompt bar gets
"Switch Camera", "Go to friend" opens explore on foot beside the friend, friend forgotten after the timeout.
Needs: pip install lupa.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.Bridge": (ROOT / "src" / "ovl_mod" / "pz2coop.bridge.lua").read_text(encoding="utf-8"),
    "PZ2Coop.Avatar": (ROOT / "src" / "ovl_mod" / "pz2coop.avatar.lua").read_text(encoding="utf-8"),
    "PZ2Coop.Presence": (ROOT / "src" / "ovl_mod" / "pz2coop.presence.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, calls = {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end}
end
local mode = "Standard"
local camPos, camYPR, centre = vec(10, 30, 20), vec(0, 0.5, 0), vec(10, 0, 40)
local nextId, transforms, late, hidden = 100, {}, {}, {}
local labels = {}
local uiMode, keyPressed, crouchPressed, sweepHit, wheel = "Select", false, false, nil, 0
local lakeSurfaceY = nil
local sphereCheckEmpty = false
local nearbyAquariumSurfaceY = nil -- simulates aquarium water 1 m behind glass (FindLake misses, sphere check hits)
local physicsRayHit = nil -- optional {vNormal = vec(...), nDistance = ...} returned by api.physics.RayCast
local shortWallZ = nil -- when set, blocks sweeps whose Y - radius <= 10.90 (a 0.90 m short wall above y=10)
local tWorldAPIs = {
  ModeHelperComponent = {GetCurrentModeName = function() return uiMode end},
  InputManager = {
    GetKeyPressed = function(_, s)
      return (keyPressed and s == "GameCamera_ToggleThirdPerson") or (crouchPressed and s == "GameCamera_Crouch")
    end,
    GetKeyDown = function() return false end,
    GetGamepadControlValue = function() return 0 end,
    GetMouseInput = function() return {RawZAxis = wheel} end,
  },
  gameterrain = {
    FindLake = function(_, vStart, vDir, nMaxDist)
      if lakeSurfaceY == nil then return nil, nil end
      local dist = vStart:GetY() - lakeSurfaceY
      if dist >= 0 and dist <= nMaxDist then return 42, dist end
      return nil, nil
    end,
    FindLakesWithSphereCheck = function(_, vPos, r)
      if nearbyAquariumSurfaceY ~= nil and r >= 1.0 then return {99} end
      if sphereCheckEmpty or lakeSurfaceY == nil then return {} end
      return {42}
    end,
    GetLakeSurfaceLevel = function(_, id)
      if id == 99 then return nearbyAquariumSurfaceY end
      return lakeSurfaceY
    end,
  },
  motiongraph = {SetVariable = function(_, id, k, v) call("SetVariable", id, k, v) end},
  model = {SetHidden = function(_, id, b) hidden[id] = b call("SetHidden", id, b) end},
  voxelterrain = {SphereSweep = function(_, id, vStart, vDir, nLen, nRadius) return sweepHit end},
  CameraModeManager = {
    GetVoxelTerrainID = function() return 3 end,
    GetPosYPRZoom = function() return camPos, camYPR, 20 end,
    GetCurrentModeName = function() return mode end,
    GetCameraDataFinal = function() return {vCentrePos = centre} end,
    RequestMode = function(_, sMode, t) call("RequestMode", sMode, t) end,
  },
  transform = {
    -- like the game: the request reports completed in the spawn frame, the transform shows up a frame later
    HasTransform = function(_, id) if late[id] then late[id] = nil return false end return transforms[id] ~= nil end,
    SetTransform = function(_, id, t) transforms[id] = t call("SetTransform", id, t) end,
    SetPosition = function(_, id, v) transforms[id] = {pos = v} end,
  },
  billboardwidgets = {WidgetType_WidgetLabel = 7},
}
local labelManager = {
  SetBillboardWidgetUIInfo = function(_, n, i, t) labels.info = t end,
  SetBillboardWidgetData = function(_, n, t) labels.data = t end,
  ClearBillboardWidgetData = function() labels.data = nil call("ClearLabel") end,
}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end, GetActive = function() return 1 end,
    GetScript = function() return {tEnvironment = {RequireInterface = function() return labelManager end}} end},
  entity = {
    CreateRequestCompletionToken = function() return {} end,
    HaveRequestsCompleted = function() return true end,
    InstantiatePrefab = function(sPrefab, sName, token, tr, parent, b, tProps)
      nextId = nextId + 1 transforms[nextId] = {} late[nextId] = true call("Spawn", sPrefab, nextId, tProps) return nextId end,
    DestroyEntity = function(id) transforms[id] = nil call("Destroy", id) end,
    FindEntityByName = function(sName, parent)
      if sName == "Lights" then return 999 end
      if sName == "MainPhysicsWorld" then return 1 end
    end,
  },
  physics = {
    Flag_Building = 1, Flag_Scenery = 2, Flag_FirstPersonObstruction = 4, Flag_Landscape = 8, Flag_Prop = 16,
    RayCast = function(nPhys, vFrom, vTo, nFlags, nMax)
      if physicsRayHit ~= nil then return {physicsRayHit} end
      return {}
    end,
  },
  player = {GetGameOwner = function() return 1 end},
  playeravatar = {GetHatHairForAvatarHairModel = function(s) return s .. "_Hat" end},
  animationcontrol = {
    SetBaseAnimation = function(id, sAnim, nRate, bWait, nBlend, bSkip)
      call("SetBaseAnimation", id, sAnim, nRate, bWait, nBlend, bSkip)
    end,
    SetPlaybackRate = function(id, nRate) call("SetPlaybackRate", id, nRate) end,
    IsRequestedBaseAnimationPlayingNow = function(id) return true end,
  },
  multipart2 = {GetProperties = function(t)
    return "Peep_Avatar", {
      DefaultAnimName = "TM$StandBaseIdle01",
      SkeletonName = "TM",
      ["Head/ModelName"] = "TM_Head_01",
      ["Hair/ModelName"] = "TM_Hair_01",
      ["Hair/Slot0_Colour"] = vec(0.1, 0.2, 0.3),
      ["Torso/ModelName"] = "TM_Torso_01",
      ["Legs/ModelName"] = "TM_Legs_01",
    }
  end},
  json = {Stringify = function() return true, "{}" end},
  time = {GetTotalTimeUnscaled = function() return 1 end},
}
local walkingData = {
  tWalkingData = {nWalkingHeightIndex = 2},
  tFinal = {vCameraPos = vec(5, 11.55, 5), vCameraYPR = vec(0, 0, 0),
    transformQ = {WithPos = function(self, v) return {pos = v, WithPos = self.WithPos} end}},
}
local WalkingCamera = {
  GetDefaultWalkingHeight = function() return 1.55 end,
  GetStartingPos = function() return vec(1, 2, 3) end,
  SweepAndSlide = function(physId, vStart, vEnd, flags, radius, iters)
    if shortWallZ ~= nil and vEnd:GetZ() > shortWallZ and (vStart:GetY() - (radius or 0.15)) <= 10.90 then
      return vec(vEnd:GetX(), vEnd:GetY(), shortWallZ)
    end
    return vEnd
  end,
  Advance = function(t, w)
    if t.tWalkingData and w and w.InputManager and w.InputManager:GetKeyPressed("GameCamera_Crouch") then
      t.tWalkingData.nWalkingHeightIndex = t.tWalkingData.nWalkingHeightIndex - 1
      if t.tWalkingData.nWalkingHeightIndex < 1 then t.tWalkingData.nWalkingHeightIndex = 2 end
    end
    call("VanillaAdvance")
  end,
}
local promptData = {Empty = {WalkingCamera = {
  tMouse = {{sLogicalControl = "GameCamera_Forward"}, {sLogicalControl = "GameCamera_Crouch"}, {sLogicalControl = "MouseRight"}},
  tGamepad = {{sLogicalControl = "GameCamera_SpeedMod"}, {sLogicalControl = "GameCamera_Crouch"}, {sLogicalControl = "Gamepad_BackButton"}}}}}
local CameraModeManager = {TryRequestWalkingMode = function(self) call("VanillaTryWalk") return true end}
local cmm = setmetatable({mainEntityID = 1, tEntities = {[1] = {tModeData = {}}}, tWorldAPIs = tWorldAPIs}, {__index = CameraModeManager})
local DriveVehicleUIMode = {}
DriveVehicleUIMode.SwitchCamera = function(self, b) self.bThirdPersonCamera = b == true end
DriveVehicleUIMode.TransitionIn = function(self, p) self:SwitchCamera(p.bThirdPersonCamera) end
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {Identity = {WithPos = function(_, v) return {pos = v} end},
    FromOrPos = function(q, v) return {pos = v, yaw = q.yaw} end},
  Quaternion = {Identity = {yaw = 0}, FromYawPitchRoll = function(v) return {yaw = v:GetX()} end},
  ["Components.Cameras.WalkingCamera"] = WalkingCamera,
  ["Components.Cameras.CameraModeManager"] = CameraModeManager,
  ["Editors.Vehicle.DriveVehicleUIMode"] = DriveVehicleUIMode,
  ["Editors.Shared.BaseUIMode"] = {GetModeHelperEntity = function() return 9 end,
    SetNewMode = function(sMode, t) call("SetNewMode", sMode, t) end},
  ["Database.GameDatabase"] = {GetPlayerKey = function() return 1 end,
    GetPlayer = function() return {GetMainAvatarData = function()
      return {tData = {version = 6, group = "TM", actor = 2, voice = 1, variant = 3, skin = 4,
        parts = {Heads = {model = 10, custom = {patternType = 0, colours = {["1"] = vec(0.5, 0.25, 0.75), ["2"] = 222}}}},
        items = {Hats = {prefab = "Hat_Safari_01"}}}}
    end} end,
    GetButtonPromptData = function(s) return promptData[s] end},
  -- Create yields while "assets load", like startscreenavatar.lua:_RecreateFromScratch
  ["StartScreen.Shared.StartScreenAvatar"] = {AvatarVersionCheck = function(t) return t end,
    new = function() return {Create = function(self, tAvatar, nParent, sType, sState)
      coroutine.yield()
      local _, tProps = api.multipart2.GetProperties(tAvatar)
      tProps.MotionGraphName = tAvatar.group -- like startscreenavatar.lua:145, after GetProperties
      tProps.AvatarType = sType
      self.tOldProps = tProps
      self.nAnimatedEntityID = api.entity.InstantiatePrefab("Peep_Avatar_StartScreen", "Avatar", {}, nil, nParent, true, tProps)
      call("AvatarCreate", tAvatar.group, nParent, sType, sState, tProps.DefaultAnimName, rawget(tProps, "MotionGraphName"),
        rawget(tProps, "AvatarType"))
      coroutine.yield()
    end} end},
}
local loaded = {}
require = function(name)
  if stubs[name] then return stubs[name] end
  if loaded[name] then return loaded[name] end
  if SOURCES[name] then
    local captured
    local prevModule = module
    module = function() captured = {} return captured end
    load(SOURCES[name], name)()
    module = prevModule
    loaded[name] = captured
    return captured
  end
  error("module not stubbed: " .. name)
end
local Bridge = require("PZ2Coop.Bridge")
local Presence = require("PZ2Coop.Presence")
-- capture Bridge.Log lines and packets instead of writing to the shared-memory ring
Bridge.Log = function(s) table.insert(log, s) end
"""

CHECKS = r"""
local function has(p) for _, l in ipairs(log) do if string.find(l, p, 1, true) then return true end end return false end
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function lastCall(name) local r = nil for _, c in ipairs(calls) do if c.name == name then r = c end end return r end
local function dump() return table.concat(log, "\n") end
local function pump(n)
  for _ = 1, n or 1 do
    Presence.Update(0.1, true)
    for _, tMsg in ipairs(__PZ2CoopBridgeState.tLoopIn or {}) do Presence.OnPacket(tMsg) end
    __PZ2CoopBridgeState.tLoopIn = {}
  end
end

Bridge.Open()
Bridge.SetLoopback(true)
Presence.Install()
assert(has("walking camera wrapped"), dump())

-- 1) flying: friend = my mirror 50 m east, drawn as the ring at my orbit centre, with a label; avatar 0x12 sent once
pump(3)
assert(has("first friend pose received (mode 0)"), dump())
assert(has("sent own avatar (group TM)") and has("received friend avatar (group TM)"), dump())
local fa = __PZ2CoopPresenceState.tFriendAvatarData
assert(fa and fa.actor == 2 and fa.voice == 1 and fa.variant == 3 and fa.skin == 4, "avatar fields lost")
assert(fa.parts.Heads.custom.colours[1]:GetX() == 0.5 and fa.parts.Heads.custom.colours[2] == 222, "custom Vector3/int colour fixup failed")
assert(fa.items and fa.items.Hats and fa.items.Hats.prefab == "Hat_Safari_01", "hat prefab lost")
local spawn = lastCall("Spawn")
assert(spawn and spawn.args[1] == "Char_Props_PlacementRing", "flying friend must be a ring")
local placed = lastCall("SetTransform").args[2].pos
assert(math.abs(placed:GetX() - 60) < 1e-6 and placed:GetZ() == 40, "ring not at orbit centre + 50 m: " .. placed:GetX())
assert(labels.data and labels.info.sLabel == "You (mirror)", "label missing")
assert(Presence.HasFriend(), "friend not known")

-- 2) walking first person: friend shown as their animated avatar at their feet (eye - 1.55) + 50 m; ring parked
mode = "Walking"
camPos, camYPR = vec(5, 11.55, 5), vec(1.0, 0, 0)
pump(30)
local ring = spawn.args[2]
local friendParent = __PZ2CoopPresenceState.tFriendBody and __PZ2CoopPresenceState.tFriendBody.tParent.nId
local friendAvatar = __PZ2CoopPresenceState.tFriendBody and __PZ2CoopPresenceState.tFriendBody.nAvatar
local friendAnim = __PZ2CoopPresenceState.tFriendBody and __PZ2CoopPresenceState.tFriendBody.tAnim
assert(friendParent ~= nil and friendAvatar ~= nil, "friend avatar not built while walking:\n" .. dump())
assert(friendAnim ~= nil and friendAnim.bAnimated == true and friendAnim.sState == "idle",
  "friend avatar must start animated in idle:\n" .. dump())
-- Verify friend avatar root prefab uses BakedAnimation + AnimationControl (no crowd components, no MotionGraph)
local bFoundRoot, bFoundPart, bFoundHat = false, false, false
for _, c in ipairs(calls) do
  if c.name == "Spawn" and type(c.args[1]) == "table" then
    local p = c.args[1]
    if p.Components and p.Components.BakedAnimation and p.Components.AnimationControl then
      bFoundRoot = true
      assert(p.Components.GuestVisual == nil and p.Components.GuestAnimation == nil and p.Components.MotionGraph == nil,
        "animated root must never include crowd or MotionGraph components")
      assert(p.Components.BakedAnimation.AnimName == "TM$StandBaseIdle01", "wrong default baked clip")
    elseif p.Prefab == "PeepBodyPart" then
      bFoundPart = true
    elseif p.Prefab == "Hat_Safari_01" then
      bFoundHat = true
    end
  end
end
assert(bFoundRoot and bFoundPart and bFoundHat, "animated friend must spawn clean root, PeepBodyPart children, and hat")
local tf = transforms[friendParent]
assert(math.abs(tf.pos:GetX() - 55) < 0.01 and math.abs(tf.pos:GetY() - 10) < 0.01, "friend avatar not at feet + 50 m")
assert(math.abs(tf.yaw - 1.0) < 0.01, "friend yaw not carried")
assert(transforms[ring].pos:GetY() == -1000, "ring should be parked while friend avatar is shown")
-- friend walks forward (+z at ~2 m/s): transitions to TM$WalkBase
for i = 1, 8 do
  camPos = vec(5, 11.55, 5 + i * 0.2)
  pump(1)
end
assert(friendAnim.sState == "walk" and friendAnim.sClip == "TM$WalkBase",
  "walking friend must play TM$WalkBase, got " .. tostring(friendAnim.sClip))
-- friend sprints (+z at ~5.5 m/s): transitions to TM$RunBase
for i = 1, 10 do
  camPos = vec(5, 11.55, 6.6 + i * 0.55)
  pump(1)
end
assert(friendAnim.sState == "run" and friendAnim.sClip == "TM$RunBase",
  "sprinting friend must play TM$RunBase, got " .. tostring(friendAnim.sClip))
-- friend stops: returns to idle
for _ = 1, 15 do pump(1) end
assert(friendAnim.sState == "idle" and friendAnim.sClip == "TM$StandBaseIdle01",
  "stopped friend must return to TM$StandBaseIdle01, got " .. tostring(friendAnim.sClip))
-- friend switches back to flying: friend avatar hidden, ring returns
mode = "Standard"
pump(3)
assert(hidden[friendAvatar] == true, "friend avatar must hide while flying")
assert(transforms[ring].pos:GetY() ~= -1000, "ring must return while flying")
mode = "Walking"
camPos, camYPR = vec(5, 11.55, 5), vec(1.0, 0, 0)
pump(5)
assert(hidden[friendAvatar] == false, "friend avatar must re-show when walking again")

-- 2b) untrusted friend avatar packets (trust boundary) are rejected cleanly
assert(Presence.OnPacket({nType = 0x12, tData = {group = "Peep_Evil"}}) == true)
assert(Presence.OnPacket({nType = 0x12, tData = {group = "TM", items = {Hats = {prefab = "../evil"}}}}) == true)
assert(Presence.OnPacket({nType = 0x12, tData = {group = "TM", parts = {Head = {model = "a/b"}}}}) == true)
assert(__PZ2CoopPresenceState.tFriendAvatarData == fa, "invalid avatar packet overwrote valid avatar")
assert(has("dropped friend avatar packet (invalid group)") and has("dropped friend avatar packet (invalid hat prefab)"), dump())

-- 3) prompt bar: "Switch Camera" inserted once before Back, and "Crouch" removed from mouse + gamepad
local tm = promptData.Empty.WalkingCamera.tMouse
assert(#tm == 3 and tm[2].sLogicalControl == "GameCamera_ToggleThirdPerson" and tm[3].sLogicalControl == "MouseRight", "prompt not before Back")
for _, e in ipairs(tm) do assert(e.sLogicalControl ~= "GameCamera_Crouch", "mouse crouch prompt must be removed") end
assert(#promptData.Empty.WalkingCamera.tGamepad == 3, "gamepad prompt missing")
for _, e in ipairs(promptData.Empty.WalkingCamera.tGamepad) do assert(e.sLogicalControl ~= "GameCamera_Crouch", "gamepad crouch prompt must be removed") end

-- 3b) pressing Crouch on foot keeps nWalkingHeightIndex at Normal (2) with zero dip
crouchPressed = true
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
crouchPressed = false
assert(walkingData.tWalkingData.nWalkingHeightIndex == 2, "crouch key must stay at Normal height (2), got " .. tostring(walkingData.tWalkingData.nWalkingHeightIndex))
walkingData.tWalkingData.nWalkingHeightIndex = 1
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
assert(walkingData.tWalkingData.nWalkingHeightIndex == 2, "clamped crouch height must reset to Normal (2)")

-- 4) C on foot toggles third person (only in the native explore UI mode)
keyPressed = true
Presence.Update(0, true)
assert(not __PZ2CoopPresenceState.bThirdPerson, "C outside explore on foot must not toggle")
uiMode = "WalkingCamera"
Presence.Update(0, true)
assert(__PZ2CoopPresenceState.bThirdPerson, "C must turn third person on")
keyPressed = false

-- 5) third person: the camera zooms out smoothly from the eye to 3.5 m behind it (yaw 0 = facing +z)
local nBeforeAdvance = count("VanillaAdvance")
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
assert(count("VanillaAdvance") == nBeforeAdvance + 1, "vanilla walking must still run")
local cam = walkingData.tFinal.transformQ.pos
assert(cam:GetZ() < 5 and cam:GetZ() > 1.5, "zoom-out must be eased: " .. cam:GetZ())
for _ = 1, 60 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
cam = walkingData.tFinal.transformQ.pos
assert(math.abs(cam:GetZ() - 1.5) < 1e-6 and math.abs(cam:GetY() - 11.95) < 1e-6, "third person camera wrong")
sweepHit = 1.0 -- wall 1 m behind: camera snaps in immediately (with +0.30 m right-shoulder offset)
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
cam = walkingData.tFinal.transformQ.pos
assert(math.abs(cam:GetZ() - (5 - 3.5 / math.sqrt(3.5 * 3.5 + 0.16 + 0.09))) < 1e-5, "camera must stop at the wall")
sweepHit = nil
-- smooth occlusion recovery eases back out when wall clears
for _ = 1, 40 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
-- eased follow: a 1 m step moves the camera part of the way in one frame, a 20 m jump snaps
walkingData.tFinal.vCameraPos = vec(5, 11.55, 6)
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
cam = walkingData.tFinal.transformQ.pos
assert(cam:GetZ() > 1.5 and cam:GetZ() < 2.5, "camera must ease after the player: " .. cam:GetZ())
walkingData.tFinal.vCameraPos = vec(5, 11.55, 26)
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
assert(math.abs(walkingData.tFinal.transformQ.pos:GetZ() - 22.5) < 1e-6, "far jump must snap")
-- mouse wheel out: target grows to 8 m, distance eases there
wheel = -1
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
assert(__PZ2CoopPresenceState.nCamDist > 3.5 and __PZ2CoopPresenceState.nCamDist < 3.8, "wheel zoom must be eased")
for _ = 1, 40 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
wheel = 0
for _ = 1, 60 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
assert(__PZ2CoopPresenceState.nCamDist == 8, "zoom out must stop at 8 m")
-- wheel in all the way: slides into first person (plain vanilla camera, third person off)
wheel = 1
for _ = 1, 40 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
wheel = 0
for _ = 1, 80 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
assert(not __PZ2CoopPresenceState.bThirdPerson and __PZ2CoopPresenceState.nCamDist == 0, "wheel in must reach first person")
-- wheel out from first person: third person again, starting close
wheel = -1
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
wheel = 0
for _ = 1, 80 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
assert(__PZ2CoopPresenceState.bThirdPerson and __PZ2CoopPresenceState.nCamDist == 1.5, "wheel out must start third person at 1.5 m")
-- C back to the usual distance
__PZ2CoopPresenceState.nThirdDist = 3.5
Presence.SetThirdPerson(true)
walkingData.tFinal.vCameraPos = vec(5, 11.55, 5)
for _ = 1, 80 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) end
assert(__PZ2CoopPresenceState.nCamDist == 3.5, "C must zoom to the last third-person distance")

-- 5b) own body: the player's animated avatar built on a parent we move
local nSpawns = count("Spawn")
pump(1)
assert(count("Spawn") == nSpawns + 1, "own body parent not spawned")
local parent = lastCall("Spawn").args[2]
assert(type(lastCall("Spawn").args[1]) == "table", "parent must be a plain prefab table, never a guest prefab")
pump(4)
local ownBody = __PZ2CoopPresenceState.tOwnBody
local avatar = ownBody and ownBody.nAvatar
local ownAnim = ownBody and ownBody.tAnim
assert(avatar ~= nil and ownAnim ~= nil and ownAnim.bAnimated == true,
  "own animated avatar not built:\n" .. dump())
assert(has("own avatar built after") and has("player animated avatar ready"), dump())
assert(count("SetVariable") == 0, "no motion-graph variables are touched")
assert(math.abs(transforms[parent].pos:GetY() - 10) < 1e-6, "own body parent not at feet")
-- walking along the camera direction (2.0 m/s): yaw stays 0, plays TM$WalkBase
for i = 1, 6 do
  walkingData.tFinal.vCameraPos = vec(5, 11.55, 5 + i * 0.2)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
  pump(1)
end
assert(math.abs(transforms[parent].yaw) < 1e-6, "walking along the camera direction keeps yaw 0")
assert(ownAnim.sState == "walk" and ownAnim.sClip == "TM$WalkBase",
  "own body walking must play TM$WalkBase, got " .. tostring(ownAnim.sClip))
-- strafing right (+x at 2.0 m/s) with the camera still facing +z: body turns toward +x (pi/2), camera yaw untouched
for i = 1, 5 do
  walkingData.tFinal.vCameraPos = vec(5 + i * 0.2, 11.55, 6.2)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
  pump(1)
end
assert(math.abs(transforms[parent].yaw - math.pi / 2) < 1e-6, "body must face its walking direction: " .. transforms[parent].yaw)
assert(walkingData.tFinal.vCameraYPR:GetX() == 0, "camera yaw must stay the player's")
-- jogging (3.5 m/s) -> TM$JogBase, then sprinting (5.5 m/s) -> TM$RunBase
for i = 1, 6 do
  walkingData.tFinal.vCameraPos = vec(6.0 + i * 0.35, 11.55, 6.2)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
  pump(1)
end
assert(ownAnim.sState == "jog" and ownAnim.sClip == "TM$JogBase",
  "own body jogging must play TM$JogBase, got " .. tostring(ownAnim.sClip))
for i = 1, 6 do
  walkingData.tFinal.vCameraPos = vec(8.1 + i * 0.55, 11.55, 6.2)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
  pump(1)
end
assert(ownAnim.sState == "run" and ownAnim.sClip == "TM$RunBase",
  "own body sprinting must play TM$RunBase, got " .. tostring(ownAnim.sClip))
-- standing still keeps the facing and transitions directly to TM$StandBaseIdle01 quickly (no running in place!)
for _ = 1, 2 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) Presence.Update(0.05, true) end
assert(math.abs(transforms[parent].yaw - math.pi / 2) < 1e-6, "standing still must keep the facing")
assert(ownAnim.sState == "idle" and ownAnim.sClip == "TM$StandBaseIdle01",
  "own body stopped after sprint must snap quickly to TM$StandBaseIdle01 (<=0.10s), got " .. tostring(ownAnim.sState) .. " / " .. tostring(ownAnim.sClip))
local lastAnimCall = lastCall("SetBaseAnimation")
assert(lastAnimCall and lastAnimCall.args[4] == false and type(lastAnimCall.args[5]) == "number" and lastAnimCall.args[5] >= 0.2 and lastAnimCall.args[6] == true,
  "SetBaseAnimation must pass smooth crossfade blend time (arg #5 >= 0.2)")
-- vanilla WalkingCamera residual glide tail damps rapidly when no movement input is pressed
walkingData.tDelta = {vDisplace = vec(0.8, 0, 0.8)}
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
assert(walkingData.tDelta.vDisplace:GetX() < 0.35 and walkingData.tDelta.vDisplace:GetZ() < 0.35,
  "residual WalkingCamera vDisplace must damp rapidly when movement keys are released")
walkingData.tDelta = nil

-- 5b-ii) WASD rapid direction taps (A -> D -> S -> W -> stop) at 60 FPS must never snap the third-person camera
-- laterally (former unsmoothed nTurnBias jumped 14-28 cm in 1 frame) or vertically (former hard-cut nBobY).
do
  local dt60 = 1 / 60
  local px, py, pz = 11.4, 11.55, 6.2
  walkingData.tFinal.vCameraPos = vec(px, py, pz)
  for _ = 1, 20 do
    WalkingCamera.Advance(walkingData, tWorldAPIs, dt60)
    Presence.Update(dt60, true)
  end
  local prevCam = walkingData.tFinal.transformQ.pos
  local dirs = {
    {-1, 0}, {-1, 0}, {-1, 0}, {-1, 0}, {-1, 0}, {-1, 0}, -- tap A (left)
    {1, 0},  {1, 0},  {1, 0},  {1, 0},  {1, 0},  {1, 0},  -- tap D (right)
    {0, -1}, {0, -1}, {0, -1}, {0, -1}, {0, -1}, {0, -1}, -- tap S (back)
    {0, 1},  {0, 1},  {0, 1},  {0, 1},  {0, 1},  {0, 1},  -- tap W (forward)
    {0, 0},  {0, 0},  {0, 0},  {0, 0},  {0, 0},  {0, 0},  -- release WASD (stop)
  }
  local maxDx, maxDy, maxDz = 0, 0, 0
  for _, d in ipairs(dirs) do
    px = px + d[1] * 2.0 * dt60
    pz = pz + d[2] * 2.0 * dt60
    walkingData.tFinal.vCameraPos = vec(px, py, pz)
    WalkingCamera.Advance(walkingData, tWorldAPIs, dt60)
    Presence.Update(dt60, true)
    local curCam = walkingData.tFinal.transformQ.pos
    maxDx = math.max(maxDx, math.abs(curCam:GetX() - prevCam:GetX()))
    maxDy = math.max(maxDy, math.abs(curCam:GetY() - prevCam:GetY()))
    maxDz = math.max(maxDz, math.abs(curCam:GetZ() - prevCam:GetZ()))
    prevCam = curCam
  end
  -- Max physical step at 2 m/s over 1/60s is 0.0333 m; any camera snap would jump > 0.05 m horizontally or > 0.01 m vertically.
  assert(maxDx < 0.04, "WASD tap snapped camera laterally: maxDx=" .. tostring(maxDx))
  assert(maxDz < 0.04, "WASD tap snapped camera fore/aft: maxDz=" .. tostring(maxDz))
  assert(maxDy < 0.005, "WASD tap snapped camera vertically: maxDy=" .. tostring(maxDy))
  -- settle back to idle before the water check below
  for _ = 1, 15 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1) pump(1) end
end
-- shallow water (< 0.75 m above feet at y=10) stays idle; waist/chest-deep water (>= 0.75 m) switches to TM$CoasterCrash_TreadWater
lakeSurfaceY = 10.5
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
pump(1)
assert(ownAnim.sState == "idle", "shallow water must not trigger swim, got " .. tostring(ownAnim.sState))
lakeSurfaceY = 11.2
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
pump(1)
assert(ownAnim.sState == "swim" and ownAnim.sClip == "TM$CoasterCrash_TreadWater",
  "deep water must play TM$CoasterCrash_TreadWater, got " .. tostring(ownAnim.sClip))
local swimCall = lastCall("SetBaseAnimation")
assert(swimCall and math.abs(swimCall.args[5] - 0.35) < 1e-6, "swim transition must use 0.35s crossfade blend")
-- 5 m deep lake (feet at y=5, surface at y=10, FindLakesWithSphereCheck empty): FindLake detects it, floats avatar & lifts camera above waterline
sphereCheckEmpty = true
lakeSurfaceY = 10.0
walkingData.tFinal.vCameraPos = vec(11.4, 6.55, 6.2)
for _ = 1, 15 do
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
  pump(1)
end
assert(ownAnim.sState == "swim" and ownAnim.sClip == "TM$CoasterCrash_TreadWater",
  "5 m deep lake must trigger swim via FindLake even when sphere check is empty, got " .. tostring(ownAnim.sState))
assert(transforms[parent].pos:GetY() > 8.4, "avatar in 5 m deep lake must float near surface - 1.25, got " .. tostring(transforms[parent].pos:GetY()))
assert(walkingData.tFinal.transformQ.pos:GetY() >= 10.18, "third-person camera must float above deep waterline, got " .. tostring(walkingData.tFinal.transformQ.pos:GetY()))
sphereCheckEmpty = false
lakeSurfaceY = nil
walkingData.tFinal.vCameraPos = vec(11.4, 11.55, 6.2)
for _ = 1, 8 do
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
  pump(1)
end
assert(ownAnim.sState == "idle", "leaving water must blend back to idle, got " .. tostring(ownAnim.sState))

-- 5b-iii) Aquarium 1 m away (FindLake misses, old 1.5 m sphere check would hit) & underwater viewing tunnel (ceiling blocks upward ray)
-- must NEVER trigger swimming or teleport avatar/camera up!
nearbyAquariumSurfaceY = 14.5
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
pump(1)
assert(ownAnim.sState == "idle" and math.abs(transforms[parent].pos:GetY() - 10) < 0.05,
  "standing 1 m outside aquarium glass must NOT swim or teleport up, got state=" .. tostring(ownAnim.sState) .. " y=" .. tostring(transforms[parent].pos:GetY()))
nearbyAquariumSurfaceY = nil
lakeSurfaceY = 14.5
physicsRayHit = {vNormal = vec(0, -1, 0), nDistance = 1.2} -- solid tunnel roof between player and aquarium water above
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
pump(1)
assert(ownAnim.sState == "idle" and math.abs(transforms[parent].pos:GetY() - 10) < 0.05,
  "standing inside underwater tunnel beneath aquarium must NOT swim or teleport up, got state=" .. tostring(ownAnim.sState))
physicsRayHit = nil
lakeSurfaceY = nil

-- 5c) short-wall & curved-wall collision fix: 0.90 m wall blocks chest/waist capsule sweeps,
-- blocked curved-wall steps (< 0.32 m) NEVER ratchet Y upward, steep curved bevels (normal.y < 0.65) reject climbs,
-- and normal flat stairs (normal.y = 1.0, +0.22 m) climb cleanly.
shortWallZ = 10.0
local vBlocked = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.5), vec(5, 11.55, 10.5), 0, 0.15, 4)
assert(math.abs(vBlocked:GetZ() - 10.0) < 1e-5, "short 0.9 m wall must block walking at z=10, got z=" .. tostring(vBlocked:GetZ()))
local vStepBlocked = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.5), vec(5, 12.55, 10.5), 0, 0.15, 4)
assert(vStepBlocked:GetY() <= 11.55 + 1e-5 and math.abs(vStepBlocked:GetZ() - 10.0) < 1e-5,
  "short wall step-up (> 0.32 m) must be clamped and blocked, got y=" .. tostring(vStepBlocked:GetY()) .. " z=" .. tostring(vStepBlocked:GetZ()))
-- Curved wall multi-frame ratchet test: even a +0.25 m step (below 0.32 m cap) must NOT raise Y when waist/chest hits wall
local vCurvedBlocked = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.99), vec(5, 11.80, 10.20), 0, 0.15, 4)
assert(vCurvedBlocked:GetY() <= 11.55 + 1e-5,
  "blocked curved wall must never ratchet Y upward, got y=" .. tostring(vCurvedBlocked:GetY()))
shortWallZ = nil
-- Unblocked steep curved wall bevel (normal.y = 0.25 < 0.65) must reject climbing
physicsRayHit = {vNormal = vec(0, 0.25, -0.96), nDistance = 1.4}
local vSteepRejected = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.5), vec(5, 11.80, 9.6), 0, 0.15, 4)
assert(vSteepRejected:GetY() <= 11.55 + 1e-5,
  "steep curved face (normal.y=0.25) must reject climbing, got y=" .. tostring(vSteepRejected:GetY()))
-- Normal stair tread (normal.y = 1.0, +0.22 m step) climbs smoothly
physicsRayHit = {vNormal = vec(0, 1.0, 0), nDistance = 1.3}
local vStairOk = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.5), vec(5, 11.77, 9.7), 0, 0.15, 4)
assert(math.abs(vStairOk:GetY() - 11.77) < 1e-5,
  "normal stair tread (+0.22 m, normal.y=1.0) must climb smoothly, got y=" .. tostring(vStairOk:GetY()))
physicsRayHit = nil

-- 5d) Emote wheel open: WalkingCamera.Advance releases captured cursor & pauses vanilla camera advance
local cursorReleased = false
walkingData.cursorRequest = {Release = function() cursorReleased = true end}
local nAdvBeforeWheel = count("VanillaAdvance")
Presence.SetWheelOpenCheck(function() return true end, function() return true end)
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
assert(cursorReleased == true and walkingData.cursorRequest == nil, "open emote wheel must release WalkingCamera cursor capture")
assert(count("VanillaAdvance") == nAdvBeforeWheel, "open emote wheel must pause vanilla WalkingCamera advance")
Presence.SetWheelOpenCheck(nil, nil)
-- teleport jump (50 m in one frame) must be ignored by speed smoother and stay idle
walkingData.tFinal.vCameraPos = vec(61.4, 11.55, 6.2)
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
pump(1)
assert(ownAnim.sState == "idle", "teleport must not spike to run, got " .. tostring(ownAnim.sState))
-- fallback: if api.animationcontrol is unavailable, falls back cleanly to StartScreenAvatar
local savedAC = api.animationcontrol
api.animationcontrol = nil
local AvatarMod = require("PZ2Coop.Avatar")
local nFbId, bFbAnim = nil, nil
local coFb = coroutine.create(function()
  nFbId, bFbAnim = AvatarMod.CreateAnimated({group = "TM", parts = {}}, parent, "player")
end)
for _ = 1, 5 do if coroutine.status(coFb) ~= "dead" then assert(coroutine.resume(coFb)) end end
api.animationcontrol = savedAC
assert(nFbId ~= nil and bFbAnim == false and lastCall("AvatarCreate") ~= nil,
  "missing animationcontrol must fall back to StartScreenAvatar")
-- packet mode 2 while walking in third person
pump(2)
-- zooming into first person hides the body first, then removes it
Presence.SetThirdPerson(false)
local bHiddenSeen = false
for _ = 1, 80 do
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  pump(1)
  if transforms[parent] ~= nil and hidden[avatar] == true then bHiddenSeen = true end
end
assert(bHiddenSeen, "body must hide when the camera reaches it")
assert(transforms[parent] == nil, "own body must go in first person")

-- 6) research vehicle starts in the shared view, and its own C switch updates it
Presence.SetThirdPerson(true)
local veh = setmetatable({}, {__index = DriveVehicleUIMode})
veh:TransitionIn({nVehicle = 5})
assert(veh.bThirdPersonCamera == true, "vehicle must start in third person")
veh:SwitchCamera(false)
assert(not __PZ2CoopPresenceState.bThirdPerson, "vehicle C must update the shared view")

-- 7) Explore button: native explore on foot instead of the bare walking camera
uiMode = "Select"
local nVanilla = count("VanillaTryWalk")
assert(cmm:TryRequestWalkingMode() == false, "must not let WalkingCameraInit switch to Select")
assert(lastCall("SetNewMode").args[1] == "WalkingCamera" and count("VanillaTryWalk") == nVanilla, "native explore not opened")
uiMode = "WalkingCamera"
assert(cmm:TryRequestWalkingMode() == true and count("VanillaTryWalk") == nVanilla + 1, "inside explore on foot vanilla must run")
uiMode = "Select"

-- 9) go to friend: explore on foot opened 1.5 m to the friend's right, facing their way
Presence.RequestGoToFriend()
pump(1)
local req = lastCall("SetNewMode")
assert(req and req.args[1] == "WalkingCamera" and req.args[2].vStartingYPR:GetX() == 1.0, "go to friend not requested")

-- 10) leaving solo mode: friend times out, entities and label removed
Bridge.SetLoopback(false)
pump(1)
assert(not Presence.HasFriend() and transforms[ring] == nil and transforms[friendParent] == nil and labels.data == nil,
  "friend not removed:\n" .. dump())
assert(not has("error"), dump())
return "ok: presence"
"""


def main() -> int:
    lua = lupa.LuaRuntime()
    sources = lua.table()
    for name, text in SOURCES.items():
        sources[name] = text
    lua.globals().SOURCES = sources
    try:
        result = lua.execute(HARNESS + CHECKS)
    except lupa.LuaError as error:
        print("FAIL:", error)
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
