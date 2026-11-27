// PZ2-Coop anchor patch for UIGameface/js/project/modules/Browser/BrowserUtils.js.
// Dynamically allows the Research Outpost and Vehicle Station blueprints through the WildAreaOnly
// and Essentials filters in Sandbox, Challenge, and Career zoos while keeping Franchise mode and
// Reserve-only equipment (Acoustic Monitors / Camera Traps) untouched.
import { GameMode } from '/js/project/data/GameTypes.js';
import { currentGamemodeIs, gameModeHelper } from '/js/project/data/SimulationDataModel.js';
import { isPz2CoopResearchVehicleItem } from '/js/project/data/Schemas/BrowserItemsDatabase.js';
@@ replace if (isWildArea && item.areaType == BrowserItemAreaType.ZooOnly || !isWildArea && item.areaType == BrowserItemAreaType.WildAreaOnly) {
        const pz2CoopUnlockVehicle = isPz2CoopResearchVehicleItem(item.uid, item.icon, item.label) && !(gameModeHelper && currentGamemodeIs(GameMode.Franchise));
        if (isWildArea && item.areaType == BrowserItemAreaType.ZooOnly || (!isWildArea && item.areaType == BrowserItemAreaType.WildAreaOnly && !pz2CoopUnlockVehicle)) {
@@ replace if (showEssentials == true && !item.isCoreItem) {
        if (showEssentials == true && !item.isCoreItem && !pz2CoopUnlockVehicle) {
