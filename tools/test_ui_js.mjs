// Headless Node.js check for src/ovl_ui/*.js (run: node tools/test_ui_js.mjs).
// Verifies JS syntax, pure state/label helpers in CoopMenu.js & JoinFriends.js, literal tag sanitization,
// and controller/focus invariants in our modal components without needing the game running.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const UI_DIR = path.join(ROOT, 'src', 'ovl_ui');

// 1. Check ES module syntax on CoopMenu.js, JoinFriends.js, and EmoteWheel.js
for (const name of ['CoopMenu.js', 'JoinFriends.js', 'EmoteWheel.js']) {
    const file = path.join(UI_DIR, name);
    execFileSync(process.execPath, ['--input-type=module', '--check'], {
        input: fs.readFileSync(file, 'utf8'),
        stdio: ['pipe', 'pipe', 'pipe'],
    });
}

// 2. Verify CoopMenu, JoinFriends, EmoteWheel & Browser patch source invariants
const coopSrc = fs.readFileSync(path.join(UI_DIR, 'CoopMenu.js'), 'utf8');
const joinSrc = fs.readFileSync(path.join(UI_DIR, 'JoinFriends.js'), 'utf8');
const wheelSrc = fs.readFileSync(path.join(UI_DIR, 'EmoteWheel.js'), 'utf8');
const browserItemsPatch = fs.readFileSync(path.join(UI_DIR, 'browseritemsdatabase_patch.js'), 'utf8');
const browserUtilsPatch = fs.readFileSync(path.join(UI_DIR, 'browserutils_patch.js'), 'utf8');
const pauseMenuPatch = fs.readFileSync(path.join(UI_DIR, 'pausemenu_patch.js'), 'utf8');
const pausePatch = fs.readFileSync(path.join(UI_DIR, 'pausemenumodule_patch.js'), 'utf8');

