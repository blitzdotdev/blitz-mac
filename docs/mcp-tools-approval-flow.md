# Plan: Expose All Blitz UI Elements as MCP Tools + IDE Approval Flow

## Context

Blitz macOS is a SwiftUI app with a basic HTTP MCP server (`MCPServerService.swift`) that currently only exposes 5 device-interaction tools. The goal is to expose **every interactive UI element** as an MCP tool (navigation, project CRUD, settings, simulator controls, recording) and add an **interactive approval flow** where destructive operations show a native macOS popup in Blitz that the user must approve/deny before execution proceeds.

Claude Code connects to MCP servers via stdio transport (spawns a child process). Since Blitz is already running as a GUI app, we need a **thin stdio→HTTP bridge** that Claude Code spawns, which forwards JSON-RPC to Blitz's HTTP endpoint.

## Architecture

```
Claude Code ←stdio→ Bridge Script ←HTTP→ MCPServerService (Swift actor)
                                              ↓ MainActor.run
                                          AppState (SwiftUI)
                                              ↓
                                     Approval Alert (native macOS)
```

## Files to Create (6 new files)

### 1. `Sources/BlitzApp/Models/ApprovalRequest.swift`

Defines the approval request model with tool categories that determine whether user approval is needed.

```swift
struct ApprovalRequest: Identifiable {
    let id: String          // UUID for correlating with continuation
    let toolName: String
    let description: String // Human-readable, shown in alert
    let parameters: [String: String]
    let category: ToolCategory

    enum ToolCategory: String {
        case navigation, query           // Auto-approved (read-only)
        case projectMutation             // Create/import/delete project
        case settingsMutation            // Change settings
        case simulatorControl            // Boot/shutdown/streaming
        case recording                   // Start/stop recording
    }

    var requiresApproval: Bool {
        switch category {
        case .navigation, .query: return false
        default: return true
        }
    }
}
```

### 2. `Sources/BlitzApp/Services/MCPToolRegistry.swift`

Static definitions for all ~31 MCP tools. Returns `[[String: Any]]` for the `tools/list` response.

**Full tool inventory:**

| Tool                      | Description                                                     | Approval? |
|---------------------------|-----------------------------------------------------------------|-----------|
| `app_get_state`           | Get current project, tab, streaming status                      | No        |
| `nav_switch_tab`          | Switch sidebar tab (simulator, tests, settings, etc.)           | No        |
| `nav_list_tabs`           | List all available tabs with groups                             | No        |
| `project_list`            | List all projects                                               | No        |
| `project_get_active`      | Get active project details                                      | No        |
| `project_open`            | Open project by ID                                              | **Yes**   |
| `project_create`          | Create new project (name + type)                                | **Yes**   |
| `project_import`          | Import external project (path + type)                           | **Yes**   |
| `project_close`           | Close current project                                           | **Yes**   |
| `simulator_list_devices`  | List simulators + physical devices                              | No        |
| `simulator_select_device` | Select/boot a simulator by UDID                                 | **Yes**   |
| `simulator_start_streaming` | Start screen capture stream                                   | **Yes**   |
| `simulator_stop_streaming`  | Stop screen capture stream                                    | **Yes**   |
| `simulator_press_home`    | Press home button                                               | No        |
| `simulator_send_text`     | Send keyboard text to simulator                                 | No        |
| `simulator_toggle_keyboard` | Toggle keyboard input bar                                     | No        |
| `settings_get`            | Get current settings                                            | No        |
| `settings_update`         | Update settings (FPS, cursor, format)                           | **Yes**   |
| `settings_save`           | Save settings to disk                                           | **Yes**   |
| `recording_start`         | Start screen recording                                          | **Yes**   |
| `recording_stop`          | Stop screen recording                                           | **Yes**   |

### 3. `Sources/BlitzApp/Services/MCPToolExecutor.swift`

Actor that executes tool calls. Holds a reference to `AppState` and a map of pending `CheckedContinuation<Bool, Never>` for the approval flow.

Key pattern:
- **Read-only tools:** `await MainActor.run { read appState }` → return JSON
- **Mutating tools:** `requestApproval()` → suspends via `withCheckedContinuation` → UI shows alert → user approves/denies → continuation resumes → execute on MainActor → return JSON
- 5-minute auto-deny timeout on approval requests

### 4. `Sources/BlitzApp/Views/Shared/ApprovalOverlay.swift`

