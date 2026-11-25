// PZ2-Coop insertions into UIGameface/js/project/modules/PauseMenu/PauseMenuModule.js: the Co-op screen
// opens on top of the Esc menu exactly like the Save/Load menu does (Layer + modal, Esc closes it first).
// Format: see pausemenu_patch.js.
import { DataStoreHelper } from '/js/common/util/DataStoreHelper.js';
import { bindDSPropsToState } from '/js/common/util/DataStoreUtil.js';
import { UI_CONTEXT } from '/js/project/utils/ContextUtil.js';
import { CoopMenu, isGuestWorld } from '/js/project/modules/PZ2Coop/CoopMenu.js';
import { EmoteWheel, parseEmoteState } from '/js/project/modules/PZ2Coop/EmoteWheel.js';
@@ after _controlContext;
    _pz2coopDataHelper = new DataStoreHelper();
@@ after Engine.addListener('SaveFailed_ShowSavesMenu', this.showSaveFailedMenu);
        bindDSPropsToState(this, UI_CONTEXT, this._pz2coopDataHelper, 'pz2coopEmoteWheel');
        bindDSPropsToState(this, UI_CONTEXT, this._pz2coopDataHelper, 'pz2coopState');
        this._pz2coopDataHelper.getAllPropertiesNow();
@@ after Engine.removeListener('SaveFailed_ShowSavesMenu', this.showSaveFailedMenu);
        this._pz2coopDataHelper.clear();
@@ replace const saveOnExit = (currentGamemodeIs(GameMode.ScenarioCareer) || currentGamemodeIs(GameMode.Scenario) || currentGamemodeIs(GameMode.Franchise)) && !hasUnownedDLC();
const saveOnExit = (currentGamemodeIs(GameMode.ScenarioCareer) || currentGamemodeIs(GameMode.Scenario) || currentGamemodeIs(GameMode.Franchise)) && !hasUnownedDLC() && !isGuestWorld(state.pz2coopState);
@@ replace { show: props.showingGameMenu }
{ show: props.showingGameMenu || parseEmoteState(state.pz2coopEmoteWheel).open }
@@ after onQuitGame: this.showQuitDialog
, onOpenCoop: this.pz2coopOpenMenu
@@ before state.showExitDialog &&
preact.h(EmoteWheel, { focusable: parseEmoteState(state.pz2coopEmoteWheel).open, focusableIfEmpty: true, focusBarrier: parseEmoteState(state.pz2coopEmoteWheel).open ? Focus.Barrier.Input_Hover_Spatial : Focus.Barrier.None, focusModulePriority: parseEmoteState(state.pz2coopEmoteWheel).open ? ProjectModuleFocusPriority.RadialMenu : undefined }),
state.pz2coopMenu &&
                preact.h(Layer, { onMouseDownBackground: this.pz2coopCloseMenu, darkenBackground: !props.showingGameMenu },
                    preact.h(CoopMenu, { focusableIfEmpty: true, focusBarrier: Focus.Barrier.Input_Hover_Spatial, focusModulePriority: ProjectModuleFocusPriority.SaveLoadMenu, onClose: this.pz2coopCloseMenu })),

@@ before if (this.state.showSave || this.state.showLoad) {
if (this.state.pz2coopMenu) {
                this.pz2coopCloseMenu();
                return true;
            }

@@ before showSettingsMenu = () => {
pz2coopOpenMenu = () => {
        this.setState({ pz2coopMenu: true });
    };
    pz2coopCloseMenu = () => {
        this.setState({ pz2coopMenu: false });
    };

