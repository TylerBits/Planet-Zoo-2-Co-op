-- Dev-only ad-hoc Lua probe plan (triggered ONLY by local autotest.txt + autotest_eval.lua via test_live_game.py --eval).
-- Runs a snippet inside a loaded park with zero OVL rebuilds and zero reboots when paired with --warm.
local global = _G
local api = global.api
local string = global.string
local table = global.table
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local type = global.type
local rawget = global.rawget

local Plan = module(...)

local DecodeHex = function(_sHex)
  if type(_sHex) ~= "string" or #_sHex == 0 or (#_sHex % 2) ~= 0 then
    return nil
  end
  local tOut = {}
  for i = 1, #_sHex, 2 do
    local nByte = tonumber(string.sub(_sHex, i, i + 1), 16)
    if nByte == nil then
      return nil
    end
    tOut[#tOut + 1] = string.char(nByte)
  end
  return table.concat(tOut)
end

local FormatResult = function(_v)
  if _v == nil then
    return "nil"
  end
  if type(_v) == "table" then
    local bOk, bJsonOk, sJson = pcall(function() return api.json.Stringify(_v) end)
    if bOk and bJsonOk and type(sJson) == "string" then
      return sJson
    end
  end
  return tostring(_v)
end

Plan.Register = function(ctx)
  local s, Record, SetStage = ctx.s, ctx.Record, ctx.SetStage

  local StepEvalRun = function()
    local fnLoad = rawget(global, "load")
    if type(fnLoad) ~= "function" then
      Record("eval", false, "_G.load unavailable in this runtime")
      SetStage("cleanup")
      return
    end
    local sCode = DecodeHex(s.sEvalHex)
    if sCode == nil then
      Record("eval", false, "missing or invalid autotest_eval.lua payload")
      SetStage("cleanup")
      return
    end
    local fnChunk, sCompileErr = fnLoad(sCode, "=autotest_eval", "t", global)
    if fnChunk == nil then
      Record("eval", false, "compile error: " .. tostring(sCompileErr))
      SetStage("cleanup")
      return
    end
    local bOk, vRes = pcall(fnChunk)
    if not bOk then
      Record("eval", false, "runtime error: " .. tostring(vRes))
    else
      Record("eval", true, FormatResult(vRes))
    end
    SetStage("cleanup")
  end

  return {
    eval_run = StepEvalRun,
  }
end
