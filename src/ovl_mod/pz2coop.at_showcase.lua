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


  return {
    sc_prepare = StepSCPrepare,
    sc_habitat_walls = StepSCHabitatWalls,
    sc_water_sync = StepSCWaterSync,
    sc_walk_emotes = StepSCWalkEmotes,
  }
end
