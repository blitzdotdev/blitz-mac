# Unified Toolbar with Per-Tab Items in NavigationSplitView

## The Pattern

Replace the default window title bar with a unified toolbar that shows different controls depending on the active tab. This is the same pattern Xcode, Finder, and Safari use.

## Setup

### 1. Scene: `.windowToolbarStyle(.unified(showsTitle: false))`

Apply this to the `WindowGroup` scene. It merges the title bar and toolbar into a single row and removes the window title text.

```swift
WindowGroup(id: "main", for: String.self) { _ in
    ContentView(appState: appState)
        .frame(minWidth: 800, minHeight: 600)
}
.windowToolbarStyle(.unified(showsTitle: false))
```

**Do NOT use** `.windowStyle(.hiddenTitleBar)` — that hides the traffic light buttons (close/minimize/expand).

### 2. Each tab view declares its own `.toolbar { }`

Toolbar items from child views in a `NavigationSplitView` propagate up to the window toolbar automatically. When the user switches tabs, SwiftUI swaps in the new view's toolbar items.

```swift
struct DetailView: View {
    var body: some View {
        switch appState.activeTab {
        case .simulator: SimulatorView(appState: appState)  // has its own .toolbar
        case .tests: TestsView(appState: appState)          // has its own .toolbar
        case .settings:  SettingsView(settings: ...)        // no .toolbar — empty bar
        }
    }
}
```

### 3. Toolbar item placements

| Placement | Position | Use for |
|-----------|----------|---------|
| `.navigation` | Leading (after traffic lights) | Primary context: device selector, status indicator |
| `.principal` | Center | Title-like content, search bars |
| `.primaryAction` | Trailing | Action buttons: start/stop, refresh, keyboard |
| `.secondaryAction` | Overflow menu | Rarely-used actions |

## Example: Simulator Tab

```swift
struct SimulatorView: View {
    var body: some View {
        VStack(spacing: 0) {
            // ... content (no inline toolbar HStack)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DeviceSelectorView(appState: appState)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if stream.isCapturing {
                    Text("\(stream.fps) FPS")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Button(action: { stream.showTextInput.toggle() }) {
                    Image(systemName: "keyboard")
                }

                Button(action: { /* home */ }) {
                    Image(systemName: "house")
                }

                Button(action: { /* start/stop */ }) {
                    Image(systemName: stream.isCapturing ? "stop.fill" : "play.fill")
                }
            }
        }
    }
}
```

## Key Takeaways

- **Do**: Use `.windowToolbarStyle(.unified(showsTitle: false))` on the scene
- **Do**: Put `.toolbar { }` on each tab's root view — SwiftUI handles the switching
- **Do**: Use `ToolbarItem`/`ToolbarItemGroup` with explicit placements
- **Don't**: Use `.windowStyle(.hiddenTitleBar)` — kills traffic light buttons
- **Don't**: Build custom inline `HStack` toolbars with `.background(.ultraThinMaterial)` — use the native toolbar system instead
- **Don't**: Put a single `.toolbar` on `DetailView` with a switch — let each tab view own its toolbar declaration

## Anti-Pattern: Custom Inline Toolbar

```swift
// BAD: Wastes vertical space, doesn't integrate with the title bar
var body: some View {
    VStack(spacing: 0) {
        HStack(spacing: 8) {
            DeviceSelectorView(appState: appState)
            Spacer()
            Button("Stop") { }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)

        // actual content below...
    }
}
```

This creates a second bar below the title bar. Instead, use `.toolbar { }` so the controls appear in the title bar row itself.
