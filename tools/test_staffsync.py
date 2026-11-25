"""Offline smoke test for src/ovl_mod/pz2coop.staffsync.lua (run: python tools/test_staffsync.py).

Loads BuildSync + StaffSync in stock Lua (lupa) with fake game APIs and tests:
  1) Startup seeding of pre-existing staff (not re-sent).
  2) Cancelled placement preview ghost (bCreated=true then bCreated=false while pending) is NOT sent.
  3) Committed local hire via StaffPlacementMode._CommitStaffMember -> 0x30 staff hire packet with SyncUUID.
  4) Remote staff hire -> InstantiatePrefab (whitelisted type) -> SetPosition -> SetStaffMemberSuspended(false) ->
     IncreasePriorityOfNearestApplicableJobInRange, with echo suppression.
  5) Local staff fire -> 0x30 staff fire packet; remote fire matches by SyncUUID and calls FireStaffMember.
  6) Untrusted staff prefab name is dropped cleanly.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.BuildSync": (ROOT / "src" / "ovl_mod" / "pz2coop.buildsync.lua").read_text(encoding="utf-8"),
    "PZ2Coop.StaffSync": (ROOT / "src" / "ovl_mod" / "pz2coop.staffsync.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, packets, calls = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end}
end
local staffEntities = {[10] = {type = "Keeper", pos = vec(1, 0, 1)}}
local nextEntity = 100
local tWorldAPIs = {
  staff = {
    GetAllStaffEntities = function()
      local t = {}
      for id in pairs(staffEntities) do table.insert(t, id) end
      table.sort(t)
      return t
    end,
    GetStaffMemberType = function(_, id) return staffEntities[id] and staffEntities[id].type end,
    SetStaffMemberSuspended = function(_, id, b) call("SetStaffMemberSuspended", id, b) end,
    IncreasePriorityOfNearestApplicableJobInRange = function(_, id) call("IncreasePriority", id) end,
    FireStaffMember = function(_, id) call("FireStaffMember", id) staffEntities[id] = nil end,
  },
  transform = {
    CalculateWorldTransform = function(_, id)
      local e = staffEntities[id]
      if not e then return nil end
      return {GetPos = function() return e.pos end}
    end,
    SetPosition = function(_, id, v)
      if staffEntities[id] then staffEntities[id].pos = v end
      call("SetPosition", id, v)
    end,
  },
  scenery_group = {TryGetBuildingGroupForPart = function() end, CalculateBuildingGroupAABB = function() end},
  placement = {GetPartResourceName = function() end},
  facilities = {GetAllHabitatsEntityIDs = function() return {} end},
  editors = {CreateUndoOperationsHierarchy = function() return {} end},
}
local receivers = {}
local StaffPlacementMode = {
  _CommitStaffMember = function(self, vPos) call("VanillaCommitStaff", self.staffEntityID, vPos) end,
}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end},
  entity = {
    CreateRequestCompletionToken = function() return {} end,
    HaveRequestsCompleted = function() return true end,
    InstantiatePrefab = function(sType, sName, tok, tr, parent, b, tProps)
      nextEntity = nextEntity + 1
      staffEntities[nextEntity] = {type = sType, pos = vec(0, 0, 0)}
      call("InstantiatePrefab", sType, nextEntity, tProps)
      return nextEntity
    end,
    DestroyEntity = function(id) staffEntities[id] = nil call("DestroyEntity", id) end,
  },
  undo = {
    PreviewChangeList = function() return {}, {} end,
    IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end,
    CommitPreview = function() return {} end,
    CancelPreview = function() return {} end,
    Checkpoint = function() end,
    ClearHistory = function() end,
    IsPreviewingChangeList = function() return false end,
    IsBusy = function() return false end,
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
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {},
  Quaternion = {},
  ["PZ2Coop.Bridge"] = Bridge,
  ["Editors.Scenery.SceneryEditHelper"] = {},
  ["Editors.Staff.StaffPlacementMode"] = StaffPlacementMode,
  ["Helpers.StaffUtils"] = {GetStaffType = function(staffAPI, id) return staffAPI:GetStaffMemberType(id) end},
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
local BuildSync = require("PZ2Coop.BuildSync")
local StaffSync = require("PZ2Coop.StaffSync")
"""

