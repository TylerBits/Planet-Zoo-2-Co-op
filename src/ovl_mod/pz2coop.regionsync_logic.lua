-- Pure region-sync logic (box math, packet field checks, which path chunks an area sends or replaces), split
-- out of pz2coop.regionsync.lua so it can be unit tested offline and hot swapped into a running game.
-- Rules (enforced by tools/test_live_game.py --hot-logic): no api.* calls, no message receivers, no undo
-- wrappers, no require, no state. Every function takes explicit arguments and returns values.
-- The functions live in one shared table in _G that RegionSync calls through on every use, so re-running this
-- file (a dev hot swap through the autotest eval bridge) replaces them in place: no second copy, no stale hooks.
local global = _G
local math = global.math
local string = global.string
local table = global.table
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local type = global.type
local rawget = global.rawget
local rawset = global.rawset

local Logic = rawget(global, "__PZ2CoopRegionSyncLogic")
if Logic == nil then
  Logic = {}
  rawset(global, "__PZ2CoopRegionSyncLogic", Logic)
end
-- Loaded by require (game or offline harness): register the module name the vanilla way.
local sModuleName = ...
if sModuleName ~= nil and rawget(global, "module") ~= nil then
  global.module(sModuleName)
end

Logic.c_nMaxRegionM = 400 -- larger "changes" are park-wide refreshes, not edits
Logic.c_nInsideTolM = 1.0 -- receiver: chunks may reach this far past the area and still count as inside

Logic.Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

Logic.HasFlag = function(_nFlags, _nBit)
  local bOk, bHas = pcall(function()
    return (math.tointeger(_nFlags) & math.tointeger(_nBit)) ~= 0
  end)
  return bOk and bHas
end

Logic.Vec3 = function(_v)
  local bOk, x, y, z = pcall(function()
    return _v:GetX(), _v:GetY(), _v:GetZ()
  end)
  if bOk and type(x) == "number" and type(y) == "number" and type(z) == "number" then
    return x, y, z
  end
  return nil
end

-- ---- boxes (metres) --------------------------------------------------------------------------------------
Logic.Grow = function(_t, _vMin, _vMax)
  local x0, y0, z0 = Logic.Vec3(_vMin)
  local x1, y1, z1 = Logic.Vec3(_vMax)
  if x0 == nil or x1 == nil then
    return _t
  end
  if x1 - x0 > Logic.c_nMaxRegionM or z1 - z0 > Logic.c_nMaxRegionM then
    return _t
  end
  if _t == nil then
    return {x0 = x0, y0 = y0, z0 = z0, x1 = x1, y1 = y1, z1 = z1}
  end
  _t.x0, _t.y0, _t.z0 = math.min(_t.x0, x0), math.min(_t.y0, y0), math.min(_t.z0, z0)
  _t.x1, _t.y1, _t.z1 = math.max(_t.x1, x1), math.max(_t.y1, y1), math.max(_t.z1, z1)
  return _t
end

Logic.BoxUnion = function(_a, _b)
  if _a == nil then
    return _b
  end
  if _b == nil then
    return _a
  end
  return {x0 = math.min(_a.x0, _b.x0), y0 = math.min(_a.y0, _b.y0), z0 = math.min(_a.z0, _b.z0),
    x1 = math.max(_a.x1, _b.x1), y1 = math.max(_a.y1, _b.y1), z1 = math.max(_a.z1, _b.z1)}
end

Logic.Expand = function(_r, _n)
  return {x0 = _r.x0 - _n, y0 = _r.y0 - _n, z0 = _r.z0 - _n, x1 = _r.x1 + _n, y1 = _r.y1 + _n, z1 = _r.z1 + _n}
end

Logic.ExpandY = function(_r, _nExtraY)
  return {x0 = _r.x0, y0 = _r.y0 - _nExtraY, z0 = _r.z0, x1 = _r.x1, y1 = _r.y1 + _nExtraY, z1 = _r.z1}
end

Logic.Shift = function(_r, _nDx)
  return {x0 = _r.x0 + _nDx, y0 = _r.y0, z0 = _r.z0, x1 = _r.x1 + _nDx, y1 = _r.y1, z1 = _r.z1}
end

Logic.RegionText = function(_r)
  return string.format("(%.1f,%.1f,%.1f)-(%.1f,%.1f,%.1f)", _r.x0, _r.y0, _r.z0, _r.x1, _r.y1, _r.z1)
end

Logic.Overlaps = function(_a, _b)
  return _a.x0 <= _b.x1 and _a.x1 >= _b.x0 and _a.y0 <= _b.y1 and _a.y1 >= _b.y0 and _a.z0 <= _b.z1 and _a.z1 >= _b.z0
