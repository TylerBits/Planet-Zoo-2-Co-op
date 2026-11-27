"""Offline smoke test for src/ovl_mod/pz2coop.animalsync.lua (run: python tools/test_animalsync.py).

Loads BuildSync + AnimalSync in stock Lua (lupa) with fake game APIs and verifies:
  1) Local MsgType_ExhibitAnimalAddedMessage -> spatial exhibit lookup -> 0x30 exhibit add packet.
  2) Remote 0x30 exhibit add -> spatial SphereQuery(Flag_Exhibit) -> exhibits:AddAnimalToExhibit(id, species, bIsMale).
  3) Echo suppression: added message arriving during/after remote apply is NOT re-sent.
  4) Untrusted species name (path traversal / spaces) is dropped cleanly.
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {
    "PZ2Coop.BuildSync": (ROOT / "src" / "ovl_mod" / "pz2coop.buildsync.lua").read_text(encoding="utf-8"),
    "PZ2Coop.AnimalSync": (ROOT / "src" / "ovl_mod" / "pz2coop.animalsync.lua").read_text(encoding="utf-8"),
}

HARNESS = r"""
log, packets, calls = {}, {}, {}
local function call(name, ...) table.insert(calls, {name = name, args = {...}}) end
local function vec(x, y, z)
  return {GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end}