SwiftUI `.alert` modifier attached to `ContentView`. When `appState.pendingApproval != nil`, shows:

```
┌─────────────────────────────┐
│    AI Tool Request          │
│                             │
│  Create a new project       │
│  named 'MyApp' (type: blitz)│
│                             │
│  [Deny]          [Approve]  │
└─────────────────────────────┘
```

On approve/deny, calls `toolExecutor.resolveApproval(id:approved:)` which resumes the suspended continuation.

### 5. `scripts/blitz-mcp-bridge.sh`

Thin stdio→HTTP bridge (shell script, ~20 lines):
- Reads port from `~/.blitz/mcp-port`
- Reads JSON-RPC lines from stdin
- POSTs each to `http://127.0.0.1:{port}/mcp` via curl
- Writes response to stdout
- Handles "Blitz not running" error gracefully

### 6. `Sources/BlitzApp/Views/Settings/MCPSetupSection.swift`

New section in SettingsView showing MCP server status and a "Copy Config to Clipboard" button that copies the JSON snippet for `~/.claude.json`.

## Files to Modify (4 files)

### 1. `Sources/BlitzApp/AppState.swift`

- Add `pendingApproval: ApprovalRequest?`
- Add `showApprovalAlert: Bool = false`
- Add `toolExecutor: MCPToolExecutor?` (set during app init)

### 2. `Sources/BlitzApp/Services/MCPServerService.swift`

- Accept `AppState` at init (alongside `DeviceInteractionService`)
- Create `MCPToolExecutor` internally
- Replace `mcpToolDefinitions()` → delegate to `MCPToolRegistry.allTools()`
- Replace `executeMCPTool()` → delegate to `MCPToolExecutor.execute()`
- Write port to `~/.blitz/mcp-port` on start, remove on stop
- Increase recv buffer (4096 → 65536) for large tool arguments

### 3. `Sources/BlitzApp/BlitzApp.swift`

- Instantiate and start `MCPServerService` on app launch
- Store reference in `AppState` or as `@State`
- Stop server in `applicationWillTerminate`
- Copy bridge script to `~/.blitz/` on first launch

### 4. `Sources/BlitzApp/Views/ContentView.swift`

- Attach the approval alert modifier to the root view
- Pass `toolExecutor` reference for resolve callbacks

## Approval Flow Sequence

```
1. Claude Code calls tool → bridge POSTs to Blitz HTTP server
2. MCPToolExecutor checks category.requiresApproval
3. If false → execute immediately, return result
4. If true → create ApprovalRequest, store continuation
5. Dispatch to MainActor → set appState.pendingApproval
6. SwiftUI alert appears in Blitz window
7. User clicks Approve or Deny
8. Alert handler calls toolExecutor.resolveApproval(id, approved)
9. Continuation resumes → executor either executes or returns denial
10. HTTP response sent → bridge writes to stdout → Claude Code receives
```

## Port Discovery

- `MCPServerService.start()` writes port to `~/.blitz/mcp-port`
- `MCPServerService.stop()` deletes the file
- Bridge script reads this file per-request (handles port changes after restart)

## Claude Code Registration

Users add to `~/.claude.json` → `mcpServers`:

```json
{
  "blitz-macos": {
    "command": "bash",
    "args": ["/Users/{user}/.blitz/blitz-mcp-bridge.sh"]
  }
}
```

The Settings → MCP section provides a "Copy Config" button for this.

## Implementation Order

1. [x] **ApprovalRequest model** + AppState changes
2. [x] **MCPToolRegistry** — all 31 tool definitions
3. [x] **MCPToolExecutor** — execution logic + approval continuation system
4. [x] **MCPServerService** — wire up registry + executor, port file, buffer fix
5. [x] **ApprovalOverlay** — SwiftUI alert on ContentView
6. [x] **BlitzApp** — start MCP server on launch
7. [x] **Bridge script** + Settings MCP section
8. [ ] **End-to-end test** with curl + Claude Code

## Verification

1. `curl` test: Start Blitz → `cat ~/.blitz/mcp-port` → POST `tools/list` → verify all 31 tools returned
2. Bridge test: `echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | bash ~/.blitz/blitz-mcp-bridge.sh`
3. Approval test: POST `project_create` → verify alert appears → click Approve → verify response
4. Claude Code test: Ask "list all Blitz tabs" → verify `nav_list_tabs` called → response shown
5. Claude Code approval test: Ask "create a project called TestApp" → verify Blitz alert → approve → verify success
