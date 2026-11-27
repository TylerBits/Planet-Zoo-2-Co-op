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

local StepVBSetup = function()
  local tWorld = api.world.GetWorldAPIs()
  local Vector3 = require("Vector3")
  local Quaternion = require("Quaternion")
  local TransformQ = require("TransformQ")
  local RegionSync = require("PZ2Coop.RegionSync")
  if s.vb == nil then
    -- Ensure simulation is unpaused so vehicle physics ticks.
    local worldScript = api.world.GetScript(api.world.GetActive())
    local hud = worldScript and worldScript:GetHUD()
    if hud and hud.FullScreenUIPause then pcall(hud.FullScreenUIPause, hud, false) end
    if hud and hud.ChangeSimulationSpeedSettings then pcall(hud.ChangeSimulationSpeedSettings, hud, false, 1) end
    if api.time and api.time.Unpause then pcall(api.time.Unpause, "World") end

    local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
    local cx, cz = vCam:GetX(), vCam:GetZ()
    local gx, gy, gz = cx, RaycastGroundY(cx, cz, 0), cz
    local gt = tWorld.gameterrain
    for _, tOff in ipairs({{0, 0}, {40, 0}, {-40, 0}, {0, 40}, {0, -40}, {60, 40}, {-60, 40}, {0, 80}}) do
      local tx, tz = cx + tOff[1], cz + tOff[2]
      local ty = RaycastGroundY(tx, tz, nil)
      local tyW = RaycastGroundY(tx, tz + 10, nil)
      if ty ~= nil and tyW ~= nil and math.abs(ty - tyW) < 0.4 then
        local np, nl = CountFenceInBox(tx, ty, tz + 8, 18)
        local tLakes = (gt and gt:FindLakesWithSphereCheck(Vector3:new(tx, ty, tz + 8), 22)) or {}
        if np == 0 and nl == 0 and #tLakes == 0 then
          gx, gy, gz = tx, ty, tz
          break
        end
      end
    end

    -- Build a closed 16x10 Brick_Red habitat enclosure with 8 m panels (vanilla max panel length).
    -- Front-left 8 m panel [gx-8..gx] stays solid (Phases 1 & 2); front-right 8 m panel [gx..gx+8] gets GuestGate (Phases 3 & 4).
    local wz0, wz1 = gz + 10, gz + 20
    local wx0, wxm, wx1 = gx - 8, gx, gx + 8
    local y1 = RaycastGroundY(wx0, wz0, gy)
    local ym1 = RaycastGroundY(wxm, wz0, gy)
    local y2 = RaycastGroundY(wx1, wz0, gy)
    local y3 = RaycastGroundY(wx1, wz1, gy)
    local ym2 = RaycastGroundY(wxm, wz1, gy)
    local y4 = RaycastGroundY(wx0, wz1, gy)
    local p1 = MakePost(wx0 - 50, y1, wz0, 1, 0, "Brick_Red", 2.5)
    local p2 = MakePost(wxm - 50, ym1, wz0, 1, 0, "Brick_Red", 2.5)
    local p3 = MakePost(wx1 - 50, y2, wz0, 0, 1, "Brick_Red", 2.5)
    local p4 = MakePost(wx1 - 50, y3, wz1, -1, 0, "Brick_Red", 2.5)
    local p5 = MakePost(wxm - 50, ym2, wz1, -1, 0, "Brick_Red", 2.5)
    local p6 = MakePost(wx0 - 50, y4, wz1, 0, -1, "Brick_Red", 2.5)
    local pan1 = MakePanel(1, 2, p1, p2, "Brick_Red")
    local pan2 = MakePanel(2, 3, p2, p3, "Brick_Red")
    local pan3 = MakePanel(3, 4, p3, p4, "Brick_Red")
    local pan4 = MakePanel(4, 5, p4, p5, "Brick_Red")
    local pan5 = MakePanel(5, 6, p5, p6, "Brick_Red")
    local pan6 = MakePanel(6, 1, p6, p1, "Brick_Red")
    RegionSync.OnPacket({
      nType = 0x22,
      tData = {
        k = "fence", mode = "pieces", n = 12, ox = 5000,
        x0 = math.floor((wx0 - 52) * 100), y0 = math.floor((gy - 4) * 100), z0 = math.floor((wz0 - 2) * 100),
        x1 = math.floor((wx1 - 48) * 100), y1 = math.floor((gy + 6) * 100), z1 = math.floor((wz1 + 2) * 100),
        posts = Arr(p1, p2, p3, p4, p5, p6), panels = Arr(pan1, pan2, pan3, pan4, pan5, pan6),
      },
    })

    s.vb = {
      gx = gx, gy = gy, gz = gz, wallZ = wz0,
      solidX = gx - 4, guestX = gx + 4,
      bGatesQueued = false, bGatesReady = false, bGuestCommitted = false,
      bOutpostSpawned = false, nOutpost = nil, nVehicle = nil,
    }
    Log(string.format("vb_setup: origin=(%.1f,%.1f,%.1f) wallZ=%.1f solidX=%.1f guestX=%.1f",
      gx, gy, gz, wz0, gx - 4, gx + 4))
    return
  end

  local vb = s.vb
  -- Once all 6 panels commit and undo is idle, place far habitatgate and front-right guestgate asynchronously.
  local nPosts, nPanels = CountFenceInBox(vb.gx, vb.gy, vb.wallZ + 5, 20)
  if nPanels >= 6 and not vb.bGatesQueued and not api.undo.IsBusy() and s.nStageTime >= 1.5 then
    vb.bGatesQueued = true
    local BuildSync = require("PZ2Coop.BuildSync")
    local PlaceGateJob = function(_sProp, _px, _pz, _fx, _fz, _fnDone)
      BuildSync.QueueJob(function()
        local undo = api.undo
        while undo.IsBusy() do coroutine.yield() end
        local tw = api.world.GetWorldAPIs()
        local api_hb = tw.habitatboundary
        local h = tw.editors:CreateUndoOperationsHierarchy()
        pcall(function() h:SetBoundaryEditPreviewModeModifyVolumes(true) end)
        h:SetPerformTerrainModificationsModifyVolumes(false)
        local op = h:GetTerrainEditOperation()
        tw.gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true,
          tw.gameterrain.CheckLakesMode_WhenTerrainCollisionEnabled, false)
        tw.gameterrain:SetTerrainEditOpGridRenderingEnabled(op, false)
        local cl = h:GetHabitatBoundaryChangeList()
        h:BeginVolumeModificationsBlock()
        local vGate = Vector3:new(_px, RaycastGroundY(_px, _pz, vb.gy), _pz)
        local tEditData = {
          oHabitatBoundaryChangeList = cl,
          vPlacePoint = vGate,
          vFacingDirection = Vector3:new(_fx, 0, _fz),
          vRayStart = Vector3:new(_px, vb.gy + 20, _pz),
          vRayDir = Vector3:new(0, -1, 0),
          nSmoothness = 0, nPanelMode = 0,
          nHeightAngleStart = 0, nHeightAngleEnd = 0,
          nWindowCutDistFromBase = 0, nWindowCutDistFromTop = 0,
          nBoundaryExtraFlags = 0,
          nTopRelativeHeight = 2.5, nTopWorldHeight = vGate:GetY() + 2.5,
          bTopHeightWorldRelative = false, bBottomHeightWorldRelative = false,
          bUseHeightDeadZones = false, nDeadZoneRange = 0.25,
          bAlignMultiSelectHeights = false,
          sBoundaryType = "Brick_Red", sHabitatType = "Standard",
        }
        local bOk, sRes = pcall(function() return api_hb:PlaceAttachableProp(_sProp, tEditData) end)
        cl:RefreshAdjacentPosts()
        h:EndVolumeModificationsBlock()
        api_hb:AddCashDeltaOperation(cl, false)
        local bt, pt = undo.PreviewChangeList(h:GetFullUndoChangeList())
        while bt ~= nil and not undo.IsOperationComplete(bt) do coroutine.yield() end
        h:BeginVolumeModificationsBlock()
        h:SetPerformTerrainModificationsModifyVolumes(true)
        h:EndVolumeModificationsBlock()
        local bCan = pt ~= nil and undo.CanCommitPreview(pt) or false
        if pt ~= nil then
          bCan = undo.CanCommitPreview(pt)
          while bCan == nil do coroutine.yield() bCan = undo.CanCommitPreview(pt) end
        end
        if bCan then
          local ct = undo.CommitPreview(pt)
          while ct ~= nil and not undo.IsOperationComplete(ct) do coroutine.yield() end
          undo.Checkpoint({sMode = "AutotestVB"})
        elseif pt ~= nil then
          local ct = undo.CancelPreview(pt)
          while ct ~= nil and not undo.IsOperationComplete(ct) do coroutine.yield() end
        end
        Log("vb_setup: placed " .. _sProp .. " ok=" .. tostring(bOk) .. " res=" .. tostring(sRes) .. " committed=" .. tostring(bCan))
        if _fnDone then _fnDone(bCan == true) end
      end)
    end
    PlaceGateJob("habitatgate", vb.gx - 4, vb.wallZ + 10, 0, 1, function()
      PlaceGateJob("guestgate", vb.guestX, vb.wallZ, 0, -1, function(_bCommitted)
        vb.bGuestCommitted = _bCommitted
        vb.bGatesReady = true
      end)
    end)
  end

  -- Spawn a stationary buggy 10 m in front of the SOLID left half of the front wall once gates are ready.
  if vb.bGatesReady and vb.nVehicle == nil then
    if not vb.bDirectBuggy then
      vb.bDirectBuggy = true
      local bOk, nV = pcall(api.entity.InstantiatePrefab, "VEH_Staff_Buggy", "AutotestBuggy", nil,
        TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(Vector3:new(0, 0, 0)),
          Vector3:new(vb.solidX, vb.gy + 0.25, vb.gz)),
        api.entity.NullEntityID, true, {})
      Log("vb_setup: direct VEH_Staff_Buggy ok=" .. tostring(bOk) .. " id=" .. tostring(nV))
      if bOk and nV ~= nil then
        vb.nDirectBuggy = nV
      end
    end
    if vb.nDirectBuggy ~= nil and tWorld.transform:HasTransform(vb.nDirectBuggy) then
      vb.nVehicle = vb.nDirectBuggy
    end
  end

  if vb.nVehicle ~= nil and vb.bGatesReady and nPanels >= 4 then
    vb.bEntered = false
    vb.phase = 1
    vb.bPhaseStarted = false
    vb.maxZ = vb.gz
    vb.prevZ = vb.gz
    vb.maxSpeed = 0
    vb.bCrossedWall = false
    vb.bTeleportedBack = false
    vb.nDriveStart = 0
    Record("vb_setup", vb.bGuestCommitted,
      string.format("veh=%s panels=%d guestCommitted=%s", tostring(vb.nVehicle), nPanels, tostring(vb.bGuestCommitted)))
    SetStage("vb_drive")
  elseif s.nStageTime >= 25.0 then
    Record("vb_setup", false, string.format("veh=%s panels=%d gatesReady=%s",
      tostring(vb.nVehicle), nPanels, tostring(vb.bGatesReady)))
    SetStage("cleanup")
  end
