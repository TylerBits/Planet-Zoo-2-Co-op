-- Exhibit & habitat animal sync across peers using spatial addressing & deterministic SyncUUIDs (CLAUDE.md rule 3).
--   Exhibits:
--     add:    MsgType_ExhibitAnimalAddedMessage -> 0x30 {k="exhibit", op="add", s, m, x, y, z} ->
--             exhibits:AddAnimalToExhibit(nExhibitID, sSpecies, bIsMale)
--     remove: MsgType_ExhibitAnimalRemovedMessage -> 0x30 {k="exhibit", op="remove", s, x, y, z} ->
--             exhibits:GetAnimalsInExhibit + ExhibitAnimalEntityIDToUID + AttemptToSendToTradeCentre
--   Habitat animals:
--     macro:  tracks animalsDataHelpers:GetAllAnimalEntities(AnimalListType_Habitat) with deterministic SyncUUIDs
--             (species + creation index), syncing contraceptive toggles (animals:SetUsingContraceptive) and removals
--             (animals:RemoveAnimal) via 0x30 {k="animal", op="contraceptive"|"remove", ...}.
--     0x31:   host broadcasts periodic ANIMAL_WAYPOINT_10HZ snapshots ({k="waypoints", a={{id,s,x,y,z},...}})
--             so clients keep dynamic SyncUUID -> entityID bindings synchronized across peers.
local global = _G
local api = global.api
local string = global.string
local table = global.table
local math = global.math
local ipairs = global.ipairs
local pairs = global.pairs
local pcall = global.pcall
local tostring = global.tostring
local type = global.type
local setmetatable = global.setmetatable
local require = global.require
local Vector3 = require("Vector3")
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local AnimalSync = module(...)

local c_nAnimalEventPacket = 0x30
local c_nWaypointPacket = 0x31
local c_nStartupIgnore = 5.0
local c_nSearchRadiusM = 4.0
local c_nEchoRadiusCm = 400
local c_nEchoWindow = 10.0
local c_nHabitatPollInterval = 0.5
local c_nWaypointInterval = 0.5
local c_nMaxWaypointsPerPacket = 24
local c_nLogLimit = 300

local s = {
  bInstalled = false,
  bSending = false,
  bHabitatSeeded = false,
  nClock = 0,
  nStartedAt = 0,
  nHabitatTimer = 0,
  nWaypointTimer = 0,
  nSeq = 0,
  nLogs = 0,
  fnAddedReceiver = nil,
  fnRemovedReceiver = nil,
  tRecentRemote = {}, -- {sKey, x, y, z (cm), nTime}
  tExhibitAnimals = {}, -- nAnimalID -> {nExhibitID, sSpecies, x, y, z (cm)}
  tHabitatKnown = {}, -- nEntityID -> {sSyncId, sSpecies, bContra, x, y, z (cm)}
  tBySyncId = {}, -- sSyncId -> nEntityID
}

local Log = function(_s)
  if s.nLogs < c_nLogLimit then
    s.nLogs = s.nLogs + 1
    Bridge.Log("animal sync: " .. _s)
  end
end

local Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

local IsFinite = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

local IsSafeSpecies = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_]+$") ~= nil
end

local IsSafeSyncId = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_%-]+$") ~= nil
end

local EntityPosCm = function(_nEntityID)
  if _nEntityID == nil then
    return nil
  end
  local bOk, vPos = pcall(function()
    local tr = api.world.GetWorldAPIs().transform:CalculateWorldTransform(_nEntityID)
    return tr and (tr.GetPos and tr:GetPos() or tr:Pos())
  end)
  if not bOk or vPos == nil then
    return nil
  end
  local bC, x, y, z = pcall(function()
    if vPos.GetX ~= nil then
      return vPos:GetX(), vPos:GetY(), vPos:GetZ()
    end
    return vPos:X(), vPos:Y(), vPos:Z()
  end)
  if bC and IsFinite(x) and IsFinite(y) and IsFinite(z) then
    return Cm(x), Cm(y), Cm(z)
  end
  return nil
end

local NoteRemote = function(_sKey, _x, _y, _z)
  table.insert(s.tRecentRemote, {sKey = _sKey, x = _x, y = _y, z = _z, nTime = s.nClock})
end

