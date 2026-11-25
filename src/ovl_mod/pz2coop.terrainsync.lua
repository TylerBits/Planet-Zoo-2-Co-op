-- Terrain stroke sync (packet 0x23 ACTION_TERRAIN_STROKE, docs/ARCHITECTURE.md §3.D, docs/NETWORK_PROTOCOL.md).
--   detect:  wraps Editors.Terrain.TerrainEditMode.TransitionIn to install a lightweight metatable proxy on
--            self.GameTerrainAPI (same ACSE pattern as api.game, LUA_API_MAP.md §1.4). Captures brush dabs
--            ONLY while self.bMouseHeld == true (hover previews are ignored) and batches them every 0.15 s
--            or 8 dabs into a single 0x23 JSON packet.
--   apply:   replays validated dabs on BuildSync's job queue using the exact vanilla TerrainEditMode recipe
--            (editors:CreateTerrainUndoOperationsHierarchy -> SetTerrainEditOpCollisionFlags ->
--            gameterrain:Add*ToChangeList -> api.undo.PreviewChangeList / CommitPreview / Checkpoint / ClearHistory).
-- Packet 0x23 (JSON): {k = "terrain", dabs = {{op, x, y, z (cm), sz (cm), int (x1000), ...}}, ox? (loopback cm)}.
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
local coroutine = global.coroutine
local require = global.require
local Vector3 = require("Vector3")
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local TerrainSync = module(...)

local c_nTerrainPacket = 0x23
local c_nFlushInterval = 0.15
local c_nMaxDabsPerPacket = 8
local c_nMaxReceiveDabs = 16
local c_nMaxBrushSizeM = 60.0
local c_nMinBrushSizeM = 0.1
local c_nMaxIntensity = 5.0
local c_nLogLimit = 300

local c_tAllowedOps = {
  pushpull = true,
  flatten = true,
  chisel = true,
  smooth = true,
  smoothbrush = true,
  roughen = true,
  terrace = true,
  gradient = true,
  attract = true,
  curl = true,
  sharpen = true,
  paint = true,
  paintgrad = true,
  autopaint = true,
}

local s = {
  bInstalled = false,
  bSending = false,
  nClock = 0,
  nFlushTimer = 0,
  nLogs = 0,
  tPendingDabs = {},
  tActiveMode = nil,
}

local Log = function(_s)
  if s.nLogs < c_nLogLimit then
    s.nLogs = s.nLogs + 1
    Bridge.Log("terrain sync: " .. _s)
  end
end

local IsFinite = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

local Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

local Milli = function(_n)
  return math.floor(_n * 1000 + 0.5)
end

local Vec3Coords = function(_v)
  if _v == nil then
    return nil
  end
  local bOk, x, y, z = pcall(function()
    if _v.GetX ~= nil then
      return _v:GetX(), _v:GetY(), _v:GetZ()
    end
    return _v:X(), _v:Y(), _v:Z()
  end)
  if bOk and IsFinite(x) and IsFinite(y) and IsFinite(z) then
    return x, y, z
  end
  return nil
end

local FlushPending = function()
  if #s.tPendingDabs == 0 then
    return
  end
  local tDabs = setmetatable(s.tPendingDabs, api.json and api.json.GetArrayMetatable and api.json.GetArrayMetatable() or nil)
  s.tPendingDabs = {}
  s.nFlushTimer = 0
  if not s.bSending or Bridge.IsApplying() then
    return
  end
  BuildSync.Count("sent terrain stroke")
  Bridge.SendPacket(c_nTerrainPacket, nil, {
    k = "terrain",
    dabs = tDabs,
  })
end

local RecordDab = function(_mode, _tDab)
  if not s.bSending or Bridge.IsApplying() then
    return
  end
  if _mode == nil or not _mode.bMouseHeld then
    return
  end
  table.insert(s.tPendingDabs, _tDab)
  if #s.tPendingDabs >= c_nMaxDabsPerPacket then
    FlushPending()
  end
end

