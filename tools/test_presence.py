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
local walkingStartPos = nil
local mouseInputOverride = nil
local tWorldAPIs = {
  ModeHelperComponent = {GetCurrentModeName = function() return uiMode end},
  InputManager = {
    GetKeyPressed = function(_, s)
      return (keyPressed and s == "GameCamera_ToggleThirdPerson") or (crouchPressed and s == "GameCamera_Crouch")
    end,
    GetKeyDown = function() return false end,
    GetGamepadControlValue = function() return 0 end,
    GetGamepadButtonDown = function() return false end,
    GetMouseInput = function() return mouseInputOverride or {RawZAxis = wheel} end,
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
    GetWalkingStartPos = function() return walkingStartPos end,
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
    QueueOneShotAnimation = function(id, sAnim) call("QueueOneShotAnimation", id, sAnim) end,
    ClearOneShotQueueAndForceStopOneShot = function(id) call("CancelOneShot", id) end,
    IsRequestedBaseAnimationPlayingNow = function(id) return true end,
  },
  audio = {
    SendGUIEvent = function(sEv) call("SendGUIEvent", sEv) end,
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
    call("SweepAndSlide", flags, radius)
    if api.physics ~= nil and api.physics.SphereSweep ~= nil then
      local hits = api.physics.SphereSweep(physId, vStart, vEnd, radius or 0.15, flags, 4)
      if type(hits) == "table" and hits[1] ~= nil then
        local h = hits[1]
        local n = h.vNormal
        local imp = h.vImpactPoint
        if imp ~= nil and n ~= nil then
          local r = radius or 0.15
          return vec(imp:GetX() + n:GetX() * r, vStart:GetY(), imp:GetZ() + n:GetZ() * r)
        end
        return vStart
      end
    end
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
    local bSawSprint = w ~= nil and w.InputManager ~= nil and w.InputManager.GetKeyDown ~= nil and
      w.InputManager:GetKeyDown("GameCamera_SpeedMod") == true
    call("VanillaAdvance", bSawSprint)
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
local WalkingCameraInitUIMode = {
  TransitionIn = function(self) self.tWorldAPIs = tWorldAPIs call("InitUIModeIn") end,
  TransitionOut = function(self) call("InitUIModeOut") end,
  Advance = function(self) call("InitUIModeAdv") end,
}
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {Identity = {pos = vec(0, 0, 0), yaw = 0, pitch = 0, roll = 0, WithPos = function(_, v) return {pos = v} end},
    FromOrPos = function(q, v)
      local function makeTr(oq, nv)
        local t = {pos = nv, yaw = oq.yaw or 0, pitch = oq.pitch or 0, roll = oq.roll or 0}
        t.WithPos = function(self, pv) return makeTr(self, pv) end
        return t
      end
      return makeTr(q, v)
    end},
  Quaternion = {Identity = {yaw = 0, pitch = 0, roll = 0},
    FromYawPitchRoll = function(v) return {yaw = v:GetX(), pitch = v:GetY(), roll = v:GetZ()} end},
  ["Components.Cameras.WalkingCamera"] = WalkingCamera,
  ["Components.Cameras.CameraModeManager"] = CameraModeManager,
  ["Editors.Vehicle.DriveVehicleUIMode"] = DriveVehicleUIMode,
  ["Editors.Cameras.WalkingCameraInitUIMode"] = WalkingCameraInitUIMode,
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
assert(labels.data and labels.info.sLabel == "[STRING_LITERAL:Value=|You (mirror)|]",
  "label must be STRING_LITERAL wrapped, got " .. tostring(labels.info and labels.info.sLabel))
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

-- 4) C on foot toggles third person (only in the native explore UI mode), defaulting to third person
assert(__PZ2CoopPresenceState.bThirdPerson, "explore must default to third person")
keyPressed = true
Presence.Update(0, true)
assert(__PZ2CoopPresenceState.bThirdPerson, "C outside explore on foot must not toggle")
uiMode = "WalkingCamera"
Presence.Update(0, true)
assert(not __PZ2CoopPresenceState.bThirdPerson, "C must turn third person off")
keyPressed = false

-- 3b) pressing Crouch on foot keeps nWalkingHeightIndex at Normal (2) with zero dip
crouchPressed = true
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
crouchPressed = false
assert(walkingData.tWalkingData.nWalkingHeightIndex == 2, "crouch key must stay at Normal height (2), got " .. tostring(walkingData.tWalkingData.nWalkingHeightIndex))
walkingData.tWalkingData.nWalkingHeightIndex = 1
WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
assert(walkingData.tWalkingData.nWalkingHeightIndex == 2, "clamped crouch height must reset to Normal (2)")

-- Toggle third person back on with C before testing third-person camera & own body
keyPressed = true
Presence.Update(0, true)
assert(__PZ2CoopPresenceState.bThirdPerson, "C must turn third person back on")
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

-- 5b) own body: the player's animated avatar built on a parent we move (spawns in both 1P and 3P)
pump(1)
local ownBody = __PZ2CoopPresenceState.tOwnBody
assert(ownBody ~= nil and ownBody.tParent ~= nil, "own body parent not spawned")
local parent = ownBody.tParent.nId
local spawnCall = nil
for _, c in ipairs(calls) do
  if c.name == "Spawn" and c.args[2] == parent then spawnCall = c end
end
assert(spawnCall ~= nil and type(spawnCall.args[1]) == "table", "parent must be a plain prefab table, never a guest prefab")
pump(4)
ownBody = __PZ2CoopPresenceState.tOwnBody
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