local IsRemoteEcho = function(_sKey, _x, _y, _z)
  local nR2 = c_nEchoRadiusCm * c_nEchoRadiusCm
  for _, tEntry in ipairs(s.tRecentRemote) do
    if tEntry.sKey == _sKey then
      local dx, dy, dz = tEntry.x - _x, tEntry.y - _y, tEntry.z - _z
      if dx * dx + dy * dy + dz * dz <= nR2 then
        return true
      end
    end
  end
  return false
end

local FindExhibitNear = function(_xCm, _yCm, _zCm)
  local tWorld = api.world.GetWorldAPIs()
  local vPos = Vector3:new(_xCm / 100, _yCm / 100, _zCm / 100)
  local nFlag = tWorld.spatial and tWorld.spatial.Flag_Exhibit
  local bOk, tHits = pcall(function()
    if nFlag ~= nil then
      return tWorld.spatial:SphereQuery(vPos, c_nSearchRadiusM, nFlag, 0, 64)
    end
    return nil
  end)
  if not bOk or type(tHits) ~= "table" then
    return nil
  end
  local pih = tWorld.PlayerInteractionHandler
  local nBest, nBestD2 = nil, math.huge
  for _, nHit in ipairs(tHits) do
    local nCand = nHit
    pcall(function()
      if pih and pih:HasParentEntityID(nCand) then
        nCand = pih:GetParentID(nCand)
      end
    end)
    local ex, ey, ez = EntityPosCm(nCand)
    if ex ~= nil then
      local dx, dy, dz = ex - _xCm, ey - _yCm, ez - _zCm
      local d2 = dx * dx + dy * dy + dz * dz
      if d2 < nBestD2 then
        nBestD2 = d2
        nBest = nCand
      end
    end
  end
  return nBest
end

-- ---- exhibit outgoing ------------------------------------------------------------------------------------
local OnExhibitAnimalAdded = function(_tMessages)
  if type(_tMessages) ~= "table" or s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  local tWorld = api.world.GetWorldAPIs()
  for _, tMessage in ipairs(_tMessages) do
    if type(tMessage) == "table" and tMessage.nParentExhibitEntityID ~= nil and IsSafeSpecies(tMessage.sSpecies) then
      local x, y, z = EntityPosCm(tMessage.nParentExhibitEntityID)
      if x ~= nil then
        if tMessage.nAnimalID ~= nil then
          s.tExhibitAnimals[tMessage.nAnimalID] = {
            nExhibitID = tMessage.nParentExhibitEntityID,
            sSpecies = tMessage.sSpecies,
            x = x,
            y = y,
            z = z,
          }
        end
        if s.bSending and not Bridge.IsApplying() and not IsRemoteEcho("ex_add:" .. tMessage.sSpecies, x, y, z) then
          local bIsMale = true
          pcall(function()
            if tWorld.exhibits and tWorld.exhibits.IsAnimalMale and tMessage.nAnimalID ~= nil then
              bIsMale = tWorld.exhibits:IsAnimalMale(tMessage.nAnimalID) == true
            end
          end)
          BuildSync.Count("sent exhibit animal")
          Log(string.format("local exhibit animal add %s (%s) at (%.1f,%.1f,%.1f)", tMessage.sSpecies,
            bIsMale and "M" or "F", x / 100, y / 100, z / 100))
          Bridge.SendPacket(c_nAnimalEventPacket, nil, {
            k = "exhibit",
            op = "add",
            s = tMessage.sSpecies,
            m = bIsMale,
            x = x,
            y = y,
            z = z,
          })
        end
      end
    end
  end
end

local OnExhibitAnimalRemoved = function(_tMessages)
  if type(_tMessages) ~= "table" or s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  for _, tMessage in ipairs(_tMessages) do
    if type(tMessage) == "table" then
      local nAnimalID = tMessage.nAnimalID
      local tInfo = nAnimalID ~= nil and s.tExhibitAnimals[nAnimalID] or nil
      if nAnimalID ~= nil then
        s.tExhibitAnimals[nAnimalID] = nil
      end
      local nExhibitID = tMessage.ParentExhibitEntityID or tMessage.nParentExhibitEntityID or (tInfo and tInfo.nExhibitID)
      local sSpecies = IsSafeSpecies(tMessage.sSpecies) and tMessage.sSpecies or (tInfo and tInfo.sSpecies)
      local x, y, z = EntityPosCm(nExhibitID)
      if x == nil and tInfo ~= nil then
        x, y, z = tInfo.x, tInfo.y, tInfo.z
      end
      if s.bSending and not Bridge.IsApplying() and x ~= nil and IsSafeSpecies(sSpecies) and
        not IsRemoteEcho("ex_rem:" .. sSpecies, x, y, z) then
        BuildSync.Count("sent exhibit remove")
        Log(string.format("local exhibit animal remove %s at (%.1f,%.1f,%.1f)", sSpecies, x / 100, y / 100, z / 100))
        Bridge.SendPacket(c_nAnimalEventPacket, nil, {
          k = "exhibit",
          op = "remove",
          s = sSpecies,
          x = x,
          y = y,
          z = z,
        })
      end
    end
  end
