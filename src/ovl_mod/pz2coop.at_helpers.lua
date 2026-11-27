-- Shared helpers for modular PZ2Coop autotest plans (pz2coop.at_*.lua).
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
local setmetatable = global.setmetatable
local require = global.require

local H = module(...)

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

H.SampleBoneRange = SampleBoneRange
H.RangeSpan = RangeSpan
H.RaycastGroundY = RaycastGroundY
H.CountFenceInBox = CountFenceInBox
H.Arr = Arr
H.MakePost = MakePost
H.MakePanel = MakePanel

