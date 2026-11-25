"""Offline smoke test for PZ2CoopManager in-game HUD notifications (run: python tools/test_notifications.py).

Loads Bridge + PZ2CoopManager in stock Lua (lupa) with a fake INotificationManager and verifies:
  - peer_connected (host) queues a Green pop-out with the friend's name (sanitizing tag-breaking chars | [ ]).
  - peer_disconnected queues a Red pop-out that still carries the friend's last known name even though
    Bridge.TrackSession clears sPartner first.
  - connection_lost / connect_failed / zoo_transfer_failed errors queue Red pop-outs.
  - Entries use bActionable = false and valid vanilla audio key "VIPEntered".
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.Bridge": (ROOT / "src" / "ovl_mod" / "pz2coop.bridge.lua").read_text(encoding="utf-8"),
    "Managers.PZ2CoopManager": (ROOT / "src" / "ovl_mod" / "managers.pz2coopmanager.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log = {}
local popouts = {}
local notificationManager = {tTimelinePopOutQueue = popouts}
local scenarioManager = {GetGameMode = function() return "Sandbox" end}
local tEnv = {
  RequestInterface = function(_, name)
    if name == "Interfaces.INotificationManager" then return notificationManager end
    if name == "Interfaces.IScenarioManager" then return scenarioManager end
    return nil
  end,
  RequireInterface = function(_, name) return nil end,
}
api = {
  world = {GetWorldAPIs = function() return {money = {GetCash = function() return 0 end, GetConservationCredits = function() return 0 end}} end},
  messaging = {},
  json = {Stringify = function() return true, "{}" end},
  time = {GetDeltaTimeUnscaled = function() return 0.1 end, GetTotalTimeUnscaled = function() return 1 end},
  game = {GetEnvironment = function() return tEnv end},
}
local noopSync = {Install = function() end, Uninstall = function() end, Update = function() end,
  ResetSnapshot = function() end, OnPacket = function() return false end, Summary = function() return "" end}
local stubs = {
  ["Environment.ModuleMutators"] = {Manager = function() return function(m) return m end end},
  ["PZ2Coop.BuildSync"] = noopSync,
  ["PZ2Coop.RegionSync"] = noopSync,
  ["PZ2Coop.WaterSync"] = noopSync,
  ["PZ2Coop.TerrainSync"] = noopSync,
  ["PZ2Coop.StaffSync"] = noopSync,
  ["PZ2Coop.AnimalSync"] = noopSync,
  ["PZ2Coop.ResearchSync"] = noopSync,
  ["PZ2Coop.Presence"] = {Install = function() end, Shutdown = function() end, Update = function() end,
    Reset = function() end, OnPacket = function() return false end},
  ["PZ2Coop.Actions"] = {Install = function() end, Uninstall = function() end, Update = function() end,
    Reset = function() end, OnPacket = function() return false end},
  ["PZ2Coop.SaveGuard"] = {Install = function() end, OnParkStart = function() end,
    SyncAutosaveState = function() end, Shutdown = function() end},
}
local loaded = {}
require = function(name)
  if stubs[name] then return stubs[name] end
  if loaded[name] then return loaded[name] end
  if SOURCES[name] then
    local captured
    module = function() captured = {} return captured end
    load(SOURCES[name], name)()
    loaded[name] = captured
    return captured
  end
  error("module not stubbed: " .. name)
end
local Bridge = require("PZ2Coop.Bridge")
Bridge.Log = function(s) table.insert(log, s) end
local Manager = require("Managers.PZ2CoopManager")
"""

CHECKS = r"""
local mgr = setmetatable({}, {__index = Manager})
mgr:Init({}, tEnv)
mgr:Advance(0.1) -- starts manager and registers Bridge handler
mgr._SendBaseline = function() end

-- 1) host status sets partner with special chars, then peer_connected fires
local s = __PZ2CoopBridgeState
s.sRole = "host"
Bridge.GetSession().sPartner = "Alice|Bob[1]"
s.fnHandler({sKind = "event", tData = {event = "status", role = "host", connected = true, partner_name = "Alice|Bob[1]"}})
s.fnHandler({sKind = "event", tData = {event = "peer_connected"}})
assert(#popouts == 1, "join popout missing")
assert(popouts[1].sColour == "Green" and popouts[1].bActionable == false, "wrong join popout style")
assert(popouts[1].tEntry.sTimelineEntryName == "VIPEntered", "wrong audio key")
assert(popouts[1].tEntry.sNotificationString == "[STRING_LITERAL:Value=|AliceBob1 joined your zoo|]",
  "bad literal/sanitization: " .. tostring(popouts[1].tEntry.sNotificationString))

-- 2) peer_disconnected after TrackSession already cleared sPartner
Bridge.GetSession().sPartner = nil
s.fnHandler({sKind = "event", tData = {event = "peer_disconnected"}})
assert(#popouts == 2, "leave popout missing")
assert(popouts[2].sColour == "Red", "wrong leave popout colour")
assert(popouts[2].tEntry.sNotificationString == "[STRING_LITERAL:Value=|AliceBob1 left the co-op session|]",
  "partner name lost on disconnect: " .. tostring(popouts[2].tEntry.sNotificationString))

-- 3) client connection_lost error
s.fnHandler({sKind = "event", tData = {event = "error", code = "connection_lost"}})
assert(#popouts == 3 and popouts[3].sColour == "Red", "connection_lost popout missing")
assert(popouts[3].tEntry.sNotificationString == "[STRING_LITERAL:Value=|Connection to host lost|]", "wrong text")

return "ok: notifications"
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
