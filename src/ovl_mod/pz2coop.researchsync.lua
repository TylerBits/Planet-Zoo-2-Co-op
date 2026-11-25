-- Research tier sync: keeps vet/mechanic research unlocks synchronized across co-op peers.
--   detect:  MsgType_ResearchUpdatedMessage + tracking active topics via research:GetPinnedResearch() and
--            research:GetResearchTopicForStaff(staffID) (verified in worlds.darwinworld.lua & facilityinfopopup.lua).
--   apply:   validates topic via research:IsResearchTopic(sTopic) & research:GetMaxTier(sTopic), then calls
--            research:SetTierForTopic(sTopic, nTier) + research:ClearNotificationBlip(sTopic)
--            (exact vanilla recipe from events.eventactionunlockresearch.lua:77-99).
-- Packet 0x30 (ACTION_ANIMAL_EVENT, JSON): {k = "research", topic = sTopic, tier = nTier}.
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
local require = global.require
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")

local ResearchSync = module(...)

local c_nAnimalEventPacket = 0x30
local c_nStartupIgnore = 5.0
local c_nPollInterval = 1.0
local c_nLogLimit = 300

local s = {
  bInstalled = false,
  bSending = false,
  nClock = 0,
  nStartedAt = 0,
  nPollTimer = 0,
  nLogs = 0,
  fnReceiver = nil,
  tKnownTiers = {}, -- sTopic -> highest known tier
  tTrackedTopics = {}, -- sTopic -> true
  bDirty = false,
}

local Log = function(_s)
  if s.nLogs < c_nLogLimit then
    s.nLogs = s.nLogs + 1
    Bridge.Log("research sync: " .. _s)
  end
end

local IsSafeTopic = function(_v)
  return type(_v) == "string" and #_v > 0 and #_v <= 64 and string.match(_v, "^[%w_%-]+$") ~= nil
end

local DiscoverTopics = function(_tWorld)
  local research = _tWorld.research
  if research == nil then
    return
  end
  pcall(function()
    if research.GetPinnedResearch ~= nil then
      local sTopic = research:GetPinnedResearch()
      if IsSafeTopic(sTopic) then
        s.tTrackedTopics[sTopic] = true
      end
    end
  end)
  pcall(function()
    if _tWorld.staff ~= nil and _tWorld.staff.GetAllStaffEntities ~= nil and research.GetResearchTopicForStaff ~= nil then
      local tStaff = _tWorld.staff:GetAllStaffEntities()
      if type(tStaff) == "table" then
        for _, nStaffID in ipairs(tStaff) do
          local sTopic = research:GetResearchTopicForStaff(nStaffID)
          if IsSafeTopic(sTopic) then
            s.tTrackedTopics[sTopic] = true
          end
        end
      end
    end
  end)
end

local CheckTrackedTopics = function(_bEmit)
  local tWorld = api.world.GetWorldAPIs()
  local research = tWorld and tWorld.research
  if research == nil or research.GetCurrentTier == nil then
    return
  end
  DiscoverTopics(tWorld)
  for sTopic in pairs(s.tTrackedTopics) do
    local bOk, nTier = pcall(research.GetCurrentTier, research, sTopic)
    if bOk and type(nTier) == "number" then
      local nPrev = s.tKnownTiers[sTopic]
      if nPrev == nil then
        s.tKnownTiers[sTopic] = nTier
      elseif nTier > nPrev then
        s.tKnownTiers[sTopic] = nTier
        if _bEmit and s.bSending and not Bridge.IsApplying() then
          BuildSync.Count("sent research")
          Log(string.format("local research unlock %s -> tier %d", sTopic, nTier))
          Bridge.SendPacket(c_nAnimalEventPacket, nil, {
            k = "research",
            topic = sTopic,
            tier = nTier,
          })
        end
      end
    end
  end
end

local OnResearchUpdated = function(_tMessages)
  if type(_tMessages) ~= "table" or s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  for _, tMessage in ipairs(_tMessages) do
    if type(tMessage) == "table" and not tMessage.bOnLoad then
      local sTopic = tMessage.sTopic or tMessage.sResearchTopic
      if IsSafeTopic(sTopic) then
        s.tTrackedTopics[sTopic] = true
      end
      s.bDirty = true
    end
  end