end

-- ---- exhibit incoming ------------------------------------------------------------------------------------
local Job_ApplyExhibitAdd = function(_tData)
  if not IsSafeSpecies(_tData.s) then
    Log("dropped exhibit animal with invalid species " .. tostring(_tData.s))
    return
  end
  local nExhibitID = FindExhibitNear(_tData.x, _tData.y, _tData.z)
  if nExhibitID == nil then
    Log(string.format("remote exhibit add %s: no exhibit found near (%.1f,%.1f,%.1f)", _tData.s,
      _tData.x / 100, _tData.y / 100, _tData.z / 100))
    return
  end
  local bIsMale = _tData.m ~= false
  NoteRemote("ex_add:" .. _tData.s, _tData.x, _tData.y, _tData.z)
  BuildSync.Breadcrumb("apply exhibit animal " .. _tData.s .. " into exhibit " .. tostring(nExhibitID))
  Bridge.BeginApply()
  local bOk, sError = pcall(function()
    api.world.GetWorldAPIs().exhibits:AddAnimalToExhibit(nExhibitID, _tData.s, bIsMale)
  end)
  Bridge.EndApply()
  if not bOk then
    BuildSync.Count("exhibit animal failed")
    Log("remote exhibit animal add failed: " .. tostring(sError))
    return
  end
  BuildSync.Count("applied exhibit animal")
  Log("remote exhibit animal add " .. _tData.s .. " into exhibit " .. tostring(nExhibitID))
end

local Job_ApplyExhibitRemove = function(_tData)
  if not IsSafeSpecies(_tData.s) then
    Log("dropped exhibit remove with invalid species " .. tostring(_tData.s))
    return
  end
  local nExhibitID = FindExhibitNear(_tData.x, _tData.y, _tData.z)
  if nExhibitID == nil then
    Log(string.format("remote exhibit remove %s: no exhibit found near (%.1f,%.1f,%.1f)", _tData.s,
      _tData.x / 100, _tData.y / 100, _tData.z / 100))
    return
  end
  local exhibits = api.world.GetWorldAPIs().exhibits
  if exhibits == nil or exhibits.GetAnimalsInExhibit == nil or exhibits.AttemptToSendToTradeCentre == nil then
    return
  end
  NoteRemote("ex_rem:" .. _tData.s, _tData.x, _tData.y, _tData.z)
  BuildSync.Breadcrumb("apply exhibit remove " .. _tData.s .. " from exhibit " .. tostring(nExhibitID))
  Bridge.BeginApply()
  local bRemoved = false
  local bOk, sError = pcall(function()
    local tAnimals = exhibits:GetAnimalsInExhibit(nExhibitID)
    if type(tAnimals) ~= "table" then
      return
    end
    for _, tEntry in ipairs(tAnimals) do
      local nEnt = type(tEntry) == "table" and tEntry.nEntityID or tEntry
      if nEnt ~= nil then
        local sSp = exhibits.GetAnimalSpecies and exhibits:GetAnimalSpecies(nEnt) or _tData.s
        if sSp == _tData.s then
          local nUid = exhibits.ExhibitAnimalEntityIDToUID and exhibits:ExhibitAnimalEntityIDToUID(nEnt) or nEnt
          exhibits:AttemptToSendToTradeCentre(nUid)
          bRemoved = true
          break
        end
      end
    end
  end)
  Bridge.EndApply()
  if not bOk then
    BuildSync.Count("exhibit remove failed")
    Log("remote exhibit remove failed: " .. tostring(sError))
    return
  end
  if bRemoved then
    BuildSync.Count("applied exhibit remove")
    Log("remote exhibit remove " .. _tData.s .. " from exhibit " .. tostring(nExhibitID))
  end
end

