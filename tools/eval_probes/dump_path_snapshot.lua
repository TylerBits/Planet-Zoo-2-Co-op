-- Eval probe: capture the retail path geometry of the last mirror_place path case for offline replay.
-- Run in a game that just ran a path case and is still open:
--   python tools/test_live_game.py --plan mirror_place --case mp_path_own --keep-open
--   python tools/test_live_game.py --eval-file tools/eval_probes/dump_path_snapshot.lua
--   python tools/test_regionsync.py --import-snapshot      (diag.log -> tools/fixtures/retail_path_snapshot.json)
-- Logs one "PZ2SNAP ..." line per item (Bridge.Log turns quotes into ', and one line must fit the 8 KB ring):
--   PZ2SNAP area <name> x0 y0 z0 x1 y1 z1    the case's areas (ref = what the sender sends, probe, mirror)
--   PZ2SNAP hit <raw> <chunk> x0 y0 z0 x1 y1 z1   every path piece hit of the sender's wide query, its chunk
--   PZ2SNAP spatial <nFlags> x0 y0 z0 x1 y1 z1   SpatialDatabase change messages seen during the case
--   PZ2SNAP meta <expref> <flag_path> <nhits> <nspatial>   last line: the counts the importer checks
-- Same engine calls as RegionSync.QueryHits / ChunkOf (selectable ancestor). Numbers only, no game assets.
local Vector3 = require("Vector3")
local Bridge = require("PZ2Coop.Bridge")
local L = rawget(_G, "__PZ2CoopRegionSyncLogic")
local c = rawget(_G, "__PZ2CoopLastMirrorCase")
if L == nil then
  return "PZ2SNAP failed: RegionSync logic module not loaded"
end
if c == nil or c.rRef == nil then
  return "PZ2SNAP failed: no path case in this game session (run mirror_place --case mp_path_own --keep-open first)"
end
local w = api.world.GetWorldAPIs()
local nFlag = w.spatial.Flag_Path
local f = function(n) return string.format("%.3f", n) end
local Box = function(r) return f(r.x0) .. " " .. f(r.y0) .. " " .. f(r.z0) .. " " .. f(r.x1) .. " " .. f(r.y1) .. " " .. f(r.z1) end

for _, t in ipairs({{"ref", c.rRef}, {"probe", c.rProbe}, {"mirror", c.rMirror}}) do
  if t[2] ~= nil then
    Bridge.Log("PZ2SNAP area " .. t[1] .. " " .. Box(t[2]))
  end
end

-- The sender's wide query (QueryPathChunks: Expand(_r, c_nWholeChunkM = 20)), as QueryHits runs it.
local q = L.Expand(c.rRef, 20)
local cx, cz = (q.x0 + q.x1) / 2, (q.z0 + q.z1) / 2
local nRadius = math.sqrt((q.x1 - q.x0) ^ 2 + (q.z1 - q.z0) ^ 2) / 2
local tHits = w.spatial:CylinderQuery(Vector3:new(cx, q.y0 - 2, cz), Vector3:new(cx, q.y1 + 2, cz), nRadius, nFlag, 0, 4000) or {}
local ms = w.editors:CreateMultiSelection()
ms:SetCanSelectPathVolumeChunks(true)
local nHits = 0
for _, nHit in ipairs(tHits) do
  local bOk, vMin, vMax = pcall(function() return w.spatial:GetShapeAABB(nHit) end)
  local tBox = bOk and vMin ~= nil and vMax ~= nil and L.Grow(nil, vMin, vMax) or nil
  local bAnc, nChunk = pcall(function() return ms:GetSelectableAncestor(nHit) end)
  if tBox ~= nil then
    nHits = nHits + 1
    Bridge.Log("PZ2SNAP hit " .. tostring(nHit) .. " " .. tostring(bAnc and nChunk or "nil") .. " " .. Box(tBox))
  end
end

local nSpatial = 0
for _, t in ipairs(c.tSpatial or {}) do
  if type(t.a) == "table" and #t.a == 6 then
    nSpatial = nSpatial + 1
    Bridge.Log("PZ2SNAP spatial " .. tostring(t.f) .. " " .. table.concat({f(t.a[1]), f(t.a[2]), f(t.a[3]), f(t.a[4]), f(t.a[5]), f(t.a[6])}, " "))
  end
end
Bridge.Log("PZ2SNAP meta " .. tostring(c.nExpRef) .. " " .. tostring(nFlag) .. " " .. nHits .. " " .. nSpatial)
Bridge.Flush(true)
return "PZ2SNAP case=" .. tostring(c.sName) .. " hits=" .. nHits .. " spatial=" .. nSpatial .. " expref=" .. tostring(c.nExpRef)