end

local StepVBDrive = function()
  local tWorld = api.world.GetWorldAPIs()
  local BaseUIMode = require("Editors.Shared.BaseUIMode")
  local Vector3 = require("Vector3")
  local Quaternion = require("Quaternion")
  local TransformQ = require("TransformQ")
  local vb = s.vb
  if not vb.bEntered then
    vb.bEntered = true
    BaseUIMode.SetNewMode("DriveVehicle", {nVehicle = vb.nVehicle, bThirdPersonCamera = true})
    return
  end
  if not vb.bPhaseStarted then
    if vb.phase == 1 and s.nStageTime < 2.2 then
      return
    end
    if (vb.phase == 4 or vb.phase == 5 or vb.phase == 6) and s.nStageTime < (vb.nPhaseReadyAt or 0) then
      return
    end
    -- Spawn a fresh stationary buggy for phases 3, 4, 5 & 6 at the exact test pose.
    if (vb.phase == 3 or vb.phase == 4 or vb.phase == 5 or vb.phase == 6) and vb.nSpawnedPhase ~= vb.phase then
      if vb.nPendingVeh == nil then
        local px, pz, pyaw = vb.guestX - 5.0, vb.wallZ - 2.5, math.pi * 0.5
        if vb.phase == 4 then
          px, pz, pyaw = vb.guestX, vb.wallZ - 6.0, 0
        elseif vb.phase == 5 then
          -- Repro manual driving: start from rest close to the guest door (aligned with 2 m opening)
          px, pz, pyaw = vb.guestX + 0.25, vb.wallZ - 3.2, 0
        elseif vb.phase == 6 then
          -- Repro slow/wait bug: sit right in front of the open guest door for 12.0 s before driving in
          px, pz, pyaw = vb.guestX, vb.wallZ - 2.8, 0
        end
        pcall(BaseUIMode.SetNewMode, "Select")
        local bOk, nV = pcall(api.entity.InstantiatePrefab, "VEH_Staff_Buggy", "AutotestBuggyP" .. tostring(vb.phase), nil,
          TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(Vector3:new(pyaw, 0, 0)), Vector3:new(px, vb.gy + 0.25, pz)),
          api.entity.NullEntityID, true, {})
        if bOk and nV ~= nil then
          vb.nPendingVeh = nV
          vb.nPendingAt = s.nStageTime
        end
        return
      end
      if not tWorld.transform:HasTransform(vb.nPendingVeh) or (s.nStageTime - (vb.nPendingAt or 0)) < 0.4 then
        return
      end
      vb.nVehicle = vb.nPendingVeh
      vb.nPendingVeh = nil
      vb.nSpawnedPhase = vb.phase
      BaseUIMode.SetNewMode("DriveVehicle", {nVehicle = vb.nVehicle, bThirdPersonCamera = true})
      vb.nEnterAt = s.nStageTime
      return
    end
    local nEnterWait = (vb.phase == 6) and 12.0 or 0.6
    if (vb.phase == 3 or vb.phase == 4 or vb.phase == 5 or vb.phase == 6) and (s.nStageTime - (vb.nEnterAt or 0)) < nEnterWait then
      return
    end
    vb.bPhaseStarted = true
    vb.nDriveStart = s.nStageTime
    vb.nNextLog = 0
    vb.maxZ = (vb.phase == 4) and (vb.wallZ - 6.0) or ((vb.phase == 5) and (vb.wallZ - 3.2) or ((vb.phase == 6) and (vb.wallZ - 2.8) or vb.gz))
    vb.prevZ = vb.maxZ
    vb.maxSpeed = 0
    vb.bCrossedWall = false
    vb.bTeleportedBack = false
    Bridge.SendCommand("veh_bounds", {remove = (vb.phase >= 2) and "1" or "0"})
    Bridge.SendCommand("autotest_drive", {on = "1"})
    Log("vb_drive: phase " .. tostring(vb.phase) .. " started (remove=" .. ((vb.phase >= 2) and "1" or "0") .. " veh=" .. tostring(vb.nVehicle) .. ")")
    return
  end

  local tr = tWorld.transform:CalculateWorldTransform(vb.nVehicle)
  local nElapsed = s.nStageTime - vb.nDriveStart
  if vb.phase == 3 or vb.phase == 4 then
    local Vehicles = require("PZ2Coop.Vehicles")
    local tVS = Vehicles.GetState and Vehicles.GetState() or nil
    if tVS ~= nil and tVS.tAutoOpenGate ~= nil then
      if vb.phase == 3 then vb.bOpenedDuringParallel = true end
      if vb.phase == 4 then vb.bOpenedDuringApproach = true end
    end
  end
  if tr ~= nil then
    local vP = tr:GetPos()
    local vx, vy, vz = vP:GetX(), vP:GetY(), vP:GetZ()
    local spd = (tWorld.vehicles and tWorld.vehicles.GetVehicleSpeed and tWorld.vehicles:GetVehicleSpeed(vb.nVehicle)) or 0
    if spd > vb.maxSpeed then vb.maxSpeed = spd end
    if vz > vb.maxZ then vb.maxZ = vz end
    if vz > vb.wallZ + 0.5 then vb.bCrossedWall = true end
    if nElapsed > 0.3 and (vb.prevZ - vz) > 5.0 then vb.bTeleportedBack = true end
    vb.prevZ = vz
    vb.lastX, vb.lastY, vb.lastZ = vx, vy, vz
    if nElapsed >= (vb.nNextLog or 0) then
      vb.nNextLog = (vb.nNextLog or 0) + 1.0
      Log(string.format("vb_drive[p%d] t=%.1f x=%.2f z=%.2f dist=%.2f spd=%.2f",
        vb.phase, nElapsed, vx, vz, vb.wallZ - vz, spd))
    end
  end

  if nElapsed >= 4.0 then
    Bridge.SendCommand("autotest_drive", {on = "0"})
    local nDistToWall = vb.wallZ - vb.maxZ
    local sDetail = string.format("maxZ=%.2f wallZ=%.2f distToWall=%.2fm maxSpd=%.2f crossed=%s teleported=%s",
      vb.maxZ, vb.wallZ, nDistToWall, vb.maxSpeed, tostring(vb.bCrossedWall), tostring(vb.bTeleportedBack))
    if vb.phase == 1 then
      local bReproOk = vb.maxSpeed > 1.0 and nDistToWall > 3.5
      Record("vb_vanilla_repro", bReproOk, sDetail)
      vb.phase = 2
      vb.bPhaseStarted = false
    elseif vb.phase == 2 then
      local bApproachOk = vb.maxSpeed > 1.0 and nDistToWall <= 3.2 and (not vb.bTeleportedBack)
      local bCollisionOk = not vb.bCrossedWall
      Record("vb_fixed_approach", bApproachOk, sDetail)
      Record("vb_fixed_wall_collision", bCollisionOk, sDetail)
      vb.phase = 3
      vb.bPhaseStarted = false
      vb.bOpenedDuringParallel = false
    elseif vb.phase == 3 then
      Record("vb_guest_parallel", not vb.bOpenedDuringParallel and vb.maxSpeed > 1.0,
        string.format("opened=%s maxSpd=%.2f", tostring(vb.bOpenedDuringParallel), vb.maxSpeed))
      vb.phase = 4
      vb.bPhaseStarted = false
      vb.nPhaseReadyAt = s.nStageTime + 0.5
      vb.bOpenedDuringApproach = false
    elseif vb.phase == 4 then
      local bAutoOpen = vb.bOpenedDuringApproach == true
      local bPassedThrough = vb.maxZ > (vb.wallZ + 2.0)
      Record("vb_guest_autoopen", bAutoOpen, string.format("opened=%s maxZ=%.2f wallZ=%.2f", tostring(bAutoOpen), vb.maxZ, vb.wallZ))
      Record("vb_guest_passthrough", bPassedThrough,
        string.format("maxZ=%.2f wallZ=%.2f maxSpd=%.2f", vb.maxZ, vb.wallZ, vb.maxSpeed))
      vb.phase = 5
      vb.bPhaseStarted = false
      vb.nPhaseReadyAt = s.nStageTime + 0.5
    elseif vb.phase == 5 then
      local bPassedFromStop = vb.maxZ > (vb.wallZ + 2.0)
      Record("vb_guest_from_stop", bPassedFromStop,
        string.format("maxZ=%.2f wallZ=%.2f maxSpd=%.2f", vb.maxZ, vb.wallZ, vb.maxSpeed))
      vb.phase = 6
      vb.bPhaseStarted = false
      vb.nPhaseReadyAt = s.nStageTime + 0.5
    else
      local bPassedAfterWait = vb.maxZ > (vb.wallZ + 2.0)
      Record("vb_guest_wait_and_enter", bPassedAfterWait,
        string.format("maxZ=%.2f wallZ=%.2f maxSpd=%.2f", vb.maxZ, vb.wallZ, vb.maxSpeed))
      pcall(BaseUIMode.SetNewMode, "Select")
      SetStage("cleanup")
    end
  end
end

  return {
    vb_setup = StepVBSetup,
    vb_drive = StepVBDrive,
  }
end
