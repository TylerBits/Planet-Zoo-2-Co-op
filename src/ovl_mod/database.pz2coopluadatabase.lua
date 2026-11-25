-- PZ2-Coop content-pack entry point.
-- GameMain/Main/database.main.lua requires "Database.<PackName>LuaDatabase" for every loaded content
-- pack and calls AddContentToCall; the modules it inserts then receive Main.CallOnContent hooks
-- ("Init" runs from GameDatabase.Init, before any park world exists). See docs/LUA_API_MAP.md §1.
local global = _G
local api = global.api
local table = global.table
local string = global.string
local tostring = global.tostring
local ipairs = global.ipairs
local pcall = global.pcall
local rawget = global.rawget
local rawset = global.rawset
local type = global.type
local require = global.require

local PZ2CoopLuaDatabase = module(...)

-- First-run diagnostics: a marker is written under every candidate root. Whichever files show up on
-- disk prove (a) the pack's Lua ran and (b) where api.debug file paths land (LUA_API_MAP.md §10).
local c_tMarkerRoots = {"/run/", "/run_platform/", "", "./", "../"}

-- Reads are probed too: version.dll's diag.log records every file open whose path contains "pz2coop",
-- so a read attempt proves the Lua ran even if retail turns WriteStringToFile into a no-op.
-- A runtime-built string ("PZ2COOPALIVE" x3 never appears in the source) is kept alive in the Lua heap;
-- version.dll's diagnostics scan process memory for it. It also records, per root, whether reading the
-- DLL's real bridge.txt succeeded, which identifies the working path root even if writes are disabled.
PZ2CoopLuaDatabase.tAlive = {}

PZ2CoopLuaDatabase.WriteMarkers = function(_sStage)
  local sHeader = string.rep("PZ2COOPALIVE", 3) .. "|" .. _sStage .. "|read_fn=" ..
    type(api.debug.ReadStringFromFile) .. " write_fn=" .. type(api.debug.WriteStringToFile) ..
    " json_fn=" .. type(api.json and api.json.Stringify)
  PZ2CoopLuaDatabase.tAlive[_sStage] = sHeader .. "|END"
  local tResults = {}
  for _, sRoot in ipairs(c_tMarkerRoots) do
    local bOk, sResult = pcall(function()
      api.debug.ReadStringFromFile(sRoot .. "PZ2Coop_probe_read_" .. _sStage .. ".txt")
      local bReadOk, sData = api.debug.ReadStringFromFile(sRoot .. "PZ2Coop/bridge.txt")
      local sText = "PZ2Coop stage=" .. _sStage .. " root='" .. sRoot .. "'\n"
      local bWriteOk = api.debug.WriteStringToFile(sText, sRoot .. "PZ2Coop_marker_" .. _sStage .. ".txt")
      return "read=" .. tostring(bReadOk) .. "/" .. tostring(sData ~= nil) .. " write=" .. tostring(bWriteOk)
    end)
    table.insert(tResults, "root=" .. sRoot .. " " .. (bOk and sResult or ("error=" .. tostring(sResult))))
  end
  PZ2CoopLuaDatabase.tAlive[_sStage] = sHeader .. "|" .. table.concat(tResults, ";") .. "|END"
end

PZ2CoopLuaDatabase.WriteMarkers("require")

PZ2CoopLuaDatabase.AddContentToCall = function(_tContentToCall)
  PZ2CoopLuaDatabase.WriteMarkers("addcontent")
  table.insert(_tContentToCall, PZ2CoopLuaDatabase)
end

-- Registers the sync manager in the park world's environment, the same way
-- environments.startscreenenvironment.lua adds AssetsShowroomDebugManager to its prototype.
PZ2CoopLuaDatabase.Init = function()
  PZ2CoopLuaDatabase.WriteMarkers("database")
  PZ2CoopLuaDatabase.StartBridgeTask()
  PZ2CoopLuaDatabase.InstallEnvironmentHook()
end

-- Adding the manager to DarwinEnvironment's prototype at boot does not stick (verified in-game: the
-- park manager never started), so it is added at the moment the park environment is built instead:
-- World.CreateEnvironment calls tEnvironment:Init(sPrototypeModule, ...), resolved through the
-- Environment class table. Re-checked every frame in case the game reloads that module.
local c_sParkPrototype = "Environments.DarwinEnvironment"

