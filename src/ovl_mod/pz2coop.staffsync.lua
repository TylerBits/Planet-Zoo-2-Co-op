-- Staff sync: hires and fires staff members across peers using vanilla StaffPlacementMode / StaffUtils APIs.
--   detect:  MsgType_StaffCreatedOrDestroyedMessage ({staffEntityID, bCreated}) + StaffPlacementMode._CommitStaffMember
--            wrap so preview ghosts held on the cursor are never sent before the player places them.
--   address: deterministic SyncUUID (staff type + quantized placement position + sequence) for hired staff,
--            plus nearest-of-type spatial fallback for pre-existing staff loaded from the baseline save.
--   apply:   hire = StaffPlacementMode recipe (InstantiatePrefab with whitelisted staff type -> wait token ->
--            SetPosition -> SetStaffMemberSuspended(false) -> IncreasePriorityOfNearestApplicableJobInRange);
--            fire = staff:FireStaffMember(entityID). Neither touches api.undo change lists.
-- Packet 0x30 (ACTION_ANIMAL_EVENT, JSON): {k = "staff", op = "hire"|"fire", t = staffType, id = syncId, x, y, z (cm)}.
local global = _G
local api = global.api
local string = global.string
local table = global.table
local math = global.math
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local error = global.error
local tostring = global.tostring
local type = global.type
local rawget = global.rawget
local rawset = global.rawset
local coroutine = global.coroutine
local require = global.require
local Vector3 = require("Vector3")
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local StaffSync = module(...)

local c_nAnimalEventPacket = 0x30
local c_nStartupIgnore = 5.0
local c_nSpawnTimeout = 10.0
local c_nEchoWindow = 10.0
local c_nEchoRadiusCm = 250 -- 2.5 m
local c_nLogLimit = 300

-- Vanilla staff prefab types (helpers.staffutils.lua:34). Trust boundary: only these may be spawned.
local c_tValidTypes = {
  Keeper = true,
  Mechanic = true,
  Vet = true,
  Janitor = true,
  Vendor = true,
  Presenter = true,
}

local s = {
  bInstalled = false,
  bSeeded = false,
  bSending = false,
  nClock = 0,
  nStartedAt = 0,
  nSeq = 0,
  nLogs = 0,
  fnReceiver = nil,
  tKnown = {}, -- entityID -> {sType, sSyncId, x, y, z (cm), bRemote}
  tBySyncId = {}, -- sSyncId -> entityID
  tPending = {}, -- entityID -> {nSince = clock, bCommitted = bool} (waiting for preview placement to finish)
  tRemoteSpawns = {}, -- entityID -> true (entities currently being spawned by us)
  tRecentRemote = {}, -- {sType, x, y, z, nTime}
}

local Log = function(_s)
  if s.nLogs < c_nLogLimit then
    s.nLogs = s.nLogs + 1
    Bridge.Log("staff sync: " .. _s)
  end
end

local Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

local IsFinite = function(_n)
  return type(_n) == "number" and _n == _n and _n > -1e7 and _n < 1e7
end

local IsSafeSyncId = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_%-]+$") ~= nil
end

local StaffPosCm = function(_nEntityID)
  local tWorld = api.world.GetWorldAPIs()
  local bOk, vPos = pcall(function()
    local tr = tWorld.transform:CalculateWorldTransform(_nEntityID)
    return tr and (tr.GetPos and tr:GetPos() or tr:Pos())
  end)
  if not bOk or vPos == nil then
    return nil
  end
  local bCoords, x, y, z = pcall(function()
    return vPos:GetX(), vPos:GetY(), vPos:GetZ()
  end)
  if bCoords and IsFinite(x) and IsFinite(y) and IsFinite(z) then
    return Cm(x), Cm(y), Cm(z)
  end
  return nil
end

local StaffTypeOf = function(_nEntityID)
  local bOk, sType = pcall(function()
    local StaffUtils = require("Helpers.StaffUtils")
    return StaffUtils.GetStaffType(api.world.GetWorldAPIs().staff, _nEntityID)
  end)
  if bOk and c_tValidTypes[sType] then
    return sType
  end
  return nil
end

local IsStaffAlive = function(_nEntityID)
  local bOk, tAll = pcall(function()
    return api.world.GetWorldAPIs().staff:GetAllStaffEntities()
  end)
  if not bOk or type(tAll) ~= "table" then
    return false
  end
  for _, id in ipairs(tAll) do
    if id == _nEntityID then
      return true
    end
  end
  return false
end

local NoteRemote = function(_sType, _x, _y, _z)
  table.insert(s.tRecentRemote, {sType = _sType, x = _x, y = _y, z = _z, nTime = s.nClock})
end