-- 5c-ii) Sprinting up slopes & sloped/angled paths must NEVER clip the player into the floor:
-- Vanilla WalkingCamera smooths vDisplace at ~5/s, so sprinting (5.6 m/s) passes vDelta ~1.12 m ahead;
-- on a 20-35 deg sloped path/hill ey-sy is +0.41..+0.78 m (> 0.32 m single-step cap).
do
  -- 1) Continuous 30 deg slope with FocusRaycast: sprinting 1.12 m (+0.65 m climb) climbs full elevation
  local slopeFn = function(x, z) return 10.0 + math.max(0, z - 5.0) * 0.58 end
  stubs["Components.Cameras.CameraUtils"] = {
    nDefaultFOV = math.pi / 3,
    FocusRaycast = function(_, _, vStart, vDir, bPhys, bTrack, bNav)
      assert(bPhys == true and bTrack == true and bNav == true, "FocusRaycast must match vanilla WalkingCamera flags (true,true,true)")
      return vec(vStart:GetX(), slopeFn(vStart:GetX(), vStart:GetZ()), vStart:GetZ())
    end,
  }
  local vSprintSlope = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 5.0), vec(5, 12.20, 6.12), 7, 0.15, 4)
  assert(math.abs(vSprintSlope:GetY() - 12.20) < 1e-4 and math.abs(vSprintSlope:GetZ() - 6.12) < 1e-4,
    "sprinting up 30 deg slope must climb full +0.65 m without clipping into floor, got y=" ..
    tostring(vSprintSlope:GetY()) .. " z=" .. tostring(vSprintSlope:GetZ()))

  -- 2) Sloped path with physics ramp collider (walkable normal.y = 0.866): SphereSweep must ignore walkable ramp surface
  local savedSweepSlope = api.physics.SphereSweep
  api.physics.SphereSweep = function(_, vStart, vEnd, r, flags, maxRes)
    return {{
      nEntityID = 888,
      nDistance = 0.3,
      vNormal = vec(0, 0.866, -0.5),
      vImpactPoint = vec(5, 10.3, 5.5),
    }}
  end
  local vRampOk = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 5.0), vec(5, 12.20, 6.12), 7, 0.15, 4)
  assert(math.abs(vRampOk:GetY() - 12.20) < 1e-4 and math.abs(vRampOk:GetZ() - 6.12) < 1e-4,
    "walkable sloped path collider (normal.y=0.866) must not block sprinting uphill, got y=" ..
    tostring(vRampOk:GetY()) .. " z=" .. tostring(vRampOk:GetZ()))

  -- 3) Brushing a side wall/handrail (x=6.0, normal=-X) while sprinting diagonally up a 30 deg sloped path:
  -- slides forward along +Z AND climbs the full slope Y instead of clipping into the ramp!
  api.physics.SphereSweep = function(_, vStart, vEnd, r, flags, maxRes)
    local sx, ex = vStart:GetX(), vEnd:GetX()
    if sx < 6.0 and ex > 6.0 then
      local t = (6.0 - sx) / (ex - sx)
      local dx, dy, dz = ex - sx, vEnd:GetY() - vStart:GetY(), vEnd:GetZ() - vStart:GetZ()
      local len = math.sqrt(dx * dx + dy * dy + dz * dz)
      return {{
        nEntityID = 889,
        nDistance = len * t,
        vNormal = vec(-1, 0, 0),
        vImpactPoint = vec(6.0, vStart:GetY() + dy * t, vStart:GetZ() + dz * t),
      }}
    end
    return {}
  end
  local vSlideSlope = WalkingCamera.SweepAndSlide(1, vec(5.7, 11.55, 5.0), vec(6.3, 12.20, 6.12), 7, 0.15, 4)
  assert(vSlideSlope:GetX() <= 6.01 and vSlideSlope:GetZ() > 5.9 and vSlideSlope:GetY() > 12.05,
    "sliding along railing while sprinting up slope must climb Y cleanly, got x=" ..
    tostring(vSlideSlope:GetX()) .. " y=" .. tostring(vSlideSlope:GetY()) .. " z=" .. tostring(vSlideSlope:GetZ()))
  api.physics.SphereSweep = savedSweepSlope

  -- 4) Abrupt 0.45 m bench or 0.90 m short wall inside a 1.0 m sprint step: VerifyWalkableClimb rejects abrupt jump
  -- and stops at start instead of walking horizontally underground!
  slopeFn = function(x, z) return z >= 5.6 and 10.90 or 10.0 end
  local vCliffStop = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 5.0), vec(5, 12.45, 6.0), 7, 0.15, 4)
  assert(vCliffStop:GetY() <= 11.55 + 1e-5 and vCliffStop:GetZ() <= 5.0 + 1e-5,
    "unblocked abrupt 0.90 m wall/cliff must reject move instead of clipping horizontally underground, got y=" ..
    tostring(vCliffStop:GetY()) .. " z=" .. tostring(vCliffStop:GetZ()))

  -- 5) Elevated sloped path passing 1.2 m above a steep rock (normal.y=0.20): steep rock far below must NOT block climb
  slopeFn = function(x, z) return 10.0 + math.max(0, z - 5.0) * 0.58 end
  physicsRayHit = {vNormal = vec(0, 0.20, -0.98), vImpactPoint = vec(5, 9.2, 6.12)}
  local vBridgeOk = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 5.0), vec(5, 12.20, 6.12), 7, 0.15, 4)
  assert(math.abs(vBridgeOk:GetY() - 12.20) < 1e-4,
    "steep terrain 1.2 m below an elevated sloped path must not block climbing, got y=" .. tostring(vBridgeOk:GetY()))
  physicsRayHit = nil

  -- 6) Third-person avatar feet track uphill sprinting with ZERO lag below the slope surface
  local dt60 = 1 / 60
  local sz = 5.0
  local prevFeet = 10.0
  walkingData.tFinal.vCameraPos = vec(5, 11.55, sz)
  WalkingCamera.Advance(walkingData, tWorldAPIs, dt60)
  Presence.Update(dt60, true)
  local maxSink = 0
  for _ = 1, 20 do
    sz = sz + 5.6 * dt60
    local trueFloor = slopeFn(5, sz)
    walkingData.tFinal.vCameraPos = vec(5, trueFloor + 1.55, sz)
    WalkingCamera.Advance(walkingData, tWorldAPIs, dt60)
    Presence.Update(dt60, true)
    local avatarY = transforms[parent].pos:GetY()
    maxSink = math.max(maxSink, trueFloor - avatarY)
  end
  assert(maxSink < 0.005, "sprinting avatar feet must not sink below sloped floor, maxSink=" .. tostring(maxSink))

  -- 7) Camera floor-clip guard: if camera ever dips below floor + 0.90 m on a sharp crest, Advance lifts it safely
  walkingData.tFinal.vCameraPos = vec(5, slopeFn(5, sz) + 0.30, sz)
  WalkingCamera.Advance(walkingData, tWorldAPIs, dt60)
  assert(walkingData.tFinal.vCameraPos:GetY() >= slopeFn(5, sz) + 0.90 - 1e-5,
    "camera floor-clip guard must lift eye to at least ground + 0.90 m, got y=" .. tostring(walkingData.tFinal.vCameraPos:GetY()))

  stubs["Components.Cameras.CameraUtils"] = nil
  walkingData.tFinal.vCameraPos = vec(11.4, 11.55, 6.2)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
  pump(1)
end

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
-- zooming into first person keeps the body visible and hides ONLY the head rig (full-body 1P view)
local nOwnHeadRig = ownBody.tAnim.nHeadRig
assert(nOwnHeadRig ~= nil, "own animated avatar must have a dedicated HeadRig")
Presence.SetThirdPerson(false)
local bHeadHiddenSeen = false
for _ = 1, 80 do
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  pump(1)
  if transforms[parent] ~= nil and hidden[nOwnHeadRig] == true then bHeadHiddenSeen = true end
end
assert(bHeadHiddenSeen, "head rig must hide when the camera enters first person")
assert(transforms[parent] ~= nil, "own body must stay visible in first person")
assert(hidden[avatar] ~= true, "own body root must NOT be hidden in first person")
assert(hidden[nOwnHeadRig] == true, "own head rig must stay hidden in first person")
-- body is offset subtly backward (-0.16 m along facing yaw) in 1P so looking down shows chest/legs cleanly
local fpPose = __PZ2CoopPresenceState.tOwnPose
assert(fpPose ~= nil and fpPose.bFirstPerson == true and fpPose.bHeadHidden == true, "1P pose metadata must be set")
local nFpYaw = __PZ2CoopPresenceState.nBodyYaw
local nExpBackX = fpPose.x - math.sin(nFpYaw) * 0.16
local nExpBackZ = fpPose.z - math.cos(nFpYaw) * 0.16
assert(math.abs(transforms[parent].pos:GetX() - nExpBackX) < 0.02 and
       math.abs(transforms[parent].pos:GetZ() - nExpBackZ) < 0.02,
  "1P body must sit 0.16 m behind eye so looking down shows chest/legs instead of hollow neck")
-- standing in 1P and turning 180 deg pivots body smoothly to follow camera yaw (never staring at own back)
walkingData.tFinal.vCameraYPR = vec(math.pi, 0, 0)
for _ = 1, 30 do
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  pump(1)
end
local nDiffAfterTurn = math.abs(((__PZ2CoopPresenceState.nBodyYaw - math.pi + math.pi) % (2 * math.pi)) - math.pi)
assert(nDiffAfterTurn <= math.rad(36), "1P body yaw must pivot to follow large camera turns, diff=" .. tostring(math.deg(nDiffAfterTurn)))
walkingData.tFinal.vCameraYPR = vec(0, 0, 0)
-- 1P LegsRig upper/lower-body split & reverse playback for strafing and backpedaling
local nOwnLegsRig = ownBody.tAnim.nLegsRig
assert(nOwnLegsRig ~= nil, "own animated avatar must have a dedicated LegsRig")
local AvatarMod2 = require("PZ2Coop.Avatar")
local lyFwd, revFwd = AvatarMod2.ComputeLegsTwistTarget(0, 2.0, true)
assert(math.abs(lyFwd) < 1e-5 and revFwd == false, "forward move must have 0 twist and forward playback")
local lyDiag, revDiag = AvatarMod2.ComputeLegsTwistTarget(math.rad(45), 2.0, true)
assert(math.abs(lyDiag - math.rad(45)) < 1e-5 and revDiag == false, "diagonal forward-right must twist +45 deg")
local lyStrafeR, revStrafeR = AvatarMod2.ComputeLegsTwistTarget(math.rad(90), 2.0, true)
assert(math.abs(lyStrafeR - math.rad(62)) < 1e-5 and revStrafeR == false, "pure right strafe must clamp at +62 deg")
local lyBack, revBack = AvatarMod2.ComputeLegsTwistTarget(math.pi, 2.0, true)
assert(math.abs(lyBack) < 1e-5 and revBack == true, "straight backpedal must have 0 twist and reverse playback")
local lyBackR, revBackR = AvatarMod2.ComputeLegsTwistTarget(math.rad(135), 2.0, true)
assert(math.abs(lyBackR - math.rad(-45)) < 1e-5 and revBackR == true, "back-right diagonal must twist -45 deg with reverse playback")
-- Live 1P strafe right (+X while facing +Z): LegsRig twists right (> +45 deg), playback stays positive
local baseX, baseZ = 61.4, 6.2
for i = 1, 20 do
  walkingData.tFinal.vCameraPos = vec(baseX + i * 0.12, 11.55, baseZ)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  pump(1)
