-- Story Campaign / Career Mode progression sync (src/ovl_mod/pz2coop.careersync.lua).
-- Synchronizes ScenarioNarrativeManager chapters, stages, and objective completions between Host and Guest
-- in ScenarioCareer mode so collaborative actions (demolishing clutter, placing enrichment, adopting animals,
-- camera/UI tutorial steps) keep both players advancing together instead of softlocking or diverging.
--
-- Wire format: packet 0x30 {k = "career", ch = <chapter>, st = <stage>, done = {nUniqueNarrativeID, ...}}.
-- Never mutates nCurrentChapterIndex / nCurrentStageIndex directly: instead calls vanilla oObjective:Finish(true)
-- on started, unfinished objectives so ScenarioNarrativeManager._ScenarioNarrativeRun executes its own tEndEvents,
-- unlocks tutorial placement areas, awards medals, and starts the next stage cleanly.
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
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local CareerSync = module(...)

local c_nCareerPacket = 0x30
local c_nPollInterval = 0.5
local c_nStartupGrace = 2.0
local c_nStageStepCooldown = 0.75
local c_nEchoMuteWindow = 1.5
local c_nMaxChapter = 100
local c_nMaxStage = 200
local c_nMaxDoneIds = 64
local c_nLogLimit = 300

local s = {
  bInstalled = false,
  bSending = false,
  tEnvironment = nil,
  nClock = 0,
  nStartedAt = 0,
  nPollTimer = 0,
  nNextStepAt = 0,
  nEchoMuteUntil = -1,
  bSeeded = false,
  bSendOnNextPoll = false,
  sLastSig = nil,
  tRemoteTarget = nil, -- {ch = n, st = n, done = {[id] = true}}
  nLogs = 0,
}

local Log = function(_sMsg)
  if s.nLogs < c_nLogLimit then
    s.nLogs = s.nLogs + 1
    Bridge.Log("career sync: " .. _sMsg)
  end
end

local IsValidPosInt = function(_v, _nMax)
  return type(_v) == "number" and _v == _v and _v >= 1 and _v <= _nMax and math.floor(_v) == _v
end

local GetNarrativeManager = function()
  local tEnv = s.tEnvironment
  if tEnv == nil then
    local bOk, tWorld = pcall(function()
      return api.world and api.world.GetActive and api.world.GetScript and api.world.GetScript(api.world.GetActive())
    end)
    tEnv = bOk and tWorld and tWorld.tEnvironment or nil
  end
  if tEnv == nil then
    return nil
  end
  if tEnv.RequestManager ~= nil then
    local bOk, mgr = pcall(tEnv.RequestManager, tEnv, "Managers.ScenarioNarrativeManager")
    if bOk and type(mgr) == "table" then
      return mgr
    end
  end
  if tEnv.RequestInterface ~= nil then
    local bOk, mgr = pcall(tEnv.RequestInterface, tEnv, "Interfaces.IScenarioNarrativeManager")
    if bOk and type(mgr) == "table" then
      return mgr
    end
  end
  return nil
end

-- Reads active chapter, stage, and completed objective narrative IDs from ScenarioNarrativeManager.
local ReadLocalState = function(_mgr)
  if _mgr == nil or _mgr.bEnabled ~= true then
    return nil
  end
  local ch = _mgr.nCurrentChapterIndex
  local st = _mgr.nCurrentStageIndex
  if not IsValidPosInt(ch, c_nMaxChapter) or not IsValidPosInt(st, c_nMaxStage) then
    return nil
  end
  local narrative = _mgr.scenarioNarrative
  if narrative == nil or narrative.GetStage == nil then
    return nil
  end
  local bOk, tStage = pcall(narrative.GetStage, narrative, ch, st)
  if not bOk or type(tStage) ~= "table" or type(tStage.tObjectives) ~= "table" then
    return nil
  end
  local tDone = {}
  for _, oObj in ipairs(tStage.tObjectives) do
    if oObj ~= nil and oObj.IsComplete ~= nil and oObj.GetUniqueNarrativeID ~= nil then
      local bCompOk, bComp = pcall(oObj.IsComplete, oObj)
      local bIdOk, nId = pcall(oObj.GetUniqueNarrativeID, oObj)
      if bCompOk and bComp == true and bIdOk and type(nId) == "number" then
        table.insert(tDone, nId)
      end
    end
  end
  table.sort(tDone)
  local sSig = tostring(ch) .. ":" .. tostring(st) .. ":" .. table.concat(tDone, ",")
  return ch, st, tStage, tDone, sSig
