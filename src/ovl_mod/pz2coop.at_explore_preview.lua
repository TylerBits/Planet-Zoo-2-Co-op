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

local StepEPEnter = function()
  local BaseUIMode = require("Editors.Shared.BaseUIMode")
  local Vector3 = require("Vector3")
  local Presence = require("PZ2Coop.Presence")
  local tWorld = api.world.GetWorldAPIs()
  if not s.epStarted then
    s.epStarted = true
    local worldScript = api.world.GetScript(api.world.GetActive())
    local hud = worldScript and worldScript:GetHUD()
    if hud and hud.FullScreenUIPause then
      pcall(hud.FullScreenUIPause, hud, false)
    end
    if hud and hud.ChangeSimulationSpeedSettings then
      pcall(hud.ChangeSimulationSpeedSettings, hud, false, 1)
    end
    if api.time and api.time.Unpause then
      for _ = 1, 3 do
        if (api.time.GetDeltaTime and api.time.GetDeltaTime() or 0) <= 0 then
          pcall(api.time.Unpause, "World")
        end
      end
    end
    local vCam = tWorld.CameraModeManager:GetPosYPRZoom()
    local tFinal = tWorld.CameraModeManager:GetCameraDataFinal()
    local vCentre = (tFinal and tFinal.vCentrePos) or vCam or Vector3:new(0, 10, 0)
    local gx, gy, gz = vCentre:GetX(), vCentre:GetY(), vCentre:GetZ()
    if vCam ~= nil then
      local dx, dz = gx - vCam:GetX(), gz - vCam:GetZ()
      local d = math.sqrt(dx * dx + dz * dz)
      if d > 8.0 then
        gx = vCam:GetX() + (dx / d) * 6.0
        gz = vCam:GetZ() + (dz / d) * 6.0
      end
    end
    s.epStartPos = Vector3:new(gx, gy + 1.55, gz)
    s.epOrigStartPos = tWorld.CameraModeManager.GetWalkingStartPos
    tWorld.CameraModeManager.GetWalkingStartPos = function() return s.epStartPos end
    BaseUIMode.SetNewMode("WalkingCameraInit")
    Log(string.format("EP: entered WalkingCameraInit pos=(%.1f,%.1f,%.1f)", gx, gy, gz))
    return
  end
  local tPrev = Presence.GetExplorePreview()
  if tPrev ~= nil and tPrev.nAvatar ~= nil and tPrev.tAnim ~= nil then
    local tok = api.entity.CreateRequestCompletionToken()
    local nFoot = api.entity.InstantiatePrefab("AttachPoint", "PZ2CoopEPFoot", tok, nil, tPrev.nAvatar, true,
      {AttachBone = "def_l_foot_joint"})
    local nHead = api.entity.InstantiatePrefab("AttachPoint", "PZ2CoopEPHead", tok, nil, tPrev.nAvatar, true,
      {AttachBone = "def_c_head_joint"})
    s.ep = {tok = tok, nFoot = nFoot, nHead = nHead,
      minFootY = 1e9, maxFootY = -1e9, minHeadY = 1e9, maxHeadY = -1e9, nSamples = 0,
      footSpan = {n = 0}, bSawLoop = false, nLoopStartClock = nil}
    Record("explore_preview_spawn", true, "entity=" .. tostring(tPrev.nAvatar) .. " initClip=" .. tostring(tPrev.tAnim.sClip))
    SetStage("ep_measure")
    return
  end
  if s.nStageTime >= 15.0 then
    if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
    Record("explore_preview_spawn", false, "timed out waiting for explore preview avatar")
    BaseUIMode.SetNewMode("Select")
    SetStage("cleanup")
  end
end

