-- Terrain stroke & stamp sync (packet 0x23 ACTION_TERRAIN_STROKE, docs/ARCHITECTURE.md §3.D).
--   detect:  1) wraps Editors.Terrain.TerrainEditMode (TransitionIn/TransitionOut/Advance) to install a
--               metatable proxy on self.GameTerrainAPI capturing all sculpt/noise/paint/modifier dabs while
--               self.bMouseHeld == true, batched every 0.15 s or 8 dabs.
--            2) wraps Editors.Terrain.TerrainShapeStampMode & TerrainHeightStampMode (TransitionIn/Out/
--               FeaturePlaced) so large shape stamps (cube/sphere/cylinder/pyramid/wedge) and height stamps
--               (mountains/valleys/canyons) sync cleanly across peers.
--   safety:  prevents concurrent terrain-preview crashes (PlanetZoo2.exe+0x6e75372) in BOTH directions:
--            - Remote terrain jobs wait in a dedicated queue while the local player is actively sculpting or
--              holding a stamp preview (never calling Breadcrumb/yield between IsUndoFree and PreviewChangeList).
--            - Local TerrainEditMode.Advance pauses preview creation for the 1-2 frames while Bridge.IsApplying()
--              is committing a remote terrain edit.
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
local bHasV2, Vector2 = pcall(require, "Vector2")
if not bHasV2 then
  Vector2 = nil
end
local Vector3 = require("Vector3")
local Quaternion = require("Quaternion")
local TransformQ = require("TransformQ")
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local TerrainSync = module(...)

local c_nTerrainPacket = 0x23
local c_nFlushInterval = 0.15
local c_nMaxDabsPerPacket = 8
local c_nMaxReceiveDabs = 16
local c_nMaxRemoteQueueDabs = 512
local c_nMaxRemoteQueueStamps = 32
local c_nMaxBrushSizeM = 200.0
local c_nMinBrushSizeM = 0.1
local c_nMaxIntensity = 5.0
local c_nLogLimit = 300

local c_tAllowedOps = {
  pushpull = true,
  noisy = true,
  flatten = true,
  chisel = true,
  smooth = true,
  smoothbrush = true,
  roughen = true,
  terrace = true,
  gradient = true,
  pinch = true,
  attract = true,
  curl = true,
  sharpen = true,
  paint = true,
  paintgrad = true,
  autopaint = true,
  smoothpaint = true,
  modifier = true,
  modgrad = true,
}

local c_tAllowedShapes = {
  cube = true,
  sphere = true,
  cylinder = true,
  pyramid = true,
  wedge = true,
}

local s = {
  bInstalled = false,
  bSending = false,
  nClock = 0,
  nFlushTimer = 0,
  nLogs = 0,
  tPendingDabs = {},
  tRemoteDabQueue = {}, -- queued remote dabs {dab, ox} waiting for local terrain tool to be idle
  tRemoteStampQueue = {}, -- queued remote shape/height stamps
  bRemoteJobQueued = false,
  tActiveMode = nil, -- active TerrainEditMode instance
  tActiveStampMode = nil, -- active TerrainShapeStampMode or TerrainHeightStampMode instance
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

local IsSafeIdent = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_%-]+$") ~= nil
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

local TransformCoords = function(_tr)
  if _tr == nil then
    return nil
  end
  local bOk, x, y, z, yaw, pitch, roll = pcall(function()
    local vPos = _tr.GetPos and _tr:GetPos() or _tr:Pos()
    local px, py, pz = Vec3Coords(vPos)
    if px == nil then
      return nil
    end
    local q = _tr.GetOr and _tr:GetOr() or nil
    local yw, pt, rl = 0, 0, 0
    if q ~= nil and q.ToYawPitchRoll ~= nil then
      local vYpr = q:ToYawPitchRoll()
      local a, b, c = Vec3Coords(vYpr)
      if a ~= nil then
        yw, pt, rl = a, b, c
      end
    end
    return px, py, pz, yw, pt, rl
  end)
  if bOk and x ~= nil then
    return x, y, z, yaw, pitch, roll
  end
  return nil
