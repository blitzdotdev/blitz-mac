# Screenshots Tab Redesign — Implementation Plan

## Context

The screenshots tab currently has a simple flow: pick local files → validate → drag to reorder → upload all to ASC. It shows uploaded ASC screenshots as a read-only section. With the new `@blitzdev/screenshot-generator` skill, AI agents can now generate promotional screenshots — the tab needs a proper asset management UX with a "track" paradigm (like a video editor timeline) so both users and agents can manage, stage, and upload screenshots.

## Layout

```
┌──────────┬───────────────────────────────────────────┐
│          │                                           │
│  ASSET   │           DETAIL VIEW (~60%)              │
│ LIBRARY  │    (selected asset shown large)           │
│  (220pt) │                                           │
│          ├───────────────────────────────────────────┤
│ [iPhone] │                                           │
│ [iPad]   │  TRACK (10 slots, horizontal scroll)      │
│          │  [1 ✓][2 ✓][3 ●][4  ][5  ]...[10  ]     │
│  file1   │  green=synced  orange=changed              │
│  file2   │                                           │
│  file3   │                          [Save] (grayed   │
│          │                           if no changes)  │
│ [+ Add]  │                                           │
└──────────┴───────────────────────────────────────────┘
```

- **Left panel (220pt fixed):** Device picker + vertical list of local PNG/JPEG assets from `~/.blitz/projects/{projectId}/screenshots/`
- **Right top (~60%):** Detail view of selected asset/slot shown large. Empty state if nothing selected.
- **Right bottom (~40%, min 200pt):** Horizontal scrolling track with 10 numbered slots. Slots show thumbnail + status badge.

## Design Decisions

1. **Track is fully local until "Save".** On load, populate track from ASC-fetched screenshots. All edits (add, remove, reorder) are local. Nothing touches ASC until the user clicks "Save". This means reordering is NOT destructive from the user's perspective — they freely drag slots around. The Save action computes a diff and syncs to ASC (delete removed, upload new, re-upload reordered).

2. **Save button is disabled when track matches ASC state.** We snapshot the ASC state on load as `savedTrackState`. Compare current track to saved state — if identical, Save is grayed out. Any change (add, remove, reorder) enables it.

3. **Track is per-device-type.** Switching device tab saves nothing — just loads that device's track from ASC. Unsaved changes on the previous device are preserved in memory so switching back restores them (with a warning dot on the device picker if there are unsaved changes).

4. **No FSEvents file watcher for v1.** Scan local directory on appear + manual refresh.

5. **Save sync algorithm:**
   - Compare current track slots vs `savedTrackState`
   - Delete from ASC: any screenshot in saved state but not in current track
   - Upload to ASC: any local asset in current track not in saved state
   - Reorder: if the set of ASC IDs is the same but order changed, delete all + re-upload in new order
   - After sync completes, reload track from ASC to confirm, update `savedTrackState`

## Files to Modify (6 files)

### 1. `src/BlitzPaths.swift` — Add screenshots path

```swift
static func screenshots(projectId: String) -> URL {
    projects.appendingPathComponent(projectId).appendingPathComponent("screenshots")
}
```

### 2. `src/services/AppStoreConnectService.swift` — Add delete method

```swift
func deleteScreenshot(screenshotId: String) async throws {
    try await delete(path: "appScreenshots/\(screenshotId)")
}
```

Uses the existing `private func delete(path:)` at line 177.

### 3. `src/services/ASCManager.swift` — Add track state + methods

**New models (top-level, not private — MCP tools need access):**

```swift
struct TrackSlot: Identifiable, Equatable {
    let id: String              // UUID for local, ASC id for uploaded
    var localPath: String?      // file path for local assets
    var localImage: NSImage?    // loaded thumbnail
    var ascScreenshot: ASCScreenshot?  // present if from ASC
    var isFromASC: Bool         // true if this slot was loaded from ASC

    static func == (lhs: TrackSlot, rhs: TrackSlot) -> Bool {
        lhs.id == rhs.id
    }
}

struct LocalScreenshotAsset: Identifiable {
    let id: UUID
    let url: URL
    let image: NSImage
    let fileName: String
}
```

**New state properties:**

