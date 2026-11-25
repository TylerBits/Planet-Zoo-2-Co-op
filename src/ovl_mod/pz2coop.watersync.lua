-- Water (lakes) sync: detects added and removed lakes and replays them with vanilla's lake APIs.
--   detect:  MsgType_LakeUpdateMessage marks a dirty flag; after a quiet window (with undo free), we diff
--            gameterrain:GetAllLakes() against our snapshot.
--   capture: gameterrain:FindLakeRefillPoint(nLakeID) + gameterrain:GetLakeRespawnProperties(nLakeID)
--            (the exact pair TerrainEditMode.AsyncRespawnLakes uses, editors.terrain.terraineditmode.lua:3583).
--   apply:   add = TerrainEditMode.AsyncCreateLake recipe (PreviewLakeAddition -> IsPreviewLakeAdditionDone ->
--            CreateLakeAddOperationFromLakePreview -> undo preview/commit -> ResetPreviewLakeAddition);
--            remove = gameterrain:FindLakesWithSphereCheck(vPos, r) -> CreateLakeRemoveOperation -> commit.
-- Packet 0x22 (ACTION_PATH_STAMP, JSON): {k = "water", op = "add"|"remove", x, y, z (cm), ...}.
-- ox (cm, solo loopback only): receiver shifts x by ox.
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
local coroutine = global.coroutine
local setmetatable = global.setmetatable
local require = global.require
local Vector3 = require("Vector3")
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local WaterSync = module(...)

local c_nRegionPacket = 0x22
local c_nStartupIgnore = 5.0
local c_nQuiet = 0.5
local c_nIgnoreAfterApply = 1.5
local c_nEchoRadiusCm = 200 -- 2 m: lakes arriving near a just-applied point are echoes
local c_nEchoWindow = 10.0
local c_nRemoveSearchRadiusM = 3.0
local c_nPreviewTimeout = 10.0 -- seconds to wait for IsPreviewLakeAdditionDone
local c_nLogLimit = 300
local c_sDefaultPrefab = "Lake"
local c_sDefaultSurface = "CalmWaterSurface"
local c_sDefaultUnderside = "CalmWaterUnderside"

local s = {
  bInstalled = false,
  bSeeded = false,
  bDirty = false,
  bSending = false,
  nClock = 0,
  nStartedAt = 0,
  nLastChange = -1,
  nIgnoreUntil = -1,
  nLogs = 0,
  fnReceiver = nil,
  tKnown = {}, -- nLakeID -> {x, y, z (cm), tProps = packed properties}
  tRecentRemote = {}, -- {x, y, z (cm), nTime}
}

local Log = function(_s)
  if s.nLogs < c_nLogLimit then
    s.nLogs = s.nLogs + 1
    Bridge.Log("water sync: " .. _s)
  end
end

local Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

local IsFinite = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

local IsSafeIdent = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_]+$") ~= nil
end

local Vec3 = function(_v)
  local bOk, x, y, z = pcall(function()
    return _v:GetX(), _v:GetY(), _v:GetZ()
  end)
  if bOk and IsFinite(x) and IsFinite(y) and IsFinite(z) then
    return x, y, z
  end
  return nil
end

local Arr = function(_a, _b, _c)
  local t = setmetatable({}, api.json.GetArrayMetatable())
  t[1], t[2], t[3] = _a, _b, _c
  return t
end

local PackTable = function(_t)
  if type(_t) ~= "table" then
    return nil
  end
  local tOut = {}
  for k, v in pairs(_t) do
    if IsSafeIdent(k) then
      local x, y, z = Vec3(v)
      if x ~= nil then
        tOut[k] = Arr(x, y, z)
      elseif IsFinite(v) or type(v) == "boolean" or IsSafeIdent(v) then
        tOut[k] = v
      end
    end
  end
  return next(tOut) ~= nil and tOut or nil
end

