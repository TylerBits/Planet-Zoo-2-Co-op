// PZ2-Coop: Vanilla-styled 3-page x 8-wedge Radial Emote & Prop Wheel for Explore on Foot.
// Reuses Planet Zoo 2's native RadialMenuContent, RadialItem, PaperPanelBackground, Paginator, and RadialMenu.css
// so the wheel looks and feels identical to the base game's radial wheel.
// State: Lua publishes JSON in 'ui' data store key `pz2coopEmoteWheel` ({open, page, activeProp, activeEmote}).
// Actions: sendEvent('PauseMenu_UI_Select', 'pz2coop_emote:<id>' | 'pz2coop_emotepage:<1..3>' | 'pz2coop_emoteclose').
import * as preact from '/js/common/lib/preact.js';
import * as Focusable from '/js/common/components/Focusable.js';
import * as Audio from '/js/common/core/Audio.js';
import { sendEvent } from '/js/common/core/Engine.js';
import * as Input from '/js/common/core/Input.js';
import { currentInputMethodIs } from '/js/common/core/Input.js';
import { InputMethod, InputName } from '/js/common/core/InputTypes.js';
import { translate } from '/js/common/core/Localisation.js';
import { classNames } from '/js/common/lib/classnames.js';
import { loadCSS } from '/js/common/util/CSSUtil.js';
import { DataStoreHelper } from '/js/common/util/DataStoreHelper.js';
import { bindDSPropsToState } from '/js/common/util/DataStoreUtil.js';
import { isLeftClick } from '/js/common/util/MouseButton.js';
import { clamp, RAD_TO_DEG } from '/js/common/util/MathUtil.js';
import { ControlContextPriority } from '/js/config/ControlContextPriority.js';
import { Paginator } from '/js/project/components/Paginator.js';
import { PaperPanelBackground } from '/js/project/components/PaperPanelBackground.js';
import { RadialItem } from '/js/project/modules/RadialMenu/RadialItem.js';
import * as RadialMenuAccess from '/js/project/modules/RadialMenu/RadialMenuAccess.js';
import { VALID_LOGICAL_DISTANCE } from '/js/project/modules/RadialMenu/RadialMenuConfig.js';
import { RadialMenuContent } from '/js/project/modules/RadialMenu/RadialMenuContent.js';
import { ProjectInput } from '/js/project/utils/ProjectInput.js';
import { UI_CONTEXT } from '/js/project/utils/ContextUtil.js';
loadCSS('project/components/RadialMenu/RadialMenu');
loadCSS('project/components/PZ2Coop/EmoteWheel');

export function literal(text) {
    return `[STRING_LITERAL:Value=|${String(text ?? '').replace(/[|\[\]]/g, '')}|]`;
}

