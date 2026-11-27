-- Autotest plan module (loaded lazily by pz2coop.autotest.lua).
local global = _G
local api = global.api
local string = global.string
local table = global.table
local math = global.math
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local type = global.type
local rawget = global.rawget
local rawset = global.rawset
local setmetatable = global.setmetatable
local next = global.next
local coroutine = global.coroutine
local require = global.require
local Bridge = require("PZ2Coop.Bridge")
local H = require("PZ2Coop.AT_Helpers")

local Plan = module(...)

Plan.Register = function(ctx)
  local s, Log, Record, SetStage, Finish = ctx.s, ctx.Log, ctx.Record, ctx.SetStage, ctx.Finish
  local RaycastGroundY, CountFenceInBox, Arr, MakePost, MakePanel = H.RaycastGroundY, H.CountFenceInBox, H.Arr, H.MakePost, H.MakePanel
  local SampleBoneRange, RangeSpan = H.SampleBoneRange, H.RangeSpan

local c_nHostCycles = 15
local c_nThrottleWait = 30.0
local c_nMaxThrottles = 4
local StepHSCycle = function()
  local hs = s.hs
  if hs == nil then
    local vCam = api.world.GetWorldAPIs().CameraModeManager:GetPosYPRZoom()
    hs = {nCycle = 1, nOk = 1, sPhase = "leave", nAt = 0, -- cycle 1 = the host_room check that got us here
      cx = vCam:GetX() - 60, cz = vCam:GetZ(), nThrottled = 0}
    s.hs = hs
    Bridge.SendCommand("leave")
    return
  end
  local nT = s.nStageTime - hs.nAt
  if s.nStageTime >= (hs.nNextPoll or 0) then
    hs.nNextPoll = s.nStageTime + 0.25
    Bridge.SendCommand("status")
    Bridge.SendCommand("friends", hs.bAvatarsReset and nil or {reset = "1"})
    hs.bAvatarsReset = true
  end
  if hs.sPhase == "leave" then
    if Bridge.GetRole() == "none" then
      hs.sPhase, hs.nAt = "gap", s.nStageTime
    elseif nT >= 10.0 then
      hs.sFail = "leave timed out at cycle " .. hs.nCycle
    end
  elseif hs.sPhase == "gap" then
    if nT >= (hs.nCycle % 5) * 0.4 + (hs.bRetry and c_nThrottleWait or 0) then
      if not hs.bRetry then
        hs.nCycle = hs.nCycle + 1
      end
      hs.bRetry = false
      Bridge.GetSession().sError = nil
      hs.bAvatarsReset = false
      Bridge.Log("autotest: host_stress cycle " .. hs.nCycle .. " host + aquarium place")
      local x, z = hs.cx + 40 * (hs.nCycle % 4), hs.cz + 40 * math.floor(hs.nCycle / 4)
      local y = RaycastGroundY(x, z, 0)
      require("PZ2Coop.BuildSync").OnPacket({nType = 0x20, sFile = Bridge.GetPrefix() .. "test_aquarium.bin",
        tData = {x = math.floor(x * 100 + 0.5), y = math.floor(y * 100 + 0.5) + 867, z = math.floor(z * 100 + 0.5)}})
      Bridge.SendCommand("host")
      hs.sPhase, hs.nAt = "host", s.nStageTime
    end
  elseif hs.sPhase == "host" then
    if Bridge.GetRole() == "host" and Bridge.GetSession().sCode ~= nil then
      hs.nOk = hs.nOk + 1
      if hs.nCycle >= c_nHostCycles then
        hs.sPhase = "done"
      else
        Bridge.SendCommand("leave")
        hs.sPhase, hs.nAt = "leave", s.nStageTime
      end
    elseif Bridge.GetSession().sError == "create_lobby_failed" and hs.nThrottled < c_nMaxThrottles then
      hs.nThrottled = hs.nThrottled + 1
      Bridge.Log("autotest: host_stress cycle " .. hs.nCycle .. " CreateLobby throttled, retrying")
      hs.bRetry = true
      hs.sPhase, hs.nAt = "gap", s.nStageTime
    elseif nT >= 20.0 then
      hs.sFail = "no room code at cycle " .. hs.nCycle .. " (err=" .. tostring(Bridge.GetSession().sError) .. ")"
    end
  end
  if hs.sFail ~= nil or hs.sPhase == "done" then
    Record("host_stress", hs.sFail == nil and hs.nOk == c_nHostCycles,
      string.format("cycles=%d ok=%d throttled=%d fail=%s", hs.nCycle, hs.nOk, hs.nThrottled, tostring(hs.sFail)))
    SetStage("cleanup")
  end
end


  return {
    hs_cycle = StepHSCycle,
  }
end
