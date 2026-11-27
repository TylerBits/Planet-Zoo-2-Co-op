// PZ2-Coop: the Co-op screen opened from the Esc menu (served as
// UIGameface/js/project/modules/PZ2Coop/CoopMenu.js by our UI overlay; see tools/build_ovl_mod.py).
// Built only from the game's own components so it matches the Save/Load screen.
// State: Lua publishes one JSON string in the 'ui' data store (key pz2coopState) plus one key per Steam
// picture (pz2coopAv_<steamid> = "<size>:<base64 RGB>"); see src/ovl_mod/pz2coop.ui.lua.
// Actions: sendEvent('PauseMenu_UI_Select', 'pz2coop_<cmd>[:<arg>]'), handled in pz2coop.ui.lua.
import * as preact from '/js/common/lib/preact.js';
import * as Focusable from '/js/common/components/Focusable.js';
import * as DS from '/js/common/core/DataStore.js';
import { classNames } from '/js/common/lib/classnames.js';
import { loadCSS } from '/js/common/util/CSSUtil.js';
import { sendEvent } from '/js/common/core/Engine.js';
import * as Input from '/js/common/core/Input.js';
import { InputName } from '/js/common/core/InputTypes.js';
import { ControlContextPriority } from '/js/config/ControlContextPriority.js';
import { DataStoreHelper } from '/js/common/util/DataStoreHelper.js';
import { bindDSPropsToState } from '/js/common/util/DataStoreUtil.js';
import { Canvas } from '/js/common/components/Canvas.js';
import { Icon } from '/js/common/components/Icon.js';
import { ScrollPane, Policy } from '/js/common/components/ScrollPane.js';
import * as RadialMenuAccess from '/js/project/modules/RadialMenu/RadialMenuAccess.js';
import { UI_CONTEXT } from '/js/project/utils/ContextUtil.js';
import { SpecialModal } from '/js/project/components/SpecialModal.js';
import { Button } from '/js/project/components/Button.js';
import { InputField } from '/js/project/components/InputField.js';
import { Divider } from '/js/project/components/Divider.js';
import { LoadingSpinner } from '/js/project/components/LoadingSpinner.js';
loadCSS('project/components/PZ2Coop/CoopMenu');

const ICON = {
    people: 'img/icons/IconPeople.svg',
    person: 'img/icons/IconPerson.svg',
    copy: 'img/icons/Icon_Copy.svg',
    leave: 'img/icons/IconLeave.svg',
    lock: 'img/icons/IconLock.svg',
    unlock: 'img/icons/IconUnlock.svg',
    tick: 'img/icons/Icon_Tick.svg',
    error: 'img/icons/Icon_NoConnection.svg',
};

export const ERRORS = {
    invalid_room_code: "That room code isn't valid. Codes look like PZ-3YQd8w.",
    join_lobby_failed: "Couldn't join. The room may be closed or already full.",
    create_lobby_failed: "Couldn't open a room. Check that Steam is online.",
    steam_not_ready: "Steam isn't ready yet. Try again in a moment.",
    already_in_session: "You're already in a co-op session.",
    invite_failed: "The invite couldn't be sent.",
    connect_failed: "Couldn't reach the host's game. Check you both have the same mod version, then try again.",
    connection_lost: 'The connection to the host was lost. Join again to continue.',
    zoo_transfer_failed: "The host's zoo didn't arrive complete. Leave and join again.",
    listen_socket_failed: 'Connection failed. Try again.',
    no_response: 'No answer from the co-op service. Try again, or restart the game if it keeps happening.',
};

// A choice made in the UI is shown at once and trusted for this long while Lua/Steam confirm it, so a
// click never flips back and forth.
const OPTIMISTIC_MS = 4000;

// Game text goes through the localiser; a literal tag shows our English text as-is.
// '|', '[' and ']' would break the tag, so they are removed.
export function literal(text) {
    return `[STRING_LITERAL:Value=|${String(text).replace(/[|[\]]/g, '')}|]`;
}

export function parseCoopState(json) {
    try {
        const state = typeof json === 'string' && json !== '' ? JSON.parse(json) : null;
        return state && typeof state === 'object' ? state : {};
    }
    catch (e) {
        return {};
    }
}

// True while the local player is viewing a host's world (blocks guest saving and save-on-exit prompts).
export function isGuestWorld(json) {
    const s = parseCoopState(json);
    return s.role === 'client' || s.guestWorld === true;
}

