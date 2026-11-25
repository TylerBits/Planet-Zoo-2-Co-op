// PZ2-Coop insertions into the vanilla Esc menu (UIGameface/js/project/modules/PauseMenu/PauseMenu.js).
// tools/build_ovl_mod.py applies each "@@ <before|after> <anchor>" section at its anchor (found exactly
// once, or the build fails). Lines starting with "import " are hoisted to the top of the file.
import { coopMenuValue, isGuestWorld } from '/js/project/modules/PZ2Coop/CoopMenu.js';
@@ after bindDSPropsToState(this, ZOOPEDIA_CONTEXT, this._dataHelper, 'zoopediaDisabled');
        bindDSPropsToState(this, UI_CONTEXT, this._dataHelper, 'pz2coopState');
@@ replace preact.h(Button, { icon: 'img/icons/save.svg', label: '[Save]', modifiers: 'stretch', disabled: unownedDLC || state.isLoadingPark, tooltip: unownedDLC ? '[OnLoadPopup_body]' : undefined, onSelect: this.onSaveButtonSelect }),
preact.h(Button, { icon: 'img/icons/save.svg', label: '[Save]', modifiers: 'stretch', disabled: unownedDLC || state.isLoadingPark || isGuestWorld(state.pz2coopState), tooltip: unownedDLC ? '[OnLoadPopup_body]' : (isGuestWorld(state.pz2coopState) ? '[STRING_LITERAL:Value=|Only the host can save this zoo|]' : undefined), onSelect: this.onSaveButtonSelect }),
@@ before preact.h(Button, { icon: 'img/icons/Icon_LoadingTip.svg'
preact.h(Button, { icon: 'img/icons/IconPeople.svg', label: '[STRING_LITERAL:Value=|Co-op|]', modifiers: 'stretch', value: coopMenuValue(state.pz2coopState), onSelect: props.onOpenCoop, disabled: state.isLoadingPark || props.onOpenCoop == undefined }),
@@ after onSaveButtonSelect = () => {
        if (isGuestWorld(this.state.pz2coopState)) {
            return;
        }