local IsRemoteEcho = function(_sType, _x, _y, _z)
  local nR2 = c_nEchoRadiusCm * c_nEchoRadiusCm
  for _, tEntry in ipairs(s.tRecentRemote) do
    if tEntry.sType == _sType then
      local dx, dy, dz = tEntry.x - _x, tEntry.y - _y, tEntry.z - _z
      if dx * dx + dy * dy + dz * dz <= nR2 then
        return true
      end
    end
  end
  return false
end

local RegisterKnown = function(_nEntityID, _sType, _x, _y, _z, _sSyncId, _bRemote)
  local tOld = s.tKnown[_nEntityID]
  if tOld ~= nil and tOld.sSyncId ~= nil then
    s.tBySyncId[tOld.sSyncId] = nil
  end
  s.tKnown[_nEntityID] = {sType = _sType, sSyncId = _sSyncId, x = _x, y = _y, z = _z, bRemote = _bRemote == true}
  if _sSyncId ~= nil then
    s.tBySyncId[_sSyncId] = _nEntityID
  end
end

local SeedExisting = function()
  local bOk, tAll = pcall(function()
    return api.world.GetWorldAPIs().staff:GetAllStaffEntities()
  end)
  if not bOk or type(tAll) ~= "table" then
    return
  end
  local nCount = 0
  for _, nEntityID in ipairs(tAll) do
    local sType = StaffTypeOf(nEntityID)
    local x, y, z = StaffPosCm(nEntityID)
    if sType ~= nil and x ~= nil then
      RegisterKnown(nEntityID, sType, x, y, z, nil, false)
      nCount = nCount + 1
    end
  end
  s.bSeeded = true
  Log("seeded " .. nCount .. " existing staff")
end

-- ---- StaffPlacementMode._CommitStaffMember wrap ----------------------------------------------------------
-- Marks newly hired staff as committed immediately on click (supports multi-placement without exiting mode).
local InstallPlacementWrap = function()
  local bOk, StaffPlacementMode = pcall(require, "Editors.Staff.StaffPlacementMode")
  if not bOk or type(StaffPlacementMode) ~= "table" or rawget(StaffPlacementMode, "__PZ2CoopOriginalCommit") ~= nil then
    return
  end
  local fnOriginal = StaffPlacementMode._CommitStaffMember
  if type(fnOriginal) ~= "function" then
    return
  end
  rawset(StaffPlacementMode, "__PZ2CoopOriginalCommit", fnOriginal)
  StaffPlacementMode._CommitStaffMember = function(self, _vFinalPos, ...)
    local nEntityID = self.staffEntityID
    local bNew = self.bCreateNew == true
    local r = fnOriginal(self, _vFinalPos, ...)
    if bNew and nEntityID ~= nil and not Bridge.IsApplying() then
      s.tPending[nEntityID] = {nSince = s.nClock, bCommitted = true}
    end
    return r
  end
  Log("wrapped StaffPlacementMode._CommitStaffMember")
end

-- ---- outgoing --------------------------------------------------------------------------------------------
local EmitHire = function(_nEntityID)
  local sType = StaffTypeOf(_nEntityID)
  local x, y, z = StaffPosCm(_nEntityID)
  if sType == nil or x == nil then
    return
  end
  if IsRemoteEcho(sType, x, y, z) then
    RegisterKnown(_nEntityID, sType, x, y, z, nil, true)
    return
  end
  s.nSeq = s.nSeq + 1
  local sSyncId = string.format("%s_%d_%d_%d_%d", sType, x, y, z, s.nSeq)
  RegisterKnown(_nEntityID, sType, x, y, z, sSyncId, false)
  if not s.bSending then
    return
  end
  BuildSync.Count("sent staff hire")
  Log(string.format("local staff hire %s (id %s) at (%.1f,%.1f,%.1f)", sType, sSyncId, x / 100, y / 100, z / 100))
  Bridge.SendPacket(c_nAnimalEventPacket, nil, {
    k = "staff",
    op = "hire",
    t = sType,
    id = sSyncId,
    x = x,
    y = y,
    z = z,
  })
end

local EmitFire = function(_nEntityID)
  local tInfo = s.tKnown[_nEntityID]
  if tInfo == nil then
    return
  end
  s.tKnown[_nEntityID] = nil
  if tInfo.sSyncId ~= nil and s.tBySyncId[tInfo.sSyncId] == _nEntityID then
    s.tBySyncId[tInfo.sSyncId] = nil
  end
  if not s.bSending or Bridge.IsApplying() then
    return
  end
  local x, y, z = StaffPosCm(_nEntityID)
  x, y, z = x or tInfo.x, y or tInfo.y, z or tInfo.z
  BuildSync.Count("sent staff fire")
  Log(string.format("local staff fire %s (id %s)", tInfo.sType, tostring(tInfo.sSyncId or _nEntityID)))
  Bridge.SendPacket(c_nAnimalEventPacket, nil, {
    k = "staff",
    op = "fire",
    t = tInfo.sType,
    id = tInfo.sSyncId,
    x = x,
    y = y,
    z = z,
    p = tInfo.bRemote and 1 or nil,
  })