end

-- True while the local player is actively sculpting or has an in-flight TerrainEditMode/stamp preview.
-- Prevents concurrent terrain PreviewChangeList calls that crash the engine (PlanetZoo2.exe+0x6e75372).
local IsLocalTerrainBusy = function()
  local m = s.tActiveMode
  if m ~= nil then
    if m.bMouseHeld == true or m.undoBusyToken ~= nil or m.previewToken ~= nil then
      return true
    end
    if type(m.nMouseHeldFrames) == "number" and m.nMouseHeldFrames > 0 then
      return true
    end
  end
  if s.tActiveStampMode ~= nil then
    return true
  end
  return false
end

TerrainSync.IsLocalTerrainBusy = IsLocalTerrainBusy

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

    AddNoisyBrushWithLakeSupportToChangeList = function(_, _clh, _pinch, _lakeId, _vPos, _nSize, _nIntensity, _nTile, _nQuad, ...)
      local tDab = MakeBaseDab("noisy", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        tDab.tile = IsFinite(_nTile) and Milli(_nTile) or 1000
        RecordDab(_mode, tDab)
      end
      return _raw:AddNoisyBrushWithLakeSupportToChangeList(_clh, _pinch, _lakeId, _vPos, _nSize, _nIntensity, _nTile, _nQuad, ...)
    end,

    AddMaskedBrushWithLakeSupportToChangeList = function(_, _clh, _pinch, _lakeId, _pkg, _vPos, _nSize, _nIntensity, _bFlag, _nQuad, ...)
      local tDab = MakeBaseDab("pushpull", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddMaskedBrushWithLakeSupportToChangeList(_clh, _pinch, _lakeId, _pkg, _vPos, _nSize, _nIntensity, _bFlag, _nQuad, ...)
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

    AddPinchBrushToChangeList = function(_, _op, _vPos, _nIntensity, ...)
      local tDab = MakeBaseDab("pinch", _vPos, 4.0, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddPinchBrushToChangeList(_op, _vPos, _nIntensity, ...)
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

    AddCompoundAutoPaintToChangeList = function(_, _op, _pkg, _vPos, _nSize, _nIntensity, _nGrad, ...)
      local tDab = MakeBaseDab("autopaint", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddCompoundAutoPaintToChangeList(_op, _pkg, _vPos, _nSize, _nIntensity, _nGrad, ...)
    end,

    AddSmoothVoxelColoursToChangeList = function(_, _op, _vPos, _nSize, _nIntensity, ...)
      local tDab = MakeBaseDab("smoothpaint", _vPos, _nSize, _nIntensity)
      if tDab ~= nil then
        RecordDab(_mode, tDab)
      end
      return _raw:AddSmoothVoxelColoursToChangeList(_op, _vPos, _nSize, _nIntensity, ...)
    end,

    AddPaintVoxelModifiersToChangeList = function(_, _op, _vPos, _nSize, _nIntensity, _nModIdx, ...)
      local tDab = MakeBaseDab("modifier", _vPos, _nSize, _nIntensity)
      if tDab ~= nil and IsFinite(_nModIdx) then
        tDab.mod = math.floor(_nModIdx + 0.5)
        RecordDab(_mode, tDab)
      end
      return _raw:AddPaintVoxelModifiersToChangeList(_op, _vPos, _nSize, _nIntensity, _nModIdx, ...)
    end,

    AddGradientConstrainedModifiersToChangeList = function(_, _op, _vPos, _nSize, _nIntensity, _nGrad, _nModIdx, ...)
      local tDab = MakeBaseDab("modgrad", _vPos, _nSize, _nIntensity)
      if tDab ~= nil and IsFinite(_nModIdx) and IsFinite(_nGrad) then
        tDab.mod = math.floor(_nModIdx + 0.5)
        tDab.grad = Milli(_nGrad)
        RecordDab(_mode, tDab)
      end
      return _raw:AddGradientConstrainedModifiersToChangeList(_op, _vPos, _nSize, _nIntensity, _nGrad, _nModIdx, ...)
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
  if bOk and type(TerrainEditMode) == "table" and rawget(TerrainEditMode, "__PZ2CoopOriginalTransitionIn") == nil then
    local fnOrigIn = TerrainEditMode.TransitionIn
    local fnOrigOut = TerrainEditMode.TransitionOut
    local fnOrigAdv = TerrainEditMode.Advance
    if type(fnOrigIn) == "function" then
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
      if type(fnOrigAdv) == "function" then
        rawset(TerrainEditMode, "__PZ2CoopOriginalAdvance", fnOrigAdv)
        TerrainEditMode.Advance = function(self, ...)
          -- Never allow local TerrainEditMode to start a PreviewChangeList on top of an in-flight remote commit!
          if Bridge.IsApplying() then
            return
          end
          if self.GameTerrainAPI ~= nil and not rawget(self.GameTerrainAPI, "__PZ2CoopTerrainProxy") then
            self.GameTerrainAPI = WrapGameTerrainAPI(self, self.GameTerrainAPI)
          end
          s.tActiveMode = self
          return fnOrigAdv(self, ...)
        end
      end
      Log("wrapped TerrainEditMode.TransitionIn/Advance")
    end
  end

  -- Large terrain Shape Stamps (cube/sphere/cylinder/pyramid/wedge).
  local bShapeOk, ShapeStampMode = pcall(require, "Editors.Terrain.TerrainShapeStampMode")
  if bShapeOk and type(ShapeStampMode) == "table" and rawget(ShapeStampMode, "__PZ2CoopStampHook") == nil then
    local fnIn, fnOut, fnPlaced = ShapeStampMode.TransitionIn, ShapeStampMode.TransitionOut, ShapeStampMode.FeaturePlaced
    if type(fnPlaced) == "function" then
      rawset(ShapeStampMode, "__PZ2CoopStampHook", true)
      if type(fnIn) == "function" then
        ShapeStampMode.TransitionIn = function(self, ...)
          s.tActiveStampMode = self
          return fnIn(self, ...)
        end
      end
      if type(fnOut) == "function" then
        ShapeStampMode.TransitionOut = function(self, ...)
          if s.tActiveStampMode == self then
            s.tActiveStampMode = nil
          end
          return fnOut(self, ...)
        end
      end
      ShapeStampMode.FeaturePlaced = function(self, ...)
        if s.bSending and not Bridge.IsApplying() and c_tAllowedShapes[self.sShapeType] then
          local tr = self.lastCommittedTransform or (self.cShapeStampMoveObject and self.cShapeStampMoveObject:GetTransform())
          local x, y, z, yaw, pitch, roll = TransformCoords(tr)
          local sx, sy, sz = Vec3Coords(self.vSize)
          if x ~= nil and sx ~= nil then
            BuildSync.Count("sent terrain stamp")
            Log(string.format("local terrain shape stamp %s at (%.1f,%.1f,%.1f) size=(%.1f,%.1f,%.1f)",
              tostring(self.sShapeType), x, y, z, sx, sy, sz))
            Bridge.SendPacket(c_nTerrainPacket, nil, {
              k = "terrain",
              op = "shapestamp",
              shape = self.sShapeType,
              sx = Cm(sx),
              sy = Cm(sy),
              sz = Cm(sz),
              fill = self.bFill == true and 1 or 0,
              ang = IsFinite(self.nWedgeAngle) and Milli(self.nWedgeAngle) or 0,
              x = Cm(x),
              y = Cm(y),
              z = Cm(z),
              yaw = Milli(yaw),
              pitch = Milli(pitch),
              roll = Milli(roll),
            })
          end
        end
        return fnPlaced(self, ...)
      end
      Log("wrapped TerrainShapeStampMode")
    end
  end

  -- Large terrain Height Stamps (mountains, valleys, canyons, cliffs).
  local bHeightOk, HeightStampMode = pcall(require, "Editors.Terrain.TerrainHeightStampMode")
  if bHeightOk and type(HeightStampMode) == "table" and rawget(HeightStampMode, "__PZ2CoopStampHook") == nil then
    local fnIn, fnOut, fnPlaced = HeightStampMode.TransitionIn, HeightStampMode.TransitionOut, HeightStampMode.FeaturePlaced
    if type(fnPlaced) == "function" then
      rawset(HeightStampMode, "__PZ2CoopStampHook", true)
      if type(fnIn) == "function" then
        HeightStampMode.TransitionIn = function(self, ...)
          s.tActiveStampMode = self
          return fnIn(self, ...)
        end
      end
      if type(fnOut) == "function" then
        HeightStampMode.TransitionOut = function(self, ...)
          if s.tActiveStampMode == self then
            s.tActiveStampMode = nil
          end
          return fnOut(self, ...)
        end
      end
      HeightStampMode.FeaturePlaced = function(self, ...)
        if s.bSending and not Bridge.IsApplying() and IsSafeIdent(self.sID) then
          local tr = self.lastCommittedTransform or (self.cMoveObject and self.cMoveObject:GetTransform())
          local x, y, z, yaw, pitch, roll = TransformCoords(tr)
          local bScOk, scx, scz = pcall(function()
            return self.vXZScale:GetX(), self.vXZScale:GetY()
          end)
          local bHOk, nHScale = pcall(function()
            return self:FinalHeightScale()
          end)
          if x ~= nil and bScOk and IsFinite(scx) and IsFinite(scz) and bHOk and IsFinite(nHScale) then
            BuildSync.Count("sent terrain stamp")
            Log(string.format("local terrain height stamp %s at (%.1f,%.1f,%.1f) scale=(%.2f,%.2f) h=%.1f",
              tostring(self.sID), x, y, z, scx, scz, nHScale))
            Bridge.SendPacket(c_nTerrainPacket, nil, {
              k = "terrain",
              op = "heightstamp",
              sid = self.sID,
              scx = Milli(scx),
              scz = Milli(scz),
              hs = Cm(nHScale),
              fill = self.bFill == true and 1 or 0,
              mir = self.bMirror == true and 1 or 0,
              dmask = self.bEnableDynamicMask ~= false and 1 or 0,
              x = Cm(x),
              y = Cm(y),
              z = Cm(z),
              yaw = Milli(yaw),
              pitch = Milli(pitch),
              roll = Milli(roll),
            })
          end
        end
        return fnPlaced(self, ...)
      end
      Log("wrapped TerrainHeightStampMode")
    end
  end
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
  elseif sOp == "noisy" then
    local nTile = IsFinite(_tDab.tile) and (_tDab.tile / 1000) or 1.0
    if _gt.AddNoisyBrushWithLakeSupportToChangeList ~= nil then
      _gt:AddNoisyBrushWithLakeSupportToChangeList(_clh, nil, nil, vPos, nSize, nIntensity, nTile, 0)
    else
      _gt:AddPushPullWithLakeSupportToChangeList(_clh, nil, nil, vPos, nSize, nIntensity, 0)
    end
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
  elseif sOp == "pinch" then
    if _gt.AddPinchBrushToChangeList ~= nil then
      _gt:AddPinchBrushToChangeList(_op, vPos, nIntensity)
    else
      return false
    end
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
  elseif sOp == "smoothpaint" then
    if _gt.AddSmoothVoxelColoursToChangeList ~= nil then
      _gt:AddSmoothVoxelColoursToChangeList(_op, vPos, nSize, nIntensity)
    else
      return false
    end
  elseif sOp == "modifier" then
    local nMod = IsFinite(_tDab.mod) and math.max(0, math.min(16, math.floor(_tDab.mod))) or 0
    if _gt.AddPaintVoxelModifiersToChangeList ~= nil then
      _gt:AddPaintVoxelModifiersToChangeList(_op, vPos, nSize, nIntensity, nMod)
    else
      return false
    end
  elseif sOp == "modgrad" then
    local nMod = IsFinite(_tDab.mod) and math.max(0, math.min(16, math.floor(_tDab.mod))) or 0
    local nGrad = IsFinite(_tDab.grad) and math.max(0.01, math.min(10.0, _tDab.grad / 1000)) or 1.0
    if _gt.AddGradientConstrainedModifiersToChangeList ~= nil then
      _gt:AddGradientConstrainedModifiersToChangeList(_op, vPos, nSize, nIntensity, nGrad, nMod)
    else
      return false
    end
  else
    return false
  end
  return true
end

local CommitChangeListSync = function(_oChangeList)
  -- Re-verify immediately before PreviewChangeList (no yield allowed between this check and PreviewChangeList!).
  if IsLocalTerrainBusy() or not BuildSync.IsUndoFree() then
    return nil
  end
  local undo = api.undo
  local busyToken, previewToken = undo.PreviewChangeList(_oChangeList)
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
  return bCanCommit == true
end

local Job_ApplyTerrainBatch = function(_tBatch)
  if IsLocalTerrainBusy() or not BuildSync.IsUndoFree() then
    -- Put dabs back at the front of the queue without dropping them.
    for i = #_tBatch, 1, -1 do
      table.insert(s.tRemoteDabQueue, 1, _tBatch[i])
    end
    return
  end
  local tWorld = api.world.GetWorldAPIs()
  local gt = tWorld.gameterrain
  local editors = tWorld.editors
  if gt == nil or editors == nil or editors.CreateTerrainUndoOperationsHierarchy == nil then
    Log("terrain APIs unavailable; stroke dropped")
    return
  end
  local nApplied = 0
  local bCommitted = false
  local bDeferred = false
  local bOk, sError = pcall(function()
    local clh = editors:CreateTerrainUndoOperationsHierarchy()
    local oChangeList = clh:GetFullUndoChangeList()
    local oOp = clh:GetTerrainEditOperation()
    if gt.SetTerrainEditOpCollisionFlags ~= nil then
      gt:SetTerrainEditOpCollisionFlags(oOp, true, false, false, false, false, gt.CheckLakesMode_Off or 0, false)
    end
    for i = 1, #_tBatch do
      local tItem = _tBatch[i]
      if ApplyOneDab(gt, clh, oOp, tItem.dab, tItem.ox) then
        nApplied = nApplied + 1
      end
    end
    if nApplied == 0 then
      return
    end
    local res = CommitChangeListSync(oChangeList)
    if res == nil then
      bDeferred = true
    else
      bCommitted = res == true
    end
  end)
  if bDeferred then
    for i = #_tBatch, 1, -1 do
      table.insert(s.tRemoteDabQueue, 1, _tBatch[i])
    end
    return
  end
  if not bOk then
    Log("terrain stroke error: " .. tostring(sError))
  end
  BuildSync.Count(bCommitted and "applied terrain stroke" or "terrain stroke failed")
  Log(string.format("remote terrain stroke (%d dabs) %s", nApplied, bCommitted and "applied" or "rejected"))
end

local Job_ApplyTerrainStamp = function(_tData)
  if IsLocalTerrainBusy() or not BuildSync.IsUndoFree() then
    table.insert(s.tRemoteStampQueue, 1, _tData)
    return
  end
  local tWorld = api.world.GetWorldAPIs()
  local gt = tWorld.gameterrain
  local editors = tWorld.editors
  if gt == nil or editors == nil then
    return
  end
  local nOxCm = IsFinite(_tData.ox) and _tData.ox or 0
  local vPos = Vector3:new((_tData.x + nOxCm) / 100, _tData.y / 100, _tData.z / 100)
  local vYpr = Vector3:new((_tData.yaw or 0) / 1000, (_tData.pitch or 0) / 1000, (_tData.roll or 0) / 1000)
  local tr = TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(vYpr), vPos)
  local bCommitted = false
  local bDeferred = false

  if _tData.op == "shapestamp" then
    if not c_tAllowedShapes[_tData.shape] or not (IsFinite(_tData.sx) and IsFinite(_tData.sy) and IsFinite(_tData.sz)) then
      return
    end
    local bOk, sErr = pcall(function()
      local clh = editors:CreateUndoOperationsHierarchy()
      local oOp = clh.GetTerrainEditOperation and clh:GetTerrainEditOperation() or nil
      if oOp ~= nil and gt.SetTerrainEditOpCollisionFlags ~= nil then
        gt:SetTerrainEditOpCollisionFlags(oOp, true, false, false, false, false, gt.CheckLakesMode_Off or 0, false)
      end
      local vSize = Vector3:new(
        math.max(0.5, math.min(c_nMaxBrushSizeM, _tData.sx / 100)),
        math.max(0.5, math.min(c_nMaxBrushSizeM, _tData.sy / 100)),
        math.max(0.5, math.min(c_nMaxBrushSizeM, _tData.sz / 100)))
      local nAngle = IsFinite(_tData.ang) and (_tData.ang / 1000) or 0
      local moveObj = clh:CreateTerrainShapeStamp(_tData.shape, vSize, _tData.fill == 1, nAngle)
      if moveObj == nil then
        return
      end
      moveObj:SetTransform(tr, {})
      local res = CommitChangeListSync(clh:GetFullUndoChangeList())
      if res == nil then
        bDeferred = true
      else
        bCommitted = res == true
      end
    end)
    if not bOk then
      Log("terrain shape stamp error: " .. tostring(sErr))
    end
  elseif _tData.op == "heightstamp" then
    if not IsSafeIdent(_tData.sid) or not (IsFinite(_tData.scx) and IsFinite(_tData.scz) and IsFinite(_tData.hs)) then
      return
    end
    local oPkg, oPrev = nil, nil
    local bOk, sErr = pcall(function()
      local vt = tWorld.voxelterrain
      if vt == nil or vt.GetPrimaryVoxelTerrainEntityID == nil or gt.CreateHeightStampPackage == nil then
        return
      end
      oPkg = gt:CreateHeightStampPackage(_tData.sid)
      if oPkg == nil then
        return
      end
      local nWait = 0
      while oPkg:AdvanceLoading() and nWait < 300 do
        nWait = nWait + 1
        coroutine.yield()
      end
      if not oPkg:IsReady() then
        return
      end
      if IsLocalTerrainBusy() or not BuildSync.IsUndoFree() then
        bDeferred = true
        return
      end
      local nTerrainId = vt:GetPrimaryVoxelTerrainEntityID()
      oPrev = gt:CreateHeightStampEditPreview(nTerrainId)
      local clh = editors:CreateUndoOperationsHierarchy()
      local oOp = clh.GetTerrainEditOperation and clh:GetTerrainEditOperation() or nil
      if oOp ~= nil and gt.SetTerrainEditOpCollisionFlags ~= nil then
        gt:SetTerrainEditOpCollisionFlags(oOp, true, false, false, false, false, gt.CheckLakesMode_Off or 0, false)
      end
      if Vector2 == nil then
        return
      end
      local vXZScale = Vector2:new(
        math.max(0.05, math.min(20.0, _tData.scx / 1000)),
        math.max(0.05, math.min(20.0, _tData.scz / 1000)))
      local nHeightScale = math.max(-200.0, math.min(200.0, _tData.hs / 100))
      local moveObj = gt:CreateMoveObjectHeightStamp(clh, oPkg, oPrev, vXZScale, nHeightScale,
        _tData.fill == 1, _tData.mir == 1, _tData.dmask ~= 0)
      if moveObj == nil then
        return
      end
      moveObj:SetTransform(tr, {})
      local nOpWait = 0
      while gt.AreMoveObjectTerrainEditOpsBusy ~= nil and gt:AreMoveObjectTerrainEditOpsBusy(moveObj) and nOpWait < 300 do
        nOpWait = nOpWait + 1
        coroutine.yield()
      end
      if gt.BuildLakeHighLevelChangeListsForMoveObject ~= nil then
        gt:BuildLakeHighLevelChangeListsForMoveObject(moveObj)
      end
      if gt.BuildVoxelChangeListsForMoveObject ~= nil then
        local tok = gt:BuildVoxelChangeListsForMoveObject(moveObj)
        while tok ~= nil and not api.undo.IsOperationComplete(tok) do
          coroutine.yield()
        end
      end
      local res = CommitChangeListSync(clh:GetFullUndoChangeList())
      if res == nil then
        bDeferred = true
      else
        bCommitted = res == true
      end
    end)
    if oPrev ~= nil then
      pcall(function() oPrev:ReleaseContents() end)
    end
    if oPkg ~= nil then
      pcall(function() oPkg:ReleaseContents() end)
    end
    if not bOk then
      Log("terrain height stamp error: " .. tostring(sErr))
    end
  end

  if bDeferred then
    table.insert(s.tRemoteStampQueue, 1, _tData)
    return
  end
  BuildSync.Count(bCommitted and "applied terrain stamp" or "terrain stamp failed")
  Log(string.format("remote terrain %s %s", tostring(_tData.op), bCommitted and "applied" or "rejected"))
end

local PumpRemoteQueue = function()
  if s.bRemoteJobQueued or IsLocalTerrainBusy() or not BuildSync.IsUndoFree() then
    return
  end
  if #s.tRemoteStampQueue > 0 then
    local tStamp = table.remove(s.tRemoteStampQueue, 1)
    s.bRemoteJobQueued = true
    BuildSync.QueueRemote(function()
      Job_ApplyTerrainStamp(tStamp)
      s.bRemoteJobQueued = false
    end, false)
  elseif #s.tRemoteDabQueue > 0 then
    local tBatch = {}
    local nTake = math.min(#s.tRemoteDabQueue, c_nMaxReceiveDabs)
    for i = 1, nTake do
      tBatch[i] = table.remove(s.tRemoteDabQueue, 1)
    end
    s.bRemoteJobQueued = true
    BuildSync.QueueRemote(function()
      Job_ApplyTerrainBatch(tBatch)
      s.bRemoteJobQueued = false
    end, false)
  end
end

-- ---- module API ------------------------------------------------------------------------------------------
TerrainSync.Install = function()
  if s.bInstalled then
    return
  end
  s.tPendingDabs = {}
  s.tRemoteDabQueue = {}
  s.tRemoteStampQueue = {}
  s.bRemoteJobQueued = false
  s.nFlushTimer = 0
  InstallTerrainHook()
  if BuildSync.SetExternalBusyCheck ~= nil then
    BuildSync.SetExternalBusyCheck(IsLocalTerrainBusy)
  end
  s.bInstalled = true
  Log("installed")
end

TerrainSync.Uninstall = function()
  FlushPending()
  if BuildSync.SetExternalBusyCheck ~= nil then
    BuildSync.SetExternalBusyCheck(nil)
  end
  s.bInstalled = false
  s.tPendingDabs = {}
  s.tRemoteDabQueue = {}
  s.tRemoteStampQueue = {}
  s.bRemoteJobQueued = false
  s.tActiveMode = nil
  s.tActiveStampMode = nil
end

TerrainSync.ResetSnapshot = function()
  s.tPendingDabs = {}
  s.tRemoteDabQueue = {}
  s.tRemoteStampQueue = {}
  s.bRemoteJobQueued = false
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
  PumpRemoteQueue()
end

TerrainSync.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nTerrainPacket or type(_tMsg.tData) ~= "table" or _tMsg.tData.k ~= "terrain" then
    return false
  end
  local d = _tMsg.tData
  if d.op == "shapestamp" or d.op == "heightstamp" then
    if not (IsFinite(d.x) and IsFinite(d.y) and IsFinite(d.z)) then
      Log("terrain stamp without position dropped")
      return true
    end
    if #s.tRemoteStampQueue < c_nMaxRemoteQueueStamps then
      table.insert(s.tRemoteStampQueue, d)
    end
    PumpRemoteQueue()
    return true
  end
  if type(d.dabs) ~= "table" or #d.dabs == 0 then
    Log("empty terrain stroke dropped")
    return true
  end
  local nOxCm = IsFinite(d.ox) and d.ox or 0
  for i = 1, math.min(#d.dabs, c_nMaxReceiveDabs) do
    if #s.tRemoteDabQueue < c_nMaxRemoteQueueDabs then
      table.insert(s.tRemoteDabQueue, {dab = d.dabs[i], ox = nOxCm})
    end
  end
  PumpRemoteQueue()
  return true
end
