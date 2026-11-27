-- Autonomous in-game feature test harness (triggered ONLY by <game>\PZ2Coop\autotest.txt via tools/test_live_game.py).
-- Completely inert during normal gameplay: zero timers, zero hooks, zero allocations unless Start(plan) is called.
-- Individual plan implementations live in modular pz2coop.at_*.lua files loaded lazily on demand.
local global = _G
local api = global.api
local string = global.string
local table = global.table
local pairs = global.pairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local type = global.type
local rawget = global.rawget
local rawset = global.rawset
local require = global.require
local Bridge = require("PZ2Coop.Bridge")

local Autotest = module(...)

local c_sTestZoo = "/run/PZ2Coop/PZ2Coop_Baseline.bin"
local c_sFlatZoo = "/run/Zoos/Sandbox/Flat/Sandbox_Zoo_01_BL_Rural.bin"

local c_tPlans = {
  full            = { mod = "PZ2Coop.AT_Core",            entry = "test_notifications", needsMenu = true,  needsHost = true,  loopback = true  },
  fences_water    = { mod = "PZ2Coop.AT_Fences_Water",    entry = "fw_inspect",         needsMenu = false, needsHost = false, loopback = false },
  showcase        = { mod = "PZ2Coop.AT_Showcase",        entry = "sc_prepare",         needsMenu = false, needsHost = false, loopback = false },
  gate_probe      = { mod = "PZ2Coop.AT_Gate_Probe",      entry = "gp_setup",           needsMenu = false, needsHost = false, loopback = false },
  explore_preview = { mod = "PZ2Coop.AT_Explore_Preview", entry = "ep_enter",           needsMenu = false, needsHost = false, loopback = false },
  mirror_place    = { mod = "PZ2Coop.AT_Mirror_Place",    entry = "mp_setup",           needsMenu = false, needsHost = true,  loopback = false },
  host_stress     = { mod = "PZ2Coop.AT_Host_Stress",     entry = "hs_cycle",           needsMenu = false, needsHost = true,  loopback = false },
  vehicle_bounds  = { mod = "PZ2Coop.AT_Vehicle_Bounds",  entry = "vb_setup",           needsMenu = false, needsHost = false, loopback = false },
  eval            = { mod = "PZ2Coop.AT_Eval",            entry = "eval_run",           needsMenu = false, needsHost = false, loopback = false },
}

local s = rawget(global, "__PZ2CoopAutotestState")
if s == nil then
  s = {
    bActive = false,
    sPlan = nil,
    sStage = "idle",
    nStageTime = 0,
    nPass = 0,
    nFail = 0,
    bLoadRequested = false,
    bHostRequested = false,
    bExploreStarted = false,
    tAnimProbe = nil,
    bStaffHireSent = false,
    bStaffFireSent = false,
    nStaffCountBefore = 0,
    sStaffSyncId = "autotest_keeper_1",
    tStages = {},
  }
  rawset(global, "__PZ2CoopAutotestState", s)
end

local Now = function()
  local bOk, t = pcall(function() return api.time.GetTotalTimeUnscaled() end)
  return (bOk and type(t) == "number") and t or 0
end

local Log = function(_sMsg)
  Bridge.Log("autotest: " .. _sMsg)
end

local SetStage = function(_sStage)
  s.sStage = _sStage
  s.nStageTime = 0
  Log("stage -> " .. _sStage)
end

local Record = function(_sName, _bPass, _sDetail)
  if _bPass then
    s.nPass = s.nPass + 1
  else
    s.nFail = s.nFail + 1
  end
  Bridge.Log("AUTOTEST_CHECK " .. _sName .. " " .. (_bPass and "PASS" or "FAIL") ..
    (_sDetail and (" | " .. tostring(_sDetail)) or ""))
  if not _bPass and s.bStopOnFail and s.sStage ~= "cleanup" then
    Log("stop-on-fail triggered at " .. tostring(_sName))
    SetStage("cleanup")
  end
end

local Finish = function()
  Bridge.SetLoopback(false)
  if Bridge.GetRole() ~= "none" then
    Bridge.SendCommand("leave")
  end
  local nNow = Now()
  local nBoot = (s.nTimeLoadReq or nNow) - (s.nTimeStart or nNow)
  local nPark = (s.nTimeParkReady or nNow) - (s.nTimeLoadReq or s.nTimeStart or nNow)
  local nPlan = nNow - (s.nTimePlanStart or s.nTimeParkReady or nNow)
  if nBoot < 0 then nBoot = 0 end
  if nPark < 0 then nPark = 0 end
  if nPlan < 0 then nPlan = 0 end
  Bridge.Log(string.format("AUTOTEST_TIMING boot=%.1f park=%.1f plan=%.1f", nBoot, nPark, nPlan))
  Bridge.Log(string.format("AUTOTEST_SUMMARY pass=%d fail=%d", s.nPass, s.nFail))
  Bridge.Log("AUTOTEST_DONE")
  Bridge.Flush(true)
  s.bActive = false
  s.sStage = "done"
