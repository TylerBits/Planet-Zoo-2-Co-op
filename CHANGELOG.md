# Changelog

Feature status follows `docs/HANDOFF.md` "Current state". "Not 2-PC tested" means the feature works solo or
offline but has not yet been confirmed between two players.

## 0.4.0 (2026-11-28)

This release was packaged without a fresh live autotest run (offline tests pass 23/23).

### New
- **4-seat Research Vehicles:** the buggy works in every Sandbox, Challenge and Career zoo with the Research
  Outpost unlocked. It has a driver, a front passenger and two back passengers, with seat prompts at each door,
  `Q` / D-pad Up to swap seats, passenger first- and third-person cameras, seated emotes, headlights (`L`),
  door exits that avoid obstacles, auto-opening safari and habitat gates, and vehicle recall. Solo seating and
  clipping are verified; multiplayer ride-along is not 2-PC tested yet.
- **Career / Story mode sync:** chapter, stage and objective progress stays in step between Host and Guest, so
  shared tutorial steps no longer softlock or drift apart. Not 2-PC tested.
- **Terrain sync:** terrain brush strokes, shape stamps (cube, sphere, cylinder, pyramid, wedge) and height stamps
  (mountains, valleys, canyons) now sync. Remote terrain edits wait while you are sculpting, which prevents a
  known terrain-preview crash. Not 2-PC tested.
- **World interactions:** sit on benches, chairs and picnic tables (both sides), walk up to seats naturally,
  open single and double scenery doors, and hold props in hand.
- **Walk together:** head tracking follows the camera with natural neck limits, avatars follow slopes and stairs
  more smoothly, avatars float in deep water, and you can walk through scenery door frames, archways and glass
  tunnel gates. Aquarium staff doors stay blocked.
- **Premade blueprints** from the game's own database are sent whole, including habitat, roof net, decoration,
  water and terrain edits. Offline only, NOT verified in game.

### Fixed
- Premade aviaries no longer arrive as several copies, as copies with only walls and a net, or without their
  terrain changes. Offline only, NOT verified in game.
- Placing a friend's habitat no longer removes the roof net from a neighbouring habitat.
- Mirrored paths no longer land 83 cm too low, and drawing your own path right after a friend's edit is no
  longer dropped. Paths are still PARTIAL (see Known issues).
- Batch demolishes (Multi-Select) now send every selected part, not only one of them.
- A friend's blueprint now flattens and joins the terrain the same way the game does for your own.
- The terrain grid preview no longer stays visible after a friend places a blueprint.
- Name tags no longer show a localisation parse error for player names.
- Animals that drift far from their position on the host are corrected, and a habitat animal missing on the
  Guest is spawned once.
- "Return to Menu" from a Career or Scenario completion screen is now handled by the save guard.

### Known issues
- Paths: chunks can be missing, duplicated or left behind, and undo/redo of path edits is unreliable.
- Fences and habitat walls are not applied on the receiving side (turned off: rebuilding them froze the game).
- Steam invite join, redo (`Ctrl+Y`), and lake removal/undo still need 2-PC testing.

## 0.3.0 (2026-11-26)

- Initial public release.
