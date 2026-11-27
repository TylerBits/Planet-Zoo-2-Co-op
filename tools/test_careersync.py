#!/usr/bin/env python3
"""Offline unit test for src/ovl_mod/pz2coop.careersync.lua (run: python tools/test_careersync.py).

Verifies Story Campaign / Career Mode progression sync via ScenarioNarrativeManager:
  1. Completing an objective locally sends 0x30 {k="career", ch, st, done}.
  2. Receiving same-stage objective completion calls Finish(true) only on started, unfinished matching objectives.
  3. Receiving a peer snapshot on a later stage/chapter catches up the local stage cleanly without
     touching optional or unstarted objectives.
  4. Echo suppression prevents re-broadcasting remote-completed objectives.
  5. Trust boundary drops malformed / out-of-range packets cleanly.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src" / "ovl_mod" / "pz2coop.careersync.lua").read_text(encoding="utf-8")

HARNESS = r"""
local logs, packets = {}, {}
local function makeObj(id, started, optional)
  local o = {id = id, started = started ~= false, complete = false, optional = optional == true, finishCalls = 0}
  function o:GetUniqueNarrativeID() return self.id end
  function o:IsStarted() return self.started end
  function o:IsComplete() return self.complete end
  function o:IsFinished() return self.complete end
  function o:GetIsOptional() return self.optional end
  function o:Finish(b)
    assert(self.started and not self.complete, "Objective.Finish called on unstarted/finished objective " .. tostring(self.id))
    self.complete = b == true
    self.finishCalls = self.finishCalls + 1
  end
  return o
end

local stages = {
  [1] = {
    [15] = {tObjectives = {makeObj(124, true, false), makeObj(999, true, true)}},
    [16] = {tObjectives = {makeObj(439, true, false)}},
    [19] = {tObjectives = {makeObj(347, true, false), makeObj(503, true, false), makeObj(504, false, false)}},
  },
}

local narrativeMgr = {
  bEnabled = true,
  nCurrentChapterIndex = 1,
  nCurrentStageIndex = 15,
  scenarioNarrative = {
    GetStage = function(_, ch, st) return stages[ch] and stages[ch][st] or nil end,
  },
}

local tEnv = {
  RequestManager = function(_, name)
    if name == "Managers.ScenarioNarrativeManager" then return narrativeMgr end
    return nil
  end,
}

api = {
  json = {GetArrayMetatable = function() return {} end},
}
local Bridge = {
  Log = function(s) table.insert(logs, s) end,
  IsApplying = function() return false end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}
local BuildSync = {Count = function() end}
local stubs = {["PZ2Coop.Bridge"] = Bridge, ["PZ2Coop.BuildSync"] = BuildSync}
require = function(name) return assert(stubs[name], "missing stub " .. name) end

local CareerSync
module = function() CareerSync = {} return CareerSync end
assert(load(SOURCE, "careersync"))()

CareerSync.Install(tEnv)
-- Advance past 2 s startup grace and seed initial state (should NOT emit)
for _ = 1, 30 do CareerSync.Update(0.1, true) end
assert(#packets == 0, "seeding must not emit packet")

-- 1. Same-stage local completion emits 0x30 {k="career", ch=1, st=15, done={124}}
stages[1][15].tObjectives[1]:Finish(true)
for _ = 1, 6 do CareerSync.Update(0.1, true) end
assert(#packets == 1 and packets[1].n == 0x30 and packets[1].d.k == "career", "local objective completion not sent")
assert(packets[1].d.ch == 1 and packets[1].d.st == 15 and packets[1].d.done[1] == 124, "wrong career payload")

-- 2. Move to Stage 19 (Adopt Shoebill): peer completes 347 & 503 (plus unstarted 504)
narrativeMgr.nCurrentStageIndex = 19
for _ = 1, 6 do CareerSync.Update(0.1, true) end -- seeds new stage packet
local nBefore = #packets
assert(CareerSync.OnPacket({nType = 0x30, tData = {k = "career", ch = 1, st = 19, done = {347, 503, 504}}}) == true)
CareerSync.Update(0.1, true)
assert(stages[1][19].tObjectives[1]:IsComplete(), "objective 347 not completed from peer")
assert(stages[1][19].tObjectives[2]:IsComplete(), "objective 503 not completed from peer")
assert(not stages[1][19].tObjectives[3]:IsComplete(), "unstarted objective 504 must not be finished")
-- Echo suppression: must not immediately echo back the remote completion
for _ = 1, 6 do CareerSync.Update(0.1, true) end
assert(#packets == nBefore, "remote career completion echoed back")

-- 3. Peer is ahead on Stage 16 while local is still on Stage 15 (fresh stage 15)
stages[1][15].tObjectives[1].complete = false
narrativeMgr.nCurrentStageIndex = 15
for _ = 1, 20 do CareerSync.Update(0.1, true) end
assert(CareerSync.OnPacket({nType = 0x30, tData = {k = "career", ch = 1, st = 16, done = {}}}) == true)
CareerSync.Update(0.1, true)
assert(stages[1][15].tObjectives[1]:IsComplete(), "required objective in lagging stage was not finished")
assert(not stages[1][15].tObjectives[2]:IsComplete(), "optional objective should not be forced finished")

-- 4. Trust boundary: invalid packets dropped safely
assert(CareerSync.OnPacket({nType = 0x30, tData = {k = "career", ch = -1, st = 1}}) == true)
assert(CareerSync.OnPacket({nType = 0x30, tData = {k = "career", ch = 999, st = 1}}) == true)
assert(CareerSync.OnPacket({nType = 0x30, tData = {k = "staff", op = "hire"}}) == false)

return "ok: careersync"
"""


def main() -> int:
    rt = lupa.LuaRuntime()
    rt.globals().SOURCE = SOURCE
    try:
        print(rt.execute(HARNESS))
    except lupa.LuaError as exc:
        print("FAIL:", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