end

local Job_ApplyResearch = function(_tData)
  local sTopic = _tData.topic
  local nTier = type(_tData.tier) == "number" and math.floor(_tData.tier + 0.5) or nil
  if not IsSafeTopic(sTopic) or nTier == nil or nTier < 1 or nTier > 20 then
    Log("dropped invalid research packet")
    return
  end
  local research = api.world.GetWorldAPIs().research
  if research == nil or research.SetTierForTopic == nil then
    Log("research API unavailable")
    return
  end
  local bValid, bIsTopic = pcall(function()
    return research.IsResearchTopic == nil or research:IsResearchTopic(sTopic) == true
  end)
  if not bValid or not bIsTopic then
    Log("dropped unknown research topic " .. sTopic)
    return
  end
  local bMaxOk, nMax = pcall(function()
    return research.GetMaxTier ~= nil and research:GetMaxTier(sTopic) or 20
  end)
  if bMaxOk and type(nMax) == "number" and nTier > nMax then
    nTier = nMax
  end
  local bCurOk, nCur = pcall(function()
    return research.GetCurrentTier ~= nil and research:GetCurrentTier(sTopic) or 0
  end)
  if bCurOk and type(nCur) == "number" and nCur >= nTier then
    s.tTrackedTopics[sTopic] = true
    s.tKnownTiers[sTopic] = nCur
    return
  end
  s.tTrackedTopics[sTopic] = true
  s.tKnownTiers[sTopic] = nTier
  BuildSync.Breadcrumb("apply research " .. sTopic .. " tier " .. tostring(nTier))
  Bridge.BeginApply()
  local bOk, sErr = pcall(function()
    research:SetTierForTopic(sTopic, nTier)
    if research.ClearNotificationBlip ~= nil then
      research:ClearNotificationBlip(sTopic)
    end
  end)
  Bridge.EndApply()
  if not bOk then
    BuildSync.Count("research failed")
    Log("remote research apply failed: " .. tostring(sErr))
    return
  end
  BuildSync.Count("applied research")
  Log(string.format("remote research unlock %s -> tier %d", sTopic, nTier))
end

-- ---- module API ------------------------------------------------------------------------------------------
ResearchSync.Install = function()
  if s.bInstalled then
    return
  end
  s.nStartedAt = s.nClock
  s.nPollTimer = 0
  s.tKnownTiers = {}
  s.tTrackedTopics = {}
  s.bDirty = false
  local nMsg = api.messaging.MsgType_ResearchUpdatedMessage
  if nMsg ~= nil then
    s.fnReceiver = function(_tMessages)
      local bOk, sErr = pcall(OnResearchUpdated, _tMessages)
      if not bOk then
        Log("receiver error: " .. tostring(sErr))
      end
    end
    api.messaging.RegisterReceiver(nMsg, s.fnReceiver)
  end
  s.bInstalled = true
  Log("installed")
end

ResearchSync.Uninstall = function()
  if s.fnReceiver ~= nil then
    api.messaging.UnregisterReceiver(api.messaging.MsgType_ResearchUpdatedMessage, s.fnReceiver)
    s.fnReceiver = nil
  end
  s.bInstalled = false
end

ResearchSync.ResetSnapshot = function()
  s.tKnownTiers = {}
  s.tTrackedTopics = {}
  s.bDirty = false
  s.nStartedAt = s.nClock
end

ResearchSync.Update = function(_nDt, _bSending)
  if not s.bInstalled then
    return
  end
  s.nClock = s.nClock + _nDt
  s.bSending = _bSending
  if s.nClock < s.nStartedAt + c_nStartupIgnore then
    return
  end
  s.nPollTimer = s.nPollTimer + _nDt
  if s.bDirty or s.nPollTimer >= c_nPollInterval then
    s.bDirty = false
    s.nPollTimer = 0
    pcall(CheckTrackedTopics, true)
  end
end

ResearchSync.OnPacket = function(_tMsg)
  if _tMsg.nType ~= c_nAnimalEventPacket or type(_tMsg.tData) ~= "table" or _tMsg.tData.k ~= "research" then
    return false
  end
  local d = _tMsg.tData
  BuildSync.QueueJob(function() Job_ApplyResearch(d) end)
  return true
end