CHECKS = r"""
local function has(p) for _, l in ipairs(log) do if string.find(l, p, 1, true) then return true end end return false end
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function lastCall(name) local r = nil for _, c in ipairs(calls) do if c.name == name then r = c end end return r end
local function dump() return table.concat(log, "\n") end
local function tick(n) for _ = 1, n or 1 do BuildSync.Update(0.1, true) StaffSync.Update(0.1, true) end end
local function staffMsg(id, bCreated)
  for _, fn in ipairs(receivers.MsgType_StaffCreatedOrDestroyedMessage) do
    fn({{staffEntityID = id, bCreated = bCreated}})
  end
end

BuildSync.Install(function() end)
StaffSync.Install()
tick(60) -- past startup window, seeds entity 10
assert(#packets == 0 and has("seeded 1 existing staff"), dump())

-- 1) preview ghost cancelled: never sent
staffEntities[20] = {type = "Vet", pos = vec(5, 0, 5)}
staffMsg(20, true)
tick(1)
staffEntities[20] = nil
staffMsg(20, false)
tick(10)
assert(#packets == 0, "cancelled preview ghost must not be sent:\n" .. dump())

-- 2) local hire committed via StaffPlacementMode._CommitStaffMember
staffEntities[21] = {type = "Mechanic", pos = vec(14.5, 1.0, 22.0)}
staffMsg(21, true)
StaffPlacementMode._CommitStaffMember({staffEntityID = 21, bCreateNew = true}, vec(14.5, 1.0, 22.0))
tick(2)
assert(#packets == 1, "hire packet missing:\n" .. dump())
local pHire = packets[1]
assert(pHire.n == 0x30 and pHire.d.k == "staff" and pHire.d.op == "hire" and pHire.d.t == "Mechanic", "bad hire packet")
assert(pHire.d.x == 1450 and pHire.d.y == 100 and pHire.d.z == 2200 and pHire.d.id ~= nil, "bad hire coords/id")

-- 3) remote staff hire applied (shifted +50 m)
calls = {}
local rxHire = {k = "staff", op = "hire", t = "Mechanic", id = pHire.d.id, x = pHire.d.x + 5000, y = pHire.d.y, z = pHire.d.z}
assert(StaffSync.OnPacket({nType = 0x30, tData = rxHire}) == true, "staff packet not handled")
tick(5)
assert(count("InstantiatePrefab") == 1 and count("SetPosition") == 1 and count("SetStaffMemberSuspended") == 1,
  "staff hire apply incomplete:\n" .. dump())
local spawnedId = lastCall("InstantiatePrefab").args[2]
assert(lastCall("InstantiatePrefab").args[1] == "Mechanic", "wrong staff prefab")
assert(math.abs(lastCall("SetPosition").args[2]:GetX() - 64.5) < 1e-6, "wrong staff pos")
assert(lastCall("SetStaffMemberSuspended").args[2] == false, "staff not unsuspended")
-- echo of remote hire must not send another packet
staffMsg(spawnedId, true)
tick(10)
assert(#packets == 1, "remote staff hire echoed back:\n" .. dump())

-- 4) local fire of 21 -> packet -> remote fire matches spawnedId by SyncUUID
staffEntities[21] = nil
staffMsg(21, false)
tick(2)
assert(#packets == 2, "fire packet missing:\n" .. dump())
local pFire = packets[2]
assert(pFire.d.k == "staff" and pFire.d.op == "fire" and pFire.d.id == pHire.d.id, "bad fire packet")
calls = {}
StaffSync.OnPacket({nType = 0x30, tData = pFire.d})
tick(5)
assert(count("FireStaffMember") == 1 and lastCall("FireStaffMember").args[1] == spawnedId,
  "remote fire did not target SyncUUID match:\n" .. dump())

-- 5) untrusted prefab type rejected
calls = {}
StaffSync.OnPacket({nType = 0x30, tData = {k = "staff", op = "hire", t = "Peep_Avatar", x = 0, y = 0, z = 0}})
tick(5)
assert(count("InstantiatePrefab") == 0 and has("invalid type Peep_Avatar"), "untrusted staff type was not rejected:\n" .. dump())
assert(not has("error") and not has("failed"), dump())
return "ok: staff sync"
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