end

local OnStaffMessage = function(_tMessages)
  if type(_tMessages) ~= "table" or s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  for _, tMessage in ipairs(_tMessages) do
    if type(tMessage) == "table" and tMessage.staffEntityID ~= nil then
      local nId = tMessage.staffEntityID
      if tMessage.bCreated then
        if not Bridge.IsApplying() and not s.tRemoteSpawns[nId] and s.tKnown[nId] == nil then
          s.tPending[nId] = s.tPending[nId] or {nSince = s.nClock, bCommitted = false}
        end
      else
        if s.tPending[nId] ~= nil then
          s.tPending[nId] = nil -- cancelled preview ghost, never committed
        elseif not Bridge.IsApplying() then
          EmitFire(nId)
        else
          local tInfo = s.tKnown[nId]
          if tInfo ~= nil and tInfo.sSyncId ~= nil then
            s.tBySyncId[tInfo.sSyncId] = nil
          end
          s.tKnown[nId] = nil
        end
      end
    end
  end
end

-- ---- incoming (apply) ------------------------------------------------------------------------------------
-- Vanilla recipe: StaffPlacementMode.TransitionIn + _CommitStaffMember (editors.staff.staffplacementmode.lua:72, 310).
local Job_ApplyHire = function(_tData)
  local sType = _tData.t
  if not c_tValidTypes[sType] then
    Log("dropped staff hire with invalid type " .. tostring(sType))
    return
  end
  local x, y, z = _tData.x, _tData.y, _tData.z
  local sSyncId = IsSafeSyncId(_tData.id) and _tData.id or nil
  local vPos = Vector3:new(x / 100, y / 100, z / 100)
  NoteRemote(sType, x, y, z)
  BuildSync.Breadcrumb(string.format("apply staff hire %s at %.1f,%.1f,%.1f", sType, x / 100, y / 100, z / 100))

  Bridge.BeginApply()
  local nEntityID = nil
  local bOk, sError = pcall(function()
    local token = api.entity.CreateRequestCompletionToken()
    nEntityID = api.entity.InstantiatePrefab(sType, nil, token, nil, nil, nil, {
      CompletionToken = token,
      IsPreview = true,
      Suspended = true,
    })
    if nEntityID == nil then
      error("InstantiatePrefab returned nil")
    end
    s.tRemoteSpawns[nEntityID] = true
    local nStart = s.nClock
    while not api.entity.HaveRequestsCompleted(token) do
      if s.nClock - nStart > c_nSpawnTimeout then
        error("staff spawn timed out")
      end
      coroutine.yield()
    end
    local tWorld = api.world.GetWorldAPIs()
    tWorld.transform:SetPosition(nEntityID, vPos)
    tWorld.staff:SetStaffMemberSuspended(nEntityID, false)
    pcall(function()
      tWorld.staff:IncreasePriorityOfNearestApplicableJobInRange(nEntityID)
    end)
  end)
  Bridge.EndApply()
  if nEntityID ~= nil then
    s.tRemoteSpawns[nEntityID] = nil
  end
  if not bOk then
    if nEntityID ~= nil then
      pcall(api.entity.DestroyEntity, nEntityID)
    end
    BuildSync.Count("staff hire failed")
    Log("remote staff hire failed: " .. tostring(sError))
    return
  end
  RegisterKnown(nEntityID, sType, x, y, z, sSyncId, true)
  BuildSync.Count("applied staff hire")
  Log(string.format("remote staff hire %s (entity %s, id %s) at (%.1f,%.1f,%.1f)", sType, tostring(nEntityID),
    tostring(sSyncId), x / 100, y / 100, z / 100))
end

-- Finds the matching staff member by SyncUUID first, else nearest living staff of the same type.
local FindStaffToFire = function(_tData)
  if IsSafeSyncId(_tData.id) then
    local nExact = s.tBySyncId[_tData.id]
    if nExact ~= nil and IsStaffAlive(nExact) then
      return nExact
    end
  end
  local bOk, tAll = pcall(function()
    return api.world.GetWorldAPIs().staff:GetAllStaffEntities()
  end)
  if not bOk or type(tAll) ~= "table" then
    return nil
  end
  local nBest, nBestD2 = nil, math.huge
  for _, nEntityID in ipairs(tAll) do
    if StaffTypeOf(nEntityID) == _tData.t then
      local sx, sy, sz = StaffPosCm(nEntityID)
      if sx ~= nil then
        local dx, dy, dz = sx - _tData.x, sy - _tData.y, sz - _tData.z
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

