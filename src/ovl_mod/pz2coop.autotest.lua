-- Autonomous in-game feature test driver (triggered ONLY by <game>\PZ2Coop\autotest.txt via tools/test_live_game.py).
-- Completely inert during normal gameplay: zero timers, zero hooks, zero allocations unless Start(plan) is called.
local global = _G
local api = global.api
local string = global.string
local table = global.table
local math = global.math
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local type = global.type
local rawget = global.rawget
local rawset = global.rawset
local setmetatable = global.setmetatable
local next = global.next
local coroutine = global.coroutine
local require = global.require
local Bridge = require("PZ2Coop.Bridge")

local Autotest = module(...)

local c_sTestZoo = "/run/PZ2Coop/PZ2Coop_Baseline.bin"

local s = rawget(global, "__PZ2CoopAutotestState")
if s == nil then
  s = {
    bActive = false,
    sPlan = nil,
    sStage = "idle",
    nStageTime = 0,
    nPass = 0,
    nFail = 0,
    bLoadRequested = false,
    bHostRequested = false,
    bExploreStarted = false,
    tAnimProbe = nil,
    bStaffHireSent = false,
    bStaffFireSent = false,
    nStaffCountBefore = 0,
    sStaffSyncId = "autotest_keeper_1",
  }
  rawset(global, "__PZ2CoopAutotestState", s)
end

local Log = function(_sMsg)
  Bridge.Log("autotest: " .. _sMsg)
end

local Record = function(_sName, _bPass, _sDetail)
  if _bPass then
    s.nPass = s.nPass + 1
  else
    s.nFail = s.nFail + 1
  end
  Bridge.Log("AUTOTEST_CHECK " .. _sName .. " " .. (_bPass and "PASS" or "FAIL") ..
    (_sDetail and (" | " .. tostring(_sDetail)) or ""))
end

local SetStage = function(_sStage)
  s.sStage = _sStage
  s.nStageTime = 0
  Log("stage -> " .. _sStage)
end

local Finish = function()
  Bridge.SetLoopback(false)
  if Bridge.GetRole() ~= "none" then
    Bridge.SendCommand("leave")
  end
  Bridge.Log(string.format("AUTOTEST_SUMMARY pass=%d fail=%d", s.nPass, s.nFail))
  Bridge.Log("AUTOTEST_DONE")
  Bridge.Flush(true)
  s.bActive = false
  s.sStage = "done"
end

Autotest.Start = function(_sPlan)
  if s.bActive then
    return
  end
  s.bActive = true
  -- Trigger "<plan>,run.<run_id>[,expref.<n>]" (tools/test_live_game.py): run_id is a per-run nonce, expref the
  -- path chunk count read from the fixture file itself (never measured from the build under test).
  local sTrigger = tostring(_sPlan or "full")
  s.sPlan = string.match(sTrigger, "^([^,]+)") or "full"
  s.sRunId = string.match(sTrigger, ",run%.([%w_-]+)") or "none"
  s.nExpRef = tonumber(string.match(sTrigger, ",expref%.(%d+)") or "")
  local bMeta, BuildMeta = pcall(require, "PZ2Coop.Build_Meta")
  local tMeta = bMeta and type(BuildMeta) == "table" and BuildMeta or {}
  Bridge.Log("AUTOTEST_META run_id=" .. s.sRunId .. " build_hash=" .. tostring(tMeta.BUILD_SOURCE_HASH or "none") ..
    " test_hash=" .. tostring(tMeta.BUILD_TEST_HASH or "none") .. " plan=" .. s.sPlan)
  s.nPass = 0
  s.nFail = 0
  s.bLoadRequested = false
  s.bHostRequested = false
  s.bExploreStarted = false
  s.tAnimProbe = nil
  s.bStaffHireSent = false
  s.bStaffFireSent = false
  Log("started plan=" .. s.sPlan)
  if Bridge.IsSyncedPark() then
    Record("boot_menu", true, "already in synced park")
    SetStage("park_host")
  else
    SetStage("wait_menu")
  end
end

local CountStaff = function()
  local bOk, tAll = pcall(function()
    return api.world.GetWorldAPIs().staff:GetAllStaffEntities()
  end)
  if not bOk or type(tAll) ~= "table" then
    return nil
  end
  return #tAll
end

local FindStaffSpawnPosCm = function()
  local tWorld = api.world.GetWorldAPIs()
  local bOk, vPos = pcall(function()
    local tAll = tWorld.staff:GetAllStaffEntities()
    if type(tAll) == "table" and #tAll > 0 then
      local tr = tWorld.transform:CalculateWorldTransform(tAll[1])
      return tr and (tr.GetPos and tr:GetPos() or tr:Pos())
    end
    local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
    return vCam
  end)
  if bOk and vPos ~= nil then
    local bC, x, y, z = pcall(function() return vPos:GetX(), vPos:GetY(), vPos:GetZ() end)
    if bC and type(x) == "number" then
      return math.floor(x * 100 + 0.5), math.floor(y * 100 + 0.5), math.floor(z * 100 + 0.5)
    end
  end
  return 0, 0, 0
end

local StepMenu = function()
  if Bridge.IsSyncedPark() then
    Record("park_load", true, "entered synced park")
    SetStage("park_host")
    return
  end
  local tUi = rawget(global, "__PZ2CoopUIState")
  local bOverlayOk = tUi ~= nil and tUi.sOverlay == "mapped"
  local bMenuReady = tUi ~= nil and tUi.bMenuListenerAdded == true
  if not s.bLoadRequested then
    if Bridge.IsStartScreenActive() and bOverlayOk and bMenuReady then
      s.nMenuReadyTime = (s.nMenuReadyTime or 0) + 0.05
      if s.nMenuReadyTime < 3.0 then
        return
      end
      Record("boot_menu", true, "overlay mapped + start screen activated + main menu ready")
      s.bLoadRequested = true
      local tEnv = api.game.GetEnvironment()
      local bOk, bLoaded, sErr = pcall(function()
        local nextWorld = tEnv:RequireInterface("Interfaces.INextWorldDataManager")
        nextWorld:SetIsWildArea(false)
        nextWorld:SetGameMode("Sandbox")
        if nextWorld.SetIsCareerExport ~= nil then
          nextWorld:SetIsCareerExport(false)
        end
        local pls = tEnv:RequireInterface("Interfaces.IParkLoadSaveManager")
        local bOkLoad, sLoadErr = pls:RequestLoadParkFromFile(c_sTestZoo)
        if not bOkLoad then
          local sFlat = "/run/Zoos/Sandbox/Flat/Sandbox_Zoo_01_BL_Rural.bin"
          Log("baseline missing, falling back to built-in flat Sandbox map: " .. sFlat)
          return pls:RequestLoadParkFromFile(sFlat)
        end
        return bOkLoad, sLoadErr
      end)
      Log("requested baseline zoo load: ok=" .. tostring(bOk) .. " loaded=" .. tostring(bLoaded) .. " err=" .. tostring(sErr))
      if not bOk or bLoaded == false then
        Record("park_load", false, "RequestLoadParkFromFile failed: " .. tostring(sErr))
        SetStage("cleanup")
      else
        SetStage("wait_park")
      end
    elseif s.nStageTime >= 45.0 then
      Record("boot_menu", false, "timed out waiting for menu/overlay (overlay=" .. tostring(tUi and tUi.sOverlay) ..
        " menuReady=" .. tostring(bMenuReady) .. " startScreen=" .. tostring(Bridge.IsStartScreenActive()) .. ")")
      SetStage("cleanup")
    end
  end
end

local StepWaitPark = function()
  if Bridge.IsSyncedPark() then
    if s.nStageTime >= 1.0 then
      Record("park_load", true, "synced Sandbox park loaded")
      SetStage("park_host")
    end
  elseif s.nStageTime >= 60.0 then
    Record("park_load", false, "timed out waiting for park load")
    SetStage("cleanup")
  end
end

local StepParkHost = function()
  if not s.bHostRequested then
    s.bHostRequested = true
    Bridge.SendCommand("host")
    Log("sent host command")
    return
  end
  if Bridge.GetRole() == "host" and Bridge.GetSession().sCode ~= nil then
    Record("host_room", true, "code=" .. tostring(Bridge.GetSession().sCode))
    if s.sPlan == "fences_water" then
      Bridge.SetLoopback(false)
      SetStage("fw_inspect")
    elseif s.sPlan == "showcase" then
      Bridge.SetLoopback(false)
      SetStage("sc_prepare")
    elseif s.sPlan == "gate_probe" then
      Bridge.SetLoopback(false)
      SetStage("gp_setup")
    elseif s.sPlan == "explore_preview" then
      Bridge.SetLoopback(false)
      SetStage("ep_enter")
    elseif s.sPlan == "mirror_place" then
      SetStage("mp_setup")
    else
      Bridge.SetLoopback(true)
      SetStage("test_notifications")
    end
  elseif s.nStageTime >= 20.0 then
    Record("host_room", false, "role=" .. tostring(Bridge.GetRole()) .. " err=" .. tostring(Bridge.GetSession().sError))
    SetStage("cleanup")
  end
end

local StepNotifications = function()
  local bOk, sInfo = pcall(function()
    local worldScript = api.world.GetScript(api.world.GetActive())
    local nm = worldScript.tEnvironment:RequestInterface("Interfaces.INotificationManager")
    if nm == nil or type(nm.tTimelinePopOutQueue) ~= "table" then
      return "missing INotificationManager or tTimelinePopOutQueue"
    end
    local nBefore = #nm.tTimelinePopOutQueue
    table.insert(nm.tTimelinePopOutQueue, {
      nTimeShown = 0,
      bActionable = false,
      sColour = "Green",
      tEntry = {
        sTimelineEntryName = "VIPEntered",
        sNotificationString = "[STRING_LITERAL:Value=|Autotest friend joined your zoo|]",
      },
    })
    return #nm.tTimelinePopOutQueue == nBefore + 1 and "ok" or "queue did not grow"
  end)
  Record("notifications", bOk and sInfo == "ok", tostring(sInfo))
  SetStage("test_presence")
end

local StepPresence = function()
  local Presence = require("PZ2Coop.Presence")
  local Avatar = require("PZ2Coop.Avatar")
  local tPres = rawget(global, "__PZ2CoopPresenceState")
  if not s.bExploreStarted then
    s.bExploreStarted = true
    -- Log live engine animation API availability so Phase 1 results are immediately visible in diag.log.
    local tWorld = api.world.GetWorldAPIs()
    local ac = api.animationcontrol
    local anim = tWorld and tWorld.animation
    local baked = tWorld and tWorld.bakedanimation
    Log(string.format("anim APIs: ac=%s setBase=%s setRate=%s isPlaying=%s | world.anim=%s play=%s | world.baked=%s",
      tostring(ac ~= nil), tostring(ac and ac.SetBaseAnimation ~= nil),
      tostring(ac and ac.SetPlaybackRate ~= nil), tostring(ac and ac.IsRequestedBaseAnimationPlayingNow ~= nil),
      tostring(anim ~= nil), tostring(anim and anim.PlayAnimation ~= nil),
      tostring(baked ~= nil)))
    Presence.SetThirdPerson(true)
    local bOk, sErr = pcall(function()
      local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
      require("Editors.Shared.BaseUIMode").SetNewMode("WalkingCamera", {vStartingPos = vCam})
    end)
    Log("entered explore on foot for avatar test: ok=" .. tostring(bOk) .. " err=" .. tostring(sErr))
    return
  end
  local bOwnReady = tPres and tPres.tOwnBody and tPres.tOwnBody.nAvatar ~= nil
  local bFriendData = tPres and tPres.tFriendAvatarData ~= nil
  local bFriendReady = tPres and tPres.tFriendBody and tPres.tFriendBody.nAvatar ~= nil
  if (bOwnReady and bFriendReady) or s.nStageTime >= 12.0 then
    local bOwnAnim = tPres and tPres.tOwnBody and tPres.tOwnBody.tAnim and tPres.tOwnBody.tAnim.bAnimated == true
    local bFriendAnim = tPres and tPres.tFriendBody and tPres.tFriendBody.tAnim and tPres.tFriendBody.tAnim.bAnimated == true
    Record("presence_avatars", bFriendData and (bOwnReady or bFriendReady),
      string.format("own=%s(anim=%s) friendData=%s friendAvatar=%s(anim=%s)",
        tostring(bOwnReady), tostring(bOwnAnim), tostring(bFriendData), tostring(bFriendReady), tostring(bFriendAnim)))
    if bOwnReady and bOwnAnim then
      local nOwn = tPres.tOwnBody.nAvatar
      local tWorld = api.world.GetWorldAPIs()
      local tParts = {}
      local nHeadRig = tPres.tOwnBody.tAnim and tPres.tOwnBody.tAnim.nHeadRig
      for _, sP in ipairs({"Head", "Hair", "Torso", "Legs"}) do
        local pId = api.entity.FindEntityByName(sP, nOwn) or (nHeadRig and api.entity.FindEntityByName(sP, nHeadRig))
        table.insert(tParts, sP .. "=" .. tostring(pId ~= nil))
      end
      Log("own avatar parts: " .. table.concat(tParts, " "))
      -- Attach bone probes to left foot & head to measure real skeletal motion across rendered frames.
      local tok = api.entity.CreateRequestCompletionToken()
      local nFootProbe = api.entity.InstantiatePrefab("AttachPoint", "PZ2CoopFootProbe", tok, nil, nOwn, true,
        {AttachBone = "def_l_foot_joint"})
      local nHeadProbe = api.entity.InstantiatePrefab("AttachPoint", "PZ2CoopHeadProbe", tok, nil, nOwn, true,
        {AttachBone = "def_c_head_joint"})
      pcall(function()
        if tWorld.bakedanimation and tWorld.bakedanimation.RequestAllBonesForCalculate then
          tWorld.bakedanimation:RequestAllBonesForCalculate(nOwn)
        end
      end)
      s.tAnimProbe = {
        tok = tok,
        nFoot = nFootProbe,
        nHead = nHeadProbe,
        nPhase = 1,
        nPhaseTime = 0,
        tPhases = {
          {name = "idle", speed = 0.0, water = false, dur = 0.6},
          {name = "walk", speed = 2.0, water = false, dur = 1.0},
          {name = "run", speed = 5.5, water = false, dur = 1.0},
          {name = "swim", speed = 1.5, water = true, dur = 1.0},
          {name = "idle2", speed = 0.0, water = false, dur = 0.5},
        },
        tStats = {},
        tCur = nil,
      }
      SetStage("test_presence_anim")
      return
    end
    Record("avatar_animations", false, "no own animated avatar built")
    SetStage("test_presence_done")
  end
end

local SampleBoneRange = function(_tAcc, _nEntityID)
  if _nEntityID == nil then
    return
  end
  local tWorld = api.world.GetWorldAPIs()
  local bOk, tr = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, _nEntityID)
  if not bOk or tr == nil then
    return
  end
  local bPos, v = pcall(function() return tr.GetPos and tr:GetPos() or tr:Pos() end)
  if not bPos or v == nil then
    return
  end
  local x, y, z = v:GetX(), v:GetY(), v:GetZ()
  if _tAcc.n == 0 then
    _tAcc.minX, _tAcc.maxX = x, x
    _tAcc.minY, _tAcc.maxY = y, y
    _tAcc.minZ, _tAcc.maxZ = z, z
  else
    if x < _tAcc.minX then _tAcc.minX = x end
    if x > _tAcc.maxX then _tAcc.maxX = x end
    if y < _tAcc.minY then _tAcc.minY = y end
    if y > _tAcc.maxY then _tAcc.maxY = y end
    if z < _tAcc.minZ then _tAcc.minZ = z end
    if z > _tAcc.maxZ then _tAcc.maxZ = z end
  end
  _tAcc.n = _tAcc.n + 1
end

