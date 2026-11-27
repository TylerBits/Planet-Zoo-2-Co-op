-- Guest save & autosave protection (src/ovl_mod/pz2coop.saveguard.lua).
-- Prevents a joining friend from autosaving, save-on-exiting, or manually saving the host's world into their
-- own local save slots (including after a disconnect while the host's downloaded park is still loaded).
-- Host and solo play remain completely unaffected; blueprint saving is untouched.
local global = _G
local api = global.api
local string = global.string
local table = global.table
local tostring = global.tostring
local type = global.type
local pcall = global.pcall
local rawget = global.rawget
local rawset = global.rawset
local require = global.require
local Bridge = require("PZ2Coop.Bridge")

local SaveGuard = module(...)

local c_sReason = "PZ2CoopClient"
local c_sBlockedError = "CoopGuestReadOnly"
local c_sToastMsg = "Only the host can save this zoo"

local s = rawget(global, "__PZ2CoopSaveGuardState")
if s == nil then
  s = {
    oSuspension = nil,
    bSlotCleared = false,
    bSuspendedLogged = false,
    nLastToast = -10,
  }
  rawset(global, "__PZ2CoopSaveGuardState", s)
end

local Log = function(_sMsg)
  Bridge.Log("save guard: " .. _sMsg)
end

local GetClock = function()
  local bOk, nNow = pcall(function()
    return api.time and api.time.GetTotalTimeUnscaled and api.time.GetTotalTimeUnscaled()
  end)
  return (bOk and type(nNow) == "number") and nNow or 0
end

local NotifyBlocked = function(_sWhat)
  Log("blocked guest save (" .. tostring(_sWhat) .. ")")
  local nNow = GetClock()
  if nNow - (s.nLastToast or -10) < 2.0 then
    return
  end
  s.nLastToast = nNow
  pcall(function()
    local tWorld = api.world and api.world.GetActive and api.world.GetScript and api.world.GetScript(api.world.GetActive())
    local tEnv = tWorld and tWorld.tEnvironment
    local nm = tEnv and tEnv.RequestInterface and tEnv:RequestInterface("Interfaces.INotificationManager")
    if nm ~= nil and type(nm.tTimelinePopOutQueue) == "table" then
      table.insert(nm.tTimelinePopOutQueue, {
        nTimeShown = 0,
        bActionable = false,
        sColour = "Red",
        tEntry = {
          sTimelineEntryName = "VIPEntered",
          sNotificationString = "[STRING_LITERAL:Value=|" .. c_sToastMsg .. "|]",
        },
      })
    end
  end)
end

local GetParkLoadSaveManager = function()
  local bOk, mgr = pcall(function()
    local env = api.game and api.game.GetEnvironment and api.game.GetEnvironment()
    if env == nil then
      return nil
    end
    if env.RequestInterface ~= nil then
      return env:RequestInterface("Interfaces.IParkLoadSaveManager")
    end
    if env.RequireInterface ~= nil then
      return env:RequireInterface("Interfaces.IParkLoadSaveManager")
    end
    return nil
  end)
  return bOk and mgr or nil
end

local GetAutosaveIdent = function()
  local bOk, sIdent = pcall(function()
    if api.save ~= nil and api.save.GetIdentForSaveID ~= nil and api.save.ID_ZooAutosave ~= nil then
      return api.save.GetIdentForSaveID(api.save.ID_ZooAutosave)
    end
    return "zooauto"
  end)
  return (bOk and type(sIdent) == "string" and sIdent ~= "") and sIdent or "zooauto"
end

-- Synchronizes the native C++ autosave suspension control and clears any armed zooauto slot for guests.
SaveGuard.SyncAutosaveState = function()
  local bGuest = Bridge.IsGuestWorld()
  if bGuest then
    if s.oSuspension == nil then
      local bOk, oCtrl = pcall(function()
        if api.save == nil or api.save.CreateSaveSuspensionControl == nil then
          return nil
        end
        local ctrl = api.save.CreateSaveSuspensionControl()
        if ctrl ~= nil and ctrl.SuspendAutosave ~= nil then
          ctrl:SuspendAutosave(api.player.GetGameOwner(), GetAutosaveIdent(), c_sReason)
          return ctrl
        end
        return nil
      end)
      if bOk and oCtrl ~= nil then
        s.oSuspension = oCtrl
        if not s.bSuspendedLogged then
          s.bSuspendedLogged = true
          Log("autosave suspended for guest world")
        end
      end
    end
    if not s.bSlotCleared then
      local mgr = GetParkLoadSaveManager()
      if mgr ~= nil and mgr.ClearAutosaveSlot ~= nil then
        local bCleared = pcall(mgr.ClearAutosaveSlot, mgr)
        if bCleared then
          s.bSlotCleared = true
          Log("cleared guest autosave slot")
        end
      end
    end
  else
    if s.oSuspension ~= nil then
      pcall(function()
        if s.oSuspension.ResumeAutosave ~= nil then
          s.oSuspension:ResumeAutosave()
        end
      end)
      s.oSuspension = nil
      s.bSuspendedLogged = false
      Log("autosave resumed")
    end
    s.bSlotCleared = false
  end
end

local WrapMethod = function(_tTarget, _sMethod, _fnWrap)
  if type(_tTarget) ~= "table" then
    return false
  end
  local sKey = "__PZ2CoopSG_" .. _sMethod
  if rawget(_tTarget, sKey) ~= nil then
    return false
  end
  local fnOrig = _tTarget[_sMethod]
  if type(fnOrig) ~= "function" then
    return false
  end
  rawset(_tTarget, sKey, fnOrig)
  _tTarget[_sMethod] = function(...)
    return _fnWrap(fnOrig, ...)
  end
  return true
end

local WrapParkLoadSaveTable = function(_tMgr)
  if type(_tMgr) ~= "table" then
    return
  end
  WrapMethod(_tMgr, "SelectAppropriateAutosaveSlot", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      Log("blocked SelectAppropriateAutosaveSlot on guest world")
      if self.ClearAutosaveSlot ~= nil then
        pcall(self.ClearAutosaveSlot, self)
      end
      s.bSlotCleared = true
      return
    end
    return _fnOrig(self, ...)
  end)
  WrapMethod(_tMgr, "_SelectAppropriateAutosaveSlot", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      return
    end
    return _fnOrig(self, ...)
  end)
  WrapMethod(_tMgr, "OnAutosaveComplete", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      Log("suppressed OnAutosaveComplete on guest world")
      return
    end
    return _fnOrig(self, ...)
  end)
  WrapMethod(_tMgr, "SaveParkToSlot", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("SaveParkToSlot")
      return false, c_sBlockedError
    end
    return _fnOrig(self, ...)
  end)
  WrapMethod(_tMgr, "SaveParkToSaveToken", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("SaveParkToSaveToken")
      return false, c_sBlockedError
    end
    return _fnOrig(self, ...)
  end)
  -- Loading one of the player's own saves (or a Workshop park) leaves the host's world and restores saving.
  WrapMethod(_tMgr, "LoadParkFromSaveToken", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      Log("loading local save: clearing guest world lock")
      Bridge.SetGuestWorld(false)
      if Bridge.GetRole() == "client" then
        Bridge.SendCommand("leave")
      end
      SaveGuard.SyncAutosaveState()
    end
    return _fnOrig(self, ...)
  end)
end

local InstallParkLoadSaveHooks = function()
  local bOk, ParkLoadSaveManager = pcall(require, "Managers.ParkLoadSaveManager")
  if bOk and type(ParkLoadSaveManager) == "table" then
    WrapParkLoadSaveTable(ParkLoadSaveManager)
  end
  local mgr = GetParkLoadSaveManager()
  if type(mgr) == "table" then
    WrapParkLoadSaveTable(mgr)
  end
end

local InstallSaveAgentHooks = function()
  local bOk, SaveAgent = pcall(require, "Windows.SaveAgent")
  if not bOk or type(SaveAgent) ~= "table" then
    return
  end
  WrapMethod(SaveAgent, "OnPauseMenu_ReturnToStartScreen", function(_fnOrig, self, _hudUI, _bSuppressSave, _bTakeScreenshot, ...)
    if Bridge.IsGuestWorld() then
      Log("exit to main menu without saving host zoo")
      if Bridge.GetRole() == "client" then
        Bridge.SendCommand("leave")
        Bridge.Flush(true)
      end
      return _fnOrig(self, _hudUI, true, false, ...)
    end
    if Bridge.GetRole() == "host" then
      Log("host returning to start screen: closing co-op room")
      Bridge.SendCommand("leave")
      Bridge.Flush(true)
    end
    return _fnOrig(self, _hudUI, _bSuppressSave, _bTakeScreenshot, ...)
  end)
  WrapMethod(SaveAgent, "OnPauseMenu_QuitGame", function(_fnOrig, self, _hudUI, _bSuppressSave, _bTakeScreenshot, ...)
    if Bridge.IsGuestWorld() then
      Log("quit game without saving host zoo")
      if Bridge.GetRole() == "client" then
        Bridge.SendCommand("leave")
        Bridge.Flush(true)
      end
      return _fnOrig(self, _hudUI, true, false, ...)
    end
    if Bridge.GetRole() == "host" then
      Log("host quitting game: closing co-op room")
      Bridge.SendCommand("leave")
      Bridge.Flush(true)
    end
    return _fnOrig(self, _hudUI, _bSuppressSave, _bTakeScreenshot, ...)
  end)
  WrapMethod(SaveAgent, "OnPauseMenu_SaveCareerZoo", function(_fnOrig, self, _fnOnSaveCompleteCallback, _bTakeScreenshot, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("OnPauseMenu_SaveCareerZoo")
      if self._SetIsSavingGame ~= nil then
        pcall(self._SetIsSavingGame, self, false)
      end
      if type(_fnOnSaveCompleteCallback) == "function" then
        pcall(_fnOnSaveCompleteCallback, false, c_sBlockedError)
      end
      return
    end
    return _fnOrig(self, _fnOnSaveCompleteCallback, _bTakeScreenshot, ...)
  end)
  WrapMethod(SaveAgent, "SaveCareerZooNowWithoutMessage", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("SaveCareerZooNowWithoutMessage")
      if self._SetIsSavingGame ~= nil then
        pcall(self._SetIsSavingGame, self, false)
      end
      return false, c_sBlockedError
    end
    return _fnOrig(self, ...)
  end)
  WrapMethod(SaveAgent, "OnSaveLoad_Overwrite", function(_fnOrig, self, _sID, _bSaveAndQuit, _fnOnSaveCompleteCallback, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("OnSaveLoad_Overwrite")
      if type(_fnOnSaveCompleteCallback) == "function" then
        pcall(_fnOnSaveCompleteCallback, false)
      end
      return
    end
    return _fnOrig(self, _sID, _bSaveAndQuit, _fnOnSaveCompleteCallback, ...)
  end)
  WrapMethod(SaveAgent, "OnSaveLoad_NewSave", function(_fnOrig, self, _sID, _bSaveAndQuit, _fnOnSaveCompleteCallback, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("OnSaveLoad_NewSave")
      if type(_fnOnSaveCompleteCallback) == "function" then
        pcall(_fnOnSaveCompleteCallback, false)
      end
      return
    end
    return _fnOrig(self, _sID, _bSaveAndQuit, _fnOnSaveCompleteCallback, ...)
  end)
  WrapMethod(SaveAgent, "_SaveNow", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("_SaveNow")
      if self._SetIsSavingGame ~= nil then
        pcall(self._SetIsSavingGame, self, false)
      end
      return false, c_sBlockedError
    end
    return _fnOrig(self, ...)
  end)
end

local InstallMainHUDHooks = function()
  local bOk, MainHUD = pcall(require, "Windows.MainHUD")
  if not bOk or type(MainHUD) ~= "table" then
    return
  end
  WrapMethod(MainHUD, "SaveCareer", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("MainHUD.SaveCareer")
      return
    end
    return _fnOrig(self, ...)
  end)
  WrapMethod(MainHUD, "OnSaveLoad_Overwrite", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("MainHUD.OnSaveLoad_Overwrite")
      return
    end
    return _fnOrig(self, ...)
  end)
  WrapMethod(MainHUD, "OnSaveLoad_NewSave", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      NotifyBlocked("MainHUD.OnSaveLoad_NewSave")
      return
    end
    return _fnOrig(self, ...)
  end)
end

local InstallScenarioAutosaveHook = function()
  local bOk, EventAutosave = pcall(require, "Events.EventActionRequestAutosave")
  if not bOk or type(EventAutosave) ~= "table" then
    return
  end
  WrapMethod(EventAutosave, "Execute", function(_fnOrig, self, ...)
    if Bridge.IsGuestWorld() then
      Log("blocked scenario EventActionRequestAutosave on guest world")
      local bSuperOk, SuperEvent = pcall(require, "Events.Event")
      if bSuperOk and type(SuperEvent) == "table" and type(SuperEvent.Execute) == "function" then
        return SuperEvent.Execute(self)
      end
      return
    end
    return _fnOrig(self, ...)
  end)
end

-- Also catches Career/Scenario fanfare "Return to Menu" (ObjectiveManager.ReturnToMainMenu) and any
-- other path that returns to the main menu, without firing when opening the Conservation Map / Animal Market.
local InstallReturnToMenuHooks = function()
  local fnWrap = function(_fnOrig, self, ...)
    if Bridge.GetRole() == "host" then
      Log("host leaving world to start screen: closing co-op room")
      Bridge.SendCommand("leave")
      Bridge.Flush(true)
    end
    return _fnOrig(self, ...)
  end
  local bOk, BgMgr = pcall(require, "Managers.BackgroundWorldDataManager")
  if bOk and type(BgMgr) == "table" then
    WrapMethod(BgMgr, "SetupHUDForReturnToStartScreen", fnWrap)
  end
  local bEnvOk, oBg = pcall(function()
    local env = api.game and api.game.GetEnvironment and api.game.GetEnvironment()
    if env ~= nil and env.RequestInterface ~= nil then
      return env:RequestInterface("Interfaces.IBackgroundWorldDataManager")
    end
    return nil
  end)
  if bEnvOk and type(oBg) == "table" then
    WrapMethod(oBg, "SetupHUDForReturnToStartScreen", fnWrap)
  end
end

-- Safe to call every frame: each wrap guards itself with a sentinel key.
SaveGuard.Install = function()
  InstallParkLoadSaveHooks()
  InstallSaveAgentHooks()
  InstallMainHUDHooks()
  InstallScenarioAutosaveHook()
  InstallReturnToMenuHooks()
end

SaveGuard.OnParkStart = function()
  s.bSlotCleared = false
  SaveGuard.Install()
  SaveGuard.SyncAutosaveState()
end

SaveGuard.Shutdown = function()
  if not Bridge.IsGuestWorld() then
    SaveGuard.SyncAutosaveState()
  end
end

SaveGuard.IsSuspended = function()
  return s.oSuspension ~= nil
end
