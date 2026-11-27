-- Area ("region") sync for paths and fences: whatever changed inside an area is sent as the new content of
-- that area, and the receiver replaces its own content there. Built only from vanilla recipes:
--   detect:  MsgType_SpatialVolumeChangedMessage, sType "SpatialDatabase": nFlags uses the spatial.Flag_* bits
--            (verified in retail: Flag_Path = 1, Flag_HabitatBoundary = 524288) plus the changed AABB. The region
--            is flushed once the edit settled and no further change arrived for c_nQuiet seconds.
--   query:   spatial:CylinderQuery (as the demolish brush, editors.demolish.demolisheditmode.lua:886-960).
--   paths:   a path hit is a render piece; its chunk is found with multiSelection:GetSelectableAncestor (the
--            click-select path, helpers.multiselecthelper.lua:485) or a parent with a volume ID. Chunks are
--            saved with saveSelection:AddEntityID (blueprint saver), deleted with
--            SceneryUtils.StartDeletePathVolumeChunks + composite:Destroy (demolish) and placed as a blueprint.
--   fences:  a fence belongs to a habitat record even while open (habitatAPI:IsHabitatBoundaryComplete). The
--            touched habitats are saved as a blueprint holding the habitat entity, roof and boundary props -
--            what BlueprintSaveHelper.AddHabitatToSaveSelection adds, minus the contents (synced separately).
--            The receiver deletes its fences there (demolish recipe: DeleteMultiSelection) and places the
--            blueprint. OPEN fences have no habitat record (retail 2026-11-12 10:31), so they are sent as their
--            posts/panels (only the fields the fence tool fills for a brand-new piece) and rebuilt INSIDE the
--            active editor (editMode:RequestUndoOperation, as info popups edit): building them in our own change
--            list hung the game twice (10:12, 10:20), exactly like single parts crashed outside the editor.
--   apply:   change lists prepared like SingleFeatureUndoablePlacementModeBase.PreviewAddNew; a placed blueprint
--            is shifted after preview so its new pieces sit on the sender's content centre.
-- Packet 0x22 (ACTION_PATH_STAMP, JSON + optional blueprint): {k = "path"|"fence", x0..z1 = area (cm),
--   n = chunks / habitats now there (0 = area emptied), cx,cy,cz = content AABB centre (cm)}.
--   wp = 1: place the blueprint where it was saved (receivers without it re-target to cx/cy/cz).
-- ox (cm, solo loopback only): the receiver shifts everything this far along x.
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
local next = global.next
local select = global.select
local coroutine = global.coroutine
local setmetatable = global.setmetatable
local require = global.require
local Vector3 = require("Vector3")
local TransformQ = require("TransformQ")
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local RegionSync = module(...)

local c_nRegionPacket = 0x22
local c_nMarginM = 0.5 -- added around a changed AABB before querying
local c_nQuiet = 0.4 -- seconds without new changes before a settled region is sent
local c_nQuietUnsettled = 1.5 -- tools that commit through a cached undo API never "settle": wait longer
local c_nIgnoreAfterApply = 1.5 -- changes caused by applying a remote region are not sent back
local c_nStartupIgnore = 5.0 -- the park load reports every path/fence once
local c_nMaxRegionM = 400 -- larger "changes" are park-wide refreshes, not edits
local c_nMaxEntities = 4000
local c_nParentDepth = 4
local c_nDriftToleranceCm = 2
local c_nLogLimit = 400
-- Receiving fences is ON: the 2026-11-12 freezes were caused by Unpack() adding loopback ox (+50 m) to unit
-- direction vectors (vDir / vDirStart / vDirEnd) and missing vanilla boundary volume/LakesInLimbo setup.
local c_bApplyFences = global.rawget(global, "PZ2COOP_TEST_FENCES") ~= false
-- Open-fence rebuilds run inside the open fence tool (live), not after it closes. Untested live: kill switch.
local c_bLiveFences = global.rawget(global, "PZ2COOP_LIVE_FENCES") ~= false

local s = {
  bInstalled = false,
  tFlags = {}, -- kind -> spatial flag bit
  tAcc = {}, -- kind -> {x0,y0,z0,x1,y1,z1} metres, accumulated since the last flush
  nLastChange = -1,
  bSettled = false,
  nClock = 0,
  nStartedAt = 0,
  tIgnore = {}, -- {r = area (m), nUntil}: changes there come from a remote apply, not the player
  bSending = false,
  fnReceiver = nil,
  fnHabReceiver = nil,
  fnGateReceiver = nil,
  tKnownHabitats = {},
  nLogs = 0,
  tSeenFlags = {}, -- nFlags value -> count, for the diagnostic line
  tAllFlags = {}, -- every small change since the last settle: nFlags -> count (detection fallback log)
  nMissLogs = 0,
  nIgnoreFenceUntil = -1, -- an open-fence rebuild runs inside the editor, outside the apply guard
}

local Log = function(_s)
  if s.nLogs < c_nLogLimit then
    s.nLogs = s.nLogs + 1
    Bridge.Log("region sync: " .. _s)
  end
end

local Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

local HasFlag = function(_nFlags, _nBit)
  local bOk, bHas = pcall(function()
    return (math.tointeger(_nFlags) & math.tointeger(_nBit)) ~= 0
  end)
  return bOk and bHas
end

local Vec3 = function(_v)
  local bOk, x, y, z = pcall(function()
    return _v:GetX(), _v:GetY(), _v:GetZ()
  end)
  if bOk and type(x) == "number" and type(y) == "number" and type(z) == "number" then
    return x, y, z
  end
  return nil
end

-- ---- boxes (metres) --------------------------------------------------------------------------------------
local Grow = function(_t, _vMin, _vMax)
  local x0, y0, z0 = Vec3(_vMin)
  local x1, y1, z1 = Vec3(_vMax)
  if x0 == nil or x1 == nil then
    return _t
  end
  if x1 - x0 > c_nMaxRegionM or z1 - z0 > c_nMaxRegionM then
    return _t
  end
  if _t == nil then
    return {x0 = x0, y0 = y0, z0 = z0, x1 = x1, y1 = y1, z1 = z1}
  end
  _t.x0, _t.y0, _t.z0 = math.min(_t.x0, x0), math.min(_t.y0, y0), math.min(_t.z0, z0)
  _t.x1, _t.y1, _t.z1 = math.max(_t.x1, x1), math.max(_t.y1, y1), math.max(_t.z1, z1)
  return _t
end

local BoxUnion = function(_a, _b)
  if _a == nil then
    return _b
  end
  if _b == nil then
    return _a
  end
  return {x0 = math.min(_a.x0, _b.x0), y0 = math.min(_a.y0, _b.y0), z0 = math.min(_a.z0, _b.z0),
    x1 = math.max(_a.x1, _b.x1), y1 = math.max(_a.y1, _b.y1), z1 = math.max(_a.z1, _b.z1)}
end

local Expand = function(_r, _n)
  return {x0 = _r.x0 - _n, y0 = _r.y0 - _n, z0 = _r.z0 - _n, x1 = _r.x1 + _n, y1 = _r.y1 + _n, z1 = _r.z1 + _n}
end

local Shift = function(_r, _nDx)
  return {x0 = _r.x0 + _nDx, y0 = _r.y0, z0 = _r.z0, x1 = _r.x1 + _nDx, y1 = _r.y1, z1 = _r.z1}
end

local RegionText = function(_r)
  return string.format("(%.1f,%.1f,%.1f)-(%.1f,%.1f,%.1f)", _r.x0, _r.y0, _r.z0, _r.x1, _r.y1, _r.z1)
end

local ShapeBox = function(_nEntity)
  if _nEntity == nil then
    return nil
  end
  local bOk, vMin, vMax = pcall(function()
    return api.world.GetWorldAPIs().spatial:GetShapeAABB(_nEntity)
  end)
  if not bOk or vMin == nil or vMax == nil then
    return nil
  end
  return Grow(nil, vMin, vMax)
end

local Overlaps = function(_a, _b)
  return _a.x0 <= _b.x1 and _a.x1 >= _b.x0 and _a.y0 <= _b.y1 and _a.y1 >= _b.y0 and _a.z0 <= _b.z1 and _a.z1 >= _b.z0
end

local Centre = function(_t)
  return {x = Cm((_t.x0 + _t.x1) / 2), y = Cm((_t.y0 + _t.y1) / 2), z = Cm((_t.z0 + _t.z1) / 2)}
end

-- Echo suppression by area: only changes overlapping a just-applied remote area are dropped, so the player's
-- own next stroke elsewhere is still sent (a global 1.5 s window lost half a path circle, diag.log 2026-11-27).
local c_nIgnoreMarginM = 5 -- the engine re-joins neighbouring chunks a little past the applied area
local IgnoreArea = function(_r)
  table.insert(s.tIgnore, {r = Expand(_r, c_nIgnoreMarginM), nUntil = s.nClock + c_nIgnoreAfterApply})
end

local IsIgnored = function(_tBox)
  if _tBox == nil then
    return false
  end
  for i = #s.tIgnore, 1, -1 do
    local t = s.tIgnore[i]
    if s.nClock >= t.nUntil then
      table.remove(s.tIgnore, i)
    elseif Overlaps(_tBox, t.r) then
      return true
    end
  end
  return false
end