// 3 pages x 8 wedges matching Planet Zoo 2's vanilla radial colour tabs and 40x40 white silhouette icon set.
export const EMOTE_PAGES = [
    {
        id: 1,
        tabMod: 'radialTab-tools',
        title: 'Social',
        centerIcon: 'img/icons/Icon_Guests.svg',
        items: [
            { id: 'cheer', label: 'Cheer', icon: 'PZ2Coop_Cheer' },
            { id: 'clap', label: 'Clap', icon: 'PZ2Coop_Clap' },
            { id: 'point', label: 'Point', icon: 'PZ2Coop_Point' },
            { id: 'laugh', label: 'Laugh', icon: 'PZ2Coop_Laugh' },
            { id: 'cute', label: 'Cute / Aww', icon: 'Icon_Heart' },
            { id: 'dance', label: 'Groove', icon: 'IconSpeakerMusic' },
            { id: 'phone', label: 'Check Phone', icon: 'PZ2Coop_Phone' },
            { id: 'photo', label: 'Photo Pose', icon: 'Icon_TakePhoto' },
        ],
    },
    {
        id: 2,
        tabMod: 'radialTab-build',
        title: 'Reactions',
        centerIcon: 'img/icons/Icon_FaceHappy.svg',
        items: [
            { id: 'excited', label: 'Excited!', icon: 'Icon_FancyStarFill' },
            { id: 'spooked', label: 'Spooked', icon: 'PZ2Coop_Spooked' },
            { id: 'disapprove', label: 'Disapprove', icon: 'IconThumbsDown' },
            { id: 'bored', label: 'Bored', icon: 'Icon_FaceNeutral' },
            { id: 'sad', label: 'Sad', icon: 'Icon_FaceSad' },
            { id: 'taunt', label: 'Taunt Glass', icon: 'PZ2Coop_Taunt' },
            { id: 'calm', label: 'Calm Down', icon: 'PZ2Coop_Calm' },
            { id: 'sick', label: 'Sick', icon: 'IconVomitCleanliness' },
        ],
    },
    {
        id: 3,
        tabMod: 'radialTab-management',
        title: 'Props',
        centerIcon: 'img/icons/IconMerch.svg',
        items: [
            { id: 'prop_umbrella', label: 'Umbrella', icon: 'PZ2Coop_Umbrella' },
            { id: 'prop_coffee', label: 'Coffee', icon: 'PZ2Coop_Coffee' },
            { id: 'prop_burger', label: 'Burger', icon: 'IconFood' },
            { id: 'prop_icecream', label: 'Ice Cream', icon: 'PZ2Coop_IceCream' },
            { id: 'prop_slushie', label: 'Slushie', icon: 'IconDrink' },
            { id: 'prop_balloon', label: 'Balloon', icon: 'PZ2Coop_Balloon' },
            { id: 'prop_bag', label: 'Shop Bag', icon: 'IconMerch' },
            { id: 'prop_clear', label: 'Clear Prop', icon: 'Icon_Close', modifiers: 'negative' },
        ],
    },
];

export function parseEmoteState(json) {
    try {
        const s = typeof json === 'string' && json !== '' ? JSON.parse(json) : null;
        return s && typeof s === 'object' ? s : { open: false, page: 1 };
    }
    catch (e) {
        return { open: false, page: 1 };
    }
}

// Converts a 2D vector (dx right, dy down) into clockwise 12-o'clock-first segment index [0..count-1] and angle [0..360).
export function polarSegmentIndex(dx, dy, count) {
    const n = Math.max(1, count || 8);
    let angle = (Math.atan2(dy, dx) * (180 / Math.PI)) + 90;
    if (angle < 0) {
        angle += 360;
    }
    const step = 360 / n;
    let idx = Math.floor((angle + step * 0.5) / step);
    if (idx < 0) {
        idx = n - 1;
    }
    else if (idx >= n) {
        idx = 0;
    }
    return { index: idx, angle };
}

