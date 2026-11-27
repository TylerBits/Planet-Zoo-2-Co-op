-- PZ2-Coop park manager: save handshake, host ledger, build sync, message probe.
-- Registered into DarwinEnvironment by database.pz2coopluadatabase.lua. The bridge itself (and the
-- session state: role, peer connected) lives for the whole process and is pumped by a background task
-- spawned at boot; this manager only exists while a park is loaded and receives messages via a handler.
-- Session control comes from the Co-op screen in the Esc menu (pz2coop.ui.lua).
local global = _G
local api = global.api
local string = global.string
local table = global.table
local math = global.math
local pairs = global.pairs
local ipairs = global.ipairs
local tostring = global.tostring
local tonumber = global.tonumber
local type = global.type
local coroutine = global.coroutine
local require = global.require
local pcall = global.pcall
local Mutators = require("Environment.ModuleMutators")
local Bridge = require("PZ2Coop.Bridge")
local BuildSync = require("PZ2Coop.BuildSync")
local RegionSync = require("PZ2Coop.RegionSync")
local WaterSync = require("PZ2Coop.WaterSync")
local TerrainSync = require("PZ2Coop.TerrainSync")
local StaffSync = require("PZ2Coop.StaffSync")
local AnimalSync = require("PZ2Coop.AnimalSync")
local ResearchSync = require("PZ2Coop.ResearchSync")
local CareerSync = require("PZ2Coop.CareerSync")
local Presence = require("PZ2Coop.Presence")
local Actions = require("PZ2Coop.Actions")
local Vehicles = require("PZ2Coop.Vehicles")
local SaveGuard = require("PZ2Coop.SaveGuard")

local PZ2CoopManager = module(..., (Mutators.Manager)())

local c_nHandshakeHello = 0x01
local c_nSaveChunkData = 0x02
local c_nSaveLoadCommit = 0x03
local c_nLedgerSync = 0x11
local c_nLedgerInterval = 1.0
local c_sBaselineName = "PZ2Coop_Baseline"
local c_nProbeLimit = 10
local c_nProbeLineMax = 900
local c_nHeartbeatInterval = 30.0

-- Flight recorder (docs/MEGA_TEST.md): the first messages of each type go to diag.log with their payload,
-- so sync for paths, habitats, terrain, water, animals, staff and research can be written from facts.
local c_tProbeTypes = {
  "MsgType_PlacementPartCommittedMessage",
  "MsgType_UndoRedoCompletedMessage",
  "MsgType_HabitatBoundaryUpdatedMessage",
  "MsgType_HabitatBoundingBoxChangedMessage",
  "MsgType_HabitatGateCreatedMessage",
  "MsgType_ExhibitAddedMessage",
  "MsgType_SpatialVolumeChangedMessage",
  "MsgType_TerrainEditStatsMessage",
  "MsgType_LakeUpdateMessage",
  "MsgType_StaffCreatedOrDestroyedMessage",
  "MsgType_AnimalPurchasedMessage",
  "MsgType_AnimalAddedToZooMessage",
  "MsgType_ExhibitAnimalAddedToZooMessage",
  "MsgType_AnimalBornMessage",
  "MsgType_AnimalDiedMessage",
  "MsgType_ExhibitAnimalAddedMessage",
  "MsgType_ExhibitAnimalRemovedMessage",
  "MsgType_AnimalAssignedHabitatChangedMessage",
  "MsgType_CashSpentMessage",
  "MsgType_ResearchUpdatedMessage",
  "MsgType_ParkZoneCreatedOrDeletedMessage",
  "MsgType_RideEditedMessage",
}

PZ2CoopManager.Init = function(self, _tProperties, _tEnvironment)
  Bridge.Log("park manager Init")
  self.tEnvironment = _tEnvironment -- the park's environment; api.game.GetEnvironment() is the game-level one
  self.tLoggedErrors = {}
  self.bDisabled = false
  self.bStarted = false
  self.nLedgerTimer = 0
  self.bLedgerDirty = false
  self.saveJob = nil
  self.tProbeCounts = {}
  self.tReceivers = {}
  self.sLastPartner = nil
  self.sGameMode = "Sandbox"
  self.sScenarioCode = nil
  self.sGameDifficulty = nil
  self.bIsWildArea = false
  self.nLastAppliedSpeed = nil
  self.bMismatchNotified = false
  self.nAutoBaselineTimer = nil
  self.nReturnToMenuTimer = nil
