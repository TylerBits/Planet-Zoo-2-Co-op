-- Build sync via blueprint files + quantized spatial keys (CLAUDE.md rule 3).
--
-- Synced object kinds (an "object" is a table key in this module):
--   building group   number  (group ID)      key = AABB centre + extents (scenery_group:CalculateBuildingGroupAABB)
--   loose part       "p"..ID (placement ID)  key = resource name + world position + yaw/pitch/roll; sent as
--                    parameters (no file). Part edits run inside the active editor via
--                    editMode:RequestUndoOperation (as every vanilla info popup does): committing a single part
--                    from our own change list crashed the engine at PlanetZoo2.exe+0x71675e4 three times
--                    (blueprint and by-name alike, crash dumps 2026-11-12 08:53 / 09:02 / 09:14).
-- Habitats and path volumes are only *recorded* this round: their commits are logged and a test blueprint
-- is saved ("save-proof") to show whether the blueprint pipeline can carry them (docs/MEGA_TEST.md).
--
-- Retail strips every group enumerator (scenery:GetAllBuildingIDs, placement:GetAllPlacementPartHolderIDs),
-- so changes are tracked per commit instead of by snapshot diff (facts: LUA_API_MAP.md §10a, diag.log):
--   pre-image: the undo hierarchy's EditExistingPart(s) / DestroyExistingPart(s) are wrapped on its class
--              metatable; vanilla moves pass the touched part IDs there while they still exist.
--   post-image: MsgType_PlacementPartCommittedMessage lists committed part IDs (nPlacementPartID).
--   settle:    a local CommitPreview token completes, or an undo/redo completes. Every object seen this
--              session is re-keyed on each settle (the retail delete tool bypasses the hierarchy hooks).
-- Changed key -> ACTION_DELETE_SPATIAL (old) + ACTION_PLACE_OBJECT (new, blueprint file attached).
-- Apply:  placement follows managers.assetsshowroomdebugmanager.lua:806-850 and the preview/adjust/commit
--         order of managers.blueprintdebugsavemanager.lua:_UpdateBlueprint; part removal follows
--         components.ui.exhibitinfopopup.lua:1818 (NonYielding_AddPartToDestroyIntoCompositeObject).
local global = _G
local api = global.api
local string = global.string
local table = global.table
local error = global.error
local select = global.select
local math = global.math
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local type = global.type
local coroutine = global.coroutine
local setmetatable = global.setmetatable
local getmetatable = global.getmetatable
local rawget = global.rawget
local rawset = global.rawset
local require = global.require
local next = global.next
local Vector3 = require("Vector3")
local TransformQ = require("TransformQ")
local Quaternion = require("Quaternion")
local SceneryEditHelper = require("Editors.Scenery.SceneryEditHelper")
local Bridge = require("PZ2Coop.Bridge")

local BuildSync = module(...)

local c_nPlaceObject = 0x20
local c_nDeleteSpatial = 0x21
-- ponytail: AABB centres of a re-placed blueprint are not bit-identical across machines; 25 cm search
-- radius instead of the spec's 5 cm until real drift is measured in-game.
local c_nSearchRadiusMm = 250
local c_nUndoRedoSettle = 0.5
local c_nAfterLocalCommit = 1.0 -- seconds a remote editor change waits after the player's own commit
-- Blueprint files are kept for undo (a deleted building is rebuilt from its last saved state), so slots are
-- recycled late. ponytail: undo of a building whose slot was reused restores the wrong blueprint.
local c_nClipSlots = 512
local c_nJournalLimit = 100
-- A replayed remote action commits and messages asynchronously; local detections within this window and
-- radius of a replayed key are the replay's own echo (CLAUDE.md rule 2).
-- ponytail: a genuine local edit at the same spot within 5 s of a replay is absorbed too.
local c_nEchoWindow = 10.0
-- Commit messages of a replayed action can arrive just after it finishes; this long after a replay they are
-- still counted as the replay's own. ponytail: a genuine local edit inside this window is not sent.
local c_nRemoteGrace = 0.5
-- A previewed remote placement further than this from its target is shifted before commit.
local c_nDriftToleranceCm = 2
local c_nSettleLogLimit = 300
local c_nToolLogLimit = 300
local c_nProofLimit = 3
local c_nModeOpTimeout = 30 -- seconds to wait for an idle editor / for its commit of a remote part edit
local c_nMaxRetries = 100 -- a remote job re-queued this often (undo never free when it commits) is dropped -- save-proofs per kind (habitat, each volume message type)
-- Undo hierarchy methods that receive the IDs of existing parts before they are moved or destroyed.
local c_tPreImageMethods = {"EditExistingPart", "EditExistingParts", "DestroyExistingPart", "DestroyExistingParts"}

local s = {
  rawUndo = nil,
  tProxy = nil,
  tHooked = {}, -- {t = table, sName = name, fn = original}
  tReceivers = {}, -- message type -> receiver registered by Install
  tKnown = {}, -- object -> last key this client saw (sent or applied)
  tSeen = {}, -- every object seen this session, kept after delete so undo can bring it back
  tPre = {}, -- object -> key before the pending local edit (false: had no key)
  tTouched = {}, -- part IDs from commit messages since the last settle
  tRemoteTouched = {}, -- part IDs committed by a replayed remote action (never sent back)
  -- Object -> position the remote player knows it by. A replayed blueprint can land off its target, so
  -- deletes are matched and sent by this shared position, not the local key.
  tNetKey = {},
  tPendingNetKey = nil, -- target of the remote placement being applied
  nRemoteGraceUntil = -1,
  bUndoSettle = false,
  tRecentRemote = {}, -- {x, y, z, nTime}
  nClock = 0,
  nSettleLogs = 0,
  nCommitMessages = 0,
  tCommitTokens = {},
  nUndoRedoTimer = nil,
  nClip = 0,
  tJobs = {}, -- {fn = job, bSlot = needs the loaded-blueprint slot, bPreview = previews a change list}
  bRetry = false, -- set by Yielding_Commit when the undo system was taken; the job is queued again
  tWaitLogged = {}, -- wait reason -> already logged
  tBlueprintModes = {}, -- open BlueprintPlacementMode instances
  worker = nil,
  fnOnLocalChange = nil,
  fnSettleListener = nil, -- RegionSync: told on every settle (a local commit or undo/redo finished)
  -- Own-undo per player (co-op only): every local action is journaled as reversible ops; Ctrl+Z/Ctrl+Y replay
  -- their inverse as normal synced edits, so the partner's actions are never undone.
  tUndo = {}, -- journal entries, newest last: {ops = {...}} or {sRegion = "path"|"fence"}
  tRedo = {},
  tPendingOps = {}, -- ops emitted by the settle being processed
  tGroupFile = {}, -- group -> blueprint file (relative) holding its latest known state
  nJournalMuteUntil = -1, -- region changes caused by a vanilla undo/redo are not journaled again
  bUndoHooked = false,
  sTool = "none", -- last editor/UI mode requested (tool tracker)
  nToolLogs = 0,
  tProofs = {}, -- proof kind -> count
  tProofedHabitats = {},
  tStats = {}, -- counter name -> n (heartbeat)
}

local Count = function(_sName)
  s.tStats[_sName] = (s.tStats[_sName] or 0) + 1
end

local Cm = function(_n)
  return math.floor(_n * 100 + 0.5)
end

local IsFinite = function(_n)
  return _n == _n and _n < 1e7 and _n > -1e7
end

-- Natives this module calls. Missing ones are logged at install so a retail-stripped function shows up
-- before it is needed.
local c_tNeededMethods = {
  {"scenery", "AddGroupToBlueprintSelection"},
  {"scenery_group", "TryGetBuildingGroupForPart"},
  {"scenery_group", "CalculateBuildingGroupAABB"},
  {"scenery_puppets", "PlacementIDToEntityID"},
  {"transform", "CalculateWorldTransform"},
  {"placement", "GetPartResourceName"},
  {"worldserialisation", "CreateSaveSelection"},
  {"editors", "CreateUndoOperationsHierarchy"},
  {"facilities", "GetAllHabitatsEntityIDs"},
  {"habitat", "GetHabitatIDFromEntityID"},
  {"habitatboundary", "GetBoundaryObjectsForHabitat"},
  {"money", "GetCash"},
  {"money", "ModifyCash"},
}