local UnpackTable = function(_t)
  if type(_t) ~= "table" then
    return nil
  end
  local tOut, nKeys = {}, 0
  for k, v in pairs(_t) do
    nKeys = nKeys + 1
    if nKeys > 16 then
      break
    end
    if IsSafeIdent(k) then
      if type(v) == "table" and IsFinite(v[1]) and IsFinite(v[2]) and IsFinite(v[3]) then
        tOut[k] = Vector3:new(v[1], v[2], v[3])
      elseif IsFinite(v) or type(v) == "boolean" or IsSafeIdent(v) then
        tOut[k] = v
      end
    end
  end
  return next(tOut) ~= nil and tOut or nil
end

-- ---- lake inspection -------------------------------------------------------------------------------------
local IsAquariumLake = function(_nLakeID)
  local bOk, bAq = pcall(function()
    local tWorld = api.world.GetWorldAPIs()
    if tWorld.facilities == nil or tWorld.habitat == nil or tWorld.habitat.GetAquariumLake == nil then
      return false
    end
    local tHabs = tWorld.facilities:GetAllHabitatsEntityIDs()
    if type(tHabs) ~= "table" then
      return false
    end
    for _, nHabEnt in pairs(tHabs) do
      if tWorld.habitat:IsAquarium(nHabEnt) and tWorld.habitat:GetAquariumLake(nHabEnt) == _nLakeID then
        return true
      end
    end
    return false
  end)
  return bOk and bAq == true
end

local FindAquariumAt = function(_vPos)
  local bOk, nHabEnt = pcall(function()
    local tWorld = api.world.GetWorldAPIs()
    local habitat = tWorld.habitat
    if habitat == nil then
      return nil
    end
    if habitat.GetHabitatContainingPoint ~= nil then
      local nFound = habitat:GetHabitatContainingPoint(_vPos, true, 0.5)
      if nFound ~= nil and habitat:IsAquarium(nFound) then
        return nFound
      end
    end
    if tWorld.facilities ~= nil and tWorld.habitatboundary ~= nil then
      local tHabs = tWorld.facilities:GetAllHabitatsEntityIDs()
      local nBest, nBestD2 = nil, 25.0 * 25.0
      local px, pz = _vPos:GetX(), _vPos:GetZ()
      for _, nEnt in pairs(tHabs or {}) do
        if habitat:IsAquarium(nEnt) then
          local nHabID = habitat:GetHabitatIDFromEntityID(nEnt)
          local tObjs = nHabID ~= nil and tWorld.habitatboundary:GetBoundaryObjectsForHabitat(nHabID) or nil
          local sx, sz, nPts = 0, 0, 0
          for oPost in pairs((tObjs and tObjs.tControlPosts) or {}) do
            local d = oPost:GetAllData()
            local x, _, z = Vec3(d and d.vPos)
            if x ~= nil then
              sx, sz, nPts = sx + x, sz + z, nPts + 1
            end
          end
          if nPts > 0 then
            local dx, dz = (sx / nPts) - px, (sz / nPts) - pz
            local d2 = dx * dx + dz * dz
            if d2 < nBestD2 then
              nBestD2 = d2
              nBest = nEnt
            end
          end
        end
      end
      return nBest
    end
    return nil
  end)
  return bOk and nHabEnt or nil
end