-- ---- spatial query ---------------------------------------------------------------------------------------
-- Hits with _nFlag inside the region: each raw hit plus its owner resolved the way the demolish brush does.
local QueryHits = function(_r, _nFlag)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local cx, cz = (_r.x0 + _r.x1) / 2, (_r.z0 + _r.z1) / 2
  local nRadius = math.sqrt((_r.x1 - _r.x0) ^ 2 + (_r.z1 - _r.z0) ^ 2) / 2
  local tHits = tWorldAPIs.spatial:CylinderQuery(Vector3:new(cx, _r.y0 - 2, cz), Vector3:new(cx, _r.y1 + 2, cz),
    nRadius, _nFlag, 0, c_nMaxEntities) or {}
  local pih = tWorldAPIs.PlayerInteractionHandler
  local tPairs = {}
  for _, nHit in ipairs(tHits) do
    -- The cylinder circles the box, so its rim reaches past the box corners (into the solo mirror copy).
    local tHitBox = ShapeBox(nHit)
    if tHitBox == nil or Overlaps(tHitBox, _r) then
      table.insert(tPairs, {nRaw = nHit})
    end
  end
  for _, tPair in ipairs(tPairs) do
    local nHit = tPair.nRaw
    local nOwner = nHit
    pcall(function()
      if pih:HasParentEntityID(nOwner) then
        nOwner = pih:GetParentID(nOwner)
      end
      if not pih:HasPlayerInteractionHandlerComponent(nOwner) then
        nOwner = tWorldAPIs.transform:GetParent(nOwner) or nOwner
      end
    end)
    tPair.nOwner = nOwner
  end
  return tPairs
end

-- ---- paths ----------------------------------------------------------------------------------------------
local VolumeOf = function(_volumes, _nEntity)
  if _nEntity == nil then
    return nil
  end
  local bOk, nVolume = pcall(function()
    return _volumes:GetVolumeIDFromEntityID(_nEntity, false, false)
  end)
  if bOk and nVolume ~= nil then
    return nVolume
  end
  bOk, nVolume = pcall(function()
    return _volumes:GetVolumeIDFromEntityID(_nEntity)
  end)
  return bOk and nVolume or nil
end

-- The path chunk a hit belongs to: the multi-selection's selectable ancestor (click-select), else the first
-- of raw hit / owner / transform parents that has a non-pool volume. Returns entity and how it was found.
local ChunkOf = function(_ms, _volumes, _tPair)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local bOk, nAncestor = pcall(function()
    return _ms:GetSelectableAncestor(_tPair.nRaw)
  end)
  local tCandidates = {}
  if bOk and nAncestor ~= nil then
    table.insert(tCandidates, {nAncestor, "ancestor"})
  end
  table.insert(tCandidates, {_tPair.nRaw, "raw"})
  table.insert(tCandidates, {_tPair.nOwner, "owner"})
  local nParent = _tPair.nRaw
  for i = 1, c_nParentDepth do
    local bParent, nNext = pcall(function()
      return tWorldAPIs.transform:GetParent(nParent)
    end)
    if not bParent or nNext == nil or nNext == nParent then
      break
    end
    nParent = nNext
    table.insert(tCandidates, {nParent, "parent" .. i})
  end
  for _, tCandidate in ipairs(tCandidates) do
    local nVolume = VolumeOf(_volumes, tCandidate[1])
    if nVolume ~= nil then
      local bPool = select(2, pcall(function() return _volumes:IsPool(nVolume) end))
      if bPool ~= true then
        return tCandidate[1], tCandidate[2]
      end
    end
  end
  if bOk and nAncestor ~= nil then
    return nAncestor, "ancestor-novolume"
  end
  return nil, nil, tCandidates
end

-- Path volume chunks in the region, in an editors multi-selection (the container vanilla saves and deletes
-- from), their union box and each chunk's box (from the raw hit, which has the spatial shape).
-- _rInside (receiver only): skip chunks reaching more than c_nInsideTolM outside it. Deleting a whole chunk
-- that sticks out of the area removes path the sender never re-sent (the "disconnected path" after a delete).
local c_nInsideTolM = 1.0
local c_nWholeChunkM = 20 -- shortcut: chunks longer than this past the area edge look smaller; raise if paths still break
local Inside = function(_a, _b)
  return _a.x0 >= _b.x0 and _a.x1 <= _b.x1 and _a.z0 >= _b.z0 and _a.z1 <= _b.z1
end

local QueryPathChunks = function(_r, _rInside)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local volumes = tWorldAPIs.volumes
  -- Look wider, so each chunk's whole extent is known from all its hits, not only those inside.
  local tPairs = QueryHits(Expand(_r, c_nWholeChunkM), s.tFlags.path)
  local ms = tWorldAPIs.editors:CreateMultiSelection()
  ms:SetCanSelectPathVolumeChunks(true)
  local tBoxByChunk = {}
  local tWholeByChunk = {}
  local tOrder = {}
  local tHow = {}
  local tMiss = nil
  local nOutside = 0
  for _, tPair in ipairs(tPairs) do
    local nChunk, sHow, tTried = ChunkOf(ms, volumes, tPair)
    if nChunk ~= nil then
      local tBox = ShapeBox(tPair.nRaw) or ShapeBox(nChunk)
      if tBox ~= nil then
        tWholeByChunk[nChunk] = BoxUnion(tWholeByChunk[nChunk], tBox)
      end
      if tBox == nil or Overlaps(tBox, _r) then
        tHow[sHow] = (tHow[sHow] or 0) + 1
        if tBoxByChunk[nChunk] == nil then
          table.insert(tOrder, nChunk)
          tBoxByChunk[nChunk] = tBox or false
        else
          tBoxByChunk[nChunk] = BoxUnion(tBoxByChunk[nChunk] or nil, tBox) or false
        end
      else
        nOutside = nOutside + 1
      end
    elseif tMiss == nil then
      tMiss = tTried
    end
  end
  if _rInside == nil then
    -- Sender: also send every chunk lying inside the grown area, until no more fit. The receiver replaces all
    -- its chunks inside that area; one the sender left out (it did not touch the change box) was deleted
    -- there and never came back: the gaps in a freshly drawn loop (play test 2026-11-27 14:56).
    local rArea = _r
    for _, nChunk in ipairs(tOrder) do
      rArea = BoxUnion(rArea, tWholeByChunk[nChunk] or tBoxByChunk[nChunk] or nil)
    end
    local nAdded, bGrew, nPass = 0, true, 0
    while bGrew and nPass < 5 do
      bGrew, nPass = false, nPass + 1
      local rFit = Expand(rArea, c_nInsideTolM)
      for nChunk, tWhole in pairs(tWholeByChunk) do
        if tBoxByChunk[nChunk] == nil and Inside(tWhole, rFit) then
          table.insert(tOrder, nChunk)
          tBoxByChunk[nChunk] = tWhole
          rArea = BoxUnion(rArea, tWhole)
          nAdded, bGrew = nAdded + 1, true
        end
      end
    end
    if nAdded > 0 then
      Log("path query: added " .. nAdded .. " chunk(s) lying inside the area")
    end
  end
  local rTol = _rInside and Expand(_rInside, c_nInsideTolM) or nil
  local nKept = 0
  for _, nChunk in ipairs(tOrder) do
    local tWhole = tWholeByChunk[nChunk] or ShapeBox(nChunk)
    if rTol ~= nil and tWhole ~= nil and not Inside(tWhole, rTol) then
      nKept = nKept + 1
    else
      pcall(function() ms:AddEntity(nChunk) end)
    end
  end
  if nKept > 0 then
    Log("path query: kept " .. nKept .. " own chunk(s) reaching outside the area")
  end
  local tChunks, tBox = {}, nil
  local nCount = ms:CountCategory(ms.SelectionCategory_PathVolumeChunks) or 0
  for i = 1, nCount do
    local nChunk = ms:GetPathVolumeChunkEntity(i)
    table.insert(tChunks, nChunk)
    -- Piece boxes (raw hits) first: the chunk entity's own box reaches ~83 cm below the pieces, and a by0
    -- taken from it seated every mirrored path 83 cm low (autotest mirror_place, 2026-11-27).
    local tChunkBox = tWholeByChunk[nChunk] or tBoxByChunk[nChunk] or ShapeBox(nChunk) or nil
    tBoxByChunk[nChunk] = tChunkBox or false
    tBox = BoxUnion(tBox, tChunkBox or nil)
  end
  local tHowText = {}
  for sHow, n in pairs(tHow) do
    table.insert(tHowText, sHow .. "=" .. n)
  end
  Log(string.format("path query %s: hits=%d found{%s} outside=%d selected=%d", RegionText(_r), #tPairs,
    table.concat(tHowText, " "), nOutside, nCount))
  if nCount == 0 and tMiss ~= nil then
    local tText = {}
    for _, tCandidate in ipairs(tMiss) do
      table.insert(tText, tCandidate[2] .. "=" .. tostring(tCandidate[1]))
    end
    Log("  first unmatched path hit, tried: " .. table.concat(tText, " ") .. " (none has a volume)")
  end
  return ms, tChunks, tBox, tBoxByChunk
end

-- ---- fences ---------------------------------------------------------------------------------------------
local EntityOf = function(_o)
  local bOk, nEntity = pcall(function()
    return _o:GetAllData().nEntityID
  end)
  if bOk and nEntity ~= nil then
    return nEntity
  end
  bOk, nEntity = pcall(function()
    return _o:EntityID()
  end)
  return bOk and nEntity or nil
end

-- Fence pieces (posts, panels, props, pillars, roofs) hit in the region, plus the habitats they belong to.
local QueryFencePieces = function(_r)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local api_hb = tWorldAPIs.habitatboundary
  local tPairs = QueryHits(_r, s.tFlags.fence)
  local tPosts, tPanels, tProps, tPillars, tRoofs, tHabitats, tSeen = {}, {}, {}, {}, {}, {}, {}
  for _, tPair in ipairs(tPairs) do
    for _, nEntity in ipairs({tPair.nOwner, tPair.nRaw}) do
      if nEntity ~= nil and not tSeen[nEntity] then
        tSeen[nEntity] = true
        local bOk, bHit, oPanel, oPost, oProp, oPillar, nRoof = pcall(function()
          return api_hb:GetBoundaryObjectFromEntity(nEntity)
        end)
        if bOk and bHit then
          if oPost ~= nil then
            tPosts[EntityOf(oPost) or tostring(oPost)] = oPost
          end
          if oPanel ~= nil then
            tPanels[EntityOf(oPanel) or tostring(oPanel)] = oPanel
            pcall(function()
              local oAttached = oPanel:GetAllData().oAttachedProp
              if oAttached ~= nil then
                tProps[EntityOf(oAttached) or tostring(oAttached)] = oAttached
              end
            end)
          end
          if oProp ~= nil then
            tProps[EntityOf(oProp) or tostring(oProp)] = oProp
          end
          if oPillar ~= nil then
            tPillars[EntityOf(oPillar) or tostring(oPillar)] = oPillar
          end
          if nRoof ~= nil then
            tRoofs[nRoof] = true
          end
          local oAny = oPanel or oPost or oProp or oPillar or nRoof
          if oAny ~= nil then
            pcall(function()
              for nHabitatID in pairs(api_hb:GetHabitatsFromBoundaryObject(oAny) or {}) do
                tHabitats[nHabitatID] = true
              end
            end)
          end
        end
      end
    end
  end
  return tPosts, tPanels, tHabitats, #tPairs, tProps, tPillars, tRoofs
