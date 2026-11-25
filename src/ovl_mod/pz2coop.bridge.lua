-- Lua <-> version.dll transport: a Lua table used as shared memory (src/proxy_dll/mem_bridge.hpp).
-- Retail PZ2 stubs api.debug file I/O and Lua HTTP, so the DLL instead finds this table's array part in
-- process memory (by its magic values) and both sides exchange text lines through two integer rings.
-- Lines use the protocol in src/proxy_dll/file_bridge.hpp ({"cmd":...} / "<type> <file|-> <json>").
local global = _G
local api = global.api
local string = global.string
local table = global.table
local math = global.math
local tostring = global.tostring
local tonumber = global.tonumber
local pairs = global.pairs
local ipairs = global.ipairs
local type = global.type
local rawget = global.rawget
local rawset = global.rawset

-- Like vanilla modules, every global is captured above: module() replaces the environment.
local Bridge = module(...)

local c_nMagic = 0x5A32434F4F500000
local c_nVersion = 1
local c_nRing = 8192
local c_nHeader = 16
local c_nTotal = c_nHeader + 2 * c_nRing
local c_nSlotClaim, c_nSlotBeat, c_nSlotVersion = 5, 6, 7
local c_nSlotOutHead, c_nSlotOutTail, c_nSlotInHead, c_nSlotInTail = 9, 10, 11, 12
local c_nOutData = c_nHeader + 1
local c_nInData = c_nOutData + c_nRing
local c_nFlushInterval = 0.05
local c_nHeartbeat = 1.0
local c_nMaxPendingLines = 4000
-- ponytail: engine-side file APIs (SaveParkToFile, blueprints) take paths whose root is still unverified;
-- version.dll's diag.log records the real path the first time one is used.
local c_sEnginePrefix = "/run/PZ2Coop/"
-- Solo test mode (Bridge.SetLoopback): mirror offset and a cap so a leaking echo cannot loop forever.
local c_nLoopOffsetCm = 5000 -- 50 m: wider than the prefab aquariums (29 m)
local c_nLoopLimit = 200
local c_nHandshakeHello, c_nSaveChunkData, c_nSaveLoadCommit, c_nCursor, c_nLedgerSync, c_nPresenceAvatar = 0x01, 0x02, 0x03, 0x10, 0x11, 0x12
local c_sModVersion = "0.3.0"
-- Offline/local park modes supported in co-op. Franchise is strictly excluded (CLAUDE.md rules 6 & 8).
local c_tAllowedModes = {
  Sandbox = true,
  Challenge = true,
  ScenarioCareer = true,
  ScenarioChallenge = true,
  WildArea = true,
}
local c_tAllowedDiffs = {
  Easy = true,
  Default = true,
  Hard = true,
}

-- One state per Lua VM, kept in _G so it survives module reloads (the game can re-run its database
-- init) as well as world changes: the DLL keeps its claim on this one table for the whole process.
local s = rawget(global, "__PZ2CoopBridgeState")
if s == nil then
  s = {
    t = nil,
    bCodecOk = nil,
    sSid = nil,
    bNeedHello = false,
    nOutHead = 0,
    nInTail = 0,
    sRx = "",
    tOutLines = {},
    nFlushTimer = 0,
    nSinceWrite = 0,
    bApplying = false,
    sRole = "none",
    bPeerConnected = false,
    fnHandler = nil,
    bAnnounced = false,
  }
  rawset(global, "__PZ2CoopBridgeState", s)
end

