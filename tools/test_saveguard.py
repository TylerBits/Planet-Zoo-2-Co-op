#!/usr/bin/env python3
"""Offline unit test for src/ovl_mod/pz2coop.saveguard.lua (run: python tools/test_saveguard.py).

Verifies defense-in-depth guest save & autosave protection:
  1. Host and solo play can save, autosave, and exit/quit normally without interference.
  2. Guest (role == "client") suspends native zooauto autosave, clears armed autosave slot,
     blocks SelectAppropriateAutosaveSlot / OnAutosaveComplete / EventActionRequestAutosave.
  3. Guest manual saves via MainHUD, SaveAgent, and ParkLoadSaveManager are all blocked
     (zero underlying RequestSave calls, isSavingGame cleared, Red HUD notification queued).
  4. Guest Exit-to-Menu & Quit Game force bSuppressSave = true and bTakeScreenshot = false
     so Career/Scenario modes never silently save the host's zoo on exit.
  5. Sticky guest-world lock: after peer_disconnected / left, saving and autosaving remain
     blocked until returning to the Start Screen or loading a local save via LoadParkFromSaveToken,
     at which point autosave resumes cleanly.
  6. Solo loopback (role == "host", loopback == true) never locks saving.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE_SRC = (ROOT / "src" / "ovl_mod" / "pz2coop.bridge.lua").read_text(encoding="utf-8")
SAVEGUARD_SRC = (ROOT / "src" / "ovl_mod" / "pz2coop.saveguard.lua").read_text(encoding="utf-8")

HARNESS = r"""
logs, calls, popouts, cmds = {}, {}, {}, {}
local function note(name, ...) table.insert(calls, {name = name, args = {...}}) end

local suspendCount, resumeCount = 0, 0
local clearedSlotCount = 0
local autosaveArmedCount = 0
local parkSavedCount = 0
local eventSuperExecuted = 0
local autosaveRequestedCount = 0
local lastExitArgs = nil
local lastQuitArgs = nil
local isSavingGameFlag = true

local notificationManager = {tTimelinePopOutQueue = popouts}

local ParkLoadSaveManager = {
  SelectAppropriateAutosaveSlot = function(self) autosaveArmedCount = autosaveArmedCount + 1 end,
  _SelectAppropriateAutosaveSlot = function(self) autosaveArmedCount = autosaveArmedCount + 1 end,
  OnAutosaveComplete = function(self) note("OnAutosaveComplete") end,
  ClearAutosaveSlot = function(self) clearedSlotCount = clearedSlotCount + 1 end,
  SaveParkToSlot = function(self, ...) parkSavedCount = parkSavedCount + 1 return true, "" end,
  SaveParkToSaveToken = function(self, ...) parkSavedCount = parkSavedCount + 1 return true, "" end,
  SaveParkToFile = function(self, path) note("SaveParkToFile", path) return true, path end,
  SaveBlueprintToSaveToken = function(self, ...) note("SaveBlueprintToSaveToken") return true end,
  LoadParkFromSaveToken = function(self, tok) note("LoadParkFromSaveToken", tok) return true end,
}

local SaveAgent = {
  _SetIsSavingGame = function(self, b) isSavingGameFlag = b end,
  OnPauseMenu_ReturnToStartScreen = function(self, hud, bSuppress, bShot)
    lastExitArgs = {suppress = bSuppress, shot = bShot}
  end,
  OnPauseMenu_QuitGame = function(self, hud, bSuppress, bShot)
    lastQuitArgs = {suppress = bSuppress, shot = bShot}
  end,
  OnPauseMenu_SaveCareerZoo = function(self, fnCb)
    parkSavedCount = parkSavedCount + 1
    if fnCb then fnCb(true, "") end
  end,
  SaveCareerZooNowWithoutMessage = function(self)
    parkSavedCount = parkSavedCount + 1
    return true, ""
  end,
  OnSaveLoad_Overwrite = function(self, id, bQuit, fnCb)
    parkSavedCount = parkSavedCount + 1
    if fnCb then fnCb(true) end
  end,
  OnSaveLoad_NewSave = function(self, id, bQuit, fnCb)
    parkSavedCount = parkSavedCount + 1
    if fnCb then fnCb(true) end
  end,
  _SaveNow = function(self)
    parkSavedCount = parkSavedCount + 1
    return true, ""
  end,
}

local MainHUD = {
  SaveCareer = function(self) parkSavedCount = parkSavedCount + 1 end,
  OnSaveLoad_Overwrite = function(self) parkSavedCount = parkSavedCount + 1 end,
  OnSaveLoad_NewSave = function(self) parkSavedCount = parkSavedCount + 1 end,
}