end

local SendState = function(_ch, _st, _tDone)
  local tArr = setmetatable({}, api.json and api.json.GetArrayMetatable and api.json.GetArrayMetatable() or nil)
  for i, nId in ipairs(_tDone) do
    tArr[i] = nId
  end
  BuildSync.Count("sent career progress")
  Log(string.format("local career progress ch=%d st=%d done=%d", _ch, _st, #_tDone))
  Bridge.SendPacket(c_nCareerPacket, nil, {
    k = "career",
    ch = _ch,
    st = _st,
    done = tArr,
  })
end

-- Finishes a single objective only when it is in progress (Objective.Finish asserts state == InProgress).
local TryFinishObjective = function(_oObj)
  if _oObj == nil or _oObj.IsStarted == nil or _oObj.IsFinished == nil or _oObj.Finish == nil then
    return false
  end
  local bStOk, bStarted = pcall(_oObj.IsStarted, _oObj)
  local bFinOk, bFinished = pcall(_oObj.IsFinished, _oObj)
  if not (bStOk and bStarted == true and bFinOk and bFinished ~= true) then
    return false
  end
  local bOk, sErr = pcall(_oObj.Finish, _oObj, true)
  if not bOk then
    Log("failed to finish objective: " .. tostring(sErr))
    return false
  end
  return true
end

-- Applies queued remote career progress to the local ScenarioNarrativeManager step-by-step.
local ApplyRemoteTarget = function(_mgr, _ch, _st, _tStage)
  local tTarget = s.tRemoteTarget
  if tTarget == nil then
    return false
  end
  local bPeerAhead = (tTarget.ch > _ch) or (tTarget.ch == _ch and tTarget.st > _st)
  local bSameStage = (tTarget.ch == _ch and tTarget.st == _st)
  if not bPeerAhead and not bSameStage then
    -- Local player is already ahead of this remote snapshot.
    s.tRemoteTarget = nil
    return false
  end
  if bPeerAhead and s.nClock < s.nNextStepAt then
    return false
  end
  local nFinished = 0
  for _, oObj in ipairs(_tStage.tObjectives) do
    if oObj ~= nil and oObj.GetUniqueNarrativeID ~= nil then
      local bIdOk, nId = pcall(oObj.GetUniqueNarrativeID, oObj)
      local bOptOk, bOptional = pcall(function()
        return oObj.GetIsOptional ~= nil and oObj:GetIsOptional() == true
      end)
      local bWant = false
      if bPeerAhead then
        bWant = not (bOptOk and bOptional == true)
      elseif bSameStage and bIdOk and tTarget.done[nId] == true then
        bWant = true
      end
      if bWant and TryFinishObjective(oObj) then
        nFinished = nFinished + 1
      end
    end
  end
  if nFinished > 0 then
    s.nEchoMuteUntil = s.nClock + c_nEchoMuteWindow
    if bPeerAhead then
      s.nNextStepAt = s.nClock + c_nStageStepCooldown
    end
    BuildSync.Count("applied career progress")
    Log(string.format("applied %d remote objective(s) at ch=%d st=%d (peer ch=%d st=%d)",
      nFinished, _ch, _st, tTarget.ch, tTarget.st))
    return true
  end
  return false
end

local Poll = function()
  local mgr = GetNarrativeManager()
  local ch, st, tStage, tDone, sSig = ReadLocalState(mgr)
  if ch == nil then
    return
  end
  if not s.bSeeded then
    s.bSeeded = true
    s.sLastSig = sSig
    if s.bSendOnNextPoll and s.bSending and not Bridge.IsApplying() then
      s.bSendOnNextPoll = false
      SendState(ch, st, tDone)
    end
    return
  end

  if s.tRemoteTarget ~= nil then
    local bApplied = ApplyRemoteTarget(mgr, ch, st, tStage)
    if bApplied then
      local _, _, _, _, sAfter = ReadLocalState(mgr)
      if sAfter ~= nil then
        s.sLastSig = sAfter
      end
      return
    end
  end

  if s.bSendOnNextPoll and s.bSending and not Bridge.IsApplying() then
    s.bSendOnNextPoll = false
    s.sLastSig = sSig
    SendState(ch, st, tDone)
    return
  end

  if sSig ~= s.sLastSig then
    s.sLastSig = sSig
    if s.bSending and not Bridge.IsApplying() and s.nClock >= s.nEchoMuteUntil then
      SendState(ch, st, tDone)
    end
  end
end

CareerSync.Install = function(_tEnvironment)
  s.tEnvironment = _tEnvironment
  s.bInstalled = true
  s.nStartedAt = s.nClock
  s.nPollTimer = 0
  s.nNextStepAt = 0
  s.nEchoMuteUntil = -1
  s.bSeeded = false
  s.bSendOnNextPoll = false
  s.sLastSig = nil
  s.tRemoteTarget = nil
  Log("installed")
end

CareerSync.Uninstall = function()
  s.bInstalled = false
  s.tEnvironment = nil
  s.tRemoteTarget = nil
  s.sLastSig = nil
  s.bSeeded = false
  s.bSendOnNextPoll = false
end

CareerSync.ResetSnapshot = function()
  s.nStartedAt = s.nClock
  s.nPollTimer = 0
  s.nNextStepAt = 0
  s.nEchoMuteUntil = -1
  s.bSeeded = false
  s.sLastSig = nil
  s.tRemoteTarget = nil
end

CareerSync.OnPeerConnected = function()
  s.bSendOnNextPoll = true
end

CareerSync.Update = function(_nDt, _bSending)
  if not s.bInstalled then
    return
  end
  s.nClock = s.nClock + _nDt
  s.bSending = _bSending == true
  if s.nClock < s.nStartedAt + c_nStartupGrace then
    return
  end
  s.nPollTimer = s.nPollTimer + _nDt
  if s.nPollTimer >= c_nPollInterval then
    s.nPollTimer = 0
    local bOk, sErr = pcall(Poll)
    if not bOk then
      Log("poll error: " .. tostring(sErr))
    end
  end
end

CareerSync.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nCareerPacket or type(_tMsg.tData) ~= "table" or _tMsg.tData.k ~= "career" then
    return false
  end
  local d = _tMsg.tData
  if not IsValidPosInt(d.ch, c_nMaxChapter) or not IsValidPosInt(d.st, c_nMaxStage) then
    Log("dropped invalid career packet (bad chapter/stage)")
    return true
  end
  local tDoneMap = {}
  if type(d.done) == "table" then
    local nCount = 0
    for _, v in ipairs(d.done) do
      nCount = nCount + 1
      if nCount > c_nMaxDoneIds then
        break
      end
      if type(v) == "number" and v == v and v >= 0 and v <= 1e9 and math.floor(v) == v then
        tDoneMap[v] = true
      end
    end
  end
  local tCur = s.tRemoteTarget
  if tCur == nil or d.ch > tCur.ch or (d.ch == tCur.ch and d.st > tCur.st) then
    s.tRemoteTarget = {ch = d.ch, st = d.st, done = tDoneMap}
  elseif d.ch == tCur.ch and d.st == tCur.st then
    for nId in pairs(tDoneMap) do
      tCur.done[nId] = true
    end
  end
  -- Apply promptly on the next poll tick.
  s.nPollTimer = c_nPollInterval
  return true
end