assert.match(coopSrc, /Focusable\.decorate/, 'CoopMenu must be Focusable.decorate');
assert.match(coopSrc, /InputName\.Cancel/, 'CoopMenu must handle Cancel (Esc/B)');
assert.match(coopSrc, /oskTitle:\s*'Room code'/, 'CoopMenu room code input must set oskTitle for controllers');
assert.match(coopSrc, /createExtendedUIControlContext/, 'CoopMenu must create extended UI control context for controllers');
assert.match(coopSrc, /requestRadialDisable/, 'CoopMenu must disable radial menu while open');
assert.match(coopSrc, /hasGlobalInput:\s*true/, 'CoopMenu ScrollPane must enable controller scrolling');
assert.match(coopSrc, /defaultFocus:\s*true/, 'CoopMenu must set defaultFocus for controllers');
assert.match(coopSrc, /viewfriend/, 'CoopMenu must expose Jump camera (viewfriend)');
assert.match(coopSrc, /resync/, 'CoopMenu must expose Resync zoo');
assert.match(coopSrc, /versionMismatch/, 'CoopMenu must display version mismatch banner');
assert.match(joinSrc, /Focusable\.decorate/, 'JoinFriendsModal must be Focusable.decorate');
assert.match(joinSrc, /InputName\.Cancel/, 'JoinFriendsModal must handle Cancel (Esc/B)');
assert.match(joinSrc, /createExtendedUIControlContext/, 'JoinFriendsModal must create extended UI control context for controllers');
assert.match(joinSrc, /requestRadialDisable/, 'JoinFriendsModal must disable radial menu while open');
assert.match(joinSrc, /hasGlobalInput:\s*true/, 'JoinFriendsModal ScrollPane must enable controller scrolling');
assert.match(joinSrc, /defaultFocus:\s*true/, 'JoinFriendsModal must set defaultFocus for controllers');
assert.match(joinSrc, /Focus\.Barrier\.Input_Hover_Spatial/, 'JoinFriendsModal must set focusBarrier');
assert.match(pausePatch, /Focus\.Barrier\.Input_Hover_Spatial/, 'PauseMenu CoopMenu layer must set focusBarrier');
assert.match(pauseMenuPatch, /isGuestWorld\(state\.pz2coopState\)/, 'PauseMenu patch must disable Save button for guest worlds');
assert.match(pauseMenuPatch, /Only the host can save this zoo/, 'PauseMenu patch must show host-only save tooltip');
assert.match(pausePatch, /!isGuestWorld\(state\.pz2coopState\)/, 'PauseMenuModule patch must suppress saveOnExit for guest worlds');
assert.match(pausePatch, /EmoteWheel/, 'PauseMenuModule patch must mount EmoteWheel');
assert.match(pausePatch, /ProjectModuleFocusPriority\.RadialMenu/, 'PauseMenuModule patch must pass RadialMenu focusModulePriority to EmoteWheel');
assert.match(wheelSrc, /Focusable\.decorate/, 'EmoteWheel must be Focusable.decorate');
assert.match(wheelSrc, /requestRadialDisable/, 'EmoteWheel must disable vanilla radial menu while open');
assert.match(wheelSrc, /pz2coopEmoteWheel/, 'EmoteWheel must bind pz2coopEmoteWheel data store key');
assert.match(wheelSrc, /RadialMenuContent/, 'EmoteWheel must reuse vanilla RadialMenuContent');
assert.match(wheelSrc, /RadialItem/, 'EmoteWheel must reuse vanilla RadialItem');
assert.match(wheelSrc, /PaperPanelBackground/, 'EmoteWheel must reuse vanilla PaperPanelBackground');
assert.match(wheelSrc, /Paginator/, 'EmoteWheel must reuse vanilla Paginator');
assert.match(wheelSrc, /enableHitBoxes:\s*true/, 'EmoteWheel must enable mouse hitboxes on RadialItem');
assert.doesNotMatch(pausePatch, /VehicleHUD/, 'Custom VehicleHUD must be removed from PauseMenuModule patch');
assert.doesNotMatch(pausePatch, /pz2coopVehicleHUD/, 'pz2coopVehicleHUD binding must be removed from PauseMenuModule patch');
assert.ok(!fs.existsSync(path.join(UI_DIR, 'VehicleHUD.js')), 'VehicleHUD.js must be deleted');
assert.ok(!fs.existsSync(path.join(UI_DIR, 'VehicleHUD.css')), 'VehicleHUD.css must be deleted');
assert.match(coopSrc, /vrecall/, 'CoopMenu must expose vehicle recall controls');
assert.match(browserItemsPatch, /isPz2CoopResearchVehicleItem/, 'BrowserItemsDatabase patch must export isPz2CoopResearchVehicleItem');
assert.match(browserItemsPatch, /MenuCategory_Facilities_Transport/, 'BrowserItemsDatabase patch must add leaf Facilities Transport tag');
assert.match(browserItemsPatch, /tags\.slice\(\)/, 'BrowserItemsDatabase patch must copy tags defensively before pushing');
assert.match(browserItemsPatch, /isCoreItem = true/, 'BrowserItemsDatabase patch must mark vehicle items as core/essential');
assert.doesNotMatch(browserItemsPatch, /currentGamemodeIs/, 'BrowserItemsDatabase patch must NOT call currentGamemodeIs during startup before gameModeHelper is ready');
assert.doesNotMatch(browserItemsPatch, /'MenuCategory_Facilities'/, 'BrowserItemsDatabase patch must never add root category tag MenuCategory_Facilities');
assert.match(browserUtilsPatch, /gameModeHelper && currentGamemodeIs\(GameMode\.Franchise\)/, 'BrowserUtils patch must gate out Franchise mode dynamically with null-safe gameModeHelper');
assert.match(browserUtilsPatch, /showEssentials == true && !item\.isCoreItem && !pz2CoopUnlockVehicle/, 'BrowserUtils patch must bypass Essentials filter for unlocked Research Vehicles');

