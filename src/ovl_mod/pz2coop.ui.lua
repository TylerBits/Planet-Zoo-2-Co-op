-- PZ2-Coop Esc-menu integration (co-op screen).
-- 1. Loads our UI overlay (PZ2Coop/UI/PZ2CoopUI.ovl: CoopMenu.js, JoinFriends.js plus patched vanilla menu
--    files; version.dll builds it at start-up from the player's own game files, src/proxy_dll/ui_overlay.cpp) the way GameMain/Main/game.gamescript.lua loads
--    Content0/UI overlays: api.ui2.LoadOverlay -> wait IsOverlayLoaded -> MapResources.
-- 2. Wraps MainHUD.OnPauseMenuUISelect (windows.mainhud.lua): the Esc menu sends
--    PauseMenu_UI_Select("pz2coop_<cmd>[:<arg>]") for our buttons; everything else goes to vanilla.
--    MainHUD binds the method when the HUD is created, so the wrap must be in place before a park loads.
-- 3. Publishes the session as one JSON string in the 'ui' data store (key pz2coopState) for the JS side.
-- 4. Main menu: the Join Friends card (src/ovl_ui/JoinFriends.js) sends PZ2Coop_Select("pz2coop_...") to
--    the Frontend view, where a listener is added next to StartScreenHUD's own (FrontEndUI wrap). A guest
--    who joins from the menu has no park manager, so the host's zoo is loaded here via the start screen.
local global = _G
local api = global.api
local string = global.string
local table = global.table
local math = global.math
local tostring = global.tostring
local ipairs = global.ipairs
local pairs = global.pairs
local pcall = global.pcall
local rawget = global.rawget
local rawset = global.rawset
local setmetatable = global.setmetatable
local type = global.type
local require = global.require
local Bridge = require("PZ2Coop.Bridge")

local UI = module(...)

local c_sOverlay = "PZ2CoopUI"
local c_sOverlayPath = "PZ2Coop/UI/PZ2CoopUI"
local c_nPublishInterval = 0.25
local c_nStatusInterval = 2.0 -- while the co-op screen is open
local c_nFriendsInterval = 5.0
local c_nDebounce = 0.3
local c_nBusyTimeout = 20.0 -- no room/lobby/error answer by then: show an error instead of spinning

-- The game re-runs module files during boot (package cache resets), so state lives in _G like the
-- bridge's: the overlay is loaded once and the publish cache survives.
local s = rawget(global, "__PZ2CoopUIState")
if s == nil then
  s = {
    sOverlay = "idle", -- idle -> loading -> mapped | failed
    nClock = 0,
    nPublishTimer = 0,
    nStatusTimer = 0,
    nFriendsTimer = 0,
    sPublished = nil,
    bScreenOpen = false,
    bWatching = false, -- main menu Join Friends card is shown (keeps the friends count fresh)
    bBusy = false, -- host/join sent, waiting for the DLL's answer
    nBusySince = 0,
    sLastEvent = nil,
    bAvatarsReset = false, -- first friends request of this Lua state asks the DLL to resend pictures
    tAvatarsPublished = {},
    nLastEventTime = -1,
    sPhase = "idle", -- join progress shown on the co-op screen; nPhaseSince = when it last changed
    nPhaseSince = 0,
  }
  rawset(global, "__PZ2CoopUIState", s)
end

-- ---- overlay -------------------------------------------------------------------------------------
local UpdateOverlay = function()
  if s.sOverlay == "idle" then
    local bOk, sError = pcall(api.ui2.LoadOverlay, c_sOverlay, c_sOverlayPath)
    s.sOverlay = bOk and "loading" or "failed"
    Bridge.Log("ui overlay LoadOverlay " .. c_sOverlayPath .. ": " .. (bOk and "requested" or tostring(sError)))
  elseif s.sOverlay == "loading" then
    local bOk, bLoaded = pcall(api.ui2.IsOverlayLoaded, c_sOverlay)
    if not bOk then
      s.sOverlay = "failed"
      Bridge.Log("ui overlay IsOverlayLoaded error: " .. tostring(bLoaded))
    elseif bLoaded then
      local bMapped, sError = pcall(api.ui2.MapResources, c_sOverlay)
      s.sOverlay = bMapped and "mapped" or "failed"
      Bridge.Log("ui overlay MapResources: " .. (bMapped and "ok" or tostring(sError)))
    end
  end
end

-- ---- commands from the co-op screen --------------------------------------------------------------
local RequestFriends = function()
  if s.bAvatarsReset then
    Bridge.SendCommand("friends")
  else
    s.bAvatarsReset = true
    Bridge.SendCommand("friends", {reset = "1"})
  end
end

-- Loaded on first use: the presence module belongs to the park, this one runs from boot.
local GetPresence = function()
  local bOk, Presence = pcall(require, "PZ2Coop.Presence")
  return bOk and type(Presence) == "table" and Presence or nil
end

local GetActions = function()
  local bOk, Actions = pcall(require, "PZ2Coop.Actions")
  return bOk and type(Actions) == "table" and Actions or nil
end

local GetVehicles = function()
  local bOk, Vehicles = pcall(require, "PZ2Coop.Vehicles")
  return bOk and type(Vehicles) == "table" and Vehicles or nil
end

local GetSaveGuard = function()
  local bOk, SaveGuard = pcall(require, "PZ2Coop.SaveGuard")
  return bOk and type(SaveGuard) == "table" and SaveGuard or nil
end

local RequestRefresh = function(_bFriends)
  Bridge.SendCommand("status")
  if _bFriends then
    RequestFriends()
  end
end

-- Joining is offered in a synced park (Sandbox/Challenge) and on the main menu; never in Franchise.
local CanJoin = function()
  return Bridge.GetRole() == "none" and (Bridge.IsSyncedPark() or Bridge.IsStartScreenActive())
end

local StartJoin = function(_tArgs)
  s.bBusy = true
  s.nBusySince = s.nClock
  Bridge.GetSession().sError = nil
  Bridge.SendCommand("join", _tArgs)
end

-- Arguments come from the UI's text box, so each is checked before it reaches the DLL.
local c_tCommands = {
  open = function()
    s.bScreenOpen = true
    s.nStatusTimer = c_nStatusInterval
    s.nFriendsTimer = c_nFriendsInterval
    RequestRefresh(true)
  end,
  close = function()
    s.bScreenOpen = false
  end,
  refresh = function()
    RequestRefresh(true)
  end,
  host = function()
    if Bridge.IsSyncedPark() and Bridge.GetRole() == "none" then
      s.bBusy = true
      s.nBusySince = s.nClock
      Bridge.GetSession().sError = nil
      Bridge.SendCommand("host")
    end
  end,
  join = function(_sArg)
    local sCode = string.match(_sArg or "", "^%s*([%w%-]+)%s*$")
    if sCode == nil or #sCode > 12 then
      Bridge.GetSession().sError = "invalid_room_code"
      return
    end
    if CanJoin() then
      StartJoin({code = sCode})
    end
  end,
  joinlobby = function(_sArg)
    if string.match(_sArg or "", "^%d+$") and CanJoin() then
      StartJoin({lobby = _sArg})
    end
  end,
  -- Main menu card mounted/unmounted: poll friends so its "N Online" pill stays current.
  watch = function(_sArg)
    s.bWatching = _sArg == "on"
    if s.bWatching then
      s.nFriendsTimer = 0
    end
  end,
  leave = function()
    s.bBusy = false
    Bridge.SendCommand("leave")
  end,
  invite = function(_sArg)
    if string.match(_sArg or "", "^%d+$") then
      Bridge.SendCommand("invite", {id = _sArg})
    end
  end,
  privacy = function(_sArg)
    if _sArg == "friends" or _sArg == "public" then
      Bridge.SendCommand("privacy", {type = _sArg})
    end
  end,
  -- Solo test mode, offered only while hosting with nobody connected.
  loopback = function(_sArg)
    if _sArg == "on" and Bridge.GetRole() == "host" and not Bridge.IsPeerConnected() then
      Bridge.SetLoopback(true)
    elseif _sArg == "off" then
      Bridge.SetLoopback(false)
    end
  end,
  testjoin = function()
    if Bridge.IsLoopback() then
      Bridge.RequestTestJoin()
    end
  end,
  -- Walking together & camera jump (pz2coop.presence.lua).
  gotofriend = function()
    local Presence = GetPresence()
    if Presence ~= nil then
      Presence.RequestGoToFriend()
    end
  end,
  viewfriend = function()
    local Presence = GetPresence()
    if Presence ~= nil and Presence.RequestViewFriend ~= nil then
      Presence.RequestViewFriend()
    end
  end,
  resync = function()
    if Bridge.RequestResync ~= nil then
      Bridge.RequestResync()
    end
  end,
  copy = function()
    local sCode = Bridge.GetSession().sCode
    if sCode ~= nil then
      Bridge.SendCommand("clipboard", {text = sCode})
    end
  end,
  -- Radial Emote & Prop Wheel (pz2coop.actions.lua).
  emote = function(_sArg)
    local Actions = GetActions()
    if Actions ~= nil and type(_sArg) == "string" and _sArg ~= "" then
      Actions.PlayEmote(_sArg)
    end
  end,
  emotepage = function(_sArg)
    local Actions = GetActions()
    if Actions ~= nil then
      Actions.SetWheelPage(_sArg)
    end
  end,
  emoteclose = function()
    local Actions = GetActions()
    if Actions ~= nil then
      Actions.SetWheelOpen(false)
    end
  end,
  -- Research Vehicle recall command from the Co-op Esc menu (pz2coop.vehicles.lua).
  vrecall = function(_sArg)
    local Vehicles = GetVehicles()
    if Vehicles ~= nil and Vehicles.QueueUICommand ~= nil then
      Vehicles.QueueUICommand("vrecall", _sArg)
    end
  end,
}

local OnSelect = function(_sEvent)
  -- One click can reach Lua twice (double click, gamepad repeat): identical events within 0.3 s are one.
  if _sEvent == s.sLastEvent and s.nClock - s.nLastEventTime < c_nDebounce then
    return
  end
  s.sLastEvent = _sEvent
  s.nLastEventTime = s.nClock
  local sCmd, sArg = string.match(_sEvent, "^pz2coop_([%a]+):?(.*)$")
  local fnCommand = sCmd and c_tCommands[sCmd]
  if fnCommand == nil then
    Bridge.Log("pause menu: unknown co-op command " .. _sEvent)
    return
  end
  if sCmd ~= "open" and sCmd ~= "close" and sCmd ~= "refresh" and sCmd ~= "watch" then
    Bridge.Log("co-op command " .. sCmd)
  end
  fnCommand(sArg)
  s.nPublishTimer = 0
end

-- Re-checked every frame, like the environment hook, in case the game reloads the module.
local InstallMenuHook = function()
  local bOk, MainHUD = pcall(require, "Windows.MainHUD")
  if not bOk or type(MainHUD) ~= "table" or rawget(MainHUD, "__PZ2CoopOriginalSelect") ~= nil then
    return
  end
  local fnOriginal = MainHUD.OnPauseMenuUISelect
  if fnOriginal == nil then
    return
  end
  rawset(MainHUD, "__PZ2CoopOriginalSelect", fnOriginal)
  MainHUD.OnPauseMenuUISelect = function(self, _sEvent, ...)
    if type(_sEvent) == "string" and string.sub(_sEvent, 1, 8) == "pz2coop_" then
      local bHandled, sError = pcall(OnSelect, _sEvent)
      if not bHandled then
        Bridge.Log("co-op command error: " .. tostring(sError))
      end
      return
    end
    return fnOriginal(self, _sEvent, ...)
  end
  Bridge.Log("pause menu hook installed")
end

-- Main menu: StartScreenHUD registers its Frontend view listeners through FrontEndUI.AddListener_* calls
-- (startscreen.shared.startscreenhud.lua), so wrapping one of them hands us each new Frontend view.
-- The listener lives as long as that view (ViewWrapper.Shutdown drops it).
local InstallFrontendHook = function()
  local bOk, FrontEndUI = pcall(require, "UI.Controllers.FrontEndUI")
  if not bOk or type(FrontEndUI) ~= "table" or rawget(FrontEndUI, "__PZ2CoopOriginalResume") ~= nil then
    return
  end
  local fnOriginal = FrontEndUI.AddListener_Frontend_Resume
  if fnOriginal == nil then
    return
  end
  rawset(FrontEndUI, "__PZ2CoopOriginalResume", fnOriginal)
  FrontEndUI.AddListener_Frontend_Resume = function(self, ...)
    -- A non-nil callback argument comes back first, so the event string is always the 2nd value.
    local bAdded, sError = pcall(self.AddEventListener, self, "PZ2Coop_Select", 1, function(_, _sEvent)
      if type(_sEvent) == "string" and string.sub(_sEvent, 1, 8) == "pz2coop_" then
        local bHandled, sCmdError = pcall(OnSelect, _sEvent)
        if not bHandled then
          Bridge.Log("co-op command error: " .. tostring(sCmdError))
        end
      end
    end, s)
    s.bMenuListenerAdded = bAdded == true
    Bridge.Log("main menu co-op listener: " .. (bAdded and "added" or tostring(sError)))
    return fnOriginal(self, ...)
  end
  Bridge.Log("main menu hook installed")
end

-- Guest joined from the main menu: load the host's zoo in the host's reported game mode & scenario settings.
local LoadFromMenu = function(_sFile)
  local tEnvironment = Bridge.GetStartScreenEnvironment()
  if tEnvironment == nil then
    Bridge.Log("menu join: host zoo arrived but the start screen is gone, not loading " .. tostring(_sFile))
    return
  end
  local sMode = Bridge.GetHostGameMode and Bridge.GetHostGameMode() or "Sandbox"
  local sScenario = Bridge.GetHostScenarioCode and Bridge.GetHostScenarioCode() or nil
  local sDiff = Bridge.GetHostDifficulty and Bridge.GetHostDifficulty() or nil
  local bWild = Bridge.GetHostIsWildArea and Bridge.GetHostIsWildArea() == true or false
  if Bridge.SetGuestWorld ~= nil then
    Bridge.SetGuestWorld(true)
  end
  local SaveGuard = GetSaveGuard()
  if SaveGuard ~= nil then
    SaveGuard.Install()
    SaveGuard.SyncAutosaveState()
  end
  local bOk, bLoaded, sError = pcall(function()
    local nextWorld = tEnvironment:RequireInterface("Interfaces.INextWorldDataManager")
    nextWorld:SetIsWildArea(bWild)
    nextWorld:SetGameMode(sMode)
    if sScenario ~= nil and nextWorld.SetScenarioCode ~= nil then
      nextWorld:SetScenarioCode(sScenario)
    end
    if sDiff ~= nil and nextWorld.SetGameDifficulty ~= nil then
      nextWorld:SetGameDifficulty(sDiff)
    end
    return tEnvironment:RequireInterface("Interfaces.IParkLoadSaveManager"):RequestLoadParkFromFile(_sFile)
  end)
  Bridge.Log("menu join: loading host zoo (" .. sMode ..
    (sScenario and (" scenario=" .. sScenario) or "") .. ") " .. tostring(_sFile) .. ": " .. tostring(bOk) .. " " ..
    tostring(bLoaded) .. " " .. tostring(sError))
  if not bOk or bLoaded == false then
    Bridge.GetSession().sError = "zoo_transfer_failed"
  end
end

-- ---- state for the JS side -----------------------------------------------------------------------
-- Which step of a session the player is waiting on, so the screen can show it with a running timer.
local JoinPhase = function(_tSession, _sRole, _bBusy)
  local tZoo = _tSession.tZoo
  if _sRole == "client" then
    if not Bridge.IsPeerConnected() then
      return "joining"
    elseif tZoo == nil then
      return "waitzoo"
    elseif not tZoo.bReceived then
      return "download"
    end
    return "joined"
  end
  return _bBusy and "connecting" or _sRole
end

local c_tWaitPhases = {connecting = true, joining = true, waitzoo = true, download = true}

local BuildState = function()
  local tSession = Bridge.GetSession()
  local sRole = Bridge.GetRole()
  if sRole ~= "none" or tSession.sError ~= nil then
    s.bBusy = false -- the DLL answered (room/lobby or an error)
  elseif s.bBusy and s.nClock - s.nBusySince > c_nBusyTimeout then
    s.bBusy = false
    tSession.sError = "no_response"
    Bridge.Log("co-op: no answer from version.dll within " .. c_nBusyTimeout .. " s")
  end
  local tFriends = setmetatable({}, api.json.GetArrayMetatable())
  for _, tFriend in ipairs(tSession.tFriends or {}) do
    table.insert(tFriends, {
      id = tostring(tFriend.id),
      name = tostring(tFriend.name),
      playing = tFriend.playing == true,
      lobby = tFriend.lobby ~= "" and tFriend.lobby or nil,
      invited = tSession.tInvited[tostring(tFriend.id)] == true,
    })
  end
  local bBusy = s.bBusy or tSession.bPending == true
  local sPhase = JoinPhase(tSession, sRole, bBusy)
  if sPhase ~= s.sPhase then
    s.sPhase = sPhase
    s.nPhaseSince = s.nClock
    Bridge.Log("co-op phase: " .. sPhase)
  end
  local tZoo = tSession.tZoo
  local Presence = GetPresence()
  local Vehicles = GetVehicles()
  return {
    friendPose = Presence ~= nil and Presence.HasFriend() or nil,
    hasVehicle = Vehicles ~= nil and Vehicles.HasVehicle ~= nil and Vehicles.HasVehicle() or nil,
    allowed = Bridge.IsSyncedPark(),
    canJoin = CanJoin(),
    role = sRole,
    guestWorld = Bridge.IsGuestWorld and Bridge.IsGuestWorld() or (sRole == "client"),
    connected = Bridge.IsPeerConnected(),
    busy = bBusy,
    phase = sPhase,
    -- Only while waiting: a ticking value republishes the JSON every second.
    phaseSecs = c_tWaitPhases[sPhase] and math.floor(s.nClock - s.nPhaseSince) or nil,
    zooGot = tZoo and tZoo.nGot,
    zooTotal = tZoo and tZoo.nTotal,
    zooBytes = tZoo and tZoo.nBytes,
    code = tSession.sCode,
    privacy = tSession.sPrivacy,
    self = tSession.sSelf,
    selfId = tSession.sSelfId,
    partnerId = tSession.sPartnerId,
    avatars = s.tAvatarsPublished,
    partner = tSession.sPartner,
    ping = tSession.nPing,
    error = tSession.sError,
    versionMismatch = Bridge.GetVersionMismatch and Bridge.GetVersionMismatch() or nil,
    friendsAvailable = tSession.bFriendsAvailable,
    friends = tFriends,
    loopback = Bridge.IsLoopback(),
  }
end

-- Pictures go to their own data-store keys (pz2coopAv_<steamid> = "<size>:<base64 RGB>"), once each,
-- so the frequently republished state JSON stays small.
local PublishAvatars = function(_context)
  for sId, tAvatar in pairs(Bridge.GetSession().tAvatars) do
    if not s.tAvatarsPublished[sId] then
      api.ui2.SetDataStoreElement(_context, "pz2coopAv_" .. sId, tostring(tAvatar.nSize) .. ":" .. tAvatar.sRgb)
      s.tAvatarsPublished[sId] = true
    end
  end
end

local PublishEmoteWheel = function()
  local Actions = GetActions()
  if Actions == nil or not Actions.ConsumeWheelDirty() then
    return
  end
  local bOk, sJson = api.json.Stringify(Actions.GetWheelState())
  if not bOk or sJson == s.sEmotePublished then
    return
  end
  local bSet = pcall(function()
    api.ui2.SetDataStoreElement(api.ui2.GetDataStoreContext("ui"), "pz2coopEmoteWheel", sJson)
  end)
  if bSet then
    s.sEmotePublished = sJson
  end
end

local Publish = function()
  pcall(function()
    PublishAvatars(api.ui2.GetDataStoreContext("ui"))
  end)
  pcall(PublishEmoteWheel)
  local bOk, sJson = api.json.Stringify(BuildState())
  if not bOk or sJson == s.sPublished then
    return
  end
  local bSet, sError = pcall(function()
    api.ui2.SetDataStoreElement(api.ui2.GetDataStoreContext("ui"), "pz2coopState", sJson)
  end)
  if bSet then
    s.sPublished = sJson
  elseif s.sPublished ~= false then
    s.sPublished = false
    Bridge.Log("ui data store publish failed: " .. tostring(sError))
  end
end

UI.IsScreenOpen = function()
  return s.bScreenOpen
end

-- Called every frame from the GameScript.OnAdvance wrap (menu and parks).
UI.Update = function(_nDeltaTime)
  s.nClock = s.nClock + _nDeltaTime
  UpdateOverlay()
  InstallMenuHook()
  InstallFrontendHook()
  local SaveGuard = GetSaveGuard()
  if SaveGuard ~= nil then
    SaveGuard.Install()
    SaveGuard.SyncAutosaveState()
  end
  local sMenuLoad = Bridge.TakeMenuLoad()
  if sMenuLoad ~= nil then
    LoadFromMenu(sMenuLoad)
  end
  local sAutotest = Bridge.TakeAutotestPlan and Bridge.TakeAutotestPlan() or nil
  if sAutotest ~= nil then
    local bAutoOk, Autotest = pcall(require, "PZ2Coop.Autotest")
    if bAutoOk and type(Autotest) == "table" then
      Autotest.Start(sAutotest)
    end
  end
  if rawget(global, "__PZ2CoopAutotestState") ~= nil then
    local bAutoOk, Autotest = pcall(require, "PZ2Coop.Autotest")
    if bAutoOk and type(Autotest) == "table" then
      Autotest.Update(_nDeltaTime)
    end
  end
  if s.bScreenOpen or (s.bWatching and Bridge.IsStartScreenActive()) then
    s.nStatusTimer = s.nStatusTimer - _nDeltaTime
    s.nFriendsTimer = s.nFriendsTimer - _nDeltaTime
    if s.nStatusTimer <= 0 then
      s.nStatusTimer = c_nStatusInterval
      Bridge.SendCommand("status")
    end
    if s.nFriendsTimer <= 0 then
      s.nFriendsTimer = c_nFriendsInterval
      RequestFriends()
    end
  end
  pcall(PublishEmoteWheel)
  s.nPublishTimer = s.nPublishTimer - _nDeltaTime
  if s.nPublishTimer <= 0 then
    s.nPublishTimer = c_nPublishInterval
    Publish()
  end
end