-- ---- habitat animals (SyncUUID + macro events + 0x31 waypoints) ------------------------------------------
local ListHabitatAnimals = function()
  local tWorld = api.world.GetWorldAPIs()
  local dh = tWorld and tWorld.animalsDataHelpers
  if dh == nil or dh.GetAllAnimalEntities == nil then
    return nil, tWorld
  end
  local bOk, tAll = pcall(function()
    return dh:GetAllAnimalEntities(dh.AnimalListType_Habitat)
  end)
  if not bOk or type(tAll) ~= "table" then
    return nil, tWorld
  end
  return tAll, tWorld
end

local FindHabitatAnimal = function(_sSyncId, _sSpecies, _xCm, _yCm, _zCm)
  if IsSafeSyncId(_sSyncId) then
    local nExact = s.tBySyncId[_sSyncId]
    if nExact ~= nil and s.tHabitatKnown[nExact] ~= nil then
      return nExact
    end
  end
  local tAll, tWorld = ListHabitatAnimals()
  if tAll == nil or tWorld.animals == nil then
    return nil
  end
  local nBest, nBestD2 = nil, math.huge
  for _, nEntityID in ipairs(tAll) do
    local bSpOk, sSp = pcall(tWorld.animals.GetSpecies, tWorld.animals, nEntityID)
    if bSpOk and sSp == _sSpecies then
      local ax, ay, az = EntityPosCm(nEntityID)
      if ax ~= nil then
        local dx, dy, dz = ax - _xCm, ay - _yCm, az - _zCm
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 < nBestD2 then
          nBestD2 = d2
          nBest = nEntityID
        end
      end
    end
  end
  return nBest
end

local PollHabitatAnimals = function()
  local tAll, tWorld = ListHabitatAnimals()
  local animals = tWorld and tWorld.animals
  if tAll == nil or animals == nil then
    return
  end
  local tCurrent = {}
  for _, nEntityID in ipairs(tAll) do
    tCurrent[nEntityID] = true
  end

  if not s.bHabitatSeeded then
    s.bHabitatSeeded = true
    for _, nEntityID in ipairs(tAll) do
      local bSp, sSp = pcall(animals.GetSpecies, animals, nEntityID)
      local ax, ay, az = EntityPosCm(nEntityID)
      if bSp and IsSafeSpecies(sSp) and ax ~= nil then
        local bCOk, bContra = pcall(function()
          return animals.IsUsingContraceptive and animals:IsUsingContraceptive(nEntityID) == true or false
        end)
        s.nSeq = s.nSeq + 1
        local sSyncId = string.format("%s_%d", sSp, s.nSeq)
        s.tHabitatKnown[nEntityID] = {sSyncId = sSyncId, sSpecies = sSp, bContra = bCOk and bContra == true,
          x = ax, y = ay, z = az}
        s.tBySyncId[sSyncId] = nEntityID
      end
    end
    return
  end

  -- Removed habitat animals
  for nEntityID, tInfo in pairs(s.tHabitatKnown) do
    if not tCurrent[nEntityID] then
      s.tHabitatKnown[nEntityID] = nil
      if s.tBySyncId[tInfo.sSyncId] == nEntityID then
        s.tBySyncId[tInfo.sSyncId] = nil
      end
      if s.bSending and not Bridge.IsApplying() and not IsRemoteEcho("hab_rem:" .. tInfo.sSpecies, tInfo.x, tInfo.y, tInfo.z) then
        BuildSync.Count("sent animal remove")
        Bridge.SendPacket(c_nAnimalEventPacket, nil, {
          k = "animal",
          op = "remove",
          id = tInfo.sSyncId,
          s = tInfo.sSpecies,
          x = tInfo.x,
          y = tInfo.y,
          z = tInfo.z,
        })
      end
    end
  end

  -- Updated / newly tracked habitat animals
  for nEntityID in pairs(tCurrent) do
    local tInfo = s.tHabitatKnown[nEntityID]
    local ax, ay, az = EntityPosCm(nEntityID)
    if tInfo == nil then
      local bSp, sSp = pcall(animals.GetSpecies, animals, nEntityID)
      if bSp and IsSafeSpecies(sSp) and ax ~= nil then
        local bCOk, bContra = pcall(function()
          return animals.IsUsingContraceptive and animals:IsUsingContraceptive(nEntityID) == true or false
        end)
        s.nSeq = s.nSeq + 1
        local sSyncId = string.format("%s_%d", sSp, s.nSeq)
        s.tHabitatKnown[nEntityID] = {sSyncId = sSyncId, sSpecies = sSp, bContra = bCOk and bContra == true,
          x = ax, y = ay, z = az}
        s.tBySyncId[sSyncId] = nEntityID
      end
    else
      if ax ~= nil then
        tInfo.x, tInfo.y, tInfo.z = ax, ay, az
      end
      local bCOk, bContra = pcall(function()
        return animals.IsUsingContraceptive and animals:IsUsingContraceptive(nEntityID) == true or false
      end)
      if bCOk and (bContra == true) ~= tInfo.bContra then
        tInfo.bContra = bContra == true
        if s.bSending and not Bridge.IsApplying() and
          not IsRemoteEcho("hab_contra:" .. tInfo.sSpecies, tInfo.x, tInfo.y, tInfo.z) then
          BuildSync.Count("sent animal contraceptive")
          Bridge.SendPacket(c_nAnimalEventPacket, nil, {
            k = "animal",
            op = "contraceptive",
            id = tInfo.sSyncId,
            s = tInfo.sSpecies,
            v = tInfo.bContra,
            x = tInfo.x,
            y = tInfo.y,
            z = tInfo.z,
          })
        end
      end
    end
  end
