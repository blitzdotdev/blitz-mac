# Migration: blitz-macos → Shared ASC Domain/Infrastructure Package

## Goal

Replace blitz-macos's custom App Store Connect models (`ASCModels.swift`, 770 lines) and API service (`AppStoreConnectService.swift`, 1,716 lines) with asc-cli's battle-tested Domain and Infrastructure layers, consumed as a Swift package dependency.

## Why

blitz-macos and asc-cli both implement the App Store Connect API independently. asc-cli's implementation is superior in every measurable way:

- **226 domain types** (vs 36 flat structs in one file) with parent ID injection, semantic booleans, type-safe state enums, custom Codable, and CAEOAS affordances
- **54 `@Mockable` repository protocols** — blitz-macos has zero testable abstractions; `AppStoreConnectService` is a concrete 1,716-line class with no protocol
- **6,545 lines of domain logic** with full test coverage (Chicago School TDD) vs 0 tests in blitz-macos's ASC layer
- **Parent IDs on every model** — the ASC API doesn't return parent IDs; asc-cli's Infrastructure injects them at the mapper layer. blitz-macos works around this by relying on `ASCManager` knowing which app/version is selected, which breaks when passing models between contexts or serializing them

Unifying means blitz-macos deletes ~2,500 lines of hand-rolled API code, gains testability, and automatically inherits every future asc-cli domain addition (Game Center, Xcode Cloud, diagnostics, etc.) for free.

---

## Architecture Overview

### Before

```
blitz-macos (zero external Swift dependencies)
├── ASCModels.swift          — 36 flat Decodable structs, raw string states
├── AppStoreConnectService   — 1,716 lines, manual JWT, 70+ methods, no protocol
├── ASCManager               — @Observable, holds all state, string comparisons
└── 23 views                 — access .attributes.fieldName, hardcode state strings
```

### After

```
asc-cli repo
├── Sources/Domain/          — 165 files, pure value types, @Mockable protocols
├── Sources/Infrastructure/  — 69 files, SDK adapters with parent ID injection
└── Sources/ASCCommand/      — CLI (unchanged, still depends on Domain + Infra)

blitz-macos (depends on asc-cli's Domain + Infrastructure via SPM)
├── ASCModels.swift          — DELETED (replaced by Domain types)
├── AppStoreConnectService   — DELETED (replaced by Infrastructure repositories)
├── ASCManager               — REFACTORED: holds repository protocols, uses Domain types
├── BlitzAuthProvider        — NEW: thin adapter bridging ~/.blitz/asc-credentials.json to AuthProvider protocol
├── 23 views                 — REFACTORED: .isLive instead of .attributes.appStoreState == "READY_FOR_SALE"
└── Iris/MCP/Simulator       — UNCHANGED (blitz-specific, not in shared package)
```

---

## Prerequisites

### Step 0: Make asc-cli's Domain and Infrastructure consumable as library products

In `/Users/minjunes/superapp/asc-cli/Package.swift`, add library products so blitz-macos can depend on them:

```swift
products: [
    .executable(name: "asc", targets: ["ASCCommand"]),
    // NEW: library products for external consumers
    .library(name: "ASCDomain", targets: ["Domain"]),
    .library(name: "ASCInfrastructure", targets: ["Infrastructure"]),
],
```

No code changes needed in asc-cli — just exposing existing targets as libraries.

In `/Users/minjunes/superapp/blitz-macos/Package.swift`, add the local dependency:

```swift
dependencies: [
    .package(path: "../asc-cli"),
],
targets: [
    .executableTarget(
        name: "blitz",
        dependencies: [
            .product(name: "ASCDomain", package: "asc-swift"),
            .product(name: "ASCInfrastructure", package: "asc-swift"),
        ],
        // ...
    ),
]
```

> Note: `asc-swift` is the package name in asc-cli's Package.swift. Using a local `path:` dependency during development; switch to a git URL for release.

This introduces transitive dependencies: `appstoreconnect-swift-sdk`, `Mockable`, `SweetCookieKit`. This is the cost of unification. blitz-macos's zero-dependency constraint is relaxed for its own sibling package only — no third-party code is imported directly.

---

## Phase 1: Auth Bridge

**Goal:** blitz-macos can construct asc-cli's Infrastructure repositories using its own credential store.

### What exists

