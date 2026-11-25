# Planet Zoo 2 Lua API Map (`docs/LUA_API_MAP.md`)

Every name below was harvested from the decompiled game scripts, not guessed. Paths are relative to
`decompiled_lua/vanilla/`. Module `Foo.BarBaz` lives in file `<archive>/Main/foo.barbaz.lua` (luadec lowercases names).

## 0. Provenance & confidence

| Item | Value |
| :--- | :--- |
| Source archives | `Win64/ovldata/GameMain/Main.ovl` (245 Lua), `Win64/ovldata/Content0/Main.ovl` (871 Lua) |
| Bytecode | Frontier Lua 5.3 (`1B 4C 75 61 53 02`; format byte `02` is non-standard, plus `<x, y, z>` vec3 literals) |
| Decompiler | cobra-tools' bundled `luadec.exe -s` (stock unluac not tested; luadec without `-s` segfaults) |
| Coverage | 1091 / 1116 decompiled. 25 failures, all `peep*` guest-appearance modules (irrelevant to sync) |
| Quality | ~630 files contain partial `DECOMPILER ERROR` blocks. Names, strings, call sites are reliable; control flow is not |
| UI layer | `GameMain/Content/UserInterfaceEssentials.ovl` holds a single `.ppuipkg`. **No HTML/JS has been extracted** (cobra-tools has no loader for it) |

Regenerate: `python tools/extract_all_lua.py` (all steps) or `--skip-extract` (decompile only).

"Verified" = seen at a real call site. "Unverified" = name/shape known, runtime behaviour not yet observed in-game.

## 1. How a mod gets its Lua loaded (injection points)

### 1.1 Content-pack database discovery — `GameMain/Main/database.main.lua`
```lua
-- Main.InitContentToCall (line ~54)
local tLoadedPackNames = api.content.GetLoadedContentPackDebugNames()
for each sPackName:
    local database = tryrequire("Database." .. sPackName .. "LuaDatabase")
    if database ~= nil and database.AddContentToCall ~= nil then
        database.AddContentToCall(tContentToCall)
```
A mod ships a content pack whose Lua contains `Database.<PackName>LuaDatabase` with `AddContentToCall(t)`.
Vanilla example: `Content0/Main/database.content0luadatabase.lua` inserts `require("Database.C0ParkData")` etc.

Each inserted module may implement any of these hooks, dispatched via `Main.CallOnContent(sMethod, ...)`:
`Init`, `Setup`, `Shutdown`, `ShutdownForReInit`, `AddDatabaseFunctions`, `AddPlayer`, `AddPlayerMethods`,
`LoadPlayer`, `SavePlayer`, `RemovePlayer`, `AddGameModeData`, `AddGameDifficultyData`, `AddParkSettingData`,
`AddLevelTransitions`, `AddHeadlessLevelTransitions`, `AddCareerData`, `AddClimateData`, `AddBiomeData`,
`AddCommsData`, `AddMarketingData`, `AddButtonPromptData`, `AddEntitlementUnlockData`, `AddEntitlementRewardItems`,
`AddGlobeAreaPinData`, `AddWeatherLookData`, `AddUpdateFanfareData`, `AddTutorialHelpComms`,
`AddTerrainMaterialToIconData`, `AddStaffSettingNames`.

There is **no** manager-registration hook; use 1.2.

### 1.2 Adding a world manager — `Content0/Main/environments.darwinenvironment.lua`
The park world's environment is a prototype table:
```lua
local Module = module(..., Mutators.EnvironmentPrototype)
Module.EnvironmentPrototype = { SearchPaths = {"Managers"}, Managers = {
    ["Managers.CashSpentPopupManager"] = {}, ["Managers.ScenarioManager"] = {}, ... } }
```
Vanilla precedent for mutating it at runtime (`environments.startscreenenvironment.lua:32`):
```lua
Module.EnvironmentPrototype.Managers["Managers.AssetsShowroomDebugManager"] = {}
```
→ Mod plan: from the LuaDatabase `Init`/`Setup`, do
`require("Environments.DarwinEnvironment").EnvironmentPrototype.Managers["Managers.PZ2CoopManager"] = {}`
(unverified that this runs before the park environment instantiates its managers; check in-game).

Environment API (`GameMain/Main/environment.environment.lua`): `RequireManager(name)`, `RequestManager(name)`,
`RequireInterface("Interfaces.IX")`, `RequestInterface(...)`.

### 1.3 Manager lifecycle (verified on `managers.cashspentpopupmanager.lua`, `managers.guestcounthistorymanager.lua`)
| Method | Signature |
| :--- | :--- |
| `Init` | `(self, _tProperties, _tEnvironment)` |
| `Advance` | `(self, _nDeltaTime)` — per-frame, main thread |
| `Shutdown` | `(self)` |
| `Activate` / `Deactivate` | `(self)` |
| `WorldSave` / `WorldLoad` | `(self, _tSave)` / `(self, _tLoad, _nLoadedVersion)` |
| `ParkReset` | `(self)` |
| `OnHUDUIReady` | `(self, _uiHUD)` |

