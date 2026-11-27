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


  return {
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
  }
end