local RangeSpan = function(_tAcc)
  if _tAcc == nil or _tAcc.n < 2 then
    return 0
  end
  local dx = _tAcc.maxX - _tAcc.minX
  local dy = _tAcc.maxY - _tAcc.minY
  local dz = _tAcc.maxZ - _tAcc.minZ
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local StepPresenceAnim = function()
  local Avatar = require("PZ2Coop.Avatar")
  local tPres = rawget(global, "__PZ2CoopPresenceState")
  local p = s.tAnimProbe
  local tOwn = tPres and tPres.tOwnBody
  local tFriend = tPres and tPres.tFriendBody
  if p == nil or tOwn == nil or tOwn.nAvatar == nil or tOwn.tAnim == nil then
    Record("avatar_animations", false, "own avatar disappeared during anim test")
    SetStage("test_presence_done")
    return
  end
  if not api.entity.HaveRequestsCompleted(p.tok) and s.nStageTime < 3.0 then
    return
  end
  local tPhase = p.tPhases[p.nPhase]
  if p.tCur == nil then
    p.tCur = {foot = {n = 0}, head = {n = 0}, playingStart = nil, playingEnd = nil}
    p.nPhaseTime = 0
    -- Drive smoother straight into target gait so frames tick in this state (with native crossfade blend).
    for _ = 1, 15 do
      Avatar.UpdateAnimation(tOwn.tAnim, tOwn.nAvatar, tPhase.speed, 0.1, tPhase.water)
      if tFriend ~= nil and tFriend.nAvatar ~= nil and tFriend.tAnim ~= nil then
        Avatar.UpdateAnimation(tFriend.tAnim, tFriend.nAvatar, tPhase.speed, 0.1, tPhase.water)
      end
    end
    local bOk, bPl = pcall(api.animationcontrol.IsRequestedBaseAnimationPlayingNow, tOwn.nAvatar)
    p.tCur.playingStart = bOk and bPl or "err"
    p.tCur.clip = tOwn.tAnim.sClip
  end

  local tWorld = api.world.GetWorldAPIs()
  pcall(function()
    if tWorld.bakedanimation and tWorld.bakedanimation.RequestAllBonesForCalculate then
      tWorld.bakedanimation:RequestAllBonesForCalculate(tOwn.nAvatar)
    end
  end)
  -- Keep driving target speed/water state so Presence.Update doesn't pull it back to idle during probes.
  Avatar.UpdateAnimation(tOwn.tAnim, tOwn.nAvatar, tPhase.speed, 0.05, tPhase.water)
  if tFriend ~= nil and tFriend.nAvatar ~= nil and tFriend.tAnim ~= nil then
    Avatar.UpdateAnimation(tFriend.tAnim, tFriend.nAvatar, tPhase.speed, 0.05, tPhase.water)
  end
  SampleBoneRange(p.tCur.foot, p.nFoot)
  SampleBoneRange(p.tCur.head, p.nHead)
  p.nPhaseTime = p.nPhaseTime + 0.05

  if p.nPhaseTime >= tPhase.dur then
    local bOk, bPl = pcall(api.animationcontrol.IsRequestedBaseAnimationPlayingNow, tOwn.nAvatar)
    p.tCur.playingEnd = bOk and bPl or "err"
    local nFootSpan = RangeSpan(p.tCur.foot)
    local nHeadSpan = RangeSpan(p.tCur.head)
    table.insert(p.tStats, string.format("%s=%s(foot=%.3fm,head=%.3fm,n=%d,play=%s->%s)",
      tPhase.name, tostring(p.tCur.clip), nFootSpan, nHeadSpan, p.tCur.foot.n,
      tostring(p.tCur.playingStart), tostring(p.tCur.playingEnd)))
    p.tStats[tPhase.name] = {foot = nFootSpan, head = nHeadSpan, clip = p.tCur.clip, playingEnd = p.tCur.playingEnd}
    p.nPhase = p.nPhase + 1
    p.tCur = nil
    if p.nPhase > #p.tPhases then
      if p.nFoot then pcall(api.entity.DestroyEntity, p.nFoot) end
      if p.nHead then pcall(api.entity.DestroyEntity, p.nHead) end
      local bWalkMoved = p.tStats.walk ~= nil and p.tStats.walk.foot > 0.10
      local bRunMoved = p.tStats.run ~= nil and p.tStats.run.foot > 0.15
      local bSwimMoved = p.tStats.swim ~= nil and p.tStats.swim.foot > 0.10
      local bNoErr = not tOwn.tAnim.bErrorLogged and (tFriend == nil or tFriend.tAnim == nil or not tFriend.tAnim.bErrorLogged)
      Record("avatar_animations", bNoErr and bWalkMoved and bRunMoved and bSwimMoved, table.concat(p.tStats, " | "))
      -- Live-engine head-look verification: verify HeadRig RenderGroup transform, def_c_neck1_joint pivot, clamping, & 180-deg neutral.
      local bHeadOk, bHeadPass, sHeadDetail = pcall(function()
        local nHeadRig = tOwn.tAnim.nHeadRig
        local tHeadParts = tOwn.tAnim.tHeadParts
        local nNeck = tOwn.tAnim.nNeckAttach
        if nHeadRig == nil or type(tHeadParts) ~= "table" or #tHeadParts < 1 then
          return false, "no HeadRig or headParts recorded"
        end
        local bHasTr = tWorld.transform:HasTransform(nHeadRig) == true
        local trAv = tWorld.transform:CalculateWorldTransform(tOwn.nAvatar)
        local trNk = nNeck and tWorld.transform:CalculateWorldTransform(nNeck) or nil
        local nNeckX, nNeckY, nNeckZ = nil, nil, nil
        if trAv ~= nil and trNk ~= nil and trAv.ToLocalPos ~= nil then
          local vPos = trNk.GetPos and trNk:GetPos() or (trNk.Pos and trNk:Pos())
          local vLoc = vPos and trAv:ToLocalPos(vPos) or nil
          if vLoc ~= nil then
            nNeckX = vLoc.GetX and vLoc:GetX() or vLoc:X()
            nNeckY = vLoc.GetY and vLoc:GetY() or vLoc:Y()
            nNeckZ = vLoc.GetZ and vLoc:GetZ() or vLoc:Z()
          end
        end
        -- Drive forward (+40/-20), verify engine actually applied local transform to HeadRig!
        local yFwd, pFwd = 0, 0
        for _ = 1, 25 do
          yFwd, pFwd = Avatar.UpdateHeadLook(tOwn.tAnim, tOwn.nAvatar, math.rad(40), math.rad(-20), 0, 0, 0.05, false, false)
        end
        local trRigAfter = tWorld.transform:GetTransform(nHeadRig)
        local nRigYawDeg = nil
        if trRigAfter ~= nil and trRigAfter.GetOr ~= nil then
          local vY = trRigAfter:GetOr():ToYawPitchRoll()
          nRigYawDeg = vY and math.deg(vY.GetX and vY:GetX() or vY:X()) or nil
        end
        local yPeriph = 0
        for _ = 1, 25 do
          yPeriph = Avatar.UpdateHeadLook(tOwn.tAnim, tOwn.nAvatar, math.rad(90), 0, 0, 0, 0.05, false, false)
        end
        local ySelf, pSelf = 0, 0
        for _ = 1, 35 do
          ySelf, pSelf = Avatar.UpdateHeadLook(tOwn.tAnim, tOwn.nAvatar, math.rad(180), math.rad(-20), 0, 0, 0.05, false, false)
        end
        local bFriendHead = tFriend ~= nil and tFriend.tAnim ~= nil and tFriend.tAnim.nHeadRig ~= nil and
          type(tFriend.tAnim.tHeadParts) == "table" and #tFriend.tAnim.tHeadParts >= 1
        local bPass = bHasTr and (type(nNeckY) == "number" and nNeckY >= 0.9 and nNeckY <= 1.8) and
          (type(nRigYawDeg) == "number" and nRigYawDeg > 25) and
          yFwd > math.rad(25) and pFwd < math.rad(-10) and yPeriph <= math.rad(49) and
          math.abs(ySelf) < 0.03 and math.abs(pSelf) < 0.03
        return bPass, string.format("rig=%s parts=%d hasTr=%s rigYaw=%s neck=(%s,%s,%s) fwd=(%.1f,%.1f) periph=%.1f self=(%.1f,%.1f) friendHead=%s",
          tostring(nHeadRig), #tHeadParts, tostring(bHasTr),
          nRigYawDeg and string.format("%.1f", nRigYawDeg) or "nil",
          nNeckX and string.format("%.3f", nNeckX) or "nil",
          nNeckY and string.format("%.3f", nNeckY) or "nil",
          nNeckZ and string.format("%.3f", nNeckZ) or "nil",
          math.deg(yFwd), math.deg(pFwd), math.deg(yPeriph), math.deg(ySelf), math.deg(pSelf), tostring(bFriendHead))
      end)
      Record("head_look", bHeadOk and bHeadPass == true, tostring(bHeadOk and sHeadDetail or bHeadPass))
      s.tAnimProbe = nil
      SetStage("test_presence_done")
    end
  end
end

local StepPresenceDone = function()
  local Presence = require("PZ2Coop.Presence")
  local bViewOk, sViewErr = pcall(function()
    Presence.RequestViewFriend()
    Presence.Update(0.05, true)
  end)
  Record("view_friend_camera", bViewOk, tostring(sViewErr or "ok"))
  Presence.SetThirdPerson(false)
  pcall(function()
    require("Editors.Shared.BaseUIMode").SetNewMode("Select")
  end)
  SetStage("test_water")
end

local StepWater = function()
  local bOk, sDetail = pcall(function()
    local gt = api.world.GetWorldAPIs().gameterrain
    local tLakes = gt:GetAllLakes()
    if type(tLakes) ~= "table" then
      return "GetAllLakes returned " .. type(tLakes)
    end
    local sExtra = "lakes=" .. #tLakes
    if #tLakes > 0 then
      local vFill = gt:FindLakeRefillPoint(tLakes[1])
      local tProps = gt:GetLakeRespawnProperties(tLakes[1])
      sExtra = sExtra .. " fill=" .. tostring(vFill ~= nil) .. " props=" .. tostring(type(tProps) == "table") ..
        " surf=" .. tostring(type(tProps) == "table" and tProps.sSurfaceMaterialName or nil)
    end
    return "ok:" .. sExtra
  end)
  Record("water_apis", bOk and type(sDetail) == "string" and string.sub(sDetail, 1, 3) == "ok:", tostring(sDetail))
  SetStage("test_staff")
end

local StepStaff = function()
  local StaffSync = require("PZ2Coop.StaffSync")
  if not s.bStaffHireSent then
    s.bStaffHireSent = true
    s.nStaffCountBefore = CountStaff() or 0
    local x, y, z = FindStaffSpawnPosCm()
    StaffSync.OnPacket({
      nType = 0x30,
      tData = {k = "staff", op = "hire", t = "Keeper", id = s.sStaffSyncId, x = x, y = y, z = z},
    })
    Log("queued live staff hire Keeper at " .. x .. "," .. y .. "," .. z)
    return
  end
  if not s.bStaffFireSent then
    local nNow = CountStaff() or 0
    if StaffSync.HasSyncId(s.sStaffSyncId) or s.nStageTime >= 6.0 then
      s.bStaffFireSent = true
      s.bHireWorked = StaffSync.HasSyncId(s.sStaffSyncId) and nNow > s.nStaffCountBefore
      Log("staff count after hire: " .. s.nStaffCountBefore .. " -> " .. nNow)
      local x, y, z = FindStaffSpawnPosCm()
      StaffSync.OnPacket({
        nType = 0x30,
        tData = {k = "staff", op = "fire", t = "Keeper", id = s.sStaffSyncId, x = x, y = y, z = z},
      })
      s.nFireSentAt = s.nStageTime
    end
    return
  end
  local bFired = not StaffSync.HasSyncId(s.sStaffSyncId)
  if bFired or (s.nStageTime - (s.nFireSentAt or 0)) >= 4.0 then
    Record("staff_hire_fire", s.bHireWorked == true and bFired,
      string.format("before=%d hired=%s fired=%s", s.nStaffCountBefore, tostring(s.bHireWorked), tostring(bFired)))
    SetStage("test_ledger")
  end
end

local StepLedger = function()
  local bOk, sDetail = pcall(function()
    local tWorld = api.world.GetWorldAPIs()
    local money = tWorld.money
    local worldScript = api.world.GetScript(api.world.GetActive())
    local mainHUD = worldScript and worldScript.GetHUD and worldScript:GetHUD()
    local tSim = mainHUD and mainHUD.GetSimulationTimeSettings and mainHUD:GetSimulationTimeSettings()
    local nHour, nMin = tWorld.park:GetTimeOfDay()
    return string.format("cash=%.2f unlimited=%s sim=%s tod=%s:%s exhibits=%s",
      money:GetCash(), tostring(money:HasUnlimitedCash()),
      tostring(type(tSim) == "table"), tostring(nHour), tostring(nMin),
      tostring(tWorld.exhibits ~= nil))
  end)
  Record("ledger_speed_tod_exhibit", bOk, tostring(sDetail))
  SetStage("cleanup")
end

local StepCleanup = function()
  if s.nStageTime >= 1.5 then
    Finish()
  end
end

-- ---- fences & water live-game verification plan (--plan fences_water) ------------------------------------
local RaycastGroundY = function(_x, _z, _nFallback)
  local bOk, y = pcall(function()
    local Vector3 = require("Vector3")
    local tWorld = api.world.GetWorldAPIs()
    local nTerrainId = tWorld.CameraModeManager:GetVoxelTerrainID()
    local nDist = tWorld.voxelterrain:RayCast(nTerrainId, Vector3:new(_x, 200, _z), Vector3:new(0, -1, 0), 400)
    if type(nDist) == "number" then
      return 200 - nDist
    end
    return nil
  end)
  return (bOk and type(y) == "number") and y or (_nFallback or 0)
end

local CountFenceInBox = function(_x, _y, _z, _r)
  local Vector3 = require("Vector3")
  local tWorld = api.world.GetWorldAPIs()
  local api_hb = tWorld.habitatboundary
  local tHits = tWorld.spatial:CylinderQuery(Vector3:new(_x, _y - 10, _z), Vector3:new(_x, _y + 20, _z),
    _r, tWorld.spatial.Flag_HabitatBoundary, 0, 2000) or {}
  local tPosts, tPanels, tHabs, tSeen = {}, {}, {}, {}
  local nPosts, nPanels, nHabs = 0, 0, 0
  local pih = tWorld.PlayerInteractionHandler
  for _, nHit in ipairs(tHits) do
    local nOwner = nHit
    pcall(function()
      if pih:HasParentEntityID(nOwner) then nOwner = pih:GetParentID(nOwner) end
      if not pih:HasPlayerInteractionHandlerComponent(nOwner) then nOwner = tWorld.transform:GetParent(nOwner) or nOwner end
    end)
    for _, nEnt in ipairs({nOwner, nHit}) do
      if nEnt ~= nil and not tSeen[nEnt] then
        tSeen[nEnt] = true
        local bOk, bHit, oPanel, oPost = pcall(api_hb.GetBoundaryObjectFromEntity, api_hb, nEnt)
        if bOk and bHit then
          if oPost ~= nil then
            local k = tostring(oPost:GetAllData().nEntityID or oPost)
            if not tPosts[k] then tPosts[k] = oPost nPosts = nPosts + 1 end
            pcall(function()
              for hid in pairs(api_hb:GetHabitatsFromBoundaryObject(oPost) or {}) do
                if not tHabs[hid] then tHabs[hid] = true nHabs = nHabs + 1 end
              end
            end)
          end
          if oPanel ~= nil then
            local k = tostring(oPanel:GetAllData().nEntityID or oPanel)
            if not tPanels[k] then tPanels[k] = oPanel nPanels = nPanels + 1 end
            pcall(function()
              for hid in pairs(api_hb:GetHabitatsFromBoundaryObject(oPanel) or {}) do
                if not tHabs[hid] then tHabs[hid] = true nHabs = nHabs + 1 end
              end
            end)
          end
        end
      end
    end
  end
  return nPosts, nPanels, nHabs, tPosts, tPanels
end

local Arr = function(...)
  local t = setmetatable({...}, api.json.GetArrayMetatable())
  return t
end

local MakePost = function(_x, _y, _z, _dx, _dz, _sType, _h)
  return {
    f = {sBoundaryType = _sType, nWorldHeight = _y + (_h or 2.5)},
    v = {vPos = Arr(_x, _y, _z), vDir = Arr(_dx, 0, _dz)},
  }
end

