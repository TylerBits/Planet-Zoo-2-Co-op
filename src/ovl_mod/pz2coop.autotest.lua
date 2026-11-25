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
  s.sPlan = tostring(_sPlan or "full")
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
        return tEnv:RequireInterface("Interfaces.IParkLoadSaveManager"):RequestLoadParkFromFile(c_sTestZoo)
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
      for _, sP in ipairs({"Head", "Hair", "Torso", "Legs"}) do
        local pId = api.entity.FindEntityByName(sP, nOwn)
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