local StepEPMeasure = function()
  local BaseUIMode = require("Editors.Shared.BaseUIMode")
  local Presence = require("PZ2Coop.Presence")
  local tWorld = api.world.GetWorldAPIs()
  local tPrev = Presence.GetExplorePreview()
  local ep = s.ep
  if tPrev == nil or tPrev.nAvatar == nil or ep == nil then
    if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
    Record("explore_preview_loop", false, "preview vanished during measurement")
    BaseUIMode.SetNewMode("Select")
    SetStage("cleanup")
    return
  end
  if tWorld.bakedanimation and tWorld.bakedanimation.RequestAllBonesForCalculate then
    pcall(tWorld.bakedanimation.RequestAllBonesForCalculate, tWorld.bakedanimation, tPrev.nAvatar)
  end
  if tPrev.sPhase == "loop" then
    if not ep.bSawLoop then
      ep.bSawLoop = true
      ep.nLoopStartClock = s.nStageTime
    end
    local nElapsed = s.nStageTime - ep.nLoopStartClock
    if api.entity.HaveRequestsCompleted(ep.tok) then
      local bOkA, trAv = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, tPrev.nAvatar)
      local bOkF, trF = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, ep.nFoot)
      local bOkH, trH = pcall(tWorld.transform.CalculateWorldTransform, tWorld.transform, ep.nHead)
      if bOkA and trAv ~= nil and bOkF and trF ~= nil and bOkH and trH ~= nil then
        local ay = trAv:GetPos():GetY()
        local fy = trF:GetPos():GetY() - ay
        local hy = trH:GetPos():GetY() - ay
        if fy < ep.minFootY then ep.minFootY = fy end
        if fy > ep.maxFootY then ep.maxFootY = fy end
        if hy < ep.minHeadY then ep.minHeadY = hy end
        if hy > ep.maxHeadY then ep.maxHeadY = hy end
        ep.nSamples = ep.nSamples + 1
        SampleBoneRange(ep.footSpan, ep.nFoot)
      end
    end
    if nElapsed >= 1.8 or s.nStageTime >= 6.0 then
      if ep.nFoot then pcall(api.entity.DestroyEntity, ep.nFoot) end
      if ep.nHead then pcall(api.entity.DestroyEntity, ep.nHead) end
      if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
      local nSpan = RangeSpan(ep.footSpan)
      local sDetail = string.format("loop(n=%d) footY=[%.3f,%.3f] headY=[%.3f,%.3f] span=%.3fm",
        ep.nSamples, ep.minFootY, ep.maxFootY, ep.minHeadY, ep.maxHeadY, nSpan)
      local bPass = ep.bSawLoop and ep.nSamples >= 5 and ep.minFootY > 2.0 and nSpan > 0.15
      Record("explore_preview_loop", bPass, sDetail)
      BaseUIMode.SetNewMode("Select")
      SetStage("ep_exit")
    end
  elseif s.nStageTime >= 6.0 then
    if s.epOrigStartPos then tWorld.CameraModeManager.GetWalkingStartPos = s.epOrigStartPos s.epOrigStartPos = nil end
    Record("explore_preview_loop", false, "never reached loop phase")
    BaseUIMode.SetNewMode("Select")
    SetStage("ep_exit")
  end
end

local StepEPExit = function()
  local Presence = require("PZ2Coop.Presence")
  if s.nStageTime < 0.5 then
    return
  end
  local bClean = Presence.GetExplorePreview() == nil
  Record("explore_preview_cleanup", bClean, bClean and "preview destroyed cleanly on Select" or "preview still alive")
  SetStage("cleanup")
end

-- ---- plan "mirror_place": remote path/floor + aquarium applies, own route vs open-editor route ----------
-- Fixtures (the player's own blueprints, copied by tools/test_live_game.py, never in git):
-- <game>\PZ2Coop\test_path.bin (path/floor chunks) and test_aquarium.bin (a prefab aquarium group).
-- Path cases: a reference copy is placed at P, then sent for real; loopback mirrors it 50 m east. The mirror
-- is compared with the reference cell by cell (occupancy + bottom per 3 m cell), in whole path chunks (the
-- unit the sender logs, RegionSync.TestPathChunks), and the reference itself against the chunk count read
-- from the fixture file (s.nExpRef, never measured from the build under test). Boxes around the mirror, the
-- reference, the world origin and the 2x offset must not change (stray pieces). Each case prints one MEASURE
-- line and one compact AUTOTEST_CHECK line.
-- mp_path_undo undoes and redoes the send through the real Ctrl+Z route (MainHUD.RequestUndoRedo as hooked by
-- BuildSync: a journaled path edit falls through to the game's undo). Solo loopback runs sender and receiver
-- in one game, so this exercises the sender's undo propagating to the mirror; a receiver-side undo of a
-- partner's path needs the 2-PC test.

  return {
    ep_enter = StepEPEnter,
    ep_measure = StepEPMeasure,
    ep_exit = StepEPExit,
  }
end