end

PZ2CoopManager.Shutdown = function(self)
  Bridge.SetHandler(nil)
  self.nAutoBaselineTimer = nil
  self.nReturnToMenuTimer = nil
  for nType, fnReceiver in pairs(self.tReceivers) do
    api.messaging.UnregisterReceiver(nType, fnReceiver)
  end
  self.tReceivers = {}
  Vehicles.Uninstall()
  Actions.Uninstall()
  Presence.Shutdown()
  CareerSync.Uninstall()
  ResearchSync.Uninstall()
  AnimalSync.Uninstall()
  StaffSync.Uninstall()
  TerrainSync.Uninstall()
  WaterSync.Uninstall()
  RegionSync.Uninstall()
  BuildSync.Uninstall()
  SaveGuard.Shutdown()
  Bridge.SetSyncedPark(false)
  Bridge.Log("park manager shut down")
end

-- CLAUDE.md rules 6 & 8: sync only in offline/local parks (Sandbox, Challenge, ScenarioCareer,
-- ScenarioChallenge, WildArea). Franchise is strictly excluded (Frontier's servers own that state),
-- and so is anything else such as ScenarioEdit or the main menu's background park.
PZ2CoopManager._GetScenarioManager = function(self)
  return self.tEnvironment and self.tEnvironment:RequestInterface("Interfaces.IScenarioManager") or nil
end

PZ2CoopManager._GetGameMode = function(self)
  local scenarioManager = self:_GetScenarioManager()
  if scenarioManager == nil then
    return "none"
  end
  return tostring(scenarioManager:GetGameMode())
end

PZ2CoopManager._ReadScenarioMeta = function(self, _scenarioManager)
  local sCode, sDiff, bWild = nil, nil, false
  if _scenarioManager ~= nil then
    local bOkCode, vCode = pcall(function()
      return _scenarioManager.GetScenarioCode and _scenarioManager:GetScenarioCode()
    end)
    if bOkCode and type(vCode) == "string" and vCode ~= "" then
      sCode = vCode
    end
    local bOkDiff, vDiff = pcall(function()
      return _scenarioManager.GetGameDifficulty and _scenarioManager:GetGameDifficulty()
    end)
    if bOkDiff and type(vDiff) == "string" and vDiff ~= "" then
      sDiff = vDiff
    end
  end
  pcall(function()
    local wt = api.world and api.world.GetWorldAPIs and api.world.GetWorldAPIs().wildterritory
    if wt ~= nil and wt.IsWildTerritoryCreationEnabled ~= nil then
      bWild = wt:IsWildTerritoryCreationEnabled() == true
    end
  end)
  return sCode, sDiff, bWild
end

-- Deferred to the first Advance: all managers (ScenarioManager included) are initialised by then.
PZ2CoopManager._Start = function(self)
  self.bStarted = true
  local scenarioManager = self:_GetScenarioManager()
  local sMode = scenarioManager ~= nil and tostring(scenarioManager:GetGameMode()) or "none"
  if not Bridge.IsAllowedGameMode(sMode) then
    self.bDisabled = true
    Bridge.SetSyncedPark(false)
    Bridge.Log("park manager idle: game mode " .. sMode .. " is not synced")
    return
  end
  -- Respect vanilla DLC ownership checks (CLAUDE.md rule 8: never unlock or bypass DLC checks).
  local bDlcBlocked = false
  pcall(function()
    if scenarioManager.IsDLCBlockingParkLoad ~= nil and scenarioManager:IsDLCBlockingParkLoad() == true then
      bDlcBlocked = true
    end
  end)
  if bDlcBlocked then
    self.bDisabled = true
    Bridge.SetSyncedPark(false)
    self:_Notify("Missing required DLC for this scenario", "Red")
    Bridge.Log("park manager idle: DLC blocks park load for mode " .. sMode)
    return
  end
  self.sGameMode = sMode
  self.sScenarioCode, self.sGameDifficulty, self.bIsWildArea = self:_ReadScenarioMeta(scenarioManager)
  Bridge.SetSyncedPark(true)
  SaveGuard.OnParkStart()
  Bridge.SetHandler(function(_tMsg)
    local bOk, sError = pcall(self._OnMessage, self, _tMsg)
    if not bOk then
      self:_LogError("message " .. tostring(_tMsg.nType or (_tMsg.tData and _tMsg.tData.event)), sError)
    end
  end)
  BuildSync.Install(function()
    self.bLedgerDirty = true
  end)
  RegionSync.Install()
  WaterSync.Install()
  TerrainSync.Install()
  StaffSync.Install()
  AnimalSync.Install()
  ResearchSync.Install()
  CareerSync.Install(self.tEnvironment)
  Presence.Install()
  Actions.Install()
  Vehicles.Install()
  self:_RegisterProbes()
  -- Host switched to a new park (e.g. next Career campaign zoo from the Conservation Map) while a peer is
  -- still connected: re-send handshake metadata + baseline save once the new park settles so the friend follows.
  if Bridge.GetRole() == "host" and Bridge.IsPeerConnected() then
    self.nAutoBaselineTimer = 1.5
  end
  Bridge.Log("park manager started (" .. sMode ..
    (self.sScenarioCode and (" scenario=" .. self.sScenarioCode) or "") ..
    (self.bIsWildArea and " wild=true" or "") ..
    "), role=" .. Bridge.GetRole() .. " connected=" .. tostring(Bridge.IsPeerConnected()) ..
    " guestWorld=" .. tostring(Bridge.IsGuestWorld()))
end

-- PZ2 keeps one park environment and loads parks into it (the menu background is a park too), so these
-- lifecycle calls mark park changes. A newly loaded park needs a fresh build snapshot.
PZ2CoopManager.Activate = function(self)
  Bridge.Log("park manager Activate")
end

PZ2CoopManager.Deactivate = function(self)
  Bridge.Log("park manager Deactivate")
end

PZ2CoopManager.ParkReset = function(self)
  Bridge.Log("park manager ParkReset")
  BuildSync.ResetSnapshot()
  WaterSync.ResetSnapshot()
  TerrainSync.ResetSnapshot()
  StaffSync.ResetSnapshot()
  AnimalSync.ResetSnapshot()
  ResearchSync.ResetSnapshot()
  CareerSync.ResetSnapshot()
end

PZ2CoopManager.WorldLoad = function(self, _tLoad, _nLoadedVersion)
  Bridge.Log("park manager WorldLoad version=" .. tostring(_nLoadedVersion))
  BuildSync.ResetSnapshot()
  WaterSync.ResetSnapshot()
  TerrainSync.ResetSnapshot()
  StaffSync.ResetSnapshot()
  AnimalSync.ResetSnapshot()
  ResearchSync.ResetSnapshot()
  CareerSync.ResetSnapshot()
  Presence.Reset()
  Actions.Reset()
  Vehicles.Reset()
end

-- Errors inside environment phases are otherwise invisible in retail; each distinct one is logged once.
PZ2CoopManager._LogError = function(self, _sWhere, _sError)
  local sKey = _sWhere .. tostring(_sError)
  if not self.tLoggedErrors[sKey] then
    self.tLoggedErrors[sKey] = true
    Bridge.Log("error in " .. _sWhere .. ": " .. tostring(_sError))
  end
end

PZ2CoopManager.Advance = function(self, _nDeltaTime)
  if not self.bAdvanceSeen then
    self.bAdvanceSeen = true
    Bridge.Log("park manager first Advance")
  end
  if self.bDisabled then
    return
  end
  local bOk, sError = pcall(self._Advance, self)
  if not bOk then
    self:_LogError("Advance", sError)
  end
end

PZ2CoopManager._Advance = function(self)
  if not self.bStarted then
    if Bridge.IsStartScreenActive() then
      if not self.bLoggedMenu then
        self.bLoggedMenu = true
        Bridge.Log("park manager waiting: start screen is up (menu background park)")
      end
      return
    end
    self:_Start()
    return
  end
  local nDt = api.time.GetDeltaTimeUnscaled()
  -- Proves the manager is still running, so a silent diag.log means "nothing happened", not "mod stopped".
  self.nHeartbeat = (self.nHeartbeat or 0) + nDt
  if self.nHeartbeat >= c_nHeartbeatInterval then
    self.nHeartbeat = 0
    Bridge.Log("alive: role=" .. Bridge.GetRole() .. " " .. BuildSync.Summary())
  end
  SaveGuard.SyncAutosaveState()
  BuildSync.Update(nDt, Bridge.GetRole() ~= "none")
  RegionSync.Update(nDt, Bridge.GetRole() ~= "none")
  WaterSync.Update(nDt, Bridge.GetRole() ~= "none")
  TerrainSync.Update(nDt, Bridge.GetRole() ~= "none")
  StaffSync.Update(nDt, Bridge.GetRole() ~= "none")
  AnimalSync.Update(nDt, Bridge.GetRole() ~= "none")
  ResearchSync.Update(nDt, Bridge.GetRole() ~= "none")
  CareerSync.Update(nDt, Bridge.GetRole() ~= "none")
  Presence.Update(nDt, Bridge.GetRole() ~= "none")
  Actions.Update(nDt, Bridge.GetRole() ~= "none")
  Vehicles.Update(nDt, Bridge.GetRole() ~= "none")
  if self.nAutoBaselineTimer ~= nil then
    if Bridge.GetRole() ~= "host" or not Bridge.IsPeerConnected() then
      self.nAutoBaselineTimer = nil
    else
      self.nAutoBaselineTimer = self.nAutoBaselineTimer - nDt
      if self.nAutoBaselineTimer <= 0 then
        self.nAutoBaselineTimer = nil
        Bridge.Log("host switched park while connected: sending handshake + baseline to friend")
        self:_SendHandshakeHello()
        self:_SendBaseline()
      end
    end
  end
  if self.nReturnToMenuTimer ~= nil then
    if not Bridge.IsGuestWorld() or Bridge.IsLoopback() or Bridge.IsStartScreenActive() then
      self.nReturnToMenuTimer = nil
    else
      self.nReturnToMenuTimer = self.nReturnToMenuTimer - nDt
      if self.nReturnToMenuTimer <= 0 then
        self.nReturnToMenuTimer = nil
        self:_ReturnGuestToStartScreen()
      end
    end
  end
  -- Solo test (Co-op menu "Test join"): the baseline is saved and looped back as if a friend had joined.
  if Bridge.TakeTestJoin() then
    Bridge.Log("test join: saving this zoo as the baseline a joining friend would receive")
    self:_SendBaseline()
  end
  if Bridge.TakeResync and Bridge.TakeResync() then
    self:_Notify("Resyncing zoo for your friend...", "Green")
    Bridge.Log("resync: host requested fresh baseline send")
    self:_SendBaseline()
  end
  self:_UpdateSaveJob()
  self:_UpdateLedger(nDt)
end

-- In-game HUD pop-out toast via NotificationManager.tTimelinePopOutQueue (managers.notificationmanager.lua:665).
PZ2CoopManager._Notify = function(self, _sText, _sColour)
  local sSafe = string.gsub(tostring(_sText or ""), "[|%[%]]", "")
  if sSafe == "" then
    return
  end
  Bridge.Log("notify (" .. tostring(_sColour or "default") .. "): " .. sSafe)
  pcall(function()
    local nm = self.tEnvironment and self.tEnvironment:RequestInterface("Interfaces.INotificationManager")
    if nm ~= nil and type(nm.tTimelinePopOutQueue) == "table" then
      table.insert(nm.tTimelinePopOutQueue, {
        nTimeShown = 0,
        bActionable = false,
        sColour = _sColour,
        tEntry = {
          sTimelineEntryName = "VIPEntered",
          sNotificationString = "[STRING_LITERAL:Value=|" .. sSafe .. "|]",
        },
      })
    end
  end)
end

PZ2CoopManager._SendHandshakeHello = function(self)
  Bridge.SendPacket(c_nHandshakeHello, nil, {
    mode = self.sGameMode,
    scenario = self.sScenarioCode,
    diff = self.sGameDifficulty,
    wild = self.bIsWildArea == true,
    ver = Bridge.GetModVersion and Bridge.GetModVersion() or "0.3.0",
  })
end

PZ2CoopManager._ScheduleReturnToMenu = function(self, _nDelaySecs, _sReason)
  if self.nReturnToMenuTimer ~= nil then
    return
  end
  self.nReturnToMenuTimer = _nDelaySecs or 2.0
  Bridge.Log("guest world disconnect (" .. tostring(_sReason) .. "): returning to main menu in " ..
    tostring(self.nReturnToMenuTimer) .. " s")
end

-- Returns a disconnected guest to the Start Screen without saving the host's zoo.
PZ2CoopManager._ReturnGuestToStartScreen = function(self)
  if not Bridge.IsGuestWorld() or Bridge.IsLoopback() or Bridge.IsStartScreenActive() then
    return
  end
  Bridge.Log("returning guest to start screen (host left world)")
  local bTriggered = false
  pcall(function()
    local worldScript = api.world and api.world.GetActive and api.world.GetScript and api.world.GetScript(api.world.GetActive())
    local mainHUD = worldScript and worldScript.GetHUD and worldScript:GetHUD()
    local saveAgent = mainHUD and mainHUD.saveAgent
    if saveAgent ~= nil and saveAgent.OnPauseMenu_ReturnToStartScreen ~= nil then
      saveAgent:OnPauseMenu_ReturnToStartScreen(mainHUD, true, false)
      bTriggered = true
    end
  end)
  if not bTriggered then
    pcall(function()
      local tGameEnv = api.game and api.game.GetEnvironment and api.game.GetEnvironment()
      local bg = tGameEnv and tGameEnv.RequestInterface and tGameEnv:RequestInterface("Interfaces.IBackgroundWorldDataManager")
      if bg ~= nil and bg.SetupHUDForReturnToStartScreen ~= nil then
        bg:SetupHUDForReturnToStartScreen()
      end
      if api.game ~= nil and api.game.RequestReturnToStart ~= nil then
        api.game.RequestReturnToStart()
        bTriggered = true
      elseif api.world ~= nil and api.world.Activate ~= nil then
        api.world.Activate("StartScreenGlobe", false)
        bTriggered = true
      end
    end)
  end
  if not bTriggered then
    Bridge.Log("could not automatically return guest to start screen (no SaveAgent or RequestReturnToStart)")
  end
end

PZ2CoopManager._OnSessionEvent = function(self, _tEvent)
  local sEvent = _tEvent.event
  local tSession = Bridge.GetSession()
  if type(tSession.sPartner) == "string" and tSession.sPartner ~= "" then
    self.sLastPartner = tSession.sPartner
  end
  if sEvent == "peer_connected" then
    self.bMismatchNotified = false
    self.nLastAppliedSpeed = nil
    self.nReturnToMenuTimer = nil
    local sName = self.sLastPartner
    self:_SendHandshakeHello()
    CareerSync.OnPeerConnected()
    Vehicles.OnPeerConnected()
    SaveGuard.SyncAutosaveState()
    if Bridge.GetRole() == "host" then
      self:_Notify((sName or "A friend") .. " joined your zoo", "Green")
      self:_SendBaseline()
    else
      self:_Notify(sName and ("Connected to " .. sName .. "'s zoo") or "Connected to host's zoo", "Green")
    end
  elseif sEvent == "peer_disconnected" then
    Vehicles.OnPeerDisconnected()
    local sName = self.sLastPartner or "Your friend"
    self.sLastPartner = nil
    self.nLastAppliedSpeed = nil
    self.bMismatchNotified = false
    SaveGuard.SyncAutosaveState()
    if Bridge.IsGuestWorld() and not Bridge.IsLoopback() then
      self:_Notify("Host left the co-op session — returning to main menu", "Red")
      self:_ScheduleReturnToMenu(2.0, "host disconnected")
    else
      self:_Notify(sName .. " left the co-op session", "Red")
    end
  elseif sEvent == "left" then
    Vehicles.OnPeerDisconnected()
    self.sLastPartner = nil
    self.nLastAppliedSpeed = nil
    self.bMismatchNotified = false
    SaveGuard.SyncAutosaveState()
  elseif sEvent == "error" then
    local sCode = tostring(_tEvent.code)
    if sCode == "connection_lost" then
      if Bridge.IsGuestWorld() and not Bridge.IsLoopback() then
        if self.nReturnToMenuTimer == nil then
          self:_Notify("Connection to host lost — returning to main menu", "Red")
          self:_ScheduleReturnToMenu(2.0, "connection lost")
        end
      else
        self:_Notify("Connection to host lost", "Red")
      end
    elseif sCode == "connect_failed" then
      self:_Notify("Could not connect to host", "Red")
    elseif sCode == "zoo_transfer_failed" then
      self:_Notify("Host zoo download failed", "Red")
    end
  end
end

PZ2CoopManager._OnMessage = function(self, _tMsg)
  if _tMsg.sKind == "event" then
    self:_OnSessionEvent(_tMsg.tData)
    return
  end
  if _tMsg.nType == c_nHandshakeHello then
    local sMismatch = Bridge.GetVersionMismatch and Bridge.GetVersionMismatch()
    if sMismatch ~= nil and not self.bMismatchNotified then
      self.bMismatchNotified = true
      self:_Notify("Mod version mismatch (" .. sMismatch .. ")", "Red")
    end
    return
  end
  if _tMsg.nType == c_nSaveLoadCommit and _tMsg.sFile ~= nil then
    self:_LoadBaseline(_tMsg.sFile)
  elseif _tMsg.nType == c_nLedgerSync then
    self:_ApplyLedger(_tMsg.tData)
  elseif Vehicles.OnPacket(_tMsg) then
    return
  elseif Presence.OnPacket(_tMsg) then
    return
  elseif Actions.OnPacket(_tMsg) then
    return
  elseif WaterSync.OnPacket(_tMsg) then
    return
  elseif TerrainSync.OnPacket(_tMsg) then
    return
  elseif StaffSync.OnPacket(_tMsg) then
    return
  elseif ResearchSync.OnPacket(_tMsg) then
    return
  elseif CareerSync.OnPacket(_tMsg) then
    return
  elseif AnimalSync.OnPacket(_tMsg) then
    return
  elseif not RegionSync.OnPacket(_tMsg) then
    BuildSync.OnPacket(_tMsg)
  end
end

-- ---- save handshake (ARCHITECTURE.md §3.A, LUA_API_MAP.md §6) ---------------------------------------
-- ponytail: assumes SaveParkToFile / RequestLoadParkFromFile accept Bridge.GetPrefix() paths and land in
-- the DLL's folder. diag.log's file hook shows the real path on first use.
PZ2CoopManager._SendBaseline = function(self)
  if self.saveJob ~= nil then
    return
  end
  self.saveJob = coroutine.create(function()
    local parkLoadSaveManager = api.game.GetEnvironment():RequireInterface("Interfaces.IParkLoadSaveManager")
    local bOk, sResult = parkLoadSaveManager:SaveParkToFile(Bridge.GetPrefix() .. c_sBaselineName, false, true)
    Bridge.Log("baseline save ok=" .. tostring(bOk) .. " result=" .. tostring(sResult))
    if not bOk then
      return
    end
    Bridge.SendPacket(c_nSaveChunkData, c_sBaselineName .. ".bin", {})
    self.bLedgerDirty = true
  end)
end

PZ2CoopManager._UpdateSaveJob = function(self)
  if self.saveJob == nil then
    return
  end
  local bOk, sError = coroutine.resume(self.saveJob)
  if not bOk then
    Bridge.Log("baseline job failed: " .. tostring(sError))
    self.saveJob = nil
  elseif coroutine.status(self.saveJob) == "dead" then
    self.saveJob = nil
  end
end

-- Client: the host's park replaces ours. The world transition restarts this manager; the bridge and
-- the Steam session (in version.dll) survive it.
PZ2CoopManager._LoadBaseline = function(self, _sFile)
  if Bridge.GetRole() ~= "client" and not Bridge.IsLoopback() then
    return
  end
  local bRealClient = Bridge.GetRole() == "client" and not Bridge.IsLoopback()
  if bRealClient then
    Bridge.SetGuestWorld(true)
    SaveGuard.SyncAutosaveState()
  end
  local tGameEnv = api.game.GetEnvironment()
  local sMode = Bridge.GetHostGameMode and Bridge.GetHostGameMode() or "Sandbox"
  local sScenario = Bridge.GetHostScenarioCode and Bridge.GetHostScenarioCode() or nil
  local sDiff = Bridge.GetHostDifficulty and Bridge.GetHostDifficulty() or nil
  local bWild = Bridge.GetHostIsWildArea and Bridge.GetHostIsWildArea() == true or false
  if bRealClient then
    pcall(function()
      local nextWorld = (tGameEnv.RequestInterface ~= nil and tGameEnv:RequestInterface("Interfaces.INextWorldDataManager"))
        or tGameEnv:RequireInterface("Interfaces.INextWorldDataManager")
      if nextWorld ~= nil then
        if nextWorld.SetIsWildArea ~= nil then
          nextWorld:SetIsWildArea(bWild)
        end
        if nextWorld.SetGameMode ~= nil then
          nextWorld:SetGameMode(sMode)
        end
        if sScenario ~= nil and nextWorld.SetScenarioCode ~= nil then
          nextWorld:SetScenarioCode(sScenario)
        end
        if sDiff ~= nil and nextWorld.SetGameDifficulty ~= nil then
          nextWorld:SetGameDifficulty(sDiff)
        end
      end
    end)
  end
  local parkLoadSaveManager = tGameEnv:RequireInterface("Interfaces.IParkLoadSaveManager")
  local bOk, sError = parkLoadSaveManager:RequestLoadParkFromFile(_sFile)
  Bridge.Log("loading host baseline (" .. sMode ..
    (sScenario and (" scenario=" .. sScenario) or "") .. ") " .. tostring(_sFile) .. ": " ..
    tostring(bOk) .. " " .. tostring(sError))
end

-- ---- host-authoritative ledger + simulation speed (CLAUDE.md rule 5, LUA_API_MAP.md §7) -------------
PZ2CoopManager._ReadSimSpeedAndTod = function(self)
  local nSpeed = 1
  local nTod = 0
  pcall(function()
    local worldScript = api.world.GetScript(api.world.GetActive())
    local mainHUD = worldScript and worldScript.GetHUD and worldScript:GetHUD()
    if mainHUD ~= nil and mainHUD.GetSimulationTimeSettings ~= nil then
      local tSim = mainHUD:GetSimulationTimeSettings()
      if type(tSim) == "table" then
        if tSim.bPaused then
          nSpeed = 0
        else
          nSpeed = math.max(1, math.min(3, math.floor(tonumber(tSim.nTimeScaleIndex) or 1)))
        end
      end
    end
  end)
  pcall(function()
    local park = api.world.GetWorldAPIs().park
    if park ~= nil and park.GetTimeOfDay ~= nil then
      local nHour, nMinute = park:GetTimeOfDay()
      if type(nHour) == "number" then
        nTod = math.max(0, math.min(23.99, nHour + (type(nMinute) == "number" and nMinute or 0) / 60.0))
      end
    end
  end)
  return nSpeed, nTod
end

PZ2CoopManager._UpdateLedger = function(self, _nDt)
  if Bridge.GetRole() ~= "host" or not (Bridge.IsPeerConnected() or Bridge.IsLoopback()) then
    return
  end
  self.nLedgerTimer = self.nLedgerTimer - _nDt
  if self.nLedgerTimer > 0 and not self.bLedgerDirty then
    return
  end
  self.nLedgerTimer = c_nLedgerInterval
  self.bLedgerDirty = false
  local money = api.world.GetWorldAPIs().money
  -- Solo test: the first looped-back ledger claims 1.00 more cash than this zoo has, so the client-side
  -- overwrite (ModifyCash delta) is exercised once; later ledgers carry the real value and change nothing.
  local nTestExtra = 0
  if Bridge.IsLoopback() and not self.bLedgerTested then
    self.bLedgerTested = true
    nTestExtra = 100
  end
  local nSpeed, nTod = self:_ReadSimSpeedAndTod()
  Bridge.SendPacket(c_nLedgerSync, nil, {
    cash = math.floor(money:GetCash() * 100 + 0.5) + nTestExtra,
    cc = math.floor(money:GetConservationCredits() + 0.5),
    speed = nSpeed,
    tod = nTod,
    t = nTestExtra > 0 and 1 or nil,
  })
end

-- There is no SetCash, so the client converges with a delta. Game speed mirrors host (0=paused, 1..3=1x/2x/5x).
PZ2CoopManager._ApplyLedger = function(self, _tData)
  if (Bridge.GetRole() ~= "client" and not Bridge.IsLoopback()) or type(_tData.cash) ~= "number" then
    return
  end
  local tWorldAPIs = api.world.GetWorldAPIs()
  local money = tWorldAPIs.money
  if not money:HasUnlimitedCash() then
    local nBefore = money:GetCash()
    local nDelta = _tData.cash / 100 - nBefore
    if math.abs(nDelta) >= 0.01 then
      Bridge.BeginApply()
      money:ModifyCash(nDelta, tWorldAPIs.park.ExpenditureCategory_Rewards)
      Bridge.EndApply()
      if _tData.t == 1 or not self.bLedgerLogged then
        self.bLedgerLogged = true
        Bridge.Log(string.format("ledger: cash overwritten %.2f -> %.2f (host says %.2f)%s", nBefore, money:GetCash(),
          _tData.cash / 100, _tData.t == 1 and " [solo test +1.00]" or ""))
      end
    end
  elseif not self.bLedgerLogged then
    self.bLedgerLogged = true
    Bridge.Log("ledger: this zoo has unlimited cash, overwrite skipped (test money in a zoo with a budget)")
  end
  -- Mirror host simulation speed & time-of-day on real clients (never override locally during solo loopback).
  if Bridge.GetRole() == "client" and type(_tData.speed) == "number" then
    local nSpeed = math.floor(_tData.speed + 0.5)
    if nSpeed >= 0 and nSpeed <= 3 and nSpeed ~= self.nLastAppliedSpeed then
      self.nLastAppliedSpeed = nSpeed
      pcall(function()
        local worldScript = api.world.GetScript(api.world.GetActive())
        local mainHUD = worldScript and worldScript.GetHUD and worldScript:GetHUD()
        if mainHUD ~= nil and mainHUD.ChangeSimulationSpeedSettings ~= nil then
          if nSpeed == 0 then
            mainHUD:ChangeSimulationSpeedSettings(true, nil)
          else
            mainHUD:ChangeSimulationSpeedSettings(false, nSpeed)
          end
        end
      end)
    end
  end
  if Bridge.GetRole() == "client" and type(_tData.tod) == "number" and _tData.tod >= 0 and _tData.tod < 24 then
    pcall(function()
      local park = tWorldAPIs.park
      if park ~= nil and park.GetTimeOfDay ~= nil and park.OverrideApparentTimeOfDay ~= nil then
        local nHour, nMin = park:GetTimeOfDay()
        local nLocalTod = (type(nHour) == "number" and nHour or 0) + (type(nMin) == "number" and nMin or 0) / 60.0
        local nDiff = math.abs(nLocalTod - _tData.tod)
        if nDiff > 12 then
          nDiff = 24 - nDiff
        end
        if nDiff > 0.25 then
          park:OverrideApparentTimeOfDay(true, _tData.tod / 24.0)
        end
      end
    end)
  end
end

-- ---- message probe ---------------------------------------------------------------------------------
PZ2CoopManager._RegisterProbes = function(self)
  for _, sName in ipairs(c_tProbeTypes) do
    local nType = api.messaging[sName]
    if nType ~= nil then
      local fnReceiver = function(_tMessages)
        self:_Probe(sName, _tMessages)
      end
      self.tReceivers[nType] = fnReceiver
      api.messaging.RegisterReceiver(nType, fnReceiver)
    end
  end
end

PZ2CoopManager._Probe = function(self, _sName, _tMessages)
  local nCount = self.tProbeCounts[_sName] or 0
  if nCount >= c_nProbeLimit or type(_tMessages) ~= "table" then
    return
  end
  self.tProbeCounts[_sName] = nCount + 1
  local tLines = {_sName}
  for i, tMessage in ipairs(_tMessages) do
    if type(tMessage) == "table" then
      for k, v in pairs(tMessage) do
        table.insert(tLines, string.format("[%d] %s = %s (%s)", i, tostring(k), tostring(v), type(v)))
      end
    else
      table.insert(tLines, string.format("[%d] %s", i, tostring(tMessage)))
    end
  end
  local sLine = table.concat(tLines, " | ")
  if #sLine > c_nProbeLineMax then
    sLine = string.sub(sLine, 1, c_nProbeLineMax) .. " ...(" .. #_tMessages .. " messages)"
  end
  Bridge.Log("probe " .. sLine)
end
