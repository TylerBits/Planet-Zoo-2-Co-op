// PZ2-Coop: main menu "Join Friends" card and its join-only popup
// (served as UIGameface/js/project/modules/PZ2Coop/JoinFriends.js; placed by homebuttons_patch.js).
// Same data as the Esc-menu Co-op screen (CoopMenu.js): Lua publishes pz2coopState in the 'ui' data store.
// The Frontend view has no MainHUD, so actions go out as sendEvent('PZ2Coop_Select', 'pz2coop_<cmd>[:<arg>]'),
// which pz2coop.ui.lua listens for on the Frontend view. No hosting controls here by design.
import * as preact from '/js/common/lib/preact.js';
import * as Focusable from '/js/common/components/Focusable.js';
import * as Focus from '/js/common/core/Focus.js';
import { classNames } from '/js/common/lib/classnames.js';
import { loadCSS } from '/js/common/util/CSSUtil.js';
import { sendEvent } from '/js/common/core/Engine.js';
import * as Input from '/js/common/core/Input.js';
import { InputName } from '/js/common/core/InputTypes.js';
import { ControlContextPriority } from '/js/config/ControlContextPriority.js';
import { DataStoreHelper } from '/js/common/util/DataStoreHelper.js';
import { bindDSPropsToState } from '/js/common/util/DataStoreUtil.js';
import { Icon } from '/js/common/components/Icon.js';
import { Layer } from '/js/common/components/Layer.js';
import { ScrollPane, Policy } from '/js/common/components/ScrollPane.js';
import * as RadialMenuAccess from '/js/project/modules/RadialMenu/RadialMenuAccess.js';
import { UI_CONTEXT } from '/js/project/utils/ContextUtil.js';
import { ProjectModuleFocusPriority } from '/js/project/utils/ProjectModuleFocusPriority.js';
import { SpecialModal } from '/js/project/components/SpecialModal.js';
import { ImageButton } from '/js/project/components/ImageButton.js';
import { Button } from '/js/project/components/Button.js';
import { InputField } from '/js/project/components/InputField.js';
import { Divider } from '/js/project/components/Divider.js';
import { LoadingSpinner } from '/js/project/components/LoadingSpinner.js';
import { literal, parseCoopState, statusOf, ERRORS, CoopAvatar } from '/js/project/modules/PZ2Coop/CoopMenu.js';
loadCSS('project/components/PZ2Coop/JoinFriends');

const ICON = {
    people: 'img/icons/IconPeople.svg',
    arrow: 'img/icons/Icon_Arrow_Right.svg',
    refresh: 'img/icons/Icon_CircleWithArrows.svg',
    back: 'img/icons/Icon_Back.svg',
};
const REFRESH_MS = 1500;

function send(cmd, arg) {
    sendEvent('PZ2Coop_Select', arg === undefined ? `pz2coop_${cmd}` : `pz2coop_${cmd}:${arg}`);
}

// Pill on the card: friends with an open co-op room, or Offline when Steam friends can't be read.
export function joinPill(json) {
    const s = parseCoopState(json);
    if (s.friendsAvailable !== true) {
        return { text: 'Offline', live: false };
    }
    const count = (s.friends || []).filter((f) => f.lobby).length;
    return { text: `${count} Online`, live: count > 0 };
}

export class JoinFriendsCard extends preact.Component {
    _dataHelper = new DataStoreHelper();
    state = { open: false };
    componentWillMount() {
        bindDSPropsToState(this, UI_CONTEXT, this._dataHelper, 'pz2coopState');
        this._dataHelper.getAllPropertiesNow();
        send('watch', 'on');
    }
    componentWillUnmount() {
        this._dataHelper.clear();
        send('watch', 'off');
    }
    render(props, state) {
        // Nothing published yet = the mod's Lua side isn't running: show the card, but disabled.
        const known = typeof state.pz2coopState === 'string' && state.pz2coopState !== '';
        const pill = known ? joinPill(state.pz2coopState) : { text: 'Offline', live: false };
        return preact.h("div", { className: classNames('JoinFriends_card', { fill: props.fill }) },
            preact.h(ImageButton, { rootClassName: 'HomeButtons_button', showLabelCuts: true, modifiers: 'secondary leftAlign joinFriends HomeButtons autoHeightLabel mediumLabel', labelIcon: ICON.people, label: literal('Join Friends'), disabled: !known, onSelect: this.open, imageChildren: [
                    preact.h("div", { className: 'JoinFriends_glyph', key: 'glyph' },
                        preact.h(Icon, { rootClassName: 'JoinFriends_glyphPeople', src: ICON.people }),
                        preact.h(Icon, { rootClassName: 'JoinFriends_glyphArrow', src: ICON.arrow })),
                    preact.h("div", { className: classNames('JoinFriends_pill', { live: pill.live }), key: 'pill' },
                        preact.h("span", { className: 'JoinFriends_pillDot' }),
                        pill.text)
                ] }),
            state.open &&
                preact.h(Layer, { darkenBackground: true, onMouseDownBackground: this.close },
                    preact.h(JoinFriendsModal, { focusableIfEmpty: true, focusBarrier: Focus.Barrier.Input_Hover_Spatial, focusModulePriority: ProjectModuleFocusPriority.SaveLoadMenu, coopState: state.pz2coopState, onClose: this.close })));
    }
    open = () => {
        this.setState({ open: true });
    };
    close = () => {
        this.setState({ open: false });
    };
}