local SuperEvent = {
  Execute = function(self) eventSuperExecuted = eventSuperExecuted + 1 end,
}
local EventActionRequestAutosave = {
  Execute = function(self)
    autosaveRequestedCount = autosaveRequestedCount + 1
    SuperEvent.Execute(self)
  end,
}

local tEnv = {
  RequestInterface = function(_, name)
    if name == "Interfaces.IParkLoadSaveManager" then return ParkLoadSaveManager end
    if name == "Interfaces.INotificationManager" then return notificationManager end
    return nil
  end,
  RequireInterface = function(_, name)
    if name == "Interfaces.IParkLoadSaveManager" then return ParkLoadSaveManager end
    return nil
  end,
}

local nClock = 0
api = {
  game = {GetEnvironment = function() return tEnv end},
  world = {
    GetActive = function() return 1 end,
    GetScript = function() return {tEnvironment = tEnv} end,
  },
  player = {GetGameOwner = function() return 1 end},
  time = {GetTotalTimeUnscaled = function() nClock = nClock + 5 return nClock end},
  save = {
    ID_ZooAutosave = 2,
    GetIdentForSaveID = function() return "zooauto" end,
    CreateSaveSuspensionControl = function()
      return {
        SuspendAutosave = function(_, p, ident, reason)
          assert(ident == "zooauto" and reason == "PZ2CoopClient", "bad suspend args")
          suspendCount = suspendCount + 1
        end,
        ResumeAutosave = function(_)
          resumeCount = resumeCount + 1
        end,
      }
    end,
  },
  json = {Stringify = function() return true, "{}" end, Parse = function() return true, {} end},
}

local stubs = {
  ["Managers.ParkLoadSaveManager"] = ParkLoadSaveManager,
  ["Windows.SaveAgent"] = SaveAgent,
  ["Windows.MainHUD"] = MainHUD,
  ["Events.EventActionRequestAutosave"] = EventActionRequestAutosave,
  ["Events.Event"] = SuperEvent,
}
local loaded = {}
require = function(name)
  if stubs[name] then return stubs[name] end
  if loaded[name] then return loaded[name] end
  if SOURCES[name] then
    local mod
    local prev = module
    module = function() mod = {} return mod end
    assert(load(SOURCES[name], name))()
    module = prev
    loaded[name] = mod
    return mod
  end
  error("missing stub: " .. name)
end

local Bridge = require("PZ2Coop.Bridge")
Bridge.Log = function(s) table.insert(logs, s) end
Bridge.SendCommand = function(cmd) table.insert(cmds, cmd) end
local SaveGuard = require("PZ2Coop.SaveGuard")
SaveGuard.Install()

-- 1. Solo / host mode: everything works normally
assert(not Bridge.IsGuestWorld(), "solo must not be guest world")
SaveGuard.SyncAutosaveState()
assert(suspendCount == 0 and not SaveGuard.IsSuspended(), "solo must not suspend autosave")
ParkLoadSaveManager:SelectAppropriateAutosaveSlot()
assert(autosaveArmedCount == 1, "solo autosave slot should arm")
local ok1 = ParkLoadSaveManager:SaveParkToSlot(0, "MyZoo")
assert(ok1 == true and parkSavedCount == 1, "solo SaveParkToSlot should work")
EventActionRequestAutosave:Execute()
assert(autosaveRequestedCount == 1 and eventSuperExecuted == 1, "solo scenario autosave should fire")
SaveAgent:OnPauseMenu_ReturnToStartScreen(nil, false, true)
assert(lastExitArgs.suppress == false and lastExitArgs.shot == true, "solo exit should preserve vanilla save flag")

-- 2. Host + loopback must NOT trigger guest lock
__PZ2CoopBridgeState.sRole = "host"
Bridge.SetLoopback(true)
Bridge.SetGuestWorld(true)
assert(not Bridge.IsGuestWorld(), "loopback host must never become guest world")
Bridge.SetLoopback(false)

-- 3. Guest role: autosave suspended, slot cleared, all save vectors blocked
__PZ2CoopBridgeState.sRole = "client"
Bridge.SetGuestWorld(true)
SaveGuard.OnParkStart()
assert(Bridge.IsGuestWorld(), "client must be guest world")
assert(suspendCount == 1 and SaveGuard.IsSuspended(), "guest must suspend autosave")
assert(clearedSlotCount == 1, "guest must clear autosave slot")

-- Re-arming autosave or firing scenario autosave event is blocked (but narrative SUPER still runs)
ParkLoadSaveManager:SelectAppropriateAutosaveSlot()
ParkLoadSaveManager:_SelectAppropriateAutosaveSlot()
ParkLoadSaveManager:OnAutosaveComplete()
assert(autosaveArmedCount == 1, "guest SelectAppropriateAutosaveSlot must be blocked")
EventActionRequestAutosave:Execute()
assert(autosaveRequestedCount == 1, "guest EventActionRequestAutosave must not request autosave")
assert(eventSuperExecuted == 2, "guest EventActionRequestAutosave must still call SUPER.Execute")