end
local exhibitsPos = {[501] = vec(20, 1, 30), [502] = vec(70, 1, 30)}
local habitatAnimals = {[701] = {species = "African_Lion", contra = false, pos = vec(15, 0, 25)}}
local exhibitContents = {[502] = {{nEntityID = 9002}}}
local tWorldAPIs = {
  spatial = {
    Flag_Exhibit = 1024,
    SphereQuery = function(_, vPos, r, flag)
      local out = {}
      for id, v in pairs(exhibitsPos) do
        local dx, dy, dz = v:GetX() - vPos:GetX(), v:GetY() - vPos:GetY(), v:GetZ() - vPos:GetZ()
        if dx*dx + dy*dy + dz*dz <= r*r then table.insert(out, id) end
      end
      return out
    end,
  },
  transform = {
    CalculateWorldTransform = function(_, id)
      local v = exhibitsPos[id] or (habitatAnimals[id] and habitatAnimals[id].pos)
      return v and {GetPos = function() return v end} or nil
    end,
  },
  exhibits = {
    IsAnimalMale = function(_, id) return id == 9001 end,
    AddAnimalToExhibit = function(_, exId, sSpecies, bMale) call("AddAnimalToExhibit", exId, sSpecies, bMale) end,
    GetAnimalsInExhibit = function(_, exId) return exhibitContents[exId] or {} end,
    GetAnimalSpecies = function(_, entId) return "Goliath_Frog" end,
    ExhibitAnimalEntityIDToUID = function(_, entId) return entId + 10000 end,
    AttemptToSendToTradeCentre = function(_, uid) call("ExhibitTradeCentre", uid) end,
  },
  animalsDataHelpers = {
    AnimalListType_Habitat = 1,
    GetAllAnimalEntities = function()
      local out = {}
      for id in pairs(habitatAnimals) do table.insert(out, id) end
      return out
    end,
  },
  animals = {
    GetSpecies = function(_, id) return habitatAnimals[id] and habitatAnimals[id].species end,
    IsUsingContraceptive = function(_, id) return habitatAnimals[id] and habitatAnimals[id].contra or false end,
    SetUsingContraceptive = function(_, id, b)
      if habitatAnimals[id] then habitatAnimals[id].contra = b end
      call("SetUsingContraceptive", id, b)
    end,
    RemoveAnimal = function(_, id)
      habitatAnimals[id] = nil
      call("RemoveAnimal", id)
    end,
  },
  scenery_group = {TryGetBuildingGroupForPart = function() end, CalculateBuildingGroupAABB = function() end},
  placement = {GetPartResourceName = function() end},
  facilities = {
    GetAllHabitatsEntityIDs = function() return {801} end,
    CreateAnimalInHabitatAtTransform = function(_, nHab, nG, nAge, sSp, tr)
      call("CreateAnimalInHabitat", nHab, sSp, nG, nAge, tr.pos:GetX(), tr.pos:GetZ())
      habitatAnimals[702] = {species = sSp, contra = false, pos = tr.pos}
      return {animalEntityID = 702}
    end,
  },
  habitat = {GetHabitatContainingPoint = function(_, vPos) return 801 end},
  editors = {CreateUndoOperationsHierarchy = function() return {} end},
}
local receivers = {}
api = {
  world = {GetWorldAPIs = function() return tWorldAPIs end},
  undo = {PreviewChangeList = function() return {}, {} end, IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end, CommitPreview = function() return {} end,
    CancelPreview = function() return {} end, Checkpoint = function() end, ClearHistory = function() end,
    IsPreviewingChangeList = function() return false end, IsBusy = function() return false end},
  messaging = setmetatable({
    RegisterReceiver = function(n, fn) receivers[n] = receivers[n] or {} table.insert(receivers[n], fn) end,
    UnregisterReceiver = function() end,
  }, {__index = function(_, k) return k end}),
}
applying = false
local Bridge = {
  Log = function(s) table.insert(log, s) end,
  Flush = function() end,
  GetRole = function() return "host" end,
  IsPeerConnected = function() return true end,
  IsLoopback = function() return false end,
  IsApplying = function() return applying end,
  BeginApply = function() applying = true end,
  EndApply = function() applying = false end,
  GetPrefix = function() return "/run/PZ2Coop/" end,
  SendPacket = function(n, f, d) table.insert(packets, {n = n, f = f, d = d}) end,
}
local stubs = {
  Vector3 = {new = function(_, x, y, z) return vec(x, y, z) end},
  TransformQ = {Identity = {WithPos = function(_, v) return {pos = v} end},
    FromOrPos = function(q, v) return {pos = v, q = q} end},
  Quaternion = {Identity = {}},
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
local AnimalSync = require("PZ2Coop.AnimalSync")
"""

CHECKS = r"""
local function has(p) for _, l in ipairs(log) do if string.find(l, p, 1, true) then return true end end return false end
local function count(name) local n = 0 for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end return n end
local function lastCall(name) local r = nil for _, c in ipairs(calls) do if c.name == name then r = c end end return r end
local function dump() return table.concat(log, "\n") end
local function tick(n) for _ = 1, n or 1 do BuildSync.Update(0.1, true) AnimalSync.Update(0.1, true) end end
local function added(exId, animalId, species)
  for _, fn in ipairs(receivers.MsgType_ExhibitAnimalAddedMessage) do
    fn({{nParentExhibitEntityID = exId, nAnimalID = animalId, sSpecies = species}})
  end
end

BuildSync.Install(function() end)
AnimalSync.Install()
tick(60)
packets = {} -- clear periodic host 0x31 waypoint snapshots sent during startup

-- 1) local exhibit animal added
added(501, 9001, "Goliath_Frog")
assert(#packets == 1, "exhibit packet missing:\n" .. dump())
local p = packets[1]
assert(p.n == 0x30 and p.d.k == "exhibit" and p.d.op == "add" and p.d.s == "Goliath_Frog" and p.d.m == true, "bad exhibit packet")
assert(p.d.x == 2000 and p.d.y == 100 and p.d.z == 3000, "bad exhibit coords")

-- 2) remote exhibit animal applied (+50 m to exhibit 502)
calls = {}
assert(AnimalSync.OnPacket({nType = 0x30, tData = {k = "exhibit", op = "add", s = "Goliath_Frog", m = false, x = 7000, y = 100, z = 3000}}) == true)
tick(5)
assert(count("AddAnimalToExhibit") == 1, "exhibit animal not applied:\n" .. dump())
local c = lastCall("AddAnimalToExhibit")
assert(c.args[1] == 502 and c.args[2] == "Goliath_Frog" and c.args[3] == false, "wrong exhibit add args")