### 1.4 Native API wrapping (ACSE pattern) — `GameMain/Main/api.game.lua`
The game itself replaces native tables with metatable proxies, falling back to the raw table:
```lua
local raw = api.game
api.game = setmetatable({ GetEnvironment = function(...) return self:Api_GetEnvironment(raw, ...) end, ... },
                        {__index = raw})
-- Shutdown restores: api.game = getmetatable(api.game).__index
```
Same mechanism is used for `api.gamesave`, `api.gamedatastore`, `api.debug`, `api.gametelemetry` (`GameMain/Main/api.*.lua`).
→ This is how the mod should hook `api.undo` (section 4) without touching vanilla files.

## 2. Reaching game systems

| Accessor | Returns | Uses |
| :--- | :--- | :--- |
| `api.world.GetWorldAPIs()` | table of per-world native APIs (`tWorldAPIs.money`, `.park`, `.animals`, …) | 274 files |
| `api.game.GetEnvironment()` | current environment (see 1.2) | 81 files |
| `api.world.GetActive()` / `api.world.GetScript(world)` | active world + its script | 156 / 163 files |

World APIs by frequency of use: `animals, staff, park, exhibits, habitat, scenery, transform, animalsDataHelpers,
guests, facilities, scenery_puppets, gameaudio, editors, rides, education, tours, model, money, habitatboundary,
gameterrain, placement, franchise, voxelterrain, worldserialisation, billboardwidgets, camera, wildterritory,
scenery_group, complex, research, …`

Global `api.*` namespaces: `debug, world, ui2, database, messaging, entity, undo, track, planetHub, usercontent, game,
save, player, uioptions, time, render, input, debugui, content, task, online, localisation, audio, telemetry,
gamedatastore, physics, gamevolatileconfig, cursor, json, componentmanager, movie, crowdsimulation, random,
xmlconfig, globe, steam, presence, gamenet, multipart2, lighting, math, playeravatar, vipguests`.

## 3. Game-mode gating (CLAUDE.md rule 6) — `Content0/Main/managers.scenariomanager.lua`
```lua
local scenarioManager = api.game.GetEnvironment():RequireInterface("Interfaces.IScenarioManager")
scenarioManager:GetGameMode()      -- "Sandbox" | "Challenge" | "Franchise" (field self.sGameMode, line 310)
scenarioManager:IsSandboxMode()    -- sGameMode == "Sandbox"
scenarioManager:IsChallengeMode()  -- sGameMode == "Challenge"
scenarioManager:IsFranchiseMode()  -- sGameMode == "Franchise"   ← disable all sync when true
```
Secondary signal: `tWorldAPIs.franchise:GetPlanetHubType()` vs `franchise.PlanetHubType_None` /
`franchise.PlanetHubType_FranchiseOnline`.

## 4. Build actions — the undo pipeline (`api.undo`)

Every Lua-driven editor commits through the same sequence
(`Content0/Main/editors.shared.singlefeatureundoableplacementmodebase.lua:60-85, 1125-1200, 1650-1671`):
```lua
local hierarchy = tWorldAPIs.editors:CreateUndoOperationsHierarchy()
-- ... fill: hierarchy:CreateCompositeObject({}), :AddBlueprintToCompositeObject(obj),
--           :AddPartsToCompositeObject(...), :GetTerrainEditOperation(), :AddCashDelta(...), :SetCashPos(...)
local waitToken, previewToken = api.undo.PreviewChangeList(hierarchy:GetFullUndoChangeList())
-- poll api.undo.IsOperationComplete(waitToken)
if api.undo.CanCommitPreview(previewToken) then
    WaitFor(api.undo.CommitPreview(previewToken))
else
    WaitFor(api.undo.CancelPreview(previewToken))
end
api.undo.Checkpoint({sMode = self._NAME})
```
Full `api.undo` surface: `PreviewChangeList, IsPreviewingChangeList, CanCommitPreview, CanCommitPreviewApprox,
CommitPreview, CancelPreview, GetCommitFailReasons, IsOnlyTooExpensiveReason, IsOperationComplete, IsBusy,
Checkpoint, GetCheckpointData, GetUndoneCheckpointData, GetMostRecentOperation, Undo, Redo, CanUndo, CanRedo,
ClearHistory`.

Operation-hierarchy methods seen: `CreateCompositeObject, AddBlueprintToCompositeObject, AddPartsToCompositeObject,
AddVolumeChunkToCompositeObject, GetTerrainEditOperation, GetFullUndoChangeList, AddCashDelta, SetCashPos,
BeginVolumeModificationsBlock, EndVolumeModificationsBlock, SetPerformTerrainModificationsModifyVolumes,
SetCanCommitResultModifyVolumes, SetErrorOnPathMergeUnchangedModifyVolumes, SetMagicModeModifyVolumes,
CreateTerrainShapeStamp, ModifyParkZoneShape, DestroyParkZone, RemoveVolume, IsLoadedBlueprintReadyForEditing,
GetLoadedBlueprintLakeCount, CreateAdditionalPostOpChangelists, CreateDioramaTerrain`.