end
assert(transforms[nOwnLegsRig] and transforms[nOwnLegsRig].yaw > math.rad(45),
  "1P right strafe must twist LegsRig > +45 deg, got " .. tostring(transforms[nOwnLegsRig] and math.deg(transforms[nOwnLegsRig].yaw)))
assert(ownBody.tAnim.nRate > 0, "1P right strafe must use positive playback rate, got " .. tostring(ownBody.tAnim.nRate))
-- Live 1P walk backward (-Z while facing +Z): LegsRig relaxes near 0, playback rate goes negative (reverse stride!)
local strX = baseX + 20 * 0.12
for i = 1, 20 do
  walkingData.tFinal.vCameraPos = vec(strX, 11.55, baseZ - i * 0.12)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  pump(1)
end
assert(ownBody.tAnim.nRate < 0, "1P backpedal must play walk/run in reverse (negative rate), got " .. tostring(ownBody.tAnim.nRate))
assert(ownBody.tAnim.sState == "walk", "1P backpedal must stay capped to WalkBase, got " .. tostring(ownBody.tAnim.sState))
assert(math.abs(ownBody.tAnim.nLegsYaw) < math.rad(10),
  "1P straight backpedal must keep LegsRig aligned near 0, got " .. tostring(math.deg(ownBody.tAnim.nLegsYaw)))
-- Even at sprint speed (5.5 m/s), reverse playback must stay capped to WalkBase (never JogBase or RunBase)
for i = 1, 15 do
  AvatarMod2.UpdateAnimation(ownBody.tAnim, ownBody.nAvatar, 5.5, 0.05, false, "clear", false, true)
end
assert(ownBody.tAnim.sState == "walk" and ownBody.tAnim.nRate < 0,
  "high-speed backpedal must stay capped to walk with negative rate, got " .. tostring(ownBody.tAnim.sState) .. " / " .. tostring(ownBody.tAnim.nRate))
-- 1P sprint suppression: Shift+S and Shift+D suppress GameCamera_SpeedMod, while Shift+W and Shift+W+D keep it
do
  local origGetKeyDown = tWorldAPIs.InputManager.GetKeyDown
  local activeKeys = {}
  tWorldAPIs.InputManager.GetKeyDown = function(_, k) return activeKeys[k] == true end
  -- Shift+S (backpedal): sprint MUST be blocked
  activeKeys = {GameCamera_SpeedMod = true, GameCamera_Backward = true}
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  assert(lastCall("VanillaAdvance").args[1] == false, "1P Shift+S must suppress GameCamera_SpeedMod")
  -- Shift+D (pure strafe): sprint MUST be blocked
  activeKeys = {GameCamera_SpeedMod = true, GameCamera_Right = true}
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  assert(lastCall("VanillaAdvance").args[1] == false, "1P pure Shift+D strafe must suppress GameCamera_SpeedMod")
  -- Shift+W (forward) and Shift+W+D (forward diagonal): sprint MUST stay enabled
  activeKeys = {GameCamera_SpeedMod = true, GameCamera_Forward = true}
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  assert(lastCall("VanillaAdvance").args[1] == true, "1P Shift+W must keep GameCamera_SpeedMod enabled")
  activeKeys = {GameCamera_SpeedMod = true, GameCamera_Forward = true, GameCamera_Right = true}
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  assert(lastCall("VanillaAdvance").args[1] == true, "1P Shift+W+D must keep GameCamera_SpeedMod enabled")
  tWorldAPIs.InputManager.GetKeyDown = origGetKeyDown
end
-- switching back to third person unhides the head rig seamlessly without rebuilding the body
Presence.SetThirdPerson(true)
for _ = 1, 60 do
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  pump(1)
end
assert(hidden[nOwnHeadRig] == false, "switching back to third person must unhide the head rig")
assert(__PZ2CoopPresenceState.tOwnBody == ownBody, "1P <-> 3P toggle must keep the same body with zero rebuild")
-- leaving Walking mode (back to overhead camera) still destroys own body cleanly
mode = "Standard"
pump(1)
assert(transforms[parent] == nil and __PZ2CoopPresenceState.tOwnBody == nil, "own body must be destroyed when leaving Walking mode")
mode = "Walking"

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

-- 10) Chair/prop + fence collision normally SOLID, and automatically cleared right next to an opened habitat gate
local bSawPropNormal = false
for _, c in ipairs(calls) do
  if c.name == "SweepAndSlide" and type(c.args[1]) == "number" and (c.args[1] % 32) >= 16 then
    bSawPropNormal = true
  end
end
assert(bSawPropNormal, "SweepAndSlide must include Flag_Prop (16) normally so chairs/benches/props are solid")

-- Fence collision (Flag_HabitatBoundary): solid Glass panel blocks crossing; Null barrier lets player pass;
-- opened gate doorway clears BOTH Flag_Prop and HabitatBoundary so doors are smoothly walkable!
local fenceType = "Glass"
local mockPanel = {GetAllData = function() return {
  sBoundaryType = fenceType,
  vBasePosStart = vec(0, 10, 10),
  vBasePosEnd = vec(10, 10, 10),
  nWorldHeightStart = 12,
  nWorldHeightEnd = 12,
} end}
tWorldAPIs.spatial = {
  Flag_HabitatBoundary = 8192,
  CapsuleQuery = function(_, a, b, r, fl) return {901} end,
}
tWorldAPIs.habitatboundary = {
  GetBoundaryObjectFromEntity = function(_, e) return e == 901, e == 901 and mockPanel or nil, nil end,
}
-- Walk north (+z) across Glass fence at z=10 (from z=9.5 to z=10.5 at eye y=11.55)
local vBlocked = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.5), vec(5, 11.55, 10.5), 7, 0.15, 4)
assert(vBlocked:GetZ() <= 9.8, "solid Glass habitat fence must block player walkthrough, got z=" .. tostring(vBlocked:GetZ()))
-- Null barrier must remain walkable
fenceType = "Null"
local vNull = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.5), vec(5, 11.55, 10.5), 7, 0.15, 4)
assert(vNull:GetZ() > 10.4, "Null barrier must remain walkable, got z=" .. tostring(vNull:GetZ()))
-- Opened habitat gate at (5, 10, 10) makes doorway walkable and drops Flag_Prop
fenceType = "Glass"
calls = {}
Presence.SetOpenGatePos("local", {x = 5, y = 10, z = 10})
local vGate = WalkingCamera.SweepAndSlide(1, vec(5, 11.55, 9.5), vec(5, 11.55, 10.5), 7, 0.15, 4)
assert(vGate:GetZ() > 10.4, "opened habitat gate must allow walking through, got z=" .. tostring(vGate:GetZ()))
for _, c in ipairs(calls) do
  if c.name == "SweepAndSlide" then
    assert((c.args[1] % 32) < 16, "Flag_Prop must be excluded inside opened habitat gate doorway")
  end
