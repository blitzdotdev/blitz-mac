# Screenshots Tab Design

## Current Model

The screenshots tab is a direct track editor. Users and agents work against per-locale, per-display 10-slot tracks that are loaded from App Store Connect, edited locally, and synced on save.

The old asset-library workflow is removed from the runtime code and from the MCP surface. Imported files are only an implementation detail used to persist local screenshots for the active project before upload.

## User-Facing Behavior

- No visible asset tray or staging library
- Import or drop files directly into track slots
- Remove a slot in place
- Reorder the track in memory before saving
- Save pushes the prepared track state to App Store Connect

## Agent-Facing MCP Surface

Agents should use this flow:

1. `screenshots_switch_localization`
2. `screenshots_put_track_slot`
3. `screenshots_remove_track_slot`
4. `screenshots_reorder_track`
5. `screenshots_save`

`screenshots_reorder_track` accepts a full 10-element permutation of current 0-based slot positions. Example:

```json
[0, 2, 1, 4, 3, 5, 6, 7, 8, 9]
```

That means:

- new slot 0 gets old slot 0
- new slot 1 gets old slot 2
- new slot 2 gets old slot 1
- new slot 3 gets old slot 4
- new slot 4 gets old slot 3

## State Inspection

`get_tab_state(tab: "screenshots")` now exposes:

- selected locale
- available locales
- remote screenshot sets
- known display types
- per-display staged tracks
- slot-by-slot staged state, including source, file name, sync status, and upload errors

## Notes

The project still stores imported local screenshots under the project screenshots directory so they can be staged, previewed, and uploaded reliably. That storage is internal; it is no longer a first-class UX or MCP abstraction.