-- 8 bytes <-> one Lua integer, little-endian, with plain integer arithmetic (Lua 5.3 integer
-- multiplication wraps; % and // floor, which extracts bytes correctly from negative values too).
local Pack8 = function(_s, _i)
  local v = 0
  for k = _i + 7, _i, -1 do
    v = v * 256 + string.byte(_s, k)
  end
  return v
end

local Unpack8 = function(_v)
  local b = {}
  for k = 1, 8 do
    local n = _v % 256
    b[k] = n
    _v = (_v - n) // 256
  end
  return string.char(b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
end

local CodecSelfTest = function()
  local sProbe = "\255\254\128\001\000\127\200\009"
  return math.type(256) == "integer" and Unpack8(Pack8(sProbe, 1)) == sProbe
end

local Encode = function(_tData)
  local bOk, sJson = api.json.Stringify(_tData or {})
  if not bOk or sJson == nil or sJson == "" or sJson == "[]" then
    sJson = "{}"
  end
  return (string.gsub(sJson, "[\r\n]", " "))
end

local Decode = function(_sJson)
  local bOk, tData = api.json.Parse(_sJson)
  if bOk and type(tData) == "table" then
    return tData
  end
  return nil
end

local Queue = function(_sLine)
  if #s.tOutLines < c_nMaxPendingLines then
    table.insert(s.tOutLines, _sLine)
  end
end

Bridge.GetPrefix = function()
  return c_sEnginePrefix
end

Bridge.GetTableId = function()
  return tostring(s.t)
end

Bridge.IsOpen = function()
  return s.sSid ~= nil
end

-- True once version.dll has found and claimed the shared table.
Bridge.IsConnected = function()
  return s.t ~= nil and s.t[c_nSlotClaim] ~= 0
end

-- Creates the shared table once per Lua state and starts a fresh protocol session.
Bridge.Open = function()
  if s.bCodecOk == nil then
    s.bCodecOk = CodecSelfTest()
  end
  if not s.bCodecOk then
    return false
  end
  if s.t == nil then
    local t = {}
    for i = 1, c_nTotal do
      t[i] = 0 -- sequential fill: everything lives in the array part, allocated once
    end
    t[c_nSlotVersion] = c_nVersion
    for i = 1, 4 do
      t[i] = c_nMagic + i -- written last, so no discarded, smaller array copy ever held the magic
    end
    s.t = t
  end
  local nNow = api.time.GetTotalTimeUnscaled()
  s.sSid = "s" .. string.format("%.0f", (nNow * 1000) % 1000000000) .. string.format("%06d", math.random(0, 999999))
  s.bNeedHello = true
  s.bApplying = false
  return true
end

Bridge.Close = function()
  if s.sSid ~= nil and s.bApplying then
    Bridge.EndApply()
  end
  Bridge.Flush(true)
  s.sSid = nil
end

Bridge.SendCommand = function(_sCmd, _tExtra)
  local tMsg = {cmd = _sCmd}
  for k, v in pairs(_tExtra or {}) do
    tMsg[k] = v
  end
  Queue(Encode(tMsg))
end

-- Lua's only log channel in retail: lands in <game>/PZ2Coop/diag.log as "lua: ...".
Bridge.Log = function(_sMessage)
  Bridge.SendCommand("diag", {msg = (string.gsub(tostring(_sMessage), "[\"\\]", "'"))})
end

-- CLAUDE.md rule 2: player actions (type >= 0x20) are never sent while a remote action is replayed.
Bridge.SendPacket = function(_nType, _sFile, _tData)
  if s.sSid == nil then
    return false
  end
  if _nType >= 0x20 and s.bApplying then
    return false
  end
  Queue(string.format("%d %s %s", _nType, _sFile or "-", Encode(_tData)))
  -- Solo test mode: the packet also comes back as if a friend sent it, so the receive path runs without a
  -- second player. Builds are shifted c_nLoopOffsetCm east; the ledger comes back as is; a baseline save
  -- (0x02) comes back as the load commit (0x03) the DLL would hand a joining client.
  if s.bLoopback and _nType == c_nCursor then
    -- Presence comes back as a "friend" standing 50 m east (metres here); ~10 per second, so no cap and no log.
    local tMirror = {}
    for k, v in pairs(_tData or {}) do
      tMirror[k] = v
    end
    tMirror.cx = (tMirror.cx or 0) + c_nLoopOffsetCm / 100
    tMirror.px = (tMirror.px or 0) + c_nLoopOffsetCm / 100
    table.insert(s.tLoopIn, {sKind = "packet", nType = _nType, sFile = nil, tData = tMirror})
  elseif s.bLoopback and _nType == c_nPresenceAvatar then
    -- Round-trip through JSON when Parse is available so loopback exercises the real wire format.
    local tMirror = api.json and api.json.Parse and Decode(Encode(_tData)) or _tData or {}
    table.insert(s.tLoopIn, {sKind = "packet", nType = _nType, sFile = nil, tData = tMirror})
  elseif s.bLoopback and (_nType == c_nLedgerSync or _nType == c_nSaveChunkData) then
    if _nType == c_nSaveChunkData then
      table.insert(s.tLoopIn, {sKind = "packet", nType = c_nSaveLoadCommit,
        sFile = _sFile and (c_sEnginePrefix .. _sFile) or nil, tData = {}})
      Bridge.Log("loopback: baseline " .. tostring(_sFile) .. " returned as a join load")
    else
      table.insert(s.tLoopIn, {sKind = "packet", nType = _nType, sFile = nil, tData = _tData or {}})
    end
  elseif s.bLoopback and _nType >= 0x20 and s.nLoopCount < c_nLoopLimit then
    s.nLoopCount = s.nLoopCount + 1
    local tMirror = {}
    for k, v in pairs(_tData or {}) do
      tMirror[k] = v
    end
    -- p = 1: the packet is about the "friend's" copy, which sits on the other side of the mirror.
    if type(tMirror.x) == "number" then
      tMirror.x = tMirror.x + (tMirror.p == 1 and -c_nLoopOffsetCm or c_nLoopOffsetCm)
    end
    tMirror.p = nil
    -- Area & terrain packets carry nested positions: the receiver applies the shift itself.
    if _nType == 0x22 or _nType == 0x23 then
      tMirror.ox = c_nLoopOffsetCm
    end
    table.insert(s.tLoopIn, {sKind = "packet", nType = _nType,
      sFile = _sFile and (c_sEnginePrefix .. _sFile) or nil, tData = tMirror})
    Bridge.Log("loopback: mirrored packet type " .. _nType .. " (" .. s.nLoopCount .. "/" .. c_nLoopLimit .. ")")
  elseif s.bLoopback and _nType >= 0x20 then
    Bridge.Log("loopback: limit reached, packet not mirrored (possible echo loop)")
  end
  return true
end

Bridge.SetLoopback = function(_bOn)
  s.bLoopback = _bOn == true
  s.nLoopCount = 0
  s.tLoopIn = {}
  Bridge.Log("loopback " .. (s.bLoopback and "on" or "off"))
end

Bridge.IsLoopback = function()
  return s.bLoopback == true
end

-- Co-op menu "Test join" (loopback only); the park manager takes the request on its next Advance.
Bridge.RequestTestJoin = function()
  s.bTestJoin = s.bLoopback == true
end

Bridge.TakeTestJoin = function()
  local bRequested = s.bTestJoin == true
  s.bTestJoin = false
  return bRequested
end

Bridge.RequestResync = function()
  s.bResync = (s.sRole == "host" and s.bPeerConnected == true)
end

Bridge.TakeResync = function()
  local bRequested = s.bResync == true
  s.bResync = false
  return bRequested
end

Bridge.GetModVersion = function()
  return c_sModVersion
end

Bridge.IsAllowedGameMode = function(_sMode)
  return type(_sMode) == "string" and c_tAllowedModes[_sMode] == true
end

Bridge.GetHostGameMode = function()
  return (type(s.sHostMode) == "string" and c_tAllowedModes[s.sHostMode]) and s.sHostMode or "Sandbox"
end

Bridge.GetHostScenarioCode = function()
  return s.sHostScenario
end

Bridge.GetHostDifficulty = function()
  return s.sHostDifficulty
end

Bridge.GetHostIsWildArea = function()
  return s.bHostWildArea == true
end

Bridge.SetGuestWorld = function(_bGuest)
  s.bGuestWorld = (_bGuest == true and not s.bLoopback)
end

Bridge.IsGuestWorld = function()
  return s.sRole == "client" or s.bGuestWorld == true
end

Bridge.GetVersionMismatch = function()
  return s.sVersionMismatch
end

Bridge.IsApplying = function()
  return s.bApplying
end

-- Mirrors g_IsApplyingRemoteAction in the DLL (lines are processed in order, so the guard brackets
-- exactly the messages written while applying).
Bridge.BeginApply = function()
  s.bApplying = true
  Bridge.SendCommand("apply_begin")
end

Bridge.EndApply = function()
  s.bApplying = false
  Bridge.SendCommand("apply_end")
end

-- Writes queued lines into the Lua -> DLL ring if they fit (a batch is never split).
Bridge.Flush = function(_bForce)
  local t = s.t
  if t == nil or s.sSid == nil or t[c_nSlotClaim] == 0 then
    return
  end
  if s.bNeedHello then
    s.bNeedHello = false
    table.insert(s.tOutLines, 1, Encode({cmd = "hello", sid = s.sSid}))
    table.insert(s.tOutLines, 2, Encode({cmd = "status"}))
  end
  if #s.tOutLines == 0 then
    if s.nSinceWrite < c_nHeartbeat and not _bForce then
      return
    end
    table.insert(s.tOutLines, Encode({cmd = "ack", n = "0"})) -- keep-alive for the DLL's liveness check
  end
  local sText = table.concat(s.tOutLines, "\n") .. "\n"
  sText = sText .. string.rep("\n", (8 - #sText % 8) % 8)
  local nSlots = #sText // 8
  if nSlots > c_nRing - (s.nOutHead - t[c_nSlotOutTail]) then
    return -- DLL is behind; retry next flush
  end
  for i = 0, nSlots - 1 do
    t[c_nOutData + (s.nOutHead + i) % c_nRing] = Pack8(sText, i * 8 + 1)
  end
  s.nOutHead = s.nOutHead + nSlots
  t[c_nSlotOutHead] = s.nOutHead -- published after the data
  s.tOutLines = {}
  s.nSinceWrite = 0
end

-- Returns new messages: {sKind = "event", tData = {...}} or
-- {sKind = "packet", nType = n, sFile = <path or nil>, tData = {...}}.
Bridge.Receive = function()
  local tOut = {}
  local t = s.t
  if t == nil or s.sSid == nil then
    return tOut
  end
  local nHead = t[c_nSlotInHead]
  if nHead == s.nInTail then
    return tOut
  end
  local tChunks = {s.sRx}
  while s.nInTail < nHead do
    table.insert(tChunks, Unpack8(t[c_nInData + s.nInTail % c_nRing]))
    s.nInTail = s.nInTail + 1
  end
  t[c_nSlotInTail] = s.nInTail
  local sData = table.concat(tChunks)
  local nLast = 0
  for sLine, nEnd in string.gmatch(sData, "([^\n]*)\n()") do
    nLast = nEnd
    if string.sub(sLine, 1, 1) == "{" then
      local tData = Decode(sLine)
      if tData ~= nil then
        table.insert(tOut, {sKind = "event", tData = tData})
      end
    elseif sLine ~= "" then
      local sType, sFile, sJson = string.match(sLine, "^(%d+) (%S+) (.*)$")
      local tData = sJson and Decode(sJson)
      if tData ~= nil then
        table.insert(tOut, {
          sKind = "packet",
          nType = tonumber(sType),
          sFile = sFile ~= "-" and (c_sEnginePrefix .. sFile) or nil,
          tData = tData,
        })
      end
    end
  end
  s.sRx = nLast > 0 and string.sub(sData, nLast) or sData
  return tOut
end

-- Per-frame pump: heartbeat, receive, throttled flush. Returns received messages.
Bridge.Update = function(_nDeltaTime)
  local t = s.t
  if t == nil then
    return {}
  end
  t[c_nSlotBeat] = t[c_nSlotBeat] + 1
  if s.sSid == nil or t[c_nSlotClaim] == 0 then
    return {}
  end
  s.nSinceWrite = s.nSinceWrite + _nDeltaTime
  s.nFlushTimer = s.nFlushTimer + _nDeltaTime
  local tMessages = Bridge.Receive()
  if s.nFlushTimer >= c_nFlushInterval then
    s.nFlushTimer = 0
    Bridge.Flush(false)
  end
  return tMessages
end

-- ---- session state + dispatch (lives for the whole process, across park loads) -------------------

Bridge.GetRole = function()
  return s.sRole
end

Bridge.IsPeerConnected = function()
  return s.bPeerConnected
end

-- Live environments by prototype name (fed by the Environment.Init/Shutdown hook in the database module).
-- The main menu shows a real Sandbox park behind the start screen, so "start screen alive" = not in a park.
-- _sEvent: "Init" | "Activate" | "Deactivate" | "Shutdown". An environment counts as active from Init or
-- Activate until Deactivate or Shutdown.
Bridge.NoteEnvironment = function(_tEnvironment, _sPrototypeModule, _sEvent)
  s.tLiveEnvironments = s.tLiveEnvironments or {}
  if _sEvent == "Shutdown" then
    s.tLiveEnvironments[_tEnvironment] = nil
  else
    s.tLiveEnvironments[_tEnvironment] = {sPrototype = _sPrototypeModule, bActive = _sEvent ~= "Deactivate"}
  end
  -- Returning to the main menu unloads the host's world, restoring normal saving/autosaving for solo play.
  if _sPrototypeModule == "Environments.StartScreenEnvironment" and _sEvent == "Activate" and s.sRole ~= "client" then
    s.bGuestWorld = false
  end
end

-- The live start-screen environment (main menu), or nil while a park is up.
Bridge.GetStartScreenEnvironment = function()
  for tEnvironment, tEnv in pairs(s.tLiveEnvironments or {}) do
    if tEnv.sPrototype == "Environments.StartScreenEnvironment" and tEnv.bActive then
      return tEnvironment
    end
  end
  return nil
end

Bridge.IsStartScreenActive = function()
  return Bridge.GetStartScreenEnvironment() ~= nil
end

-- A guest who joined from the main menu has no park manager to load the host's zoo; pz2coop.ui.lua
-- takes the received file from here and loads it through the start screen.
Bridge.TakeMenuLoad = function()
  local sFile = s.sMenuLoad
  s.sMenuLoad = nil
  return sFile
end

Bridge.TakeAutotestPlan = function()
  local sPlan = s.sAutotestPlan
  s.sAutotestPlan = nil
  return sPlan
end

-- The park manager registers while a park is loaded; nil = messages are only logged.
Bridge.SetHandler = function(_fnHandler)
  s.fnHandler = _fnHandler
end

-- Details for the co-op screen (pz2coop.ui.lua); role/connected stay in s.sRole / s.bPeerConnected.
-- ponytail: lives in the bridge state so it survives module reloads like the rest of the session.
local Session = function()
  s.tSession = s.tSession or {sPrivacy = "friends", tFriends = {}, bFriendsAvailable = false, tInvited = {},
    tAvatars = {}}
  return s.tSession
end

local c_tQuietEvents = {status = true, friends = true, invited = true, avatar = true, save_progress = true}

local TrackSession = function(_tEvent)
  local sEvent = _tEvent.event
  local tSession = Session()
  if sEvent == "room_code" then
    s.sRole = "host"
    tSession.sCode = "PZ-" .. tostring(_tEvent.code)
    tSession.sError = nil
  elseif sEvent == "lobby_joined" then
    s.sRole = "client"
    tSession.sError = nil
    tSession.tZoo = nil
  elseif sEvent == "peer_connected" then
    s.bPeerConnected = true
  elseif sEvent == "peer_disconnected" then
    s.bPeerConnected = false
    s.sVersionMismatch = nil
    s.sHostMode = nil
    s.sHostScenario = nil
    s.sHostDifficulty = nil
    s.bHostWildArea = false
    tSession.sPartner = nil
    tSession.nPing = nil
    tSession.tZoo = nil
  elseif sEvent == "left" then
    s.bLoopback = false
    s.bPeerConnected = false
    s.sRole = "none"
    s.sVersionMismatch = nil
    s.sHostMode = nil
    s.sHostScenario = nil
    s.sHostDifficulty = nil
    s.bHostWildArea = false
    tSession.sCode = nil
    tSession.sPartner = nil
    tSession.nPing = nil
    tSession.tInvited = {}
    tSession.tZoo = nil
  elseif sEvent == "status" then
    s.sRole = _tEvent.role or "none"
    s.bPeerConnected = _tEvent.connected == true
    tSession.sCode = _tEvent.room_code and ("PZ-" .. _tEvent.room_code) or nil
    tSession.sPrivacy = _tEvent.privacy or tSession.sPrivacy
    tSession.sSelf = _tEvent.self_name
    tSession.sPartner = _tEvent.partner_name
    tSession.sSelfId = _tEvent.self_id
    tSession.sPartnerId = _tEvent.partner_id
    tSession.nPing = _tEvent.ping
    tSession.bPending = _tEvent.pending == true
  elseif sEvent == "friends" then
    tSession.bFriendsAvailable = _tEvent.available == true
    tSession.tFriends = type(_tEvent.list) == "table" and _tEvent.list or {}
  elseif sEvent == "avatar" then
    -- 32x32 Steam picture as base64 RGB; pz2coop.ui.lua hands each to the UI once.
    if type(_tEvent.rgb) == "string" and type(_tEvent.size) == "number" then
      tSession.tAvatars[tostring(_tEvent.id)] = {nSize = _tEvent.size, sRgb = _tEvent.rgb}
    end
  elseif sEvent == "save_progress" then
    -- Guest: the host's park arriving chunk by chunk (version.dll file_bridge.cpp).
    tSession.tZoo = {nGot = tonumber(_tEvent.got) or 0, nTotal = tonumber(_tEvent.total) or 0,
      nBytes = tonumber(_tEvent.bytes) or 0, bReceived = false}
  elseif sEvent == "invited" then
    tSession.tInvited[tostring(_tEvent.id)] = true
  elseif sEvent == "autotest" then
    s.sAutotestPlan = tostring(_tEvent.plan or "full")
  elseif sEvent == "error" then
    tSession.sError = tostring(_tEvent.code)
  end
  tSession.nVersion = (tSession.nVersion or 0) + 1
  if not c_tQuietEvents[sEvent] then
    Bridge.Log("event " .. tostring(sEvent) .. " -> role=" .. s.sRole .. " connected=" .. tostring(s.bPeerConnected))
  end
end

Bridge.GetSession = function()
  return Session()
end

-- True while a Sandbox/Challenge park runs its sync manager (co-op is offered only then).
Bridge.SetSyncedPark = function(_bSynced)
  s.bSyncedPark = _bSynced == true
end

Bridge.IsSyncedPark = function()
  return s.bSyncedPark == true
end

-- Called every frame by the background task spawned in database.pz2coopluadatabase.lua.
Bridge.Pump = function(_nDeltaTime)
  local tMessages = Bridge.Update(_nDeltaTime)
  if s.tLoopIn ~= nil and #s.tLoopIn > 0 then
    for _, tMsg in ipairs(s.tLoopIn) do
      table.insert(tMessages, tMsg)
    end
    s.tLoopIn = {}
  end
  if not s.bAnnounced and Bridge.IsConnected() then
    s.bAnnounced = true
    Bridge.Log("Lua bridge connected (codec ok, table claimed)")
  end
  for _, tMsg in ipairs(tMessages) do
    if tMsg.sKind == "event" then
      TrackSession(tMsg.tData)
    elseif tMsg.nType == c_nHandshakeHello and type(tMsg.tData) == "table" then
      if type(tMsg.tData.mode) == "string" and c_tAllowedModes[tMsg.tData.mode] then
        s.sHostMode = tMsg.tData.mode
      end
      if type(tMsg.tData.scenario) == "string" and #tMsg.tData.scenario > 0 and #tMsg.tData.scenario <= 64 and
          string.match(tMsg.tData.scenario, "^[%w_%-]+$") ~= nil then
        s.sHostScenario = tMsg.tData.scenario
      elseif tMsg.tData.mode ~= nil then
        s.sHostScenario = nil
      end
      if type(tMsg.tData.diff) == "string" and c_tAllowedDiffs[tMsg.tData.diff] then
        s.sHostDifficulty = tMsg.tData.diff
      elseif tMsg.tData.mode ~= nil then
        s.sHostDifficulty = nil
      end
      if tMsg.tData.wild ~= nil then
        s.bHostWildArea = tMsg.tData.wild == true
      elseif tMsg.tData.mode ~= nil then
        s.bHostWildArea = false
      end
      if type(tMsg.tData.ver) == "string" and tMsg.tData.ver ~= "" and tMsg.tData.ver ~= c_sModVersion then
        s.sVersionMismatch = "peer " .. string.sub(tMsg.tData.ver, 1, 16) .. " vs local " .. c_sModVersion
        Bridge.Log("WARNING: mod version mismatch (" .. s.sVersionMismatch .. ")")
      else
        s.sVersionMismatch = nil
      end
    elseif tMsg.nType == c_nSaveLoadCommit and s.sRole == "client" then
      local tZoo = Session().tZoo or {nGot = 0, nTotal = 0, nBytes = 0}
      tZoo.bReceived = true
      Session().tZoo = tZoo
      if s.fnHandler == nil and tMsg.sFile ~= nil then
        s.sMenuLoad = tMsg.sFile
      end
    end
    if s.fnHandler ~= nil then
      s.fnHandler(tMsg)
    end
  end
end