end

-- XZ only: _a lies inside _b.
Logic.Inside = function(_a, _b)
  return _a.x0 >= _b.x0 and _a.x1 <= _b.x1 and _a.z0 >= _b.z0 and _a.z1 <= _b.z1
end

Logic.Centre = function(_t)
  return {x = Logic.Cm((_t.x0 + _t.x1) / 2), y = Logic.Cm((_t.y0 + _t.y1) / 2), z = Logic.Cm((_t.z0 + _t.z1) / 2)}
end

-- ---- packet fields --------------------------------------------------------------------------------------
Logic.RegionFromData = function(_t)
  return {x0 = _t.x0 / 100, y0 = _t.y0 / 100, z0 = _t.z0 / 100, x1 = _t.x1 / 100, y1 = _t.y1 / 100, z1 = _t.z1 / 100}
end

-- wp = 1: the blueprint is placed where it was saved (+ ox, + the kdy height fix), not re-targeted to cx/cy/cz.
Logic.TargetOf = function(_tData)
  return {x = _tData.cx + (_tData.ox or 0), y = _tData.cy, z = _tData.cz, by0 = _tData.by0,
    bKeep = _tData.wp == 1, ox = _tData.ox or 0, dy = _tData.kdy or 0}
end

Logic.HabitatTypeFor = function(_sBoundaryType)
  local sType = string.lower(global.tostring(_sBoundaryType))
  if string.find(sType, "acrylic", 1, true) then
    return "Aquarium"
  end
  return "Standard"
end

Logic.IsFiniteNum = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

Logic.IsSafeBoundaryType = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_]+$") ~= nil
end

Logic.NormDir = function(_x, _y, _z)
  local len = math.sqrt(_x * _x + _y * _y + _z * _z)
  if len > 1e-5 then
    return _x / len, _y / len, _z / len
  end
  return 0, 0, 1
end

-- ---- path chunks ----------------------------------------------------------------------------------------
-- Which path chunks an area query selects. In: _r the queried area, _rInside the receiver's area (nil on the
-- sender), _tOrder the chunks whose pieces overlap _r (in hit order), _tBoxByChunk chunk -> box of those
-- pieces (false = unknown), _tWholeByChunk chunk -> box of ALL its pieces seen by the wider query,
-- _fnShapeBox(chunk) -> the chunk entity's own box (fallback). _tOrder and _tBoxByChunk are extended in place.
-- Returns: chunks to select (in order), chunks added because they lie inside the grown area (sender),
-- own chunks kept because they reach outside the area (receiver).
Logic.PlanPathChunks = function(_r, _rInside, _tOrder, _tBoxByChunk, _tWholeByChunk, _fnShapeBox)
  local nAdded = 0
  if _rInside == nil then
    -- Sender: also send every chunk lying inside the grown area, until no more fit. The receiver replaces all
    -- its chunks inside that area; one the sender left out (it did not touch the change box) was deleted
    -- there and never came back: the gaps in a freshly drawn loop (play test 2026-11-27 14:56).
    local rArea = _r
    for _, nChunk in ipairs(_tOrder) do
      rArea = Logic.BoxUnion(rArea, _tWholeByChunk[nChunk] or _tBoxByChunk[nChunk] or nil)
    end
    local bGrew, nPass = true, 0
    while bGrew and nPass < 5 do
      bGrew, nPass = false, nPass + 1
      local rFit = Logic.Expand(rArea, Logic.c_nInsideTolM)
      for nChunk, tWhole in pairs(_tWholeByChunk) do
        if _tBoxByChunk[nChunk] == nil and Logic.Inside(tWhole, rFit) then
          table.insert(_tOrder, nChunk)
          _tBoxByChunk[nChunk] = tWhole
          rArea = Logic.BoxUnion(rArea, tWhole)
          nAdded, bGrew = nAdded + 1, true
        end
      end
    end
  end
  -- Receiver: skip chunks reaching more than c_nInsideTolM outside its area. Deleting a whole chunk that
  -- sticks out removes path the sender never re-sent (the "disconnected path" after a delete).
  local rTol = _rInside and Logic.Expand(_rInside, Logic.c_nInsideTolM) or nil
  local tSelect, nKept = {}, 0
  for _, nChunk in ipairs(_tOrder) do
    local tWhole = _tWholeByChunk[nChunk] or _fnShapeBox(nChunk)
    if rTol ~= nil and tWhole ~= nil and not Logic.Inside(tWhole, rTol) then
      nKept = nKept + 1
    else
      table.insert(tSelect, nChunk)
    end
  end
  return tSelect, nAdded, nKept
end

return Logic