local SnapshotLake = function(_gameterrain, _nLakeID)
  local bPt, vFill = pcall(function()
    return _gameterrain:FindLakeRefillPoint(_nLakeID)
  end)
  local x, y, z = nil, nil, nil
  if bPt and vFill ~= nil then
    x, y, z = Vec3(vFill)
  end
  if x == nil then
    return nil
  end
  local bProp, tRespawn = pcall(function()
    return _gameterrain:GetLakeRespawnProperties(_nLakeID)
  end)
  tRespawn = (bProp and type(tRespawn) == "table") and tRespawn or {}
  local tCol = tRespawn.tColourData
  if tCol == nil then
    local bCol, tGot = pcall(function() return _gameterrain:GetLakeColourData(_nLakeID) end)
    if bCol and type(tGot) == "table" then
      tCol = tGot
    end
  end
  local tPart = tRespawn.tParticleData
  if tPart == nil then
    local bPart, tGot = pcall(function() return _gameterrain:GetLakeParticleData(_nLakeID) end)
    if bPart and type(tGot) == "table" then
      tPart = tGot
    end
  end
  return {
    x = Cm(x),
    y = Cm(y),
    z = Cm(z),
    aq = IsAquariumLake(_nLakeID) or nil,
    prefab = IsSafeIdent(tRespawn.sPrefabName) and tRespawn.sPrefabName or c_sDefaultPrefab,
    surf = IsSafeIdent(tRespawn.sSurfaceMaterialName) and tRespawn.sSurfaceMaterialName or c_sDefaultSurface,
    under = IsSafeIdent(tRespawn.sUndersideMaterialName) and tRespawn.sUndersideMaterialName or c_sDefaultUnderside,
    clean = IsFinite(tRespawn.nCleanliness) and tRespawn.nCleanliness or 1.0,
    temp = IsFinite(tRespawn.nTemperature) and tRespawn.nTemperature or nil,
    col = PackTable(tCol),
    part = PackTable(tPart),
  }
end

local ListLakes = function()
  local gameterrain = api.world.GetWorldAPIs().gameterrain
  local bOk, tLakes = pcall(function()
    return gameterrain:GetAllLakes()
  end)
  if not bOk or type(tLakes) ~= "table" then
    return nil, gameterrain
  end
  return tLakes, gameterrain
end

local RefreshSnapshot = function()
  local tLakes, gameterrain = ListLakes()
  if tLakes == nil then
    return false
  end
  local tNew = {}
  for _, nLakeID in ipairs(tLakes) do
    local tSnap = SnapshotLake(gameterrain, nLakeID)
    if tSnap ~= nil then
      tNew[nLakeID] = tSnap
    end
  end
  s.tKnown = tNew
  s.bSeeded = true
  return true
end

-- ---- echo suppression ------------------------------------------------------------------------------------
local NoteRemote = function(_x, _y, _z)
  table.insert(s.tRecentRemote, {x = _x, y = _y, z = _z, nTime = s.nClock})
end

local IsRemoteEcho = function(_x, _y, _z)
  local nR2 = c_nEchoRadiusCm * c_nEchoRadiusCm
  for _, tEntry in ipairs(s.tRecentRemote) do
    local dx, dy, dz = tEntry.x - _x, tEntry.y - _y, tEntry.z - _z
    if dx * dx + dy * dy + dz * dz <= nR2 then
      return true
    end
  end
  return false
end