```swift
// Track state per device type — current (editable) and saved (last synced to ASC)
var trackSlots: [String: [TrackSlot?]] = [:]        // keyed by ascDisplayType, 10-element arrays
var savedTrackState: [String: [TrackSlot?]] = [:]   // snapshot after last load/save
var localScreenshotAssets: [LocalScreenshotAsset] = []
var isSyncing = false  // true during Save operation
```

**Computed property:**

```swift
func hasUnsavedChanges(displayType: String) -> Bool {
    let current = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
    let saved = savedTrackState[displayType] ?? Array(repeating: nil, count: 10)
    // Compare slot IDs in order
    return zip(current, saved).contains { c, s in c?.id != s?.id }
}
```

**New methods:**

- `loadTrackFromASC(displayType: String)` — populates `trackSlots[displayType]` from fetched ASC screenshots, also snapshots to `savedTrackState[displayType]`
- `syncTrackToASC(displayType: String, locale: String) async` — the Save operation:
  1. Set `isSyncing = true`
  2. Compute diff between `trackSlots[displayType]` and `savedTrackState[displayType]`
  3. Delete removed screenshots from ASC
  4. If order changed for existing ASC screenshots, delete + re-upload in new order
  5. Upload new local assets in their slot positions
  6. Refetch from ASC, update both `trackSlots` and `savedTrackState`
  7. Set `isSyncing = false`
- `deleteScreenshot(screenshotId: String) async throws` — calls `service.deleteScreenshot()`
- `scanLocalAssets(projectId: String)` — scans `BlitzPaths.screenshots(projectId:)`, populates `localScreenshotAssets`
- `addAssetToTrack(displayType: String, slotIndex: Int, localPath: String)` — loads image, creates `TrackSlot` with `isFromASC: false`, places in slot
- `removeFromTrack(displayType: String, slotIndex: Int)` — nils out slot, shifts remaining left
- `reorderTrack(displayType: String, fromIndex: Int, toIndex: Int)` — moves slot with cascading displacement

### 4. `src/views/release/ScreenshotsView.swift` — Full rewrite

**Keep:** `ScreenshotDeviceType` enum (unchanged).

**Remove:** `LocalScreenshot`, `ScreenshotCategory`, all old `@State` arrays, the grid/legend/upload flow.

**New state:**

```swift
@State private var selectedDevice: ScreenshotDeviceType = .iPhone
@State private var selectedAssetId: UUID?         // selected in asset library
@State private var selectedTrackIndex: Int?       // selected in track
@State private var draggedAssetId: UUID?          // drag from asset library
@State private var draggedTrackIndex: Int?        // drag within track
@State private var importError: String?
```

**Body structure:**

```swift
ASCCredentialGate(...) {
    ASCTabContent(asc: asc, tab: .screenshots, ...) {
        HStack(spacing: 0) {
            assetLibraryPanel.frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                detailView
                Divider()
                trackView.frame(minHeight: 200)
            }
        }
    }
}
.task { await loadData() }
.onChange(of: selectedDevice) { _, _ in loadTrackForDevice() }
```

**Asset Library Panel (left):**
- Device picker (segmented) at top, with unsaved-changes dot indicator per device
- `ScrollView` + `LazyVStack` of thumbnails from `asc.localScreenshotAssets`
- Click → set `selectedAssetId`, clear `selectedTrackIndex`
- `.onDrag` on each asset item
- "Add Files" button → `NSOpenPanel`, copies to screenshots dir, re-scans

**Detail View (top right):**
- If `selectedTrackIndex` set and slot non-nil → show that image large
- Else if `selectedAssetId` set → show that asset large
- Else → `ContentUnavailableView`

**Track View (bottom right):**
- Toolbar above track: slot count, "Save" button (disabled when `!hasUnsavedChanges`, shows spinner when `isSyncing`)
- `ScrollView(.horizontal)` with `HStack` of 10 `trackSlotView(index:)` items
- Each slot ~130pt wide: index badge (1-10), thumbnail or empty placeholder, status indicator
- Status: `.green` border + "Synced" if slot matches saved state (from ASC), `.orange` border + "Changed" if new/moved/different from saved
- Delete (X) button overlay on hover
- Click slot → `selectedTrackIndex`, show in detail view
- Drop target for assets from library + reorder within track

**Drag-and-drop:**
- `TrackSlotDropDelegate: DropDelegate` — handles drops into track slots
  - From asset library: places asset as local `TrackSlot` in target slot, shifts existing slots right
  - From another track slot: cascading displacement reorder with `withAnimation`