- asc-cli defines `AuthProvider` protocol in Domain, with `FileAuthProvider`, `EnvironmentAuthProvider`, `CompositeAuthProvider` in Infrastructure
- asc-cli stores credentials at `~/.asc/credentials.json`
- blitz-macos stores credentials at `~/.blitz/asc-credentials.json` with a different JSON schema
- blitz-macos's `ASCCredentials` struct has `issuerId`, `keyId`, `privateKey` fields
- asc-cli's `AuthCredentials` struct has `keyID`, `issuerID`, `privateKeyPEM`, `vendorNumber` fields

### What to do

Create `src/services/BlitzAuthProvider.swift`:

```swift
import Domain  // from asc-cli

/// Bridges blitz-macos credential storage to asc-cli's AuthProvider protocol.
struct BlitzAuthProvider: AuthProvider {
    func resolve() throws -> AuthCredentials {
        // Read from existing ~/.blitz/asc-credentials.json
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz/asc-credentials.json")
        let data = try Data(contentsOf: url)

        struct BlitzCreds: Decodable {
            let issuerId: String
            let keyId: String
            let privateKey: String
        }

        let creds = try JSONDecoder().decode(BlitzCreds.self, from: data)
        return AuthCredentials(
            keyID: creds.keyId,
            issuerID: creds.issuerId,
            privateKeyPEM: creds.privateKey,
            vendorNumber: nil
        )
    }
}
```

### What to delete

Nothing yet. This phase is additive — both auth paths coexist.

### Verification

Write a test that constructs `BlitzAuthProvider`, loads credentials from a temp file, and asserts the returned `AuthCredentials` fields match. This is your first blitz-macos test using asc-cli's domain types.

---

## Phase 2: Repository Wiring

**Goal:** blitz-macos can call asc-cli's repository implementations to fetch data, getting back rich Domain types.

### What exists

- asc-cli's `Infrastructure/Client/ClientFactory.swift` creates all SDK repository implementations given an `AuthProvider`
- Each repository (e.g., `SDKVersionRepository`) needs an `APIClient` (which wraps `AppStoreConnect_Swift_SDK.APIProvider`)

### What to do

Create `src/services/ASCClientFactory.swift` — a blitz-specific factory that:

1. Takes `BlitzAuthProvider`
2. Constructs `AppStoreConnect_Swift_SDK.APIProvider` (JWT-based)
3. Returns typed repositories

```swift
import Infrastructure  // from asc-cli
import Domain

struct ASCClientFactory {
    private let authProvider: BlitzAuthProvider

    /// Returns all repositories blitz-macos needs.
    func makeRepositories() throws -> ASCRepositories {
        let credentials = try authProvider.resolve()
        // Use asc-cli's ClientFactory or replicate its wiring
        let config = APIConfiguration(
            issuerID: credentials.issuerID,
            privateKeyID: credentials.keyID,
            privateKey: credentials.privateKeyPEM
        )
        let provider = APIProvider(configuration: config)
        return ASCRepositories(
            apps: SDKAppRepository(client: provider),
            versions: SDKVersionRepository(client: provider),
            builds: OpenAPIBuildRepository(client: provider),
            localizations: SDKLocalizationRepository(client: provider),
            screenshots: OpenAPIScreenshotRepository(client: provider),
            appInfo: SDKAppInfoRepository(client: provider),
            reviews: SDKCustomerReviewRepository(client: provider),
            submissions: OpenAPISubmissionRepository(client: provider),
            testFlight: OpenAPITestFlightRepository(client: provider),
            // ... add repositories as needed per phase
        )
    }
}

/// Container for all ASC repositories blitz-macos consumes.
struct ASCRepositories {
    let apps: any AppRepository
    let versions: any VersionRepository
    let builds: any BuildRepository
    let localizations: any VersionLocalizationRepository
    let screenshots: any ScreenshotRepository
    let appInfo: any AppInfoRepository
    let reviews: any CustomerReviewRepository
    let submissions: any SubmissionRepository
    let testFlight: any TestFlightRepository
}
```

> Check asc-cli's `ClientFactory.swift` for exact constructor signatures — the repository implementations may require specific `APIClient` protocol conformance rather than raw `APIProvider`.

### Verification

In a test or debug build, call `factory.makeRepositories().apps.listApps(limit: 5)` and assert you get back `[Domain.App]` with `.name`, `.bundleId`, `.affordances`.

---

## Phase 3: Migrate ASCManager (Incremental, One Repository at a Time)

**Goal:** `ASCManager` uses asc-cli repository protocols instead of `AppStoreConnectService`.

This is the core of the migration. Do it **one feature area at a time** so the app stays functional throughout.

### Migration order (by blast radius, smallest first)

#### 3a. Apps

**Before (ASCManager):**
```swift
var app: ASCApp?
// ...
app = try await service.fetchApp(bundleId: bundleId)
// Views: app.name, app.bundleId, app.attributes.vendorNumber
```