-- ---- apply (runs on BuildSync's job queue inside Bridge.BeginApply/EndApply) -----------------------------
local Yielding_CommitChangeList = function(_oChangeList, _fnExtraCheck)
  local undo = api.undo
  if not BuildSync.IsUndoFree() then
    BuildSync.RequestRetry()
    return nil
  end
  local busyToken, previewToken = undo.PreviewChangeList(_oChangeList)
  while not undo.IsOperationComplete(busyToken) do
    coroutine.yield()
  end
  local bCanCommit = undo.CanCommitPreview(previewToken)
  while bCanCommit == nil do
    coroutine.yield()
    bCanCommit = undo.CanCommitPreview(previewToken)
  end
  if bCanCommit and _fnExtraCheck ~= nil then
    bCanCommit = _fnExtraCheck() == true
  end
  local waitToken = bCanCommit and undo.CommitPreview(previewToken) or undo.CancelPreview(previewToken)
  while not undo.IsOperationComplete(waitToken) do
    coroutine.yield()
  end
  undo.Checkpoint({sMode = "PZ2Coop"})
  undo.ClearHistory({})
  return bCanCommit
end

-- Vanilla recipe: TerrainEditMode.AsyncCreateLake (editors.terrain.terraineditmode.lua:3730-3756),
-- plus HabitatGateInfoPopUp FillAquarium (components.ui.habitatgateinfopopup.lua:3531) for aquarium water.
local Job_ApplyAddLake = function(_tData)
  local tWorld = api.world.GetWorldAPIs()
  local gameterrain = tWorld.gameterrain
  local xCm = _tData.x + (_tData.ox or 0)
  local yCm, zCm = _tData.y, _tData.z
  local vFill = Vector3:new(xCm / 100, yCm / 100, zCm / 100)
  local sPrefab = IsSafeIdent(_tData.prefab) and _tData.prefab or c_sDefaultPrefab
  local sSurf = IsSafeIdent(_tData.surf) and _tData.surf or c_sDefaultSurface
  local sUnder = IsSafeIdent(_tData.under) and _tData.under or c_sDefaultUnderside
  local nClean = IsFinite(_tData.clean) and _tData.clean or 1.0
  local nTemp = IsFinite(_tData.temp) and _tData.temp or nil
  local tCol = UnpackTable(_tData.col)
  local tPart = UnpackTable(_tData.part)

  if not BuildSync.IsUndoFree() then
    BuildSync.RequestRetry()
    return
  end
  NoteRemote(xCm, yCm, zCm)
  BuildSync.Breadcrumb(string.format("apply water add at %.1f,%.1f,%.1f (aq=%s)", xCm / 100, yCm / 100, zCm / 100,
    tostring(_tData.aq == true)))

  if _tData.aq == true and tWorld.habitat ~= nil and tWorld.habitat.FillAquarium ~= nil then
    local nAqEnt = FindAquariumAt(vFill)
    if nAqEnt ~= nil then
      local bFilled = false
      local bAqOk, sAqErr = pcall(function()
        if tWorld.habitat:GetAquariumLake(nAqEnt) ~= nil then
          bFilled = true
          return
        end
        tWorld.habitat:FillAquarium(nAqEnt)
        local nStart = s.nClock
        while s.nClock - nStart < c_nPreviewTimeout do
          local bRes = tWorld.habitat:GetAquariumFillResult(nAqEnt)
          if bRes ~= nil then
            bFilled = bRes == true
            return
          end
          coroutine.yield()
        end
        bFilled = tWorld.habitat:GetAquariumLake(nAqEnt) ~= nil
      end)
      if not bAqOk then
        Log("aquarium fill error: " .. tostring(sAqErr))
      end
      s.nIgnoreUntil = s.nClock + c_nIgnoreAfterApply
      RefreshSnapshot()
      BuildSync.Count(bFilled and "applied water add" or "water add failed")
      Log(string.format("remote aquarium fill entity=%s at (%.1f,%.1f,%.1f) %s", tostring(nAqEnt),
        xCm / 100, yCm / 100, zCm / 100, bFilled and "applied" or "rejected"))
      return
    end
  end

  local bCommitted = false
  local bOk, sError = pcall(function()
    gameterrain:PreviewLakeAddition(vFill, sPrefab, sSurf, sUnder, nClean, nTemp, tCol, tPart)
    local nStart = s.nClock
    while not gameterrain:IsPreviewLakeAdditionDone() do
      if s.nClock - nStart > c_nPreviewTimeout then
        Log("lake preview timed out")
        return
      end
      coroutine.yield()
    end
    if not gameterrain:IsPreviewLakeAdditionCommitableInTheory() then
      Log(string.format("lake add at (%.1f,%.1f,%.1f) not commitable in theory", xCm / 100, yCm / 100, zCm / 100))
      return
    end
    local oChangeList = gameterrain:CreateLakeAddOperationFromLakePreview(false)
    if oChangeList == nil then
      Log("CreateLakeAddOperationFromLakePreview returned nil")
      return
    end
    local bRes = Yielding_CommitChangeList(oChangeList, function()
      return gameterrain:IsPreviewLakeAdditionCommitableInPractice()
    end)
    bCommitted = bRes == true
  end)
  pcall(function()
    gameterrain:ResetPreviewLakeAddition()
  end)
  if not bOk then
    Log("lake add error: " .. tostring(sError))
  end
  s.nIgnoreUntil = s.nClock + c_nIgnoreAfterApply
  RefreshSnapshot()
  BuildSync.Count(bCommitted and "applied water add" or "water add failed")
  Log(string.format("remote water add at (%.1f,%.1f,%.1f) %s", xCm / 100, yCm / 100, zCm / 100,
    bCommitted and "applied" or "rejected"))
end

-- Vanilla recipe: LakeInfoPopUp / TerrainEditMode lake removal (components.ui.lakeinfopopup.lua:626).
local Job_ApplyRemoveLake = function(_tData)
  local gameterrain = api.world.GetWorldAPIs().gameterrain
  local xCm = _tData.x + (_tData.ox or 0)
  local yCm, zCm = _tData.y, _tData.z
  local vPos = Vector3:new(xCm / 100, yCm / 100, zCm / 100)
  if not BuildSync.IsUndoFree() then
    BuildSync.RequestRetry()
    return
  end
  NoteRemote(xCm, yCm, zCm)
  BuildSync.Breadcrumb(string.format("apply water remove at %.1f,%.1f,%.1f", xCm / 100, yCm / 100, zCm / 100))

  local bFound, tLakes = pcall(function()
    return gameterrain:FindLakesWithSphereCheck(vPos, c_nRemoveSearchRadiusM)
  end)
  local nLakeID = (bFound and type(tLakes) == "table") and tLakes[1] or nil
  if nLakeID == nil then
    -- Fallback: nearest known lake within search radius
    local nBestDist = (c_nRemoveSearchRadiusM * 100) ^ 2
    for id, tSnap in pairs(s.tKnown) do
      local dx, dy, dz = tSnap.x - xCm, tSnap.y - yCm, tSnap.z - zCm
      local d2 = dx * dx + dy * dy + dz * dz
      if d2 <= nBestDist then
        nBestDist = d2
        nLakeID = id
      end
    end
  end
  if nLakeID == nil then
    Log(string.format("remote water remove: found no lake near (%.1f,%.1f,%.1f)", xCm / 100, yCm / 100, zCm / 100))
    return
  end
  local bOp, oChangeList = pcall(function()
    return gameterrain:CreateLakeRemoveOperation(nLakeID)
  end)
  if not bOp or oChangeList == nil then
    Log("CreateLakeRemoveOperation failed: " .. tostring(oChangeList))
    return
  end
  local bCommitted = Yielding_CommitChangeList(oChangeList)
  if bCommitted == nil then
    return
  end
  s.nIgnoreUntil = s.nClock + c_nIgnoreAfterApply
  RefreshSnapshot()
  BuildSync.Count(bCommitted and "applied water remove" or "water remove failed")
  Log(string.format("remote water remove lake %s at (%.1f,%.1f,%.1f) %s", tostring(nLakeID),
    xCm / 100, yCm / 100, zCm / 100, bCommitted and "applied" or "rejected"))
end

-- ---- detection & diff ------------------------------------------------------------------------------------
local ProcessDiff = function()
  local tLakes, gameterrain = ListLakes()
  if tLakes == nil then
    return
  end
  local tCurrent = {}
  for _, nLakeID in ipairs(tLakes) do
    tCurrent[nLakeID] = true
  end

  -- Removed lakes
  for nLakeID, tOld in pairs(s.tKnown) do
    if not tCurrent[nLakeID] then
      s.tKnown[nLakeID] = nil
      if not IsRemoteEcho(tOld.x, tOld.y, tOld.z) then
        BuildSync.Count("sent water remove")
        Log(string.format("local water remove lake %s at (%.1f,%.1f,%.1f)", tostring(nLakeID),
          tOld.x / 100, tOld.y / 100, tOld.z / 100))
        Bridge.SendPacket(c_nRegionPacket, nil, {
          k = "water", op = "remove", x = tOld.x, y = tOld.y, z = tOld.z,
        })
      end
    end
  end

  -- Added lakes
  for nLakeID in pairs(tCurrent) do
    if s.tKnown[nLakeID] == nil then
      local tSnap = SnapshotLake(gameterrain, nLakeID)
      if tSnap ~= nil then
        s.tKnown[nLakeID] = tSnap
        if not IsRemoteEcho(tSnap.x, tSnap.y, tSnap.z) then
          BuildSync.Count("sent water add")
          Log(string.format("local water add lake %s (%s) at (%.1f,%.1f,%.1f)", tostring(nLakeID),
            tSnap.surf, tSnap.x / 100, tSnap.y / 100, tSnap.z / 100))
          Bridge.SendPacket(c_nRegionPacket, nil, {
            k = "water",
            op = "add",
            x = tSnap.x,
            y = tSnap.y,
            z = tSnap.z,
            aq = tSnap.aq,
            prefab = tSnap.prefab,
            surf = tSnap.surf,
            under = tSnap.under,
            clean = tSnap.clean,
            temp = tSnap.temp,
            col = tSnap.col,
            part = tSnap.part,
          })
        end
      end
    end
  end
end

local OnLakeUpdate = function()
  if not s.bSending or Bridge.IsApplying() or s.nClock < s.nIgnoreUntil or s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  s.bDirty = true
  s.nLastChange = s.nClock
end

-- ---- module API ------------------------------------------------------------------------------------------
WaterSync.Install = function()
  if s.bInstalled then
    return
  end
  s.bSeeded = false
  s.bDirty = false
  s.nStartedAt = s.nClock
  s.nIgnoreUntil = -1
  s.tKnown = {}
  s.tRecentRemote = {}
  local nMsg = api.messaging.MsgType_LakeUpdateMessage
  if nMsg ~= nil then
    s.fnReceiver = function()
      pcall(OnLakeUpdate)
    end
    api.messaging.RegisterReceiver(nMsg, s.fnReceiver)
  end
  s.bInstalled = true
  Log("installed")
end

WaterSync.Uninstall = function()
  if s.fnReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_LakeUpdateMessage, s.fnReceiver)
    s.fnReceiver = nil
  end
  s.bInstalled = false
  s.bSeeded = false
  s.tKnown = {}