end

local BuildBoundarySelection = function(_tPosts, _tPanels, _tProps, _tPillars, _tRoofs)
  local HabitatBoundaryEditMode = require("Editors.HabitatBoundary.HabitatBoundaryEditMode")
  local selection = HabitatBoundaryEditMode.NewBoundarySelection()
  local nCount = 0
  for _, o in pairs(_tPosts or {}) do
    selection.tControlPosts[o] = true
    nCount = nCount + 1
  end
  for _, o in pairs(_tPanels or {}) do
    selection.tPanels[o] = true
    nCount = nCount + 1
    pcall(function()
      local oAttached = o:GetAllData().oAttachedProp
      if oAttached ~= nil and not selection.tAttachableProps[oAttached] then
        selection.tAttachableProps[oAttached] = true
        nCount = nCount + 1
      end
    end)
  end
  for _, o in pairs(_tProps or {}) do
    if not selection.tAttachableProps[o] then
      selection.tAttachableProps[o] = true
      nCount = nCount + 1
    end
  end
  for _, o in pairs(_tPillars or {}) do
    selection.tRoofPillars[o] = true
    nCount = nCount + 1
  end
  for nRoof in pairs(_tRoofs or {}) do
    selection.tRoofs[nRoof] = true
    nCount = nCount + 1
  end
  return selection, nCount
end

-- Exact 3D box of a boundary object from GetAllData() (posts/panels have no spatial shape on their root entity
-- in retail, so ShapeBox alone returned nil and collapsed the habitat box to the last gate edit!).
local BoundaryObjectBox = function(_o)
  local tBox = nil
  pcall(function()
    local d = _o:GetAllData()
    if type(d) ~= "table" then
      return
    end
    local AddPt = function(_x, _y, _z)
      if _x == nil then return end
      if tBox == nil then
        tBox = {x0 = _x, y0 = _y, z0 = _z, x1 = _x, y1 = _y, z1 = _z}
      else
        tBox.x0, tBox.y0, tBox.z0 = math.min(tBox.x0, _x), math.min(tBox.y0, _y), math.min(tBox.z0, _z)
        tBox.x1, tBox.y1, tBox.z1 = math.max(tBox.x1, _x), math.max(tBox.y1, _y), math.max(tBox.z1, _z)
      end
    end
    local px, py, pz = Vec3(d.vPos)
    if px ~= nil then
      AddPt(px, py, pz)
      if type(d.nWorldHeight) == "number" then
        AddPt(px, d.nWorldHeight, pz)
      end
    end
    local sx, sy, sz = Vec3(d.vBasePosStart)
    if sx ~= nil then
      AddPt(sx, sy, sz)
      if type(d.nWorldHeightStart) == "number" then
        AddPt(sx, d.nWorldHeightStart, sz)
      end
    end
    local ex, ey, ez = Vec3(d.vBasePosEnd)
    if ex ~= nil then
      AddPt(ex, ey, ez)
      if type(d.nWorldHeightEnd) == "number" then
        AddPt(ex, d.nWorldHeightEnd, ez)
      end
    end
    local bx, by, bz = Vec3(d.vBasePos)
    if bx ~= nil then
      AddPt(bx, by, bz)
    end
  end)
  return BoxUnion(tBox, ShapeBox(EntityOf(_o)))
end

-- Box of every boundary object of a habitat (GetBoundaryObjectsForHabitat returns tables keyed by object).
local HabitatBoundaryBox = function(_nHabitatID)
  local tBox = nil
  pcall(function()
    local tObjects = api.world.GetWorldAPIs().habitatboundary:GetBoundaryObjectsForHabitat(_nHabitatID)
    for _, tSet in pairs(tObjects or {}) do
      if type(tSet) == "table" then
        for o in pairs(tSet) do
          tBox = BoxUnion(tBox, BoundaryObjectBox(o))
        end
      end
    end
  end)
  return tBox
end

-- ---- change lists (vanilla recipes) ---------------------------------------------------------------------
local PrepareHierarchy = function(_h)
  local gameterrain = api.world.GetWorldAPIs().gameterrain
  _h:SetPerformTerrainModificationsModifyVolumes(false)
  local op = _h:GetTerrainEditOperation()
  gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true,
    gameterrain.CheckLakesMode_WhenTerrainCollisionEnabled, false)
  gameterrain:SetTerrainEditOpGridRenderingEnabled(op, false)
end

-- Exact vanilla HabitatBoundaryEditMode._CreateChangeListHierarchy + _HandleLakesInLimbo recipe
-- (editors.habitatboundary.habitatboundaryeditmode.lua:2323-2349). Uses CheckLakesMode_Off so aquarium
-- water never blocks replacing glass/acrylic walls on the remote peer.
local PrepareFenceHierarchy = function(_h)
  pcall(function()
    _h:SetBoundaryEditPreviewModeModifyVolumes(true)
  end)
  local gameterrain = api.world.GetWorldAPIs().gameterrain
  _h:SetPerformTerrainModificationsModifyVolumes(false)
  local op = _h:GetTerrainEditOperation()
  gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true,
    gameterrain.CheckLakesMode_Off or 0, false)
  gameterrain:SetTerrainEditOpGridRenderingEnabled(op, false)
end

local HandleLakesInLimbo = function(_h)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local api_hb = tWorldAPIs.habitatboundary
  local gameterrain = tWorldAPIs.gameterrain
  local cl = _h:GetHabitatBoundaryChangeList()
  local bOk, bEnabled = pcall(function()
    return api_hb:IsLakesInLimboEnabled()
  end)
  if not bOk or not bEnabled then
    return
  end
  local bChk, bAlready = pcall(function()
    return cl:IsLakesInLimboEnabled()
  end)
  if bChk and bAlready then
    return
  end
  pcall(function()
    cl:SetLakesInLimboEnabled(true)
    gameterrain:AddHabitatBoundaryLakesInLimboToChangeList(_h)
  end)
end