local Job_ApplyFire = function(_tData)
  if not c_tValidTypes[_tData.t] then
    Log("dropped staff fire with invalid type " .. tostring(_tData.t))
    return
  end
  local nTarget = FindStaffToFire(_tData)
  if nTarget == nil then
    Log("remote staff fire: no matching " .. tostring(_tData.t) .. " found")
    return
  end
  BuildSync.Breadcrumb("apply staff fire " .. tostring(_tData.t) .. " entity " .. tostring(nTarget))
  Bridge.BeginApply()
  local bOk, sError = pcall(function()
    api.world.GetWorldAPIs().staff:FireStaffMember(nTarget)
  end)
  Bridge.EndApply()
  if not bOk then
    BuildSync.Count("staff fire failed")
    Log("remote staff fire failed: " .. tostring(sError))
    return
  end
  local tInfo = s.tKnown[nTarget]
  if tInfo ~= nil and tInfo.sSyncId ~= nil then
    s.tBySyncId[tInfo.sSyncId] = nil
  end
  s.tKnown[nTarget] = nil
  BuildSync.Count("applied staff fire")
  Log("remote staff fire " .. tostring(_tData.t) .. " entity " .. tostring(nTarget))
end

-- ---- module API ------------------------------------------------------------------------------------------
StaffSync.Install = function()
  if s.bInstalled then
    return
  end
  s.bSeeded = false
  s.nStartedAt = s.nClock
  s.tKnown = {}
  s.tBySyncId = {}
  s.tPending = {}
  s.tRemoteSpawns = {}
  s.tRecentRemote = {}
  InstallPlacementWrap()
  local nMsg = api.messaging.MsgType_StaffCreatedOrDestroyedMessage
  if nMsg ~= nil then
    s.fnReceiver = function(_tMessages)
      local bOk, sError = pcall(OnStaffMessage, _tMessages)
      if not bOk then
        Log("receiver error: " .. tostring(sError))
      end
    end
    api.messaging.RegisterReceiver(nMsg, s.fnReceiver)
  end
  s.bInstalled = true
  Log("installed")
end

StaffSync.Uninstall = function()
  if s.fnReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_StaffCreatedOrDestroyedMessage, s.fnReceiver)
    s.fnReceiver = nil
  end
  s.bInstalled = false
  s.bSeeded = false
  s.tKnown = {}
  s.tBySyncId = {}
  s.tPending = {}
end

StaffSync.ResetSnapshot = function()
  s.bSeeded = false
  s.tKnown = {}
  s.tBySyncId = {}
  s.tPending = {}
  s.tRemoteSpawns = {}
  s.tRecentRemote = {}
  s.nStartedAt = s.nClock
end

StaffSync.Update = function(_nDt, _bSending)
  if not s.bInstalled then
    return
  end
  s.nClock = s.nClock + _nDt
  s.bSending = _bSending
  InstallPlacementWrap()
  for i = #s.tRecentRemote, 1, -1 do
    if s.nClock - s.tRecentRemote[i].nTime > c_nEchoWindow then
      table.remove(s.tRecentRemote, i)
    end
  end
  if not s.bSeeded and s.nClock >= s.nStartedAt + c_nStartupIgnore then
    SeedExisting()
    return
  end
  if Bridge.IsApplying() then
    return
  end
  local bInPlaceTool = BuildSync.GetTool() == "StaffMovement"
  local tReady = {}
  for nEntityID, tPend in pairs(s.tPending) do
    if tPend.bCommitted or (not bInPlaceTool and s.nClock - tPend.nSince >= 0.25) then
      table.insert(tReady, nEntityID)
    end
  end
  for _, nEntityID in ipairs(tReady) do
    s.tPending[nEntityID] = nil
    if s.tKnown[nEntityID] == nil and IsStaffAlive(nEntityID) then
      local bOk, sError = pcall(EmitHire, nEntityID)
      if not bOk then
        Log("emit hire error: " .. tostring(sError))
      end
    end
  end
end

StaffSync.HasSyncId = function(_sSyncId)
  return s.tBySyncId[_sSyncId] ~= nil
end

StaffSync.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nAnimalEventPacket or type(_tMsg.tData) ~= "table" or _tMsg.tData.k ~= "staff" then
    return false
  end
  local d = _tMsg.tData
  if not (IsFinite(d.x) and IsFinite(d.y) and IsFinite(d.z)) then
    Log("staff packet without position dropped")
    return true
  end
  if d.op == "hire" then
    BuildSync.QueueJob(function() Job_ApplyHire(d) end)
  elseif d.op == "fire" then
    BuildSync.QueueJob(function() Job_ApplyFire(d) end)
  else
    Log("unknown staff op " .. tostring(d.op))
  end
  return true
end