end
Presence.SetOpenGatePos("local", nil)
tWorldAPIs.spatial, tWorldAPIs.habitatboundary = nil, nil

-- 10b) Opened habitat gate skips Flag_Building doorway slab in MainPhysicsWorld (vanilla RequestHabitatGateOpen
-- leaves the barrier slab solid!) while keeping closed gates, side posts, and adjacent walls solid.
do
  local gatePos = vec(20, 10, 20)
  local gateFwd = vec(0, 0, 1)
  tWorldAPIs.transform.CalculateWorldTransform = function(_, id)
    if id == 7777 then
      return {GetPos = function() return gatePos end, GetF = function() return gateFwd end}
    end
    return nil
  end
  -- Simulate a Flag_Building slab across z=20 (x in [15, 25], y in [10, 12.5]) in api.physics.SphereSweep
  local savedSweep = api.physics.SphereSweep
  api.physics.SphereSweep = function(_, vStart, vEnd, r, flags, maxRes)
    local sz, ez = vStart:GetZ(), vEnd:GetZ()
    local sx, ex = vStart:GetX(), vEnd:GetX()
    local sy = vStart:GetY()
    if (sz < 20 and ez > 20) or (sz > 20 and ez < 20) then
      local t = (20 - sz) / (ez - sz)
      local ix = sx + (ex - sx) * t
      if ix >= 15 and ix <= 25 and sy >= 10 and sy <= 12.5 then
        local dz = ez - sz
        local len = math.sqrt((ex - sx)^2 + dz^2)
        local nSign = dz > 0 and -1 or 1
        return {{
          nEntityID = 92936,
          nDistance = len * t,
          vNormal = vec(0, 0, nSign),
          vImpactPoint = vec(ix, sy, 20),
          vCentrePoint = vec(ix, sy, 20 + nSign * r),
        }}
      end
    end
    return {}
  end
  -- Gate CLOSED: slab blocks at z=20
  local vClosed = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 19.0), vec(20, 11.55, 21.0), 7, 0.15, 4)
  assert(vClosed:GetZ() < 20.0, "closed gate slab must block walking, got z=" .. tostring(vClosed:GetZ()))
  -- Gate OPENED: walking straight through front->back AND back->front passes cleanly!
  Presence.SetLocalOpenGate(7777)
  local vOpenFwd = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 19.0), vec(20, 11.55, 21.0), 7, 0.15, 4)
  assert(math.abs(vOpenFwd:GetZ() - 21.0) < 1e-4, "opened gate must allow walking front->back, got z=" .. tostring(vOpenFwd:GetZ()))
  local vOpenBack = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 21.0), vec(20, 11.55, 19.0), 7, 0.15, 4)
  assert(math.abs(vOpenBack:GetZ() - 19.0) < 1e-4, "opened gate must allow walking back->front, got z=" .. tostring(vOpenBack:GetZ()))
  -- Adjacent wall 1.5 m sideways from gate center MUST remain solid even while gate is open!
  local vSideWall = WalkingCamera.SweepAndSlide(1, vec(21.5, 11.55, 19.0), vec(21.5, 11.55, 21.0), 7, 0.15, 4)
  assert(vSideWall:GetZ() < 20.0, "wall beside opened gate must remain solid, got z=" .. tostring(vSideWall:GetZ()))
  -- Gate CLOSED again: immediately solid again
  Presence.SetLocalOpenGate(nil)
  local vReclosed = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 19.0), vec(20, 11.55, 21.0), 7, 0.15, 4)
  assert(vReclosed:GetZ() < 20.0, "re-closed gate must block walking again, got z=" .. tostring(vReclosed:GetZ()))
  -- Remote friend opened gate: local player can also walk through it!
  Presence.SetRemoteOpenGate(7777)
  local vRemoteOpen = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 19.0), vec(20, 11.55, 21.0), 7, 0.15, 4)
  assert(math.abs(vRemoteOpen:GetZ() - 21.0) < 1e-4, "friend-opened gate must allow local player through, got z=" .. tostring(vRemoteOpen:GetZ()))
  Presence.SetRemoteOpenGate(nil)
  api.physics.SphereSweep = savedSweep
  tWorldAPIs.transform.CalculateWorldTransform = nil
end