local MakePanel = function(_iS, _iE, _pS, _pE, _sType)
  local sx, sy, sz = _pS.v.vPos[1], _pS.v.vPos[2], _pS.v.vPos[3]
  local ex, ey, ez = _pE.v.vPos[1], _pE.v.vPos[2], _pE.v.vPos[3]
  local dx, dz = ex - sx, ez - sz
  local len = math.sqrt(dx * dx + dz * dz)
  if len > 1e-4 then dx, dz = dx / len, dz / len else dx, dz = 1, 0 end
  return {
    s = _iS,
    e = _iE,
    f = {
      nWorldHeightStart = _pS.f.nWorldHeight,
      nWorldHeightEnd = _pE.f.nWorldHeight,
      nPanelMode = 0,
      nHeightAngleStart = 0,
      nHeightAngleEnd = 0,
      nWindowCutDistFromBase = 0,
      nWindowCutDistFromTop = 0,
      nRandomUVLengthOffset = 0,
      nBoundaryExtraFlags = 0,
      sBoundaryType = _sType,
      bHabitatWall = true,
      nSmoothness = 0,
      nMaxDurability = 100,
    },
    v = {
      vBasePosStart = Arr(sx, sy, sz),
      vDirStart = Arr(dx, 0, dz),
      vBasePosEnd = Arr(ex, ey, ez),
      vDirEnd = Arr(dx, 0, dz),
    },
  }
end

local StepFWInspect = function()
  local tWorld = api.world.GetWorldAPIs()
  local gt = tWorld.gameterrain
  local tLakes = gt:GetAllLakes() or {}
  local tHabs = (tWorld.facilities and tWorld.facilities:GetAllHabitatsEntityIDs()) or {}
  local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
  local cx, cz = vCam:GetX(), vCam:GetZ()
  -- Find a clear open flat spot where BOTH (tx, tz) AND loopback mirror (tx + 50, tz) have zero fences & zero water.
  local Vector3 = require("Vector3")
  local gx, gy, gz = cx, RaycastGroundY(cx, cz, 0), cz
  for _, tOff in ipairs({{0, 0}, {40, 0}, {-40, 0}, {0, 40}, {0, -40}, {-80, 40}, {80, 40}, {-80, -40}, {0, 80}, {0, -80}, {-120, 0}, {60, -80}}) do
    local tx, tz = cx + tOff[1], cz + tOff[2]
    local ty = RaycastGroundY(tx, tz, nil)
    local tyM = RaycastGroundY(tx + 50, tz, nil)
    if ty ~= nil and tyM ~= nil and math.abs(ty - tyM) < 0.3 then
      local np, nl = CountFenceInBox(tx + 4, ty, tz + 4, 18)
      local npM, nlM = CountFenceInBox(tx + 54, tyM, tz + 4, 18)
      local tNearLakes = gt:FindLakesWithSphereCheck(Vector3:new(tx + 4, ty, tz + 4), 20) or {}
      local tNearLakesM = gt:FindLakesWithSphereCheck(Vector3:new(tx + 54, tyM, tz + 4), 20) or {}
      if np == 0 and nl == 0 and npM == 0 and nlM == 0 and #tNearLakes == 0 and #tNearLakesM == 0 then
        gx, gy, gz = tx, ty, tz
        break
      end
    end
  end
  s.fw = {gx = gx, gy = gy, gz = gz, lakes = tLakes, sent = false, stepTime = 0}
  local sLakeDetail = "lakes=" .. #tLakes .. " habs=" .. #tHabs
  if #tLakes > 0 then
    local id = tLakes[1]
    local vFill = gt:FindLakeRefillPoint(id)
    local tProps = gt:GetLakeRespawnProperties(id)
    local vMin, vMax = nil, nil
    pcall(function() vMin, vMax = gt:GetLakeAABB(id) end)
    local tKeys = {}
    if type(tProps) == "table" then
      for k, v in pairs(tProps) do
        table.insert(tKeys, tostring(k) .. "=" .. type(v))
      end
      table.sort(tKeys)
    end
    s.fw.lake0 = {id = id, vFill = vFill, tProps = tProps, vMin = vMin, vMax = vMax}
    sLakeDetail = sLakeDetail .. " lake1_props={" .. table.concat(tKeys, ",") .. "}"
  end
  Log(string.format("fw_inspect: clear=(%.1f,%.1f,%.1f) %s", gx, gy, gz, sLakeDetail))
  Record("fw_inspect", true, sLakeDetail)
  SetStage("fw_single_post")
end

local StepFWSinglePost = function()
  local RegionSync = require("PZ2Coop.RegionSync")
  local fw = s.fw
  local tx, tz = fw.gx, fw.gz
  local ty = RaycastGroundY(tx, tz, fw.gy)
  if not fw.sent then
    fw.sent = true
    -- Send with ox=5000 (loopback shift) to verify Unpack shifts vPos but NOT vDir.
    local p1 = MakePost(tx - 50, ty, tz, 0, 1, "Brick_Red", 2.5)
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 1, ox = 5000,
        x0 = math.floor((tx - 55) * 100), y0 = math.floor((ty - 2) * 100), z0 = math.floor((tz - 5) * 100),
        x1 = math.floor((tx - 45) * 100), y1 = math.floor((ty + 6) * 100), z1 = math.floor((tz + 5) * 100),
        posts = Arr(p1), panels = Arr(),
      },
    })
    return
  end
  local nPosts, nPanels = CountFenceInBox(tx, ty, tz, 6)
  if nPosts >= 1 or s.nStageTime >= 8.0 then
    Record("fw_single_post", nPosts >= 1, string.format("posts=%d panels=%d (t=%.1fs)", nPosts, nPanels, s.nStageTime))
    fw.sent = false
    SetStage("fw_open_wall")
  end
end

local StepFWOpenWall = function()
  local RegionSync = require("PZ2Coop.RegionSync")
  local fw = s.fw
  local tx, tz = fw.gx, fw.gz
  local ty1 = RaycastGroundY(tx, tz, fw.gy)
  local ty2 = RaycastGroundY(tx + 4, tz, fw.gy)
  local ty3 = RaycastGroundY(tx + 8, tz + 2, fw.gy)
  if not fw.sent then
    fw.sent = true
    local p1 = MakePost(tx - 50, ty1, tz, 1, 0, "Brick_Red", 2.5)
    local p2 = MakePost(tx - 46, ty2, tz, 1, 0, "Brick_Red", 2.5)
    local p3 = MakePost(tx - 42, ty3, tz + 2, 0.9, 0.43, "Brick_Red", 2.5)
    local pan1 = MakePanel(1, 2, p1, p2, "Brick_Red")
    local pan2 = MakePanel(2, 3, p2, p3, "Brick_Red")
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 5, ox = 5000,
        x0 = math.floor((tx - 52) * 100), y0 = math.floor((ty1 - 4) * 100), z0 = math.floor((tz - 3) * 100),
        x1 = math.floor((tx - 39) * 100), y1 = math.floor((ty1 + 6) * 100), z1 = math.floor((tz + 5) * 100),
        posts = Arr(p1, p2, p3), panels = Arr(pan1, pan2),
      },
    })
    return
  end
  local nPosts, nPanels, nHabs, tPosts, tPanels = CountFenceInBox(tx + 4, ty1, tz + 1, 10)
  if (nPosts >= 3 and nPanels >= 2) or s.nStageTime >= 10.0 then
    -- Log real panel GetAllData keys from retail engine
    for _, oPan in pairs(tPanels) do
      local tK = {}
      for k, v in pairs(oPan:GetAllData() or {}) do
        table.insert(tK, tostring(k) .. "=" .. type(v))
      end
      table.sort(tK)
      Log("fw_open_wall retail panel keys: " .. table.concat(tK, ","))
      break
    end
    Record("fw_open_wall", nPosts >= 3 and nPanels >= 2,
      string.format("posts=%d panels=%d habs=%d (t=%.1fs)", nPosts, nPanels, nHabs, s.nStageTime))
    fw.sent = false
    SetStage("fw_delete_open")
  end
end

local StepFWDeleteOpen = function()
  local RegionSync = require("PZ2Coop.RegionSync")
  local fw = s.fw
  local tx, tz = fw.gx, fw.gz
  local ty = RaycastGroundY(tx, tz, fw.gy)
  if not fw.sent then
    fw.sent = true
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", n = 0, ox = 5000,
        x0 = math.floor((tx - 53) * 100), y0 = math.floor((ty - 5) * 100), z0 = math.floor((tz - 4) * 100),
        x1 = math.floor((tx - 38) * 100), y1 = math.floor((ty + 8) * 100), z1 = math.floor((tz + 6) * 100),
      },
    })
    return
  end
  local nPosts, nPanels = CountFenceInBox(tx + 4, ty, tz + 1, 10)
  if (nPosts == 0 and nPanels == 0) or s.nStageTime >= 8.0 then
    Record("fw_delete_open", nPosts == 0 and nPanels == 0,
      string.format("remaining posts=%d panels=%d (t=%.1fs)", nPosts, nPanels, s.nStageTime))
    fw.sent = false
    SetStage("fw_closed_loop")
  end
end

local StepFWClosedLoop = function()
  local RegionSync = require("PZ2Coop.RegionSync")
  local fw = s.fw
  local tx, tz = fw.gx, fw.gz
  local y1 = RaycastGroundY(tx, tz, fw.gy)
  local y2 = RaycastGroundY(tx + 8, tz, fw.gy)
  local y3 = RaycastGroundY(tx + 8, tz + 8, fw.gy)
  local y4 = RaycastGroundY(tx, tz + 8, fw.gy)
  if not fw.sent then
    fw.sent = true
    local p1 = MakePost(tx - 50, y1, tz, 1, 0, "Brick_Red", 2.5)
    local p2 = MakePost(tx - 42, y2, tz, 0, 1, "Brick_Red", 2.5)
    local p3 = MakePost(tx - 42, y3, tz + 8, -1, 0, "Brick_Red", 2.5)
    local p4 = MakePost(tx - 50, y4, tz + 8, 0, -1, "Brick_Red", 2.5)
    local pan1 = MakePanel(1, 2, p1, p2, "Brick_Red")
    local pan2 = MakePanel(2, 3, p2, p3, "Brick_Red")
    local pan3 = MakePanel(3, 4, p3, p4, "Brick_Red")
    local pan4 = MakePanel(4, 1, p4, p1, "Brick_Red")
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 8, ox = 5000,
        x0 = math.floor((tx - 53) * 100), y0 = math.floor((y1 - 5) * 100), z0 = math.floor((tz - 3) * 100),
        x1 = math.floor((tx - 39) * 100), y1 = math.floor((y1 + 8) * 100), z1 = math.floor((tz + 11) * 100),
        posts = Arr(p1, p2, p3, p4), panels = Arr(pan1, pan2, pan3, pan4),
      },
    })
    return
  end
  local nPosts, nPanels, nHabs = CountFenceInBox(tx + 4, y1, tz + 4, 12)
  if (nPosts >= 4 and nPanels >= 4) or s.nStageTime >= 10.0 then
    Record("fw_closed_loop", nPosts >= 4 and nPanels >= 4,
      string.format("posts=%d panels=%d habs=%d (t=%.1fs)", nPosts, nPanels, nHabs, s.nStageTime))
    fw.sent = false
    SetStage("fw_habitat_gate_blueprint")
  end
end

-- Place a habitat gate on the closed loop to form a real Habitat entity, then test full loopback
-- RegionSync send (blueprint save) -> receive (+50 m blueprint place) + clean delete!
local StepFWHabitatGateBlueprint = function()
  local BuildSync = require("PZ2Coop.BuildSync")
  local RegionSync = require("PZ2Coop.RegionSync")
  local Vector3 = require("Vector3")
  local fw = s.fw
  local tx, tz = fw.gx, fw.gz
  local y1 = RaycastGroundY(tx, tz, fw.gy)
  -- Wait 4.0 s so both RegionSync's 5.0 s startup window and 1.5 s post-apply ignore window have expired.
  if not fw.gatePhase then
    if s.nStageTime < 4.0 then
      return
    end
    fw.gatePhase = "placing_gate"
    -- Turn loopback ON so creating the gate triggers RegionSync's real local detection -> blueprint send -> +50m mirror!
    Bridge.SetLoopback(true)
    BuildSync.QueueJob(function()
      local tWorld = api.world.GetWorldAPIs()
      local api_hb = tWorld.habitatboundary
      local h = tWorld.editors:CreateUndoOperationsHierarchy()
      pcall(function() h:SetBoundaryEditPreviewModeModifyVolumes(true) end)
      h:SetPerformTerrainModificationsModifyVolumes(false)
      local op = h:GetTerrainEditOperation()
      tWorld.gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true,
        tWorld.gameterrain.CheckLakesMode_WhenTerrainCollisionEnabled, false)
      tWorld.gameterrain:SetTerrainEditOpGridRenderingEnabled(op, false)
      local cl = h:GetHabitatBoundaryChangeList()
      h:BeginVolumeModificationsBlock()
      local vGate = Vector3:new(tx + 4, RaycastGroundY(tx + 4, tz, y1), tz)
      local tEditData = {
        oHabitatBoundaryChangeList = cl,
        vPlacePoint = vGate,
        vFacingDirection = Vector3:new(0, 0, -1),
        vRayStart = Vector3:new(tx + 4, y1 + 20, tz),
        vRayDir = Vector3:new(0, -1, 0),
        nSmoothness = 0,
        nPanelMode = 0,
        nHeightAngleStart = 0,
        nHeightAngleEnd = 0,
        nWindowCutDistFromBase = 0,
        nWindowCutDistFromTop = 0,
        nBoundaryExtraFlags = 0,
        nTopRelativeHeight = 2.5,
        nTopWorldHeight = vGate:GetY() + 2.5,
        bTopHeightWorldRelative = false,
        bBottomHeightWorldRelative = false,
        bUseHeightDeadZones = false,
        nDeadZoneRange = 0.25,
        bAlignMultiSelectHeights = false,
        sBoundaryType = "Brick_Red",
        sHabitatType = "Standard",
      }
      local bOk, sRes = pcall(function()
        return api_hb:PlaceAttachableProp("habitatgate", tEditData)
      end)
      cl:RefreshAdjacentPosts()
      h:EndVolumeModificationsBlock()
      api_hb:AddCashDeltaOperation(cl, false)
      Log("fw_gate: PlaceAttachableProp ok=" .. tostring(bOk) .. " res=" .. tostring(sRes))
      local undo = api.undo
      local busyToken, previewToken = undo.PreviewChangeList(h:GetFullUndoChangeList())
      while not undo.IsOperationComplete(busyToken) do coroutine.yield() end
      h:BeginVolumeModificationsBlock()
      h:SetPerformTerrainModificationsModifyVolumes(true)
      h:EndVolumeModificationsBlock()
      local bCan = undo.CanCommitPreview(previewToken)
      while bCan == nil do coroutine.yield() bCan = undo.CanCommitPreview(previewToken) end
      local wt = bCan and undo.CommitPreview(previewToken) or undo.CancelPreview(previewToken)
      while not undo.IsOperationComplete(wt) do coroutine.yield() end
      undo.Checkpoint({sMode = "PZ2CoopTest"})
      Log("fw_gate: commit=" .. tostring(bCan))
    end)
    return
  end
  local nPosts1, nPanels1, nHabs1 = CountFenceInBox(tx + 4, y1, tz + 4, 12)
  local nPosts2, nPanels2, nHabs2 = CountFenceInBox(tx + 54, RaycastGroundY(tx + 54, tz + 4, y1), tz + 4, 14)
  if (nHabs1 >= 1 and nHabs2 >= 1) or s.nStageTime >= 18.0 then
    Bridge.SetLoopback(false)
    Record("fw_habitat_gate_blueprint", nHabs1 >= 1 and nHabs2 >= 1,
      string.format("orig(posts=%d panels=%d habs=%d) mirror+50m(posts=%d panels=%d habs=%d) t=%.1fs",
        nPosts1, nPanels1, nHabs1, nPosts2, nPanels2, nHabs2, s.nStageTime))
    -- Clean up both original and mirrored habitats
    for _, nOff in ipairs({0, 50}) do
      RegionSync.OnPacket({
        nType = 0x22,
        tData = {
          k = "fence", n = 0, ox = 0,
          x0 = math.floor((tx + nOff - 4) * 100), y0 = math.floor((y1 - 5) * 100), z0 = math.floor((tz - 4) * 100),
          x1 = math.floor((tx + nOff + 14) * 100), y1 = math.floor((y1 + 8) * 100), z1 = math.floor((tz + 14) * 100),
        },
      })
    end
    fw.sent = false
    SetStage("fw_curved_wall")
  end