**Sync implication:** the changelist is opaque native userdata — it cannot be serialised. Hooking
`api.undo.CommitPreview` (via 1.4) gives a reliable *"something was committed, and by whom"* signal, but the payload
must be reconstructed per editor (blueprint file, spatial key, terrain parameters). Undo cost is paid via
`AddCashDelta`, so replayed builds will charge the client → host ledger overwrite (section 7) is required.

Editors that commit through `api.undo` (21 files): `components.ui.selectandeditcomponent`, `editors.diorama.dioramaeditmode`,
`editors.blueprint.blueprintplacementmode`, `editors.scenery.submodeplacement`, `editors.scenery.submodeonterrainplacement`,
`editors.scenery.brushplacement`, `editors.flatride.*`, `editors.track.trackeditselection`, `editors.volume.*`,
`editors.terrain.terraineditmode`, `editors.park.parkzone.parkzoneeditmode`, `editors.animal.releasetowilduimode`,
`components.ui.staffinfopopup`, …

### 4.1 Paths — mostly native ⚠
`Content0/Main/editors.path.pathedituimode.lua` (1663 lines) only drives UI data-store fields
(`api.ui2.SetDataStoreElement`, `volumesAPI:GetOutlineGroup`); **no `api.undo` commit happens in Lua**. Path tool
parameter replay (ARCHITECTURE.md §3.D) is therefore not possible from Lua as-is. Candidates: observe
`MsgType_UndoRedoCompletedMessage` + `api.undo.GetMostRecentOperation()` and diff, or sync paths via blueprint
selection. Needs in-game investigation.

### 4.2 Terrain — `editors.terrain.terraineditmode.lua` (3907 lines), `editors.terrain.terrainshapestampmode.lua`, `terrainheightstampmode.lua`
Uses `gameterrain:SetTerrainEditOpAssociatedLake`, `SetTerrainEditOpCollisionFlags`, `FindLakesWithSphereCheck`,
`sceneryTerrainAPI:SetTerrainStampShape`, and `api.undo.GetCheckpointData / GetUndoneCheckpointData /
GetMostRecentOperation`. Brush strokes run inside native terrain edit operations; capture point is the editor's
commit path (needs per-stroke parameter capture).

### 4.3 Demolish — `editors.demolish.demolisheditmode.lua`
Selection is UI/data-store driven (`api.ui2.*DataStoreElementByID`); deletion commit path to be traced in-game.

## 5. Blueprint / clipboard sync — verified viable

`GameMain/Main/managers.parkloadsavemanager.lua`:
| Method | Line | Notes |
| :--- | :--- | :--- |
| `SaveBlueprintToFile(self, _sFileName, _selection, _bCompressed)` | 468 | → `worldserialisation:RequestSaveBlueprintToFile`; yields until `HasSaveToFileCompleted()`; call from a coroutine |
| `LoadBlueprintFromFile(self, _sFileName, _fnOnCompletion)` | 605 | checks `worldserialisation:IsValidBlueprintFile` then `LoadBlueprintFromFile` |
| `SaveBlueprintToSaveToken(...)` / `LoadBlueprintFromSaveToken(cSaveToken)` | 532 / 646 | Steam-save-slot variants |

Reference implementation that saves a live selection to a file: `Content0/Main/managers.blueprintdebugsavemanager.lua:525-560`
(`parkLoadSaveManager:SaveBlueprintToFile(sFullPath, tBlueprintData.saveSelection, true)`).
Placement of a loaded blueprint: `editors.blueprint.blueprintplacementmode.lua:209`
(`hierarchy:CreateCompositeObject({})` + `hierarchy:AddBlueprintToCompositeObject(obj)`).
Group helpers: `tWorldAPIs.scenery_group:TryGetBuildingGroupForPart`, `GetGroupMembers`, `CalculateBuildingGroupAABB`;
`tWorldAPIs.scenery:GetSceneryGroupBlueprintData(nBuildingID)` → `(nBlueprintID, nVersion, loadedTransform)`.

→ Plan: on local commit, save the affected group to `PZ2Coop_clip_<seq>.bin`, stream it on Channel 0
(`ACTION_PLACE_OBJECT`, chunked), peer loads it and places it at the transmitted transform.

### 5.1 What a blueprint selection can hold — `Content0/Main/helpers.blueprintsavehelper.lua` (decompiled, 2026-11-12)
- Building groups: `sceneryAPI:AddGroupToBlueprintSelection(nGroupID, sel[, bHabitat])` (verified in retail)
- Standalone scenery: `sceneryAPI:AddSceneryToBlueprintSelection(nPartID, sel)`
- Rides / path volume chunks: `sel:AddEntityID(nEntityID)` (`tPathVolumeChunks`)
- Habitats incl. roof, barrier props and contents: `BlueprintSaveHelper.AddHabitatToSaveSelection(sel, nHabitatEntityID)`
  (`habitatboundary:GetRoof`, `GetBoundaryObjectsForHabitat(habitatID).tAttachableProps`,
  `habitat:GetHabitatContentsForBlueprint` -> scenery, groups, volume chunks)