local MakeBaseDab = function(_sOp, _vPos, _nSize, _nIntensity)
  local x, y, z = Vec3Coords(_vPos)
  if x == nil or not IsFinite(_nSize) or not IsFinite(_nIntensity) then
    return nil
  end
  return {
    op = _sOp,
    x = Cm(x),
    y = Cm(y),
    z = Cm(z),
    sz = Cm(_nSize),
    int = Milli(_nIntensity),
  }
end

-- Creates a lightweight proxy over raw GameTerrainAPI that captures committed brush dabs from TerrainEditMode.
local WrapGameTerrainAPI = function(_mode, _raw)
  if _raw == nil or rawget(_raw, "__PZ2CoopTerrainProxy") then
    return _raw
  end
  local tHooks = {
    __PZ2CoopTerrainProxy = true,

    AddPushPullWithLakeSupportToChangeList = function(_, _clh, _pinch, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
      local tDab = MakeBaseDab("pushpull", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddPushPullWithLakeSupportToChangeList(_clh, _pinch, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
    end,

    AddPlaneFlattenWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _vDir, _vOrigin, _nQuad, ...)
      local tDab = MakeBaseDab("flatten", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        local dx, dy, dz = Vec3Coords(_vDir)
        local ox, oy, oz = Vec3Coords(_vOrigin)
        if dx ~= nil and ox ~= nil then
          tDab.dx, tDab.dy, tDab.dz = Milli(dx), Milli(dy), Milli(dz)
          tDab.ox0, tDab.oy0, tDab.oz0 = Cm(ox), Cm(oy), Cm(oz)
        end
        RecordDab(_mode, tDab)
      end
      return _raw:AddPlaneFlattenWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _vDir, _vOrigin, _nQuad, ...)
    end,

    AddLowerToPlaneWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _vDir, _vOrigin, _nQuad, ...)
      local tDab = MakeBaseDab("chisel", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        local dx, dy, dz = Vec3Coords(_vDir)
        local ox, oy, oz = Vec3Coords(_vOrigin)
        if dx ~= nil and ox ~= nil then
          tDab.dx, tDab.dy, tDab.dz = Milli(dx), Milli(dy), Milli(dz)
          tDab.ox0, tDab.oy0, tDab.oz0 = Cm(ox), Cm(oy), Cm(oz)
        end
        RecordDab(_mode, tDab)
      end
      return _raw:AddLowerToPlaneWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _vDir, _vOrigin, _nQuad, ...)
    end,

    AddSmoothWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
      local tDab = MakeBaseDab("smooth", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddSmoothWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
    end,

    AddSmoothBrushWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
      local tDab = MakeBaseDab("smoothbrush", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddSmoothBrushWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
    end,

    AddRoughenWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _nTile, _nQuad, ...)
      local tDab = MakeBaseDab("roughen", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        tDab.tile = IsFinite(_nTile) and Milli(_nTile) or 1000
        RecordDab(_mode, tDab)
      end
      return _raw:AddRoughenWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _nTile, _nQuad, ...)
    end,

    AddTerraceWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _nHeight, _bOff, _nQuad, ...)
      local tDab = MakeBaseDab("terrace", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        tDab.th = IsFinite(_nHeight) and Cm(_nHeight) or 100
        tDab.bo = _bOff == true and 1 or 0
        RecordDab(_mode, tDab)
      end
      return _raw:AddTerraceWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _nHeight, _bOff, _nQuad, ...)
    end,

    AddGradientConstrainedBrushToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _nSlope, _nQuad, ...)
      local tDab = MakeBaseDab("gradient", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        tDab.sl = IsFinite(_nSlope) and Milli(_nSlope) or 500
        RecordDab(_mode, tDab)
      end
      return _raw:AddGradientConstrainedBrushToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _nSlope, _nQuad, ...)
    end,

    AddAttractBrushWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _bFlag, _nQuad, ...)
      local tDab = MakeBaseDab("attract", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddAttractBrushWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _bFlag, _nQuad, ...)
    end,

    AddCurlBrushWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _bFlag, _nQuad, ...)
      local tDab = MakeBaseDab("curl", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddCurlBrushWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _bFlag, _nQuad, ...)
    end,

    AddSharpenBrushWithLakeSupportToChangeList = function(_, _clh, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
      local tDab = MakeBaseDab("sharpen", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddSharpenBrushWithLakeSupportToChangeList(_clh, _lakeId, _vPos, _nSize, _nIntensity, _nQuad, ...)
    end,

    AddPaintVoxelColoursToChangeList = function(_, _op, _vPos, _nSize, _nIntensity, _nA, _nLayer, _nB, _nMode, _bKeep, ...)
      local tDab = MakeBaseDab("paint", _vPos, _nSize, _nIntensity)
      if tDab ~= nil and IsFinite(_nLayer) then
        tDab.layer = math.floor(_nLayer + 0.5)
        tDab.keep = _bKeep == true and 1 or 0
        RecordDab(_mode, tDab)
      end
      return _raw:AddPaintVoxelColoursToChangeList(_op, _vPos, _nSize, _nIntensity, _nA, _nLayer, _nB, _nMode, _bKeep, ...)
    end,

    AddGradientConstrainedPaintToChangeList = function(_, _op, _vPos, _nSize, _nIntensity, _nA, _nGrad, _nLayer, _bKeep, ...)
      local tDab = MakeBaseDab("paintgrad", _vPos, _nSize, _nIntensity)
      if tDab ~= nil and IsFinite(_nLayer) and IsFinite(_nGrad) then
        tDab.layer = math.floor(_nLayer + 0.5)
        tDab.grad = Milli(_nGrad)
        tDab.keep = _bKeep == true and 1 or 0
        RecordDab(_mode, tDab)
      end
      return _raw:AddGradientConstrainedPaintToChangeList(_op, _vPos, _nSize, _nIntensity, _nA, _nGrad, _nLayer, _bKeep, ...)
    end,

    AddAutoPaintVoxelColoursToChangeList = function(_, _op, _vPos, _nSize, _nIntensity, ...)
      local tDab = MakeBaseDab("autopaint", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddAutoPaintVoxelColoursToChangeList(_op, _vPos, _nSize, _nIntensity, ...)
    end,
  }
  return setmetatable(tHooks, {
    __index = function(_, _k)
      local v = _raw[_k]
      if type(v) == "function" then
        return function(_, ...)
          return v(_raw, ...)
        end
      end
      return v
    end,
  })
end

local InstallTerrainHook = function()
  local bOk, TerrainEditMode = pcall(require, "Editors.Terrain.TerrainEditMode")
  if not bOk or type(TerrainEditMode) ~= "table" or rawget(TerrainEditMode, "__PZ2CoopOriginalTransitionIn") ~= nil then
    return
  end
  local fnOrigIn = TerrainEditMode.TransitionIn
  local fnOrigOut = TerrainEditMode.TransitionOut
  if type(fnOrigIn) ~= "function" then
    return
  end
  rawset(TerrainEditMode, "__PZ2CoopOriginalTransitionIn", fnOrigIn)
  TerrainEditMode.TransitionIn = function(self, ...)
    local r = fnOrigIn(self, ...)
    if self.GameTerrainAPI ~= nil then
      self.GameTerrainAPI = WrapGameTerrainAPI(self, self.GameTerrainAPI)
      s.tActiveMode = self
    end
    return r
  end
  if type(fnOrigOut) == "function" then
    rawset(TerrainEditMode, "__PZ2CoopOriginalTransitionOut", fnOrigOut)
    TerrainEditMode.TransitionOut = function(self, ...)
      FlushPending()
      if s.tActiveMode == self then
        s.tActiveMode = nil
      end
      return fnOrigOut(self, ...)
    end
  end
  Log("wrapped TerrainEditMode.TransitionIn")
end

-- ---- apply (runs on BuildSync's job queue inside Bridge.BeginApply/EndApply) -----------------------------
local ApplyOneDab = function(_gt, _clh, _op, _tDab, _nOxCm)
  if type(_tDab) ~= "table" or not c_tAllowedOps[_tDab.op] then
    return false
  end
  if not (IsFinite(_tDab.x) and IsFinite(_tDab.y) and IsFinite(_tDab.z) and IsFinite(_tDab.sz) and IsFinite(_tDab.int)) then
    return false
  end
  local nSize = math.max(c_nMinBrushSizeM, math.min(c_nMaxBrushSizeM, _tDab.sz / 100))
  local nIntensity = math.max(-c_nMaxIntensity, math.min(c_nMaxIntensity, _tDab.int / 1000))
  local vPos = Vector3:new((_tDab.x + _nOxCm) / 100, _tDab.y / 100, _tDab.z / 100)
  local sOp = _tDab.op

  if sOp == "pushpull" then
    _gt:AddPushPullWithLakeSupportToChangeList(_clh, nil, nil, vPos, nSize, nIntensity, 0)
  elseif sOp == "flatten" or sOp == "chisel" then
    local vDir = Vector3:new(0, 1, 0)
    local vOrigin = vPos
    if IsFinite(_tDab.dx) and IsFinite(_tDab.dy) and IsFinite(_tDab.dz) then
      vDir = Vector3:new(_tDab.dx / 1000, _tDab.dy / 1000, _tDab.dz / 1000)
    end
    if IsFinite(_tDab.ox0) and IsFinite(_tDab.oy0) and IsFinite(_tDab.oz0) then
      vOrigin = Vector3:new((_tDab.ox0 + _nOxCm) / 100, _tDab.oy0 / 100, _tDab.oz0 / 100)
    end
    if sOp == "flatten" then
      _gt:AddPlaneFlattenWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, vDir, vOrigin, 0)
    else
      _gt:AddLowerToPlaneWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, vDir, vOrigin, 0)
    end
  elseif sOp == "smooth" then
    _gt:AddSmoothWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, 0)
  elseif sOp == "smoothbrush" then
    _gt:AddSmoothBrushWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, 0)
  elseif sOp == "roughen" then
    local nTile = IsFinite(_tDab.tile) and (_tDab.tile / 1000) or 1.0
    _gt:AddRoughenWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, nTile, 0)
  elseif sOp == "terrace" then
    local nHeight = IsFinite(_tDab.th) and math.max(0.1, math.min(50.0, _tDab.th / 100)) or 1.0
    _gt:AddTerraceWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, nHeight, _tDab.bo == 1, 0)
  elseif sOp == "gradient" then
    local nSlope = IsFinite(_tDab.sl) and math.max(0, math.min(1.57, _tDab.sl / 1000)) or 0.5
    _gt:AddGradientConstrainedBrushToChangeList(_clh, nil, vPos, nSize, nIntensity, nSlope, 0)
  elseif sOp == "attract" then
    _gt:AddAttractBrushWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, false, 0)
  elseif sOp == "curl" then
    _gt:AddCurlBrushWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, false, 0)
  elseif sOp == "sharpen" then
    _gt:AddSharpenBrushWithLakeSupportToChangeList(_clh, nil, vPos, nSize, nIntensity, 0)
  elseif sOp == "paint" then
    local nLayer = IsFinite(_tDab.layer) and math.max(0, math.min(31, math.floor(_tDab.layer))) or 0
    _gt:AddPaintVoxelColoursToChangeList(_op, vPos, nSize, nIntensity, 1, nLayer, 1,
      _gt.PaintVoxelColoursMode_Lerp or 0, _tDab.keep == 1)
  elseif sOp == "paintgrad" then
    local nLayer = IsFinite(_tDab.layer) and math.max(0, math.min(31, math.floor(_tDab.layer))) or 0
    local nGrad = IsFinite(_tDab.grad) and math.max(0.01, math.min(10.0, _tDab.grad / 1000)) or 1.0
    _gt:AddGradientConstrainedPaintToChangeList(_op, vPos, nSize, nIntensity, 1, nGrad, nLayer, _tDab.keep == 1)
  elseif sOp == "autopaint" then
    _gt:AddAutoPaintVoxelColoursToChangeList(_op, vPos, nSize, nIntensity)
  else
    return false
  end
  return true