export const EmoteWheel = Focusable.decorate(class EmoteWheel extends preact.Component {
    static defaultProps = {
        componentName: 'RadialMenuNew',
        outcome: 'Radial',
    };
    _dataHelper = new DataStoreHelper();
    _componentName = 'UI_PZ2CoopEmoteWheel';
    _radialRequestName = Symbol('UI_PZ2CoopEmoteWheel');
    _visibleControlContext = null;
    _logicalStick = null;
    _animFrameId = -1;
    _contextActive = false;
    state = {
        activeSelectionIndex: -1,
        lastAngle: undefined,
    };

    componentWillMount() {
        bindDSPropsToState(this, UI_CONTEXT, this._dataHelper, 'pz2coopEmoteWheel');
        this._dataHelper.addPropertyListener(UI_CONTEXT, 'pz2coopExploreUI', this._onExploreUIState);
        this._dataHelper.getAllPropertiesNow();
    }

    componentDidMount() {
        Input.createGameOwnerControlContext(this._componentName, ControlContextPriority.RadialMenuAxis, (context) => {
            this._visibleControlContext = context;
            this._logicalStick = context.addPosition(InputName.Thumb_Left_Position);
            context.addButton(InputName.Cancel);
            context.addButton(InputName.Select);
            context.addButton(InputName.Up);
            context.addButton(InputName.Down);
            context.addButton(InputName.Left);
            context.addButton(InputName.Right);
            context.addButton(InputName.TabPrev);
            context.addButton(InputName.TabNext);
            context.addButton(ProjectInput.RadialMenuTabPrev);
            context.addButton(ProjectInput.RadialMenuTabNext);
            context.addButton(ProjectInput.RadialMenuOptionNext);
            context.addButton(ProjectInput.RadialMenuOptionPrev);
            if (this._contextActive) {
                context.enable();
            }
            else {
                context.disable();
            }
        });
    }

    componentWillUnmount() {
        this._setActive(false);
        this._setExploreUIClass('idle');
        this._dataHelper.clear();
        this._visibleControlContext?.destroy();
        this._visibleControlContext = null;
        this._logicalStick = null;
    }

    _onExploreUIState = (mode) => {
        this._setExploreUIClass(mode);
    };

    _setExploreUIClass(mode) {
        if (typeof document === 'undefined' || !document.body || !document.body.classList) {
            return;
        }
        const cl = document.body.classList;
        cl.remove('pz2coop-explore-ui-entering', 'pz2coop-explore-ui-visible', 'pz2coop-explore-ui-exiting');
        if (mode === 'entering' || mode === 'visible' || mode === 'exiting') {
            cl.add(`pz2coop-explore-ui-${mode}`);
        }
    }

    _setActive(active) {
        if (this._contextActive === active) {
            return;
        }
        this._contextActive = active;
        if (active) {
            this._visibleControlContext?.enable();
            RadialMenuAccess.requestRadialDisable(this._radialRequestName);
            document.addEventListener('wheel', this._onMouseWheel);
            this._startFrameLoop();
            Audio.onAction(this, 'show');
        }
        else {
            this._visibleControlContext?.disable();
            RadialMenuAccess.clearRadialDisable(this._radialRequestName);
            document.removeEventListener('wheel', this._onMouseWheel);
            this._stopFrameLoop();
            if (this.state.activeSelectionIndex !== -1 || this.state.lastAngle !== undefined) {
                this.setState({ activeSelectionIndex: -1, lastAngle: undefined });
            }
            Audio.onAction(this, 'hide');
        }
    }

    _startFrameLoop() {
        this._stopFrameLoop();
        const tick = () => {
            if (!this._contextActive) {
                return;
            }
            if (this._logicalStick && currentInputMethodIs(InputMethod.Gamepad)) {
                const v = this._logicalStick.getValueAsCartesian();
                const dist = Math.min(1, Math.sqrt(v.x * v.x + v.y * v.y));
                if (dist >= VALID_LOGICAL_DISTANCE) {
                    const page = this._currentPage();
                    const { index, angle } = polarSegmentIndex(v.x, -v.y, page.items.length);
                    if (index !== this.state.activeSelectionIndex || Math.abs((this.state.lastAngle ?? -999) - angle) > 1) {
                        this.setState({ activeSelectionIndex: index, lastAngle: angle });
                    }
                }
            }
            this._animFrameId = requestAnimationFrame(tick);
        };
        this._animFrameId = requestAnimationFrame(tick);
    }

    _stopFrameLoop() {
        if (this._animFrameId !== -1) {
            cancelAnimationFrame(this._animFrameId);
            this._animFrameId = -1;
        }
    }

    _currentPageIndex() {
        const st = parseEmoteState(this.state.pz2coopEmoteWheel);
        return clamp(0, EMOTE_PAGES.length - 1, (st.page || 1) - 1);
    }

    _currentPage() {
        return EMOTE_PAGES[this._currentPageIndex()];
    }

    _send(cmd, arg) {
        sendEvent('PauseMenu_UI_Select', arg === undefined ? `pz2coop_${cmd}` : `pz2coop_${cmd}:${arg}`);
    }

    _setPageIndex = (index, wrap = false) => {
        let next = index;
        if (wrap) {
            next = ((next % EMOTE_PAGES.length) + EMOTE_PAGES.length) % EMOTE_PAGES.length;
        }
        else {
            next = clamp(0, EMOTE_PAGES.length - 1, next);
        }
        this.setState({ activeSelectionIndex: -1, lastAngle: undefined });
        this._send('emotepage', String(EMOTE_PAGES[next].id));
    };

    _onSelectPreviewTab = (pageId) => {
        const idx = EMOTE_PAGES.findIndex((p) => p.id === pageId);
        if (idx >= 0) {
            this._setPageIndex(idx, false);
        }
    };

    _stepPage(delta) {
        this._setPageIndex(this._currentPageIndex() + delta, true);
    }

    _setHover = (index) => {
        if (index !== this.state.activeSelectionIndex) {
            const page = this._currentPage();
            const angle = index >= 0 ? (index * (360 / page.items.length)) : undefined;
            this.setState({ activeSelectionIndex: index, lastAngle: angle });
        }
    };

    _selectSegment = (index) => {
        const page = this._currentPage();
        if (index < 0 || index >= page.items.length) {
            return;
        }
        const item = page.items[index];
        if (!item) {
            return;
        }
        Audio.onAction(this, 'select', item.id);
        this._send('emote', item.id);
        this._send('emoteclose');
    };

    _onMouseWheel = (e) => {
        if (!this._contextActive) {
            return;
        }
        this._stepPage(e.deltaY > 0 ? 1 : -1);
    };

    // Polar angle fallback: smoothly tracks mouse anywhere over the active wheel ring (including between hitboxes).
    _onMouseMove = (e) => {
        if (!this._contextActive) {
            return;
        }
        const cx = window.innerWidth * 0.5;
        const cy = window.innerHeight * 0.5;
        const dx = e.clientX - cx;
        const dy = e.clientY - cy;
        const r = Math.sqrt(dx * dx + dy * dy);
        const minDim = Math.min(window.innerWidth, window.innerHeight);
        const innerR = minDim * 0.08;
        const outerR = minDim * 0.34;
        if (r >= innerR && r <= outerR) {
            const page = this._currentPage();
            const { index, angle } = polarSegmentIndex(dx, dy, page.items.length);
            if (index !== this.state.activeSelectionIndex) {
                this.setState({ activeSelectionIndex: index, lastAngle: angle });
            }
        }
        else if (r < innerR && this.state.activeSelectionIndex !== -1) {
            this.setState({ activeSelectionIndex: -1, lastAngle: undefined });
        }
    };

    _onMouseDown = (e) => {
        if (!this._contextActive) {
            return;
        }
        if (!isLeftClick(e.button)) {
            this._send('emoteclose');
            return;
        }
        if (e.target === e.currentTarget) {
            if (this.state.activeSelectionIndex >= 0) {
                this._selectSegment(this.state.activeSelectionIndex);
            }
            else {
                this._send('emoteclose');
            }
        }
    };

    handleInput(e) {
        const st = parseEmoteState(this.state.pz2coopEmoteWheel);
        if (!st.open || !e.button || !e.button.isPressed()) {
            return false;
        }
        if (e.inputName == InputName.Cancel) {
            this._send('emoteclose');
            return true;
        }
        if (e.inputName == InputName.Select) {
            if (this.state.activeSelectionIndex >= 0) {
                this._selectSegment(this.state.activeSelectionIndex);
                return true;
            }
            return false;
        }
        const page = this._currentPage();
        const count = page.items.length;
        if (e.inputName == ProjectInput.RadialMenuOptionNext || e.inputName == InputName.Right || e.inputName == InputName.Down) {
            const next = this.state.activeSelectionIndex < 0 ? 0 : (this.state.activeSelectionIndex + 1) % count;
            this._setHover(next);
            return true;
        }
        if (e.inputName == ProjectInput.RadialMenuOptionPrev || e.inputName == InputName.Left || e.inputName == InputName.Up) {
            const prev = this.state.activeSelectionIndex < 0 ? count - 1 : (this.state.activeSelectionIndex + count - 1) % count;
            this._setHover(prev);
            return true;
        }
        if (e.inputName == ProjectInput.RadialMenuTabNext || e.inputName == InputName.TabNext) {
            this._stepPage(1);
            return true;
        }
        if (e.inputName == ProjectInput.RadialMenuTabPrev || e.inputName == InputName.TabPrev) {
            this._stepPage(-1);
            return true;
        }
        return false;
    }

    render(props, state) {
        const st = parseEmoteState(state.pz2coopEmoteWheel);
        const isOpen = Boolean(st.open);
        this._setActive(isOpen);
        if (!isOpen) {
            return null;
        }
        const pageIdx = clamp(0, EMOTE_PAGES.length - 1, (st.page || 1) - 1);
        const activePage = EMOTE_PAGES[pageIdx];
        const visibleMod = 'visible';

        const content = EMOTE_PAGES.map((page, idx) => {
            const isPreview = idx !== pageIdx;
            const left = idx < pageIdx;
            const right = idx > pageIdx;
            const isVisible = idx >= (pageIdx - 1) && idx <= (pageIdx + 1);
            const hoveredItem = (!isPreview && state.activeSelectionIndex >= 0) ? page.items[state.activeSelectionIndex] : null;
            const centerLabel = literal(hoveredItem ? hoveredItem.label : page.title);
            const modifiers = classNames(page.tabMod, { isPreview });
            let inputName = undefined;
            if (isVisible) {
                if (left) {
                    inputName = ProjectInput.RadialMenuTabPrev;
                }
                else if (right) {
                    inputName = ProjectInput.RadialMenuTabNext;
                }
            }
            return preact.h(RadialMenuContent, {
                key: page.id,
                userData: page.id,
                icon: page.centerIcon,
                label: centerLabel,
                onMouseDownMenu: isPreview ? this._onSelectPreviewTab : undefined,
                preview: isPreview,
                modifiers: classNames({ left, right }, modifiers),
                arrowRotation: isPreview ? undefined : state.lastAngle,
                isVisible: isVisible,
                inputName: inputName,
                segments: page.items.map((item, j) => {
                    const selectable = !isPreview;
                    const isEquipped = st.activeProp === item.id || st.activeEmote === item.id;
                    const itemMods = classNames(item.modifiers, isEquipped ? 'warning' : undefined, modifiers);
                    return preact.h(RadialItem, {
                        key: item.id,
                        id: item.id,
                        icon: item.icon,
                        label: literal(item.label),
                        modifiers: itemMods,
                        onClick: this._selectSegment,
                        onHover: this._setHover,
                        enableHitBoxes: true,
                        selectable: selectable,
                        selected: selectable && j === state.activeSelectionIndex,
                        segmentIndex: j,
                        totalSegments: page.items.length,
                        isVisible: true,
                        allowInputIcon: true,
                    });
                }),
            });
        });

        return preact.h('div', {
            className: classNames('RadialMenu_root', 'PZ2CoopEmoteWheel_root', visibleMod),
            onMouseMove: this._onMouseMove,
            onMouseDown: this._onMouseDown,
        },
            preact.h('div', { className: classNames('RadialMenu_header', visibleMod) },
                preact.h(PaperPanelBackground, null),
                preact.h('div', { className: 'RadialMenu_headerLabel' }, translate(literal(activePage.title))),
                preact.h('div', { className: 'RadialMenu_headerSubLabel' },
                    translate(literal('Scroll / Click side wheels for pages  •  B / Esc to close')))),
            content,
            preact.h('div', { className: classNames('RadialMenu_paginator', visibleMod) },
                preact.h(Paginator, {
                    numberOfPages: EMOTE_PAGES.length,
                    selectedIndex: pageIdx,
                    onChange: (idx) => this._setPageIndex(idx, false),
                })));
    }
});
