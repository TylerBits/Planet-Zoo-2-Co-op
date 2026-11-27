// PZ2-Coop anchor patch for UIGameface/js/project/data/Schemas/BrowserItemsDatabase.js.
// Copies tags defensively (Coherent DataStore arrays can be non-extensible), adds the verified
// Facilities -> Transport leaf category tag ('MenuCategory_Facilities_Transport', ID 835), and
// marks the Research Outpost (FAC_Wild_ResearchOutpost) and its 4 biome Vehicle Station blueprints
// (RTW_*_VehicleStation) as core/essential items so they appear even when the Essentials filter is on.
// Live Franchise vs Sandbox/Challenge/Career gating happens in browserutils_patch.js.
@@ after export const onBrowserItemsDataChanged = new Signal();
export function isPz2CoopResearchVehicleItem(uid, icon, label) {
    const lowUid = String(uid || '').toLowerCase();
    const lowIcon = String(icon || '').toLowerCase();
    const lowLabel = String(label || '').toLowerCase();
    return lowUid === 'fac_wild_researchoutpost' ||
        lowUid.includes('researchoutpost') ||
        lowUid.includes('vehiclestation') ||
        lowIcon.includes('researchoutpost') ||
        lowIcon.includes('vehiclestation') ||
        lowLabel.includes('researchoutpost') ||
        lowLabel.includes('research outpost') ||
        lowLabel.includes('vehiclestation') ||
        lowLabel.includes('vehicle station');
}
@@ replace const isCoreItem = DS.getValue(item, "isCoreItem") ?? true;
            let isCoreItem = DS.getValue(item, "isCoreItem") ?? true;
@@ after if (uid != undefined) {
                if (isPz2CoopResearchVehicleItem(uid, icon, label)) {
                    tags = Array.isArray(tags) ? tags.slice() : [];
                    if (!tags.includes('MenuCategory_Facilities_Transport')) {
                        tags.push('MenuCategory_Facilities_Transport');
                    }
                    isCoreItem = true;
                }