// 2b. Verify every custom PZ2Coop_*.svg icon referenced in EmoteWheel.js exists and is a valid 40x40 white SVG
const iconMatches = [...wheelSrc.matchAll(/icon:\s*'(PZ2Coop_[A-Za-z0-9_]+)'/g)].map((m) => m[1]);
assert.equal(iconMatches.length, 12, `expected 12 custom PZ2Coop SVG icons, found ${iconMatches.length}`);
for (const iconName of iconMatches) {
    const svgPath = path.join(UI_DIR, 'icons', `${iconName}.svg`);
    assert.ok(fs.existsSync(svgPath), `missing custom SVG icon: ${svgPath}`);
    const svgText = fs.readFileSync(svgPath, 'utf8');
    assert.match(svgText, /viewBox="0 0 40 40"/, `${iconName}.svg must use 40x40 viewBox`);
    assert.match(svgText, /fill="white"/, `${iconName}.svg must use solid white fill for vanilla CSS tint filters`);
}

// 3. Extract and unit-test pure helpers from CoopMenu.js & JoinFriends.js in isolation
function extractFn(src, name) {
    const start = src.indexOf(`export function ${name}(`);
    assert.ok(start >= 0, `missing export function ${name}`);
    let depth = 0;
    let i = src.indexOf('{', start);
    for (; i < src.length; i++) {
        if (src[i] === '{') depth++;
        else if (src[i] === '}') {
            depth--;
            if (depth === 0) return src.slice(start + 'export '.length, i + 1);
        }
    }
    throw new Error(`unclosed function ${name}`);
}

const helpersCode = [
    'const ICON = { people: "p", person: "u", error: "e" };',
    'const SLOW_SECS = 60;',
    extractFn(coopSrc, 'literal'),
    extractFn(coopSrc, 'parseCoopState'),
    extractFn(coopSrc, 'isGuestWorld'),
    extractFn(coopSrc, 'coopMenuValue'),
    extractFn(coopSrc, 'statusOf'),
    extractFn(joinSrc, 'joinPill'),
    extractFn(wheelSrc, 'parseEmoteState'),
    extractFn(wheelSrc, 'polarSegmentIndex'),
    'return { literal, parseCoopState, isGuestWorld, coopMenuValue, statusOf, joinPill, parseEmoteState, polarSegmentIndex };',
].join('\n');

const { literal, parseCoopState, isGuestWorld, coopMenuValue, statusOf, joinPill, parseEmoteState, polarSegmentIndex } = new Function(helpersCode)();

// 4. Test browseritemsdatabase_patch.js + browserutils_patch.js unlock logic (Sandbox vs Franchise, Outpost vs AcousticMonitor)
const isVehFnSrc = extractFn(browserItemsPatch, 'isPz2CoopResearchVehicleItem');
const isPz2CoopResearchVehicleItem = new Function(`${isVehFnSrc}\nreturn isPz2CoopResearchVehicleItem;`)();
assert.equal(isPz2CoopResearchVehicleItem('FAC_Wild_ResearchOutpost', 'img/Scenery/Textures/FAC_Wild_ResearchOutpost.png', 'Research Outpost'), true);
assert.equal(isPz2CoopResearchVehicleItem('921', 'img/Blueprints/Textures/RTW_GRASS_VehicleStation.png', 'Grassland Vehicle Station'), true, 'Blueprint numeric UID with VehicleStation icon must match');
assert.equal(isPz2CoopResearchVehicleItem('1234', 'img/Scenery/Textures/UndefinedImage.png', 'Research Outpost'), true, 'Label fallback must match Research Outpost');
assert.equal(isPz2CoopResearchVehicleItem('FAC_Wild_AcousticMonitor', 'img/Scenery/Textures/FAC_Wild_AcousticMonitor.png', 'Acoustic Monitor'), false, 'Acoustic Monitor must NOT match');
assert.equal(isPz2CoopResearchVehicleItem('FAC_Wild_CameraTrap', 'img/Scenery/Textures/FAC_Wild_CameraTrap.png', 'Camera Trap'), false, 'Camera Trap must NOT match');

