# SwiftUI View Lifecycle in NavigationSplitView Tab Patterns

## The Problem

When using `NavigationSplitView` with a `switch` statement to render different tab views:

```swift
struct DetailView: View {
    var body: some View {
        switch activeTab {
        case .simulator: SimulatorView(appState: appState)
        case .tests: TestsView(appState: appState)
        // ...
        }
    }
}
```

**SwiftUI destroys and recreates each view on every tab switch.** This means:

- `@State` is reset (capture state, timers, local flags)
- `.onAppear` fires every time you switch back to the tab
- `.task` fires every time you switch back to the tab
- `.task(id:)` fires every time — even if the id hasn't changed — because it's a new view instance

## The Anti-Pattern

```swift
// BAD: This re-triggers expensive setup on every tab switch
struct ResourceHeavyView: View {
    var body: some View {
        content
            .task(id: appState.activeProjectId) {
                await sessionManager.start(projectId: project.id)
            }
            .onDisappear {
                sessionManager.stop()
            }
    }
}
```

## The Fix: State in Observable Manager, Dedup in the Manager

### 1. Keep long-lived state in an `@Observable` class on `AppState`

The manager lives on `AppState`, which persists for the app's lifetime. It survives tab switches.

```swift
@Observable
final class SessionManager {
    private(set) var activeProjectId: String?
    var isActive = false
    // ...
}
```

### 2. Guard against re-entry in the manager

```swift
func start(projectId: String) async {
    if activeProjectId == projectId && isActive { return }
    if activeProjectId != nil && activeProjectId != projectId {
        stop()
    }
    activeProjectId = projectId
    isActive = true
    // ... proceed with startup
}
```

### 3. Use `.onAppear` with a guard, not `.task(id:)`

```swift
.onAppear {
    guard let project = appState.activeProject else { return }
    guard sessionManager.activeProjectId != project.id || !sessionManager.isActive else { return }
    Task {
        await sessionManager.start(projectId: project.id)
    }
}
```

### 4. Never use `.onDisappear` to tear down shared resources

Tab switches destroy the view. Only tear down when the *project* changes, not when the *tab* changes. The manager handles this internally via `activeProjectId` tracking.

## Summary

| Concern | Where it lives | Why |
|---------|---------------|-----|
| Session state | `@Observable` manager on `AppState` | Survives view destruction |
| "Am I already active?" | `activeProjectId` in manager | Single source of truth |
| Trigger startup | `.onAppear` + guard | Fires on tab switch but guard prevents re-work |
| Tear down old session | Inside `start()` when projectId changes | Manager owns lifecycle |
| Never | `.onDisappear { stop() }` | View destruction != intent to stop shared work |

## Second Anti-Pattern: `@State` for Long-Lived Resources

```swift
// BAD: All state destroyed on tab switch, capture stream killed, must re-start
struct SimulatorView: View {
    @State private var captureService = SimulatorCaptureService()
    @State private var renderer: MetalRenderer?
    @State private var isCapturing = false
    @State private var fps: Int = 0
    // ...
}
```

### The Fix: Move to a Manager on AppState

```swift
// GOOD: Lives on AppState, survives tab switches
@Observable
final class SimulatorStreamManager {
    let captureService = SimulatorCaptureService()
    var renderer: MetalRenderer?
    var isCapturing = false
    var fps: Int = 0

    private var rendererInitialized = false

    func ensureRenderer() {
        guard !rendererInitialized else { return }
        rendererInitialized = true
        renderer = try? MetalRenderer()
    }
}

// In AppState:
var simulatorStream = SimulatorStreamManager()

// In the view — just reference the manager:
struct SimulatorView: View {
    @Bindable var appState: AppState
    private var stream: SimulatorStreamManager { appState.simulatorStream }

    var body: some View {
        // ...
        .onAppear { stream.ensureRenderer() }
    }
}
```

Key: use `ensureRenderer()` / `ensureX()` with an internal `initialized` flag so `.onAppear` is safe to call repeatedly.

## Rule of Thumb

If a resource should survive tab switches, it cannot live in `@State`. Move it to an `@Observable` manager on `AppState`.

| Use `@State` for | Use `AppState` manager for |
|---|---|
| Text input fields | Capture streams |
| Sheet/alert presentation | Process lifecycles |
| Local UI toggles | Network connections |
| Animation state | Renderers, timers, polling tasks |

## Applies To

Any view in the `DetailView` switch that manages expensive or long-lived resources:
- Simulator capture streams (`SimulatorStreamManager` + `SimulatorCaptureService`)
- WebSocket connections
- Background polling tasks