end

local Job_ApplyTerrainStroke = function(_tData)
  if not BuildSync.IsUndoFree() then
    BuildSync.RequestRetry()
    return
  end
  local tWorld = api.world.GetWorldAPIs()
  local gt = tWorld.gameterrain
  local editors = tWorld.editors
  if gt == nil or editors == nil or editors.CreateTerrainUndoOperationsHierarchy == nil then
    Log("terrain APIs unavailable; stroke dropped")
    return
  end
  local nOxCm = IsFinite(_tData.ox) and _tData.ox or 0
  local tDabs = _tData.dabs
  local nApplied = 0
  BuildSync.Breadcrumb("apply terrain stroke (" .. tostring(#tDabs) .. " dabs)")

  local bCommitted = false
  local bOk, sError = pcall(function()
    local clh = editors:CreateTerrainUndoOperationsHierarchy()
    local oChangeList = clh:GetFullUndoChangeList()
    local oOp = clh:GetTerrainEditOperation()
    if gt.SetTerrainEditOpCollisionFlags ~= nil then
      gt:SetTerrainEditOpCollisionFlags(oOp, true, false, false, false, false, gt.CheckLakesMode_Off or 0, false)
    end
    for i = 1, math.min(#tDabs, c_nMaxReceiveDabs) do
      if ApplyOneDab(gt, clh, oOp, tDabs[i], nOxCm) then
        nApplied = nApplied + 1
      end
    end
    if nApplied == 0 then
      return
    end
    local undo = api.undo
    local busyToken, previewToken = undo.PreviewChangeList(oChangeList)
    while not undo.IsOperationComplete(busyToken) do
      coroutine.yield()
    end
    local bCanCommit = undo.CanCommitPreview(previewToken)
    while bCanCommit == nil do
      coroutine.yield()
      bCanCommit = undo.CanCommitPreview(previewToken)
    end
    local waitToken = bCanCommit and undo.CommitPreview(previewToken) or undo.CancelPreview(previewToken)
    while not undo.IsOperationComplete(waitToken) do
      coroutine.yield()
    end
    undo.Checkpoint({sMode = "PZ2Coop"})
    undo.ClearHistory({})
    bCommitted = bCanCommit == true
  end)
  if not bOk then
    Log("terrain stroke error: " .. tostring(sError))
  end
  BuildSync.Count(bCommitted and "applied terrain stroke" or "terrain stroke failed")
  Log(string.format("remote terrain stroke (%d dabs) %s", nApplied, bCommitted and "applied" or "rejected"))
end

-- ---- module API ------------------------------------------------------------------------------------------
TerrainSync.Install = function()
  if s.bInstalled then
    return
  end
  s.tPendingDabs = {}
  s.nFlushTimer = 0
  InstallTerrainHook()
  s.bInstalled = true
  Log("installed")
end

TerrainSync.Uninstall = function()
  FlushPending()
  s.bInstalled = false
  s.tPendingDabs = {}
  s.tActiveMode = nil
end

TerrainSync.ResetSnapshot = function()
  s.tPendingDabs = {}
  s.nFlushTimer = 0
end

TerrainSync.Update = function(_nDt, _bSending)
  if not s.bInstalled then
    return
  end
  s.nClock = s.nClock + _nDt
  s.bSending = _bSending
  InstallTerrainHook()
  if #s.tPendingDabs > 0 then
    s.nFlushTimer = s.nFlushTimer + _nDt
    local bReleased = s.tActiveMode == nil or not s.tActiveMode.bMouseHeld
    if bReleased or s.nFlushTimer >= c_nFlushInterval then
      FlushPending()
    end
  end
end

TerrainSync.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nTerrainPacket or type(_tMsg.tData) ~= "table" or _tMsg.tData.k ~= "terrain" then
    return false
  end
  local d = _tMsg.tData
  if type(d.dabs) ~= "table" or #d.dabs == 0 then
    Log("empty terrain stroke dropped")
    return true
  end
  BuildSync.QueueRemote(function() Job_ApplyTerrainStroke(d) end, false)
  return true
end