local ProbeMethods = function()
  local tWorldAPIs = api.world.GetWorldAPIs()
  local tMissing = {}
  for _, tEntry in ipairs(c_tNeededMethods) do
    local bOk, fn = pcall(function()
      return tWorldAPIs[tEntry[1]][tEntry[2]]
    end)
    if not bOk or fn == nil then
      table.insert(tMissing, tEntry[1] .. ":" .. tEntry[2])
    end
  end
  Bridge.Log("build sync natives missing: " .. (#tMissing > 0 and table.concat(tMissing, ", ") or "none"))
end

-- ---- objects and keys ----------------------------------------------------------------------------
local IsPart = function(_obj)
  return type(_obj) == "string"
end

local PartIDOf = function(_obj)
  return tonumber(string.sub(_obj, 2))
end

local GroupKey = function(_nGroupID)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local bOk, vMin, vMax = pcall(function()
    return tWorldAPIs.scenery_group:CalculateBuildingGroupAABB(_nGroupID)
  end)
  if not bOk or vMin == nil or vMax == nil then
    return nil
  end
  -- Some parts (e.g. spawner helpers) report an infinite or NaN box; they have no usable key.
  for _, n in ipairs({vMin:GetX(), vMin:GetY(), vMin:GetZ(), vMax:GetX(), vMax:GetY(), vMax:GetZ()}) do
    if not IsFinite(n) then
      return nil
    end
  end
  local tKey = {
    x = Cm((vMin:GetX() + vMax:GetX()) / 2),
    y = Cm((vMin:GetY() + vMax:GetY()) / 2),
    z = Cm((vMin:GetZ() + vMax:GetZ()) / 2),
    ex = Cm(vMax:GetX() - vMin:GetX()),
    ey = Cm(vMax:GetY() - vMin:GetY()),
    ez = Cm(vMax:GetZ() - vMin:GetZ()),
  }
  tKey.sSig = string.format("%d,%d,%d,%d,%d,%d", tKey.x, tKey.y, tKey.z, tKey.ex, tKey.ey, tKey.ez)
  return tKey
end

-- A loose part: resource name, world position and orientation of its entity (orientation as yaw/pitch/
-- roll in milliradians, read the way cameramodemanager.lua:735 does). nil once the part is gone.
local PartKey = function(_nPartID)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local bOk, sName, transform = pcall(function()
    local sResource = tWorldAPIs.placement:GetPartResourceName(_nPartID)
    if sResource == nil then
      return nil
    end
    local nEntity = tWorldAPIs.scenery_puppets:PlacementIDToEntityID(_nPartID)
    if nEntity == nil then
      return nil
    end
    return sResource, tWorldAPIs.transform:CalculateWorldTransform(nEntity)
  end)
  if not bOk or sName == nil or transform == nil then
    return nil
  end
  local vPos = transform:GetPos()
  local x, y, z = vPos:GetX(), vPos:GetY(), vPos:GetZ()
  if not (IsFinite(x) and IsFinite(y) and IsFinite(z)) then
    return nil
  end
  local bYpr, vYpr = pcall(function()
    return transform:GetOr():ToYawPitchRoll()
  end)
  local nYaw, nPitch, nRoll = 0, 0, 0
  if bYpr and vYpr ~= nil then
    nYaw, nPitch, nRoll = math.floor(vYpr:GetX() * 1000 + 0.5), math.floor(vYpr:GetY() * 1000 + 0.5),
      math.floor(vYpr:GetZ() * 1000 + 0.5)
  end
  local tKey = {x = Cm(x), y = Cm(y), z = Cm(z), ex = 0, ey = 0, ez = 0, sName = tostring(sName),
    yaw = nYaw, pitch = nPitch, roll = nRoll}
  tKey.sSig = string.format("%s,%d,%d,%d,%d,%d,%d", tKey.sName, tKey.x, tKey.y, tKey.z, nYaw, nPitch, nRoll)
  return tKey
end

local KeyOf = function(_obj)
  if IsPart(_obj) then
    return PartKey(PartIDOf(_obj))
  end
  return GroupKey(_obj)
end

local Label = function(_obj, _tKey)
  if IsPart(_obj) then
    return "part " .. tostring(PartIDOf(_obj)) .. " (" .. tostring(_tKey and _tKey.sName) .. ")"
  end
  return "group " .. tostring(_obj)
end

local SameKey = function(_tA, _tB)
  if _tA == nil or _tB == nil then
    return _tA == _tB
  end
  return _tA.sSig == _tB.sSig
end

-- Distance in cm between a key and a packet position.
local DistCm = function(_tKey, _x, _y, _z)
  local dx, dy, dz = _tKey.x - _x, _tKey.y - _y, _tKey.z - _z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The building group a part belongs to; a group's own ID resolves to itself.
local GroupOf = function(_nPartID)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local bOk, nGroupID = pcall(function()
    return tWorldAPIs.scenery_group:TryGetBuildingGroupForPart(_nPartID)
  end)
  if bOk and nGroupID ~= nil then
    return nGroupID
  end
  if GroupKey(_nPartID) ~= nil then
    return _nPartID
  end
  return nil
end

-- The synced object a committed part belongs to: its building group, else the part itself if it still
-- exists (a deleted group's members report no resource name and resolve to nothing).
local ObjOfPart = function(_nPartID)
  local nGroupID = GroupOf(_nPartID)
  if nGroupID ~= nil then
    return nGroupID
  end
  if PartKey(_nPartID) ~= nil then
    return "p" .. _nPartID
  end
  return nil
end

-- ---- pre-image capture (undo hierarchy hooks) ----------------------------------------------------
local NotePrePart = function(_nPartID)
  local obj = ObjOfPart(_nPartID)
  if obj ~= nil and s.tPre[obj] == nil then
    s.tPre[obj] = KeyOf(obj) or false
  end
end

-- Vanilla passes a part ID, a table of part IDs, or a BuildingPartSet (table or userdata, Demolish / Multi-Select).
-- Read every part ID via GetPartIDCollection() so batch demolishes capture all parts, not just 1 of N.
local NotePre = function(_arg)
  if Bridge.IsApplying() or s.rawUndo == nil or _arg == nil then
    return
  end
  if type(_arg) == "number" then
    NotePrePart(_arg)
    return
  end
  local bGotCollection = false
  local bOkCol, tCol = pcall(function()
    return _arg.GetPartIDCollection and _arg:GetPartIDCollection()
  end)
  if bOkCol and type(tCol) == "table" then
    for _, v in pairs(tCol) do
      if type(v) == "number" then
        NotePrePart(v)
        bGotCollection = true
      end
    end
  end
  if not bGotCollection then
    local bOkP, tP = pcall(function()
      return _arg.GetPartIDCollectionWithPuppetIndices and _arg:GetPartIDCollectionWithPuppetIndices()
    end)
    if bOkP and type(tP) == "table" then
      for _, v in pairs(tP) do
        if type(v) == "table" and type(v.nID) == "number" then
          NotePrePart(v.nID)
          bGotCollection = true
        end
      end
    end
  end
  if not bGotCollection and type(_arg) == "table" then
    for _, v in pairs(_arg) do
      if type(v) == "number" then
        NotePrePart(v)
        bGotCollection = true
      elseif type(v) == "table" and type(v.nID) == "number" then
        NotePrePart(v.nID)
        bGotCollection = true
      end
    end
  end
  if not bGotCollection then
    local bOk, nPartID = pcall(function()
      return _arg:GetOnePartID()
    end)
    if bOk and type(nPartID) == "number" then
      NotePrePart(nPartID)
    end
  end
end

local HookHierarchy = function()
  local tWorldAPIs = api.world.GetWorldAPIs()
  local bOk, hierarchy = pcall(function()
    return tWorldAPIs.editors:CreateUndoOperationsHierarchy()
  end)
  local mt = bOk and getmetatable(hierarchy) or nil
  if type(mt) ~= "table" then
    Bridge.Log("build sync: undo hierarchy metatable unavailable (" .. tostring(hierarchy) .. ")")
    return
  end
  local tWhere = {mt}
  if type(rawget(mt, "__index")) == "table" and rawget(mt, "__index") ~= mt then
    table.insert(tWhere, rawget(mt, "__index"))
  end
  local tResult = {}
  for _, sName in ipairs(c_tPreImageMethods) do
    local sState = "missing"
    for _, t in ipairs(tWhere) do
      local fn = rawget(t, sName)
      if type(fn) == "function" then
        local bSet = pcall(rawset, t, sName, function(_self, _arg, ...)
          pcall(NotePre, _arg)
          return fn(_self, _arg, ...)
        end)
        if bSet then
          table.insert(s.tHooked, {t = t, sName = sName, fn = fn})
          sState = "hooked"
        else
          sState = "readonly"
        end
        break
      end
    end
    table.insert(tResult, sName .. "=" .. sState)
  end
  Bridge.Log("build sync hierarchy hooks: " .. table.concat(tResult, " "))
end

local UnhookHierarchy = function()
  for _, tHook in ipairs(s.tHooked) do
    pcall(rawset, tHook.t, tHook.sName, tHook.fn)
  end
  s.tHooked = {}
end

-- ---- tool tracker --------------------------------------------------------------------------------
-- Every editor/UI mode change goes through BaseEditMode.SetNewMode or BaseUIMode.SetNewMode, which vanilla
-- looks up on each call ((BaseEditMode.SetNewMode)(...)), so wrapping the module field sees all of them.
-- Re-checked every frame because the game re-runs module files (LUA_API_MAP.md §10a).
local c_tModeModules = {"Editors.Shared.BaseEditMode", "Editors.Shared.BaseUIMode"}

local HookToolTracker = function()
  for _, sModule in ipairs(c_tModeModules) do
    local bOk, Mode = pcall(require, sModule)
    if bOk and type(Mode) == "table" and rawget(Mode, "__PZ2CoopToolHook") == nil then
      local fnSetNewMode = rawget(Mode, "SetNewMode")
      if type(fnSetNewMode) == "function" then
        rawset(Mode, "__PZ2CoopToolHook", true)
        rawset(Mode, "SetNewMode", function(_sMode, ...)
          local sTool = tostring(_sMode)
          if sTool ~= s.sTool then
            s.sTool = sTool
            if s.nToolLogs < c_nToolLogLimit then
              s.nToolLogs = s.nToolLogs + 1
              Bridge.Log("tool: " .. sTool)
            end
          end
          return fnSetNewMode(_sMode, ...)
        end)
        Bridge.Log("build sync: tool tracker installed on " .. sModule)
      end
    end
  end
end

-- ---- undo plumbing -------------------------------------------------------------------------------
-- The engine runs ONE change-list preview at a time: vanilla editors assert "Mode entered while undo is
-- previewing another change" and wait on api.undo.IsBusy (editors.scenery.submodebase.lua:94-98). A remote
-- commit started while the player held a scenery ghost (a live preview) crashed the game (diag.log
-- 2026-11-12 09:02), so remote jobs only start, and only preview, while the undo system is free.
local IsUndoFree = function()
  local undo = s.rawUndo
  local bOk, bPreviewing = pcall(undo.IsPreviewingChangeList)
  local bOk2, bBusy = pcall(undo.IsBusy)
  if (bOk and bPreviewing) or (bOk2 and bBusy) then
    return false
  end
  if s.fnExternalBusy ~= nil then
    local bExtOk, bExtBusy = pcall(s.fnExternalBusy)
    if bExtOk and bExtBusy == true then
      return false
    end
  end
  return true
end

-- Waits on undo-system tokens with the raw API so replays never look like local commits. Remote jobs only.
-- _fnAdjust runs once the preview exists (vanilla adjusts transforms at that point too) and may move the
-- previewed objects; the commit check then re-polls until the preview has caught up.
local Yielding_Commit = function(_hierarchy, _fnAdjust)
  local undo = s.rawUndo
  if not IsUndoFree() then
    -- The player started a preview while this job was preparing: drop this attempt, run it again later.
    s.bRetry = true
    return nil
  end
  local busyToken, previewToken = undo.PreviewChangeList(_hierarchy:GetFullUndoChangeList())
  while not undo.IsOperationComplete(busyToken) do
    coroutine.yield()
  end
  if _fnAdjust ~= nil then
    local bOk, sError = pcall(_fnAdjust)
    if not bOk then
      Bridge.Log("build sync: adjust before commit failed: " .. tostring(sError))
    end
  end
  local bCanCommit = undo.CanCommitPreview(previewToken)
  while bCanCommit == nil do
    coroutine.yield()
    bCanCommit = undo.CanCommitPreview(previewToken)
  end
  local waitToken
  if bCanCommit then
    waitToken = undo.CommitPreview(previewToken)
  else
    local bReasons, tReasons = pcall(undo.GetCommitFailReasons, previewToken)
    local tNames = {}
    if bReasons and type(tReasons) == "table" then
      for k, v in pairs(tReasons) do
        if v then
          table.insert(tNames, tostring(k))
        end
      end
    end
    Bridge.Log("build sync: commit refused, reasons: " .. (#tNames > 0 and table.concat(tNames, ",") or "unknown"))
    waitToken = undo.CancelPreview(previewToken)
  end
  while not undo.IsOperationComplete(waitToken) do
    coroutine.yield()
  end
  undo.Checkpoint({sMode = "PZ2Coop"})
  -- The engine has no undo-free commit, so a replayed remote action would land in this player's undo
  -- history and Ctrl+Z could undo the friend's work (diag.log 2026-11-12 08:18). Chosen behaviour: a remote
  -- action clears the local undo history, as the game itself does at checkpoints (worlds.darwinworld.lua).
  undo.ClearHistory({})
  Bridge.Log("build sync: undo history cleared (remote action applied)")
  return bCanCommit
end

local ParkLoadSaveManager = function()
  return api.game.GetEnvironment():RequireInterface("Interfaces.IParkLoadSaveManager")
end

local NoteRemote = function(_x, _y, _z)
  table.insert(s.tRecentRemote, {x = _x, y = _y, z = _z, nTime = s.nClock})
end

local IsRemoteEcho = function(_tKey)
  for _, tRemote in ipairs(s.tRecentRemote) do
    if DistCm(_tKey, tRemote.x, tRemote.y, tRemote.z) <= c_nSearchRadiusMm / 10 then
      return tRemote
    end
  end
  return nil
end

-- ---- outgoing ------------------------------------------------------------------------------------
local NextClipFile = function(_sPrefix)
  s.nClip = s.nClip % c_nClipSlots + 1
  return (_sPrefix or "clip_") .. s.nClip .. ".bin"
end

-- ponytail: a part is sent as name + transform only; scale and custom colours are not carried yet.
local SendPlacePart = function(_obj, _tKey)
  Count("sent part")
  Bridge.SendPacket(c_nPlaceObject, nil, {x = _tKey.x, y = _tKey.y, z = _tKey.z, k = "p", n = _tKey.sName,
    yaw = _tKey.yaw, pitch = _tKey.pitch, roll = _tKey.roll})
end

local Job_SendPlace = function(_obj, _tKey, _op)
  local tWorldAPIs = api.world.GetWorldAPIs()
  local selection = tWorldAPIs.worldserialisation:CreateSaveSelection()
  tWorldAPIs.scenery:AddGroupToBlueprintSelection(_obj, selection)
  local sFile = NextClipFile()
  local bOk, sError = ParkLoadSaveManager():SaveBlueprintToFile(Bridge.GetPrefix() .. sFile, selection, true)
  if not bOk then
    Count("send failed")
    Bridge.Log("build sync: blueprint save failed for " .. Label(_obj, _tKey) .. ": " .. tostring(sError))
    return
  end
  Count("sent group")
  s.tGroupFile[_obj] = sFile
  if _op ~= nil then
    _op.sFile = sFile
  end
  Bridge.Log("build sync: blueprint saved " .. sFile .. " for " .. Label(_obj, _tKey))
  Bridge.SendPacket(c_nPlaceObject, sFile, {x = _tKey.x, y = _tKey.y, z = _tKey.z})
end

-- h carries the sender's group/part ID as a lookup hint; the receiver only trusts it if its own object with
-- that ID sits at the sent position (NETWORK_PROTOCOL.md, ACTION_DELETE_SPATIAL). Parts carry their
-- resource name instead (k = "p", n = name).
local SendDelete = function(_tKey, _obj)
  local tNet = s.tNetKey[_obj]
  local tPos = tNet or _tKey
  local bPart = IsPart(_obj)
  local nHint = bPart and (PartIDOf(_obj) or 0) or _obj
  Count(bPart and "sent part delete" or "sent group delete")
  Bridge.SendPacket(c_nDeleteSpatial, nil, {h = nHint, x = tPos.x, y = tPos.y, z = tPos.z,
    r = c_nSearchRadiusMm, p = tNet and 1 or nil, k = bPart and "p" or nil, n = bPart and _tKey.sName or nil})
end

local Emit = function(_sWhat, _obj, _tKey, _bSending)
  local tRemote = IsRemoteEcho(_tKey)
  if tRemote ~= nil then
    -- A replayed remote action: never sent back; a placed object keeps the position the peer knows it by.
    s.tNetKey[_obj] = _sWhat == "place" and {x = tRemote.x, y = tRemote.y, z = tRemote.z} or nil
    Bridge.Log("build sync: " .. _sWhat .. " " .. Label(_obj, _tKey) .. " came from the remote player, not sent back")
    return false
  end
  Bridge.Log("build sync: local " .. _sWhat .. " " .. Label(_obj, _tKey) .. " at " .. _tKey.sSig ..
    " [tool " .. s.sTool .. "]" .. (_bSending and "" or " (not in session, not sent)"))
  if not _bSending then
    return false
  end
  local op = {sKind = IsPart(_obj) and "part" or "group", sWhat = _sWhat, tKey = _tKey,
    sFile = (not IsPart(_obj)) and s.tGroupFile[_obj] or nil}
  table.insert(s.tPendingOps, op)
  if _sWhat == "delete" then
    SendDelete(_tKey, _obj)
    s.tNetKey[_obj] = nil
  else
    -- Placed or moved here: this client's own position is now the shared one.
    s.tNetKey[_obj] = nil
    if IsPart(_obj) then
      SendPlacePart(_obj, _tKey)
    else
      table.insert(s.tJobs, {fn = function() Job_SendPlace(_obj, _tKey, op) end})
    end
  end
  return true
end

local Job_ApplyPlace, Job_ApplyDelete, QueueRemote -- defined below; used by the landing-offset correction

local ProcessSettled = function(_bSending)
  if s.fnSettleListener ~= nil then
    s.fnSettleListener()
  end
  -- Objects built by a replayed remote action: remember their key, never emit them.
  local tRemoteObjs = {}
  for _, nPartID in ipairs(s.tRemoteTouched) do
    local obj = ObjOfPart(nPartID)
    if obj ~= nil and not tRemoteObjs[obj] then
      tRemoteObjs[obj] = true
      local tKey = KeyOf(obj)
      s.tKnown[obj] = tKey
      s.tSeen[obj] = true
      s.tNetKey[obj] = s.tPendingNetKey
      local sOff = ""
      if tKey ~= nil and s.tPendingNetKey ~= nil then
        s.nLastLandedCm = Cm(DistCm(tKey, s.tPendingNetKey.x, s.tPendingNetKey.y, s.tPendingNetKey.z) / 100)
        sOff = string.format(", landed %d cm from target", s.nLastLandedCm)
      end
      Bridge.Log("build sync: " .. Label(obj, tKey) .. " came from the remote player, not sent back" .. sOff)
      -- The open-editor route has no drift check: an aquarium landed 154 cm off (autotest 2026-11-27). The
      -- offset is fixed per blueprint, so delete it and re-place once with the offset subtracted.
      local tPend = s.tPendingNetKey
      if not IsPart(obj) and tKey ~= nil and tPend ~= nil and tPend.sFile ~= nil and not tPend.bCorrected and
          DistCm(tKey, tPend.x, tPend.y, tPend.z) > c_nDriftToleranceCm then
        local tFix = {x = 2 * tPend.x - tKey.x, y = 2 * tPend.y - tKey.y, z = 2 * tPend.z - tKey.z,
          tNet = {x = tPend.x, y = tPend.y, z = tPend.z, bCorrected = true}}
        Bridge.Log("build sync: re-placing " .. Label(obj, tKey) .. " once with its landing offset corrected")
        local tDel = {h = obj, x = tKey.x, y = tKey.y, z = tKey.z, r = c_nSearchRadiusMm}
        QueueRemote(function() Job_ApplyDelete(tDel) end, false, true)
        local sFile = tPend.sFile
        QueueRemote(function() Job_ApplyPlace(sFile, tFix) end, true, true)
      end
      -- Keep the partner's building as a blueprint too, so deleting it here can be undone.
      if not IsPart(obj) and tKey ~= nil then
        table.insert(s.tJobs, {fn = function() BuildSync.SnapshotGroup(obj) end})
      end
    end
  end
  s.tRemoteTouched = {}
  if next(tRemoteObjs) ~= nil then
    s.tPendingNetKey = nil
  end
  -- The batch is taken first, so an error in it drops this batch instead of repeating every frame.
  local tPre, tTouched, bUndoSettle = s.tPre, s.tTouched, s.bUndoSettle
  s.tPre = {}
  s.tTouched = {}
  s.bUndoSettle = false
  local tObjs = {}
  local nPre, nParts = 0, 0
  for obj in pairs(tPre) do
    tObjs[obj] = true
    nPre = nPre + 1
  end
  for _, nPartID in ipairs(tTouched) do
    local obj = ObjOfPart(nPartID)
    if obj ~= nil then
      if IsPart(obj) and not tObjs[obj] then
        nParts = nParts + 1
      end
      tObjs[obj] = true
    end
  end
  -- Undo/redo and the retail delete tool bypass the hierarchy hooks (diag.log 2026-11-12: deletes settled
  -- with pre-image groups=0), so every object this client knows is re-checked on every settle.
  -- ponytail: only objects seen this session; objects loaded from the save are caught once tracked.
  for obj in pairs(s.tSeen) do
    tObjs[obj] = true
  end
  -- One line per settled edit, so "nothing detected" and "nothing happened" look different in diag.log.
  if s.nSettleLogs < c_nSettleLogLimit then
    s.nSettleLogs = s.nSettleLogs + 1
    local nObjs = 0
    for _ in pairs(tObjs) do
      nObjs = nObjs + 1
    end
    Bridge.Log("build sync settle: committed parts=" .. #tTouched .. " loose parts=" .. nParts ..
      " pre-image=" .. nPre .. " undo=" .. tostring(bUndoSettle) .. " objects to check=" .. nObjs ..
      " tool=" .. s.sTool)
  end
  local bChanged = false
  for obj in pairs(tObjs) do
    local tBefore = tPre[obj]
    if tBefore == nil then
      tBefore = s.tKnown[obj]
    elseif tBefore == false then
      tBefore = nil
    end
    local tNow = KeyOf(obj)
    if not SameKey(tBefore, tNow) then
      if tBefore ~= nil then
        bChanged = Emit("delete", obj, tBefore, _bSending) or bChanged
      end
      if tNow ~= nil then
        bChanged = Emit("place", obj, tNow, _bSending) or bChanged
      end
    end
    s.tKnown[obj] = tNow
    s.tSeen[obj] = true
  end
  if #s.tPendingOps > 0 then
    table.insert(s.tUndo, {ops = s.tPendingOps})
    if #s.tUndo > c_nJournalLimit then
      table.remove(s.tUndo, 1)
    end
    s.tRedo = {}
  end
  s.tPendingOps = {}
  if bChanged and s.fnOnLocalChange then
    s.fnOnLocalChange()
  end
end

-- ---- incoming ------------------------------------------------------------------------------------
-- A native crash kills the game before queued log lines are flushed, so each risky engine call is preceded
-- by a log line that is flushed and given a frame to reach the DLL.
local Breadcrumb = function(_sStep)
  Bridge.Log("build sync apply: " .. _sStep)
  Bridge.Flush(true)
  coroutine.yield()
end

-- Drift fix: the sender's key is the AABB centre of its groups, but SetCompositeOriginToOBBCentre places
-- the OBB centre there, which landed copies ~1.3 m off (diag.log 2026-11-12 08:04). Once previewed, the new
-- groups exist, so their AABB is measured and the composite shifted by the difference.
local MakeDriftAdjust = function(_moveObject, _tData)
  return function()
    local nCount, tGroupIDs = _moveObject:GetGroups()
    if type(nCount) ~= "number" or nCount < 1 or type(tGroupIDs) ~= "table" then
      Bridge.Log("build sync: drift check skipped (preview has no groups, kind=" .. tostring(_tData.k or "group") .. ")")
      return
    end
    local nMinX, nMinY, nMinZ, nMaxX, nMaxY, nMaxZ
    for _, nGroupID in pairs(tGroupIDs) do
      local tKey = GroupKey(nGroupID)
      if tKey ~= nil then
        local x0, y0, z0 = tKey.x - tKey.ex / 2, tKey.y - tKey.ey / 2, tKey.z - tKey.ez / 2
        local x1, y1, z1 = tKey.x + tKey.ex / 2, tKey.y + tKey.ey / 2, tKey.z + tKey.ez / 2
        nMinX, nMinY, nMinZ = math.min(nMinX or x0, x0), math.min(nMinY or y0, y0), math.min(nMinZ or z0, z0)
        nMaxX, nMaxY, nMaxZ = math.max(nMaxX or x1, x1), math.max(nMaxY or y1, y1), math.max(nMaxZ or z1, z1)
      end
    end
    if nMinX == nil then
      Bridge.Log("build sync: drift check skipped (previewed groups have no AABB yet)")
      return
    end
    s.tLastGroupBox = {y0 = nMinY, y1 = nMaxY} -- cm, autotest only (BuildSync.TakeLastGroupBox)
    local dx = _tData.x - (nMinX + nMaxX) / 2
    local dy = _tData.y - (nMinY + nMaxY) / 2
    local dz = _tData.z - (nMinZ + nMaxZ) / 2
    local nOff = math.sqrt(dx * dx + dy * dy + dz * dz)
    if nOff <= c_nDriftToleranceCm then
      Bridge.Log(string.format("build sync: drift %d cm before commit, no correction needed", Cm(nOff / 100)))
      return
    end
    local vPos
    local bGotPos, vCur = pcall(function() return _moveObject:GetPosition() end)
    if bGotPos and vCur ~= nil then
      vPos = Vector3:new(vCur:GetX() + dx / 100, vCur:GetY() + dy / 100, vCur:GetZ() + dz / 100)
    else
      vPos = Vector3:new((_tData.x + dx) / 100, (_tData.y + dy) / 100, (_tData.z + dz) / 100)
    end
    _moveObject:SetTransform(TransformQ.Identity:WithPos(vPos), {})
    Bridge.Log(string.format("build sync: drift %d cm before commit, corrected", Cm(nOff / 100)))
  end
end

local PrepareBuildHierarchy = function(_hierarchy)
  pcall(function()
    if _hierarchy.SetPerformTerrainModificationsModifyVolumes ~= nil then
      _hierarchy:SetPerformTerrainModificationsModifyVolumes(false)
    end
    local gt = api.world.GetWorldAPIs().gameterrain
    local op = _hierarchy.GetTerrainEditOperation and _hierarchy:GetTerrainEditOperation() or nil
    if gt ~= nil and op ~= nil and gt.SetTerrainEditOpCollisionFlags ~= nil then
      gt:SetTerrainEditOpCollisionFlags(op, true, false, false, true, true, gt.CheckLakesMode_Off or 0, false)
    end
  end)
end

-- Vanilla blueprint commit check, exactly (SingleFeatureUndoablePlacementModeBase._OnTryCommitCheck +
-- BlueprintPlacementMode.OnTryCommitCheck): terrain edits on, and the move object flattens/joins the ground
-- unless its toggle is locked to never flatten. Without it a friend's aquarium or floor ignores the terrain.
local VanillaPlacementCommitStep = function(_hierarchy, _moveObject)
  local tResult = {}
  local Step = function(_sName, _fn)
    local bOk, sErr = pcall(_fn)
    table.insert(tResult, _sName .. "=" .. (bOk and "ok" or ("ERR " .. tostring(sErr))))
  end
  Step("begin", function() _hierarchy:BeginVolumeModificationsBlock() end)
  Step("terrain", function() _hierarchy:SetPerformTerrainModificationsModifyVolumes(true) end)
  if _moveObject ~= nil then
    Step("flatten", function()
      local editors = api.world.GetWorldAPIs().editors
      local nToggle = _moveObject:GetFlattenTerrainToggleState()
      local bFlatten = nToggle ~= editors.FlattenTerrain_LockedNeverFlatten
      editors:SetTerrainActionOnMoveObject(_moveObject,
        bFlatten and editors.TerrainActionType_PathJoinPartFlatten or editors.TerrainActionType_None, true)
      table.insert(tResult, "toggle=" .. tostring(nToggle) .. " flatten=" .. tostring(bFlatten))
      if not s.bLoggedTerrainConsts then
        s.bLoggedTerrainConsts = true
        local tConsts = {}
        pcall(function()
          for k, v in pairs(editors) do
            if type(k) == "string" and (k:find("TerrainAction", 1, true) or k:find("FlattenTerrain", 1, true)) then
              table.insert(tConsts, k .. "=" .. tostring(v))
            end
          end
        end)
        table.sort(tConsts)
        Bridge.Log("build sync: terrain consts " .. table.concat(tConsts, " "))
      end
    end)
  else
    table.insert(tResult, "flatten=skipped(no move object)")
  end
  Step("end", function() _hierarchy:EndVolumeModificationsBlock() end)
  if (s.nCommitStepLogs or 0) < 20 then
    s.nCommitStepLogs = (s.nCommitStepLogs or 0) + 1
    Bridge.Log("build sync: commit-check step " .. table.concat(tResult, " "))
  end
end

local Yielding_ApplyChange -- defined after Yielding_ModeOperation

Job_ApplyPlace = function(_sFile, _tData)
  NoteRemote(_tData.x, _tData.y, _tData.z)
  local bCommitted, bViaEditor = Yielding_ApplyChange("group", _tData, function(hierarchy)
    PrepareBuildHierarchy(hierarchy)
    Breadcrumb("load " .. tostring(_sFile))
    local bOk, sError = ParkLoadSaveManager():LoadBlueprintFromFile(_sFile)
    if not bOk then
      Bridge.Log("build sync: remote blueprint load failed: " .. tostring(sError))
      return false
    end
    Breadcrumb("wait until blueprint ready")
    while not hierarchy:IsLoadedBlueprintReadyForEditing() do
      coroutine.yield()
    end
    Breadcrumb("add blueprint to composite")
    local moveObject = hierarchy:CreateCompositeObject({})
    hierarchy:AddBlueprintToCompositeObject(moveObject)
    Breadcrumb("position")
    moveObject:SetCompositeOriginToOBBCentre()
    -- ponytail: position only; rotation rides inside the blueprint. Verify orientation in-game.
    local vPos = Vector3:new(_tData.x / 100, _tData.y / 100, _tData.z / 100)
    moveObject:SetTransform(TransformQ.Identity:WithPos(vPos), {})
    -- tNet: a corrected re-place keeps the original target as the position the partner knows it by.
    s.tPendingNetKey = _tData.tNet or {x = _tData.x, y = _tData.y, z = _tData.z, sFile = _sFile}
    Breadcrumb("preview, drift check, commit")
    local fnDrift = MakeDriftAdjust(moveObject, _tData)
    return true, function()
      fnDrift()
      VanillaPlacementCommitStep(hierarchy, moveObject)
    end, moveObject
  end)
  if bCommitted == nil or bViaEditor then
    return -- retry later, or the editor route already counted and logged it
  elseif bCommitted then
    Count("applied group")
    Bridge.Log("build sync: remote place applied from " .. tostring(_sFile) .. " at " .. _tData.x .. "," ..
      _tData.y .. "," .. _tData.z)
  else
    Count("apply failed")
    Bridge.Log("build sync: remote placement not applied (load failed or rejected by the undo system)")
  end
end

-- ---- part edits through the active editor --------------------------------------------------------
-- editMode:RequestUndoOperation(fn, bCheckpoint, fnPostWait) (editors.shared.baseeditmode.lua:155) runs fn(clh)
-- inside the current editor's own coroutine, creating, previewing and committing the change list there.
local GetEditMode = function()
  local bOk, mode = pcall(function()
    local BaseEditMode = require("Editors.Shared.BaseEditMode")
    return api.world.GetWorldAPIs().ModeHelperComponent:GetCurrentMode(BaseEditMode.GetModeHelperEntity())
  end)
  if bOk and type(mode) == "table" and type(mode.RequestUndoOperation) == "function" then
    return mode
  end
  return nil
end

-- Temporarily suspends Career Mode tutorial placement restrictions (editors:GetIsTutorialActive /
-- SetIsTutorialActive) while applying a remote peer's action so valid builds/deletes/fences from a friend
-- are never rejected with bTutorialPlacementInvalid when peers are on slightly different tutorial steps.
local SuspendTutorialRestriction = function()
  local bWas = false
  pcall(function()
    local ed = api.world.GetWorldAPIs().editors
    if ed ~= nil and ed.GetIsTutorialActive ~= nil and ed.SetIsTutorialActive ~= nil then
      if ed:GetIsTutorialActive() == true then
        ed:SetIsTutorialActive(false)
        bWas = true
      end
    end
  end)
  if bWas then
    s.nTutorialSuspended = (s.nTutorialSuspended or 0) + 1
  end
  return bWas
end

local RestoreTutorialRestriction = function(_bWas)
  if not _bWas then
    return
  end
  s.nTutorialSuspended = math.max(0, (s.nTutorialSuspended or 1) - 1)
  if s.nTutorialSuspended == 0 then
    pcall(function()
      local ed = api.world.GetWorldAPIs().editors
      if ed ~= nil and ed.SetIsTutorialActive ~= nil then
        ed:SetIsTutorialActive(true)
      end
    end)
  end
end

-- Hands _fnChange to the active editor, waiting until one exists and is idle; then waits for the commit
-- (or exits promptly if the editor finishes without calling postWait because the commit was refused).
local Yielding_ModeOperation = function(_sWhat, _tData, _fnChange)
  local nStart = s.nClock
  local bLoggedWait = false
  while true do
    local mode = GetEditMode()
    -- Not while the engine is still finishing a commit: a remote part handed over right after a 697-part
    -- aquarium commit (water still filling) crashed at PlanetZoo2.exe+0x6e75372 (2026-11-27 12:45).
    local bBusy = select(2, pcall(s.rawUndo.IsBusy)) == true or
      s.nClock - (s.nLastLocalCommit or -1e9) < c_nAfterLocalCommit
    if mode ~= nil and not bBusy and not mode:HasRequestedChange() then
      local tState = {bDone = false, bRan = false, bAppliedGuard = false, bTutSuspended = false}
      local bQueued = mode:RequestUndoOperation(function(clh)
        tState.bRan = true
        tState.bTutSuspended = SuspendTutorialRestriction()
        if not Bridge.IsApplying() then
          Bridge.BeginApply()
          tState.bAppliedGuard = true
        end
        -- Recorded when the change actually runs, so the echo window covers the commit that follows.
        NoteRemote(_tData.x, _tData.y, _tData.z)
        _fnChange(clh)
      end, true, function()
        NoteRemote(_tData.x, _tData.y, _tData.z)
        s.rawUndo.ClearHistory({})
        tState.bDone = true
        if tState.bAppliedGuard then
          tState.bAppliedGuard = false
          Bridge.EndApply()
        end
        if tState.bTutSuspended then
          tState.bTutSuspended = false
          RestoreTutorialRestriction(true)
        end
        s.nRemoteGraceUntil = s.nClock + c_nRemoteGrace
      end)
      if bQueued then
        Bridge.Log("build sync: " .. _sWhat .. " handed to the active editor")
        local nQueued = s.nClock
        local nIdleAfterRun = 0
        while not tState.bDone and s.nClock - nQueued < c_nModeOpTimeout do
          if tState.bRan and not mode:HasRequestedChange() then
            nIdleAfterRun = nIdleAfterRun + 1
            if nIdleAfterRun >= 2 then
              break -- editor completed the coroutine without calling postWait (commit refused)
            end
          end
          coroutine.yield()
        end
        if tState.bAppliedGuard then
          tState.bAppliedGuard = false
          Bridge.EndApply()
        end
        if tState.bTutSuspended then
          tState.bTutSuspended = false
          RestoreTutorialRestriction(true)
        end
        s.nRemoteGraceUntil = s.nClock + c_nRemoteGrace
        if tState.bDone then
          Count("applied " .. _sWhat)
          Bridge.Log("build sync: remote " .. _sWhat .. " applied, undo history cleared")
        elseif tState.bRan and nIdleAfterRun >= 2 then
          Count("apply failed")
          Bridge.Log("build sync: remote " .. _sWhat .. " refused by the active editor")
        else
          Count("apply failed")
          Bridge.Log("build sync: remote " .. _sWhat .. " not committed by the editor within " .. c_nModeOpTimeout .. " s")
        end
        return tState.bDone
      end
    end
    if not bLoggedWait then
      bLoggedWait = true
      Bridge.Log("build sync: remote " .. _sWhat .. " waits for an idle editor")
    end
    if s.nClock - nStart > c_nModeOpTimeout then
      Count("apply failed")
      Bridge.Log("build sync: remote " .. _sWhat .. " not handed over, no idle editor for " .. c_nModeOpTimeout .. " s")
      return nil -- never queued, so a caller may safely try again
    end
    coroutine.yield()
  end
end

-- Commits a remote change that _fnBuild(hierarchy) fills in; _fnBuild returns false if it could not, else
-- true plus an optional adjust to run once the preview exists. Undo system free: our own change list (drift
-- check). While the player holds a preview (an item in hand), the change goes to their active editor
-- instead: it parks its ghost, runs the change and carries on, the vanilla Ctrl+Z route
-- (editors.scenery.submodeplacement.lua:1119 _DoBeginRequestedChange). Before this, a friend's buildings
-- waited until you put the item down (88 s in the 2026-11-25 test).
-- Returns committed (true/false) and whether the editor ran it; nil = try again later (s.bRetry set).
Yielding_ApplyChange = function(_sWhat, _tData, _fnBuild)
  -- PZ2COOP_FORCE_EDITOR (autotest only): take the editor route without a live player preview.
  if IsUndoFree() and global.rawget(global, "PZ2COOP_FORCE_EDITOR") ~= true then
    local hierarchy = api.world.GetWorldAPIs().editors:CreateUndoOperationsHierarchy()
    local bBuilt, fnAdjust = _fnBuild(hierarchy)
    if not bBuilt then
      return false, false
    end
    return Yielding_Commit(hierarchy, fnAdjust), false
  end
  local bBuilt = false
  local bDone = Yielding_ModeOperation(_sWhat, _tData, function(clh)
    local bOk, fnAdjust, moveObject = _fnBuild(clh)
    bBuilt = bOk == true
    if bBuilt and fnAdjust ~= nil then
      -- No preview step here (the editor previews and commits itself): do the commit-check step now.
      VanillaPlacementCommitStep(clh, moveObject)
    end
  end)
  if bDone == nil then
    s.bRetry = true
    return nil, true
  end
  return bDone and bBuilt, true
end

-- A part is re-created by name, as the asset showroom spawns scenery
-- (managers.assetsshowroomdebugmanager.lua: Yielding_CreateNewPart_Scenery + SetTransform).
local Job_ApplyPlacePart = function(_tData)
  Yielding_ModeOperation("part " .. tostring(_tData.n), _tData, function(clh)
    local moveObject = SceneryEditHelper.Yielding_CreateNewPart_Scenery(clh, _tData.n)
    local vYpr = Vector3:new((_tData.yaw or 0) / 1000, (_tData.pitch or 0) / 1000, (_tData.roll or 0) / 1000)
    local vPos = Vector3:new(_tData.x / 100, _tData.y / 100, _tData.z / 100)
    moveObject:SetTransform(TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(vYpr), vPos), {})
  end)
end

-- Discovers pre-existing scenery parts or building groups near (_xCm, _yCm, _zCm) via spatial:SphereQuery
-- (same flag set + parent walk as editors.demolish.demolisheditmode.lua:888-960) so deleting objects that
-- were loaded from the baseline save (and thus absent from s.tSeen) works reliably across peers.
local AddSpatialCandidates = function(_tCandidates, _bPart, _xCm, _yCm, _zCm, _nRadiusCm)
  local tWorld = api.world.GetWorldAPIs()
  local spatial = tWorld.spatial
  local puppets = tWorld.scenery_puppets
  if spatial == nil or spatial.SphereQuery == nil or puppets == nil or puppets.EntityIDToPlacementID == nil then
    return
  end
  local nFlags = 0
  for _, sFlag in ipairs({
    "Flag_Scenery", "Flag_NonStaticScenery", "Flag_BulldozeNature", "Flag_Facility", "Flag_Exhibit",
    "Flag_PathExtra", "Flag_Enrichment", "Flag_StaticEnrichment", "Flag_Bedding", "Flag_BulldozeHabitatObjects",
  }) do
    local nBit = spatial[sFlag]
    if type(nBit) == "number" then
      nFlags = nFlags | nBit
    end
  end
  if nFlags == 0 then
    return
  end
  local nRadiusM = math.max((_nRadiusCm or 25) / 100 + 1.5, 2.5)
  local vPos = Vector3:new(_xCm / 100, _yCm / 100, _zCm / 100)
  local bOk, tHits = pcall(spatial.SphereQuery, spatial, vPos, nRadiusM, nFlags, 0, 128)
  if not bOk or type(tHits) ~= "table" then
    return
  end
  local pih = tWorld.PlayerInteractionHandler
  local tr = tWorld.transform
  local tChecked = {}
  local TryEntity = function(_nEntityID)
    if _nEntityID == nil or tChecked[_nEntityID] then
      return
    end
    tChecked[_nEntityID] = true
    local bP, nPartID = pcall(puppets.EntityIDToPlacementID, puppets, _nEntityID)
    if bP and type(nPartID) == "number" then
      if _bPart then
        _tCandidates["p" .. nPartID] = true
      else
        local nGroupID = GroupOf(nPartID)
        if nGroupID ~= nil then
          _tCandidates[nGroupID] = true
        end
      end
    end
  end
  for _, nHit in ipairs(tHits) do
    TryEntity(nHit)
    local nCur = nHit
    for _ = 1, 4 do
      if nCur == nil then
        break
      end
      local nNext = nil
      pcall(function()
        if pih ~= nil and pih.HasParentEntityID ~= nil and pih:HasParentEntityID(nCur) then
          nNext = pih:GetParentID(nCur)
        elseif tr ~= nil and tr.GetParent ~= nil then
          nNext = tr:GetParent(nCur)
        end
      end)
      if nNext == nil or nNext == nCur then
        break
      end
      TryEntity(nNext)
      nCur = nNext
    end
  end
end

-- Candidates: objects seen this session + sender's ID hint + spatial query for pre-existing save objects;
-- the spatial key (and, for parts, the resource name) always decides (CLAUDE.md rule 3).
local FindNear = function(_tData)
  local bPart = _tData.k == "p"
  local nRadiusCm = (_tData.r or c_nSearchRadiusMm) / 10
  local tCandidates = {}
  for obj in pairs(s.tSeen) do
    if IsPart(obj) == bPart then
      tCandidates[obj] = true
    end
  end
  if type(_tData.h) == "number" and _tData.h > 0 then
    tCandidates[bPart and ("p" .. _tData.h) or _tData.h] = true
  end
  local SearchCandidates = function()
    local bestObj, nBestDist = nil, nil
    for obj in pairs(tCandidates) do
      local tKey = KeyOf(obj)
      if tKey ~= nil and (not bPart or tKey.sName == _tData.n) then
        local tMatch = s.tNetKey[obj] or tKey
        local nDist = DistCm(tMatch, _tData.x, _tData.y, _tData.z)
        if nDist <= nRadiusCm and (nBestDist == nil or nDist < nBestDist) then
          bestObj, nBestDist = obj, nDist
        end
      end
    end
    return bestObj
  end
  local bestObj = SearchCandidates()
  if bestObj == nil then
    AddSpatialCandidates(tCandidates, bPart, _tData.x, _tData.y, _tData.z, nRadiusCm)
    bestObj = SearchCandidates()
  end
  return bestObj
end

Job_ApplyDelete = function(_tData)
  NoteRemote(_tData.x, _tData.y, _tData.z)
  local obj = FindNear(_tData)
  if obj == nil then
    Count("apply failed")
    Bridge.Log("build sync: remote delete found no " .. (_tData.k == "p" and ("part " .. tostring(_tData.n)) or "group") ..
      " near " .. _tData.x .. "," .. _tData.y .. "," .. _tData.z)
    return
  end
  local tWorldAPIs = api.world.GetWorldAPIs()
  if IsPart(obj) then
    -- components.ui.exhibitinfopopup.lua:1818, through the active editor like a popup.
    Yielding_ModeOperation("part delete", _tData, function(clh)
      local composite = clh:CreateCompositeObject({})
      SceneryEditHelper.NonYielding_AddPartToDestroyIntoCompositeObject(clh, composite, PartIDOf(obj))
      SceneryEditHelper.Yielding_DestroyCompositeContents(tWorldAPIs, clh, composite)
    end)
    s.tNetKey[obj] = nil
    return
  end
  Breadcrumb("delete " .. Label(obj, KeyOf(obj)))
  local bDeleted, bViaEditor = Yielding_ApplyChange("group delete", _tData, function(hierarchy)
    local group = SceneryEditHelper.Yielding_EditExistingPart_Group(hierarchy, obj)
    local tEditObjs = SceneryEditHelper.Yielding_EditGroupContents(tWorldAPIs, hierarchy, group)
    local composite = hierarchy:CreateCompositeObject({})
    hierarchy:AddPartsToCompositeObject(composite, tEditObjs)
    group:RemoveMember(composite)
    group:ClearMembers()
    group:Destroy()
    composite:Destroy()
    return true
  end)
  if bDeleted == nil then
    return
  end
  s.tKnown[obj] = nil
  s.tNetKey[obj] = nil
  if bViaEditor then
    return -- the editor route already counted and logged it
  end
  Count("applied group delete")
  Bridge.Log("build sync: remote delete applied to " .. Label(obj))
end

-- The engine has ONE loaded-blueprint slot (IsLoadedBlueprintReadyForEditing takes no argument) and the
-- blueprint tool reloads it for every ghost in hand (editors.blueprint.blueprintplacementmode.lua CreateNew).
-- Loading a remote blueprint while that tool is open crashed the game (diag.log 2026-11-12 07:57), so remote
-- placements wait until every blueprint tool instance has shut down.
-- ponytail: a friend's builds appear only once you leave the blueprint tool; needs a slot-free load path to fix.
local HookBlueprintMode = function()
  local bOk, Mode = pcall(require, "Editors.Blueprint.BlueprintPlacementMode")
  if not bOk or type(Mode) ~= "table" or rawget(Mode, "__PZ2CoopHooked") ~= nil then
    return
  end
  local fnInit, fnShutdown = rawget(Mode, "Init"), rawget(Mode, "Shutdown")
  if type(fnInit) ~= "function" or type(fnShutdown) ~= "function" then
    return
  end
  rawset(Mode, "__PZ2CoopHooked", true)
  rawset(Mode, "Init", function(self, ...)
    s.tBlueprintModes[self] = true
    return fnInit(self, ...)
  end)
  rawset(Mode, "Shutdown", function(self, ...)
    s.tBlueprintModes[self] = nil
    return fnShutdown(self, ...)
  end)
  Bridge.Log("build sync: blueprint tool hook installed")
end

local IsBlueprintToolOpen = function()
  return next(s.tBlueprintModes) ~= nil
end

local LogWait = function(_sReason, _bWaiting)
  if _bWaiting and not s.tWaitLogged[_sReason] then
    s.tWaitLogged[_sReason] = true
    Bridge.Log("build sync: remote action waits: " .. _sReason)
  elseif not _bWaiting and s.tWaitLogged[_sReason] then
    s.tWaitLogged[_sReason] = nil
    Bridge.Log("build sync: no longer waiting: " .. _sReason)
  end
end

-- Jobs that can go through the player's editor (bEditorOk: building place/delete) run while the player
-- previews; the rest (paths, fences) still wait until the player stops previewing.
local NextRunnableJob = function()
  local bToolOpen = IsBlueprintToolOpen()
  local bUndoFree = IsUndoFree()
  local bEditor = not bUndoFree and GetEditMode() ~= nil
  for i, tJob in ipairs(s.tJobs) do
    local bSlotWait = tJob.bSlot and bToolOpen
    local bPreviewWait = tJob.bPreview and not bUndoFree and not (tJob.bEditorOk and bEditor)
    if tJob.bSlot then
      LogWait("blueprint tool is open", bSlotWait)
    end
    if tJob.bPreview then
      LogWait("player is previewing a change", bPreviewWait)
    end
    if not bSlotWait and not bPreviewWait then
      return i
    end
  end
  return nil
end

-- Wraps a remote job in the apply guard (CLAUDE.md rule 2) + temporary Career tutorial restriction suspend,
-- and re-queues it at the front when its commit found the undo system taken.
QueueRemote = function(_fnJob, _bSlot, _bEditorOk)
  local tJob = {bSlot = _bSlot, bPreview = true, bEditorOk = _bEditorOk == true}
  tJob.fn = function()
    local bTutSuspended = SuspendTutorialRestriction()
    Bridge.BeginApply()
    s.bRetry = false
    _fnJob()
    Bridge.EndApply()
    RestoreTutorialRestriction(bTutSuspended)
    s.nRemoteGraceUntil = s.nClock + c_nRemoteGrace
    if s.bRetry then
      s.bRetry = false
      tJob.nRetries = (tJob.nRetries or 0) + 1
      if tJob.nRetries == 1 then
        Bridge.Log("build sync: undo system taken just before the remote commit, will retry")
      end
      if tJob.nRetries <= c_nMaxRetries then
        table.insert(s.tJobs, 1, tJob)
      else
        Count("apply failed")
        Bridge.Log("build sync: remote action dropped after " .. c_nMaxRetries .. " retries (undo never free)")
      end
    end
  end
  table.insert(s.tJobs, tJob)
end

-- ---- own undo per player -----------------------------------------------------------------------------
BuildSync.SnapshotGroup = function(_obj)
  if KeyOf(_obj) == nil then
    return
  end
  local tWorldAPIs = api.world.GetWorldAPIs()
  local selection = tWorldAPIs.worldserialisation:CreateSaveSelection()
  tWorldAPIs.scenery:AddGroupToBlueprintSelection(_obj, selection)
  local sFile = NextClipFile()
  local bOk = ParkLoadSaveManager():SaveBlueprintToFile(Bridge.GetPrefix() .. sFile, selection, true)
  if bOk then
    s.tGroupFile[_obj] = sFile
  end
end

-- Performs one op ("place" or "delete" of a part or group at its key) here AND on the partner's side: the
-- packet is what a live edit would send, the local job is the same apply a received packet runs (so the
-- result is never sent back and never journaled).
local PerformOp = function(_op, _sWhat)
  local k = _op.tKey
  if _op.sKind == "part" then
    local tData = {x = k.x, y = k.y, z = k.z, k = "p", n = k.sName, yaw = k.yaw, pitch = k.pitch, roll = k.roll}
    if _sWhat == "place" then
      Bridge.SendPacket(c_nPlaceObject, nil, tData)
      table.insert(s.tJobs, {fn = function() Job_ApplyPlacePart(tData) end})
    else
      tData.r = c_nSearchRadiusMm
      Bridge.SendPacket(c_nDeleteSpatial, nil, tData)
      table.insert(s.tJobs, {fn = function() Job_ApplyDelete(tData) end})
    end
    return true
  end
  if _sWhat == "place" then
    if _op.sFile == nil then
      return false
    end
    local tData = {x = k.x, y = k.y, z = k.z}
    Bridge.SendPacket(c_nPlaceObject, _op.sFile, tData)
    local sPath = Bridge.GetPrefix() .. _op.sFile
    QueueRemote(function() Job_ApplyPlace(sPath, tData) end, true, true)
  else
    local tData = {h = 0, x = k.x, y = k.y, z = k.z, r = c_nSearchRadiusMm}
    Bridge.SendPacket(c_nDeleteSpatial, nil, tData)
    QueueRemote(function() Job_ApplyDelete(tData) end, false, true)
  end
  return true
end

local Opposite = {place = "delete", delete = "place"}

-- Undo replays the inverse ops newest-first; redo replays the ops in order.
local ReplayEntry = function(_tEntry, _bUndo)
  local nDone, nSkipped = 0, 0
  local nFrom, nTo, nStep = 1, #_tEntry.ops, 1
  if _bUndo then
    nFrom, nTo, nStep = #_tEntry.ops, 1, -1
  end
  for i = nFrom, nTo, nStep do
    local op = _tEntry.ops[i]
    if PerformOp(op, _bUndo and Opposite[op.sWhat] or op.sWhat) then
      nDone = nDone + 1
    else
      nSkipped = nSkipped + 1
    end
  end
  return nDone, nSkipped
end

-- Called instead of the game's undo/redo while co-op is on. Returns true when handled here; false lets the
-- game's own undo run (path/fence edits, whose previous state only the game's undo history holds).
BuildSync.HandleUndoRedo = function(_bUndo)
  local tFrom, tTo = s.tUndo, s.tRedo
  if not _bUndo then
    tFrom, tTo = s.tRedo, s.tUndo
  end
  local sWhat = _bUndo and "undo" or "redo"
  local tEntry = table.remove(tFrom)
  if tEntry == nil then
    Bridge.Log("undo: nothing to " .. sWhat)
    return true
  end
  if tEntry.sRegion ~= nil then
    local fnCan = _bUndo and s.rawUndo.CanUndo or s.rawUndo.CanRedo
    local bOk, bCan = pcall(fnCan)
    if bOk and bCan then
      table.insert(tTo, tEntry)
      s.nJournalMuteUntil = s.nClock + 3
      Bridge.Log("undo: " .. sWhat .. " " .. tEntry.sRegion .. " edit with the game's undo")
      return false
    end
    Bridge.Log("undo: cannot " .. sWhat .. " that " .. tEntry.sRegion .. " edit (the partner built since; only " ..
      "buildings and single pieces can be undone past that)")
    return true
  end
  local nDone, nSkipped = ReplayEntry(tEntry, _bUndo)
  table.insert(tTo, tEntry)
  Count(sWhat)
  Bridge.Log("undo: " .. sWhat .. " of " .. #tEntry.ops .. " change(s): " .. nDone .. " done" ..
    (nSkipped > 0 and (", " .. nSkipped .. " skipped (no saved blueprint)") or ""))
  return true
end

-- RegionSync journals path/fence edits so Ctrl+Z order stays right.
BuildSync.JournalRegion = function(_sKind)
  if s.nClock < s.nJournalMuteUntil then
    return
  end
  table.insert(s.tUndo, {sRegion = _sKind})
  if #s.tUndo > c_nJournalLimit then
    table.remove(s.tUndo, 1)
  end
  s.tRedo = {}
end

-- Ctrl+Z / Ctrl+Y reach MainHUD.RequestUndoRedo (windows.mainhud.lua: OnUndo/OnRedo), looked up through the
-- class on each call, so the module field is wrapped. Re-checked every frame (module files are re-run).
local HookUndoKeys = function()
  local bOk, MainHUD = pcall(require, "Windows.MainHUD")
  if not bOk or type(MainHUD) ~= "table" or rawget(MainHUD, "__PZ2CoopUndoHook") ~= nil then
    return
  end
  local fnOriginal = rawget(MainHUD, "RequestUndoRedo")
  if type(fnOriginal) ~= "function" then
    return
  end
  rawset(MainHUD, "__PZ2CoopUndoHook", true)
  local fnUpdateDisplay = rawget(MainHUD, "UpdateDisplay")
  if type(fnUpdateDisplay) == "function" then
    rawset(MainHUD, "UpdateDisplay", function(...)
      s.bHudQuery = Bridge.GetRole() ~= "none"
      local tResults = table.pack(pcall(fnUpdateDisplay, ...))
      s.bHudQuery = false
      if not tResults[1] then
        error(tResults[2], 0)
      end
      return table.unpack(tResults, 2, tResults.n)
    end)
  end
  rawset(MainHUD, "RequestUndoRedo", function(self, _bUndo, ...)
    if Bridge.GetRole() ~= "none" and s.rawUndo ~= nil then
      local bOkHandle, bHandled = pcall(BuildSync.HandleUndoRedo, _bUndo == true)
      if not bOkHandle then
        Bridge.Log("undo: error " .. tostring(bHandled))
      elseif bHandled then
        return
      end
    end
    return fnOriginal(self, _bUndo, ...)
  end)
  Bridge.Log("undo: Ctrl+Z/Ctrl+Y hook installed (own undo per player while co-op is on)")
end

BuildSync.OnPacket = function(_tMsg)
  if _tMsg.nType == c_nPlaceObject and _tMsg.tData and _tMsg.tData.k == "p" and type(_tMsg.tData.n) == "string" then
    local tData = _tMsg.tData
    table.insert(s.tJobs, {fn = function() Job_ApplyPlacePart(tData) end})
    return true
  end
  if _tMsg.nType == c_nPlaceObject and _tMsg.sFile ~= nil then
    local sFile, tData = _tMsg.sFile, _tMsg.tData
    QueueRemote(function() Job_ApplyPlace(sFile, tData) end, true, true)
    return true
  end
  if _tMsg.nType == c_nDeleteSpatial then
    local tData = _tMsg.tData
    if tData.k == "p" then
      table.insert(s.tJobs, {fn = function() Job_ApplyDelete(tData) end})
    else
      QueueRemote(function() Job_ApplyDelete(tData) end, false, true)
    end
    return true
  end
  return false
end

-- ---- recorders: habitats and volumes (save-proof only) -------------------------------------------
-- Tests whether a habitat / volume can be written into a blueprint file, the precondition for syncing it
-- like groups. Nothing is sent. Result lines: "save-proof <label>: ok|failed ...".
local QueueSaveProof = function(_sKind, _sLabel, _fnFill)
  if Bridge.IsApplying() or (s.tProofs[_sKind] or 0) >= c_nProofLimit then
    return
  end
  s.tProofs[_sKind] = (s.tProofs[_sKind] or 0) + 1
  table.insert(s.tJobs, {fn = function()
    Breadcrumb("save-proof " .. _sLabel)
    local tWorldAPIs = api.world.GetWorldAPIs()
    local selection = tWorldAPIs.worldserialisation:CreateSaveSelection()
    local bFilled, sFillError = pcall(_fnFill, selection, tWorldAPIs)
    if not bFilled then
      Bridge.Log("save-proof " .. _sLabel .. ": failed to build selection: " .. tostring(sFillError))
      return
    end
    local sFile = "proof_" .. _sKind .. "_" .. s.tProofs[_sKind] .. ".bin"
    local bOk, sError = ParkLoadSaveManager():SaveBlueprintToFile(Bridge.GetPrefix() .. sFile, selection, true)
    Bridge.Log("save-proof " .. _sLabel .. ": " .. (bOk and ("ok -> " .. sFile) or ("failed: " .. tostring(sError))))
  end})
end

local OnHabitatBoundaryUpdated = function(_tMessages)
  if type(_tMessages) ~= "table" then
    return
  end
  for _, tMessage in pairs(_tMessages) do
    local nHabitat = type(tMessage) == "table" and tMessage.nHabitatEntityID or nil
    if type(nHabitat) == "number" and not s.tProofedHabitats[nHabitat] then
      s.tProofedHabitats[nHabitat] = true
      Count("habitats changed")
      Bridge.Log("build sync: habitat " .. nHabitat .. " changed [tool " .. s.sTool .. "] (habitat sync not implemented yet)")
      QueueSaveProof("habitat", "habitat " .. nHabitat, function(_selection)
        local BlueprintSaveHelper = require("Helpers.BlueprintSaveHelper")
        BlueprintSaveHelper.AddHabitatToSaveSelection(_selection, nHabitat)
      end)
    end
  end
end

-- Path/terrain/water volumes: the payload layout is unknown, so every numeric field whose name mentions
-- an entity is tried as a save-selection entity.
local OnSpatialVolumeChanged = function(_tMessages)
  if type(_tMessages) ~= "table" or Bridge.IsApplying() then
    return
  end
  for _, tMessage in pairs(_tMessages) do
    if type(tMessage) == "table" then
      local sType = tostring(tMessage.sType)
      Count("volume " .. sType)
      local tEntities = {}
      for k, v in pairs(tMessage) do
        if type(v) == "number" and string.find(string.lower(tostring(k)), "entity", 1, true) then
          table.insert(tEntities, v)
        end
      end
      if #tEntities > 0 then
        QueueSaveProof("volume_" .. sType, "volume " .. sType .. " entities " .. table.concat(tEntities, ","),
          function(_selection)
            for _, nEntity in ipairs(tEntities) do
              _selection:AddEntityID(nEntity)
            end
          end)
      elseif (s.tProofs["volume_" .. sType] or 0) == 0 then
        s.tProofs["volume_" .. sType] = c_nProofLimit
        Bridge.Log("build sync: volume change " .. sType .. " has no entity field to save (see probe line)")
      end
    end
  end
end

-- ---- lifecycle -----------------------------------------------------------------------------------
-- A different park was loaded into the same environment: object IDs and keys no longer apply.
BuildSync.ResetSnapshot = function()
  s.tKnown = {}
  s.tSeen = {}
  s.tPre = {}
  s.tTouched = {}
  s.tRemoteTouched = {}
  s.tNetKey = {}
  s.tPendingNetKey = nil
  s.bUndoSettle = false
  s.tRecentRemote = {}
  s.tCommitTokens = {}
  s.nUndoRedoTimer = nil
  s.tProofedHabitats = {}
  s.tUndo = {}
  s.tRedo = {}
  s.tPendingOps = {}
  s.tGroupFile = {}
end

local Register = function(_sMsgType, _fn)
  local nType = api.messaging[_sMsgType]
  if nType ~= nil then
    s.tReceivers[nType] = _fn
    api.messaging.RegisterReceiver(nType, _fn)
  else
    Bridge.Log("build sync: message type " .. _sMsgType .. " does not exist")
  end
end

BuildSync.Install = function(_fnOnLocalChange)
  if s.rawUndo ~= nil then
    return
  end
  ProbeMethods()
  local raw = api.undo
  s.rawUndo = raw
  s.fnOnLocalChange = _fnOnLocalChange
  s.tJobs = {}
  s.worker = nil
  BuildSync.ResetSnapshot()
  s.tProxy = setmetatable({
    CommitPreview = function(...)
      local token = raw.CommitPreview(...)
      if not Bridge.IsApplying() then
        table.insert(s.tCommitTokens, token)
      end
      return token
    end,
    Undo = function(...)
      s.nUndoRedoTimer = c_nUndoRedoSettle
      return raw.Undo(...)
    end,
    Redo = function(...)
      s.nUndoRedoTimer = c_nUndoRedoSettle
      return raw.Redo(...)
    end,
    -- Only while the HUD draws (s.bHudQuery): remote applies clear the game's history, and a disabled HUD
    -- undo button also blocks Ctrl+Z, so our own per-player journal would never be reached.
    CanUndo = function(...)
      if s.bHudQuery and #s.tUndo > 0 then
        return true
      end
      return raw.CanUndo(...)
    end,
    CanRedo = function(...)
      if s.bHudQuery and #s.tRedo > 0 then
        return true
      end
      return raw.CanRedo(...)
    end,
  }, {__index = raw})
  api.undo = s.tProxy
  HookHierarchy()
  Register("MsgType_PlacementPartCommittedMessage", function(_tMessages)
    if type(_tMessages) ~= "table" then
      return
    end
    s.nCommitMessages = s.nCommitMessages + 1
    for _, tMessage in ipairs(_tMessages) do
      if type(tMessage) == "table" and type(tMessage.nPlacementPartID) == "number" then
        -- Echo suppression by origin, not position: a replay can land off its target (diag.log
        -- 2026-11-12 08:04), which defeated the 25 cm position check and looped the solo mirror.
        if Bridge.IsApplying() or s.nClock < s.nRemoteGraceUntil then
          table.insert(s.tRemoteTouched, tMessage.nPlacementPartID)
        else
          table.insert(s.tTouched, tMessage.nPlacementPartID)
          s.nLastLocalCommit = s.nClock
        end
      end
    end
  end)
  -- Undo/redo from any UI path ends here, wrapped api.undo.Undo or not.
  Register("MsgType_UndoRedoCompletedMessage", function()
    if not Bridge.IsApplying() then
      s.nUndoRedoTimer = c_nUndoRedoSettle
    end
  end)
  Register("MsgType_HabitatBoundaryUpdatedMessage", function(_tMessages)
    local bOk, sError = pcall(OnHabitatBoundaryUpdated, _tMessages)
    if not bOk then
      Bridge.Log("build sync: habitat recorder error: " .. tostring(sError))
    end
  end)
  Register("MsgType_SpatialVolumeChangedMessage", function(_tMessages)
    local bOk, sError = pcall(OnSpatialVolumeChanged, _tMessages)
    if not bOk then
      Bridge.Log("build sync: volume recorder error: " .. tostring(sError))
    end
  end)
end

BuildSync.Uninstall = function()
  if s.rawUndo ~= nil and api.undo == s.tProxy then
    api.undo = getmetatable(s.tProxy).__index
  end
  for nType, fn in pairs(s.tReceivers) do
    api.messaging.UnregisterReceiver(nType, fn)
  end
  s.tReceivers = {}
  UnhookHierarchy()
  if Bridge.IsApplying() then
    Bridge.EndApply()
  end
  if (s.nTutorialSuspended or 0) > 0 then
    s.nTutorialSuspended = 1
    RestoreTutorialRestriction(true)
  end
  s.rawUndo = nil
  s.tProxy = nil
  s.worker = nil
  s.tJobs = {}
end

-- ---- shared with RegionSync (paths and fences): one job queue, so blueprint loads never overlap ----
BuildSync.QueueJob = function(_fn)
  table.insert(s.tJobs, {fn = _fn})
end
BuildSync.QueueRemote = QueueRemote
BuildSync.Yielding_ModeOperation = Yielding_ModeOperation
BuildSync.TakeLastLandedCm = function() -- autotest: distance of the last remote group from its target
  local n = s.nLastLandedCm
  s.nLastLandedCm = nil
  return n
end
BuildSync.TakeLastGroupBox = function()
  local t = s.tLastGroupBox
  s.tLastGroupBox = nil
  return t
end
BuildSync.VanillaPlacementCommitStep = function(...)
  return VanillaPlacementCommitStep(...)
end
BuildSync.Yielding_ApplyChange = function(...)
  return Yielding_ApplyChange(...)
end
BuildSync.Breadcrumb = Breadcrumb
BuildSync.NextClipFile = NextClipFile
BuildSync.IsUndoFree = IsUndoFree
BuildSync.Count = Count
BuildSync.RequestRetry = function()
  s.bRetry = true
end
BuildSync.GetTool = function()
  return s.sTool
end
BuildSync.SetSettleListener = function(_fn)
  s.fnSettleListener = _fn
end
BuildSync.SetExternalBusyCheck = function(_fn)
  s.fnExternalBusy = _fn
end

-- One heartbeat line: what was seen, sent, applied and failed, plus the habitat count (proves the
-- habitat enumerator exists in retail).
BuildSync.Summary = function()
  local nGroups, nParts = 0, 0
  for obj in pairs(s.tSeen) do
    if IsPart(obj) then
      nParts = nParts + 1
    else
      nGroups = nGroups + 1
    end
  end
  local bOk, tHabitats = pcall(function()
    return api.world.GetWorldAPIs().facilities:GetAllHabitatsEntityIDs()
  end)
  local nHabitats = 0
  if bOk and type(tHabitats) == "table" then
    for _ in pairs(tHabitats) do
      nHabitats = nHabitats + 1
    end
  end
  local tStats = {}
  for k, v in pairs(s.tStats) do
    table.insert(tStats, k .. "=" .. v)
  end
  table.sort(tStats)
  return "commit messages=" .. s.nCommitMessages .. " settles=" .. s.nSettleLogs .. " groups seen=" .. nGroups ..
    " parts seen=" .. nParts .. " habitats=" .. (bOk and tostring(nHabitats) or "n/a") .. " tool=" .. s.sTool ..
    " installed=" .. tostring(s.rawUndo ~= nil) .. (#tStats > 0 and (" | " .. table.concat(tStats, " ")) or "")
end

-- _bSending: this client is in a session (hosting or joined); detections are logged either way.
BuildSync.Update = function(_nDeltaTime, _bSending)
  if s.rawUndo == nil then
    return
  end
  s.nClock = s.nClock + _nDeltaTime
  for i = #s.tRecentRemote, 1, -1 do
    if s.nClock - s.tRecentRemote[i].nTime > c_nEchoWindow then
      table.remove(s.tRecentRemote, i)
    end
  end
  HookBlueprintMode()
  HookToolTracker()
  HookUndoKeys()
  -- Run queued jobs one at a time in a coroutine (blueprint save/load and commits yield).
  if s.worker == nil then
    local nNext = NextRunnableJob()
    if nNext ~= nil then
      s.worker = coroutine.create(table.remove(s.tJobs, nNext).fn)
    end
  end
  if s.worker ~= nil then
    local bOk, sError = coroutine.resume(s.worker)
    if not bOk then
      Bridge.Log("build sync: job failed: " .. tostring(sError))
      if Bridge.IsApplying() then
        Bridge.EndApply()
      end
      if (s.nTutorialSuspended or 0) > 0 then
        s.nTutorialSuspended = 1
        RestoreTutorialRestriction(true)
      end
      s.worker = nil
    elseif coroutine.status(s.worker) == "dead" then
      s.worker = nil
    end
  end
  if Bridge.IsApplying() then
    return
  end

  -- Commit messages can land after the commit token completes; they settle on their own.
  local bSettled = #s.tTouched > 0 or #s.tRemoteTouched > 0
  for i = #s.tCommitTokens, 1, -1 do
    if s.rawUndo.IsOperationComplete(s.tCommitTokens[i]) then
      table.remove(s.tCommitTokens, i)
      bSettled = true
    end
  end
  if s.nUndoRedoTimer ~= nil then
    s.nUndoRedoTimer = s.nUndoRedoTimer - _nDeltaTime
    if s.nUndoRedoTimer <= 0 then
      s.nUndoRedoTimer = nil
      s.bUndoSettle = true
      bSettled = true
    end
  end
  if bSettled then
    ProcessSettled(_bSending)
  end
end