const GM = { Franchise: 'Franchise', Sandbox: 'Sandbox' };
const Area = { Any: 0, ZooOnly: 1, WildAreaOnly: 2 };
function shouldRejectArea(item, isWildArea, modeHelper) {
    const currentGamemodeIs = (m) => modeHelper.value === m;
    const pz2CoopUnlockVehicle = isPz2CoopResearchVehicleItem(item.uid, item.icon) && !(modeHelper && currentGamemodeIs(GM.Franchise));
    return isWildArea && item.areaType == Area.ZooOnly || (!isWildArea && item.areaType == Area.WildAreaOnly && !pz2CoopUnlockVehicle);
}
assert.equal(shouldRejectArea({ uid: 'FAC_Wild_ResearchOutpost', icon: '', areaType: Area.WildAreaOnly }, false, { value: GM.Sandbox }), false, 'Sandbox must show Research Outpost in normal zoos');
assert.equal(shouldRejectArea({ uid: '921', icon: 'img/Blueprints/Textures/RTW_GRASS_VehicleStation.png', areaType: Area.WildAreaOnly }, false, { value: GM.Sandbox }), false, 'Sandbox must show Vehicle Station blueprint');
assert.equal(shouldRejectArea({ uid: 'FAC_Wild_AcousticMonitor', icon: '', areaType: Area.WildAreaOnly }, false, { value: GM.Sandbox }), true, 'Acoustic Monitor must stay Reserve-only');
assert.equal(shouldRejectArea({ uid: 'FAC_Wild_ResearchOutpost', icon: '', areaType: Area.WildAreaOnly }, false, { value: GM.Franchise }), true, 'Franchise must hide Research Outpost in normal zoos');
assert.equal(shouldRejectArea({ uid: 'FAC_Wild_ResearchOutpost', icon: '', areaType: Area.WildAreaOnly }, true, { value: GM.Franchise }), false, 'Franchise Reserve keeps vanilla Research Outpost');

assert.deepEqual(parseEmoteState(''), { open: false, page: 1 });
assert.equal(polarSegmentIndex(0, -100, 8).index, 0, '12 o-clock must map to segment 0');
assert.equal(polarSegmentIndex(100, -100, 8).index, 1, 'NE must map to segment 1');
assert.equal(polarSegmentIndex(100, 0, 8).index, 2, '3 o-clock must map to segment 2');
assert.equal(polarSegmentIndex(0, 100, 8).index, 4, '6 o-clock must map to segment 4');
assert.equal(polarSegmentIndex(-100, 0, 8).index, 6, '9 o-clock must map to segment 6');
assert.equal(polarSegmentIndex(-100, -100, 8).index, 7, 'NW must map to segment 7');

assert.equal(literal('Co-op | [test]'), '[STRING_LITERAL:Value=|Co-op  test|]');
assert.deepEqual(parseCoopState(''), {});
assert.deepEqual(parseCoopState('{bad'), {});
assert.equal(coopMenuValue(JSON.stringify({ role: 'host', connected: true })), '[STRING_LITERAL:Value=|Playing|]');
assert.equal(coopMenuValue(JSON.stringify({ role: 'client', phase: 'download', zooGot: 5, zooTotal: 10 })), '[STRING_LITERAL:Value=|Downloading 50%|]');
assert.equal(coopMenuValue(JSON.stringify({ role: 'none', allowed: false })), '[STRING_LITERAL:Value=|Not available|]');
assert.equal(isGuestWorld(JSON.stringify({ role: 'host', guestWorld: false })), false);
assert.equal(isGuestWorld(JSON.stringify({ role: 'client', guestWorld: false })), true);
assert.equal(isGuestWorld(JSON.stringify({ role: 'none', guestWorld: true })), true);
assert.equal(isGuestWorld(''), false);

const stDownload = statusOf({ role: 'client', phase: 'download', partner: 'Alex', zooGot: 4, zooTotal: 8, zooBytes: 2097152, phaseSecs: 12 });
assert.match(stDownload.text, /Step 3 of 3.*50%.*2\.0 MB.*12 s/);
assert.equal(stDownload.slow, false);
assert.equal(statusOf({ role: 'client', phase: 'joining', phaseSecs: 65 }).slow, true);

assert.deepEqual(joinPill(JSON.stringify({ friendsAvailable: false })), { text: 'Offline', live: false });
assert.deepEqual(joinPill(JSON.stringify({ friendsAvailable: true, friends: [{ lobby: '123' }, { lobby: '' }] })), { text: '1 Online', live: true });

console.log('ok: UI JS syntax, focus invariants, and state helpers');
