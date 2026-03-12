# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
# Debug build
swift build

# Release build
swift build -c release

# Bundle as macOS .app (signs with Developer ID)
bash scripts/bundle.sh release

# Build Node.js sidecar (must run before bundle if sidecar is needed)
npm run build:sidecar

# Full release: bump version, build sidecar, bundle app, build pkg, deploy
npm run release

# Run tests
swift test

# Run a single test
swift test --filter BlitzTests.SimctlClientTests/testParseDeviceList

# Build installer pkg
bash scripts/build-pkg.sh
```

## Architecture

**Blitz** is a native macOS SwiftUI app (requires macOS 14+) for iOS development. It provides simulator management, screen capture, database browsing, App Store Connect integration, and an MCP server for Claude Code integration. Built with Swift Package Manager (no Xcode project).

### Single-target structure

All Swift source lives in `src/`. Core types (process execution, simulator control, device interaction, project metadata, sidecar protocol) live alongside UI, services, and the MCP server in one executable target.

### App State

Single `AppState` (`@Observable`) object at `AppState.swift` holds all app state. Child observable managers:
- `ProjectManager` — project list and loading
- `SimulatorManager` — simulator lifecycle (boot/shutdown via `SimctlClient`)
- `SimulatorStreamManager` — screen capture via `ScreenCaptureKit` + Metal rendering
- `DatabaseManager` — Teenybase DB connection, schema, CRUD
- `ASCManager` — App Store Connect API integration
- `ProjectSetupManager` — project scaffolding for different project types

### Navigation

`AppTab` enum defines all tabs, grouped into Build (simulator, database, tests, assets), Release (ASC tabs), Insights, TestFlight, and Settings. `ContentView` uses `NavigationSplitView` with `SidebarView` + `DetailView` that switches on `appState.activeTab`.

### MCP Server (Claude Code Integration)

```
Claude Code ←stdio→ Bridge Script (~/.blitz/blitz-mcp-bridge.sh) ←HTTP→ MCPServerService (Swift actor)
```

- `MCPServerService` — Raw TCP HTTP server on a dynamic port. Writes port to `~/.blitz/mcp-port`. Handles JSON-RPC requests at `/mcp`.
- `MCPToolRegistry` — Static definitions of all MCP tools (~35 tools covering navigation, projects, simulator, database, settings, device interaction, ASC forms, build pipeline).
- `MCPToolExecutor` — Executes tool calls. Read-only tools execute immediately; mutating tools go through an approval flow (continuation-based) that shows a native macOS alert.
- `ApprovalRequest` — Model with `ToolCategory` enum that determines whether user approval is required.

### Device Interaction

Two paths depending on target device:
- **Simulator**: `SimctlClient` (xcrun simctl) for lifecycle + `IDBClient` for touch/swipe/describe (via `idb` CLI)
- **Physical device**: `WDAClient` (WebDriverAgent HTTP API on port 8100) for touch/swipe/screenshots

`DeviceInteractionService` is the unified actor that dispatches to either path.

### Node.js Sidecar

`NodeSidecarService` manages a Node.js child process that communicates via Unix domain socket (`/tmp/blitz-{pid}.sock`). Used for project scaffolding and runtime management (Metro/Vite). The sidecar binary is bundled into the .app at `Contents/Resources/dist/server/`.

### Screen Capture

`SimulatorCaptureService` uses `ScreenCaptureKit` (SCStream) to capture the Simulator.app window. Frames are rendered via `MetalRenderer` using a Metal pipeline. Stream pauses/resumes on tab switches to conserve resources.

### Project Storage

Projects are stored at `~/Library/Application Support/Blitz/projects/{projectId}/`. Each project has a `.blitz/project.json` metadata file (`BlitzProjectMetadata`). Supported project types: `blitz`, `react-native`, `swift`, `flutter`.

## Key Patterns

- All services that need isolation use Swift `actor` (e.g., `MCPServerService`, `NodeSidecarService`, `DeviceInteractionService`)
- UI mutations go through `@MainActor` / `MainActor.run`
- External processes are managed via `ProcessRunner.run()` (async one-shot) or `ProcessRunner.stream()` (long-running with stdout/stderr callbacks, returns `ManagedProcess`)
- The app uses `@Observable` (Observation framework) rather than `ObservableObject`/`@Published`
- Linked system frameworks: ScreenCaptureKit, Metal, MetalKit, CoreMedia, AVFoundation, AppKit
