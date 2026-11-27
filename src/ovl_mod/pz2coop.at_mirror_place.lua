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
  s.mp.tSpatial = {}
  s.mp.fnVolume = function(_tMessages)
    for _, t in pairs(type(_tMessages) == "table" and _tMessages or {}) do
      if type(t) == "table" and t.sType == "VoxelTerrain" then
        s.mp.nVoxelChanges = s.mp.nVoxelChanges + 1
      elseif type(t) == "table" and t.sType == "SpatialDatabase" and #s.mp.tSpatial < 64 then
        -- Raw retail change messages, kept for tools/eval_probes/dump_path_snapshot.lua.
        pcall(function()
          table.insert(s.mp.tSpatial, {f = t.nFlags, a = {t.vAABBMin:GetX(), t.vAABBMin:GetY(), t.vAABBMin:GetZ(),
            t.vAABBMax:GetX(), t.vAABBMax:GetY(), t.vAABBMax:GetZ()}})
        end)
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
  -- Survives the next Start() (which clears s.mp), so an eval probe in the same game can inspect this case.
  rawset(global, "__PZ2CoopLastMirrorCase", {sName = mp.case.sName, rRef = mp.case.rRef, rProbe = mp.case.rProbe,
    rMirror = mp.case.rMirror, nExpRef = s.nExpRef, tSpatial = mp.tSpatial})
  mp.tSpatial = {}
  mp.nRan = (mp.nRan or 0) + 1
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
    -- --case <name>: run only that case (an aquarium case still runs the probe it takes its height from).
    while tCase ~= nil and s.sCase ~= nil and tCase.sName ~= s.sCase and
        not (tCase.bProbe and string.find(s.sCase, "^mp_aquarium") ~= nil) do
      mp.i = mp.i + 1
      tCase = c_tMPCases[mp.i]
    end
    if tCase == nil then
      pcall(function() api.messaging.UnregisterReceiver(api.messaging.MsgType_TerrainEditStatsMessage, mp.fnTerrain) end)
      pcall(function() api.messaging.UnregisterReceiver(api.messaging.MsgType_SpatialVolumeChangedMessage, mp.fnVolume) end)
      if s.sCase ~= nil and (mp.nRan or 0) == 0 then
        Record("case_filter", false, "mirror_place has no case named " .. s.sCase)
      end
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

-- ---- plan "host_stress": leave + host again, many times -------------------------------------------------
-- Reproduces the steamclient64 access violation inside CreateListenSocketP2P right after CreateLobby
-- completes (crash dumps 2026-11-27 4:00 pm; steam_p2p.cpp pollPendingCall). The gap before each host varies
-- (0 .. 1.6 s) so the lobby call lands at different points of the game's frame, and each host starts while an
-- aquarium blueprint (test_aquarium.bin) is being placed: the player crash came while placing an aquarium.
-- The open Co-op menu's status + friends polls (with avatar fetches, reset every cycle) run all the time, as
-- they do when a player hosts from the menu.
-- 15 cycles: Steam answers CreateLobby with k_EResultTimeout (16) after ~21 quick creates (run 94a531d9) and
-- keeps throttling for minutes; a throttled cycle waits c_nThrottleWait and retries (not a crash, not a FAIL
-- unless it happens more than c_nMaxThrottles times).
-- PASS: every cycle got a room code and the game is still alive (a crash ends the run without AUTOTEST_DONE;

  return {
    mp_setup = StepMPSetup,
    mp_case = StepMPCase,
  }
end