**After:**
```swift
var app: Domain.App?
// ...
let response = try await repos.apps.listApps(limit: nil)
app = response.data.first { $0.bundleId == bundleId }
// Views: app.name, app.bundleId (same property names — minimal view changes)
```

**View changes:** `app.attributes.name` → `app.name`, `app.attributes.bundleId` → `app.bundleId`. The Domain model flattens `.attributes.` away.

#### 3b. Versions

**Before:**
```swift
var appStoreVersions: [ASCAppStoreVersion] = []
appStoreVersions = try await service.fetchAppStoreVersions(appId: app!.id)
// Views: v.attributes.appStoreState == "READY_FOR_SALE"
```

**After:**
```swift
var appStoreVersions: [Domain.AppStoreVersion] = []
appStoreVersions = try await repos.versions.listVersions(appId: app!.id)
// Views: v.isLive (semantic boolean)
```

**View changes — this is the big win.** Every string comparison becomes a boolean:

| Before (23 view files) | After |
|---|---|
| `v.attributes.appStoreState == "READY_FOR_SALE"` | `v.isLive` |
| `v.attributes.appStoreState == "PREPARE_FOR_SUBMISSION"` | `v.state == .prepareForSubmission` |
| `!nonSubmittableStates.contains(v.attributes.appStoreState)` | `v.isEditable` |
| `v.attributes.appStoreState == "WAITING_FOR_REVIEW"` | `v.state == .waitingForReview` |
| `v.attributes.appStoreState == "REJECTED"` | `v.state == .rejected` |
| `v.attributes.appStoreState` (display) | `v.state.rawValue` (same strings) |

**Parent ID bonus:** Every `AppStoreVersion` now carries `.appId` — no need to pass app context separately.

#### 3c. Builds

**Before:**
```swift
var builds: [ASCBuild] = []
builds = try await service.fetchBuilds(appId: app!.id)
// Views: b.attributes.processingState == "VALID" && b.attributes.expired != true
```

**After:**
```swift
var builds: [Domain.Build] = []
builds = try await repos.builds.listBuilds(appId: app!.id)
// Views: b.isUsable
```

**View changes:**

| Before | After |
|---|---|
| `b.attributes.processingState == "VALID" && b.attributes.expired != true` | `b.isUsable` |
| `b.attributes.processingState` (badge) | `b.processingState.rawValue` |
| `b.attributes.expired == true` | `b.expired` |
| `b.attributes.version` | `b.version` |

#### 3d. Version Localizations

**Before:**
```swift
var localizations: [ASCVersionLocalization] = []
localizations = try await service.fetchVersionLocalizations(versionId: versionId)
// Views: loc.attributes.description, loc.attributes.whatsNew
```

**After:**
```swift
var localizations: [Domain.AppStoreVersionLocalization] = []
localizations = try await repos.localizations.listLocalizations(versionId: versionId)
// Views: loc.description, loc.whatsNew (flattened — no .attributes.)
```

#### 3e. Screenshots

**Before:**
```swift
var screenshotSets: [ASCScreenshotSet] = []
var screenshots: [String: [ASCScreenshot]] = [:]
screenshotSets = try await service.fetchScreenshotSets(localizationId: locId)
screenshots[set.id] = try await service.fetchScreenshots(setId: set.id)
```

**After:**
```swift
var screenshotSets: [Domain.AppScreenshotSet] = []
var screenshots: [String: [Domain.AppScreenshot]] = [:]
screenshotSets = try await repos.screenshots.listScreenshotSets(localizationId: locId)
screenshots[set.id] = try await repos.screenshots.listScreenshots(setId: set.id)
// Bonus: each screenshot carries .setId (parent ID)
// Bonus: screenshot.isComplete replaces assetDeliveryState string checks
```

#### 3f. App Info, Age Rating, Review Detail

Same pattern. Replace `service.fetchAppInfo()` calls with `repos.appInfo.listAppInfos()`. Models gain parent IDs and affordances.

#### 3g. Customer Reviews

```swift
// Before
var customerReviews: [ASCCustomerReview] = []
customerReviews = try await service.fetchReviews(appId: app!.id)

// After
var customerReviews: [Domain.CustomerReview] = []
let response = try await repos.reviews.listReviews(appId: app!.id)
customerReviews = response.data
```

#### 3h. TestFlight (Beta Groups, Testers)

