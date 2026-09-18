# Plan: Add IAP, Subscription, and Paid Pricing to Blitz

## Context

The ASC integration currently only supports free pricing (`setPriceFree`). We need to add 3 new MCP tools for paid app pricing, in-app purchases, and subscriptions. All API endpoints have been validated against the real app `mjso` (id `6760320061`) via test scripts in `scripts/asc-api-tests/`.

## Files to Modify (4 files)

### 1. `Sources/BlitzApp/Models/ASCModels.swift`

Add 3 new Decodable types (same pattern as all existing models):

- `ASCInAppPurchase` — attrs: name, productId, inAppPurchaseType, state, reviewNote
- `ASCSubscriptionGroup` — attrs: referenceName
- `ASCSubscription` — attrs: name, productId, subscriptionPeriod, state, reviewNote

Reuse existing `ASCPricePoint` for all price point queries.

### 2. `Sources/BlitzApp/Services/AppStoreConnectService.swift`

**A) Add versioned-path HTTP helpers** (after existing `delete(path:)` at line ~150)

The current `makeRequest` hardcodes `/v1/` in the path. IAP uses `/v2/`, equalizations use `/v3/`. Add a parallel set of helpers that accept a full path instead:

- `makeRequest(fullPath:queryItems:)` — sets `components.path = fullPath` directly
- `get<T>(fullPath:queryItems:as:)`, `post(fullPath:body:)`, `patch(fullPath:body:)`, `delete(fullPath:)` — identical to existing helpers but call `makeRequest(fullPath:)`

This avoids changing any existing callers.

**B) Add paid pricing methods** (after existing `setPriceFree` at line ~465)

- `fetchAppPricePoints(appId:territory:)` → `GET /v1/apps/{id}/appPricePoints?filter[territory]=USA&limit=200`
- `setAppPrice(appId:pricePointId:)` → `POST /v1/appPriceSchedules` (compound document, same pattern as `setPriceFree`)

**C) Add IAP methods** (new MARK section)

- `createInAppPurchase(appId:name:productId:inAppPurchaseType:reviewNote:)` → `POST /v2/inAppPurchases` (uses `fullPath`)
- `localizeInAppPurchase(iapId:locale:name:description:)` → `POST /v1/inAppPurchaseLocalizations`
- `fetchInAppPurchasePricePoints(iapId:territory:)` → `GET /v2/inAppPurchases/{id}/pricePoints` (uses `fullPath`)
- `setInAppPurchasePrice(iapId:pricePointId:)` → `POST /v1/inAppPurchasePriceSchedules` (compound document)
- `fetchInAppPurchases(appId:)` → `GET /v1/apps/{id}/inAppPurchasesV2`

**D) Add Subscription methods** (new MARK section)

- `createSubscriptionGroup(appId:referenceName:)` → `POST /v1/subscriptionGroups`
- `localizeSubscriptionGroup(groupId:locale:name:)` → `POST /v1/subscriptionGroupLocalizations`
- `createSubscription(groupId:name:productId:subscriptionPeriod:)` → `POST /v1/subscriptions`
- `localizeSubscription(subscriptionId:locale:name:description:)` → `POST /v1/subscriptionLocalizations`
- `setSubscriptionPrice(subscriptionId:pricePointId:)` → `PATCH /v1/subscriptions/{id}` with `included` subscriptionPrices (compound document)
- `fetchSubscriptionPricePoints(subscriptionId:territory:)` → `GET /v1/subscriptions/{id}/pricePoints`
- `fetchSubscriptionGroups(appId:)` → `GET /v1/apps/{id}/subscriptionGroups`

### 3. `Sources/BlitzApp/Services/MCPToolRegistry.swift`

**A) Add 3 tool definitions** (before `return tools` at line 432):

| Tool | Required Params | Key Enums |
|------|----------------|-----------|
| `asc_create_iap` | productId, name, type, displayName, price | type: CONSUMABLE, NON_CONSUMABLE, NON_RENEWING_SUBSCRIPTION |
| `asc_create_subscription` | groupId or groupName, productId, name, displayName, duration, price | `groupId` adds to an existing group; duration: ONE_WEEK..ONE_YEAR |
| `asc_set_app_price` | price | — |

**B) Add category mapping** (in `category(for:)` at line ~469):

```swift
case "asc_create_iap", "asc_create_subscription", "asc_set_app_price":
    return .ascFormMutation
```

### 4. `Sources/BlitzApp/Services/MCPToolExecutor.swift`

**A) Add switch cases** (after `asc_open_submit_preview` at line 245):

```swift
case "asc_create_iap": return try await executeASCCreateIAP(arguments)
case "asc_create_subscription": return try await executeASCCreateSubscription(arguments)
case "asc_set_app_price": return try await executeASCSetAppPrice(arguments)
```

**B) Add 3 execution methods + 1 helper:**

`executeASCSetAppPrice` — Chain: fetch price points → find match → `setAppPrice()` (or `setPriceFree` if "0")

`executeASCCreateIAP` — Chain: create IAP → localize → fetch price points → set price

`executeASCCreateSubscription` — Chain: find-or-create group → localize group → create sub → localize sub → fetch price points → set price via PATCH

`priceMatches(_:target:)` — Static helper for fuzzy price matching ("0.99" vs "0.990")

All methods access the service via `appState.ascManager.service` (existing pattern, line 893).

**C) Add human descriptions** (in `humanDescription` at line ~1631):