// Right-hand value on the Esc menu's Co-op button.
export function coopMenuValue(json) {
    const s = parseCoopState(json);
    if (s.role === 'host') {
        return literal(s.connected ? 'Playing' : 'Hosting');
    }
    if (s.role === 'client') {
        if (s.phase === 'download' && s.zooTotal > 0) {
            return literal(`Downloading ${Math.floor((100 * s.zooGot) / s.zooTotal)}%`);
        }
        return literal(s.phase === 'joined' ? 'Connected' : 'Joining');
    }
    return literal(s.allowed ? 'Off' : 'Not available');
}

// ---- Steam pictures ------------------------------------------------------------------------------
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const decodedAvatars = new Map(); // raw data-store string -> { size, rgb[] }

function decodeAvatar(raw) {
    if (typeof raw !== 'string' || raw.indexOf(':') < 1) {
        return null;
    }
    if (decodedAvatars.has(raw)) {
        return decodedAvatars.get(raw);
    }
    const size = parseInt(raw, 10);
    const text = raw.substr(raw.indexOf(':') + 1);
    const rgb = [];
    let buffer = 0;
    let bits = 0;
    for (let i = 0; i < text.length && text[i] !== '='; ++i) {
        const v = B64.indexOf(text[i]);
        if (v < 0) {
            continue;
        }
        buffer = ((buffer << 6) | v) & 0xFFFFFF;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            rgb.push((buffer >> bits) & 0xFF);
        }
    }
    const avatar = size > 0 && size <= 64 && rgb.length >= size * size * 3 ? { size, rgb } : null;
    decodedAvatars.set(raw, avatar);
    return avatar;
}

// Round Steam picture painted on the game's own Canvas with fillRect (as retail LineChartGraph draws);
// a coloured initial is shown until the picture arrives or if the user has none.
export class CoopAvatar extends preact.Component {
    _avatar = null;
    render(props) {
        const raw = props.has ? DS.getValue(UI_CONTEXT, `pz2coopAv_${props.id}`) : undefined;
        this._avatar = decodeAvatar(raw);
        const initial = String(props.name || '?').trim().charAt(0).toUpperCase() || '?';
        return preact.h("div", { className: classNames('CoopMenu_avatar', props.modifiers) },
            this._avatar
                ? preact.h(Canvas, { rootClassName: 'CoopMenu_avatarCanvas', onDraw: this.draw, data: raw })
                : preact.h("div", { className: 'CoopMenu_avatarInitial' }, initial));
    }
    draw = (ctx) => {
        const avatar = this._avatar;
        if (!avatar) {
            return;
        }
        const cell = ctx.canvas.width / avatar.size;
        const cellH = ctx.canvas.height / avatar.size;
        for (let y = 0; y < avatar.size; ++y) {
            for (let x = 0; x < avatar.size; ++x) {
                const p = (y * avatar.size + x) * 3;
                ctx.fillStyle = `rgb(${avatar.rgb[p]},${avatar.rgb[p + 1]},${avatar.rgb[p + 2]})`;
                ctx.fillRect(Math.floor(x * cell), Math.floor(y * cellH), Math.ceil(cell), Math.ceil(cellH));
            }
        }
    };
}

// Waits longer than this show a "taking longer than usual" hint so a tester knows to report it.
const SLOW_SECS = 60;

export function statusOf(s) {
    const ping = typeof s.ping === 'number' && s.ping >= 0 ? ` · ${s.ping} ms` : '';
    // A visible running timer shows the game isn't frozen while we wait.
    const secs = typeof s.phaseSecs === 'number' ? ` (${s.phaseSecs} s)` : '';
    const slow = s.phaseSecs >= SLOW_SECS;
    const host = s.partner || 'the host';
    if (s.role === 'host') {
        return s.connected
            ? { text: `Playing with ${s.partner || 'your friend'}${ping}`, icon: ICON.people }
            : { text: 'Room open. Waiting for a friend to join.', icon: ICON.people, waiting: true };
    }
    if (s.role === 'client') {
        if (s.phase === 'joining') {
            return { text: `Step 1 of 3: connecting to ${host}'s game...${secs}`, icon: ICON.people, waiting: true, slow };
        }
        if (s.phase === 'waitzoo') {
            return { text: `Step 2 of 3: waiting for ${host} to send their zoo...${secs}`, icon: ICON.people, waiting: true, slow };
        }
        if (s.phase === 'download') {
            const pct = s.zooTotal > 0 ? Math.floor((100 * s.zooGot) / s.zooTotal) : 0;
            const mb = ((s.zooBytes || 0) / 1048576).toFixed(1);
            return { text: `Step 3 of 3: downloading ${host}'s zoo... ${pct}% (${mb} MB)${secs}`, icon: ICON.people, waiting: true, slow };
        }
        return { text: `Connected to ${host}'s zoo${ping}`, icon: ICON.people };
    }
    if (s.busy) {
        return { text: `Finding the room...${secs}`, icon: ICON.people, waiting: true };
    }
    if (!s.allowed) {
        return { text: 'Co-op works in Sandbox, Challenge, and Scenario parks (disabled in Franchise).', icon: ICON.error };
    }
    return { text: 'Not in a co-op session', icon: ICON.person };
}

