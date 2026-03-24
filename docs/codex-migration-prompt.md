# Task: Replace blitz-macos's AppStoreConnectService with the ascd helper daemon

## Goal

Delete `src/services/AppStoreConnectService.swift` from blitz-macos. Replace it with a client that talks to the `ascd` helper daemon — a long-lived Go process that keeps App Store Connect auth and HTTP connections warm.

The app must compile and run at every intermediate step. No big-bang rewrite.

## Why

`AppStoreConnectService.swift` is 1,716 lines of hand-rolled JWT generation, HTTP client code, and 70+ API methods with zero tests. It breaks, it's unmaintainable, and it duplicates work already done well by the Go App Store Connect CLI (2+ years, 3,054 commits). We want to stop maintaining the API layer entirely and focus on GUI/UX.

## The two projects

**blitz-macos** (`~/superapp/blitz-macos`):
- Native macOS SwiftUI app for iOS development
- `src/services/AppStoreConnectService.swift` — the thing being deleted (1,716 lines, 70+ API methods, manual JWT, no protocol, no tests)
- `src/models/ASCModels.swift` — 36 `Decodable` structs that decode JSON:API responses (770 lines). These should survive mostly unchanged.
- `src/services/ASCManager.swift` — `@Observable @MainActor` state holder. Calls `service.fetchX()` / `service.patchX()`. This gets rewired to use the new client.
- 23 view files consume `ASCManager` state via `.attributes.` access. These should be untouched.
- `src/services/MCPToolExecutor.swift` — MCP tools call ASCManager, not AppStoreConnectService. Should be untouched.
- `src/services/IrisService.swift` — private Apple API with cookie auth, completely separate from ASC JWT auth. Stays as-is.
- Credentials stored at `~/.blitz/asc-credentials.json` (fields: `issuerId`, `keyId`, `privateKey`)
- `CLAUDE.md` has the full architecture overview

**ascd helper daemon** (`~/superapp/asc-cli/forks/App-Store-Connect-CLI-helper`):
- Fork of `github.com/rudrankriyam/App-Store-Connect-CLI` with one additive commit (`5c4feee0`)
- Binary at `cmd/ascd/main.go` — long-lived process, JSON-line protocol over stdin/stdout
- `docs/long-lived-helper-fork.md` — architecture and protocol reference
- `internal/helper/protocol.go` — all request/response types
- `internal/helper/service.go` — method dispatch, session management
- `internal/asc/raw_request.go` — generic authenticated HTTP through warm `asc.Client`

### ascd protocol summary

One JSON object per line in, one per line out. Five methods:

- `ping` — health check
- `session.open` — resolves credentials, constructs warm HTTP client with cached JWT
- `session.close` — tears down session
- `session.request` — sends arbitrary ASC REST request (method, path, headers, body, timeoutMs) through the warm client. Returns raw HTTP response (statusCode, headers, contentType, body). **This is the fast path that replaces AppStoreConnectService.**
- `cli.exec` — runs the full upstream CLI as a child process. Returns exitCode, stdout, stderr. **Compatibility fallback.**

The response body from `session.request` is the raw JSON:API payload from Apple — the same bytes `URLSession` would return. This means `ASCModels.swift` should decode it without changes.

Auth: the Go CLI reads `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PATH` (or `ASC_PRIVATE_KEY`) env vars, or `~/.asc/credentials.json`, or macOS Keychain.

## Requirements

1. **Delete `AppStoreConnectService.swift` by the end.** Every API call it makes must be handled by `ascd` instead.
2. **`ASCModels.swift` survives with minimal changes.** The JSON:API format is identical.
3. **All 23 view files are untouched.** They consume `ASCManager`, not the service.
4. **`ASCManager` stays `@Observable @MainActor`.** It just calls a different backend.
5. **MCP tools keep working throughout.**
6. **Zero external Swift package dependencies.** `ascd` is a subprocess, not linked.
7. **Credential bridge.** blitz-macos stores creds at `~/.blitz/asc-credentials.json`; `ascd` reads env vars or `~/.asc/credentials.json`. Make them talk.
8. **The app compiles and runs at every intermediate step.** Old and new can coexist during migration.

## What to read

Read these files thoroughly before planning:

**blitz-macos:**
- `src/services/AppStoreConnectService.swift` — every method, HTTP verb, endpoint, request body
- `src/services/ASCManager.swift` — every `service.` call site and the call chains per tab
- `src/models/ASCModels.swift` — every model type

**ascd (`~/superapp/asc-cli/forks/App-Store-Connect-CLI-helper`):**
- `docs/long-lived-helper-fork.md` — architecture and protocol
- `internal/helper/protocol.go` — request/response types
- `internal/helper/service.go` — method dispatch
- `internal/asc/raw_request.go` — the fast-path HTTP layer
- `cmd/ascd/main.go` — entry point

## What to produce

A migration plan 