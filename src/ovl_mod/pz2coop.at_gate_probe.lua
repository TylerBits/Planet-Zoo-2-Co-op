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

  return {
    gp_setup = StepGPSetup,
    gp_open = StepGPOpen,
  }
end