-- 10c) Wide gate (TrackAirlock), Aquarium Staff Door (AquariumEntrance) exclusion vs GlassTunnelGate,
--      and Cutout Doors / Archways in walls & habitat walls (with closed-door guard).
do
  local savedSweep = api.physics.SphereSweep
  local savedEntityGetName = api.entity.GetName
  local savedTransform = tWorldAPIs.transform.CalculateWorldTransform
  local savedSpatial = tWorldAPIs.spatial
  local savedHB = tWorldAPIs.habitatboundary
  local savedPlacement = tWorldAPIs.placement
  local savedHabitat = tWorldAPIs.habitat

  local entityNames = {
    [8001] = "HB_Attachable_TransportGate_Metal",
    [8002] = "HB_Attachable_AquariumEntrance",
    [8003] = "HB_Attachable_GlassTunnelGate",
    [8010] = "PL_Wall_Brick_01_Door_Single_4x4",
    [8011] = "EA_Wall_Stone_01_Arch_Round_4x4",
  }
  api.entity.GetName = function(id) return entityNames[id] end
  tWorldAPIs.placement = {GetPartResourceName = function(_, id) return entityNames[id] end}
  tWorldAPIs.habitat = {
    GetEntityIDFromHabitatID = function(_, h) return h end,
    IsAquarium = function(_, h) return h == 500 end,
  }
  -- Aquarium staff door (8002) MUST be excluded; GlassTunnelGate (8003) and TrackAirlock (8001) MUST be allowed!
  assert(Presence.IsAquariumStaffDoorEntity(8002) == true, "AquariumEntrance must be excluded as aquarium staff door")
  assert(Presence.IsAquariumStaffDoorEntity(8003) == false, "GlassTunnelGate must be allowed")
  assert(Presence.IsAquariumStaffDoorEntity(8001) == false, "TrackAirlock must be allowed")

  -- Solid physics slab across z=30 (x in [10, 35], y in [10, 14])
  api.physics.SphereSweep = function(_, vStart, vEnd, r, flags, maxRes)
    local sz, ez = vStart:GetZ(), vEnd:GetZ()
    local sx, ex = vStart:GetX(), vEnd:GetX()
    local sy = vStart:GetY()
    if (sz < 30 and ez > 30) or (sz > 30 and ez < 30) then
      local t = (30 - sz) / (ez - sz)
      local ix = sx + (ex - sx) * t
      if ix >= 10 and ix <= 35 and sy >= 10 and sy <= 14 then
        local dz = ez - sz
        local len = math.sqrt((ex - sx)^2 + dz^2)
        local nSign = dz > 0 and -1 or 1
        return {{
          nEntityID = 93001,
          nDistance = len * t,
          vNormal = vec(0, 0, nSign),
          vImpactPoint = vec(ix, sy, 30),
          vCentrePoint = vec(ix, sy, 30 + nSign * r),
        }}
      end
    end
    return {}
  end

  local portalPos = {
    [8001] = vec(20, 10, 30),
    [8002] = vec(20, 10, 30),
    [8010] = vec(20, 10, 30),
    [8011] = vec(20, 10, 30),
  }
  tWorldAPIs.transform.CalculateWorldTransform = function(_, id)
    if portalPos[id] then
      return {GetPos = function() return portalPos[id] end, GetF = function() return vec(0, 0, 1) end}
    end
    return nil
  end

  -- Wide TrackAirlock (8001) opened: passable at center (x=20) AND 2.0 m off-center (x=22), solid at x=23!
  Presence.SetLocalOpenGate(8001)
  local vWideCenter = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 29.0), vec(20, 11.55, 31.0), 7, 0.15, 4)
  assert(math.abs(vWideCenter:GetZ() - 31.0) < 1e-4, "wide gate center must be passable, got z=" .. tostring(vWideCenter:GetZ()))
  local vWideEdge = WalkingCamera.SweepAndSlide(1, vec(22.0, 11.55, 29.0), vec(22.0, 11.55, 31.0), 7, 0.15, 4)
  assert(math.abs(vWideEdge:GetZ() - 31.0) < 1e-4, "wide gate 2.0 m off-center must be passable, got z=" .. tostring(vWideEdge:GetZ()))
  local vWideWall = WalkingCamera.SweepAndSlide(1, vec(23.2, 11.55, 29.0), vec(23.2, 11.55, 31.0), 7, 0.15, 4)
  assert(vWideWall:GetZ() < 30.0, "wall outside wide gate (3.2 m off-center) must stay solid, got z=" .. tostring(vWideWall:GetZ()))
  Presence.SetLocalOpenGate(nil)

  -- Aquarium staff door (8002) even if set as LocalOpenGate MUST NEVER allow pass-through!
  Presence.SetLocalOpenGate(8002)
  local vAqBlocked = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 29.0), vec(20, 11.55, 31.0), 7, 0.15, 4)
  assert(vAqBlocked:GetZ() < 30.0, "aquarium staff door must NEVER allow walkthrough, got z=" .. tostring(vAqBlocked:GetZ()))
  Presence.SetLocalOpenGate(nil)

  -- Cutout door (8010) & archway (8011) in a solid Brick_Red habitat wall: center opening is walkable,
  -- side wall piers stay solid, Acrylic wall stays solid, and closed door inside cutout blocks walking!
  local wallType = "Brick_Red"
  local wallPanel = {GetAllData = function() return {
    sBoundaryType = wallType,
    vBasePosStart = vec(10, 10, 30),
    vBasePosEnd = vec(35, 10, 30),
    nWorldHeightStart = 14,
    nWorldHeightEnd = 14,
  } end}
  local nearbyScenery = {8010}
  tWorldAPIs.spatial = {
    Flag_Scenery = 1,
    Flag_NonStaticScenery = 2,
    Flag_Facility = 4,
    Flag_HabitatBoundary = 8192,
    SphereQuery = function() return nearbyScenery end,
    CapsuleQuery = function() return {902} end,
  }
  tWorldAPIs.habitatboundary = {
    GetBoundaryObjectFromEntity = function(_, e) return e == 902, e == 902 and wallPanel or nil, nil end,
  }
  -- Empty single-door cutout in Brick_Red habitat wall -> center (x=20) walkable, side pier (x=21.2) solid!
  local vCutCenter = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 29.0), vec(20, 11.55, 31.0), 7, 0.15, 4)
  assert(math.abs(vCutCenter:GetZ() - 31.0) < 1e-4, "empty cutout door in habitat wall must be walkable, got z=" .. tostring(vCutCenter:GetZ()))
  local vCutPier = WalkingCamera.SweepAndSlide(1, vec(21.2, 11.55, 29.0), vec(21.2, 11.55, 31.0), 7, 0.15, 4)
  assert(vCutPier:GetZ() < 30.0, "solid pier beside cutout door must block walking, got z=" .. tostring(vCutPier:GetZ()))
  -- Closed door inside cutout -> blocked!
  Presence.SetClosedDoorCheck(function() return true end)
  local vCutClosed = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 29.0), vec(20, 11.55, 31.0), 7, 0.15, 4)
  assert(vCutClosed:GetZ() < 30.0, "cutout with closed door inside must block walking, got z=" .. tostring(vCutClosed:GetZ()))
  Presence.SetClosedDoorCheck(nil)
  -- Archway (8011) in Brick_Red habitat wall -> wider opening (x=21.0) walkable!
  nearbyScenery = {8011}
  local vArchWide = WalkingCamera.SweepAndSlide(1, vec(21.0, 11.55, 29.0), vec(21.0, 11.55, 31.0), 7, 0.15, 4)
  assert(math.abs(vArchWide:GetZ() - 31.0) < 1e-4, "archway in habitat wall must be walkable at 1.0 m off-center, got z=" .. tostring(vArchWide:GetZ()))
  -- Acrylic aquarium wall behind a regular archway must STILL block!
  wallType = "Acrylic"
  local vAcrylicBlocked = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 29.0), vec(20, 11.55, 31.0), 7, 0.15, 4)
  assert(vAcrylicBlocked:GetZ() < 30.0, "Acrylic aquarium wall must remain solid even behind scenery arch, got z=" .. tostring(vAcrylicBlocked:GetZ()))
  -- GlassTunnelGate portal (bAllowAcrylic = true) DOES allow walking through Acrylic wall!
  Presence.SetOpenPortal("door_8003", {
    nId = 8003, gx = 20, gy = 10, gz = 30, fx = 0, fz = 1, rx = 1, rz = 0,
    nHalfW = 1.50, nHalfDepth = 0.95, nMinY = -0.35, nMaxY = 2.85, bAllowAcrylic = true,
  })
  local vGlassTunnel = WalkingCamera.SweepAndSlide(1, vec(20, 11.55, 29.0), vec(20, 11.55, 31.0), 7, 0.15, 4)
  assert(math.abs(vGlassTunnel:GetZ() - 31.0) < 1e-4, "GlassTunnelGate must allow walking through Acrylic wall, got z=" .. tostring(vGlassTunnel:GetZ()))
  Presence.SetOpenPortal("door_8003", nil)

  api.physics.SphereSweep = savedSweep
  api.entity.GetName = savedEntityGetName
  tWorldAPIs.transform.CalculateWorldTransform = savedTransform
  tWorldAPIs.spatial = savedSpatial
  tWorldAPIs.habitatboundary = savedHB
  tWorldAPIs.placement = savedPlacement
  tWorldAPIs.habitat = savedHabitat
end

-- 11) Partner name sanitization + cached peer avatar survival across environment reset
local savedLoopback, savedConnected = Bridge.IsLoopback, Bridge.IsPeerConnected
Bridge.IsLoopback = function() return false end
Bridge.IsPeerConnected = function() return true end
__PZ2CoopBridgeState.tSession.sPartner = "TylerBits[|]"
Presence.Update(0.05, true)
assert(labels.info.sLabel == "[STRING_LITERAL:Value=|TylerBits|]",
  "partner name not wrapped/sanitized cleanly: " .. tostring(labels.info and labels.info.sLabel))
Bridge.IsLoopback, Bridge.IsPeerConnected = savedLoopback, savedConnected

Bridge.ClearCachedPeerAvatar()
__PZ2CoopPresenceState.tFriendAvatarData = nil
__PZ2CoopPresenceState.bAvatarSent = true
-- Simulate receiving avatar packet into Bridge cache before Presence hydrates
__PZ2CoopBridgeState.tPeerAvatar = {version = 6, group = "TM", actor = 2, parts = {}}
pump(2)
assert(__PZ2CoopPresenceState.tFriendAvatarData ~= nil and __PZ2CoopPresenceState.tFriendAvatarData.group == "TM",
  "Presence did not hydrate friend avatar from Bridge cache")