export const JoinFriendsModal = Focusable.decorate(class JoinFriendsModal extends preact.Component {
    _timer = undefined;
    _componentName = 'UI_PZ2JoinFriendsModal';
    _radialRequestName = Symbol('UI_PZ2JoinFriendsModal');
    state = { joinCode: '', search: '', joiningLobby: undefined, refreshedAt: 0 };
    componentWillMount() {
        Input.createExtendedUIControlContext(this._componentName, ControlContextPriority.SaveLoadMenu, true, () => {
            Input.getControlContext(this._componentName)?.enable();
        });
        RadialMenuAccess.requestRadialDisable(this._radialRequestName);
        send('open');
    }
    componentWillUnmount() {
        clearTimeout(this._timer);
        Input.getControlContext(this._componentName)?.destroy();
        RadialMenuAccess.clearRadialDisable(this._radialRequestName);
        send('close');
    }
    // Esc closes the popup only (as My Saves does); our focus barrier keeps it from the main menu.
    handleInput(e) {
        if (e.inputName == InputName.Cancel && e.button && e.button.isPressed() && this.props.onClose) {
            this.props.onClose();
            return true;
        }
        return false;
    }
    render(props, state) {
        const s = parseCoopState(props.coopState);
        const joining = s.role === 'client' || s.busy === true;
        const status = joining ? statusOf(s) : null;
        const refreshing = Date.now() - state.refreshedAt < REFRESH_MS;
        return (preact.h(SpecialModal, { rootClassName: classNames('JoinFriends_modal', props.rootClassName), headerIcon: ICON.people, header: literal('Join Friends'), subHeader: literal("Join a friend's zoo and build together"), onClose: props.onClose },
            preact.h(ScrollPane, { rootClassName: 'CoopMenu_scroll', contentClassName: 'CoopMenu_body', scrollBarPolicy: Policy.OnDemand, hasGlobalInput: true },
                status &&
                    preact.h("div", { className: classNames('CoopMenu_status', { live: s.role === 'client' && s.phase === 'joined' }) },
                        preact.h(Icon, { rootClassName: 'CoopMenu_statusIcon', src: status.icon }),
                        preact.h("div", { className: 'CoopMenu_statusText' }, status.text),
                        status.waiting && preact.h(LoadingSpinner, { rootClassName: 'CoopMenu_spinner', modifiers: 'show' }),
                        preact.h(Button, { label: literal('Cancel'), modifiers: 'autoWidth white', onSelect: () => send('leave') })),
                status && status.slow &&
                    preact.h("div", { className: 'CoopMenu_hint' }, "This is taking longer than usual. If nothing changes, press Cancel, join again, and send both players' diag.log (Planet Zoo 2 game folder > PZ2Coop)."),
                s.versionMismatch &&
                    preact.h("div", { className: 'CoopMenu_error' }, `Mod version mismatch (${s.versionMismatch}). Both players should install the same PZ2Coop.zip.`),
                s.error &&
                    preact.h("div", { className: 'CoopMenu_error' }, ERRORS[s.error] ?? `Something went wrong (${s.error}).`),
                this.renderFriends(s, joining),
                preact.h(Divider, null),
                preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Join with a room code'),
                preact.h("div", { className: 'CoopMenu_row' },
                    preact.h(InputField, { rootClassName: 'CoopMenu_codeInput', promptText: literal('PZ-xxxxxx'), text: state.joinCode, maxInputLength: 12, oskTitle: 'Room code', defaultFocus: true, onChange: (e) => this.setState({ joinCode: e.text }), onCommit: (e) => this.joinWithCode(e.text) }),
                    preact.h(Button, { label: literal('Join'), modifiers: 'autoWidth', disabled: !s.canJoin || joining || state.joinCode.trim() === '', onSelect: () => this.joinWithCode(state.joinCode) })),
                preact.h("div", { className: 'CoopMenu_hint' }, 'Ask your friend for the code shown in their Co-op menu.')),
            preact.h("div", { className: classNames('CoopMenu_footer', 'JoinFriends_footer') },
                preact.h(Button, { icon: ICON.refresh, label: literal(refreshing ? 'Refreshing...' : 'Refresh'), modifiers: 'autoWidth white', disabled: refreshing, onSelect: this.refresh }),
                preact.h(Button, { icon: ICON.back, label: literal('Back'), modifiers: 'stretch center', onSelect: props.onClose }))));
    }
    renderFriends(s, joining) {
        if (s.friendsAvailable !== true) {
            return preact.h("div", { className: 'JoinFriends_empty' },
                preact.h("div", { className: 'JoinFriends_emptyTitle' }, 'You are currently offline'),
                preact.h("div", { className: 'CoopMenu_hint' }, "Your Steam friends list can't be read right now. Check that Steam is online, then press Refresh. You can still join with a room code."));
        }
        const friends = this.filtered(s.friends || []);
        const hosting = friends.filter((f) => f.lobby);
        const playing = friends.filter((f) => !f.lobby && f.playing);
        const total = (s.friends || []).filter((f) => f.lobby || f.playing).length;
        return preact.h("div", { className: 'CoopMenu_section' },
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Friends hosting a zoo'),
            total > 6 &&
                preact.h(InputField, { rootClassName: 'CoopMenu_search', isSearch: true, hasClearOption: true, promptText: literal('Search friends'), text: this.state.search, onChange: (e) => this.setState({ search: e.text }), onClear: () => this.setState({ search: '' }) }),
            hosting.map((f) => this.friendRow(f, s, 'Hosting a co-op zoo', this.joinAction(f, s, joining))),
            hosting.length === 0 &&
                preact.h("div", { className: 'JoinFriends_empty' },
                    preact.h("div", { className: 'JoinFriends_emptyTitle' }, 'No friends are currently hosting a zoo'),
                    preact.h("div", { className: 'CoopMenu_hint' }, 'Ask a friend to open a Sandbox, Challenge, or Scenario zoo and press Esc > Co-op > Host Co-op, then press Refresh.')),
            playing.length > 0 && preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Playing, not hosting'),
            playing.map((f) => this.friendRow(f, s, 'Playing Planet Zoo 2', null)));
    }
    friendRow(f, s, detail, action) {
        return preact.h("div", { className: classNames('CoopMenu_row', { JoinFriends_muted: !f.lobby }), key: f.id },
            preact.h(CoopAvatar, { id: f.id, name: f.name, has: Boolean(s.avatars && s.avatars[f.id]) }),
            preact.h("div", { className: 'CoopMenu_rowText' },
                preact.h("div", { className: 'CoopMenu_name' }, f.name),
                preact.h("div", { className: 'CoopMenu_detail' },
                    preact.h("span", { className: classNames('CoopMenu_dot', { playing: f.playing || Boolean(f.lobby) }) }),
                    detail)),
            action);
    }
    joinAction(f, s, joining) {
        if (joining && this.state.joiningLobby === f.lobby) {
            return preact.h(LoadingSpinner, { rootClassName: 'CoopMenu_spinner', modifiers: 'show' });
        }
        return preact.h(Button, { label: literal('Join'), modifiers: 'autoWidth', disabled: !s.canJoin || joining, onSelect: () => this.joinLobby(f.lobby) });
    }
    filtered(list) {
        const term = this.state.search.trim().toLowerCase();
        return term === '' ? list : list.filter((f) => String(f.name).toLowerCase().indexOf(term) >= 0);
    }
    joinLobby(lobby) {
        this.setState({ joiningLobby: lobby });
        send('joinlobby', lobby);
    }
    joinWithCode(code) {
        const trimmed = String(code || '').trim();
        if (trimmed !== '') {
            this.setState({ joinCode: trimmed, joiningLobby: undefined });
            send('join', trimmed);
        }
    }
    refresh = () => {
        send('refresh');
        this.setState({ refreshedAt: Date.now() });
        clearTimeout(this._timer);
        this._timer = setTimeout(() => this.setState({}), REFRESH_MS);
    };
});