-- Preview, optional adjust, optional vanilla pre-commit terrain step, commit; nil = undo system taken (the job
-- is re-queued by BuildSync.QueueRemote).
local Yielding_CommitRegion = function(_h, _fnAdjust, _bPlacement, _moveObject)
  local undo = api.undo
  if not BuildSync.IsUndoFree() then
    BuildSync.RequestRetry()
    return nil
  end
  local busyToken, previewToken = undo.PreviewChangeList(_h:GetFullUndoChangeList())
  while not undo.IsOperationComplete(busyToken) do
    coroutine.yield()
  end
  if _fnAdjust ~= nil then
    local bOk, sError = pcall(_fnAdjust)
    if not bOk then
      Log("adjust failed: " .. tostring(sError))
    end
  end
  if _bPlacement then
    BuildSync.VanillaPlacementCommitStep(_h, _moveObject)
  end
  local bCanCommit = undo.CanCommitPreview(previewToken)
  while bCanCommit == nil do
    coroutine.yield()
    bCanCommit = undo.CanCommitPreview(previewToken)
  end
  local waitToken
  if bCanCommit then
    waitToken = undo.CommitPreview(previewToken)
  else
    local bReasons, tReasons = pcall(undo.GetCommitFailReasons, previewToken)
    local tNames = {}
    if bReasons and type(tReasons) == "table" then
      for k, v in pairs(tReasons) do
        if v then
          table.insert(tNames, tostring(k))
        end
      end
    end
    Log("commit refused, reasons: " .. (#tNames > 0 and table.concat(tNames, ",") or "unknown"))
    waitToken = undo.CancelPreview(previewToken)
  end
  while not undo.IsOperationComplete(waitToken) do
    coroutine.yield()
  end
  undo.Checkpoint({sMode = "PZ2Coop"})
  undo.ClearHistory({})
  return bCanCommit
end

local ParkLoadSaveManager = function()
  return api.game.GetEnvironment():RequireInterface("Interfaces.IParkLoadSaveManager")
end

local ExpandY = function(_r, _nExtraY)
  return {x0 = _r.x0, y0 = _r.y0 - _nExtraY, z0 = _r.z0, x1 = _r.x1, y1 = _r.y1 + _nExtraY, z1 = _r.z1}
end

local MoveObjectPos = function(_moveObject)
  local bOk, vPos = pcall(function() return _moveObject:GetPosition() end)
  if bOk and vPos ~= nil then
    local x, y, z = Vec3(vPos)
    if x ~= nil then
      return x, y, z
    end
  end
  local bTr, tr = pcall(function() return _moveObject:GetTransform() end)
  if bTr and tr ~= nil then
    local x, y, z = Vec3(tr:GetPos())
    if x ~= nil then
      return x, y, z
    end
  end
  return nil
end

local MoveObjectBox = function(_moveObject)
  local tBox = nil
  pcall(function()
    if _moveObject.GetControlPoint ~= nil then
      local vBot = _moveObject:GetControlPoint(Vector3:new(0, -1, 0))
      local vTop = _moveObject:GetControlPoint(Vector3:new(0, 1, 0))
      local bx, by, bz = Vec3(vBot)
      local tx, ty, tz = Vec3(vTop)
      if bx ~= nil and tx ~= nil then
        tBox = {
          x0 = math.min(bx, tx), y0 = math.min(by, ty), z0 = math.min(bz, tz),
          x1 = math.max(bx, tx), y1 = math.max(by, ty), z1 = math.max(bz, tz),
        }
      end
    end
  end)
  return tBox
end

local SnapshotHabitatEntities = function()
  local tOld = {}
  pcall(function()
    local fac = api.world.GetWorldAPIs().facilities
    if fac ~= nil and fac.GetAllHabitatsEntityIDs ~= nil then
      for _, nEnt in pairs(fac:GetAllHabitatsEntityIDs() or {}) do
        tOld[nEnt] = true
      end
    end
  end)
  return tOld
end

local MeasureNewHabitatsBox = function(_tOldHabs)
  local tBox = nil
  pcall(function()
    local tWorld = api.world.GetWorldAPIs()
    local fac, hab = tWorld.facilities, tWorld.habitat
    if fac == nil or hab == nil or fac.GetAllHabitatsEntityIDs == nil then
      return
    end
    for _, nEnt in pairs(fac:GetAllHabitatsEntityIDs() or {}) do
      if not _tOldHabs[nEnt] then
        local bOk, nHabID = pcall(hab.GetHabitatIDFromEntityID, hab, nEnt)
        if bOk and nHabID ~= nil then
          tBox = BoxUnion(tBox, HabitatBoundaryBox(nHabID))
        end
      end
    end
  end)
  return tBox
end

local MeasureNewFencePiecesBox = function(_r, _tOldRaw)
  local tBox = nil
  local tPosts, tPanels = QueryFencePieces(ExpandY(_r, 40))
  for key, oPost in pairs(tPosts) do
    local nEnt = EntityOf(oPost)
    if nEnt == nil or not _tOldRaw[nEnt] then
      tBox = BoxUnion(tBox, BoundaryObjectBox(oPost))
    end
  end
  for key, oPanel in pairs(tPanels) do
    local nEnt = EntityOf(oPanel)
    if nEnt == nil or not _tOldRaw[nEnt] then
      tBox = BoxUnion(tBox, BoundaryObjectBox(oPanel))
    end
  end
  return tBox
end

-- Loads a blueprint into _h, aligns its bottom (or OBB centre) to the target so it never starts 4 m
-- underground, and after preview measures the actual placed pieces/habitats to shift to 0 cm drift.
local Yielding_PlaceBlueprint = function(_h, _sFile, _tTargetCm, _r, _nFlag, _tOld, _tOpts)
  local bOk, sError = ParkLoadSaveManager():LoadBlueprintFromFile(_sFile)
  if not bOk then
    Log("blueprint load failed: " .. tostring(sError))
    return nil
  end
  while not _h:IsLoadedBlueprintReadyForEditing() do
    coroutine.yield()
  end
  local moveObject = _h:CreateCompositeObject({})
  _h:AddBlueprintToCompositeObject(moveObject)
  moveObject:SetCompositeOriginToOBBCentre()
  if _tTargetCm.bKeep then
    -- A loaded blueprint sits where the sender saved it (OBB centre = sender's world spot, retail autotest
    -- 2026-11-27). Keeping it is exact; the OBB/control-point re-targeting below landed paths +26/-83/-87 cm
    -- off, and the re-place that fixed it left a flattened trench and stray chunks behind.
    local px, py, pz = MoveObjectPos(moveObject)
    if px == nil then
      Log("blueprint has no position, cannot keep it")
      return nil
    end
    moveObject:SetTransform(TransformQ.Identity:WithPos(Vector3:new(px + (_tTargetCm.ox or 0) / 100,
      py + (_tTargetCm.dy or 0) / 100, pz)), {})
    return function() end, moveObject
  end
  local nTargetX, nTargetY, nTargetZ = _tTargetCm.x / 100, _tTargetCm.y / 100, _tTargetCm.z / 100
  moveObject:SetTransform(TransformQ.Identity:WithPos(Vector3:new(nTargetX, nTargetY, nTargetZ)), {})
  -- Pre-preview vertical alignment: if sender sent exact base Y (by0) and moveObject exposes its bottom
  -- control point, shift before preview so habitat walls/aquariums don't start buried underground.
  if _tTargetCm.by0 ~= nil then
    local tPreBox = MoveObjectBox(moveObject)
    if tPreBox ~= nil then
      local nPreDy = (_tTargetCm.by0 / 100) - tPreBox.y0
      if math.abs(nPreDy) > 0.02 and math.abs(nPreDy) < 50.0 then
        local px, py, pz = MoveObjectPos(moveObject)
        if px ~= nil then
          moveObject:SetTransform(TransformQ.Identity:WithPos(Vector3:new(px, py + nPreDy, pz)), {})
        end
      end
    end
  end
  local fnMeasure = _tOpts and _tOpts.fnMeasure or nil
  -- Second value: the move object, for the vanilla commit-check step (terrain flatten/join).
  return function()
    local tBox = nil
    if fnMeasure ~= nil then
      tBox = fnMeasure(moveObject)
    end
    if tBox == nil then
      for _, tPair in ipairs(QueryHits(ExpandY(_r, 25), _nFlag)) do
        if not _tOld[tPair.nRaw] then
          tBox = BoxUnion(tBox, ShapeBox(tPair.nRaw))
        end
      end
    end
    if tBox == nil then
      tBox = MoveObjectBox(moveObject)
    end
    if tBox == nil then
      Log("drift check skipped (no new pieces visible in preview)")
      return
    end
    local tNow = Centre(tBox)
    local dx = _tTargetCm.x - tNow.x
    local dz = _tTargetCm.z - tNow.z
    local dy
    if _tTargetCm.by0 ~= nil then
      dy = _tTargetCm.by0 - Cm(tBox.y0)
    else
      dy = _tTargetCm.y - tNow.y
    end
    local nOff = math.sqrt(dx * dx + dy * dy + dz * dz)
    if nOff <= c_nDriftToleranceCm then
      Log(string.format("drift %d cm before commit, no correction needed", math.floor(nOff + 0.5)))
      return
    end
    local px, py, pz = MoveObjectPos(moveObject)
    if px ~= nil then
      moveObject:SetTransform(TransformQ.Identity:WithPos(Vector3:new(px + dx / 100, py + dy / 100, pz + dz / 100)), {})
    else
      moveObject:SetTransform(TransformQ.Identity:WithPos(Vector3:new((_tTargetCm.x + dx) / 100,
        (_tTargetCm.y + dy) / 100, (_tTargetCm.z + dz) / 100)), {})
    end
    Log(string.format("drift %d cm (dx=%d dy=%d dz=%d) before commit, corrected",
      math.floor(nOff + 0.5), math.floor(dx + 0.5), math.floor(dy + 0.5), math.floor(dz + 0.5)))
  end, moveObject
end

local RawSet = function(_r, _nFlag)
  local tOld = {}
  for _, tPair in ipairs(QueryHits(_r, _nFlag)) do
    tOld[tPair.nRaw] = true
  end
  return tOld
end

-- ---- outgoing --------------------------------------------------------------------------------------------
local SendFencePieces -- defined with the open-fence helpers below
local RegionFields = function(_t, _r)
  _t.x0, _t.y0, _t.z0 = Cm(_r.x0), Cm(_r.y0), Cm(_r.z0)
  _t.x1, _t.y1, _t.z1 = Cm(_r.x1), Cm(_r.y1), Cm(_r.z1)
  return _t
end

local Yielding_SaveSelection = function(_sPrefix, _fnFill)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local selection = tWorldAPIs.worldserialisation:CreateSaveSelection()
  _fnFill(selection, tWorldAPIs)
  local sFile = BuildSync.NextClipFile(_sPrefix)
  local bOk, sError = ParkLoadSaveManager():SaveBlueprintToFile(Bridge.GetPrefix() .. sFile, selection, true)
  if not bOk then
    Log("blueprint save failed: " .. tostring(sError))
    return nil
  end
  return sFile
end

local Job_SendPath = function(_r)
  BuildSync.Breadcrumb("path region " .. RegionText(_r) .. ": query")
  local _, tChunks, tBox = QueryPathChunks(_r)
  -- The area grows to the whole sent chunks, so the receiver's matching chunks fall inside it.
  local tData = RegionFields({k = "path", n = #tChunks}, BoxUnion(_r, tBox))
  local sFile = nil
  if #tChunks > 0 then
    BuildSync.Breadcrumb("path region: save " .. #tChunks .. " chunks")
    sFile = Yielding_SaveSelection("path_", function(_selection)
      for _, nChunk in ipairs(tChunks) do
        _selection:AddEntityID(nChunk)
      end
    end)
    if sFile == nil or tBox == nil then
      BuildSync.Count("path send failed")
      Log("path not sent (" .. (sFile == nil and "save failed" or "chunks have no box") .. ")")
      return
    end
    local c = Centre(tBox)
    tData.cx, tData.cy, tData.cz = c.x, c.y, c.z
    tData.by0 = Cm(tBox.y0)
    tData.wp = 1
  end
  BuildSync.Count("sent path region")
  BuildSync.JournalRegion("path")
  Log("local path change " .. RegionText(_r) .. ": " .. #tChunks .. " chunks" ..
    (sFile and (", blueprint " .. sFile) or ", area now empty") .. " [tool " .. BuildSync.GetTool() .. "]")
  Bridge.SendPacket(c_nRegionPacket, sFile, tData)
end

-- ---- open fences: pieces ---------------------------------------------------------------------------------
-- Fields HabitatBoundaryEditMode fills for a brand-new post / panel (habitatboundaryeditmode.lua:3212,
-- 4067-4073), minus tFlexiColours, which is added fresh on the receiver.
local c_tPostFields = {"vPos", "vDir", "sBoundaryType", "nWorldHeight"}
local c_tPanelFields = {"vBasePosStart", "vDirStart", "nWorldHeightStart", "vBasePosEnd", "vDirEnd", "nWorldHeightEnd",
  "nPanelMode", "nHeightAngleStart", "nHeightAngleEnd", "nWindowCutDistFromBase", "nWindowCutDistFromTop",
  "nRandomUVLengthOffset", "nBoundaryExtraFlags", "sBoundaryType", "bHabitatWall", "nSmoothness", "nMaxDurability"}

local Arr = function()
  return setmetatable({}, api.json.GetArrayMetatable())
end

-- Whole connected fences: walk posts <-> panels so a fence is always replaced whole.
local CollectConnected = function(_tPosts, _tPanels)
  local api_hb = api.world.GetWorldAPIs().habitatboundary
  local tTodoPosts, tTodoPanels = {}, {}
  for _, o in pairs(_tPosts) do
    table.insert(tTodoPosts, o)
  end
  for _, o in pairs(_tPanels) do
    table.insert(tTodoPanels, o)
  end
  local nGuard = 0
  while (#tTodoPosts > 0 or #tTodoPanels > 0) and nGuard < c_nMaxEntities do
    nGuard = nGuard + 1
    local oPanel = table.remove(tTodoPanels)
    if oPanel ~= nil then
      pcall(function()
        local tData = oPanel:GetAllData()
        for _, oPost in ipairs({tData.oStartControlPost, tData.oEndControlPost}) do
          local key = EntityOf(oPost) or tostring(oPost)
          if _tPosts[key] == nil then
            _tPosts[key] = oPost
            table.insert(tTodoPosts, oPost)
          end
        end
      end)
    end
    local oPost = table.remove(tTodoPosts)
    if oPost ~= nil then
      pcall(function()
        for _, o in pairs(api_hb:GetPanelsConnectedToControlPost(oPost) or {}) do
          local key = EntityOf(o) or tostring(o)
          if _tPanels[key] == nil then
            _tPanels[key] = o
            table.insert(tTodoPanels, o)
          end
        end
      end)
    end
  end
end

local Pack = function(_tAll, _tFields)
  local tOut = {f = {}, v = {}}
  for _, sKey in ipairs(_tFields) do
    local v = _tAll[sKey]
    local x, y, z = Vec3(v)
    if x ~= nil then
      local a = Arr()
      a[1], a[2], a[3] = x, y, z
      tOut.v[sKey] = a
    elseif type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
      tOut.f[sKey] = v
    end
  end
  return tOut
end

SendFencePieces = function(_r, _tPosts, _tPanels)
  CollectConnected(_tPosts, _tPanels)
  local tData = {k = "fence", mode = "pieces", posts = Arr(), panels = Arr()}
  local tIndex, tBox = {}, nil
  for key, oPost in pairs(_tPosts) do
    local bOk, tAll = pcall(function() return oPost:GetAllData() end)
    if bOk and tAll ~= nil then
      table.insert(tData.posts, Pack(tAll, c_tPostFields))
      tIndex[key] = #tData.posts
      tBox = BoxUnion(tBox, BoundaryObjectBox(oPost))
    end
  end
  for _, oPanel in pairs(_tPanels) do
    local bOk, tAll = pcall(function() return oPanel:GetAllData() end)
    if bOk and tAll ~= nil then
      local tPacked = Pack(tAll, c_tPanelFields)
      tPacked.s = tIndex[EntityOf(tAll.oStartControlPost) or tostring(tAll.oStartControlPost)]
      tPacked.e = tIndex[EntityOf(tAll.oEndControlPost) or tostring(tAll.oEndControlPost)]
      if tPacked.s ~= nil and tPacked.e ~= nil then
        table.insert(tData.panels, tPacked)
      end
      tBox = BoxUnion(tBox, BoundaryObjectBox(oPanel))
    end
  end
  local r = BoxUnion(_r, tBox and Expand(tBox, c_nMarginM) or nil)
  RegionFields(tData, r)
  tData.n = #tData.posts + #tData.panels
  BuildSync.Count("sent fence pieces")
  BuildSync.JournalRegion("fence")
  Log("local open fence change " .. RegionText(r) .. ": " .. #tData.posts .. " posts, " .. #tData.panels ..
    " panels (no habitat record) [tool " .. BuildSync.GetTool() .. "]")
  Bridge.SendPacket(c_nRegionPacket, nil, tData)
end

local Job_SendFence = function(_r)
  BuildSync.Breadcrumb("fence region " .. RegionText(_r) .. ": query")
  local tWorldAPIs = api.world.GetWorldAPIs()
  local tPosts, tPanels, tHabitats, nHits = QueryFencePieces(_r)
  local nPieces = 0
  for _ in pairs(tPosts) do
    nPieces = nPieces + 1
  end
  for _ in pairs(tPanels) do
    nPieces = nPieces + 1
  end
  local tHabitatEntities, tBox = {}, nil
  for nHabitatID in pairs(tHabitats) do
    local bOk, nEntity = pcall(function()
      return tWorldAPIs.habitat:GetEntityIDFromHabitatID(nHabitatID)
    end)
    if bOk and nEntity ~= nil then
      table.insert(tHabitatEntities, {nHabitatID = nHabitatID, nEntity = nEntity})
      tBox = BoxUnion(tBox, HabitatBoundaryBox(nHabitatID))
    end
  end
  -- The whole habitat boundary is replaced, so the area grows to cover it.
  local r = BoxUnion(_r, tBox and Expand(tBox, c_nMarginM) or nil)
  local tData = RegionFields({k = "fence", n = #tHabitatEntities}, r)
  local sFile = nil
  if #tHabitatEntities > 0 then
    BuildSync.Breadcrumb("fence region: save " .. #tHabitatEntities .. " habitat boundaries")
    sFile = Yielding_SaveSelection("fence_", function(_selection, _tWorldAPIs)
      for _, tHabitat in ipairs(tHabitatEntities) do
        -- BlueprintSaveHelper.AddHabitatToSaveSelection without the contents
        _selection:AddEntityID(tHabitat.nEntity)
        local bRoof, nRoof = pcall(function()
          return _tWorldAPIs.habitatboundary:GetRoof(tHabitat.nEntity)
        end)
        if bRoof and nRoof ~= nil then
          _selection:AddEntityID(nRoof)
        end
        pcall(function()
          local tObjects = _tWorldAPIs.habitatboundary:GetBoundaryObjectsForHabitat(tHabitat.nHabitatID)
          for oProp in pairs(tObjects.tAttachableProps or {}) do
            _selection:AddEntityID(oProp:EntityID())
          end
        end)
      end
    end)
    if sFile == nil or tBox == nil then
      BuildSync.Count("fence send failed")
      Log("fence not sent (" .. (sFile == nil and "save failed" or "boundary has no box") .. ")")
      return
    end
    local c = Centre(tBox)
    tData.cx, tData.cy, tData.cz = c.x, c.y, c.z
    tData.by0 = Cm(tBox.y0)
  elseif nPieces > 0 then
    return SendFencePieces(_r, tPosts, tPanels)
  end
  BuildSync.Count("sent fence region")
  BuildSync.JournalRegion("fence")
  Log("local fence change " .. RegionText(r) .. ": " .. nPieces .. " pieces, " .. #tHabitatEntities ..
    " habitats (" .. nHits .. " hits)" .. (sFile and (", blueprint " .. sFile) or ", area now empty") ..
    " [tool " .. BuildSync.GetTool() .. "]")
  Bridge.SendPacket(c_nRegionPacket, sFile, tData)
end

-- ---- incoming --------------------------------------------------------------------------------------------
local RegionFromData = function(_t)
  return {x0 = _t.x0 / 100, y0 = _t.y0 / 100, z0 = _t.z0 / 100, x1 = _t.x1 / 100, y1 = _t.y1 / 100, z1 = _t.z1 / 100}
end

-- wp = 1: the blueprint is placed where it was saved (+ ox, + the kdy height fix), not re-targeted to cx/cy/cz.
local TargetOf = function(_tData)
  return {x = _tData.cx + (_tData.ox or 0), y = _tData.cy, z = _tData.cz, by0 = _tData.by0,
    bKeep = _tData.wp == 1, ox = _tData.ox or 0, dy = _tData.kdy or 0}
end

-- Bottom of the path pieces that are new since tOld, minus the sender's bottom (cm); nil if none visible.
local MeasurePathDy = function(_r, _tOld, _nBy0, _sRoute)
  if _nBy0 == nil then
    return nil
  end
  local tNew = nil
  for _, tPair in ipairs(QueryHits(ExpandY(_r, 25), s.tFlags.path)) do
    if not _tOld[tPair.nRaw] then
      tNew = BoxUnion(tNew, ShapeBox(tPair.nRaw))
    end
  end
  if tNew == nil then
    return nil
  end
  local nDy = Cm(tNew.y0) - _nBy0
  s.nLastPathDy = nDy
  Log(string.format("MEASURE path route=%s bottom=%d sender=%d dy=%d", _sRoute, Cm(tNew.y0), _nBy0, nDy))
  return nDy
end

local Job_ApplyPath

-- The preview drift check cannot see where path pieces really land: it read 0 cm while the commit put them
-- a fixed, blueprint-specific offset off (+26 / -83 cm, autotest mirror_place 2026-11-27). So measure after
-- the commit and re-place once with the target shifted by that offset; it is constant, so one pass lands it.
local CorrectPathHeight = function(_sFile, _tData, _nDy)
  if _nDy == nil or math.abs(_nDy) <= c_nDriftToleranceCm or _tData.bReseat or _tData.by0 == nil then
    return
  end
  local tAgain = setmetatable({bReseat = true, nTargetBy0 = _tData.by0, by0 = _tData.by0 - _nDy, cy = (_tData.cy or 0) - _nDy,
    kdy = (_tData.kdy or 0) - _nDy},
    {__index = _tData})
  Log("path landed " .. _nDy .. " cm off its target: re-placing once with the offset corrected")
  BuildSync.QueueRemote(function() Job_ApplyPath(_sFile, tAgain) end, _sFile ~= nil, true)
end

Job_ApplyPath = function(_sFile, _tData)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local r = Shift(RegionFromData(_tData), (_tData.ox or 0) / 100)
  BuildSync.Breadcrumb("apply path region " .. RegionText(r) .. ": query own chunks")
  local ms, tOldChunks = QueryPathChunks(r, r)
  local tOld = RawSet(r, s.tFlags.path)
  -- PZ2COOP_FORCE_EDITOR (autotest only): take the editor route with the tool open but no live preview.
  local bForce = global.rawget(global, "PZ2COOP_FORCE_EDITOR") == true and not _tData.bReseat
  if not BuildSync.IsUndoFree() or bForce then
    -- The path tool holds a preview while open: hand the change to the active editor (the route remote
    -- buildings use) so the friend's path shows now, not after the player closes the tool.
    local tTarget = type(_tData.cx) == "number" and TargetOf(_tData) or nil
    local tNote = {x = Cm((r.x0 + r.x1) / 2), y = Cm((r.y0 + r.y1) / 2), z = Cm((r.z0 + r.z1) / 2)}
    local bDone = BuildSync.Yielding_ModeOperation("path region", tNote, function(clh)
      PrepareHierarchy(clh)
      -- Load first: a failed load must not leave the old chunks deleted.
      if _sFile ~= nil and (_tData.n or 0) > 0 and tTarget ~= nil then
        local fnAdjust, moveObject = Yielding_PlaceBlueprint(clh, _sFile, tTarget, r, s.tFlags.path, tOld)
        if fnAdjust == nil then
          return
        end
        BuildSync.VanillaPlacementCommitStep(clh, moveObject)
      end
      if #tOldChunks > 0 then
        local SceneryUtils = require("Editors.Scenery.Utils.SceneryUtils")
        local composite = clh:CreateCompositeObject({})
        SceneryUtils.StartDeletePathVolumeChunks(clh, composite, ms, tWorldAPIs)
        composite:Destroy()
      end
    end)
    if bDone == nil then
      BuildSync.RequestRetry()
      return
    end
    IgnoreArea(r)
    -- This route has no drift check: measure, and (variant d) re-seat through our own change list once the
    -- player's tool frees the undo system.
    local nDy = bDone and MeasurePathDy(r, tOld, _tData.nTargetBy0 or (tTarget and tTarget.by0), _tData.bReseat and "corrected-editor" or "editor") or nil
    CorrectPathHeight(_sFile, _tData, nDy)
    BuildSync.Count(bDone and "applied path region" or "apply failed")
    Log("remote path region " .. RegionText(r) .. (bDone and " applied in the open editor" or " rejected by the editor") ..
      ": removed " .. #tOldChunks .. ", placed " .. tostring(_tData.n or 0) .. " chunks")
    return
  end
  local h = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
  PrepareHierarchy(h)
  if #tOldChunks > 0 then
    BuildSync.Breadcrumb("apply path region: remove " .. #tOldChunks .. " own chunks")
    local SceneryUtils = require("Editors.Scenery.Utils.SceneryUtils")
    local composite = h:CreateCompositeObject({})
    SceneryUtils.StartDeletePathVolumeChunks(h, composite, ms, tWorldAPIs)
    composite:Destroy()
  end
  local fnAdjust, moveObject = nil, nil
  if _sFile ~= nil and (_tData.n or 0) > 0 then
    BuildSync.Breadcrumb("apply path region: load and place " .. tostring(_sFile))
    fnAdjust, moveObject = Yielding_PlaceBlueprint(h, _sFile, TargetOf(_tData), r, s.tFlags.path, tOld)
    if fnAdjust == nil then
      BuildSync.Count("apply failed")
      return
    end
  end
  BuildSync.Breadcrumb("apply path region: preview, commit")
  local bCommitted = Yielding_CommitRegion(h, fnAdjust, true, moveObject)
  if bCommitted == nil then
    return
  end
  IgnoreArea(r)
  if bCommitted and type(_tData.cx) == "number" then
    CorrectPathHeight(_sFile, _tData, MeasurePathDy(r, tOld, _tData.nTargetBy0 or _tData.by0, _tData.bReseat and "corrected" or "own"))
  end
  BuildSync.Count(bCommitted and "applied path region" or "apply failed")
  Log("remote path region " .. RegionText(r) .. (bCommitted and " applied" or " rejected") .. ": removed " ..
    #tOldChunks .. ", placed " .. tostring(_tData.n or 0) .. " chunks")
end

-- Replaces fences in the area: when a habitat-boundary blueprint is attached, puts BOTH the demolish of old
-- fences AND the new blueprint placement in ONE atomic change list when possible (or safely falls back to
-- two-step with rollback protection) so a refused glass/aquarium wall edit NEVER deletes the player's walls!
local Job_ApplyFence = function(_sFile, _tData)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local api_hb = tWorldAPIs.habitatboundary
  local r = Shift(RegionFromData(_tData), (_tData.ox or 0) / 100)
  local bHasBlueprint = _sFile ~= nil and (_tData.n or 0) > 0
  BuildSync.Breadcrumb("apply fence region " .. RegionText(r) .. ": query own fences")
  local tPosts, tPanels, _, _, tProps, tPillars, tRoofs = QueryFencePieces(ExpandY(r, 12))
  CollectConnected(tPosts, tPanels)
  local selection, nOld = BuildBoundarySelection(tPosts, tPanels, tProps, tPillars, tRoofs)
  local tOldHabs = SnapshotHabitatEntities()
  local tOldRaw = RawSet(ExpandY(r, 40), s.tFlags.fence)

  -- Snapshot old fences to a local backup file before any two-step demolish so we can restore them if
  -- the incoming blueprint is rejected (e.g. changing wall type to glass near water/scenery).
  local sBackupFile = nil
  local tBackupTarget = nil
  if nOld > 0 and bHasBlueprint then
    local tBackupHabs = {}
    local tBackupBox = nil
    for _, o in pairs(tPanels) do
      pcall(function()
        for nHabID in pairs(api_hb:GetHabitatsFromBoundaryObject(o) or {}) do
          tBackupHabs[nHabID] = true
        end
      end)
      tBackupBox = BoxUnion(tBackupBox, BoundaryObjectBox(o))
    end
    for _, o in pairs(tPosts) do
      tBackupBox = BoxUnion(tBackupBox, BoundaryObjectBox(o))
    end
    local tHabEnts = {}
    for nHabID in pairs(tBackupHabs) do
      local bOk, nEnt = pcall(tWorldAPIs.habitat.GetEntityIDFromHabitatID, tWorldAPIs.habitat, nHabID)
      if bOk and nEnt ~= nil then
        table.insert(tHabEnts, {nHabitatID = nHabID, nEntity = nEnt})
      end
    end
    if #tHabEnts > 0 and tBackupBox ~= nil then
      sBackupFile = Yielding_SaveSelection("fence_bak_", function(_selection, _tw)
        for _, tH in ipairs(tHabEnts) do
          _selection:AddEntityID(tH.nEntity)
          local bRoof, nRoof = pcall(_tw.habitatboundary.GetRoof, _tw.habitatboundary, tH.nEntity)
          if bRoof and nRoof ~= nil then
            _selection:AddEntityID(nRoof)
          end
          pcall(function()
            local tObjs = _tw.habitatboundary:GetBoundaryObjectsForHabitat(tH.nHabitatID)
            for oProp in pairs(tObjs.tAttachableProps or {}) do
              _selection:AddEntityID(oProp:EntityID())
            end
          end)
        end
      end)
      if sBackupFile ~= nil then
        local bc = Centre(tBackupBox)
        tBackupTarget = {x = bc.x, y = bc.y, z = bc.z, by0 = Cm(tBackupBox.y0)}
      end
    end
  end

  if nOld > 0 then
    BuildSync.Breadcrumb("apply fence region: demolish " .. nOld .. " own fence pieces")
    local h = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
    PrepareFenceHierarchy(h)
    local cl = h:GetHabitatBoundaryChangeList()
    h:BeginVolumeModificationsBlock()
    api_hb:DeleteMultiSelection(selection, {oHabitatBoundaryChangeList = cl, sBoundaryType = "Brick_Red"})
    for nRoof in pairs(tRoofs or {}) do
      pcall(function()
        local nHabID = api_hb:GetRoofHabitat(nRoof)
        if nHabID ~= nil then
          cl:RemoveRoof(nHabID)
        end
      end)
    end
    HandleLakesInLimbo(h)
    cl:RefreshAdjacentPosts()
    h:EndVolumeModificationsBlock()
    api_hb:AddCashDeltaOperation(cl, false)
    local bDeleted = Yielding_CommitRegion(h, nil, true)
    if bDeleted == nil then
      return
    end
    if not bDeleted then
      BuildSync.Count("apply failed")
      Log("remote fence region: could not remove own fences, placement skipped")
      return
    end
  end
  if bHasBlueprint then
    local fnMeasureFence = function(_moveObject)
      return MeasureNewHabitatsBox(tOldHabs) or MeasureNewFencePiecesBox(r, tOldRaw) or MoveObjectBox(_moveObject)
    end
    BuildSync.Breadcrumb("apply fence region: load and place " .. tostring(_sFile))
    local h = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
    PrepareFenceHierarchy(h)
    HandleLakesInLimbo(h)
    local fnAdjust = Yielding_PlaceBlueprint(h, _sFile, TargetOf(_tData), r, s.tFlags.fence, tOldRaw, {fnMeasure = fnMeasureFence})
    if fnAdjust == nil then
      BuildSync.Count("apply failed")
      return
    end
    BuildSync.Breadcrumb("apply fence region: preview, commit")
    local bPlaced = Yielding_CommitRegion(h, fnAdjust, true)
    if bPlaced == nil then
      return
    end
    if not bPlaced then
      -- Retry once with relaxed terrain modification flags (glass/acrylic swaps next to existing water/paths).
      Log("remote fence region: retrying placement with relaxed terrain volume flags")
      local h2 = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
      PrepareFenceHierarchy(h2)
      HandleLakesInLimbo(h2)
      local fnAdjust2 = Yielding_PlaceBlueprint(h2, _sFile, TargetOf(_tData), r, s.tFlags.fence, tOldRaw, {fnMeasure = fnMeasureFence})
      if fnAdjust2 ~= nil then
        local bRetryOk = Yielding_CommitRegion(h2, fnAdjust2, false)
        if bRetryOk == true then
          bPlaced = true
        end
      end
    end
    if not bPlaced and sBackupFile ~= nil and tBackupTarget ~= nil then
      -- Roll back our demolished walls so a refused remote fence edit never leaves the player with missing walls.
      Log("remote fence region: placement rejected, restoring previous walls from backup")
      local hBak = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
      PrepareFenceHierarchy(hBak)
      HandleLakesInLimbo(hBak)
      local fnAdjBak = Yielding_PlaceBlueprint(hBak, Bridge.GetPrefix() .. sBackupFile, tBackupTarget, r, s.tFlags.fence,
        tOldRaw, {fnMeasure = fnMeasureFence})
      if fnAdjBak ~= nil then
        Yielding_CommitRegion(hBak, fnAdjBak, false)
      end
    end
    BuildSync.Count(bPlaced and "applied fence region" or "apply failed")
    Log("remote fence region " .. RegionText(r) .. (bPlaced and " placed" or " rejected") .. " (removed " ..
      nOld .. " own pieces first)")
  else
    BuildSync.Count("applied fence region")
    Log("remote fence region " .. RegionText(r) .. ": removed " .. nOld .. " own pieces, nothing to place")
  end
  IgnoreArea(r)
end

-- "Aquarium" habitats use acrylic panels; Glass / Glass_One_Way / Brick / etc. belong to Standard barriers.
local HabitatTypeFor = function(_sBoundaryType)
  local sType = string.lower(tostring(_sBoundaryType))
  if string.find(sType, "acrylic", 1, true) then
    return "Aquarium"
  end
  return "Standard"
end

local c_tPosVectorKeys = {
  vPos = true,
  vBasePosStart = true,
  vBasePosEnd = true,
  vBasePos = true,
}

local c_tDirVectorKeys = {
  vDir = true,
  vDirStart = true,
  vDirEnd = true,
}

local IsFiniteNum = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

local IsSafeBoundaryType = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_]+$") ~= nil
end

local NormDir = function(_x, _y, _z)
  local len = math.sqrt(_x * _x + _y * _y + _z * _z)
  if len > 1e-5 then
    return _x / len, _y / len, _z / len
  end
  return 0, 0, 1
end

local Unpack = function(_t, _nDx)
  local tData = {}
  for k, v in pairs(_t.f or {}) do
    if k == "sBoundaryType" then
      if IsSafeBoundaryType(v) then
        tData[k] = v
      end
    elseif type(v) == "boolean" or IsFiniteNum(v) then
      tData[k] = v
    end
  end
  for k, a in pairs(_t.v or {}) do
    if type(a) == "table" and IsFiniteNum(a[1]) and IsFiniteNum(a[2]) and IsFiniteNum(a[3]) then
      if c_tPosVectorKeys[k] then
        -- Position vectors shift with loopback offset _nDx.
        tData[k] = Vector3:new(a[1] + _nDx, a[2], a[3])
      elseif c_tDirVectorKeys[k] then
        -- Direction vectors NEVER shift with _nDx and must remain unit length.
        local dx, dy, dz = NormDir(a[1], a[2], a[3])
        tData[k] = Vector3:new(dx, dy, dz)
      end
    end
  end
  if tData.sBoundaryType ~= nil then
    local sPrimary = HabitatTypeFor(tData.sBoundaryType)
    local sFallback = sPrimary == "Aquarium" and "Standard" or "Aquarium"
    local bOk, tFlexi = pcall(function()
      return api.world.GetWorldAPIs().habitatboundary:NewFlexiColourDataForBoundaryType(sPrimary, tData.sBoundaryType)
    end)
    if not (bOk and tFlexi ~= nil) then
      bOk, tFlexi = pcall(function()
        return api.world.GetWorldAPIs().habitatboundary:NewFlexiColourDataForBoundaryType(sFallback, tData.sBoundaryType)
      end)
    end
    if bOk and tFlexi ~= nil then
      tData.tFlexiColours = tFlexi
    end
  end
  return tData
end

local ClampPostHeight = function(_api_hb, _tPostData)
  local bMin, nMin = pcall(function() return _api_hb:GetMinHeight() end)
  local nMinH = (bMin and IsFiniteNum(nMin)) and nMin or 0.5
  local nBaseY = select(2, Vec3(_tPostData.vPos))
  if nBaseY ~= nil and _tPostData.nWorldHeight < nBaseY + nMinH then
    _tPostData.nWorldHeight = nBaseY + nMinH
  end
end

local EnsurePanelDirs = function(_tPanelData)
  if _tPanelData.vDirStart == nil or _tPanelData.vDirEnd == nil then
    local sx, sy, sz = Vec3(_tPanelData.vBasePosStart)
    local ex, ey, ez = Vec3(_tPanelData.vBasePosEnd)
    if sx ~= nil and ex ~= nil then
      local dx, dy, dz = NormDir(ex - sx, 0, ez - sz)
      if _tPanelData.vDirStart == nil then
        _tPanelData.vDirStart = Vector3:new(dx, dy, dz)
      end
      if _tPanelData.vDirEnd == nil then
        _tPanelData.vDirEnd = Vector3:new(dx, dy, dz)
      end
    end
  end
end

local Job_ApplyFencePieces = function(_tData)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local api_hb = tWorldAPIs.habitatboundary
  local nDx = (_tData.ox or 0) / 100
  local r = Shift(RegionFromData(_tData), nDx)
  local tPosts, tPanels, _, _, tProps, tPillars, tRoofs = QueryFencePieces(r)
  CollectConnected(tPosts, tPanels)
  local selection, nOld = BuildBoundarySelection(tPosts, tPanels, tProps, tPillars, tRoofs)
  s.nIgnoreFenceUntil = s.nClock + 1e9
  BuildSync.Breadcrumb("apply open fence " .. RegionText(r) .. ": remove " .. nOld .. ", add " .. #_tData.posts ..
    " posts + " .. #_tData.panels .. " panels")
  local nAddedPosts, nAddedPanels = 0, 0
  local BuildInto = function(h)
    PrepareFenceHierarchy(h)
    local cl = h:GetHabitatBoundaryChangeList()
    h:BeginVolumeModificationsBlock()
    if nOld > 0 then
      api_hb:DeleteMultiSelection(selection, {oHabitatBoundaryChangeList = cl, sBoundaryType = "Brick_Red"})
    end
    local tNewPosts = {}
    for i, tPost in ipairs(_tData.posts or {}) do
      local tPostData = Unpack(tPost, nDx)
      if tPostData.vPos ~= nil and tPostData.nWorldHeight ~= nil and tPostData.sBoundaryType ~= nil then
        if tPostData.vDir == nil then
          tPostData.vDir = Vector3:new(0, 0, 1)
        end
        ClampPostHeight(api_hb, tPostData)
        local oPost = api_hb:CreateNewControlPost()
        oPost:FillData(tPostData)
        cl:AddControlPost(oPost)
        tNewPosts[i] = oPost
        nAddedPosts = nAddedPosts + 1
      end
    end
    for _, tPanel in ipairs(_tData.panels or {}) do
      local tPanelData = Unpack(tPanel, nDx)
      tPanelData.oStartControlPost = tNewPosts[tPanel.s]
      tPanelData.oEndControlPost = tNewPosts[tPanel.e]
      if tPanelData.oStartControlPost ~= nil and tPanelData.oEndControlPost ~= nil and tPanelData.vBasePosStart ~= nil and
          tPanelData.vBasePosEnd ~= nil and tPanelData.sBoundaryType ~= nil then
        EnsurePanelDirs(tPanelData)
        local oPanel = api_hb:CreateNewPanel()
        oPanel:FillData(tPanelData)
        cl:AddPanel(oPanel)
        nAddedPanels = nAddedPanels + 1
      end
    end
    HandleLakesInLimbo(h)
    cl:RefreshAdjacentPosts()
    h:EndVolumeModificationsBlock()
    api_hb:AddCashDeltaOperation(cl, false)
  end
  local bDone
  if c_bLiveFences and not BuildSync.IsUndoFree() then
    -- The fence tool holds a preview while open: hand the rebuild to the active editor so the friend's
    -- wall shows now. Kill switch: set PZ2COOP_LIVE_FENCES = false if this ever hangs the game again.
    local tNote = {x = Cm((r.x0 + r.x1) / 2), y = Cm((r.y0 + r.y1) / 2), z = Cm((r.z0 + r.z1) / 2)}
    BuildSync.Breadcrumb("apply open fence: hand to the active editor")
    bDone = BuildSync.Yielding_ModeOperation("open fence", tNote, function(clh)
      -- An error here would kill the editor's own coroutine; log it instead.
      local bOk, sError = pcall(BuildInto, clh)
      if not bOk then
        Log("open fence build in the editor failed: " .. tostring(sError))
      end
    end)
  else
    local h = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
    BuildInto(h)
    BuildSync.Breadcrumb("apply open fence: preview, commit (" .. nAddedPosts .. " posts, " .. nAddedPanels .. " panels)")
    bDone = Yielding_CommitRegion(h, nil, true)
  end
  if bDone == nil then
    if c_bLiveFences then
      BuildSync.RequestRetry()
    end
    s.nIgnoreFenceUntil = -1
    return
  end
  s.nIgnoreFenceUntil = -1
  IgnoreArea(r)
  BuildSync.Count(bDone and "applied open fence" or "apply failed")
  Log("remote open fence " .. RegionText(r) .. (bDone and " rebuilt" or " rejected") .. " (removed " .. nOld ..
    ", added " .. nAddedPosts .. " posts, " .. nAddedPanels .. " panels)")
end

-- Autotest: send the path chunks in an area for real (the local-edit route), and measure the lowest path
-- piece bottom in an area (cm), the same way on both copies.
RegionSync.TestSendPath = function(_r)
  BuildSync.QueueJob(function() Job_SendPath(_r) end)
end
-- Second value: how many path pieces the area holds (a re-applied copy must not lose any).
RegionSync.TestPathBottom = function(_r)
  local tBox = nil
  local tHits = QueryHits(_r, s.tFlags.path)
  for _, tPair in ipairs(tHits) do
    tBox = BoxUnion(tBox, ShapeBox(tPair.nRaw))
  end
  return tBox and Cm(tBox.y0) or nil, #tHits
end

-- Autotest: last measured path bottom offset (cm) of a remote path apply, then cleared.
RegionSync.TakeLastPathDy = function()
  local n = s.nLastPathDy
  s.nLastPathDy = nil
  return n
end

RegionSync.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nRegionPacket or type(_tMsg.tData) ~= "table" then
    return false
  end
  local tData = _tMsg.tData
  if type(tData.x0) ~= "number" or type(tData.x1) ~= "number" then
    Log("region packet without a region dropped")
    return true
  end
  local sFile = _tMsg.sFile
  if tData.k == "path" then
    BuildSync.QueueRemote(function() Job_ApplyPath(sFile, tData) end, sFile ~= nil, true)
  elseif tData.k == "fence" and not c_bApplyFences then
    Log("received fence change (" .. tostring(tData.mode or "habitat") .. ", " .. tostring(tData.n) ..
      " items) not applied: fence apply is switched off")
  elseif tData.k == "fence" and tData.mode == "pieces" then
    tData.posts = tData.posts or {}
    tData.panels = tData.panels or {}
    BuildSync.QueueRemote(function() Job_ApplyFencePieces(tData) end, false, c_bLiveFences)
  elseif tData.k == "fence" then
    BuildSync.QueueRemote(function() Job_ApplyFence(sFile, tData) end, sFile ~= nil)
  else
    Log("unknown region kind " .. tostring(tData.k))
  end
  return true
end

-- ---- detection -------------------------------------------------------------------------------------------
local OnSpatialChanged = function(_tMessages)
  if type(_tMessages) ~= "table" or not s.bSending or Bridge.IsApplying() or
      s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  for _, tMessage in pairs(_tMessages) do
    if type(tMessage) == "table" and tMessage.sType == "SpatialDatabase" and tMessage.nFlags ~= nil and
        not IsIgnored(Grow(nil, tMessage.vAABBMin, tMessage.vAABBMax)) then
      if Grow(nil, tMessage.vAABBMin, tMessage.vAABBMax) ~= nil then
        s.tAllFlags[tMessage.nFlags] = (s.tAllFlags[tMessage.nFlags] or 0) + 1
      end
      for sKind, nBit in pairs(s.tFlags) do
        if HasFlag(tMessage.nFlags, nBit) and not (sKind == "fence" and s.nClock < s.nIgnoreFenceUntil) then
          local tBefore = s.tAcc[sKind]
          s.tAcc[sKind] = Grow(s.tAcc[sKind], tMessage.vAABBMin, tMessage.vAABBMax)
          if s.tAcc[sKind] ~= nil then
            s.nLastChange = s.nClock
            if tBefore == nil then
              s.tSeenFlags[tMessage.nFlags] = (s.tSeenFlags[tMessage.nFlags] or 0) + 1
            end
          end
        end
      end
    end
  end
end

local OnHabitatEvent = function(_tMessages)
  if type(_tMessages) ~= "table" or not s.bSending or Bridge.IsApplying() or
      s.nClock < s.nIgnoreFenceUntil or s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  local tWorldAPIs = api.world.GetWorldAPIs()
  local bFoundExplicit = false
  local QueueHab = function(_nHabEntity)
    if type(_nHabEntity) ~= "number" or tWorldAPIs.habitat == nil then
      return
    end
    local bOk, nHabID = pcall(tWorldAPIs.habitat.GetHabitatIDFromEntityID, tWorldAPIs.habitat, _nHabEntity)
    if bOk and nHabID ~= nil then
      local tBox = HabitatBoundaryBox(nHabID)
      if tBox ~= nil and not IsIgnored(tBox) then
        s.tAcc.fence = BoxUnion(s.tAcc.fence, tBox)
        s.nLastChange = s.nClock
        bFoundExplicit = true
      end
    end
  end
  for _, tMessage in pairs(_tMessages) do
    local nHabEntity = type(tMessage) == "table" and tMessage.nHabitatEntityID or nil
    if type(nHabEntity) == "number" then
      s.tKnownHabitats[nHabEntity] = true
      QueueHab(nHabEntity)
    end
  end
  -- MsgType_HabitatGateCreatedMessage arrives with an empty payload in retail: catch newly formed habitats.
  if not bFoundExplicit and tWorldAPIs.facilities ~= nil then
    pcall(function()
      for _, nHabEntity in pairs(tWorldAPIs.facilities:GetAllHabitatsEntityIDs() or {}) do
        if not s.tKnownHabitats[nHabEntity] then
          s.tKnownHabitats[nHabEntity] = true
          QueueHab(nHabEntity)
        end
      end
    end)
  end
end

RegionSync.Install = function()
  if s.bInstalled then
    return
  end
  local spatial = api.world.GetWorldAPIs().spatial
  s.tFlags = {path = spatial.Flag_Path, fence = spatial.Flag_HabitatBoundary}
  s.tAcc = {}
  s.tIgnore = {}
  s.bSettled = false
  s.nStartedAt = s.nClock
  s.fnReceiver = function(_tMessages)
    local bOk, sError = pcall(OnSpatialChanged, _tMessages)
    if not bOk then
      Log("detector error: " .. tostring(sError))
    end
  end
  api.messaging.RegisterReceiver(api.messaging.MsgType_SpatialVolumeChangedMessage, s.fnReceiver)
  if api.messaging.MsgType_HabitatBoundaryUpdatedMessage ~= nil then
    s.fnHabReceiver = function(_tMessages) pcall(OnHabitatEvent, _tMessages) end
    api.messaging.RegisterReceiver(api.messaging.MsgType_HabitatBoundaryUpdatedMessage, s.fnHabReceiver)
  end
  if api.messaging.MsgType_HabitatGateCreatedMessage ~= nil then
    s.fnGateReceiver = function(_tMessages) pcall(OnHabitatEvent, _tMessages) end
    api.messaging.RegisterReceiver(api.messaging.MsgType_HabitatGateCreatedMessage, s.fnGateReceiver)
  end
  BuildSync.SetSettleListener(function()
    s.bSettled = true
    -- Detection fallback: a path/fence tool committed but no change carried the expected bit. The flag
    -- values that did arrive are logged so the right bits can be read off the next diag.log.
    local sTool = string.lower(BuildSync.GetTool())
    local bShapeTool = string.find(sTool, "volume", 1, true) or string.find(sTool, "boundary", 1, true) or
      string.find(sTool, "path", 1, true) or string.find(sTool, "demolish", 1, true)
    if bShapeTool and next(s.tAcc) == nil and next(s.tAllFlags) ~= nil and s.nMissLogs < 20 then
      s.nMissLogs = s.nMissLogs + 1
      local tSeen = {}
      for nFlags, n in pairs(s.tAllFlags) do
        table.insert(tSeen, tostring(nFlags) .. "x" .. n)
      end
      Log("tool " .. BuildSync.GetTool() .. " committed, no path/fence bit seen; change flags: " .. table.concat(tSeen, " "))
    end
    s.tAllFlags = {}
  end)
  s.bInstalled = true
  Log("installed, spatial flags Path=" .. tostring(s.tFlags.path) .. " HabitatBoundary=" .. tostring(s.tFlags.fence))
end

RegionSync.Uninstall = function()
  if s.fnReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_SpatialVolumeChangedMessage, s.fnReceiver)
    s.fnReceiver = nil
  end
  if s.fnHabReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_HabitatBoundaryUpdatedMessage, s.fnHabReceiver)
    s.fnHabReceiver = nil
  end
  if s.fnGateReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_HabitatGateCreatedMessage, s.fnGateReceiver)
    s.fnGateReceiver = nil
  end
  BuildSync.SetSettleListener(nil)
  s.bInstalled = false
end

RegionSync.Update = function(_nDeltaTime, _bSending)
  s.nClock = s.nClock + _nDeltaTime
  s.bSending = _bSending
  if next(s.tAcc) == nil then
    s.bSettled = false
    return
  end
  local nQuietFor = s.nClock - s.nLastChange
  local bReady = (s.bSettled and nQuietFor >= c_nQuiet) or (nQuietFor >= c_nQuietUnsettled and BuildSync.IsUndoFree())
  if not bReady then
    return
  end
  local tSeen = {}
  for nFlags, n in pairs(s.tSeenFlags) do
    table.insert(tSeen, tostring(nFlags) .. "x" .. n)
  end
  s.tSeenFlags = {}
  for sKind, tRegion in pairs(s.tAcc) do
    local r = Expand(tRegion, c_nMarginM)
    Log(sKind .. " change detected in " .. RegionText(r) .. " (settled=" .. tostring(s.bSettled) .. ", flags " ..
      table.concat(tSeen, " ") .. ")")
    if sKind == "path" then
      BuildSync.QueueJob(function() Job_SendPath(r) end)
    else
      BuildSync.QueueJob(function() Job_SendFence(r) end)
    end
  end
  s.tAcc = {}
  s.bSettled = false
end