end

local StepFWCurvedWall = function()
  local RegionSync = require("PZ2Coop.RegionSync")
  local fw = s.fw
  -- Place curved glass wall at tz + 20 so it doesn't collide with the queued cleanup at tz.
  local tx, tz = fw.gx, fw.gz + 20
  local y1 = RaycastGroundY(tx, tz, fw.gy)
  local y2 = RaycastGroundY(tx + 6, tz + 4, fw.gy)
  if not fw.sent then
    fw.sent = true
    local p1 = MakePost(tx - 50, y1, tz, 1, 0, "Glass", 3.0)
    local p2 = MakePost(tx - 44, y2, tz + 4, 0, 1, "Glass", 3.0)
    local pan = MakePanel(1, 2, p1, p2, "Glass")
    pan.f.nSmoothness = 1
    pan.v.vDirStart = Arr(1, 0, 0)
    pan.v.vDirEnd = Arr(0, 1, 0)
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 3, ox = 5000,
        x0 = math.floor((tx - 53) * 100), y0 = math.floor((y1 - 4) * 100), z0 = math.floor((tz - 3) * 100),
        x1 = math.floor((tx - 41) * 100), y1 = math.floor((y1 + 7) * 100), z1 = math.floor((tz + 7) * 100),
        posts = Arr(p1, p2), panels = Arr(pan),
      },
    })
    return
  end
  local nPosts, nPanels = CountFenceInBox(tx + 3, y1, tz + 2, 10)
  if (nPosts >= 2 and nPanels >= 1) or s.nStageTime >= 8.0 then
    Record("fw_curved_wall", nPosts >= 2 and nPanels >= 1,
      string.format("curved glass posts=%d panels=%d (t=%.1fs)", nPosts, nPanels, s.nStageTime))
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", n = 0, ox = 5000,
        x0 = math.floor((tx - 53) * 100), y0 = math.floor((y1 - 4) * 100), z0 = math.floor((tz - 3) * 100),
        x1 = math.floor((tx - 41) * 100), y1 = math.floor((y1 + 7) * 100), z1 = math.floor((tz + 7) * 100),
      },
    })
    fw.sent = false
    SetStage("fw_water_roundtrip")
  end
end

local StepFWWaterRoundtrip = function()
  local WaterSync = require("PZ2Coop.WaterSync")
  local fw = s.fw
  local gt = api.world.GetWorldAPIs().gameterrain
  if fw.lake0 == nil or fw.lake0.vFill == nil then
    Record("fw_water_roundtrip", false, "no existing lake in baseline zoo to test remove+add")
    SetStage("cleanup")
    return
  end
  local vFill = fw.lake0.vFill
  local xCm = math.floor(vFill:GetX() * 100 + 0.5)
  local yCm = math.floor(vFill:GetY() * 100 + 0.5)
  local zCm = math.floor(vFill:GetZ() * 100 + 0.5)
  if not fw.waterPhase then
    fw.waterPhase = "removing"
    fw.lakesBefore = #(gt:GetAllLakes() or {})
    WaterSync.OnPacket({
      nType = 0x22,
      tData = {k = "water", op = "remove", x = xCm, y = yCm, z = zCm},
    })
    Log(string.format("fw_water: removing lake at (%.1f,%.1f,%.1f), count=%d", xCm/100, yCm/100, zCm/100, fw.lakesBefore))
    return
  end
  local nNow = #(gt:GetAllLakes() or {})
  if fw.waterPhase == "removing" then
    if nNow < fw.lakesBefore or s.nStageTime >= 8.0 then
      fw.removedOk = nNow < fw.lakesBefore
      fw.waterPhase = "adding"
      fw.addStart = s.nStageTime
      local p = fw.lake0.tProps or {}
      local PackProps = function(_t)
        if type(_t) ~= "table" then return nil end
        local tOut = {}
        for k, v in pairs(_t) do
          local bV, vx, vy, vz = pcall(function() return v:GetX(), v:GetY(), v:GetZ() end)
          if bV and type(vx) == "number" then
            tOut[k] = Arr(vx, vy, vz)
          elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            tOut[k] = v
          end
        end
        return next(tOut) ~= nil and tOut or nil
      end
      WaterSync.OnPacket({
        nType = 0x22,
        tData = {
          k = "water", op = "add", x = xCm, y = yCm, z = zCm,
          prefab = p.sPrefabName, surf = p.sSurfaceMaterialName, under = p.sUndersideMaterialName,
          clean = p.nCleanliness, temp = p.nTemperature,
          col = PackProps(p.tColourData), part = PackProps(p.tParticleData),
        },
      })
      Log("fw_water: removed=" .. tostring(fw.removedOk) .. " (count=" .. nNow .. "), re-adding lake with colour+particle data...")
    end
    return
  end
  if fw.waterPhase == "adding" then
    if nNow >= fw.lakesBefore or (s.nStageTime - fw.addStart) >= 12.0 then
      local bAddedOk = nNow >= fw.lakesBefore
      Record("fw_water_roundtrip", fw.removedOk == true and bAddedOk,
        string.format("before=%d after_add=%d removed=%s added=%s", fw.lakesBefore, nNow, tostring(fw.removedOk), tostring(bAddedOk)))
      fw.sent = false
      SetStage("fw_fence_with_water")
    end
  end
end

local StepFWFenceWithWater = function()
  local RegionSync = require("PZ2Coop.RegionSync")
  local fw = s.fw
  local gt = api.world.GetWorldAPIs().gameterrain
  local vFill = fw.lake0 and fw.lake0.vFill
  if vFill == nil then
    Record("fw_fence_with_water", false, "no lake for fence+water test")
    SetStage("cleanup")
    return
  end
  local lx, ly, lz = vFill:GetX(), vFill:GetY(), vFill:GetZ()
  if not fw.sent then
    fw.sent = true
    fw.lakesBeforeWall = #(gt:GetAllLakes() or {})
    -- Build a 2-post, 1-panel Acrylic barrier right across/into the lake to test LakesInLimbo + water!
    local y1 = RaycastGroundY(lx - 4, lz, ly)
    local y2 = RaycastGroundY(lx + 4, lz, ly)
    local nTop = math.max(ly, y1, y2) + 2.5
    local p1 = MakePost(lx - 4, y1, lz, 1, 0, "Acrylic", nTop - y1)
    local p2 = MakePost(lx + 4, y2, lz, 1, 0, "Acrylic", nTop - y2)
    local pan1 = MakePanel(1, 2, p1, p2, "Acrylic")
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 3, ox = 0,
        x0 = math.floor((lx - 6) * 100), y0 = math.floor((math.min(y1, y2) - 4) * 100), z0 = math.floor((lz - 3) * 100),
        x1 = math.floor((lx + 6) * 100), y1 = math.floor((nTop + 3) * 100), z1 = math.floor((lz + 3) * 100),
        posts = Arr(p1, p2), panels = Arr(pan1),
      },
    })
    Log(string.format("fw_fence_with_water: placing Acrylic wall across lake at (%.1f,%.1f,%.1f)", lx, ly, lz))
    return
  end
  local nPosts, nPanels = CountFenceInBox(lx, ly, lz, 8)
  local nLakesNow = #(gt:GetAllLakes() or {})
  if (nPosts >= 2 and nPanels >= 1) or s.nStageTime >= 10.0 then
    Record("fw_fence_with_water", nPosts >= 2 and nPanels >= 1,
      string.format("posts=%d panels=%d lakes=%d->%d (t=%.1fs)", nPosts, nPanels, fw.lakesBeforeWall, nLakesNow, s.nStageTime))
    fw.aqPhase = nil
    SetStage("fw_aquarium_water")
  end
end

-- Build a closed Acrylic aquarium with an aquariumentrance gate, fill it via WaterSync (FillAquarium),
-- and verify the aquarium lake appears and can be drained cleanly via WaterSync!
local StepFWAquariumWater = function()
  local BuildSync = require("PZ2Coop.BuildSync")
  local RegionSync = require("PZ2Coop.RegionSync")
  local WaterSync = require("PZ2Coop.WaterSync")
  local Vector3 = require("Vector3")
  local fw = s.fw
  local tx, tz = fw.gx, fw.gz
  local nSize = 12
  local nH = 5.5 -- HabitatBoundary.AquariumDefaultRelativeHeight = 5.0
  local y1 = RaycastGroundY(tx, tz, fw.gy)
  local y2 = RaycastGroundY(tx + nSize, tz, fw.gy)
  local y3 = RaycastGroundY(tx + nSize, tz + nSize, fw.gy)
  local y4 = RaycastGroundY(tx, tz + nSize, fw.gy)
  local nTop = math.max(y1, y2, y3, y4) + nH
  if not fw.aqPhase then
    fw.aqPhase = "build_walls"
    local p1 = MakePost(tx, y1, tz, 1, 0, "Acrylic", nTop - y1)
    local p2 = MakePost(tx + nSize, y2, tz, 0, 1, "Acrylic", nTop - y2)
    local p3 = MakePost(tx + nSize, y3, tz + nSize, -1, 0, "Acrylic", nTop - y3)
    local p4 = MakePost(tx, y4, tz + nSize, 0, -1, "Acrylic", nTop - y4)
    local pan1 = MakePanel(1, 2, p1, p2, "Acrylic")
    local pan2 = MakePanel(2, 3, p2, p3, "Acrylic")
    local pan3 = MakePanel(3, 4, p3, p4, "Acrylic")
    local pan4 = MakePanel(4, 1, p4, p1, "Acrylic")
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 8, ox = 0,
        x0 = math.floor((tx - 3) * 100), y0 = math.floor((y1 - 5) * 100), z0 = math.floor((tz - 3) * 100),
        x1 = math.floor((tx + nSize + 3) * 100), y1 = math.floor((nTop + 3) * 100), z1 = math.floor((tz + nSize + 3) * 100),
        posts = Arr(p1, p2, p3, p4), panels = Arr(pan1, pan2, pan3, pan4),
      },
    })
    return
  end
  if fw.aqPhase == "build_walls" then
    local nP, nL = CountFenceInBox(tx + nSize / 2, y1, tz + nSize / 2, nSize + 4)
    if nP >= 4 and nL >= 4 then
      fw.aqPhase = "place_gate"
      fw.aqGateStart = s.nStageTime
      BuildSync.QueueJob(function()
        local tWorld = api.world.GetWorldAPIs()
        local api_hb = tWorld.habitatboundary
        local vGate = Vector3:new(tx + nSize / 2, RaycastGroundY(tx + nSize / 2, tz, y1), tz)
        -- Aim horizontally at the front Acrylic wall face (below wall top) for aquariumentrance, trying top/bottom fallback.
        local TryGate = function(_vPt, _vRayS, _vRayD)
          local h = tWorld.editors:CreateUndoOperationsHierarchy()
          pcall(function() h:SetBoundaryEditPreviewModeModifyVolumes(true) end)
          h:SetPerformTerrainModificationsModifyVolumes(false)
          local op = h:GetTerrainEditOperation()
          tWorld.gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true,
            tWorld.gameterrain.CheckLakesMode_WhenTerrainCollisionEnabled, false)
          tWorld.gameterrain:SetTerrainEditOpGridRenderingEnabled(op, false)
          local cl = h:GetHabitatBoundaryChangeList()
          h:BeginVolumeModificationsBlock()
          local tEditData = {
            oHabitatBoundaryChangeList = cl,
            vPlacePoint = _vPt,
            vFacingDirection = Vector3:new(0, 0, -1),
            vRayStart = _vRayS,
            vRayDir = _vRayD,
            nSmoothness = 0, nPanelMode = 0, nHeightAngleStart = 0, nHeightAngleEnd = 0,
            nWindowCutDistFromBase = 0, nWindowCutDistFromTop = 0, nBoundaryExtraFlags = 0,
            nTopRelativeHeight = nH, nTopWorldHeight = nTop,
            bTopHeightWorldRelative = false, bBottomHeightWorldRelative = false,
            bUseHeightDeadZones = false, nDeadZoneRange = 0.25, bAlignMultiSelectHeights = false,
            sBoundaryType = "Acrylic", sHabitatType = "Aquarium",
          }
          pcall(function() api_hb:PlaceAttachableProp("aquariumentrance", tEditData) end)
          cl:RefreshAdjacentPosts()
          h:EndVolumeModificationsBlock()
          api_hb:AddCashDeltaOperation(cl, false)
          local undo = api.undo
          local bt, pt = undo.PreviewChangeList(h:GetFullUndoChangeList())
          while not undo.IsOperationComplete(bt) do coroutine.yield() end
          h:BeginVolumeModificationsBlock()
          h:SetPerformTerrainModificationsModifyVolumes(true)
          h:EndVolumeModificationsBlock()
          local bCan = undo.CanCommitPreview(pt)
          while bCan == nil do coroutine.yield() bCan = undo.CanCommitPreview(pt) end
          local sReasons = ""
          if not bCan then
            local bR, tR = pcall(undo.GetCommitFailReasons, pt)
            if bR and type(tR) == "table" then
              local tN = {}
              for k, v in pairs(tR) do if v then table.insert(tN, tostring(k)) end end
              sReasons = " reasons=" .. table.concat(tN, ",")
            end
          end
          local wt = bCan and undo.CommitPreview(pt) or undo.CancelPreview(pt)
          while not undo.IsOperationComplete(wt) do coroutine.yield() end
          if bCan then
            undo.Checkpoint({sMode = "PZ2CoopTest"})
          end
          return bCan, sReasons
        end
        -- First try horizontal ray at y+1.5m; if refused, try at top rim y=nTop, and also try habitatgate-like ground placement.
        local bCan, sReasons = TryGate(vGate, Vector3:new(tx + nSize / 2, vGate:GetY() + 1.5, tz - 8), Vector3:new(0, 0, 1))
        Log("fw_aquarium: gate attempt1 (horiz low) commit=" .. tostring(bCan) .. sReasons)
        if not bCan then
          local vTop = Vector3:new(tx + nSize / 2, nTop, tz)
          bCan, sReasons = TryGate(vTop, Vector3:new(tx + nSize / 2, nTop + 5, tz), Vector3:new(0, -1, 0))
          Log("fw_aquarium: gate attempt2 (top rim) commit=" .. tostring(bCan) .. sReasons)
        end
        if not bCan then
          -- Try facing +Z (inward)
          local vLow = Vector3:new(tx + nSize / 2, vGate:GetY(), tz)
          bCan, sReasons = TryGate(vLow, Vector3:new(tx + nSize / 2, vGate:GetY() + 1.0, tz + 8), Vector3:new(0, 0, -1))
          Log("fw_aquarium: gate attempt3 (horiz inner) commit=" .. tostring(bCan) .. sReasons)
        end
      end)
    elseif s.nStageTime >= 8.0 then
      Record("fw_aquarium_water", false, "aquarium walls failed to build")
      SetStage("cleanup")
    end
    return
  end
  if fw.aqPhase == "place_gate" then
    local tWorld = api.world.GetWorldAPIs()
    local nAqEnt = nil
    pcall(function()
      for _, nEnt in pairs(tWorld.facilities:GetAllHabitatsEntityIDs() or {}) do
        if tWorld.habitat:IsAquarium(nEnt) then
          nAqEnt = nEnt
          break
        end
      end
    end)
    if nAqEnt ~= nil then
      fw.nAqEnt = nAqEnt
      fw.aqPhase = "filling"
      fw.aqFillStart = s.nStageTime
      WaterSync.OnPacket({
        nType = 0x22,
        tData = {
          k = "water", op = "add", aq = true,
          x = math.floor((tx + nSize / 2) * 100), y = math.floor((y1 + 2.0) * 100), z = math.floor((tz + nSize / 2) * 100),
        },
      })
      Log("fw_aquarium: found aquarium entity=" .. tostring(nAqEnt) .. ", requested WaterSync fill")
    elseif s.nStageTime - fw.aqGateStart >= 8.0 then
      Record("fw_aquarium_water", false, "aquarium gate did not create an aquarium habitat entity")
      SetStage("cleanup")
    end
    return
  end
  if fw.aqPhase == "filling" then
    local tWorld = api.world.GetWorldAPIs()
    local nLakeID = nil
    pcall(function() nLakeID = tWorld.habitat:GetAquariumLake(fw.nAqEnt) end)
    if nLakeID ~= nil then
      fw.aqFilledOk = true
      fw.aqPhase = "draining"
      fw.aqDrainStart = s.nStageTime
      local vFill = tWorld.gameterrain:FindLakeRefillPoint(nLakeID)
      local dx = vFill and math.floor(vFill:GetX() * 100) or math.floor((tx + 4) * 100)
      local dy = vFill and math.floor(vFill:GetY() * 100) or math.floor((y1 + 1.5) * 100)
      local dz = vFill and math.floor(vFill:GetZ() * 100) or math.floor((tz + 4) * 100)
      WaterSync.OnPacket({
        nType = 0x22,
        tData = {k = "water", op = "remove", x = dx, y = dy, z = dz},
      })
      Log("fw_aquarium: filled! lakeID=" .. tostring(nLakeID) .. ", testing WaterSync drain...")
    elseif s.nStageTime - fw.aqFillStart >= 12.0 then
      Record("fw_aquarium_water", false, "FillAquarium timed out without creating aquarium lake")
      SetStage("cleanup")
    end
    return
  end
  if fw.aqPhase == "draining" then
    local tWorld = api.world.GetWorldAPIs()
    local nLakeID = nil
    pcall(function() nLakeID = tWorld.habitat:GetAquariumLake(fw.nAqEnt) end)
    if nLakeID == nil or (s.nStageTime - fw.aqDrainStart) >= 8.0 then
      Record("fw_aquarium_water", fw.aqFilledOk == true and nLakeID == nil,
        string.format("aquarium=%s filled=%s drained=%s", tostring(fw.nAqEnt), tostring(fw.aqFilledOk), tostring(nLakeID == nil)))
      SetStage("cleanup")
    end
  end