-- 3) echo suppressed (only count 0x30 action packets, not periodic 0x31 host waypoints)
local function count30() local n = 0 for _, pkt in ipairs(packets) do if pkt.n == 0x30 then n = n + 1 end end return n end
added(502, 9002, "Goliath_Frog")
assert(count30() == 1, "remote exhibit animal echoed back:\n" .. dump())

-- 4) invalid species dropped
calls = {}
AnimalSync.OnPacket({nType = 0x30, tData = {k = "exhibit", op = "add", s = "../bad species", x = 7000, y = 100, z = 3000}})
tick(5)
assert(count("AddAnimalToExhibit") == 0 and has("invalid species"), "invalid species not dropped")

-- 5) exhibit animal remove (outgoing & incoming)
packets, calls = {}, {}
for _, fn in ipairs(receivers.MsgType_ExhibitAnimalRemovedMessage) do
  fn({{ParentExhibitEntityID = 501, nAnimalID = 9001}})
end
assert(#packets == 1 and packets[1].d.op == "remove" and packets[1].d.s == "Goliath_Frog", "exhibit remove not sent")
assert(AnimalSync.OnPacket({nType = 0x30, tData = {k = "exhibit", op = "remove", s = "Goliath_Frog", x = 7000, y = 100, z = 3000}}) == true)
tick(4)
assert(count("ExhibitTradeCentre") == 1 and lastCall("ExhibitTradeCentre").args[1] == 19002, "exhibit remove not applied")

-- 6) habitat animal waypoints (0x31) + contraceptive sync (0x30) + removal (0x30)
assert(AnimalSync.OnPacket({nType = 0x31, tData = {k = "waypoints", a = {{id = "lion_sync_1", s = "African_Lion", x = 1500, y = 0, z = 2500}}}}) == true)
assert(AnimalSync.HasSyncId("lion_sync_1"), "0x31 waypoint did not bind SyncUUID")
calls = {}
assert(AnimalSync.OnPacket({nType = 0x30, tData = {k = "animal", op = "contraceptive", id = "lion_sync_1", s = "African_Lion", v = true, x = 1500, y = 0, z = 2500}}) == true)
tick(4)
assert(count("SetUsingContraceptive") == 1 and habitatAnimals[701].contra == true, "contraceptive not applied")
assert(AnimalSync.OnPacket({nType = 0x30, tData = {k = "animal", op = "remove", id = "lion_sync_1", s = "African_Lion", x = 1500, y = 0, z = 2500}}) == true)
tick(4)
assert(count("RemoveAnimal") == 1 and habitatAnimals[701] == nil, "habitat animal remove not applied")

-- 7) habitat animal add (outgoing detection + incoming spawn via CreateAnimalInHabitatAtTransform)
packets, calls = {}, {}
habitatAnimals[705] = {species = "Leopard_African", contra = false, pos = vec(25, 1, 35)}
tick(25)
local addPkt = nil
for _, pkt in ipairs(packets) do
  if pkt.n == 0x30 and pkt.d.k == "animal" and pkt.d.op == "add" then addPkt = pkt end
end
assert(addPkt ~= nil and addPkt.d.s == "Leopard_African" and addPkt.d.x == 2500,
  "local habitat animal add not broadcast:\n" .. dump())
calls = {}
assert(AnimalSync.OnPacket({nType = 0x30, tData = {k = "animal", op = "add", id = "Leopard_African_9",
  s = "Leopard_African", g = 1, age = 1, x = 3000, y = 100, z = 4000}}) == true)
tick(6)
assert(count("CreateAnimalInHabitat") == 1, "remote habitat animal not spawned:\n" .. dump())
local sc = lastCall("CreateAnimalInHabitat")
assert(sc.args[1] == 801 and sc.args[2] == "Leopard_African" and sc.args[5] == 30 and sc.args[6] == 40,
  "wrong CreateAnimalInHabitat args")

assert(not has("error") and not has("failed"), dump())
return "ok: animal sync"
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