-- Every manual save vector is blocked on guest
local beforeSaves = parkSavedCount
MainHUD:SaveCareer()
MainHUD:OnSaveLoad_Overwrite("s1")
MainHUD:OnSaveLoad_NewSave("s2")
local cbStatus, cbErr
SaveAgent:OnPauseMenu_SaveCareerZoo(function(ok, err) cbStatus, cbErr = ok, err end, true)
assert(cbStatus == false and cbErr == "CoopGuestReadOnly", "SaveCareerZoo callback must report blocked")
local okCareer, errCareer = SaveAgent:SaveCareerZooNowWithoutMessage(true)
assert(okCareer == false and errCareer == "CoopGuestReadOnly" and isSavingGameFlag == false, "SaveCareerZooNow blocked + spinner cleared")
isSavingGameFlag = true
local okNow, errNow = SaveAgent:_SaveNow(nil, "Steal", false)
assert(okNow == false and errNow == "CoopGuestReadOnly" and isSavingGameFlag == false, "_SaveNow blocked + spinner cleared")
SaveAgent:OnSaveLoad_Overwrite("s1", false, function(ok) cbStatus = ok end)
assert(cbStatus == false, "SaveAgent overwrite blocked")
SaveAgent:OnSaveLoad_NewSave("s2", false, function(ok) cbStatus = ok end)
assert(cbStatus == false, "SaveAgent newsave blocked")
local okSlot, errSlot = ParkLoadSaveManager:SaveParkToSlot(0, "Steal")
local okTok, errTok = ParkLoadSaveManager:SaveParkToSaveToken(1, {})
assert(okSlot == false and errSlot == "CoopGuestReadOnly", "SaveParkToSlot blocked")
assert(okTok == false and errTok == "CoopGuestReadOnly", "SaveParkToSaveToken blocked")
assert(parkSavedCount == beforeSaves, "zero park saves may pass for guest")
assert(#popouts >= 1 and popouts[1].sColour == "Red", "blocked save must notify player")

-- Blueprint saves remain allowed for guests
assert(ParkLoadSaveManager:SaveBlueprintToSaveToken() == true, "blueprint saving remains allowed")

-- Exit to menu / Quit game force bSuppressSave = true and bTakeScreenshot = false
SaveAgent:OnPauseMenu_ReturnToStartScreen(nil, false, true)
assert(lastExitArgs.suppress == true and lastExitArgs.shot == false, "guest exit must suppress career save")
SaveAgent:OnPauseMenu_QuitGame(nil, false, true)
assert(lastQuitArgs.suppress == true and lastQuitArgs.shot == false, "guest quit must suppress career save")

-- 4. Sticky guest-world lock: after host disconnects (role == "none"), saving stays blocked
__PZ2CoopBridgeState.sRole = "none"
SaveGuard.SyncAutosaveState()
assert(Bridge.IsGuestWorld(), "loaded host park must stay locked after disconnect")
assert(SaveGuard.IsSuspended() and resumeCount == 0, "autosave must stay suspended after disconnect")
local okAfterDc = ParkLoadSaveManager:SaveParkToSlot(0, "StealAfterDC")
assert(okAfterDc == false and parkSavedCount == beforeSaves, "save must stay blocked after disconnect")

-- 5. Returning to main menu clears guest-world lock and resumes autosave
Bridge.NoteEnvironment({}, "Environments.StartScreenEnvironment", "Activate")
SaveGuard.SyncAutosaveState()
assert(not Bridge.IsGuestWorld(), "returning to start screen must clear guest-world lock")
assert(not SaveGuard.IsSuspended() and resumeCount == 1, "autosave must resume on return to menu")

-- 6. Loading a local save also clears guest-world lock immediately
__PZ2CoopBridgeState.sRole = "client"
Bridge.SetGuestWorld(true)
SaveGuard.SyncAutosaveState()
assert(Bridge.IsGuestWorld() and suspendCount == 2, "re-suspended for second guest session")
__PZ2CoopBridgeState.sRole = "none"
ParkLoadSaveManager:LoadParkFromSaveToken("local_save_token")
assert(not Bridge.IsGuestWorld() and not SaveGuard.IsSuspended() and resumeCount == 2,
  "loading local save must clear guest-world lock and resume autosave")

return "ok: saveguard"
"""


def main() -> int:
    rt = lupa.LuaRuntime()
    sources = rt.table()
    sources["PZ2Coop.Bridge"] = BRIDGE_SRC
    sources["PZ2Coop.SaveGuard"] = SAVEGUARD_SRC
    rt.globals().SOURCES = sources
    try:
        print(rt.execute(HARNESS))
    except lupa.LuaError as exc:
        print("FAIL:", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