end

-- ---- autonomous video showcase plan (--plan showcase) ----------------------------------------------------
local EmitCue = function(_tCue)
  local bOk, r1, r2 = pcall(api.json.Stringify, _tCue)
  local sJson = (type(r1) == "string" and r1) or (r1 == true and type(r2) == "string" and r2) or nil
  if bOk and type(sJson) == "string" then
    Bridge.Log("SHOWCASE_CUE " .. sJson)
    Bridge.Flush(true)
  else
    Bridge.Log("SHOWCASE_CUE_ERR ok=" .. tostring(bOk) .. " r1=" .. tostring(r1) .. " r2=" .. tostring(r2))
  end
end

local FocusCameraBox = function(_x0, _y0, _z0, _x1, _y1, _z1)
  local Vector3 = require("Vector3")
  local tWorld = api.world.GetWorldAPIs()
  pcall(function()
    tWorld.CameraModeManager:RequestMode("Focus", {
      vFocusMin = Vector3:new(_x0, _y0, _z0),
      vFocusMax = Vector3:new(_x1, _y1, _z1),
    })
  end)
end

local StepSCPrepare = function()
  local tWorld = api.world.GetWorldAPIs()
  local gt = tWorld.gameterrain
  local tLakes = gt:GetAllLakes() or {}
  local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
  local cx, cz = vCam:GetX(), vCam:GetZ()
  local Vector3 = require("Vector3")
  local gx, gy, gz = cx, RaycastGroundY(cx, cz, 0), cz
  for _, tOff in ipairs({{0, 0}, {30, 0}, {-30, 0}, {0, 30}, {0, -30}, {50, 30}, {-50, 30}, {0, 60}, {-60, -30}, {60, -40}}) do
    local tx, tz = cx + tOff[1], cz + tOff[2]
    local ty = RaycastGroundY(tx, tz, nil)
    if ty ~= nil then
      local np, nl = CountFenceInBox(tx + 4, ty, tz + 4, 16)
      local tNearLakes = gt:FindLakesWithSphereCheck(Vector3:new(tx + 4, ty, tz + 4), 16) or {}
      if np == 0 and nl == 0 and #tNearLakes == 0 then
        gx, gy, gz = tx, ty, tz
        break
      end
    end
  end
  local tLake0 = nil
  if #tLakes > 0 then
    local id = tLakes[1]
    local vFill = gt:FindLakeRefillPoint(id)
    local tProps = gt:GetLakeRespawnProperties(id)
    local vMin, vMax = nil, nil
    pcall(function() vMin, vMax = gt:GetLakeAABB(id) end)
    tLake0 = {id = id, vFill = vFill, tProps = tProps, vMin = vMin, vMax = vMax}
  end
  s.sc = {gx = gx, gy = gy, gz = gz, lake0 = tLake0, phase = 0}
  -- Set bright midday sun so recorded showcase footage is crisp and vivid.
  pcall(function()
    if tWorld.park and tWorld.park.OverrideApparentTimeOfDay then
      tWorld.park:OverrideApparentTimeOfDay(13.0)
    end
  end)
  EmitCue({event = "showcase_ready"})
  FocusCameraBox(gx - 3, gy, gz - 3, gx + 12, gy + 5, gz + 12)
  SetStage("sc_habitat_walls")
end

local StepSCHabitatWalls = function()
  local BuildSync = require("PZ2Coop.BuildSync")
  local RegionSync = require("PZ2Coop.RegionSync")
  local Vector3 = require("Vector3")
  local sc = s.sc
  local tx, tz = sc.gx, sc.gz
  local y1 = RaycastGroundY(tx, tz, sc.gy)
  local y2 = RaycastGroundY(tx + 9, tz, sc.gy)
  local y3 = RaycastGroundY(tx + 9, tz + 9, sc.gy)
  local y4 = RaycastGroundY(tx, tz + 9, sc.gy)

  if sc.phase == 0 and s.nStageTime >= 2.2 then
    sc.phase = 1
    EmitCue({
      event = "scene_start",
      id = "habitat_walls",
      eyebrow = "REGION SYNC",
      title = "Habitat Walls & Curved Glass",
      subtitle = "Open barriers, curved panels and closed habitats sync live",
      badge = "BETA",
      zoom = 1.0,
      fx = 0.50,
      fy = 0.52,
    })
  elseif sc.phase == 1 and s.nStageTime >= 3.6 then
    sc.phase = 2
    EmitCue({event = "zoom", zoom = 1.38, fx = 0.50, fy = 0.52})
    local p1 = MakePost(tx, y1, tz, 1, 0, "Brick_Red", 2.8)
    local p2 = MakePost(tx + 9, y2, tz, 0, 1, "Glass", 2.8)
    local p3 = MakePost(tx + 9, y3, tz + 9, -1, 0, "Glass", 2.8)
    local p4 = MakePost(tx, y4, tz + 9, 0, -1, "Brick_Red", 2.8)
    local pan1 = MakePanel(1, 2, p1, p2, "Brick_Red")
    local pan2 = MakePanel(2, 3, p2, p3, "Glass")
    pan2.f.nSmoothness = 1
    pan2.v.vDirStart = Arr(0, 0, 1)
    pan2.v.vDirEnd = Arr(-1, 0, 0)
    local pan3 = MakePanel(3, 4, p3, p4, "Glass")
    local pan4 = MakePanel(4, 1, p4, p1, "Brick_Red")
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 8, ox = 0,
        x0 = math.floor((tx - 3) * 100), y0 = math.floor((y1 - 5) * 100), z0 = math.floor((tz - 3) * 100),
        x1 = math.floor((tx + 12) * 100), y1 = math.floor((y1 + 8) * 100), z1 = math.floor((tz + 12) * 100),
        posts = Arr(p1, p2, p3, p4), panels = Arr(pan1, pan2, pan3, pan4),
      },
    })
  elseif sc.phase == 2 and s.nStageTime >= 6.4 then
    sc.phase = 3
    EmitCue({event = "zoom", zoom = 1.15, fx = 0.50, fy = 0.50})
    -- Place a habitat gate on the front brick wall so it becomes a complete synced habitat.
    BuildSync.QueueJob(function()
      local tWorld = api.world.GetWorldAPIs()
      local api_hb = tWorld.habitatboundary
      local h = tWorld.editors:CreateUndoOperationsHierarchy()
      pcall(function() h:SetBoundaryEditPreviewModeModifyVolumes(true) end)
      h:SetPerformTerrainModificationsModifyVolumes(false)
      local op = h:GetTerrainEditOperation()
      tWorld.gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true,
        tWorld.gameterrain.CheckLakesMode_WhenTerrainCollisionEnabled, false)
      tWorld.gameterrain:SetTerrainEditOpGridRenderingEnabled(op, false)
      local cl = h:GetHabitatBoundaryChangeList()
      h:BeginVolumeModificationsBlock()
      local vGate = Vector3:new(tx + 4.5, RaycastGroundY(tx + 4.5, tz, y1), tz)
      pcall(function()
        api_hb:PlaceAttachableProp("habitatgate", {
          oHabitatBoundaryChangeList = cl,
          vPlacePoint = vGate,
          vFacingDirection = Vector3:new(0, 0, -1),
          vRayStart = Vector3:new(tx + 4.5, y1 + 20, tz),
          vRayDir = Vector3:new(0, -1, 0),
          nSmoothness = 0, nPanelMode = 0, nHeightAngleStart = 0, nHeightAngleEnd = 0,
          nWindowCutDistFromBase = 0, nWindowCutDistFromTop = 0, nBoundaryExtraFlags = 0,
          nTopRelativeHeight = 2.8, nTopWorldHeight = vGate:GetY() + 2.8,
          bTopHeightWorldRelative = false, bBottomHeightWorldRelative = false,
          bUseHeightDeadZones = false, nDeadZoneRange = 0.25, bAlignMultiSelectHeights = false,
          sBoundaryType = "Brick_Red", sHabitatType = "Standard",
        })
      end)
      cl:RefreshAdjacentPosts()
      h:EndVolumeModificationsBlock()
      api_hb:AddCashDeltaOperation(cl, false)
      local undo = api.undo
      local bt, pt = undo.PreviewChangeList(h:GetFullUndoChangeList())
      while not undo.IsOperationComplete(bt) do coroutine.yield() end
      h:BeginVolumeModificationsBlock()
      h:SetPerformTerrainModificationsModifyVolumes(true)
      h:EndVolumeModificationsBlock()
      local bCan = undo.CanCommitPreview(pt)
      while bCan == nil do coroutine.yield() bCan = undo.CanCommitPreview(pt) end
      local wt = bCan and undo.CommitPreview(pt) or undo.CancelPreview(pt)
      while not undo.IsOperationComplete(wt) do coroutine.yield() end
      undo.Checkpoint({sMode = "PZ2CoopShowcase"})
    end)
  elseif sc.phase == 3 and s.nStageTime >= 9.6 then
    sc.phase = 0
    EmitCue({event = "scene_end", id = "habitat_walls"})
    Record("sc_habitat_walls", true, "recorded")
    -- Move camera toward lake0 for next scene
    if sc.lake0 ~= nil and sc.lake0.vFill ~= nil then
      local v = sc.lake0.vFill
      local lx, ly, lz = v:GetX(), v:GetY(), v:GetZ()
      FocusCameraBox(lx - 10, ly - 2, lz - 10, lx + 10, ly + 4, lz + 10)
      SetStage("sc_water_sync")
    else
      SetStage("sc_walk_emotes")
    end
  end
end

local StepSCWaterSync = function()
  local WaterSync = require("PZ2Coop.WaterSync")
  local sc = s.sc
  local vFill = sc.lake0.vFill
  local xCm = math.floor(vFill:GetX() * 100 + 0.5)
  local yCm = math.floor(vFill:GetY() * 100 + 0.5)
  local zCm = math.floor(vFill:GetZ() * 100 + 0.5)

  if sc.phase == 0 and s.nStageTime >= 2.2 then
    sc.phase = 1
    EmitCue({
      event = "scene_start",
      id = "water_sync",
      eyebrow = "WATER SYNC",
      title = "Lakes & Aquarium Water",
      subtitle = "Refill points, materials, colour and drain/fill sync",
      badge = "BETA",
      zoom = 1.0,
      fx = 0.50,
      fy = 0.52,
    })
  elseif sc.phase == 1 and s.nStageTime >= 3.7 then
    sc.phase = 2
    EmitCue({event = "zoom", zoom = 1.35, fx = 0.50, fy = 0.52})
    WaterSync.OnPacket({
      nType = 0x22,
      tData = {k = "water", op = "remove", x = xCm, y = yCm, z = zCm},
    })
  elseif sc.phase == 2 and s.nStageTime >= 6.0 then
    sc.phase = 3
    EmitCue({event = "zoom", zoom = 1.44, fx = 0.50, fy = 0.50})
    local p = sc.lake0.tProps or {}
    local PackProps = function(_t)
      if type(_t) ~= "table" then return nil end
      local tOut = {}
      for k, v in pairs(_t) do
        local bV, vx, vy, vz = pcall(function() return v:GetX(), v:GetY(), v:GetZ() end)
        if bV and type(vx) == "number" then
          tOut[k] = Arr(vx, vy, vz)
        elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
          tOut[k] = v
        end
      end
      return next(tOut) ~= nil and tOut or nil
    end
    WaterSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "water", op = "add", x = xCm, y = yCm, z = zCm,
        prefab = p.sPrefabName, surf = p.sSurfaceMaterialName, under = p.sUndersideMaterialName,
        clean = p.nCleanliness, temp = p.nTemperature,
        col = PackProps(p.tColourData), part = PackProps(p.tParticleData),
      },
    })
  elseif sc.phase == 3 and s.nStageTime >= 9.4 then
    sc.phase = 0
    EmitCue({event = "scene_end", id = "water_sync"})
    Record("sc_water_sync", true, "recorded")
    SetStage("sc_walk_emotes")
  end
end

local StepSCWalkEmotes = function()
  local Presence = require("PZ2Coop.Presence")
  local Avatar = require("PZ2Coop.Avatar")
  local Actions = require("PZ2Coop.Actions")
  local Vector3 = require("Vector3")
  local sc = s.sc
  local tPres = rawget(global, "__PZ2CoopPresenceState")
  local tOwn = tPres and tPres.tOwnBody

  if sc.phase == 0 then
    sc.phase = 1
    Bridge.SetLoopback(true)
    Presence.SetThirdPerson(true)
    pcall(function()
      local vWalk = Vector3:new(sc.gx + 2, sc.gy + 1.6, sc.gz - 4)
      require("Editors.Shared.BaseUIMode").SetNewMode("WalkingCamera", {vStartingPos = vWalk})
    end)
    return
  end

  if sc.phase == 1 then
    local bReady = tOwn ~= nil and tOwn.nAvatar ~= nil and tOwn.tAnim ~= nil
    if bReady or s.nStageTime >= 5.0 then
      sc.phase = 2
      sc.t0 = s.nStageTime
      EmitCue({
        event = "scene_start",
        id = "walk_emotes",
        eyebrow = "WALK TOGETHER",
        title = "Third-Person Avatars & Emotes",
        subtitle = "Animated locomotion, radial emote wheel and held props",
        badge = "WORKS",
        zoom = 1.0,
        fx = 0.50,
        fy = 0.54,
      })
    end
    return
  end

  local dtScene = s.nStageTime - (sc.t0 or 0)
  if sc.phase == 2 then
    if tOwn ~= nil and tOwn.nAvatar ~= nil and tOwn.tAnim ~= nil then
      Avatar.UpdateAnimation(tOwn.tAnim, tOwn.nAvatar, 2.2, 0.05, false)
    end
    if dtScene >= 1.8 then
      sc.phase = 3
      Actions.SetWheelOpen(true)
      EmitCue({event = "zoom", zoom = 1.28, fx = 0.50, fy = 0.50})
      EmitCue({event = "cursor_demo", from = Arr(0.24, 0.72), to = Arr(0.50, 0.34), dur = 1.15, click = true})
    end
  elseif sc.phase == 3 and dtScene >= 3.8 then
    sc.phase = 4
    Actions.SetWheelOpen(false)
    Actions.PlayEmote("prop_balloon")
    Actions.PlayEmote("cheer")
    EmitCue({event = "zoom", zoom = 1.38, fx = 0.50, fy = 0.54})
  elseif sc.phase == 4 and dtScene >= 6.8 then
    sc.phase = 5
    EmitCue({event = "scene_end", id = "walk_emotes"})
    Record("sc_walk_emotes", true, "recorded")
    Presence.SetThirdPerson(false)
    pcall(function() require("Editors.Shared.BaseUIMode").SetNewMode("Select") end)
    SetStage("cleanup")
  end