-- 11b) Constrained third-person & co-op friend head tracking (anatomical limits, front-orbit dead-zone, pivot math, friend sync)
do
  local AvatarMod = require("PZ2Coop.Avatar")

  -- Part classification: Head/Hair/Beard/Glasses rotate with head; Torso/Legs/backpack/audioguide stay on body
  assert(AvatarMod.IsHeadLookPart("Head", "TM_Head_01") == true)
  assert(AvatarMod.IsHeadLookPart("Hair", "TM_Hair_01") == true)
  assert(AvatarMod.IsHeadLookPart("Beard", "AM_Beard_01") == true)
  assert(AvatarMod.IsHeadLookPart("Accessory", "tm_glasses02") == true)
  assert(AvatarMod.IsHeadLookPart("Accessory", "tm_backpack") == false, "backpack must not rotate with head")
  assert(AvatarMod.IsHeadLookPart("Accessory", "tm_audioguide") == false, "audioguide must not rotate with head")
  assert(AvatarMod.IsHeadLookPart("Torso", "TM_Torso_01") == false)
  assert(AvatarMod.IsHeadLookPart("Legs", "TM_Legs_01") == false)

  -- Constraint zones: active tracking, +/-48 deg shoulder clamp, 100..140 deg smoothstep fade, 140..180 deg neutral
  local y1, p1, w1 = AvatarMod.ComputeHeadLookTarget(math.rad(30), math.rad(-20), false, false)
  assert(math.abs(w1 - 1.0) < 1e-6 and math.abs(y1 - math.rad(25.5)) < 1e-5 and math.abs(p1 - math.rad(-16)) < 1e-5,
    "active look cone math mismatch")

  -- Hard anatomical limits: yaw capped at +/-48 deg, pitch capped at -22 deg up / +18 deg down (+10 deg swim)
  local yClamp, pUpClamp = AvatarMod.ComputeHeadLookTarget(math.rad(85), math.rad(-70), false, false)
  assert(math.abs(yClamp - math.rad(48)) < 1e-5, "yaw must clamp at +48 deg, got " .. math.deg(yClamp))
  assert(math.abs(pUpClamp - math.rad(-22)) < 1e-5, "up-pitch must clamp at -22 deg, got " .. math.deg(pUpClamp))
  local _, pDownLand = AvatarMod.ComputeHeadLookTarget(0, math.rad(70), false, false)
  local _, pDownSwim = AvatarMod.ComputeHeadLookTarget(0, math.rad(70), true, false)
  assert(math.abs(pDownLand - math.rad(18)) < 1e-5, "down-pitch must clamp at +18 deg on land")
  assert(math.abs(pDownSwim - math.rad(10)) < 1e-5, "down-pitch must clamp at +10 deg while swimming")

  -- Looking at yourself (front orbit): 120 deg halfway fade, 140..180 deg fully neutral, zero snap across +/-180 deg
  local yMid, _, wMid = AvatarMod.ComputeHeadLookTarget(math.rad(120), math.rad(-20), false, false)
  assert(math.abs(wMid - 0.5) < 1e-5 and math.abs(yMid - math.rad(24)) < 1e-4, "120 deg midpoint smoothstep mismatch")
  local yBackP, pBackP, wBackP = AvatarMod.ComputeHeadLookTarget(math.rad(179), math.rad(-25), false, false)
  local yBackN, pBackN, wBackN = AvatarMod.ComputeHeadLookTarget(math.rad(-179), math.rad(-25), false, false)
  assert(wBackP == 0 and yBackP == 0 and pBackP == 0, "looking at self (+179 deg) must be neutral")
  assert(wBackN == 0 and yBackN == 0 and pBackN == 0, "looking at self (-179 deg) must be neutral with zero snap")

  -- Emote / one-shot suppression returns neutral
  local ySup, pSup, wSup = AvatarMod.ComputeHeadLookTarget(math.rad(40), math.rad(-15), false, true)
  assert(wSup == 0 and ySup == 0 and pSup == 0, "suppressed state must return neutral")

  -- Pivot invariance: R * P + T == P for arbitrary yaw, pitch, and off-origin neck pivot
  local px, py, pz = 0.02, 1.38, 0.06
  local ty, tp = math.rad(45), math.rad(-22)
  local trPiv = AvatarMod.ComputePivotTransform(ty, tp, px, py, pz)
  local cp, sp, cy, sy = math.cos(tp), math.sin(tp), math.cos(ty), math.sin(ty)
  local y1p = py * cp - pz * sp
  local z1p = py * sp + pz * cp
  local rpx = px * cy + z1p * sy
  local rpy = y1p
  local rpz = -px * sy + z1p * cy
  assert(math.abs((rpx + trPiv.pos:GetX()) - px) < 1e-5 and
         math.abs((rpy + trPiv.pos:GetY()) - py) < 1e-5 and
         math.abs((rpz + trPiv.pos:GetZ()) - pz) < 1e-5,
    "pivot transform must keep neck point fixed")

  -- End-to-end own third-person avatar + loopback friend head tracking
  calls = {}
  mode = "Walking"
  Presence.SetThirdPerson(true)
  walkingData.tFinal.vCameraPos = vec(5, 11.55, 5)
  walkingData.tFinal.vCameraYPR = vec(0, 0, 0)
  camPos, camYPR = vec(5, 11.55, 5), vec(0, 0, 0)
  for _ = 1, 25 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  local ownB = __PZ2CoopPresenceState.tOwnBody
  assert(ownB and ownB.tAnim and ownB.tAnim.nHeadRig ~= nil and ownB.tAnim.tHeadParts and #ownB.tAnim.tHeadParts >= 2,
    "own avatar missing HeadRig or headParts")
  -- Verify dedicated HeadRig RenderGroup spawned, Head/Hair point AnimationProxy & AssetPackageProvider to "../..",
  -- and Torso/Legs stay directly under the avatar root without AnimationProxy override.
  local bHeadRig, bHeadProxy, bTorsoPlain, bNeckAttach = false, false, false, false
  for _, c in ipairs(calls) do
    if c.name == "Spawn" then
      local p, props = c.args[1], c.args[3]
      if type(p) == "table" and p.Components and p.Components.RenderGroup and p.Components.BakedAnimation == nil then
        bHeadRig = true
      elseif type(p) == "table" and p.Prefab == "PeepBodyPart" and type(props) == "table" then
        if props.ModelName == "TM_Head_01" and p.Components and p.Components.AnimationProxy and
          p.Components.AnimationProxy.AnimationEntity == "../.." and p.Components.AssetPackageProvider and
          p.Components.AssetPackageProvider.LoaderPath == "../.." then
          bHeadProxy = true
        elseif props.ModelName == "TM_Torso_01" and p.Components and p.Components.AnimationProxy == nil then
          bTorsoPlain = true
        end
      elseif p == "AttachPoint" and type(props) == "table" and props.AttachBone == "def_c_neck1_joint" then
        bNeckAttach = true
      end
    end
  end
  assert(bHeadRig, "Animated avatar must spawn dedicated HeadRig RenderGroup child")
  assert(bHeadProxy, "Head PeepBodyPart must point AnimationProxy & AssetPackageProvider to '../..'")
  assert(bTorsoPlain, "Torso PeepBodyPart must stay directly under avatar root")
  assert(bNeckAttach, "Animated avatar must spawn def_c_neck1_joint AttachPoint for live neck pivot")
  local nOwnHeadRig = ownB.tAnim.nHeadRig
  -- Orbit camera +45 deg right and -20 deg up while standing still (body stays at yaw=0)
  walkingData.tFinal.vCameraYPR = vec(math.rad(45), math.rad(-20), 0)
  camYPR = vec(math.rad(45), math.rad(-20), 0)
  for _ = 1, 30 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  assert(transforms[nOwnHeadRig] and math.abs(transforms[nOwnHeadRig].yaw - math.rad(38.25)) < 0.05 and
         math.abs(transforms[nOwnHeadRig].pitch - math.rad(-16)) < 0.05,
    "own HeadRig did not track +45/-20 camera: yaw=" .. tostring(transforms[nOwnHeadRig] and math.deg(transforms[nOwnHeadRig].yaw)) ..
    " pitch=" .. tostring(transforms[nOwnHeadRig] and math.deg(transforms[nOwnHeadRig].pitch)))
  -- Orbit all the way in front (175 deg -> -175 deg): head smoothly relaxes back to neutral (0, 0) with zero snap!
  walkingData.tFinal.vCameraYPR = vec(math.rad(175), math.rad(-20), 0)
  for _ = 1, 40 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  assert(math.abs(ownB.tAnim.nHeadYaw) < 0.02 and math.abs(ownB.tAnim.nHeadPitch) < 0.02,
    "own head must relax to neutral when looking at self (+175 deg)")
  walkingData.tFinal.vCameraYPR = vec(math.rad(-175), math.rad(-20), 0)
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05)
  pump(1)
  assert(math.abs(ownB.tAnim.nHeadYaw) < 0.02, "crossing +/-180 deg must not snap own head")

  -- Seated head tracking stays active using live camera yaw/pitch relative to seat facing,
  -- while approaching drives walk animation & WalkingCamera.vCameraPos stays synced (zero teleport on release).
  Presence.SetSeatOverride({x = 5.0, y = 10.0, z = 5.5, yaw = 0, eyeHeight = 1.55, phase = "approaching", nWalkSpeed = 1.75})
  for _ = 1, 8 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  assert(ownB.tAnim.sState == "walk", "approaching seat must drive walk locomotion animation, got " .. tostring(ownB.tAnim.sState))
  assert(math.abs(walkingData.tFinal.vCameraPos:GetZ() - 5.5) < 1e-4,
    "WalkingCamera vCameraPos must stay synced to seat override so releasing never teleports")

  Presence.SetSeatOverride({x = 5, y = 10, z = 5, yaw = 0, eyeHeight = 1.15, phase = "seated"})
  AvatarMod.SetBaseOverride(ownB.tAnim, ownB.nAvatar, "$SitBenchIdle", 0.2)
  walkingData.tFinal.vCameraYPR = vec(math.rad(-40), math.rad(-18), 0)
  for _ = 1, 30 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  assert(ownB.tAnim.nHeadYaw < math.rad(-30) and ownB.tAnim.nHeadPitch < math.rad(-12),
    "seated player head must still follow camera yaw and pitch")
  -- During sit-down / stand-up transitions, head-look relaxes smoothly toward neutral
  Presence.SetSeatOverride({x = 5, y = 10, z = 5, yaw = 0, eyeHeight = 1.35, phase = "exiting"})
  AvatarMod.SetBaseOverride(ownB.tAnim, ownB.nAvatar, "$SitBenchOut", 0.15)
  for _ = 1, 30 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  assert(math.abs(ownB.tAnim.nHeadYaw) < 0.05, "head-look must relax to neutral during stand-up animation")
  AvatarMod.ClearBaseOverride(ownB.tAnim, ownB.nAvatar)
  Presence.SetSeatOverride(nil)

  -- Active one-shot emote suppresses head-look, then auto-expires after 2.5 s while standing still
  walkingData.tFinal.vCameraYPR = vec(math.rad(45), math.rad(-20), 0)
  for _ = 1, 25 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  ownB.tAnim.bOneShotActive = true
  ownB.tAnim.nOneShotUntil = ownB.tAnim.nClock + 1.5
  for _ = 1, 10 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  assert(math.abs(ownB.tAnim.nHeadYaw) < 0.05, "active emote one-shot must relax head toward neutral")
  for _ = 1, 25 do WalkingCamera.Advance(walkingData, tWorldAPIs, 0.05) pump(1) end
  assert(not ownB.tAnim.bOneShotActive and ownB.tAnim.nHeadYaw > math.rad(30),
    "one-shot must auto-expire while standing still so head-look resumes")

  -- Friend avatar receives 0x10 yaw + pitch (loopback mirror) and drives friend HeadRig transforms
  local frB = __PZ2CoopPresenceState.tFriendBody
  assert(frB and frB.tAnim and frB.tAnim.nHeadRig ~= nil and frB.tAnim.tHeadParts and #frB.tAnim.tHeadParts >= 2,
    "friend avatar missing HeadRig or headParts")
  local nFrHeadRig = frB.tAnim.nHeadRig
  __PZ2CoopPresenceState.nFriendBodyYaw = 0
  camYPR = vec(math.rad(40), math.rad(-22), 0)
  for _ = 1, 30 do pump(1) end
  assert(transforms[nFrHeadRig] and transforms[nFrHeadRig].yaw > math.rad(25) and transforms[nFrHeadRig].pitch < math.rad(-12),
    "friend HeadRig must track synced 0x10 yaw & pitch: yaw=" .. tostring(transforms[nFrHeadRig] and math.deg(transforms[nFrHeadRig].yaw)) ..
    " pitch=" .. tostring(transforms[nFrHeadRig] and math.deg(transforms[nFrHeadRig].pitch)))
  -- Restore neutral camera before cleanup check below
  walkingData.tFinal.vCameraYPR = vec(0, 0, 0)
  camYPR = vec(0, 0, 0)
  Presence.SetThirdPerson(false)