end

local EnterPlan = function()
  local tPlan = s.tPlan
  Bridge.SetLoopback(tPlan.loopback == true)
  s.nTimePlanStart = Now()
  SetStage(tPlan.entry)
end

local EnterPark = function()
  s.nTimeParkReady = Now()
  if s.tPlan.needsHost then
    SetStage("park_host")
  else
    EnterPlan()
  end
end

local StepMenu = function()
  if Bridge.IsSyncedPark() then
    Record("park_load", true, "entered synced park")
    EnterPark()
    return
  end
  local tUi = rawget(global, "__PZ2CoopUIState")
  local bOverlayOk = tUi ~= nil and tUi.sOverlay == "mapped"
  local bMenuReady = tUi ~= nil and tUi.bMenuListenerAdded == true
  if not s.bLoadRequested then
    local bReady = Bridge.IsStartScreenActive() and bMenuReady
    if s.tPlan.needsMenu then
      bReady = bReady and bOverlayOk
    end
    if bReady then
      if s.tPlan.needsMenu then
        s.nMenuReadyTime = (s.nMenuReadyTime or 0) + 0.05
        if s.nMenuReadyTime < 0.5 then
          return
        end
        Record("boot_menu", true, "overlay mapped + start screen activated + main menu ready")
      end
      s.bLoadRequested = true
      s.nTimeLoadReq = Now()
      local tEnv = api.game.GetEnvironment()
      local bOk, bLoaded, sErr = pcall(function()
        local nextWorld = tEnv:RequireInterface("Interfaces.INextWorldDataManager")
        nextWorld:SetIsWildArea(false)
        nextWorld:SetGameMode("Sandbox")
        if nextWorld.SetIsCareerExport ~= nil then
          nextWorld:SetIsCareerExport(false)
        end
        local pls = tEnv:RequireInterface("Interfaces.IParkLoadSaveManager")
        local bOkLoad, sLoadErr = pls:RequestLoadParkFromFile(c_sTestZoo)
        if not bOkLoad then
          return pls:RequestLoadParkFromFile(c_sFlatZoo)
        end
        return bOkLoad, sLoadErr
      end)
      Log("requested sandbox park load: ok=" .. tostring(bOk) .. " loaded=" .. tostring(bLoaded) .. " err=" .. tostring(sErr))
      if not bOk or bLoaded == false then
        Record("park_load", false, "RequestLoadParkFromFile failed: " .. tostring(bOk and sErr or bLoaded))
        SetStage("cleanup")
      else
        SetStage("wait_park")
      end
    elseif s.nStageTime >= 45.0 then
      Record("boot_menu", false, "timed out waiting for menu/overlay (overlay=" .. tostring(tUi and tUi.sOverlay) ..
        " menuReady=" .. tostring(bMenuReady) .. " startScreen=" .. tostring(Bridge.IsStartScreenActive()) .. ")")
      SetStage("cleanup")
    end
  end
end

local StepWaitPark = function()
  if Bridge.IsSyncedPark() then
    local bHasWorld, tWorld = pcall(function() return api.world.GetWorldAPIs() end)
    if bHasWorld and tWorld ~= nil then
      Record("park_load", true, "synced Sandbox park loaded")
      EnterPark()
    end
  elseif s.nStageTime >= 60.0 then
    Record("park_load", false, "timed out waiting for park load")
    SetStage("cleanup")
  end
end

local StepParkHost = function()
  if not s.bHostRequested then
    s.bHostRequested = true
    Bridge.SendCommand("host")
    Log("sent host command")
    return
  end
  if Bridge.GetRole() == "host" and Bridge.GetSession().sCode ~= nil then
    Record("host_room", true, "code=" .. tostring(Bridge.GetSession().sCode))
    EnterPlan()
  elseif s.nStageTime >= 20.0 then
    Record("host_room", false, "role=" .. tostring(Bridge.GetRole()) .. " err=" .. tostring(Bridge.GetSession().sError))
    SetStage("cleanup")
  end
end

local StepCleanup = function()
  local nWait = (Bridge.GetRole() == "none") and 0.25 or 1.2
  if s.nStageTime >= nWait then
    Finish()
  end
end

local c_tBaseStages = {
  wait_menu = StepMenu,
  wait_park = StepWaitPark,
  park_host = StepParkHost,
  cleanup = StepCleanup,
}