end

-- ---- gate_probe: inspect exact physics sweeps across a HabitatGate before & after opening ----
local ProbeGateSweeps = function(_sTag, _vPos, _vF, _nGateID)
  local Vector3 = require("Vector3")
  local WalkingCamera = require("Components.Cameras.WalkingCamera")
  local p = api.physics
  local nPhys = api.entity.FindEntityByName("MainPhysicsWorld")
  local tFlagNames = {
    "Flag_Animal", "Flag_Building", "Flag_Scenery", "Flag_Tree_trunk",
    "Flag_Tree_branch", "Flag_FirstPersonObstruction", "Flag_Prop",
    "Flag_Car_OffTrack", "Flag_Landscape",
  }
  local gx, gy, gz = _vPos:GetX(), _vPos:GetY(), _vPos:GetZ()
  local fx, fz = _vF:GetX(), _vF:GetZ()
  local flen = math.sqrt(fx * fx + fz * fz)
  if flen < 1e-4 then fx, fz = 0, 1 else fx, fz = fx / flen, fz / flen end
  local vA = Vector3:new(gx - fx * 1.6, gy, gz - fz * 1.6)
  local vB = Vector3:new(gx + fx * 1.6, gy, gz + fz * 1.6)
  Log(string.format("GP[%s] gate=%s pos=(%.2f,%.2f,%.2f) fwd=(%.2f,%.2f)", _sTag, tostring(_nGateID), gx, gy, gz, fx, fz))
  local nFullFlags = WalkingCamera.GetCollisionFlags(true)
  for _, tBand in ipairs({{"eye1.55", 1.55, 0.15}, {"chest1.05", 1.05, 0.18}, {"waist0.65", 0.65, 0.16}}) do
    local sName, h, r = tBand[1], tBand[2], tBand[3]
    local vS = Vector3:new(vA:GetX(), gy + h, vA:GetZ())
    local vE = Vector3:new(vB:GetX(), gy + h, vB:GetZ())
    local tHitFlags = {}
    for _, sF in ipairs(tFlagNames) do
      local nF = p[sF]
      if type(nF) == "number" and nF ~= 0 then
        local tRes = p.SphereSweep(nPhys, vS, vE, r, nF, 4)
        if type(tRes) == "table" and #tRes > 0 then
          local t0 = tRes[1]
          local sKeys = ""
          if type(t0) == "table" then
            local parts = {}
            for k, v in pairs(t0) do
              if k == "vNormal" and v ~= nil then
                table.insert(parts, string.format("N=(%.2f,%.2f,%.2f)", v:GetX(), v:GetY(), v:GetZ()))
              else
                table.insert(parts, tostring(k) .. "=" .. tostring(v))
              end
            end
            table.sort(parts)
            sKeys = table.concat(parts, ",")
          end
          table.insert(tHitFlags, string.format("%s(#%d:%s)", sF, #tRes, sKeys))
        end
      end
    end
    Log(string.format("GP[%s] %s r=%.2f hits: %s", _sTag, sName, r, #tHitFlags > 0 and table.concat(tHitFlags, " ; ") or "NONE"))
  end
  -- Also test wrapped vs original SweepAndSlide from 1.6m in front to 1.6m behind at eye height
  local vEyeA = Vector3:new(vA:GetX(), gy + 1.55, vA:GetZ())
  local vEyeB = Vector3:new(vB:GetX(), gy + 1.55, vB:GetZ())
  local fnOrig = rawget(WalkingCamera, "__PZ2CoopOriginalSweep") or WalkingCamera.SweepAndSlide
  local vOrig = fnOrig(nPhys, vEyeA, vEyeB, nFullFlags, 0.15, 4)
  local vWrap = WalkingCamera.SweepAndSlide(nPhys, vEyeA, vEyeB, nFullFlags, 0.15, 4)
  local function prog(v)
    return (v:GetX() - vEyeA:GetX()) * fx + (v:GetZ() - vEyeA:GetZ()) * fz
  end
  Log(string.format("GP[%s] Sweep orig=%.2f/3.20 (y=%.2f) wrap=%.2f/3.20 (y=%.2f)",
    _sTag, prog(vOrig), vOrig:GetY(), prog(vWrap), vWrap:GetY()))
end

local StepGPSetup = function()
  local tWorld = api.world.GetWorldAPIs()
  local Vector3 = require("Vector3")
  local fpi = tWorld.FirstPersonInteraction
  local tGates = {}
  if fpi ~= nil and type(fpi.tEntities) == "table" then
    for nEnt, tInfo in pairs(fpi.tEntities) do
      if type(tInfo) == "table" and tInfo.sType == "HabitatGate" then
        table.insert(tGates, tInfo.nParentEntityID or nEnt)
      end
    end
  end
  if #tGates == 0 and tWorld.facilities ~= nil then
    local bOkF, tHabs = pcall(function() return tWorld.facilities:GetAllHabitatsEntityIDs() end)
    if bOkF and type(tHabs) == "table" then
      for k, v in pairs(tHabs) do
        table.insert(tGates, type(v) == "number" and v or k)
      end
    end
  end
  if #tGates == 0 then
    if not s.gpBuilt then
      if s.nStageTime < 2.0 then
        return
      end
      s.gpBuilt = true
      -- Place a real 8x8 Brick_Red habitat loop + HabitatGate on flat ground so the test is 100% deterministic.
      local BuildSync = require("PZ2Coop.BuildSync")
      local RegionSync = require("PZ2Coop.RegionSync")
      local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
      local tx, tz = vCam:GetX(), vCam:GetZ()
      local ty = RaycastGroundY(tx, tz, 0)
      for _, tOff in ipairs({{0, 0}, {30, 0}, {-30, 0}, {0, 30}, {0, -30}, {40, 40}, {-40, 40}}) do
        local cx, cz = vCam:GetX() + tOff[1], vCam:GetZ() + tOff[2]
        local cy = RaycastGroundY(cx, cz, nil)
        if cy ~= nil then
          local np, nl = CountFenceInBox(cx + 4, cy, cz + 4, 14)
          if np == 0 and nl == 0 then
            tx, ty, tz = cx, cy, cz
            break
          end
        end
      end
      s.gpBuildPos = {x = tx, y = ty, z = tz}
      local y1 = RaycastGroundY(tx, tz, ty)
      local y2 = RaycastGroundY(tx + 8, tz, ty)
      local y3 = RaycastGroundY(tx + 8, tz + 8, ty)
      local y4 = RaycastGroundY(tx, tz + 8, ty)
      local p1 = MakePost(tx - 50, y1, tz, 1, 0, "Brick_Red", 2.5)
      local p2 = MakePost(tx - 42, y2, tz, 0, 1, "Brick_Red", 2.5)
      local p3 = MakePost(tx - 42, y3, tz + 8, -1, 0, "Brick_Red", 2.5)
      local p4 = MakePost(tx - 50, y4, tz + 8, 0, -1, "Brick_Red", 2.5)
      RegionSync.OnPacket({
        nType = 0x22,
        tData = {
          k = "fence", mode = "pieces", n = 8, ox = 5000,
          x0 = math.floor((tx - 53) * 100), y0 = math.floor((y1 - 5) * 100), z0 = math.floor((tz - 3) * 100),
          x1 = math.floor((tx - 39) * 100), y1 = math.floor((y1 + 8) * 100), z1 = math.floor((tz + 11) * 100),
          posts = Arr(p1, p2, p3, p4),
          panels = Arr(MakePanel(1, 2, p1, p2, "Brick_Red"), MakePanel(2, 3, p2, p3, "Brick_Red"),
            MakePanel(3, 4, p3, p4, "Brick_Red"), MakePanel(4, 1, p4, p1, "Brick_Red")),
        },
      })
      Log(string.format("GP: building test habitat loop at (%.1f, %.1f, %.1f)", tx, y1, tz))
      return
    end
    if not s.gpGatePlaced and s.nStageTime >= 5.0 then
      s.gpGatePlaced = true
      local BuildSync = require("PZ2Coop.BuildSync")
      local tx, ty, tz = s.gpBuildPos.x, s.gpBuildPos.y, s.gpBuildPos.z
      local y1 = RaycastGroundY(tx + 4, tz, ty)
      BuildSync.QueueJob(function()
        local w = api.world.GetWorldAPIs()
        local api_hb = w.habitatboundary
        local h = w.editors:CreateUndoOperationsHierarchy()
        pcall(function() h:SetBoundaryEditPreviewModeModifyVolumes(true) end)
        h:SetPerformTerrainModificationsModifyVolumes(false)
        local op = h:GetTerrainEditOperation()
        w.gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true,
          w.gameterrain.CheckLakesMode_WhenTerrainCollisionEnabled, false)
        w.gameterrain:SetTerrainEditOpGridRenderingEnabled(op, false)
        local cl = h:GetHabitatBoundaryChangeList()
        h:BeginVolumeModificationsBlock()
        local vGate = Vector3:new(tx + 4, y1, tz)
        local bOk, sRes = pcall(function()
          return api_hb:PlaceAttachableProp("habitatgate", {
            oHabitatBoundaryChangeList = cl,
            vPlacePoint = vGate,
            vFacingDirection = Vector3:new(0, 0, -1),
            vRayStart = Vector3:new(tx + 4, y1 + 20, tz),
            vRayDir = Vector3:new(0, -1, 0),
            nSmoothness = 0, nPanelMode = 0,
            nHeightAngleStart = 0, nHeightAngleEnd = 0,
            nWindowCutDistFromBase = 0, nWindowCutDistFromTop = 0,
            nBoundaryExtraFlags = 0,
            nTopRelativeHeight = 2.5, nTopWorldHeight = y1 + 2.5,
            bTopHeightWorldRelative = false, bBottomHeightWorldRelative = false,
            bUseHeightDeadZones = false, nDeadZoneRange = 0.25,
            bAlignMultiSelectHeights = false,
            sBoundaryType = "Brick_Red", sHabitatType = "Standard",
          })
        end)
        cl:RefreshAdjacentPosts()
        h:EndVolumeModificationsBlock()
        h:Commit()
        Log("GP: PlaceAttachableProp(habitatgate) ok=" .. tostring(bOk) .. " res=" .. tostring(sRes))
      end, "gp place gate")
      return
    end
    if s.nStageTime < 14.0 then
      return
    end
    Record("gate_probe", false, "no habitat gate appeared after building test habitat")
    SetStage("cleanup")
    return
  end
  Log("GP: found " .. tostring(#tGates) .. " habitat gate(s), using id=" .. tostring(tGates[1]))
  local nGateID = tGates[1]
  local tr = tWorld.transform:CalculateWorldTransform(nGateID)
  local vPos = tr:GetPos()
  local vF = tr:GetF()
  s.gp = {nGateID = nGateID, vPos = vPos, vF = vF, bOpened = false}
  local vStart = Vector3:new(vPos:GetX() - vF:GetX() * 2.0, vPos:GetY() + 1.55, vPos:GetZ() - vF:GetZ() * 2.0)
  pcall(function()
    require("Editors.Shared.BaseUIMode").SetNewMode("WalkingCamera", {vStartingPos = vStart})
  end)
  ProbeGateSweeps("CLOSED", vPos, vF, nGateID)
  SetStage("gp_open")
end

local StepGPOpen = function()
  local gp = s.gp
  local tWorld = api.world.GetWorldAPIs()
  local Presence = require("PZ2Coop.Presence")
  local WalkingCamera = require("Components.Cameras.WalkingCamera")
  local Vector3 = require("Vector3")
  if not gp.bOpened then
    if s.nStageTime < 1.0 then return end
    gp.bOpened = true
    Log("GP: opening gate " .. tostring(gp.nGateID) .. " (RequestHabitatGateOpen + SetLocalOpenGate)")
    tWorld.attractions:RequestHabitatGateOpen(gp.nGateID)
    Presence.SetLocalOpenGate(gp.nGateID)
    Presence.SetOpenGatePos("local", {x = gp.vPos:GetX(), y = gp.vPos:GetY(), z = gp.vPos:GetZ()})
    return
  end
  if s.nStageTime >= 3.0 then
    ProbeGateSweeps("OPENED", gp.vPos, gp.vF, gp.nGateID)
    local p = api.physics
    local nPhys = api.entity.FindEntityByName("MainPhysicsWorld")
    local nFlags = WalkingCamera.GetCollisionFlags(true)
    local gx, gy, gz = gp.vPos:GetX(), gp.vPos:GetY(), gp.vPos:GetZ()
    local fx, fz = gp.vF:GetX(), gp.vF:GetZ()
    local flen = math.sqrt(fx * fx + fz * fz)
    if flen < 1e-4 then fx, fz = 0, 1 else fx, fz = fx / flen, fz / flen end
    local rx, rz = fz, -fx
    local vFront = Vector3:new(gx - fx * 1.6, gy + 1.55, gz - fz * 1.6)
    local vBack = Vector3:new(gx + fx * 1.6, gy + 1.55, gz + fz * 1.6)
    -- 1) Opened gate: walk front -> back and back -> front
    local vFwd = WalkingCamera.SweepAndSlide(nPhys, vFront, vBack, nFlags, 0.15, 4)
    local nFwdProg = (vFwd:GetX() - vFront:GetX()) * fx + (vFwd:GetZ() - vFront:GetZ()) * fz
    local vRev = WalkingCamera.SweepAndSlide(nPhys, vBack, vFront, nFlags, 0.15, 4)
    local nRevProg = (vBack:GetX() - vRev:GetX()) * fx + (vBack:GetZ() - vRev:GetZ()) * fz
    -- 2) Side wall 1.6 m off-center MUST still block while gate is open
    local vSideA = Vector3:new(gx + rx * 1.6 - fx * 1.6, gy + 1.55, gz + rz * 1.6 - fz * 1.6)
    local vSideB = Vector3:new(gx + rx * 1.6 + fx * 1.6, gy + 1.55, gz + rz * 1.6 + fz * 1.6)
    local vSide = WalkingCamera.SweepAndSlide(nPhys, vSideA, vSideB, nFlags, 0.15, 4)
    local nSideProg = (vSide:GetX() - vSideA:GetX()) * fx + (vSide:GetZ() - vSideA:GetZ()) * fz
    -- 3) Close gate again -> MUST block again
    Presence.SetLocalOpenGate(nil)
    Presence.SetOpenGatePos("local", nil)
    tWorld.attractions:ReleaseHabitatGateOpenRequest(gp.nGateID)
    local vClosed = WalkingCamera.SweepAndSlide(nPhys, vFront, vBack, nFlags, 0.15, 4)
    local nClosedProg = (vClosed:GetX() - vFront:GetX()) * fx + (vClosed:GetZ() - vFront:GetZ()) * fz
    pcall(function() require("Editors.Shared.BaseUIMode").SetNewMode("Select") end)
    local sDetail = string.format("openFwd=%.2f/3.20 openRev=%.2f/3.20 sideWall=%.2f/3.20 reclosed=%.2f/3.20",
      nFwdProg, nRevProg, nSideProg, nClosedProg)
    local bPass = nFwdProg >= 3.10 and nRevProg >= 3.10 and nSideProg < 2.0 and nClosedProg < 2.0
    Record("gate_walkthrough", bPass, sDetail)
    SetStage("cleanup")
  end
end

local StepEPEnter = function()
  local BaseUIMode = require("Editors.Shared.BaseUIMode")
  local Vector3 = require("Vector3")
  local Presence = require("PZ2Coop.Presence")
  local tWorld = api.world.GetWorldAPIs()
  if not s.epStarted then
    s.epStarted = true
    local worldScript = api.world.GetScript(api.world.GetActive())
    local hud = worldScript and worldScript:GetHUD()
    if hud and hud.FullScreenUIPause then
      pcall(hud.FullScreenUIPause, hud, false)
    end
    if hud and hud.ChangeSimulationSpeedSettings then
      pcall(hud.ChangeSimulationSpeedSettings, hud, false, 1)
    end
    if api.time and api.time.Unpause then
      for _ = 1, 3 do
        if (api.time.GetDeltaTime and api.time.GetDeltaTime() or 0) <= 0 then
          pcall(api.time.Unpause, "World")
        end
      end
    end
    local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
    local tFinal = tWorld.CameraModeManager:GetCameraDataFinal()
    local vCentre = (tFinal and tFinal.vCentrePos) or vCam or Vector3:new(0, 10, 0)
    local gx, gy, gz = vCentre:GetX(), vCentre:GetY(), vCentre:GetZ()
    if vCam ~= nil then
      local dx, dz = gx - vCam:GetX(), gz - vCam:GetZ()
      local d = math.sqrt(dx * dx + dz * dz)
      if d > 8.0 then
        gx = vCam:GetX() + (dx / d) * 6.0
        gz = vCam:GetZ() + (dz / d) * 6.0
      end
    end
    s.epStartPos = Vector3:new(gx, gy + 1.55, gz)
    s.epOrigStartPos = tWorld.CameraModeManager.GetWalkingStartPos
    tWorld.CameraModeManager.GetWalkingStartPos = function() return s.epStartPos end
    BaseUIMode.SetNewMode("WalkingCameraInit")
    Log(string.format("EP: entered WalkingCameraInit pos=(%.1f,%.1f,%.1f)", gx, gy, gz))
    return
  end
  local tPrev = Presence.GetExplorePreview()
  if tPrev ~= nil and tPrev.nAvatar ~= nil and tPrev.tAnim ~= nil then
    local tok = api.entity.CreateRequestCompletionToken()
    local nFoot = api.entity.InstantiatePrefab("AttachPoint", "PZ2CoopEPFoot", tok, nil, tPrev.nAvatar, true,
      {AttachBone = "def_l_foot_joint"})
    local nHead = api.entity.InstantiatePrefab("AttachPoint", "PZ2CoopEPHead", tok, nil, tPrev.nAvatar, true,
      {AttachBone = "def_c_head_joint"})
    s.ep = {tok = tok, nFoot = nFoot, nHead = nHead,
      minFootY = 1e9, maxFootY = -1e9, minHeadY = 1e9, maxHeadY = -1e9, nSamples = 0,
      footSpan = {n = 0}, bSawLoop = false, nLoopStartClock = nil}
    Record("explore_preview_spawn", true, "entity=" .. tostring(tPrev.nAvatar) .. " initClip=" .. tostring(tPrev.tAnim.sClip))
    SetStage("ep_measure")
    return
  end
  if s.nStageTime >= 15.0 then
    if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
    Record("explore_preview_spawn", false, "timed out waiting for explore preview avatar")
    BaseUIMode.SetNewMode("Select")
    SetStage("cleanup")
  end
end

local StepEPMeasure = function()
  local BaseUIMode = require("Editors.Shared.BaseUIMode")
  local Presence = require("PZ2Coop.Presence")
  local tWorld = api.world.GetWorldAPIs()
  local tPrev = Presence.GetExplorePreview()
  local ep = s.ep
  if tPrev == nil or tPrev.nAvatar == nil or ep == nil then
    if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
    Record("explore_preview_loop", false, "preview vanished during measurement")
    BaseUIMode.SetNewMode("Select")
    SetStage("cleanup")
    return
  end
  if tWorld.bakedanimation and tWorld.bakedanimation.RequestAllBonesForCalculate then
    pcall(tWorld.bakedanimation.RequestAllBonesForCalculate, tWorld.bakedanimation, tPrev.nAvatar)
  end
  if tPrev.sPhase == "loop" then
    if not ep.bSawLoop then
      ep.bSawLoop = true
      ep.nLoopStartClock = s.nStageTime
    end
    local nElapsed = s.nStageTime - ep.nLoopStartClock
    if api.entity.HaveRequestsCompleted(ep.tok) then
      local bOkA, trAv = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, tPrev.nAvatar)
      local bOkF, trF = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, ep.nFoot)
      local bOkH, trH = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, ep.nHead)
      if bOkA and trAv ~= nil and bOkF and trF ~= nil and bOkH and trH ~= nil then
        local ay = trAv:GetPos():GetY()
        local fy = trF:GetPos():GetY() - ay
        local hy = trH:GetPos():GetY() - ay
        if fy < ep.minFootY then ep.minFootY = fy end
        if fy > ep.maxFootY then ep.maxFootY = fy end
        if hy < ep.minHeadY then ep.minHeadY = hy end
        if hy > ep.maxHeadY then ep.maxHeadY = hy end
        ep.nSamples = ep.nSamples + 1
        SampleBoneRange(ep.footSpan, ep.nFoot)
      end
    end
    if nElapsed >= 1.8 or s.nStageTime >= 6.0 then
      if ep.nFoot then pcall(api.entity.DestroyEntity, ep.nFoot) end
      if ep.nHead then pcall(api.entity.DestroyEntity, ep.nHead) end
      if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
      local nSpan = RangeSpan(ep.footSpan)
      local sDetail = string.format("loop(n=%d) footY=[%.3f,%.3f] headY=[%.3f,%.3f] span=%.3fm",
        ep.nSamples, ep.minFootY, ep.maxFootY, ep.minHeadY, ep.maxHeadY, nSpan)
      local bPass = ep.bSawLoop and ep.nSamples >= 5 and ep.minFootY > 2.0 and nSpan > 0.15
      Record("explore_preview_loop", bPass, sDetail)
      BaseUIMode.SetNewMode("Select")
      SetStage("ep_exit")
    end
  elseif s.nStageTime >= 6.0 then
    if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
    Record("explore_preview_loop", false, "never reached loop phase")
    BaseUIMode.SetNewMode("Select")
    SetStage("ep_exit")
  end