end

-- Host broadcasts compact 0x31 animal waypoint / identity sync so clients maintain SyncUUID mappings.
local SendWaypointsIfHost = function()
  if Bridge.GetRole() ~= "host" or not (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    return
  end
  local tList = setmetatable({}, api.json and api.json.GetArrayMetatable and api.json.GetArrayMetatable() or nil)
  local nCount = 0
  for _, tInfo in pairs(s.tHabitatKnown) do
    nCount = nCount + 1
    if nCount > c_nMaxWaypointsPerPacket then
      break
    end
    table.insert(tList, {id = tInfo.sSyncId, s = tInfo.sSpecies, x = tInfo.x, y = tInfo.y, z = tInfo.z})
  end
  if nCount > 0 then
    Bridge.SendPacket(c_nWaypointPacket, nil, {k = "waypoints", a = tList})
  end
end

local ApplyWaypoints = function(_tData)
  if type(_tData.a) ~= "table" then
    return
  end
  for i = 1, math.min(#_tData.a, c_nMaxWaypointsPerPacket) do
    local tEntry = _tData.a[i]
    if type(tEntry) == "table" and IsSafeSyncId(tEntry.id) and IsSafeSpecies(tEntry.s) and
      IsFinite(tEntry.x) and IsFinite(tEntry.y) and IsFinite(tEntry.z) then
      local nTarget = FindHabitatAnimal(tEntry.id, tEntry.s, tEntry.x, tEntry.y, tEntry.z)
      if nTarget ~= nil then
        local tKnown = s.tHabitatKnown[nTarget]
        if tKnown ~= nil and tKnown.sSyncId ~= tEntry.id then
          if s.tBySyncId[tKnown.sSyncId] == nTarget then
            s.tBySyncId[tKnown.sSyncId] = nil
          end
          tKnown.sSyncId = tEntry.id
          s.tBySyncId[tEntry.id] = nTarget
        end
      end
    end
  end
end

local Job_ApplyHabitatAnimal = function(_tData)
  if not IsSafeSpecies(_tData.s) then
    return
  end
  local nTarget = FindHabitatAnimal(_tData.id, _tData.s, _tData.x, _tData.y, _tData.z)
  if nTarget == nil then
    Log("remote animal " .. tostring(_tData.op) .. ": no matching " .. _tData.s .. " found")
    return
  end
  local animals = api.world.GetWorldAPIs().animals
  if animals == nil then
    return
  end
  if _tData.op == "contraceptive" then
    NoteRemote("hab_contra:" .. _tData.s, _tData.x, _tData.y, _tData.z)
    Bridge.BeginApply()
    local bOk = pcall(animals.SetUsingContraceptive, animals, nTarget, _tData.v == true)
    Bridge.EndApply()
    if bOk then
      if s.tHabitatKnown[nTarget] ~= nil then
        s.tHabitatKnown[nTarget].bContra = _tData.v == true
      end
      BuildSync.Count("applied animal contraceptive")
    end
  elseif _tData.op == "remove" then
    NoteRemote("hab_rem:" .. _tData.s, _tData.x, _tData.y, _tData.z)
    Bridge.BeginApply()
    local bOk = pcall(animals.RemoveAnimal, animals, nTarget)
    Bridge.EndApply()
    if bOk then
      local tInfo = s.tHabitatKnown[nTarget]
      if tInfo ~= nil and s.tBySyncId[tInfo.sSyncId] == nTarget then
        s.tBySyncId[tInfo.sSyncId] = nil
      end
      s.tHabitatKnown[nTarget] = nil
      BuildSync.Count("applied animal remove")
    end
  end
end

-- ---- module API ------------------------------------------------------------------------------------------
AnimalSync.Install = function()
  if s.bInstalled then
    return
  end
  s.nStartedAt = s.nClock
  s.bHabitatSeeded = false
  s.nHabitatTimer = 0
  s.nWaypointTimer = 0
  s.tRecentRemote = {}
  s.tExhibitAnimals = {}
  s.tHabitatKnown = {}
  s.tBySyncId = {}
  local nAddMsg = api.messaging.MsgType_ExhibitAnimalAddedMessage
  if nAddMsg ~= nil then
    s.fnAddedReceiver = function(_tMessages)
      local bOk, sError = pcall(OnExhibitAnimalAdded, _tMessages)
      if not bOk then
        Log("added receiver error: " .. tostring(sError))
      end
    end
    api.messaging.RegisterReceiver(nAddMsg, s.fnAddedReceiver)
  end
  local nRemMsg = api.messaging.MsgType_ExhibitAnimalRemovedMessage
  if nRemMsg ~= nil then
    s.fnRemovedReceiver = function(_tMessages)
      local bOk, sError = pcall(OnExhibitAnimalRemoved, _tMessages)
      if not bOk then
        Log("removed receiver error: " .. tostring(sError))
      end
    end
    api.messaging.RegisterReceiver(nRemMsg, s.fnRemovedReceiver)
  end
  s.bInstalled = true
  Log("installed")
end

AnimalSync.Uninstall = function()
  if s.fnAddedReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_ExhibitAnimalAddedMessage, s.fnAddedReceiver)
    s.fnAddedReceiver = nil
  end
  if s.fnRemovedReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_ExhibitAnimalRemovedMessage, s.fnRemovedReceiver)
    s.fnRemovedReceiver = nil
  end
  s.bInstalled = false