```swift
// Before
var betaGroups: [ASCBetaGroup] = []
betaGroups = try await service.fetchBetaGroups(appId: app!.id)

// After
var betaGroups: [Domain.BetaGroup] = []
betaGroups = try await repos.testFlight.listBetaGroups(appId: app!.id)
// Bonus: each group carries .appId, .affordances
```

#### 3i. Submissions

```swift
// Before: service.submitForReview(versionId:)
// After: repos.submissions.createSubmission(versionId:)
```

#### 3j. In-App Purchases & Subscriptions

These have dedicated repositories in asc-cli (`InAppPurchaseRepository`, `SubscriptionRepository`, `SubscriptionGroupRepository`). Add them to `ASCRepositories` and wire into `ASCManager`.

#### 3k. Write Operations (PATCH/POST/DELETE)

asc-cli's repositories expose write methods too. For example:

```swift
// VersionLocalizationRepository
func updateLocalization(id: String, whatsNew: String?, description: String?, ...) async throws -> AppStoreVersionLocalization

// ScreenshotRepository
func uploadScreenshot(setId: String, fileName: String, fileData: Data) async throws -> AppScreenshot
func deleteScreenshot(id: String) async throws
```

Replace `service.patchLocalization(...)`, `service.uploadScreenshot(...)`, etc. with the corresponding repository method.

---

## Phase 4: Delete Dead Code

Once all `AppStoreConnectService` call sites are replaced:

### Delete entirely
- `src/models/ASCModels.swift` — all 36 model types replaced by Domain imports
- `src/services/AppStoreConnectService.swift` — all 70+ methods replaced by repository calls

### Keep but simplify
- `src/services/ASCManager.swift` — still needed as `@Observable` state holder, but now typed with `Domain.*` models and injected with repository protocols

### Keep unchanged
- `src/services/IrisService.swift` — Iris private API is blitz-specific, not in asc-cli. Keep as-is. If Iris models overlap with Domain types (e.g., app creation), consider thin adapters later.
- `src/services/MCPToolExecutor.swift` — MCP tools read/write ASCManager state. Since ASCManager's public interface changes (new types), MCP tools need type updates but logic stays the same.
- `src/services/BuildPipelineService.swift` — uses xcodebuild, not ASC API. Unchanged.
- All simulator, database, project scaffolding code — unrelated to ASC.

---

## Phase 5: View Refactoring Checklist

Every view file that accesses `.attributes.` needs updating. The pattern is mechanical:

### Property access flattening

```swift
// BEFORE                                    // AFTER
thing.attributes.fieldName                   thing.fieldName
thing.attributes.appStoreState               thing.state.rawValue  (for display)
thing.attributes.appStoreState == "X"        thing.state == .x     (for comparison)
thing.attributes.processingState == "VALID"  thing.processingState == .valid
```

### Files to update (23 files)

**Release views:**
- `src/views/release/ASCOverview.swift` — version state filtering, rejection display
- `src/views/release/StoreListingView.swift` — localization field access
- `src/views/release/ScreenshotsView.swift` — screenshot set/screenshot types
- `src/views/release/ReviewView.swift` — age rating, review detail, build selection, state checks
- `src/views/release/SubmitPreviewSheet.swift` — nonSubmittableStates → `!version.isEditable`
- `src/views/release/AppDetailsView.swift` — app info localization fields
- `src/views/release/PricingView.swift` — IAP/subscription state checks

**TestFlight views:**
- `src/views/testflight/BuildsView.swift` — processingState badge, expired check
- `src/views/testflight/GroupsView.swift` — beta group fields
- `src/views/testflight/BetaInfoView.swift` — beta localization fields
- `src/views/testflight/FeedbackView.swift` — beta feedback fields

**Insights views:**
- `src/views/insights/ReviewsView.swift` — customer review fields
- `src/views/insights/AnalyticsView.swift` — if it touches ASC models

**Shared views:**
- `src/views/shared/asc/RejectionCardView.swift` — rejection reason display
- `src/views/shared/asc/BundleIDSetupView.swift` — bundle ID fields
- `src/views/shared/asc/ASCCredentialForm.swift` — credential entry
- `src/views/shared/asc/ASCTabContent.swift` — tab routing
- `src/views/shared/asc/ASCCredentialGate.swift` — auth state

**Other:**
- `src/views/settings/SettingsView.swift` — credential display
- `src/views/OnboardingView.swift` — credential entry

---

## Phase 6: MCP Tool Adaptation

MCP tools in `MCPToolExecutor.swift` read and write `ASCManager` state. Since ASCManager's stored types change from `ASCApp` → `Domain.App`, etc., the MCP tool implementations need type updates.

### Pattern