end

local StepEPExit = function()
  local Presence = require("PZ2Coop.Presence")
  if s.nStageTime < 0.5 then
    return
  end
  local bClean = Presence.GetExplorePreview() == nil
  Record("explore_preview_cleanup", bClean, bClean and "preview destroyed cleanly on Select" or "preview still alive")
  SetStage("cleanup")
end

-- ---- plan "mirror_place": remote path/floor + aquarium applies, own route vs open-editor route ----------
-- Fixtures (the player's own blueprints, copied by tools/test_live_game.py, never in git):
-- <game>\PZ2Coop\test_path.bin (path/floor chunks) and test_aquarium.bin (a prefab aquarium group).
-- Path cases: a reference copy is placed at P, then sent for real; loopback mirrors it 50 m east. The mirror
-- is compared with the reference cell by cell (occupancy + bottom per 3 m cell), in whole path chunks (the
-- unit the sender logs, RegionSync.TestPathChunks), and the reference itself against the chunk count read
-- from the fixture file (s.nExpRef, never measured from the build under test). Boxes around the mirror, the
-- reference, the world origin and the 2x offset must not change (stray pieces). Each case prints one MEASURE
-- line and one compact AUTOTEST_CHECK line.
-- mp_path_undo undoes and redoes the send through the real Ctrl+Z route (MainHUD.RequestUndoRedo as hooked by
-- BuildSync: a journaled path edit falls through to the game's undo). Solo loopback runs sender and receiver
-- in one game, so this exercises the sender's undo propagating to the mirror; a receiver-side undo of a
-- partner's path needs the 2-PC test.
-- Aquarium PASS: the final copy lands on its target; terrain edits are reported as a measurement.
local c_nPathTolCm = 2
local c_nMirrorDxM = 50 -- Bridge loopback offset (c_nLoopOffsetCm)
local c_nCellM = 3
-- Probe half size: test_path.bin spans ~38 x 34 m (the sender's grown area, diag.log 2026-11-27 run ba6867ab),
-- wider than the 30 m area the packet names. Probes must hold the whole copy, or its own edge chunks count as
-- missing (ref) and stray (ring). 21 m keeps the reference probe clear of the mirror's 5 m ring.
local c_nProbeHalfM = 21
local c_nRingM = 5
local c_nRingGapM = 1 -- RegionSync c_nInsideTolM: the mirror's own pieces may reach this far past its area
local c_nStablePoll = 0.5
local c_nStableTicks = 3
local c_nStableTimeout = 5.0
local c_tMPCases = {
  {sName = "mp_path_own", sKind = "path"},
  {sName = "mp_path_editor", sKind = "path", bEditor = true},
  {sName = "mp_aquarium_probe", sKind = "aq", bProbe = true}, -- learns the group's real half height
  {sName = "mp_aquarium_own", sKind = "aq"},
  {sName = "mp_aquarium_editor", sKind = "aq", bEditor = true},
  {sName = "mp_path_undo", sKind = "path", bUndo = true},
}

local GroundGrid = function(_x, _z)
  local t = {}
  for i = -2, 2 do
    for j = -2, 2 do
      table.insert(t, RaycastGroundY(_x + i * 3, _z + j * 3, 0) or 0)
    end
  end
  return t
end

local GridMaxDelta = function(_a, _b)
  local n = 0
  for i = 1, #_a do
    n = math.max(n, math.abs((_b[i] or 0) - _a[i]))
  end
  return math.floor(n * 100 + 0.5)
end

local ShiftX = function(_r, _nDx)
  return {x0 = _r.x0 + _nDx, y0 = _r.y0, z0 = _r.z0, x1 = _r.x1 + _nDx, y1 = _r.y1, z1 = _r.z1}
end

local OverlapsXZ = function(_a, _b)
  return _a.x0 <= _b.x1 and _a.x1 >= _b.x0 and _a.z0 <= _b.z1 and _a.z1 >= _b.z0
end

local GrowXZ = function(_r, _n)
  return {x0 = _r.x0 - _n, y0 = _r.y0, z0 = _r.z0 - _n, x1 = _r.x1 + _n, y1 = _r.y1, z1 = _r.z1 + _n}
end

-- {bPath, nBottom cm} per c_nCellM cell over _r, in a fixed order, so a copy shifted by whole metres maps
-- cell i onto cell i.
local PathGrid = function(_r)
  local RegionSync = require("PZ2Coop.RegionSync")
  local t = {}
  local nX = math.ceil((_r.x1 - _r.x0) / c_nCellM - 1e-6)
  local nZ = math.ceil((_r.z1 - _r.z0) / c_nCellM - 1e-6)
  for i = 0, nX - 1 do
    for j = 0, nZ - 1 do
      local rCell = {x0 = _r.x0 + i * c_nCellM, x1 = math.min(_r.x0 + (i + 1) * c_nCellM, _r.x1), y0 = _r.y0, y1 = _r.y1,
        z0 = _r.z0 + j * c_nCellM, z1 = math.min(_r.z0 + (j + 1) * c_nCellM, _r.z1)}
      local nBottom, nHits = RegionSync.TestPathBottom(rCell)
      table.insert(t, {bPath = nHits > 0, nBottom = nBottom})
    end
  end
  return t
end

-- Cells whose occupancy differs, or whose path bottom differs by more than c_nPathTolCm; -1 = no grid.
local GridDiff = function(_tRef, _tOther)
  if _tRef == nil or _tOther == nil or #_tRef ~= #_tOther then
    return -1
  end
  local n = 0
  for i, a in ipairs(_tRef) do
    local b = _tOther[i]
    if a.bPath ~= b.bPath then
      n = n + 1
    elseif a.bPath and (a.nBottom == nil or b.nBottom == nil or math.abs(a.nBottom - b.nBottom) > c_nPathTolCm) then
      n = n + 1
    end
  end
  return n
end

-- Areas where applying the mirror must change nothing: a 5 m ring outside the mirror area, the reference
-- area, and two transform-bug boxes (world origin, 2x the mirror offset) unless they touch either copy.
local StrayBoxes = function(_rRef, _rMirror)
  local o = GrowXZ(_rMirror, c_nRingM)
  local y0, y1 = _rMirror.y0 - c_nRingM, _rMirror.y1 + c_nRingM
  local g = c_nRingGapM
  local t = {
    {x0 = o.x0, x1 = _rMirror.x0 - g, z0 = o.z0, z1 = o.z1, y0 = y0, y1 = y1},
    {x0 = _rMirror.x1 + g, x1 = o.x1, z0 = o.z0, z1 = o.z1, y0 = y0, y1 = y1},
    {x0 = _rMirror.x0 - g, x1 = _rMirror.x1 + g, z0 = o.z0, z1 = _rMirror.z0 - g, y0 = y0, y1 = y1},
    {x0 = _rMirror.x0 - g, x1 = _rMirror.x1 + g, z0 = _rMirror.z1 + g, z1 = o.z1, y0 = y0, y1 = y1},
    _rRef,
  }
  local rFar = ShiftX(_rRef, 2 * c_nMirrorDxM)
  rFar.y0, rFar.y1 = rFar.y0 - 20, rFar.y1 + 20
  local rOrigin = {x0 = -15, x1 = 15, z0 = -15, z1 = 15, y0 = -200, y1 = 400}
  for _, r in ipairs({rFar, rOrigin}) do
    if not OverlapsXZ(r, GrowXZ(_rRef, c_nRingM)) and not OverlapsXZ(r, o) then
      table.insert(t, r)
    end
  end
  return t
end

local StrayCounts = function(_tBoxes)
  local RegionSync = require("PZ2Coop.RegionSync")
  local t = {}
  for i, r in ipairs(_tBoxes) do
    local _, nHits = RegionSync.TestPathBottom(r)
    t[i] = nHits
  end
  return t
end

local StrayDelta = function(_tBase, _tNow)
  local n = 0
  for i, nBase in ipairs(_tBase) do
    n = n + math.abs((_tNow[i] or 0) - nBase)
  end
  return n
end

-- Mirror state: whole chunks, piece hits, lowest bottom (cm), cell diff against the reference, stray delta.
local MeasureMirror = function(_c)
  local RegionSync = require("PZ2Coop.RegionSync")
  local nBottom, nHits = RegionSync.TestPathBottom(_c.rMirror)
  return {nChunks = RegionSync.TestPathChunks(_c.rMirror), nHits = nHits, nBottom = nBottom,
    nDiff = GridDiff(_c.tRefGrid, PathGrid(_c.rMirror)), nStray = StrayDelta(_c.tStray0, StrayCounts(_c.tStrayBoxes))}
end

local MirrorSignature = function(_c)
  local RegionSync = require("PZ2Coop.RegionSync")
  local _, nHits = RegionSync.TestPathBottom(_c.rMirror)
  return tostring(RegionSync.TestPathChunks(_c.rMirror)) .. "/" .. nHits .. "/" .. s.mp.nTerrainEdits .. "/" ..
    s.mp.nVoxelChanges
end

-- The player's Ctrl+Z / Ctrl+Y: MainHUD.RequestUndoRedo only reads self.ModeHelperComponentAPI
-- (windows.mainhud.lua), and BuildSync wraps it with the co-op undo (BuildSync.HandleUndoRedo).
local RequestUndoRedo = function(_bUndo)
  local bReq, MainHUD = pcall(require, "Windows.MainHUD")
  if not bReq or type(MainHUD) ~= "table" or rawget(MainHUD, "__PZ2CoopUndoHook") == nil then
    return false, "Ctrl+Z hook not installed"
  end
  return pcall(MainHUD.RequestUndoRedo, {ModeHelperComponentAPI = api.world.GetWorldAPIs().ModeHelperComponent}, _bUndo)
end

local AppliedGroups = function()
  local BuildSync = require("PZ2Coop.BuildSync")
  return tonumber(string.match(BuildSync.Summary(), "applied group=(%d+)") or "0") or 0
end

local OpenPathTool = function()
  local ModeChangeRequestPathEditUI = require("Editors.Path.ModeChangeRequestPathEditUI")
  local req = ModeChangeRequestPathEditUI:new()
  req:StartPathTool()
  req:PerformModeChange()
end

local CloseTool = function()
  pcall(function() require("Editors.Shared.BaseUIMode").SetNewMode("Select") end)
end

local StepMPSetup = function()
  local tWorld = api.world.GetWorldAPIs()
  local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
  -- 60 m inside the camera spot: the +50 m mirror must stay inside the playable area (round 2: bOutsidePlayableArea).
  s.mp = {cx = vCam:GetX() - 60, cz = vCam:GetZ(), i = 0, nTerrainEdits = 0, nVoxelChanges = 0}
  s.mp.fnTerrain = function() s.mp.nTerrainEdits = s.mp.nTerrainEdits + 1 end
  s.mp.fnVolume = function(_tMessages)
    for _, t in pairs(type(_tMessages) == "table" and _tMessages or {}) do
      if type(t) == "table" and t.sType == "VoxelTerrain" then
        s.mp.nVoxelChanges = s.mp.nVoxelChanges + 1
      end
    end
  end
  pcall(function() api.messaging.RegisterReceiver(api.messaging.MsgType_TerrainEditStatsMessage, s.mp.fnTerrain) end)
  pcall(function() api.messaging.RegisterReceiver(api.messaging.MsgType_SpatialVolumeChangedMessage, s.mp.fnVolume) end)
  Bridge.SetLoopback(false)
  Log(string.format("mirror_place: base (%.1f,%.1f) expRef=%s", s.mp.cx, s.mp.cz, tostring(s.nExpRef)))
  SetStage("mp_case")
end

local FinishMPCase = function(_bPass, _sDetail, _sMeasure)
  local mp = s.mp
  rawset(global, "PZ2COOP_FORCE_EDITOR", nil)
  Bridge.SetLoopback(false)
  CloseTool()
  Bridge.Log("MEASURE " .. mp.case.sName .. " " .. (_sMeasure or _sDetail))
  Record(mp.case.sName, _bPass, _sDetail)
  mp.case = nil
end

local ResetCaseClock = function(_c)
  _c.nT, _c.nT0 = 0, s.nStageTime
end

local StartUndoRedo = function(_c, _bUndo)
  ResetCaseClock(_c)
  _c.sSig0 = MirrorSignature(_c)
  _c.sLastSig, _c.nSame, _c.bChanged, _c.nNextPoll = _c.sSig0, 0, false, c_nStablePoll
  local bOk, sErr = RequestUndoRedo(_bUndo)
  if not bOk then
    _c.sUndoErr = (_bUndo and "undo: " or "redo: ") .. tostring(sErr)
  end
end

local FinishPathUndoCase = function(_c)
  local f, u, r = _c.tFirst, _c.tUndo, _c.tRedo
  local bRefOk = s.nExpRef ~= nil and _c.nRefChunks == s.nExpRef
  local bEmpty0 = _c.nMirHits0 == 0 and _c.nMirChunks0 == 0
  local bApply = f.nChunks == _c.nRefChunks and f.nDiff == 0 and f.nStray == 0
  local bUndo = u.nHits == 0 and u.nChunks == 0 and u.nStray == 0 and u.nGroundCm <= c_nPathTolCm
  local bRedo = r.nChunks == _c.nRefChunks and r.nDiff == 0 and r.nStray == 0
  local sDetail = string.format("undoHits=%d redoHits=%d redoDiff=%d strayAfterUndo=%d gridMaxDeltaCm=%d " ..
    "expRef=%s ref=%s apply=%s applyDiff=%d undoChunks=%s redoChunks=%s strayAfterRedo=%d mirror0=%d",
    u.nHits, r.nHits, r.nDiff, u.nStray, u.nGroundCm, tostring(s.nExpRef), tostring(_c.nRefChunks),
    tostring(f.nChunks), f.nDiff, tostring(u.nChunks), tostring(r.nChunks), r.nStray, _c.nMirHits0)
  local sMeasure = sDetail .. string.format(" applyStray=%d undoTimeout=%s redoTimeout=%s err=%s",
    f.nStray, tostring(u.bTimeout), tostring(r.bTimeout), tostring(_c.sUndoErr))
  FinishMPCase(bRefOk and bEmpty0 and bApply and bUndo and bRedo and _c.sUndoErr == nil, sDetail, sMeasure)
end

-- Bounded stability poll after undo/redo: the mirror's chunks, hits and terrain counters changed and then
-- stayed the same for c_nStableTicks polls, or c_nStableTimeout passed.
local StepPathUndoRedo = function(_c)
  if _c.nT < _c.nNextPoll then
    return
  end
  _c.nNextPoll = _c.nT + c_nStablePoll
  local sSig = MirrorSignature(_c)
  _c.bChanged = _c.bChanged or sSig ~= _c.sSig0
  _c.nSame = sSig == _c.sLastSig and _c.nSame + 1 or 0
  _c.sLastSig = sSig
  local bStable = _c.bChanged and _c.nSame >= c_nStableTicks
  if not bStable and _c.nT < c_nStableTimeout then
    return
  end
  local tNow = MeasureMirror(_c)
  tNow.bTimeout = not bStable
  if _c.sPhase == "undo" then
    tNow.nGroundCm = GridMaxDelta(_c.tMirGround0, GroundGrid(_c.x + c_nMirrorDxM, _c.z))
    _c.tUndo = tNow
    _c.sPhase = "redo"
    StartUndoRedo(_c, false)
    return
  end
  _c.tRedo = tNow
  FinishPathUndoCase(_c)
end

local FinishPathCase = function(_c, _tRe)
  local mp = s.mp
  local f, r = _c.tFirst, _tRe
  local nDy = (r.nBottom ~= nil and _c.nRefBottom ~= nil) and (r.nBottom - _c.nRefBottom) or nil
  local nDup = math.max(0, math.max(f.nChunks or 0, r.nChunks or 0) - (_c.nRefChunks or 0))
  local nCellDiff = (f.nDiff < 0 or r.nDiff < 0) and -1 or math.max(f.nDiff, r.nDiff)
  local nStray = math.max(f.nStray, r.nStray)
  -- First placement must land: a corrective re-place leaves the first copy's terrain flatten behind.
  local bPass = s.nExpRef ~= nil and _c.nRefChunks == s.nExpRef and f.nChunks == _c.nRefChunks and
    r.nChunks == _c.nRefChunks and f.nDiff == 0 and r.nDiff == 0 and nStray == 0 and r.nHits == f.nHits and
    nDy ~= nil and math.abs(nDy) <= c_nPathTolCm and _c.nFirstDy ~= nil and math.abs(_c.nFirstDy) <= c_nPathTolCm
  local sDetail = string.format("expRef=%s ref=%s mir=%s resend=%s cellDiff=%d dup=%d stray=%d firstDy=%s dy=%s",
    tostring(s.nExpRef), tostring(_c.nRefChunks), tostring(f.nChunks), tostring(r.nChunks), nCellDiff, nDup, nStray,
    tostring(_c.nFirstDy), tostring(nDy))
  local sMeasure = sDetail .. string.format(" hits=%d->%d refBottom=%s mirBottom=%s terrainEdits=%d voxel=%d t=%.1fs",
    f.nHits, r.nHits, tostring(_c.nRefBottom), tostring(r.nBottom), mp.nTerrainEdits - _c.nEdits0,
    mp.nVoxelChanges - _c.nVox0, _c.nT)
  FinishMPCase(bPass, sDetail, sMeasure)
end

local StepMPCase = function()
  local mp = s.mp
  local RegionSync = require("PZ2Coop.RegionSync")
  local BuildSync = require("PZ2Coop.BuildSync")
  if mp.case == nil then
    mp.i = mp.i + 1
    local tCase = c_tMPCases[mp.i]
    if tCase == nil then
      pcall(function() api.messaging.UnregisterReceiver(api.messaging.MsgType_TerrainEditStatsMessage, mp.fnTerrain) end)
      pcall(function() api.messaging.UnregisterReceiver(api.messaging.MsgType_SpatialVolumeChangedMessage, mp.fnVolume) end)
      SetStage("cleanup")
      return
    end
    -- One clean spot per case, 55 m apart along z, so cases (and their probes + rings) never touch each other.
    local x, z = mp.cx, mp.cz + 55 * mp.i
    mp.case = {sName = tCase.sName, tCase = tCase, x = x, z = z, y = RaycastGroundY(x, z, 0), sPhase = "open", nT = 0, nT0 = s.nStageTime}
    if tCase.bEditor then
      OpenPathTool()
    end
    return
  end
  local c = mp.case
  c.nT = s.nStageTime - c.nT0
  if c.sPhase == "open" then
    if c.nT < 1.5 then
      return -- let the tool finish opening
    end
    local tCase = c.tCase
    local SetRouteFlags = function()
      if tCase.bEditor then
        rawset(global, "PZ2COOP_FORCE_EDITOR", true)
      end
    end
    c.tGrid = GroundGrid(c.x, c.z)
    c.nEdits0, c.nVox0 = mp.nTerrainEdits, mp.nVoxelChanges
    RegionSync.TakeLastPathDy()
    local nX, nY, nZ = math.floor(c.x * 100 + 0.5), math.floor(c.y * 100 + 0.5), math.floor(c.z * 100 + 0.5)
    if tCase.sKind == "path" then
      -- Reference copy at P (stands in for the player's own path); sent for real once it settled.
      c.rRef = {x0 = c.x - 15, y0 = c.y - 3, z0 = c.z - 15, x1 = c.x + 15, y1 = c.y + 6, z1 = c.z + 15}
      c.rProbe = {x0 = c.x - c_nProbeHalfM, y0 = c.rRef.y0, z0 = c.z - c_nProbeHalfM, x1 = c.x + c_nProbeHalfM,
        y1 = c.rRef.y1, z1 = c.z + c_nProbeHalfM}
      c.rMirror = ShiftX(c.rProbe, c_nMirrorDxM)
      c.fnSetRouteFlags = SetRouteFlags
      RegionSync.OnPacket({nType = 0x22, sFile = Bridge.GetPrefix() .. "test_path.bin", tData = {
        k = "path", n = 1, cx = nX, cy = nY + 50, cz = nZ, by0 = nY,
        x0 = nX - 1500, y0 = nY - 300, z0 = nZ - 1500, x1 = nX + 1500, y1 = nY + 600, z1 = nZ + 1500}})
      c.sPhase = "ref"
      ResetCaseClock(c)
      return
    else
      SetRouteFlags()
      c.nGroups0 = AppliedGroups()
      -- The fixture's group centre sat 6.9 m above its ground on the sender.
      BuildSync.OnPacket({nType = 0x20, sFile = Bridge.GetPrefix() .. "test_aquarium.bin",
        tData = {x = nX, y = nY + (mp.nAqHalfCm or 690), z = nZ}})
      BuildSync.TakeLastGroupBox()
    end
    c.sPhase = "wait"
    ResetCaseClock(c)
    return
  end
  local tCase = c.tCase
  if c.sPhase == "ref" then
    if RegionSync.TakeLastPathDy() ~= nil then
      c.bRefDone = true
      c.nRefAt = c.nT
    end
    if c.bRefDone and c.nT - c.nRefAt >= 1.0 then
      -- Ground truth before anything is sent: the reference copy, the empty mirror area, the stray boxes.
      c.nRefBottom = RegionSync.TestPathBottom(c.rProbe)
      c.nRefChunks = RegionSync.TestPathChunks(c.rProbe)
      c.tRefGrid = PathGrid(c.rProbe)
      c.tStrayBoxes = StrayBoxes(c.rProbe, c.rMirror)
      c.tStray0 = StrayCounts(c.tStrayBoxes)
      local _, nMirHits0 = RegionSync.TestPathBottom(c.rMirror)
      c.nMirHits0, c.nMirChunks0 = nMirHits0, RegionSync.TestPathChunks(c.rMirror)
      c.tMirGround0 = GroundGrid(c.x + c_nMirrorDxM, c.z)
      -- Real send: the local-edit route saves the area, loopback mirrors it 50 m east through the route under test.
      c.nEdits0, c.nVox0 = mp.nTerrainEdits, mp.nVoxelChanges
      Bridge.SetLoopback(true)
      c.fnSetRouteFlags()
      RegionSync.TestSendPath(c.rRef)
      c.sPhase = "wait"
      ResetCaseClock(c)
    elseif c.nT >= 15.0 then
      FinishMPCase(false, "reference path never applied expRef=" .. tostring(s.nExpRef))
    end
    return
  end
  if c.sPhase == "undo" or c.sPhase == "redo" then
    StepPathUndoRedo(c)
    return
  end
  -- wait phase
  if tCase.sKind == "path" then
    local nDyNow = RegionSync.TakeLastPathDy()
    if nDyNow ~= nil then
      c.nLastDyAt = c.nT
      c.nFirstDy = c.nFirstDy or nDyNow
    end
    local nSettle = 3.0 -- room for the one height-correcting re-place
    if (c.nLastDyAt ~= nil and c.nT - c.nLastDyAt >= nSettle) or c.nT >= 20.0 then
      if c.tFirst == nil then
        c.tFirst = MeasureMirror(c)
        if tCase.bUndo then
          c.sPhase = "undo"
          StartUndoRedo(c, true)
          return
        end
        -- Send the same path again: the mirror now replaces its own copy (removes, then places). Gaps in the
        -- 2026-11-27 play test sat exactly where a mirror replaced its own chunks.
        c.nLastDyAt = nil
        ResetCaseClock(c)
        c.fnSetRouteFlags()
        RegionSync.TestSendPath(c.rRef)
        return
      end
      FinishPathCase(c, MeasureMirror(c))
    end
  else
    local bApplied = AppliedGroups() > c.nGroups0
    c.tBox = BuildSync.TakeLastGroupBox() or c.tBox
    local nLanded = BuildSync.TakeLastLandedCm()
    if nLanded ~= nil then
      c.nLanded, c.nLandedAt = nLanded, c.nT
    end
    -- Wait for the landing report and room for one correcting re-place after it.
    if (c.nLandedAt ~= nil and c.nT - c.nLandedAt >= 8.0) or c.nT >= 30.0 then
      local nEdits, nVox = mp.nTerrainEdits - c.nEdits0, mp.nVoxelChanges - c.nVox0
      local nGround = GridMaxDelta(c.tGrid, GroundGrid(c.x, c.z))
      local nGroundCm = math.floor(c.y * 100 + 0.5)
      local sBottom = c.tBox and tostring(math.floor(c.tBox.y0 - nGroundCm + 0.5)) or "nil"
      if tCase.bProbe then
        if c.tBox ~= nil then
          mp.nAqHalfCm = math.floor((c.tBox.y1 - c.tBox.y0) / 2 + 0.5)
        end
        FinishMPCase(c.tBox ~= nil, string.format("halfHeight=%s bottomAboveGround=%s terrainEdits=%d voxel=%d",
          tostring(mp.nAqHalfCm), sBottom, nEdits, nVox))
        return
      end
      -- PASS: the final copy sits on its target. Terrain edits are reported as a measurement.
      local bPass = c.nLanded ~= nil and c.nLanded <= c_nPathTolCm
      FinishMPCase(bPass, string.format("landed=%s applied=%s bottomAboveGround=%s terrainEdits=%d voxel=%d groundDelta=%dcm t=%.1fs",
        tostring(c.nLanded), tostring(bApplied), sBottom, nEdits, nVox, nGround, c.nT))
    end
  end
end

local c_tStages = {
  wait_menu = StepMenu,
  wait_park = StepWaitPark,
  park_host = StepParkHost,
  test_notifications = StepNotifications,
  test_presence = StepPresence,
  test_presence_anim = StepPresenceAnim,
  test_presence_done = StepPresenceDone,
  test_water = StepWater,
  test_staff = StepStaff,
  test_ledger = StepLedger,
  fw_inspect = StepFWInspect,
  fw_single_post = StepFWSinglePost,
  fw_open_wall = StepFWOpenWall,
  fw_delete_open = StepFWDeleteOpen,
  fw_closed_loop = StepFWClosedLoop,
  fw_habitat_gate_blueprint = StepFWHabitatGateBlueprint,
  fw_curved_wall = StepFWCurvedWall,
  fw_water_roundtrip = StepFWWaterRoundtrip,
  fw_fence_with_water = StepFWFenceWithWater,
  fw_aquarium_water = StepFWAquariumWater,
  sc_prepare = StepSCPrepare,
  sc_habitat_walls = StepSCHabitatWalls,
  sc_water_sync = StepSCWaterSync,
  sc_walk_emotes = StepSCWalkEmotes,
  gp_setup = StepGPSetup,
  gp_open = StepGPOpen,
  ep_enter = StepEPEnter,
  ep_measure = StepEPMeasure,
  ep_exit = StepEPExit,
  mp_setup = StepMPSetup,
  mp_case = StepMPCase,
  cleanup = StepCleanup,
}

Autotest.Update = function(_nDt)
  if not s.bActive then
    return
  end
  s.nStageTime = s.nStageTime + (_nDt or 0)
  local fn = c_tStages[s.sStage]
  if fn ~= nil then
    local bOk, sErr = pcall(fn)
    if not bOk then
      Record("stage_" .. tostring(s.sStage), false, tostring(sErr))
      SetStage("cleanup")
    end
  end
end