- Habitat enumeration: `facilities:GetAllHabitatsEntityIDs()`. Habitat change message:
  `MsgType_HabitatBoundaryUpdatedMessage` -> `tMessage.nHabitatEntityID` (objectives.objectivehabitatcreation.lua:146).
- `MsgType_SpatialVolumeChangedMessage` carries `tMessage.sType` (e.g. `"VoxelTerrain"`, cameramodemanager.lua:851).
- Single-part delete: `NonYielding_AddPartToDestroyIntoCompositeObject(clh, composite, partID)` +
  `Yielding_DestroyCompositeContents(tWorldAPIs, clh, composite)` (components.ui.exhibitinfopopup.lua:1818).
- Tool changes: `BaseEditMode.SetNewMode` / `BaseUIMode.SetNewMode` (looked up on every call by vanilla).
Retail status of everything in 5.1 except the group call: unverified until the mega test (docs/MEGA_TEST.md).

### 5.2 Paths and fences in an area (decompiled 2026-11-12; used by pz2coop.regionsync.lua, retail unverified)
- World-space queries: `tWorldAPIs.spatial:CylinderQuery(vBottom, vTop, radius, flags, 0, maxCount)`,
  `:SphereQuery`, `:CapsuleQuery`, `:RayQuery(vStart, vDir, flags)` -> entity IDs; `:GetShapeAABB(e)` -> vMin, vMax;
  `:GetFlagsFromEntityID(e)`. Flags: `Flag_Path, Flag_HabitatBoundary, Flag_Habitat, Flag_Scenery, Flag_Exhibit, ...`.
  (The multi-select box/cylinder selections are screen-space, not usable for world areas.)
- Demolish brush filter (editors.demolish.demolisheditmode.lua:886-960): resolve parent
  (`PlayerInteractionHandler:HasParentEntityID/GetParentID`, `transform:GetParent`), path chunk =
  `volumes:GetVolumeIDFromEntityID(e,false,false)` and not `IsPool(id)` and `IsEditableChunk(e)`;
  fence piece = `habitatboundary:GetBoundaryObjectFromEntity(e)` -> bHit, oPanel, oPost, oProp, oPillar, nRoof.
- Path delete: multi-selection (`editors:CreateMultiSelection()`, `SetCanSelectPathVolumeChunks(true)`, `AddEntity`)
  -> `SceneryUtils.StartDeletePathVolumeChunks(clh, composite, ms, tWorldAPIs)` + `composite:Destroy()`.
  Path save: `saveSelection:AddEntityID(chunk)` (blueprint saver).
- Fence graph: `oPost/oPanel:GetAllData()` (posts: vPos, nWorldHeight, sBoundaryType, nEntityID...; panels:
  oStartControlPost, oEndControlPost, vBasePosStart/End, vDirStart/End, nWorldHeightStart/End, nPanelMode,
  tSegmentData...), `habitatboundary:GetPanelsConnectedToControlPost(oPost)`, `GetHabitatsFromBoundaryObject`.
  Build: `CreateNewControlPost()` / `CreateNewPanel()` + `:FillData(t)` + `cl:AddControlPost/AddPanel`
  (`cl = clh:GetHabitatBoundaryChangeList()`); remove: `habitatboundary:DeleteMultiSelection(sel, {oHabitatBoundaryChangeList, sBoundaryType})`.
  Change list: `SetBoundaryEditPreviewModeModifyVolumes(true)`, `SetPerformTerrainModificationsModifyVolumes(false)`,
  terrain-op collision flags, volume block, `RefreshAdjacentPosts()`; before commit `AddCashDeltaOperation(cl,false)`
  + `SetPerformTerrainModificationsModifyVolumes(true)` (HabitatBoundaryEditMode.TryCommit).
- Water: `gameterrain:FindLakesWithSphereCheck(pos, r)`, `CreateLakeRemoveOperation(lake)`.
- Placement change-list prep (SingleFeatureUndoablePlacementModeBase.PreviewAddNew): `SetPerformTerrainModificationsModifyVolumes`,
  `gameterrain:SetTerrainEditOpCollisionFlags(op, true,false,false,true,true, CheckLakesMode_WhenTerrainCollisionEnabled, false)`.
- `HabitatBoundaryEditMode` caches `UndoAPI` at load, so its commits bypass the `api.undo` proxy (no commit token).
- **Verified in retail (2026-11-12):** `SpatialVolumeChanged` "SpatialDatabase" messages carry `nFlags` using the
  same bits as `spatial.Flag_*` (Flag_Path = 1, Flag_HabitatBoundary = 524288); CylinderQuery returns hits for
  both. New fence pieces need `tFlexiColours` (GetAllData does not return it).

## 6. Save handshake (ARCHITECTURE.md §3.A) — verified viable

| Method (`ParkLoadSaveManager`) | Line | Notes |
| :--- | :--- | :--- |
| `SaveParkToFile(self, _sFileName, _bInitialState, _bCompressed)` | 416 | appends `.bin`; `worldserialisation:RequestSaveWorldToFile`; coroutine, yields until done |
| `RequestLoadParkFromFile(self, _sFileName, _bExportToSandbox, _sWorldName, _sCreatorName, _sParkName)` | 565 | validates via `worldserialisation:IsValidZooFile`, then `api.game.RequestTransition(world)` |

