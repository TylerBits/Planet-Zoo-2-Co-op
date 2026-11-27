-- Autotest plan module (loaded lazily by pz2coop.autotest.lua).
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
local H = require("PZ2Coop.AT_Helpers")

local Plan = module(...)

Plan.Register = function(ctx)
  local s, Log, Record, SetStage, Finish = ctx.s, ctx.Log, ctx.Record, ctx.SetStage, ctx.Finish
  local RaycastGroundY, CountFenceInBox, Arr, MakePost, MakePanel = H.RaycastGroundY, H.CountFenceInBox, H.Arr, H.MakePost, H.MakePanel
  local SampleBoneRange, RangeSpan = H.SampleBoneRange, H.RangeSpan

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

  return {
    test_notifications = StepNotifications,
    test_presence = StepPresence,
    test_presence_anim = StepPresenceAnim,
    test_presence_done = StepPresenceDone,
    test_water = StepWater,
    test_staff = StepStaff,
    test_ledger = StepLedger,
  }
end