end

-- 11c) Camera -> Explore placement preview (WalkingCameraInitUIMode): suspended player model above ring,
-- $PickedUp_In -> $PickedUp_Loop transition, camera-facing yaw, cursor-velocity pendulum dangle, invalid hiding,
-- clean destroy on exit, and $PickedUp_Out drop-in one-shot on landing in third-person Explore mode.
do
  calls = {}
  mode = "Standard"
  uiMode = "WalkingCameraInit"
  camPos = vec(10, 25, 10)
  camYPR = vec(0, 0.5, 0)
  walkingStartPos = vec(10, 11.55, 20) -- ground y = 10.0, 10 m north of camera -> avatar should face south (pi)
  local initMode = {tWorldAPIs = tWorldAPIs}
  WalkingCameraInitUIMode.TransitionIn(initMode)
  assert(has("explore placement started"), "WalkingCameraInit TransitionIn wrap did not fire")
  WalkingCameraInitUIMode.Advance(initMode)
  -- Pump a few frames so parent becomes ready and animated avatar coroutine finishes building
  for _ = 1, 5 do
    WalkingCameraInitUIMode.Advance(initMode)
    Presence.Update(0.05, false)
  end
  local prev = Presence.GetExplorePreview()
  assert(prev ~= nil and prev.nAvatar ~= nil and prev.tAnim ~= nil, "explore preview avatar did not spawn")
  assert(prev.tAnim.sClip == "TM$PickedUp_In",
    "explore preview must start in TM$PickedUp_In, got " .. tostring(prev.tAnim.sClip))
  assert(prev.sPhase == "in", "explore preview phase should start as 'in'")
  local trPrev = transforms[prev.tParent.nId]
  assert(trPrev ~= nil and math.abs(trPrev.pos:GetY() - 10.0) < 0.05,
    "explore preview Y must sit on ground height (10.0), got " .. tostring(trPrev and trPrev.pos:GetY()))
  -- Avatar faces toward camera at (10, 25, 10) from (10, 10, 20) -> direction (0, -10) -> yaw ~ +/-pi
  assert(math.abs(math.abs(trPrev.yaw) - math.pi) < 0.15,
    "explore preview should face overhead camera (~pi), got " .. tostring(trPrev.yaw))

  -- Advance past $PickedUp_In duration (~0.85 s for TM) -> must crossfade into TM$PickedUp_Loop
  for _ = 1, 20 do
    WalkingCameraInitUIMode.Advance(initMode)
    Presence.Update(0.05, false)
  end
  assert(prev.sPhase == "loop" and prev.tAnim.sClip == "TM$PickedUp_Loop",
    "explore preview must transition to TM$PickedUp_Loop, got phase=" .. tostring(prev.sPhase) ..
    " clip=" .. tostring(prev.tAnim.sClip))
  local bSawLoopAnim = false
  for _, c in ipairs(calls) do
    if c.name == "SetBaseAnimation" and c.args[2] == "TM$PickedUp_Loop" then
      bSawLoopAnim = true
    end
  end
  assert(bSawLoopAnim, "SetBaseAnimation(TM$PickedUp_Loop) was not called")

  -- Sweep cursor rapidly sideways (+X) -> pendulum spring tilts roll/pitch visibly around shoulder pivot
  -- (so the shoulder point at local Y=4.15 stays directly over the placement ring!), then settles on stop.
  local nMaxTilt = 0
  local nMaxPivotDrift = 0
  for i = 1, 10 do
    walkingStartPos = vec(10 + i * 0.4, 11.55, 20)
    WalkingCameraInitUIMode.Advance(initMode)
    Presence.Update(0.04, false)
    local trCur = transforms[prev.tParent.nId]
    local tilt = math.abs(trCur.pitch or 0) + math.abs(trCur.roll or 0)
    if tilt > nMaxTilt then nMaxTilt = tilt end
    local sr, cr = math.sin(trCur.roll or 0), math.cos(trCur.roll or 0)
    local sp, cp = math.sin(trCur.pitch or 0), math.cos(trCur.pitch or 0)
    local sy, cy = math.sin(trCur.yaw or 0), math.cos(trCur.yaw or 0)
    local H = 4.15
    local x1, y1 = -H * sr, H * cr
    local x2, y2, z2 = x1, y1 * cp, y1 * sp
    local shX = trCur.pos:GetX() + (x2 * cy + z2 * sy)
    local shZ = trCur.pos:GetZ() + (-x2 * sy + z2 * cy)
    local drift = math.sqrt((shX - prev.x)^2 + (shZ - prev.z)^2)
    if drift > nMaxPivotDrift then nMaxPivotDrift = drift end
  end
  assert(nMaxTilt > 0.08, "cursor sweep must produce visible pendulum dangle tilt, got " .. tostring(nMaxTilt))
  assert(nMaxPivotDrift < 1e-4, "shoulder pivot must stay centered over placement ring, got drift=" .. tostring(nMaxPivotDrift))
  -- Hold cursor still for ~1.5 s -> pendulum settles smoothly back upright
  for _ = 1, 40 do
    WalkingCameraInitUIMode.Advance(initMode)
    Presence.Update(0.04, false)
  end
  local trRest = transforms[prev.tParent.nId]
  assert(math.abs(trRest.pitch or 0) < 0.02 and math.abs(trRest.roll or 0) < 0.02,
    "pendulum tilt must settle back upright when cursor stops")

  -- Invalid spot (vStartingPos == nil): preview hides and parks underground, click emits Staff_Invalid_Placement
  calls = {}
  walkingStartPos = nil
  mouseInputOverride = {Button = "mouseleft", Action = "click", RawZAxis = 0}
  WalkingCameraInitUIMode.Advance(initMode)
  Presence.Update(0.05, false)
  mouseInputOverride = nil
  assert(prev.bHidden == true and transforms[prev.tParent.nId].pos:GetY() < -500,
    "invalid spot must hide and park explore preview")
  local bSawInvalidAudio = false
  for _, c in ipairs(calls) do
    if c.name == "SendGUIEvent" and c.args[1] == "Staff_Invalid_Placement" then
      bSawInvalidAudio = true
    end
  end
  assert(bSawInvalidAudio, "clicking invalid spot in WalkingCameraInit should play Staff_Invalid_Placement")

  -- Return to valid spot -> unhides cleanly
  walkingStartPos = vec(15, 11.55, 22)
  WalkingCameraInitUIMode.Advance(initMode)
  Presence.Update(0.05, false)
  assert(prev.bHidden == false and math.abs(transforms[prev.tParent.nId].pos:GetX() - 15.0) < 0.1,
    "returning to valid spot must unhide and reposition explore preview")

  -- Clicking valid spot -> TryRequestWalkingMode plays TM$PickedUp_Out as a non-looping one-shot over
  -- $PickedUp_Loop (never looping back to the sky), immediately enters WalkingCamera with a simultaneous
  -- smooth cubic ease-out camera move, keeps the player planted on the ground, and adopts the avatar seamlessly.
  local nPrevParentId = prev.tParent.nId
  local nPrevAvatarId = prev.nAvatar
  Presence.SetThirdPerson(true)
  calls = {}
  assert(cmm:TryRequestWalkingMode() == false, "TryRequestWalkingMode wrap should open native explore")
  local bSawDropOutOneShot = false
  local bSawIdleBeforeOut = false
  for _, c in ipairs(calls) do
    if c.name == "QueueOneShotAnimation" and c.args[1] == nPrevAvatarId and c.args[2] == "TM$PickedUp_Out" then
      bSawDropOutOneShot = true
    elseif c.name == "SetBaseAnimation" and c.args[1] == nPrevAvatarId and c.args[2] == "TM$StandBaseIdle01" then
      bSawIdleBeforeOut = true
    end
  end
  assert(bSawDropOutOneShot, "clicking valid spot must play TM$PickedUp_Out as a non-looping one-shot")
  assert(not bSawIdleBeforeOut, "must not clear base to StandBaseIdle01 before one-shot covers the body")
  local setWalk = lastCall("SetNewMode")
  assert(setWalk ~= nil and setWalk.args[1] == "WalkingCamera",
    "camera must immediately begin transitioning to WalkingCamera")
  assert(__PZ2CoopPresenceState.nCamDist == 3.5,
    "camera distance must start at third person (3.5 m) on drop transition, got " .. tostring(__PZ2CoopPresenceState.nCamDist))
  assert(__PZ2CoopPresenceState.tExploreCamEase ~= nil, "smooth camera ease-out state must be initialized")
  assert(__PZ2CoopPresenceState.sExploreUIState == "entering", "Explore UI must start hidden while camera eases in")

  uiMode = "WalkingCamera"
  WalkingCameraInitUIMode.TransitionOut(initMode)
  assert(transforms[nPrevParentId] ~= nil, "falling avatar must stay alive across WalkingCameraInit -> WalkingCamera handoff")

  mode = "Walking"
  walkingData.tFinal.vCameraPos = vec(5, 30, 5) -- simulate vanilla WalkingCamera still high in sky on frame 1
  walkingData.tFinal.vCameraYPR = vec(0, 0, 0)
  local tEaseRef = __PZ2CoopPresenceState.tExploreCamEase
  WalkingCamera.Advance(walkingData, tWorldAPIs, 0.4)
  Presence.Update(0.4, false)
  assert(Presence.GetExplorePreview() == nil, "explore preview must be cleared after handoff")
  assert(__PZ2CoopPresenceState.tOwnBody ~= nil and
    __PZ2CoopPresenceState.tOwnBody.tParent.nId == nPrevParentId and
    __PZ2CoopPresenceState.tOwnBody.nAvatar == nPrevAvatarId,
    "own body must seamlessly adopt the explore preview avatar")
  assert(math.abs(transforms[nPrevParentId].pos:GetX() - tEaseRef.dropX) < 0.01 and
    math.abs(transforms[nPrevParentId].pos:GetY() - tEaseRef.dropY) < 0.01,
    "player body must stay planted at drop spot instead of flying with sky camera")
  local midCamY = walkingData.tFinal.transformQ.pos:GetY()
  assert(midCamY > tEaseRef.dropEyeY and midCamY < tEaseRef.startY,
    "camera must be smoothly easing down from free-cam to third person, got y=" .. tostring(midCamY))

  -- Finish camera ease-out (1.6 s) and $PickedUp_Out -> $StandBaseIdle01 settle (2.0 s)
  for _ = 1, 18 do
    WalkingCamera.Advance(walkingData, tWorldAPIs, 0.1)
    Presence.Update(0.1, false)
  end
  assert(__PZ2CoopPresenceState.tExploreCamEase == nil, "camera ease-out must finish cleanly")
  assert(__PZ2CoopPresenceState.sExploreUIState == "visible", "Explore UI must fade in once camera transition stops")
  local bClearedToIdle = false
  for _, c in ipairs(calls) do
    if c.name == "SetBaseAnimation" and c.args[1] == nPrevAvatarId and c.args[2] == "TM$StandBaseIdle01" then
      bClearedToIdle = true
    end
  end
  assert(bClearedToIdle, "base layer must switch to TM$StandBaseIdle01 underneath the active one-shot")

  -- Restore state before cleanup check 12
  Presence.SetThirdPerson(false)
  mode = "Standard"
  uiMode = "Select"
  walkingStartPos = nil
  Presence.Update(0.05, false)
end

-- 12) leaving solo mode: friend times out, entities and label removed
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