Manager access: `api.game.GetEnvironment():RequireInterface("Interfaces.IParkLoadSaveManager")` (23 call sites).
Neither method is gated on `api.debug.IsDebugAllowed()` in the decompiled source (still verify in retail).
Steam-slot API (`api.save.*`, 37 functions) incl. `RequestSave`, `RequestLoad`, `RequestAutosave`, `GetSaveMetadata`.

## 7. Economy (CLAUDE.md rule 5) — `tWorldAPIs.money`

| Function | Verified signature / use |
| :--- | :--- |
| `money:GetCash()` | `worlds.darwinworld`, `components.objectivemanager` |
| `money:GetConservationCredits()` | `worlds.darwinworld` |
| `money:ModifyCash(nDelta, park.ExpenditureCategory_X, bOptional)` | `components.challengemanager`: `ModifyCash(reward, park.ExpenditureCategory_Rewards)` |
| `money:CanModifyCash(nDelta)` | staff rehire paths |
| `money:HasUnlimitedCash()` / `SetUnlimitedCash(...)` / `SetUnlimitedCCs(...)` | `helpers.parksettingsdata` |
| others | `GetHUDData, GetSummaryForPeriod, GetSummaryForLastNQuarters, GetLifetimeSummary, GetActiveLoansList, TakeLoanOffer, RepayLoan, …` |

**There is no `SetCash`.** The host-ledger overwrite must be applied as a delta on the client:
`money:ModifyCash(hostCash - money:GetCash(), <category>)`. No CC setter was found; CC drift handling is still open.
`LedgerSyncPayload.cash_cents` assumes cents; check whether `GetCash()` returns whole units.

## 8. Animals — `tWorldAPIs.animals` / `tWorldAPIs.exhibits`
Actions seen: `animals:AttemptToSendToTradeCentre`, `animals:RemoveAnimal`, `animals:CanSellAnimal`,
`animals:SetUsingContraceptive`, `animals:GetAnimalsOfSpecies`, `animals:GetCurrentLocationEntity`,
`exhibits:AddAnimalToExhibit`, `exhibits:AddColonyAnimalToExhibit`, `exhibits:AttemptToSendToTradeCentre`,
`exhibits:SetExhibitAnimalUsingContraceptiveUsingUID`, `exhibits:RequestExhibitAnimalSpawnerPreviewSpawn`.
Market purchase is not called from Lua directly; it surfaces as `MsgType_AnimalPurchasedMessage`.

## 9. Events / messaging — `api.messaging`
`RegisterReceiver(msgType, fn)`, `UnregisterReceiver`, `RegisterGlobalReceiver`, `UnregisterGlobalReceiver`,
`SubmitMessage`, `SubmitGlobalMessage`. Receivers get a batched `_tMessages` table (fields not read by vanilla
code → **inspect at runtime**). Sync-relevant types:
`MsgType_PlacementPartCommittedMessage`, `MsgType_UndoRedoCompletedMessage`, `MsgType_AnimalPurchasedMessage`,
`MsgType_AnimalBornMessage`, `MsgType_AnimalDiedMessage`, `MsgType_ExhibitAnimalAddedMessage`,
`MsgType_ExhibitAnimalRemovedMessage`, `MsgType_AnimalAssignedHabitatChangedMessage`,
`MsgType_PlayerBlueprintSavedDeletedMessage`, `MsgType_PlayerParkSavedDeletedMessage`, `MsgType_ParkTimeRegularMessage`.

## 10a. Verified in the retail game (2026-11-06, version.dll diag.log)