end

AnimalSync.ResetSnapshot = function()
  s.tRecentRemote = {}
  s.tExhibitAnimals = {}
  s.tHabitatKnown = {}
  s.tBySyncId = {}
  s.bHabitatSeeded = false
  s.nStartedAt = s.nClock
end

AnimalSync.Update = function(_nDt, _bSending)
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
  if s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  s.nHabitatTimer = s.nHabitatTimer + _nDt
  if s.nHabitatTimer >= c_nHabitatPollInterval then
    s.nHabitatTimer = 0
    pcall(PollHabitatAnimals)
  end
  s.nWaypointTimer = s.nWaypointTimer + _nDt
  if s.nWaypointTimer >= c_nWaypointInterval then
    s.nWaypointTimer = 0
    pcall(SendWaypointsIfHost)
  end
end

AnimalSync.HasSyncId = function(_sSyncId)
  return s.tBySyncId[_sSyncId] ~= nil
end

AnimalSync.OnPacket = function(_tMsg)
  if _tMsg.nType == c_nWaypointPacket and type(_tMsg.tData) == "table" and _tMsg.tData.k == "waypoints" then
    pcall(ApplyWaypoints, _tMsg.tData)
    return true
  end
  if _tMsg.nType ~= c_nAnimalEventPacket or type(_tMsg.tData) ~= "table" then
    return false
  end
  local d = _tMsg.tData
  if d.k == "exhibit" then
    if not (IsFinite(d.x) and IsFinite(d.y) and IsFinite(d.z)) then
      Log("exhibit animal packet without position dropped")
      return true
    end
    if d.op == "add" then
      BuildSync.QueueJob(function() Job_ApplyExhibitAdd(d) end)
    elseif d.op == "remove" then
      BuildSync.QueueJob(function() Job_ApplyExhibitRemove(d) end)
    else
      Log("unknown exhibit animal op " .. tostring(d.op))
    end
    return true
  elseif d.k == "animal" then
    if not (IsFinite(d.x) and IsFinite(d.y) and IsFinite(d.z)) then
      return true
    end
    if d.op == "contraceptive" or d.op == "remove" then
      BuildSync.QueueJob(function() Job_ApplyHabitatAnimal(d) end)
    end
    return true
  end
  return false
end
