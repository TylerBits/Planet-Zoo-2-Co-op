// PZ2-Coop insertions into the vanilla main menu (UIGameface/js/project/modules/Frontend/HomeButtons.js).
// Row 1 becomes Resume | My Saves | Join Friends inside the vanilla container width; the row is now
// always shown so a player with no saves still gets Join Friends. Format: see pausemenu_patch.js
// ("@@ replace <anchor>" swaps the anchor for the section's text).
import { JoinFriendsCard } from '/js/project/modules/PZ2Coop/JoinFriends.js';
@@ replace (state.resumeSaveContext || state.showSaves) &&
true &&
@@ after userData: FrontendMode.MyZoos, onSelect: props.onModeSelect })
,
                    preact.h(JoinFriendsCard, { key: 'joinFriends', fill: !state.resumeSaveContext })