| Finding | Evidence |
| :--- | :--- |
| A mod content pack loads from `Win64/ovldata/<Name>/` (`Manifest.xml` + `Main.ovl`, cobra-tools "Planet Coaster 2" preset, plain-text Lua) | exe opens our Manifest + main.ovl; our `require` / `AddContentToCall` / `Init` all run |
| `api.debug.ReadStringFromFile` / `WriteStringToFile` exist but are **stubbed**: return false, never touch the disk, for every root | runtime probe + CreateFileW hook |
| Lua HTTP is stubbed (`"Error: endpoint not yet implemented"` in `helpers.webavatar.lua`, `zoopediauimode.lua`) | decompiled source |
| Gameface inspector needs an `HttpServer` library the game doesn't ship | cohtml 2.2.6.2 disassembly |
| `Environments.StartScreenEnvironment` is never instantiated; only `DarwinEnvironment` (park) hosts managers | no `CreateEnvironment` call references it |
| `api.task.Spawn` tasks started from database `Init` never tick | 60-frame marker never appeared |
| Per-frame hook that works everywhere (menu included): wrap `require("Game.GameScript").OnAdvance` (BaseGame.Advance calls `self:OnAdvance` every frame; instances resolve through the class) | pump marker + bridge traffic |
| **UI injection works:** a content-pack UI overlay (`<pack>/UI/X.ovl` holding a `.ppuipkg` with `UIGameface/...` files) loaded via `api.ui2.LoadOverlay(name, "<pack>/UI/X")` → `IsOverlayLoaded` → `MapResources(name)` from the boot pump **shadows** vanilla files at the same path (patched `PauseMenu.js` rendered) and serves new paths | 2026-11-11 probe: extra Esc-menu button visible, vanilla buttons fine |
| Gameface `'ui'` data store accepts custom keys from Lua (`api.ui2.SetDataStoreElement(GetDataStoreContext("ui"), key, v)`); JS reads them with `DS.getValue(UI_CONTEXT, key)` / `bindDSPropsToState` | probe button label |
| Esc-menu JS → Lua: `sendEvent('PauseMenu_UI_Select', id)` reaches `MainHUD.OnPauseMenuUISelect`, wrappable on the `Windows.MainHUD` module table before the HUD is created | `pause menu select pz2coop_test` in diag.log |
| Game re-runs module files during boot (package cache resets): per-module state must live in `_G` | overlay load / hook install logged ~40× in the first second |
| Frontier Lua TValue is **24 bytes** (stock 5.3: 16); integers, `//`, `%`, wrap-around multiply behave as stock 5.3 | mem bridge discovery + codec self-test |

**Working transport:** a Lua integer table used as shared memory (`src/proxy_dll/mem_bridge.hpp`,
`src/ovl_mod/pz2coop.bridge.lua`). Lua→DLL logging lands in `<game>/PZ2Coop/diag.log` as `lua: ...`.

## 10. Lua ⇄ outside world (IPC bridge) — original analysis (superseded by 10a)

| Channel | Status |
| :--- | :--- |
| `api.debug.WriteStringToFile(sData, sPath)` / `api.debug.ReadStringFromFile(sPath)` | **Available** (10 / 3 call sites incl. non-debug `editors.track.trackeditselection`). Retail behaviour unverified |
| `api.debug.GetFilesOfType`, `api.debug.GetMostRecentlyModifiedFile` | available |
| `api.json.Stringify(t[, bPretty])` → `(bOK, sJson)`, `api.json.Parse(s)`, `api.json.GetArrayMetatable()` | available |
| UI (Gameface) events: `api.ui2.RequestTriggerEvent`, `TriggerEventAtNextAdvance`, `RegisterForEvent`, `RequestRegisterForEvent(Global)` (`GameMain/Main/ui2.viewwrapper.lua`) | available, but the JS side lives in the unextracted `.ppuipkg` |

The WebSocket bridge (ARCHITECTURE.md §2.1) needs JS running inside the Gameface view. **No route to inject JS
has been found yet** (`.ppuipkg` cannot be unpacked by cobra-tools). The file bridge (§2.2) is the only path confirmed
by the decompiled code and is what `src/ovl_mod` uses: `version.dll` serves it from `<game exe dir>/PZ2Coop/`
(protocol in `src/proxy_dll/file_bridge.hpp`). Session control is via DLL hotkeys (Ctrl+Shift+H/J/L) until a UI exists.