end

WaterSync.ResetSnapshot = function()
  s.bSeeded = false
  s.bDirty = false
  s.tKnown = {}
  s.tRecentRemote = {}
  s.nStartedAt = s.nClock
end

WaterSync.Update = function(_nDt, _bSending)
  if not s.bInstalled then
    return
  end
  s.nClock = s.nClock + _nDt
  s.bSending = _bSending
  for i = #s.tRecentRemote, 1, -1 do
    if s.nClock - s.tRecentRemote[i].nTime > c_nEchoWindow then
      table.remove(s.tRecentRemote, i)
    end
  end
  if not s.bSeeded and s.nClock >= s.nStartedAt + c_nStartupIgnore then
    RefreshSnapshot()
    return
  end
  if not s.bDirty or not _bSending or Bridge.IsApplying() or s.nClock < s.nIgnoreUntil then
    return
  end
  if s.nClock - s.nLastChange < c_nQuiet or not BuildSync.IsUndoFree() then
    return
  end
  s.bDirty = false
  local bOk, sError = pcall(ProcessDiff)
  if not bOk then
    Log("diff error: " .. tostring(sError))
  end
end

WaterSync.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nRegionPacket or type(_tMsg.tData) ~= "table" or _tMsg.tData.k ~= "water" then
    return false
  end
  local d = _tMsg.tData
  if not (IsFinite(d.x) and IsFinite(d.y) and IsFinite(d.z)) then
    Log("water packet without position dropped")
    return true
  end
  if d.op == "add" then
    BuildSync.QueueRemote(function() Job_ApplyAddLake(d) end, false)
  elseif d.op == "remove" then
    BuildSync.QueueRemote(function() Job_ApplyRemoveLake(d) end, false)
  else
    Log("unknown water op " .. tostring(d.op))
  end
  return true
end