export const CoopMenu = Focusable.decorate(class CoopMenu extends preact.Component {
    _dataHelper = new DataStoreHelper();
    _timer = undefined;
    _componentName = 'UI_PZ2CoopMenu';
    _radialRequestName = Symbol('UI_PZ2CoopMenu');
    state = { joinCode: '', search: '', privacyChoice: undefined, privacyAt: 0, invitedNow: {}, copiedAt: 0, resyncedAt: 0 };
    componentWillMount() {
        bindDSPropsToState(this, UI_CONTEXT, this._dataHelper, 'pz2coopState');
        this._dataHelper.getAllPropertiesNow();
        Input.createExtendedUIControlContext(this._componentName, ControlContextPriority.SaveLoadMenu, true, () => {
            Input.getControlContext(this._componentName)?.enable();
        });
        RadialMenuAccess.requestRadialDisable(this._radialRequestName);
        sendEvent('PauseMenu_UI_Select', 'pz2coop_open');
    }
    componentWillUnmount() {
        clearTimeout(this._timer);
        this._dataHelper.clear();
        Input.getControlContext(this._componentName)?.destroy();
        RadialMenuAccess.clearRadialDisable(this._radialRequestName);
        sendEvent('PauseMenu_UI_Select', 'pz2coop_close');
    }
    // Esc only closes this screen (the session keeps running). Our focus barrier stops input from
    // reaching PauseMenuModule, so Cancel is handled here as retail SaveLoadMenu does.
    handleInput(e) {
        if (e.inputName == InputName.Cancel && e.button && e.button.isPressed() && this.props.onClose) {
            this.props.onClose();
            return true;
        }
        return false;
    }
    send(cmd, arg) {
        sendEvent('PauseMenu_UI_Select', arg === undefined ? `pz2coop_${cmd}` : `pz2coop_${cmd}:${arg}`);
    }
    // Re-render once a short-lived UI state (Copied!, optimistic choice) expires.
    refreshLater(ms) {
        clearTimeout(this._timer);
        this._timer = setTimeout(() => this.setState({}), ms);
    }
    render(props, state) {
        const s = parseCoopState(state.pz2coopState);
        const status = statusOf(s);
        const inSession = s.role === 'host' || s.role === 'client';
        return (preact.h(SpecialModal, { rootClassName: classNames('CoopMenu_root', props.rootClassName), headerIcon: ICON.people, header: literal('Co-op'), subHeader: literal('Build your zoo together with a friend'), onClose: props.onClose },
            preact.h(ScrollPane, { rootClassName: 'CoopMenu_scroll', contentClassName: 'CoopMenu_body', scrollBarPolicy: Policy.OnDemand, hasGlobalInput: true },
                preact.h("div", { className: classNames('CoopMenu_status', { live: inSession && s.connected }) },
                    preact.h(Icon, { rootClassName: 'CoopMenu_statusIcon', src: status.icon }),
                    preact.h("div", { className: 'CoopMenu_statusText' }, status.text),
                    status.waiting && preact.h(LoadingSpinner, { rootClassName: 'CoopMenu_spinner', modifiers: 'show' }),
                    status.waiting && !inSession &&
                        preact.h(Button, { label: literal('Cancel'), modifiers: 'autoWidth white', onSelect: () => this.send('leave') })),
                status.slow &&
                    preact.h("div", { className: 'CoopMenu_hint' }, "This is taking longer than usual. If nothing changes, press Leave Co-op, join again, and send both players' diag.log (Planet Zoo 2 game folder > PZ2Coop)."),
                s.versionMismatch &&
                    preact.h("div", { className: 'CoopMenu_error' }, `Mod version mismatch (${s.versionMismatch}). Both players should install the same PZ2Coop.zip.`),
                s.error &&
                    preact.h("div", { className: 'CoopMenu_error' }, ERRORS[s.error] ?? `Something went wrong (${s.error}).`),
                !inSession && this.renderLobby(s),
                s.role === 'host' && this.renderHost(s),
                s.role === 'client' && this.renderClient(s),
                s.hasVehicle && this.renderVehicleTools(s)),
            inSession &&
                preact.h("div", { className: 'CoopMenu_footer' },
                    preact.h(Button, { icon: ICON.leave, label: literal(s.role === 'host' ? 'Close room' : 'Leave Co-op'), modifiers: 'stretch negative center', onSelect: () => this.send('leave') }))));
    }
    // ---- rows ------------------------------------------------------------------------------------
    playerRow(id, name, detail, s, key) {
        return preact.h("div", { className: 'CoopMenu_row', key },
            preact.h(CoopAvatar, { id, name, has: Boolean(id && s.avatars && s.avatars[id]) }),
            preact.h("div", { className: 'CoopMenu_rowText' },
                preact.h("div", { className: 'CoopMenu_name' }, name),
                preact.h("div", { className: 'CoopMenu_detail' }, detail)));
    }
    friendRow(f, s, detail, action) {
        return preact.h("div", { className: 'CoopMenu_row', key: f.id },
            preact.h(CoopAvatar, { id: f.id, name: f.name, has: Boolean(s.avatars && s.avatars[f.id]) }),
            preact.h("div", { className: 'CoopMenu_rowText' },
                preact.h("div", { className: 'CoopMenu_name' }, f.name),
                preact.h("div", { className: 'CoopMenu_detail' },
                    preact.h("span", { className: classNames('CoopMenu_dot', { playing: f.playing }) }),
                    detail)),
            action);
    }
    searchBox(count) {
        return count > 6 &&
            preact.h(InputField, { rootClassName: 'CoopMenu_search', isSearch: true, hasClearOption: true, promptText: literal('Search friends'), text: this.state.search, onChange: (e) => this.setState({ search: e.text }), onClear: () => this.setState({ search: '' }) });
    }
    filtered(list) {
        const term = this.state.search.trim().toLowerCase();
        return term === '' ? list : list.filter((f) => String(f.name).toLowerCase().indexOf(term) >= 0);
    }
    // ---- views -----------------------------------------------------------------------------------
    renderLobby(s) {
        const friends = s.friends || [];
        const hosting = this.filtered(friends.filter((f) => f.lobby));
        const playing = this.filtered(friends.filter((f) => !f.lobby && f.playing));
        const canAct = s.allowed && !s.busy;
        return preact.h("div", { className: 'CoopMenu_section' },
            preact.h(Button, { icon: ICON.people, label: literal('Host Co-op'), modifiers: 'stretch', defaultFocus: true, disabled: !canAct, onSelect: () => this.send('host') }),
            preact.h("div", { className: 'CoopMenu_hint' }, 'Opens a room for your zoo. Friends can then join from their own Co-op menu.'),
            preact.h(Divider, null),
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Join a friend'),
            this.searchBox(hosting.length + playing.length),
            hosting.map((f) => this.friendRow(f, s, 'Hosting a co-op room',
                preact.h(Button, { label: literal('Join'), modifiers: 'autoWidth', disabled: !canAct, onSelect: () => this.send('joinlobby', f.lobby) }))),
            playing.map((f) => this.friendRow(f, s, 'Playing Planet Zoo 2, not hosting', null)),
            s.friendsAvailable && hosting.length === 0 && playing.length === 0 &&
                preact.h("div", { className: 'CoopMenu_hint' }, 'No friends are hosting right now. Ask a friend to press Host Co-op.'),
            !s.friendsAvailable &&
                preact.h("div", { className: 'CoopMenu_hint' }, "Can't read your Steam friends list right now. You can still join with a room code."),
            preact.h(Divider, null),
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Join with a room code'),
            preact.h("div", { className: 'CoopMenu_row' },
                preact.h(InputField, { rootClassName: 'CoopMenu_codeInput', promptText: literal('PZ-xxxxxx'), text: this.state.joinCode, maxInputLength: 12, oskTitle: 'Room code', onChange: (e) => this.setState({ joinCode: e.text }), onCommit: (e) => this.joinWithCode(e.text) }),
                preact.h(Button, { label: literal('Join'), modifiers: 'autoWidth', disabled: !canAct || this.state.joinCode.trim() === '', onSelect: () => this.joinWithCode(this.state.joinCode) })),
            preact.h("div", { className: 'CoopMenu_hint' }, "Joining loads your friend's zoo in place of this one. Save first if you want to keep it."));
    }
    joinWithCode(code) {
        const trimmed = String(code || '').trim();
        if (trimmed !== '') {
            this.setState({ joinCode: trimmed });
            this.send('join', trimmed);
        }
    }
    copyCode() {
        this.send('copy');
        this.setState({ copiedAt: Date.now() });
        this.refreshLater(2000);
    }
    resyncZoo() {
        this.send('resync');
        this.setState({ resyncedAt: Date.now() });
        this.refreshLater(4000);
    }
    choosePrivacy(choice) {
        this.send('privacy', choice);
        this.setState({ privacyChoice: choice, privacyAt: Date.now() });
        this.refreshLater(OPTIMISTIC_MS);
    }
    invite(id) {
        this.send('invite', id);
        this.setState({ invitedNow: { ...this.state.invitedNow, [id]: true } });
    }
    renderHost(s) {
        const now = Date.now();
        const privacy = this.state.privacyChoice && now - this.state.privacyAt < OPTIMISTIC_MS ? this.state.privacyChoice : (s.privacy || 'friends');
        const copied = now - this.state.copiedAt < 2000;
        const friends = this.filtered(s.friends || []);
        const privacyButton = (choice, label, icon) => {
            const selected = privacy === choice;
            return preact.h(Button, { rootClassName: 'CoopMenu_segment', icon: selected ? ICON.tick : icon, label: literal(label), modifiers: classNames('stretch center', { white: !selected }), onSelect: () => selected || this.choosePrivacy(choice) });
        };
        return preact.h("div", { className: 'CoopMenu_section' },
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Room code'),
            preact.h("div", { className: 'CoopMenu_row' },
                preact.h("div", { className: 'CoopMenu_code' }, s.code || '...'),
                preact.h(Button, { icon: copied ? ICON.tick : ICON.copy, label: literal(copied ? 'Copied!' : 'Copy'), modifiers: 'autoWidth', defaultFocus: true, disabled: !s.code, onSelect: () => this.copyCode() })),
            preact.h("div", { className: 'CoopMenu_hint' }, 'Share this code with a friend, or invite them below.'),
            preact.h(Divider, null),
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Players'),
            this.playerRow(s.selfId, s.self || 'You', 'Host', s, 'self'),
            s.connected
                ? this.playerRow(s.partnerId, s.partner || 'Friend', `Guest${typeof s.ping === 'number' ? ` · ${s.ping} ms` : ''}`, s, 'partner')
                : preact.h("div", { className: 'CoopMenu_row', key: 'free' },
                    preact.h("div", { className: 'CoopMenu_avatar free' }, preact.h("div", { className: 'CoopMenu_avatarInitial' }, '+')),
                    preact.h("div", { className: 'CoopMenu_rowText' },
                        preact.h("div", { className: 'CoopMenu_name' }, 'Free slot'),
                        preact.h("div", { className: 'CoopMenu_detail' }, 'Waiting for a friend'))),
            (s.connected || s.loopback) && this.renderTogether(s),
            s.connected && preact.h(Button, { label: literal(now - this.state.resyncedAt < 4000 ? 'Sending fresh zoo snapshot...' : 'Resync zoo for guest'), modifiers: 'stretch white', disabled: now - this.state.resyncedAt < 4000, onSelect: () => this.resyncZoo() }),
            s.connected && preact.h("div", { className: 'CoopMenu_hint' }, 'Saves and re-sends your current zoo if anything ever drifts out of sync.'),
            preact.h(Divider, null),
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Who can join'),
            preact.h("div", { className: 'CoopMenu_segmented' },
                privacyButton('friends', 'Friends only', ICON.lock),
                privacyButton('public', 'Anyone with the code', ICON.unlock)),
            preact.h("div", { className: 'CoopMenu_hint' }, privacy === 'public'
                ? 'Anyone who has the room code can join, including people who are not your Steam friends.'
                : 'Only your Steam friends can join, using the code or the Join button in their Co-op menu.'),
            !s.connected && preact.h(Divider, null),
            !s.connected && preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Solo test mode'),
            !s.connected &&
                preact.h(Button, { icon: s.loopback ? ICON.tick : undefined, label: literal(s.loopback ? 'Mirroring your builds' : 'Mirror my builds'), modifiers: classNames('stretch', { white: !s.loopback }), onSelect: () => this.send('loopback', s.loopback ? 'off' : 'on') }),
            !s.connected &&
                preact.h("div", { className: 'CoopMenu_hint' }, 'For testing without a friend: each building you place or delete is copied 50 m east, as if a friend did it.'),
            !s.connected && s.loopback &&
                preact.h(Button, { label: literal('Test join (reloads this zoo)'), modifiers: 'stretch white', onSelect: () => this.send('testjoin') }),
            !s.connected && s.loopback &&
                preact.h("div", { className: 'CoopMenu_hint' }, 'Saves this zoo the way the host does for a joining friend, then loads that copy. Save your zoo normally first.'),
            !s.connected && preact.h(Divider, null),
            !s.connected && preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Invite friends'),
            !s.connected && !s.friendsAvailable &&
                preact.h("div", { className: 'CoopMenu_hint' }, 'Steam friends list unavailable. Share the room code instead.'),
            !s.connected && s.friendsAvailable && this.searchBox((s.friends || []).length),
            !s.connected && s.friendsAvailable && (s.friends || []).length === 0 &&
                preact.h("div", { className: 'CoopMenu_hint' }, 'None of your Steam friends are online.'),
            !s.connected && s.friendsAvailable && (s.friends || []).length > 0 && friends.length === 0 &&
                preact.h("div", { className: 'CoopMenu_hint' }, 'No friends match your search.'),
            !s.connected && s.friendsAvailable &&
                friends.map((f) => {
                    const invited = f.invited || this.state.invitedNow[f.id];
                    return this.friendRow(f, s, f.playing ? 'Playing Planet Zoo 2' : 'Online',
                        preact.h(Button, { icon: invited ? ICON.tick : undefined, label: literal(invited ? 'Invited' : 'Invite'), modifiers: classNames('autoWidth', { white: invited }), disabled: invited, onSelect: () => this.invite(f.id) }));
                }));
    }
    renderClient(s) {
        return preact.h("div", { className: 'CoopMenu_section' },
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Players'),
            this.playerRow(s.partnerId, s.partner || 'Host', 'Host', s, 'partner'),
            this.playerRow(s.selfId, s.self || 'You', `Guest${typeof s.ping === 'number' ? ` · ${s.ping} ms` : ''}`, s, 'self'),
            s.connected && this.renderTogether(s));
    }
    // Walking together & camera jump (pz2coop.presence.lua): view friend in build camera or walk beside them.
    renderTogether(s) {
        return preact.h("div", { key: 'together' },
            preact.h(Divider, null),
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Find your friend'),
            preact.h("div", { className: 'CoopMenu_segmented' },
                preact.h(Button, { rootClassName: 'CoopMenu_segment', label: literal('Jump camera'), modifiers: 'stretch center white', disabled: !s.friendPose, onSelect: () => this.send('viewfriend') }),
                preact.h(Button, { rootClassName: 'CoopMenu_segment', label: literal('Walk beside'), modifiers: 'stretch center', defaultFocus: s.role === 'client', disabled: !s.friendPose, onSelect: () => this.send('gotofriend') })),
            preact.h("div", { className: 'CoopMenu_hint' }, s.friendPose
                ? 'Jump camera flies your build camera to your friend; Walk beside lands on foot next to them.'
                : 'Waiting for your friend\'s position...'),
            preact.h("div", { className: 'CoopMenu_hint' }, 'On foot, press C to switch between first and third person.'));
    }
    renderVehicleTools(s) {
        return preact.h("div", { key: 'vehicleTools', className: 'CoopMenu_section' },
            preact.h(Divider, null),
            preact.h("div", { className: 'CoopMenu_sectionTitle' }, 'Research Vehicle'),
            preact.h("div", { className: 'CoopMenu_segmented' },
                preact.h(Button, { rootClassName: 'CoopMenu_segment', label: literal('Call vehicle nearby'), modifiers: 'stretch center', onSelect: () => this.send('vrecall') }),
                preact.h(Button, { rootClassName: 'CoopMenu_segment', label: literal('Return to Outpost'), modifiers: 'stretch center white', onSelect: () => this.send('vrecall', 'outpost') })),
            preact.h("div", { className: 'CoopMenu_hint' }, 'Inside the vehicle: Q (or D-Pad Up) swaps seats, L toggles headlights, C switches camera, F opens Photo Mode.'));
    }
});