Unverified until the first in-game run: which virtual prefix `api.debug` file paths resolve against (the Lua side
probes several for the DLL's `bridge.txt` beacon), and whether `SaveParkToFile` / `LoadBlueprintFromFile` use the
same root.

## 11. Other useful verified APIs
- `api.time`: `GetDeltaTime`, `GetDeltaTimeUnscaled`, `GetTotalTimeUnscaled`, `Pause`, `Unpause`, `SetTimeScaler`, `AcquireTimeScaler`.
- `api.game`: `GetEnvironment`, `RequestTransition(sWorld)`, `RequestReturnToStart`, `HasCommandLineArgument`, `GetVersionString`.
- `api.player`: `GetGameOwner`, `RegisterGameOwnerChangeCallback`, `RegisterPlayerChangeCallback`.
- `api.debug`: `Trace`, `WriteLine`, `Warning`, `Error`, `Assert`, `IsDebugAllowed`.
- `tWorldAPIs.worldserialisation`: `RegisterWorldSerialisationClient`, `SavePlacementPartID`, `LoadPlacementPartID`, `SaveEntityID`, `LoadEntityID`.
- `api.steam`: only `IsAvailable`, `IsInBigPictureMode`, `IsOnSteamDeck` (no networking exposed to Lua).

## 12. Camera, walk mode, spawned markers (decompiled 2026-11-25; used by pz2coop.presence.lua, retail unverified)
`V` = `decompiled_lua/vanilla/Content0/Main/`.
- Walk mode is camera mode `"Walking"` (`V/components.cameras.walkingcamera.lua`), first person only, no body.
  Enter: `tWorldAPIs.CameraModeManager:RequestMode("Walking", {vStartingPos = <eye pos>, vStartingYPR = Vector3(yaw,0,0)})`
  (`cameramodemanager.lua:1168-1184`; start pos = ground + `WalkingCamera.GetDefaultWalkingHeight()` (1.55 m), `walkingcamera.lua:337-382`).
  UI mode `"WalkingCamera"` (`V/editors.cameras.walkingcamerauimode.lua`) is the native explore on foot (prompt bar,
  F photo, E buggy, compass; camera params `bIsWildArea = true, bWalkingRotateLock = true`). Vanilla opens it only from
  the research outpost; the camera panel Explore button goes `WalkingCameraInit` -> `TryRequestWalkingMode` -> UI `"Select"`.
  All zoo walk requests (Explore button `walkingcamerainituimode.lua:95`, `GameCamera_WalkingCam` hotkey `:452`, shell
  `:224`) call `CameraModeManager.TryRequestWalkingMode`; start pos = `WalkingCamera.GetStartingPos(tData.tModeData, tWorldAPIs)`.
  Current UI mode: `tWorldAPIs.ModeHelperComponent:GetCurrentModeName(BaseUIMode.GetModeHelperEntity())`.
- Research vehicle third person (vanilla): `Editors.Vehicle.DriveVehicleUIMode`, key `GameCamera_ToggleThirdPerson` (C)
  -> `self:SwitchCamera(b)` (sets `self.bThirdPersonCamera`); `TransitionIn` ends with
  `self:SwitchCamera(_tParams.bThirdPersonCamera)`. Camera sweep: `tWorldAPIs.voxelterrain:SphereSweep(
  CameraModeManager:GetVoxelTerrainID(), vStart, vDir, nLen, nRadius)` -> hit distance or nil (`thirdpersonvehiclecamera.lua:390-404`).
- Prompt bar: `GameDatabase.GetButtonPromptData("Empty").WalkingCamera.tMouse/tGamepad` (live table, read on each refresh,
  `managers.buttonpromptsmanager.lua:327`); entries `{sLocString, sLogicalControl, sLocation = "HUD_CenterPrompts"}`.
  Vanilla switch camera entry: `HUD_Controls_SwitchCamera` / `GameCamera_ToggleThirdPerson` (`database.c0buttonprompts.lua:1213`).
- Player avatar look: `GameDatabase.GetPlayer(GameDatabase.GetPlayerKey(api.player.GetGameOwner())):GetMainAvatarData()`
  -> `StartScreenAvatar.AvatarVersionCheck(tSaved.tData)` -> `api.multipart2.GetProperties(tAvatar)` -> `sPrefab, tProps`
  (start screen appends `"_StartScreen"` for its motion-graph prefab, `startscreen.shared.startscreenavatar.lua:142`).
  `sPrefab` is `"Peep_Avatar"`; spawning it bare in a park crashes the game (tested 2026-11-25).
- Avatar body in a park (the vehicle driver recipe): `StartScreenAvatar:new():Create(tAvatar, nParentID, sType, "Static")`
  (`editors.vehicle.drivevehicleuimode.lua:SwitchCamera`). Spawns `"Peep_Avatar_StartScreen"` with `MotionGraphName`,
  `AvatarType`, `AudioAvatar/IsPlayer` props as child of the parent; yields while loading (run it in a coroutine);
  `oAvatar.nAnimatedEntityID` = the avatar; destroy its `"Lights"` child. Motion graph layer `"Guest"`,
  `motiongraph:EnqueueLoopAction(id, "Guest", state)` with start-screen states only (`Static` etc., startscreenentity.lua:19).
- Mouse wheel: `tWorldAPIs.InputManager:GetMouseInput().RawZAxis` (`cameralogic.lua:500`); native explore on foot
  passes `bMagnifyEnabled = false`, so the walking camera ignores the wheel there.
- Avatar motion graph (`<group>.motiongraph`, vars `avatarguestbase.motiongraphvars`, both in
  `Content0/Worlds/StartScreenGlobeWorld/StartScreenGlobeWorld.ovl`): clips `TM$Appear_Low`, `CheckClothes`,
  `Clicked`, `Disappear`, `DriveBuggySteerLeft/Right/Straight`, `MouseOver_Smile/Wave`, `New_*`, `PeekAtUI_*`,
  `StandBaseIdle01/02`; no locomotion. Prefab `PeepBase_StartScreen` has `Animation` (`AnimName` = `DefaultAnimName`
  property) and `MotionGraph` components and loads package `Guests` (where `<group>$WalkBase/RunBase` live).
- Guest prefab: `api.multipart2.GenerateRandom(sGroup, variant)` returns a prefab name that varies (`"Peep"`,
  `"Peep_Acc"`, ...) plus `tProps` (55-69 props, `DefaultAnimName` `"AF$StandBaseIdle01"`). Spawning ANY of them with
  `InstantiatePrefab` in a park crashes the game (`PlanetZoo2.exe+0xb9af7b2`, 2026-11-25). `"Peep_" .. sGroup`
  (helpers.trackedrideutils.lua, Planet Zoo 1 leftover) does not exist: the request completes and no entity appears.
- Guest animation clips (`Content0/Characters/Guests/Guests.ovl`, 1,385 baked `.bani` files): `<group>$StandBaseIdle01` (`02`/`03`), `$WalkBase`, `$JogBase`, `$RunBase` for groups `AF`, `AM`, `TF`, `TM` (plus `CF`/`CM`; no crouch clip). All locomotion clips are in-place (zero root drift).
- **Verified runtime animation APIs (2026-11-25, live-verified in retail `PlanetZoo2.exe`, lazily bound so invisible to `pairs()`):**
  - Global `api.animationcontrol` (dot syntax, drives `AnimationControl` + `BakedAnimation` components):
    `SetBaseAnimation(nEntityID, sClipName[, nPlaybackRate=1.0, bWaitForCurrent=false, nBlendTime=0.0, bSkipIfPlaying=true])` (passing `nBlendTime > 0` activates native `BakedAnimation` hardware crossfade blending), `SetPlaybackRate(nEntityID, nRate)`,
    `IsRequestedBaseAnimationPlayingNow(nEntityID)`, `QueueOneShotAnimation`, `StopAnimation`,
    `ForceStopOneShot`, `ClearOneShotQueue`, `ClearOneShotQueueAndForceStopOneShot`.
  - World `tWorldAPIs.bakedanimation` (colon syntax): `RequestAllBonesForCalculate(nEntityID)`, `GetFloatStreamValue(nEntityID, sName)`.
  - World `tWorldAPIs.animation` (colon syntax, drives skeletal `.mani` `Animation` component): `PlayAnimation`, `SetPlaybackRate`, `SetPlaybackDirection`, `SetPropThrough`, `GetPropThrough`, `GetLength`, `GetFloatStreamValue`.
  - Clean animated avatar recipe (`src/ovl_mod/pz2coop.avatar.lua`): spawn a Lua root table with `Transform`, `AssetPackageLoader({PackageNames = {"CharacterPatterns", "Guests"}})`, `AssetPackageProvider`, `ModelSkeleton`, `BakedAnimation`, `AnimationControl`, `LevelOfDetail`, `RenderBoundingVolume`, `RenderGroup` (omitting crowd components `GuestVisual`/`GuestAnimation`/`BakedAnimTree` that crash outside the crowd sim, and omitting `MotionGraph`), then attach each multipart part (`Head`, `Hair`, `Torso`, `Legs`, optional `Accessory`/`Beard`) using vanilla `"PeepBodyPart"` with `BoundingScaler` and props from `api.multipart2.GetProperties(tAvatar)`. Switch clips at runtime via `api.animationcontrol.SetBaseAnimation(nAvatarID, "<G>$WalkBase")`.
- Staff skeletal `.mani` animations (`Content0/Characters/Staff/<Role>/<Role>.ovl`, `AF`/`AM` only — no Teen `TF`/`TM`): `<Role><AF|AM>$StandIdleContent01`, `Walk*OnSpot`, `RunOnSpot`, plus `WildLifeResearcher` crouch/prone/camera/binoculars and `Diver` swim clips. Share core `def_c_*`/`def_l_*`/`def_r_*` bones with avatars.
- Own pose: `CameraModeManager:GetPosYPRZoom()` -> `vPos, vYPR, nZoom` (yaw = `vYPR:X()`), `GetCurrentModeName()`,
  `GetCameraDataFinal()` -> `tFinal` (`vCentrePos` = orbit centre) (`cameramodemanager.lua:588,725-758`).
- Yaw/pitch convention (`components.cameras.camerautils.lua:39-44`): yaw = atan(x, z), pitch = -atan(y, horizontal);
  forward = (sin yaw cos pitch, -sin pitch, cos yaw cos pitch).
- Per frame `CameraModeManager.Advance` calls `tModeAPIs[mode].Advance` (the mode's module table, looked up each frame,
  `:414`), then writes `tModeData.tFinal.transformQ` to the main camera (`:424-426`). `CameraLogic.ApplyFinal` rebuilds
  `transformQ` from `vCameraPos` + `vCameraYPR` (`cameralogic.lua:1132-1147`), so replacing only `transformQ` after
  `WalkingCamera.Advance` moves the view without touching walking/collision state.
- Markers without the change list: `api.entity.InstantiatePrefab(sPrefab, sName, token, transformQ, parent, bAttach, tProps)`,
  `api.entity.CreateRequestCompletionToken`, `api.entity.HaveRequestsCompleted(token)`, `transform:HasTransform`,
  `transform:SetTransform / SetPosition`, `api.entity.DestroyEntity`. Ring: `"Char_Props_PlacementRing"`
  (`V/editors.cameras.walkingcamerainituimode.lua:42-89`). Guest bodies: do not spawn (see the avatar notes above).
- World label: `tEnvironment:RequireInterface("Interfaces.IUIBillboardWidgetsManager")`, widget type
  `tWorldAPIs.billboardwidgets.WidgetType_WidgetLabel`, `SetBillboardWidgetUIInfo(type, 1, {sLabel, vPos, nOpacity})`,
  `SetBillboardWidgetData(type, {...})`, `ClearBillboardWidgetData(type)` (`V/editors.volume.volumeedithelper.lua:67-68,599-608`).
  Shared with the volume / fence / camera-route editors.