**Save action:**
```swift
private func save() async {
    await asc.syncTrackToASC(
        displayType: selectedDevice.ascDisplayType,
        locale: "en-US"
    )
}
```

### 5. `src/services/MCPToolRegistry.swift` — Register 2 new tools, update 1

**`screenshots_add_asset`:**
- Description: "Copy a screenshot file into the project's local screenshots asset library."
- Properties: `sourcePath` (string), `fileName` (string, optional)
- Required: `["sourcePath"]`
- Category: `ascScreenshotMutation`

**`screenshots_set_track`:**
- Description: "Place a local screenshot asset into a specific track slot (1-10) for upload staging."
- Properties: `assetFileName` (string), `slotIndex` (integer 1-10), `displayType` (string, optional, default APP_IPHONE_67)
- Required: `["assetFileName", "slotIndex"]`
- Category: `ascScreenshotMutation`

**Replace `asc_upload_screenshots` with `screenshots_save`:**
- Description: "Save the current screenshot track to App Store Connect. Syncs all changes (additions, removals, reorder) for the specified device type."
- Properties: `displayType` (string, optional, default APP_IPHONE_67), `locale` (string, optional, default "en-US")
- Required: `[]`
- Category: `ascScreenshotMutation`

Keep old `asc_upload_screenshots` as a backward-compat alias that internally calls the same sync logic.

### 6. `src/services/MCPToolExecutor.swift` — Implement handlers

**`executeScreenshotsAddAsset`:**
1. Extract `sourcePath`, validate file exists
2. Get active project ID
3. Ensure `BlitzPaths.screenshots(projectId:)` exists (mkdir -p)
4. Copy file to that directory (with optional rename via `fileName`)
5. Trigger `asc.scanLocalAssets(projectId:)` to refresh UI
6. Return `{"success": true, "fileName": "..."}`

**`executeScreenshotsSetTrack`:**
1. Extract `assetFileName` and `slotIndex` (validate 1-10)
2. Locate file in local screenshots directory
3. Call `asc.addAssetToTrack(displayType:slotIndex:localPath:)` on MainActor
4. Return `{"success": true, "slot": slotIndex}`

**`executeScreenshotsSave`:**
1. Extract optional `displayType` (default APP_IPHONE_67) and `locale` (default "en-US")
2. Check `asc.hasUnsavedChanges(displayType:)` — if no changes, return `{"success": true, "message": "No changes to save"}`
3. Call `asc.syncTrackToASC(displayType:locale:)` on MainActor
4. Check `asc.writeError` for failures
5. Return `{"success": true, "synced": count}`

**Backward-compat `executeASCUploadScreenshots`:**
- If old-style `screenshotPaths` array provided, keep existing behavior (direct upload)
- Otherwise, delegate to `executeScreenshotsSave`

Add new tools to `category(for:)` and main `execute(name:arguments:)` switch.

## Implementation Order

1. `BlitzPaths.swift` — 1 line addition
2. `AppStoreConnectService.swift` — 3 line method
3. `ASCManager.swift` — models + state + sync algorithm (~150 lines)
4. `ScreenshotsView.swift` — full rewrite (~550-650 lines)
5. `MCPToolRegistry.swift` — 3 tools (~60 lines)
6. `MCPToolExecutor.swift` — 3 handlers (~100 lines)

## Verification

1. **Build:** `swift build` from project root
2. **Visual check:** `npm run build:app`, open Blitz, navigate to Screenshots tab
   - Verify 3-panel layout renders
   - Verify device picker switches tracks
   - Drag files from Finder into asset library (via Add button)
   - Drag assets from library to track slots → slots show orange "Changed"
   - Reorder slots by dragging → Save button enables
   - Remove slot → Save button enables
   - No changes → Save button is grayed out
3. **Save flow:** With ASC credentials configured, make changes then click Save
   - Verify pending screenshots upload
   - Verify removed screenshots delete from ASC
   - Verify reordered screenshots sync correctly
   - After save, all slots show green "Synced", Save grays out
4. **MCP tools:** From Claude Code, test:
   - `screenshots_add_asset` with a file path
   - `screenshots_set_track` to place it in slot 1
   - `screenshots_save` to sync to ASC