```swift
// BEFORE
if let app = appState.ascManager.app {
    return ["name": app.name, "bundleId": app.bundleId,
            "state": app.attributes.appStoreState ?? "unknown"]
}

// AFTER
if let app = appState.ascManager.app {
    return ["name": app.name, "bundleId": app.bundleId]
    // state is on the version, not the app — which is correct
}

// BEFORE
let version = appState.ascManager.appStoreVersions.first {
    $0.attributes.appStoreState != "READY_FOR_SALE"
}

// AFTER
let version = appState.ascManager.appStoreVersions.first { !$0.isLive }
```

### Affordances in MCP responses

New opportunity: MCP tool responses can now include `model.affordances` — giving the agent state-aware CLI commands alongside GUI actions. This is optional but powerful for hybrid workflows where Claude Code uses both MCP tools and `asc` CLI.

```swift
// Optional enhancement: include affordances in MCP tool results
func getTabState() -> [String: Any] {
    var result: [String: Any] = [...]
    if let version = currentVersion {
        result["affordances"] = version.affordances  // free from Domain
    }
    return result
}
```

---

## Phase 7: Credential Unification (Optional, Future)

Once Phase 1-6 are stable, consider whether blitz-macos should read from `~/.asc/credentials.json` (asc-cli's format) instead of `~/.blitz/asc-credentials.json`. Benefits:

- Single credential store — `asc auth login` works for both tools
- `asc auth check` validates what blitz-macos will use
- Environment variable fallback via `CompositeAuthProvider`

Cost: migration path for existing blitz-macos users who have credentials in `~/.blitz/`. Could do a one-time migration on first launch, or support both with a composite provider.

---

## What NOT To Migrate

| blitz-macos concern | Why it stays |
|---|---|
| `IrisService` + `IrisSession` + `IrisFeedbackCache` | Iris is a private Apple API using cookie auth. asc-cli has its own Iris implementation but the auth flows differ (browser cookies vs Keychain). Keep separate. |
| `ASCSubmissionHistoryCache` | Local persistence of version state transitions. Could move to shared package later, but not required — it's a UI convenience, not a domain concern. |
| `TrackSlot` model (screenshot tracks) | UI-specific: tracks local images vs ASC-sourced screenshots for the drag-reorder UI. Not a domain concept. |
| `SubmissionReadiness` (field checklist) | UI-specific readiness display. asc-cli has `VersionReadiness` in Domain which is richer — consider adopting it, but not required for migration. |
| `pendingFormValues` / `pendingCreateValues` | MCP form pre-fill state. Pure UI concern. |
| `BuildPipelineService` | Uses xcodebuild, not ASC API. |
| Simulator, Database, Project scaffolding | Unrelated to ASC. |

---

## Verification Strategy

After each phase, verify:

1. **Build:** `swift build` succeeds for blitz-macos
2. **Manual test:** Launch the app, navigate to the affected tab, confirm data loads
3. **Type check:** No `ASCApp`, `ASCBuild`, etc. references remain for migrated types (grep for the old type name)
4. **New tests:** For each migrated area, write at least one test using `@Mockable` repository mocks to verify ASCManager state transitions

### Final verification (after Phase 6)

```bash
# No references to old ASC models should remain
cd /Users/minjunes/superapp/blitz-macos
grep -r "ASCApp\b" src/ --include="*.swift"           # should return 0
grep -r "ASCAppStoreVersion\b" src/ --include="*.swift" # should return 0
grep -r "ASCBuild\b" src/ --include="*.swift"           # should return 0
grep -r "\.attributes\." src/ --include="*.swift"       # should return 0
grep -r "AppStoreConnectService" src/ --include="*.swift" # should return 0

# Old files should be gone
test ! -f src/models/ASCModels.swift
test ! -f src/services/AppStoreConnectService.swift
```

---

## Risk Mitigation

| Risk | Mitigation |
|---|---|
| asc-cli Domain types missing fields blitz-macos needs | Add fields to asc-cli's Domain types — they're the source of truth. PR to asc-cli. |
| `appstoreconnect-swift-sdk` version conflicts | blitz-macos inherits asc-cli's pinned version transitively. No conflict possible. |
| Sendable/concurrency mismatch | asc-cli Domain types are all `Sendable`. ASCManager is `@MainActor`. Repository calls are `async` — use `Task { }` from MainActor as blitz-macos already does. |
| Breaking change in asc-cli Domain | Pin to a specific asc-cli commit/tag during development. Update deliberately. |
| Migration takes too long | Each phase is independently shippable. Phase 3a-3k can be done one sub-phase per PR. The app works with a mix of old and new types during migration. |
