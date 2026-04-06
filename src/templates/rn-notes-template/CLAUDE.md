# React Native Project — Blitz AI Agent Guide

You are helping a user build a mobile app using React Native and Teenybase. Your job is to understand what they want, plan the implementation, and build it for them. Keep all technical details hidden from the user - they just want their app built.

## MANDATORY FIRST ACTION — Every New Session

**Before doing ANYTHING else** (before reading code, before making changes, before answering questions), you MUST run this pre-flight check:

1. Call `blitz-macos` `app_get_state` to get:
   - `bootedSimulator` — the UDID of the simulator the user is watching in Blitz
   - `isStreaming` — whether Blitz is actively streaming
2. Call `blitz-iphone` `describe_screen` with that UDID to check what's on screen
3. **If your app is NOT visible on the simulator** (e.g. you see the iOS home screen, or a different app, or the app hasn't been built yet):
   - You MUST build and launch the app FIRST, before doing anything the user asked
   - Follow the exact steps below **in order**, then come back to the user's request

**The user is watching the simulator in Blitz. If they ask you to "add a note" or "change the color" but the app isn't even running, you need to get it running first.** Do not skip this. Do not assume the app is installed. Do not try to find the app by swiping through home screens. Build it.

### How to build and launch the app

**You MUST follow these steps in this exact order. Do not skip step 1 — `npx react-native` commands will fail without `node_modules/`.**

**Step 1: Install dependencies and generate iOS project**
```bash
# Skip npm install ONLY if node_modules/ already exists
npm install
```
If the `ios/` folder does not exist, generate it:
```bash
APP_NAME=$(node -e "console.log(require('./app.json').name)")
npx --yes @react-native-community/cli@latest init "$APP_NAME" \
  --directory /tmp/rn-ios-gen --version 0.79.0 --skip-git-init --skip-install
cp -R /tmp/rn-ios-gen/ios .
rm -rf /tmp/rn-ios-gen
```
Then install CocoaPods:
```bash
cd ios && pod install && cd ..
```

**Step 2: Start Metro bundler** (skip if already running — check with `lsof -i :8081`)
```bash
npx react-native start &
```

**Step 3: Start backend** (skip if already running — check with `lsof -i :8787`)
```bash
npm run migrate:backend -- -y
npm run dev:backend &
```

**Step 4: Build and install on the Blitz simulator** (use UDID from `app_get_state`)
```bash
npx react-native run-ios --udid <BOOTED_SIMULATOR_UDID>
```

After the build completes, call `blitz-iphone` `describe_screen` to confirm the app is visible. Then proceed with the user's request.

---

## Blitz IDE

This project is opened in **Blitz**, a native macOS iOS development IDE with integrated simulator streaming. The user sees the simulator live in the Build>Simulator tab.

### MCP Servers

Two MCP servers are configured in `.mcp.json`:

- **`blitz-macos`** — Controls the Blitz app: project state, tab navigation, App Store Connect forms, build pipeline, settings.
- **`blitz-iphone`** — Controls the iOS device/simulator: tap, swipe, type, screenshots, UI hierarchy. See [iPhone MCP docs](https://github.com/blitzdotdev/iPhone-mcp).

### Testing Workflow

After making code changes:
1. Wait briefly for hot reload / rebuild
2. Use `blitz-iphone` `describe_screen` (with the Blitz simulator UDID) to verify the UI updated
3. Use `blitz-iphone` `device_action` to interact (tap buttons, enter text, navigate)
4. Use `blitz-iphone` `describe_screen` again to verify the result

---

## Your Workflow

### Phase 1: Understand the User's Vision

When the user describes their app idea:

1. **If their description is vague**, use the interactive questions tool to gather key requirements:
   - What is the main purpose of the app?
   - Who will use it?
   - What are the 2-3 core features?
   - Should users have accounts, or is it anonymous?

2. **If you have enough information**, proceed directly to setting up and coding the app.

### Phase 2: Set Up, Build & Run the App

**You are responsible for the full setup.** The project may be source code only — no dependencies installed, no iOS project generated, nothing built. Always check first (see mandatory first action above).

Then code the app:
1. **Build the UI**: Modify `src/App.tsx` and create screens in `src/screens/`
2. **Database**: Edit `teenybase.ts` to define your data model
3. **Run Migrations**: `npm run migrate:backend -- -y`
4. **Verify Services**: Check that backend (port 8787) and frontend are running

It is imperative to get the app running and visible on the simulator ASAP, since the user is watching the Blitz simulator tab and expects to see progress quickly.

### Phase 3: Iterate with the User

After the initial build:
- The app is running on the simulator the user is watching — they can see it live
- Make changes based on their feedback (hot reload will update the app automatically)
- Never explain technical implementation details unless asked

---

## Project Structure (Reference)

```
src/
├── App.tsx                 # Main app - START HERE for UI changes
├── api.ts                  # API client (pre-configured, rarely needs changes)
├── screens/                # App screens (create new screens here)
├── components/
│   ├── ui.tsx              # Reusable components (Button, Input, Card, etc.)
│   └── TabBar.tsx          # Bottom navigation
├── hooks/
│   └── useAuth.ts          # Authentication hook (internal)
└── context/
    ├── AuthContext.tsx     # Auth provider - USE THIS for auth state
    └── ThemeContext.tsx    # Theme colors and fonts

teenybase.ts                # DATABASE SCHEMA - edit this for data model
src-backend/worker.ts       # Backend entry (rarely needs changes)
```

---

## Database Schema (teenybase.ts)

### Adding a New Table

```typescript
import { TableData, TableRulesExtensionData, sqlValue } from "teenybase"
import { baseFields, createdTrigger } from "teenybase/scaffolds/fields"

const myTable: TableData = {
  name: "my_items",           // Use snake_case
  autoSetUid: true,           // Auto-generate UUIDs
  fields: [
    ...baseFields,            // id, created, updated (always include)

    // Add your fields:
    { name: "title", type: "text", sqlType: "text", notNull: true },
    { name: "description", type: "editor", sqlType: "text" },
    { name: "count", type: "number", sqlType: "integer", default: sqlValue(0) },
    { name: "is_active", type: "bool", sqlType: "boolean", default: sqlValue(true) },
    { name: "data", type: "json", sqlType: "json" },
    { name: "image", type: "file", sqlType: "text" },

    // Foreign key to users (for user-owned records):
    { name: "owner_id", type: "relation", sqlType: "text", notNull: true,
      foreignKey: { table: "users", column: "id" } },
  ],
  extensions: [
    {
      name: "rules",
      listRule: "auth.uid != null & owner_id == auth.uid",
      viewRule: "auth.uid != null & owner_id == auth.uid",
      createRule: "auth.uid != null & owner_id == auth.uid",
      updateRule: "auth.uid != null & owner_id == auth.uid",
      deleteRule: "auth.uid != null & owner_id == auth.uid",
    } as TableRulesExtensionData,
  ],
  indexes: [{ fields: "owner_id" }],
  triggers: [createdTrigger],
}

// Add to the export at the bottom:
export default {
  tables: [userTable, myTable, /* other tables */],
  // ... rest of config
}
```

### Field Types

| Type | SQLType | Use For |
|------|---------|---------|
| `text` | `text` | Short strings (titles, names) |
| `editor` | `text` | Long text (descriptions, content) |
| `number` | `integer` | Integers |
| `bool` | `boolean` | True/false flags |
| `date` | `timestamp` | Dates and times |
| `json` | `json` | Structured data |
| `file` | `text` | File uploads |
| `relation` | `text` | Foreign key to another table |

### Access Rules

Use these variables in rules:
- `auth.uid` - Current user's ID (null if not logged in)
- `auth.role` - Current user's role
- `owner_id` - The record's owner field (if you have one)
- `new.field` - New value being set (for update rules)

Common patterns:
```typescript
// User can only access their own records
listRule: "auth.uid != null & owner_id == auth.uid"
viewRule: "auth.uid != null & owner_id == auth.uid"

// Public read, authenticated write
listRule: "true"
viewRule: "true"
createRule: "auth.uid != null && auth.uid == owner_id"
updateRule: "auth.uid != null && auth.uid == owner_id"

// Owner or admin
deleteRule: "auth.uid == owner_id | auth.role ~ '%admin'"

// Public view, private list (unlisted)
listRule: "auth.uid != null & owner_id == auth.uid"
viewRule: "true"

```

### After Schema Changes

Always run:
```bash
npm run generate:backend
```

This will generate migration sql files for changes made to the teenybase.ts config since last migration.
Changes will be listed in stdout. Check them and if everything seems correct, continue to migrate the backend

```bash
npm run migrate:backend -- -y
```

---

## Building the Frontend

### App.tsx Structure

The app uses a tab-based navigation pattern with providers:

```tsx
// src/App.tsx
import { useState } from 'react'
import { View, StyleSheet } from 'react-native'
import { ThemeProvider, useTheme } from './context/ThemeContext'
import { AuthProvider } from './context/AuthContext'
import { useAuth } from './context/AuthContext'
import { TabBar, TabName } from './components/TabBar'
// Import your screens...

function AppContent() {
  const { colors } = useTheme()
  const { user, isAuthenticated, isInitializing } = useAuth()
  const [activeTab, setActiveTab] = useState<TabName>('home')

  if (isInitializing) {
    return <Loading message="Loading..." />
  }

  const renderActiveTab = () => {
    switch (activeTab) {
      case 'home': return <HomeScreen />
      case 'profile': return <ProfileScreen />
      // Add more tabs...
    }
  }

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <View style={styles.content}>{renderActiveTab()}</View>
      <TabBar activeTab={activeTab} onTabPress={setActiveTab} />
    </View>
  )
}

export default function App() {
  return (
    <ThemeProvider>
      <AuthProvider>
        <AppContent />
      </AuthProvider>
    </ThemeProvider>
  )
}
```

### Creating a New Screen

```tsx
// src/screens/MyScreen.tsx
import { useState, useEffect, useCallback } from 'react'
import { View, Text, StyleSheet, FlatList, RefreshControl } from 'react-native'
import { useTheme, ThemeColors, FontSizes } from '../context/ThemeContext'
import { Header, Card, Loading, EmptyState, Button } from '../components/ui'
import { api, getCurrentUserId } from '../api'

interface MyItem {
  id: string
  title: string
  // ... other fields
}

export function MyScreen() {
  const { colors, fonts } = useTheme()
  const styles = createStyles(colors, fonts)

  const [items, setItems] = useState<MyItem[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState('')

  const fetchItems = useCallback(async () => {
    try {
      setError('')
      const result = await api.request<{ items: MyItem[] }>('/table/my_items/list?order=-created')
      setItems(result.items)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load')
    } finally {
      setIsLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchItems()
  }, [fetchItems])

  if (isLoading) {
    return (
      <View style={styles.container}>
        <Header title="My Items" />
        <Loading message="Loading..." />
      </View>
    )
  }

  return (
    <View style={styles.container}>
      <Header title="My Items" />
      {items.length === 0 ? (
        <EmptyState title="No items yet" message="Create your first item" />
      ) : (
        <FlatList
          data={items}
          keyExtractor={item => item.id}
          renderItem={({ item }) => (
            <Card style={styles.card}>
              <Text style={styles.title}>{item.title}</Text>
            </Card>
          )}
          contentContainerStyle={styles.list}
        />
      )}
    </View>
  )
}

const createStyles = (colors: ThemeColors, fonts: FontSizes) => StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  list: { padding: 16 },
  card: { marginBottom: 12 },
  title: { fontSize: fonts.lg, color: colors.text, fontWeight: '600' },
})
```

### Available UI Components

Import from `'../components/ui'`:

```tsx
// Button - variants: 'primary', 'secondary', 'danger', 'ghost'
<Button title="Save" onPress={handleSave} variant="primary" loading={isLoading} />

// Input - with label and error state
<Input label="Email" value={email} onChangeText={setEmail} error={emailError} />

// Card - tappable container
<Card onPress={() => {}}><Text>Content</Text></Card>

// Loading - spinner with message
<Loading message="Loading..." />

// EmptyState - placeholder with optional action
<EmptyState title="No items" message="Get started" action={{ label: 'Create', onPress: () => {} }} />

// Header - screen header with optional actions
<Header title="Screen" leftAction={{ label: 'Back', onPress: goBack }} />
```

### Using Theme Colors

Always use theme colors for consistency:

```tsx
const { colors, fonts } = useTheme()

// Available colors:
colors.background    // App background
colors.surface       // Card/input backgrounds
colors.text          // Primary text
colors.textSecondary // Secondary text
colors.textMuted     // Muted/placeholder text
colors.primary       // Primary action color
colors.danger        // Error/delete color
colors.success       // Success color
colors.border        // Border color

// Available font sizes:
fonts.xs, fonts.sm, fonts.base, fonts.lg, fonts.xl, fonts.xxl
```

---

## API Client

The API client is pre-configured in `src/api.ts`. Use it like this:

### Generic Requests

```typescript
import { api, getCurrentUserId } from '../api'

// List records
const result = await api.request<{ items: MyItem[], total: number }>(
  '/table/my_items/list?order=-created&limit=50'
)

// Get single record
const item = await api.request<MyItem>('/table/my_items/view/record-id')

// Create record
const userId = getCurrentUserId()
const newItem = await api.request<MyItem[]>('/table/my_items/insert', {
  method: 'POST',
  body: JSON.stringify({
    values: { title: 'New Item', owner_id: userId },
    returning: '*'
  })
})

// Update record
await api.request('/table/my_items/edit/record-id', {
  method: 'POST',
  body: JSON.stringify({ title: 'Updated Title' })
})

// Delete record
await api.request('/table/my_items/delete', {
  method: 'POST',
  body: JSON.stringify({ where: `id = 'record-id'` })
})
```

### Authentication

```typescript
import { auth, getCurrentUserId, getStoredUser } from '../api'

// Check if authenticated
const userId = getCurrentUserId() // Returns null if not logged in

// Get stored user
const user = getStoredUser()

// Auth actions (handled by useAuth hook)
await auth.login('email@example.com', 'password')
await auth.signUp({ username, email, password, passwordConfirm, name })
await auth.logout()
```

### Using Authentication (AuthContext)

Wrap your app with `AuthProvider` and use `useAuth` from the context:

```tsx
// In App.tsx - wrap with AuthProvider
import { AuthProvider } from './context/AuthContext'

export default function App() {
  return (
    <ThemeProvider>
      <AuthProvider>
        <AppContent />
      </AuthProvider>
    </ThemeProvider>
  )
}

// In any component - use the context
import { useAuth } from '../context/AuthContext'

function MyComponent() {
  const { user, isAuthenticated, isInitializing, login, logout, signUp } = useAuth()

  // isInitializing - true during initial auth check on app load
  // isActionLoading - true during login/signup/logout actions
  // isAuthenticated - true if user is logged in
  // user - current user object or null
}
```

**Important:** Always import `useAuth` from `'../context/AuthContext'`, not from `'../hooks/useAuth'`. The context shares auth state across all components.

## Development Commands

```bash
# Get the simulator UDID that Blitz is streaming (call blitz-macos app_get_state first)

# First-time setup (run once)
npm install
cd ios && pod install && cd ..

# Start Metro bundler
npx react-native start &

# Build and install on the Blitz simulator (use UDID from app_get_state)
npx react-native run-ios --udid <BOOTED_SIMULATOR_UDID>

# After schema changes (teenybase.ts)
npm run generate:backend
npm run migrate:backend -- -y

# Start backend
npm run dev:backend &

# View API documentation
# Open http://localhost:8787/api/v1/doc/ui

# Reset database (delete all data)
rm -rf .local-persist && npm run migrate:backend -- -y
```

## Common Patterns

### User-Owned Records

Most tables should have an `owner_id` field linking to users:

```typescript
{ name: "owner_id", type: "relation", sqlType: "text", notNull: true,
  foreignKey: { table: "users", column: "id" } }
```

With access rules:
```typescript
createRule: "auth.uid != null & owner_id == auth.uid",
listRule: "auth.uid != null & owner_id == auth.uid",
```

When creating records:
```typescript
const userId = getCurrentUserId()
await api.request('/table/my_items/insert', {
  method: 'POST',
  body: JSON.stringify({
    values: { ...data, owner_id: userId },
    returning: '*'
  })
})
```

## Important Notes

1. **Always edit teenybase.ts first** - The API is auto-generated from this file
2. **Always run migrations** after schema changes: `npm run migrate:backend -- -y`
3. **Use theme colors** - Never hardcode colors, use `colors.xxx` from useTheme
4. **Use AuthContext for auth** - Import `useAuth` from `'./context/AuthContext'`, not from hooks
5. **User ID from JWT** - Use `getCurrentUserId()` to get the current user's ID
6. **Keep the user informed** - Tell them what you're building, but hide technical jargon unless asked
7. **Use AsyncStorage for persistence** - This app uses `@react-native-async-storage/async-storage` for data persistence (NOT localStorage). AsyncStorage is async, so always `await` storage operations.

---

### Metro Bundler

Start Metro with `npx react-native start`. If Metro appears corrupted or not responding, kill the process and restart it.

**Rebuilding after native dependency changes:**
```bash
cd ios && NO_FLIPPER=1 pod install && cd ..
npx react-native run-ios --udid <BOOTED_SIMULATOR_UDID>
```

---

## Common Issues

**App not showing on simulator:**
- You must build it first: `npx react-native run-ios --udid <UDID>`
- Get the correct UDID from `blitz-macos` `app_get_state` → `bootedSimulator`
- Do NOT try to find/launch the app before building it

**Records not appearing after creation:**
- Ensure `owner_id` is being set correctly using `getCurrentUserId()`
- Check that access rules allow the user to list their own records

**Migration errors:**
- Check for syntax errors in teenybase.ts
- Try resetting the database: `rm -rf .local-persist && npm run migrate:backend -- -y`

**401 Unauthorized errors:**
- User needs to be logged in
- Check if auth token is loaded (call `await loadTokens()` on app start)

---

## Targeting the Right Device

Always call `blitz-macos` `app_get_state` first to get the `bootedSimulator` UDID. This is the simulator the user is watching in Blitz. Use this UDID for:
- `npx react-native run-ios --udid <UDID>` (building)
- `blitz-iphone` tool calls: pass `udid` parameter to `describe_screen`, `device_action`, etc.

For physical device testing, call `blitz-iphone` `get_execution_context` to determine if the target is a device or simulator and get the appropriate UDID.

---

## Database (Teenybase) — Direct API Access

The database runs as a local Teenybase server. Get the URL via `app_get_state` (returns `database.url` when running). Then use `curl` directly:

```bash
# Get schema
curl -s "$DB_URL/api/v1/settings?raw=true" -H "Authorization: Bearer $TOKEN"

# List records
curl -s -X POST "$DB_URL/api/v1/table/TABLE_NAME/list" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"limit": 50, "offset": 0}'

# Insert record
curl -s -X POST "$DB_URL/api/v1/table/TABLE_NAME/insert" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"values": {"field": "value"}, "returning": "*"}'

# Update record
curl -s -X POST "$DB_URL/api/v1/table/TABLE_NAME/edit/RECORD_ID?returning=*" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"field": "newValue"}'

# Delete record
curl -s -X POST "$DB_URL/api/v1/table/TABLE_NAME/delete" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"where": "id='\''RECORD_ID'\''"}'
```

The `ADMIN_SERVICE_TOKEN` is in the project's `.dev.vars` file.

---

## App Store Connect Tools

### asc_fill_form

Fill App Store Connect form fields. Auto-navigates to the tab (if auto-nav permission is on).

#### Tabs and fields

**appInformation**
| field | type | required | notes |
|---|---|---|---|
| title | string | yes | App name (max 30 chars) |
| subtitle | string | no | (max 30 chars) |
| description | string | yes | (max 4000 chars) |
| keywords | string | yes | comma-separated, max 100 chars total |
| promotionalText | string | no | (max 170 chars) |
| marketingUrl | string | no | |
| supportUrl | string | yes | |
| whatsNew | string | no | first version must omit |
| privacyPolicyUrl | string | yes | |
| copyright | string | yes | e.g. "2026 Acme Inc" |
| primaryCategory | string | yes | GAMES, UTILITIES, PRODUCTIVITY, SOCIAL_NETWORKING, PHOTO_AND_VIDEO, MUSIC, TRAVEL, SPORTS, HEALTH_AND_FITNESS, EDUCATION, BUSINESS, FINANCE, NEWS, FOOD_AND_DRINK, LIFESTYLE, SHOPPING, ENTERTAINMENT, REFERENCE, MEDICAL, NAVIGATION, WEATHER, DEVELOPER_TOOLS |
| contentRightsDeclaration | string | yes | DOES_NOT_USE_THIRD_PARTY_CONTENT / USES_THIRD_PARTY_CONTENT |

Legacy aliases accepted: `storeListing`, `appDetails`

**monetization**
| field | type | required | values |
|---|---|---|---|
| isFree | string | yes | "true" / "false" |

To set a paid price, use the `asc_set_app_price` tool (not `asc_fill_form`). For in-app purchases and subscriptions, use `asc_create_iap` and `asc_create_subscription` — see dedicated tool docs below.

**review.ageRating**
Boolean fields (value "true"/"false"):
`gambling`, `messagingAndChat`, `unrestrictedWebAccess`, `userGeneratedContent`, `advertising`, `lootBox`, `healthOrWellnessTopics`, `parentalControls`, `ageAssurance`

Three-level string fields (value "NONE"/"INFREQUENT_OR_MILD"/"FREQUENT_OR_INTENSE"):
`alcoholTobaccoOrDrugUseOrReferences`, `contests`, `gamblingSimulated`, `gunsOrOtherWeapons`, `horrorOrFearThemes`, `matureOrSuggestiveThemes`, `medicalOrTreatmentInformation`, `profanityOrCrudeHumor`, `sexualContentGraphicAndNudity`, `sexualContentOrNudity`, `violenceCartoonOrFantasy`, `violenceRealistic`, `violenceRealisticProlongedGraphicOrSadistic`

**review.contact**
| field | type | required |
|---|---|---|
| contactFirstName | string | yes |
| contactLastName | string | yes |
| contactEmail | string | yes |
| contactPhone | string | yes |
| notes | string | no |
| demoAccountRequired | string | no |
| demoAccountName | string | conditional |
| demoAccountPassword | string | conditional |

**settings.bundleId**
| field | type | required |
|---|---|---|
| bundleId | string | yes |

### get_tab_state

Read the structured data state of any Blitz tab. Returns form field values, submission readiness, versions, builds, localizations, etc. **Use this instead of screenshots to read UI state.**

| param | type | required | notes |
|---|---|---|---|
| tab | string | no | Tab to query. Defaults to currently active tab. |

Valid tabs: `ascOverview`, `appInformation`, `screenshots`, `monetization`, `review`, `analytics`, `reviews`, `builds`, `groups`, `betaInfo`, `feedback`

Legacy aliases accepted: `storeListing`, `appDetails`

### asc_open_submit_preview

No arguments. Checks all required fields and either opens the Submit for Review modal or returns missing fields.

### app_store_setup_signing

Set up iOS code signing for App Store distribution. Idempotent — re-running skips already-completed steps.

| param | type | required | notes |
|---|---|---|---|
| teamId | string | no | Apple Developer Team ID. Saved to project metadata after first use. |

### app_store_build

Build an IPA for App Store submission. Archives the Xcode project and exports a signed IPA.

| param | type | required | notes |
|---|---|---|---|
| scheme | string | no | Xcode scheme (auto-detected if omitted) |
| configuration | string | no | Build configuration (default: "Release") |

### app_store_upload

Upload an IPA to App Store Connect / TestFlight. Optionally polls until build processing completes.

| param | type | required | notes |
|---|---|---|---|
| ipaPath | string | no | Path to IPA (uses latest app_store_build output if omitted) |
| skipPolling | boolean | no | Skip waiting for build processing (default: false) |

### asc_set_app_price

Set the app's price on the App Store.

| param | type | required | notes |
|---|---|---|---|
| price | string | yes | Price in USD (e.g. "0.99", "0" for free) |
| effectiveDate | string | no | ISO date for scheduled price change (e.g. "2026-06-01"). Omit for immediate. |

### asc_create_iap

Create an in-app purchase. Creates the IAP, adds en-US localization, and sets the price.

| param | type | required | notes |
|---|---|---|---|
| productId | string | yes | Unique product identifier (e.g. com.app.coins100) |
| name | string | yes | Internal reference name |
| type | string | yes | CONSUMABLE, NON_CONSUMABLE, or NON_RENEWING_SUBSCRIPTION |
| displayName | string | yes | User-facing display name (en-US) |
| price | string | yes | Price in USD (e.g. "0.99") |
| description | string | no | User-facing description |

### asc_create_subscription

Create an auto-renewable subscription. Creates or reuses a subscription group.

| param | type | required | notes |
|---|---|---|---|
| groupName | string | yes | Subscription group name (created if doesn't exist) |
| productId | string | yes | Unique product identifier |
| name | string | yes | Internal reference name |
| displayName | string | yes | User-facing display name (en-US) |
| duration | string | yes | ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS, ONE_YEAR |
| price | string | yes | Price in USD (e.g. "4.99") |
| description | string | no | User-facing description |

### Recommended full workflow (code + build + submission)

0. Code the app in the pwd, using the current pwd's framework language
1. Check submission readiness: call `get_tab_state` with `tab: "ascOverview"` — check `submissionReadiness.isComplete` and review `submissionReadiness.missingRequired` for any missing fields
2. Fill all required ASC forms until submission readiness is complete:
    - `asc_fill_form` tab `"appInformation"` — title, description, keywords, supportUrl, privacyPolicyUrl, copyright, primaryCategory, contentRightsDeclaration
    - `asc_fill_form` tab `"monetization"` — isFree (use `asc_set_app_price` for paid pricing)
    - `asc_fill_form` tab `"review.ageRating"` — set all applicable content descriptors
    - `asc_fill_form` tab `"review.contact"` — contactFirstName, contactLastName, contactEmail, contactPhone
    - Screenshots: `screenshots_add_asset` → `screenshots_set_track` (slots 1-10) → `screenshots_save` for APP_IPHONE_67/APP_IPAD_PRO_3GEN_129 (iOS) or APP_DESKTOP (macOS)
    - Re-check `get_tab_state` tab `"ascOverview"` to confirm all required fields are filled
3. **Manual step:** Tell the user to set Privacy Nutrition Labels manually in [App Store Connect](https://appstoreconnect.apple.com) — this is not exposed in Apple's REST API
4. `app_store_setup_signing` teamId=YOUR_TEAM_ID (one-time per bundle ID)
5. `app_store_build`
6. `app_store_upload`
7. `asc_open_submit_preview` — fix any flagged missing fields, then submit