```swift
case "asc_create_iap": "Create in-app purchase '{name}' (type: {type})"
case "asc_create_subscription": "Create subscription '{name}' ({duration})"
case "asc_set_app_price": "Set app price to ${price}"
```

## Implementation Order

1. ASCModels.swift (new types, no deps)
2. AppStoreConnectService.swift (versioned helpers + all API methods)
3. MCPToolRegistry.swift (tool definitions + categories)
4. MCPToolExecutor.swift (handlers, depends on 1-3)

## Verification

1. `swift build` — typecheck passes
2. Run `python3 scripts/asc-api-tests/run_all.py` — all 34 API tests pass (confirms endpoints are correct)
3. Start the app, open pureswift2 project, test each MCP tool via Claude Code:
   - `asc_set_app_price price=0.99` then `asc_set_app_price price=0` to revert
   - `asc_create_iap productId=test_coin name="Test Coin" type=CONSUMABLE displayName="100 Coins" price=0.99`
   - `asc_create_subscription groupName="Premium" productId=test_monthly name="Monthly" displayName="Monthly Pro" duration=ONE_MONTH price=4.99`

---

## Progress Tracker

- [x] Step 1: ASCModels.swift — Add ASCInAppPurchase, ASCSubscriptionGroup, ASCSubscription
- [x] Step 2: AppStoreConnectService.swift — Versioned HTTP helpers + all API methods
- [x] Step 3: MCPToolRegistry.swift — 3 tool definitions + category mapping
- [x] Step 4: MCPToolExecutor.swift — 3 handlers + humanDescription + preNavigateASCTool
- [x] Step 5: `swift build` — verify compilation

## Implementation Memo (completed 2026-03-09)

All 5 steps completed successfully. `swift build` passes clean (only pre-existing deprecation warning for `CGWindowListCreateImage`).

### What was done:

**ASCModels.swift** — Added 3 new Decodable model types: `ASCInAppPurchase`, `ASCSubscriptionGroup`, `ASCSubscription`. Placed before the existing `ASCPriceSchedule` section.

**AppStoreConnectService.swift** — Two major additions:
1. **Versioned-path HTTP helpers** (`makeRequest(fullPath:)`, `get(fullPath:)`, `post(fullPath:)`, `patch(fullPath:)`, `delete(fullPath:)`) — parallel to existing `/v1/`-prefixed helpers, these accept a full path like `/v2/inAppPurchases` for endpoints that don't use v1.
2. **17 new API methods** across 3 sections:
   - Paid Pricing: `fetchAppPricePoints`, `setAppPrice`
   - IAP: `createInAppPurchase`, `localizeInAppPurchase`, `fetchInAppPurchasePricePoints`, `setInAppPurchasePrice`, `fetchInAppPurchases`
   - Subscriptions: `createSubscriptionGroup`, `localizeSubscriptionGroup`, `createSubscription`, `localizeSubscription`, `fetchSubscriptionPricePoints`, `setSubscriptionPrice`, `fetchSubscriptionGroups`

**MCPToolRegistry.swift** — Added 3 tool definitions (`asc_create_iap`, `asc_create_subscription`, `asc_set_app_price`) with full parameter schemas and enum constraints. Added category mapping to `.ascFormMutation`.

**MCPToolExecutor.swift** — Added:
- 3 switch cases in `executeTool`
- `priceMatches(_:target:)` static helper for fuzzy USD price matching
- `executeASCSetAppPrice` — fetches price points, matches by price, calls `setAppPrice` (or `setPriceFree` for $0)
- `executeASCCreateIAP` — full chain: create → localize → fetch price points → set price
- `executeASCCreateSubscription` — full chain: find-or-create group → localize group → create sub → localize sub → fetch price points → set price
- 3 human description entries for the approval dialog
- Updated `preNavigateASCTool` to handle the 3 new tools (navigates to pricing tab)

---

## Bundle ID Setup View (added 2026-03-10)

Replaced the "App not found" warning in ASC tabs with a multi-phase inline setup flow.

### Files changed:

**AppStoreConnectService.swift** — Added `enableCapability(bundleIdResourceId:capabilityType:)` method (`POST /v1/bundleIdCapabilities`).

**ASCManager.swift** — Added `resetTabState()` method to clear all tab errors and force re-fetch after bundle ID setup completes.

**BundleIDSetupView.swift** (NEW) — Multi-phase SwiftUI view:
- **Phase 1 (form):** Organization + App Name fields composing `com.{org}.{appName}`, live preview, 28 iOS capability checkboxes in a 2-column grid, "Register Bundle ID" button
- **Phase 2 (creating):** Progress indicator with step-by-step messages ("Registering bundle ID…", "Enabling Push Notifications…")
- **Phase 3 (manual):** Success state showing registered bundle ID + capability count, instruction to create app in ASC with link, "Did you create your app?" prompt with Confirm button
- **Phase 4 (confirming):** Calls `fetchApp(bundleId:)` to verify — if found, clears errors and refreshes tab data; if not, shows error and returns to Phase 3
- Pre-fills: parses existing `metadata.bundleIdentifier` if in `com.xxx.yyy` format, otherwise uses sanitized project name
- Handles existing bundle IDs gracefully (fetches first, skips registration if already exists)
- Saves bundle ID to project metadata after successful registration

**ASCTabContent.swift** — When `tabError` is set and `asc.app == nil`, shows `BundleIDSetupView` instead of the old warning. Regular errors (app exists but network issue) still show the standard error UI with retry.