PZ2CoopLuaDatabase.InstallEnvironmentHook = function()
  local Environment = require("Environment.Environment")
  if rawget(Environment, "__PZ2CoopOriginalInit") ~= nil then
    return
  end
  local fnOriginal = Environment.Init
  rawset(Environment, "__PZ2CoopOriginalInit", fnOriginal)
  require("PZ2Coop.Bridge").Log("environment hook installed on " .. tostring(Environment))
  -- Lifecycle calls are tracked (and logged) so the park manager can tell the menu from a park.
  for _, sMethod in ipairs({"Shutdown", "Activate", "Deactivate"}) do
    local fnLifecycle = Environment[sMethod]
    Environment[sMethod] = function(self, ...)
      local Bridge = require("PZ2Coop.Bridge")
      Bridge.Log("environment " .. sMethod .. ": " .. tostring(self.sPrototypeModule))
      Bridge.NoteEnvironment(self, self.sPrototypeModule, sMethod)
      return fnLifecycle(self, ...)
    end
  end
  Environment.Init = function(self, _sPrototypeModule, ...)
    local Bridge = require("PZ2Coop.Bridge")
    Bridge.Log("environment init: " .. tostring(_sPrototypeModule))
    Bridge.NoteEnvironment(self, _sPrototypeModule, "Init")
    if _sPrototypeModule == c_sParkPrototype then
      local bOk, sError = pcall(function()
        require(c_sParkPrototype).EnvironmentPrototype.Managers["Managers.PZ2CoopManager"] = {}
      end)
      if not bOk then
        Bridge.Log("could not register park manager: " .. tostring(sError))
      end
    end
    return fnOriginal(self, _sPrototypeModule, ...)
  end
end

-- The bridge must run everywhere (menu included), so it is pumped from the game script's per-frame
-- hook: BaseGame.Advance calls self:OnAdvance every frame, and instances resolve methods through the
-- GameScript class table (Common.object), so wrapping the class method reaches the live game object.
PZ2CoopLuaDatabase.StartBridgeTask = function()
  local Bridge = require("PZ2Coop.Bridge")
  if not Bridge.Open() then
    PZ2CoopLuaDatabase.tAlive.bridge = string.rep("PZ2COOPALIVE", 3) .. "|bridge|codec self-test FAILED|END"
    return
  end
  PZ2CoopLuaDatabase.tAlive.bridge = string.rep("PZ2COOPALIVE", 3) .. "|bridge|opened " ..
    tostring(Bridge.GetTableId()) .. "|END"
  local GameScript = require("Game.GameScript")
  if rawget(GameScript, "__PZ2CoopOriginalOnAdvance") ~= nil then
    return -- already wrapped (database init ran again)
  end
  local fnOriginal = GameScript.OnAdvance
  rawset(GameScript, "__PZ2CoopOriginalOnAdvance", fnOriginal)
  local nFrames = 0
  local bUiErrorLogged = false
  GameScript.OnAdvance = function(self, _nDeltaTime)
    if fnOriginal ~= nil then
      fnOriginal(self, _nDeltaTime)
    end
    PZ2CoopLuaDatabase.InstallEnvironmentHook()
    -- Real time, not game time: the Esc menu pauses the game, and the bridge must keep flushing (and the
    -- co-op screen keep polling) while it is open.
    local bRealOk, nRealDelta = pcall(api.time.GetDeltaTimeUnscaled)
    local nDelta = (bRealOk and type(nRealDelta) == "number") and nRealDelta or _nDeltaTime
    local bUiOk, sUiError = pcall(function()
      require("PZ2Coop.UI").Update(nDelta)
    end)
    if not bUiOk and not bUiErrorLogged then
      bUiErrorLogged = true
      Bridge.Log("ui update error: " .. tostring(sUiError))
    end
    local bOk, sError = pcall(Bridge.Pump, nDelta)
    nFrames = nFrames + 1
    if not bOk then
      PZ2CoopLuaDatabase.tAlive.pumperror = string.rep("PZ2COOPALIVE", 3) .. "|pump|" .. tostring(sError) .. "|END"
      Bridge.Log("pump error: " .. tostring(sError))
    elseif nFrames == 60 then
      PZ2CoopLuaDatabase.tAlive.pump = string.rep("PZ2COOPALIVE", 3) .. "|pump|running 60 frames|END"
    end
  end
end
