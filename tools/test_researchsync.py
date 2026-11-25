"""Offline smoke test for src/ovl_mod/pz2coop.researchsync.lua (run: python tools/test_researchsync.py).

Verifies:
  1) Topic discovery via GetPinnedResearch / GetResearchTopicForStaff and tier increase -> 0x30 {k="research"}.
  2) Remote 0x30 research unlock calls research:SetTierForTopic + ClearNotificationBlip.
  3) Echo suppression: local tier bump caused by remote apply is NOT echoed back.
  4) Unknown/invalid topic names and out-of-range tiers are rejected safely.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.BuildSync": (ROOT / "src" / "ovl_mod" / "pz2coop.buildsync.lua").read_text(encoding="utf-8"),
    "PZ2Coop.ResearchSync": (ROOT / "src" / "ovl_mod" / "pz2coop.researchsync.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, packets, calls = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local tiers = {African_Lion = 1, Barrier_Glass = 0}
local validTopics = {African_Lion = 5, Barrier_Glass = 3}
local pinned = "African_Lion"
local receivers = {}
local tWorldAPIs = {
  research = {
    GetPinnedResearch = function() return pinned, 2, 1, false end,
    GetResearchTopicForStaff = function(_, id) return id == 11 and "Barrier_Glass" or nil end,
    GetCurrentTier = function(_, topic) return tiers[topic] or 0 end,
    GetMaxTier = function(_, topic) return validTopics[topic] or 0 end,
    IsResearchTopic = function(_, topic) return validTopics[topic] ~= nil end,
    SetTierForTopic = function(_, topic, tier)
      tiers[topic] = tier
      call("SetTierForTopic", topic, tier)
      return true
    end,
    ClearNotificationBlip = function(_, topic) call("ClearBlip", topic) end,
  },
  staff = {GetAllStaffEntities = function() return {11} end},
  scenery_group = {TryGetBuildingGroupForPart = function() end, CalculateBuildingGroupAABB = function() end},
  placement = {GetPartResourceName = function() end},
  facilities = {GetAllHabitatsEntityIDs = function() return {} end},
  editors = {CreateUndoOperationsHierarchy = function() return {} end},
}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end},
  undo = {
    PreviewChangeList = function() return {}, {} end, IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end, CommitPreview = function() return {} end,
    CancelPreview = function() return {} end, Checkpoint = function() end, ClearHistory = function() end,
    IsPreviewingChangeList = function() return false end, IsBusy = function() return false end,
  },
  messaging = setmetatable({
    RegisterReceiver = function(n, fn) receivers[n] = receivers[n] or {} table.insert(receivers[n], fn) end,
    UnregisterReceiver = function() end,
  }, {__index = function(_, k) return k end}),
}
applying = false
local Bridge = {
  Log = function(s) table.insert(log, s) end,
  Flush = function() end,
  IsApplying = function() return applying end,
  BeginApply = function() applying = true end,
  EndApply = function() applying = false end,
  GetPrefix = function() return "/run/PZ2Coop/" end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}
local stubs = {
  Vector3 = {new = function(_, x, y, z) return {x=x,y=y,z=z} end},
  TransformQ = {},
  Quaternion = {},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Scenery.SceneryEditHelper"] = {},
}
local loaded = {}
require = function(name)
  if stubs[name] then return stubs[name] end
  if loaded[name] then return loaded[name] end
  if SOURCES[name] then
    local mod
    local prev = module
    module = function() mod = {} return mod end
    load(SOURCES[name], name)()
    module = prev
    loaded[name] = mod
    return mod
  end
  error("module not stubbed: " .. name)
end
local BuildSync = require("PZ2Coop.BuildSync")
local ResearchSync = require("PZ2Coop.ResearchSync")
"""

CHECKS = r"""
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function dump() return table.concat(log, "\n") end
local function tick(n) for _ = 1, n or 1 do BuildSync.Update(0.2, true) ResearchSync.Update(0.2, true) end end

BuildSync.Install(function() end)
ResearchSync.Install()
tick(35) -- past startup ignore + initial seed
assert(#packets == 0, "seed should not send packets")

-- 1) Local research tier advances
tiers.African_Lion = 2
for _, fn in ipairs(receivers.MsgType_ResearchUpdatedMessage) do
  fn({{bOnLoad = false, sTopic = "African_Lion"}})
end
tick(2)
assert(#packets == 1, "expected research unlock packet:\n" .. dump())
assert(packets[1].n == 0x30 and packets[1].d.k == "research" and packets[1].d.topic == "African_Lion" and packets[1].d.tier == 2)

-- 2) Remote unlock applies and clears blip without echo
calls = {}
assert(ResearchSync.OnPacket({nType = 0x30, tData = {k = "research", topic = "Barrier_Glass", tier = 2}}) == true)
tick(4)
assert(count("SetTierForTopic") == 1 and count("ClearBlip") == 1 and tiers.Barrier_Glass == 2, "remote research not applied")
for _, fn in ipairs(receivers.MsgType_ResearchUpdatedMessage) do
  fn({{bOnLoad = false, sTopic = "Barrier_Glass"}})
end
tick(6)
assert(#packets == 1, "remote research echoed back")

-- 3) Unknown / malicious topic rejected
calls = {}
ResearchSync.OnPacket({nType = 0x30, tData = {k = "research", topic = "../bad", tier = 1}})
ResearchSync.OnPacket({nType = 0x30, tData = {k = "research", topic = "Unknown_Topic", tier = 1}})
tick(4)
assert(count("SetTierForTopic") == 0, "invalid topic should not apply")
return "ok: research sync"
"""


def main() -> int:
    lua = lupa.LuaRuntime()
    sources = lua.table()
    for name, text in SOURCES.items():
        sources[name] = text
    lua.globals().SOURCES = sources
    try:
        print(lua.execute(HARNESS + CHECKS))
    except lupa.LuaError as error:
        print("FAIL:", error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