Autotest.Start = function(_sPlan)
  if s.bActive then
    return
  end
  s.bActive = true
  -- Trigger "<plan>,run.<run_id>[,expref.<n>][,case.<name>][,hot][,stopfail]" (tools/test_live_game.py).
  local sTrigger = tostring(_sPlan or "full")
  s.sPlan = string.match(sTrigger, "^([^,]+)") or "full"
  s.sRunId = string.match(sTrigger, ",run%.([%w_-]+)") or "none"
  s.nExpRef = tonumber(string.match(sTrigger, ",expref%.(%d+)") or "")
  s.sCase = string.match(sTrigger, ",case%.([%w_]+)")
  s.bStopOnFail = string.find(sTrigger, ",stopfail", 1, true) ~= nil
  -- Hot = reused game state (--warm), a single case or hot-swapped logic: never proof for the verify stamp.
  s.bHot = s.sCase ~= nil or string.find(sTrigger, ",hot", 1, true) ~= nil
  local bMeta, BuildMeta = pcall(require, "PZ2Coop.Build_Meta")
  local tMeta = bMeta and type(BuildMeta) == "table" and BuildMeta or {}
  Bridge.Log("AUTOTEST_META run_id=" .. s.sRunId .. " build_hash=" .. tostring(tMeta.BUILD_SOURCE_HASH or "none") ..
    " test_hash=" .. tostring(tMeta.BUILD_TEST_HASH or "none") .. " plan=" .. s.sPlan ..
    (s.bHot and " hot=1" or "") .. (s.sCase and (" case=" .. s.sCase) or ""))
  if s.bHot then
    -- An earlier run in this game session may have left queued jobs, echo areas or undo entries behind.
    local nDropped = 0
    pcall(function() nDropped = require("PZ2Coop.BuildSync").ResetTransient() end)
    pcall(function() require("PZ2Coop.RegionSync").ResetTransient() end)
    -- The apply guard is left alone: a remote job still running owns it and clears it itself (rule 2).
    Log("hot run: transient sync state reset (cleared " .. tostring(nDropped) .. " queued job(s), applying=" ..
      tostring(Bridge.IsApplying()) .. ")")
  end
  -- Reset all per-run & per-plan state cleanly so warm back-to-back runs never leak state.
  s.nPass = 0
  s.nFail = 0
  s.nMenuReadyTime = 0
  s.bLoadRequested = false
  s.bHostRequested = false
  s.bExploreStarted = false
  s.tAnimProbe = nil
  s.bStaffHireSent = false
  s.bStaffFireSent = false
  s.nStaffCountBefore = 0
  s.fw, s.sc, s.gp, s.ep, s.mp, s.hs, s.vb = nil, nil, nil, nil, nil, nil, nil
  s.sEvalHex = Bridge.TakeAutotestEvalHex and Bridge.TakeAutotestEvalHex() or nil
  s.nTimeStart = Now()
  s.nTimeLoadReq = nil
  s.nTimeParkReady = nil
  s.nTimePlanStart = nil

  s.tPlan = c_tPlans[s.sPlan] or c_tPlans.full
  s.tStages = {}
  for k, v in pairs(c_tBaseStages) do
    s.tStages[k] = v
  end
  local bPlanOk, oMod = pcall(require, s.tPlan.mod)
  if bPlanOk and type(oMod) == "table" and type(oMod.Register) == "function" then
    local tPlanStages = oMod.Register({
      s = s,
      Log = Log,
      Record = Record,
      SetStage = SetStage,
      Finish = Finish,
    })
    if type(tPlanStages) == "table" then
      for k, v in pairs(tPlanStages) do
        s.tStages[k] = v
      end
    end
  else
    Record("plan_load", false, "failed to load " .. tostring(s.tPlan.mod) .. ": " .. tostring(oMod))
    SetStage("cleanup")
    return
  end

  Log("started plan=" .. s.sPlan .. " load_avail=" .. tostring(type(rawget(global, "load")) == "function"))
  if Bridge.IsSyncedPark() then
    s.nTimeLoadReq = s.nTimeStart
    Record("park_load", true, "warm park already loaded")
    EnterPark()
  else
    SetStage("wait_menu")
  end
end

Autotest.Update = function(_nDt)
  if not s.bActive then
    return
  end
  s.nStageTime = s.nStageTime + (_nDt or 0)
  local fn = s.tStages and s.tStages[s.sStage] or nil
  if fn ~= nil then
    local bOk, sErr = pcall(fn)
    if not bOk then
      Record("stage_" .. tostring(s.sStage), false, tostring(sErr))
      SetStage("cleanup")
    end
  end
end
