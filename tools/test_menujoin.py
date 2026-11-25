"""Offline smoke test for the main menu Join Friends path in src/ovl_mod/pz2coop.ui.lua
(run: python tools/test_menujoin.py). Needs: pip install lupa.

Loads the real UI module in a stock Lua with a fake Bridge and fake FrontEndUI, then checks:
the Frontend view gets a PZ2Coop_Select listener when StartScreenHUD registers Frontend_Resume; a join from
the menu reaches the DLL; a join is refused when neither a synced park nor the start screen is up
(Franchise); the card's watch keeps friends polled only on the menu; a host zoo that arrives with no park
manager is loaded through the start screen as Sandbox.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
UI_SOURCE = (ROOT / "src" / "ovl_mod" / "pz2coop.ui.lua").read_text(encoding="utf-8")

HARNESS = r"""
sent, logs, calls, listeners = {}, {}, {}, {}
local role, synced, menuLoad = "none", false, nil
local hostMode, hostScenario, hostDiff, hostWild, guestWorld = "Sandbox", nil, nil, false, false
local session = {tFriends = {}, tInvited = {}, tAvatars = {}}
startEnv = {RequireInterface = function(_, sName)
  if sName == "Interfaces.INextWorldDataManager" then
    return {
      SetIsWildArea = function(_, b) table.insert(calls, "wild=" .. tostring(b)) end,
      SetGameMode = function(_, m) table.insert(calls, "mode=" .. m) end,
      SetScenarioCode = function(_, c) table.insert(calls, "scenario=" .. tostring(c)) end,
      SetGameDifficulty = function(_, d) table.insert(calls, "diff=" .. tostring(d)) end,
    }
  end
  return {RequestLoadParkFromFile = function(_, f) table.insert(calls, "load=" .. f) return true end}
end}
local menuEnv = startEnv
Bridge = {
  Log = function(s) table.insert(logs, s) end,
  SendCommand = function(cmd, t) table.insert(sent, cmd .. (t and (":" .. tostring(t.lobby or t.code or t.reset)) or "")) end,
  GetRole = function() return role end,
  IsSyncedPark = function() return synced end,
  GetStartScreenEnvironment = function() return menuEnv end,
  IsStartScreenActive = function() return menuEnv ~= nil end,
  TakeMenuLoad = function() local f = menuLoad menuLoad = nil return f end,
  GetSession = function() return session end,
  IsPeerConnected = function() return false end,
  IsLoopback = function() return false end,
  GetHostGameMode = function() return hostMode end,
  GetHostScenarioCode = function() return hostScenario end,
  GetHostDifficulty = function() return hostDiff end,
  GetHostIsWildArea = function() return hostWild end,
  SetGuestWorld = function(b) guestWorld = b == true end,
  IsGuestWorld = function() return role == "client" or guestWorld end,
}
function setMenu(b) menuEnv = b and startEnv or nil end
function setMenuLoad(f) menuLoad = f end
function setSynced(b) synced = b end
function setHostMeta(m, sc, df, w) hostMode, hostScenario, hostDiff, hostWild = m, sc, df, w end
function clearCalls() calls = {} end
function isGuestWorld() return guestWorld end
local FrontEndUI = {AddListener_Frontend_Resume = function() return "vanilla" end}
local view = {AddEventListener = function(self, sName, n, fn, arg)
  listeners[sName] = function(sEvent) fn(arg, sEvent) end
  return 1
end}
setmetatable(view, {__index = FrontEndUI})
function registerFrontend() return view:AddListener_Frontend_Resume() end
api = {
  ui2 = {LoadOverlay = function() end, IsOverlayLoaded = function() return false end,
    GetDataStoreContext = function() return {} end, SetDataStoreElement = function() end},
  json = {Stringify = function() return true, "{}" end, GetArrayMetatable = function() return {} end},
}
module = function() captured = {} return captured end
local modules = {["PZ2Coop.Bridge"] = Bridge, ["UI.Controllers.FrontEndUI"] = FrontEndUI}
require = function(name)
  if modules[name] then return modules[name] end
  error("no module " .. name)
end
"""


def main() -> int:
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(HARNESS)
    lua.eval("function(s) assert(load(s, 'pz2coop.ui.lua'))() end")(UI_SOURCE)
    g = lua.globals()
    UI = g.captured
    failures = []

    def check(cond, what):
        print(("ok   " if cond else "FAIL ") + what)
        if not cond:
            failures.append(what)

    def sent():
        return list(g.sent.values())

    UI.Update(0.016)
    check(g.registerFrontend() == "vanilla", "vanilla Frontend_Resume listener still registered")
    check(g.listeners["PZ2Coop_Select"] is not None, "PZ2Coop_Select listener added on the Frontend view")
    select = g.listeners["PZ2Coop_Select"]

    select("pz2coop_watch:on")
    UI.Update(0.016)
    check(any(s.startswith("friends") for s in sent()), "card watch polls friends on the menu")

    select("pz2coop_joinlobby:12345")
    check("join:12345" in sent(), "join from the main menu reaches the DLL")

    g.setMenu(False)
    g.setSynced(False)
    before = len(sent())
    UI.Update(1.0)  # past the debounce window
    select("pz2coop_joinlobby:999")
    check("join:999" not in sent(), "join refused outside menu and synced parks (Franchise)")
    UI.Update(6.0)
    check(not any(s.startswith("friends") for s in sent()[before:]), "card watch stops polling once the menu is gone")

    g.setMenu(True)
    g.setMenuLoad("/pz2coop/rx_baseline.bin")
    UI.Update(0.016)
    calls = list(g.calls.values())
    check(calls == ["wild=false", "mode=Sandbox", "load=/pz2coop/rx_baseline.bin"],
          f"host zoo loads through the start screen as Sandbox ({calls})")
    check(g.isGuestWorld() is True, "menu join marks loaded host zoo as guestWorld")

    g.clearCalls()
    g.setHostMeta("ScenarioCareer", "Scenario_01", "Hard", True)
    g.setMenuLoad("/pz2coop/rx_career.bin")
    UI.Update(0.016)
    calls = list(g.calls.values())
    check(calls == ["wild=true", "mode=ScenarioCareer", "scenario=Scenario_01", "diff=Hard", "load=/pz2coop/rx_career.bin"],
          f"ScenarioCareer host zoo loads with scenario/diff/wild metadata ({calls})")

    print("all passed" if not failures else f"{len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
