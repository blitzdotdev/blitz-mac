---
name: asc-privacy-nutrition-labels
description: Set up App Store privacy nutrition labels (data collection declarations) for an app. Use when the user needs to declare what data their app collects, how it's used, and whether it's linked to the user. Handles both "no data collected" and full data collection declarations.
---

# asc privacy nutrition labels

Use this skill to configure App Store privacy nutrition labels for an app. This is the "App Privacy" section in App Store Connect where you declare what data your app collects, what purposes it's used for, and how it's protected.

## When to use

- User says "set up privacy labels", "configure nutrition labels", "app privacy", "data collection declaration"
- The submission readiness checklist shows "Privacy Nutrition Labels" as incomplete
- User is preparing an app for first submission and needs to declare data practices
- User needs to update privacy declarations after adding new data collection

## Preconditions

- Web session authenticated (cached in keychain from prior `asc web auth login`, or call `asc_web_auth` MCP tool)
- Know your app ID (`ASC_APP_ID` or `--app`)

## Data Model

Each privacy declaration is a tuple of three dimensions:

### Categories (what data is collected)

Grouped by type:

| Grouping | Categories |
|----------|-----------|
| CONTACT_INFO | `NAME`, `EMAIL_ADDRESS`, `PHONE_NUMBER`, `PHYSICAL_ADDRESS`, `OTHER_CONTACT_INFO` |
| HEALTH_AND_FITNESS | `HEALTH`, `FITNESS` |
| FINANCIAL_INFO | `PAYMENT_INFORMATION`, `CREDIT_AND_FRAUD`, `OTHER_FINANCIAL_INFO` |
| LOCATION | `PRECISE_LOCATION`, `COARSE_LOCATION` |
| SENSITIVE_INFO | `SENSITIVE_INFO` |
| CONTACTS | `CONTACTS` |
| USER_CONTENT | `EMAILS_OR_TEXT_MESSAGES`, `PHOTOS_OR_VIDEOS`, `AUDIO`, `GAMEPLAY_CONTENT`, `CUSTOMER_SUPPORT`, `OTHER_USER_CONTENT` |
| BROWSING_HISTORY | `BROWSING_HISTORY` |
| SEARCH_HISTORY | `SEARCH_HISTORY` |
| IDENTIFIERS | `USER_ID`, `DEVICE_ID` |
| PURCHASES | `PURCHASE_HISTORY` |
| USAGE_DATA | `PRODUCT_INTERACTION`, `ADVERTISING_DATA`, `OTHER_USAGE_DATA` |
| DIAGNOSTICS | `CRASH_DATA`, `PERFORMANCE_DATA`, `OTHER_DIAGNOSTIC_DATA` |
| OTHER_DATA | `OTHER_DATA_TYPES` |

### Purposes (why it's collected)

| Purpose ID | Meaning |
|-----------|---------|
| `APP_FUNCTIONALITY` | Required for the app to work |
| `ANALYTICS` | Used for analytics |
| `PRODUCT_PERSONALIZATION` | Used to personalize the product |
| `DEVELOPERS_ADVERTISING` | Used for developer's advertising |
| `THIRD_PARTY_ADVERTISING` | Used for third-party advertising |
| `OTHER_PURPOSES` | Other purposes |

### Data Protections (how it's handled)

| Protection ID | Meaning |
|--------------|---------|
| `DATA_NOT_COLLECTED` | App does not collect this data (mutually exclusive with others) |
| `DATA_LINKED_TO_YOU` | Collected and linked to user identity |
| `DATA_NOT_LINKED_TO_YOU` | Collected but not linked to identity |
| `DATA_USED_TO_TRACK_YOU` | Used for tracking (no purpose needed) |

## Workflow

### 1. Ask the user what data the app collects

Before proceeding, understand the app's data practices. Ask:

- Does the app collect any user data? If no → use the "No data collected" flow
- What types of data does it collect? (e.g., name, email, location, analytics)
- What purposes? (e.g., app functionality, analytics, advertising)
- Is the data linked to the user's identity?
- Is any data used for tracking?

If the user is unsure, analyze the app's source code to determine data collection practices (look for analytics SDKs, location APIs, user accounts, etc.).

### 2a. "No data collected" flow

If the app collects no data:

```bash
# Create the declaration file
cat > /tmp/privacy.json << 'EOF'
{
  "schemaVersion": 1,
  "dataUsages": []
}
EOF

# Apply (this sets DATA_NOT_COLLECTED)
asc web privacy apply --app "APP_ID" --file /tmp/privacy.json --allow-deletes --confirm

# Publish
asc web privacy publish --app "APP_ID" --confirm
```

### 2b. Full data collection flow

Create a declaration file listing all collected data types with their purposes and protections:

```bash
cat > /tmp/privacy.json << 'EOF'
{
  "schemaVersion": 1,
  "dataUsages": [
    {
      "category": "EMAIL_ADDRESS",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "NAME",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "CRASH_DATA",
      "purposes": ["ANALYTICS"],
      "dataProtections": ["DATA_NOT_LINKED_TO_YOU"]
    }
  ]
}
EOF
```

Each entry in `dataUsages` specifies:
- `category` — one category ID from the table above
- `purposes` — array of purpose IDs (what the data is used for)
- `dataProtections` — array of protection IDs (how it's handled)

Each combination of (category, purpose, protection) becomes a separate tuple in the API. For tracking data, use `DATA_USED_TO_TRACK_YOU` as the protection (no purpose needed for tracking entries).

### 3. Preview changes

```bash
asc web privacy plan --app "APP_ID" --file /tmp/privacy.json --pretty
```

This shows a diff of what will be created, updated, or deleted. Review with the user before applying.

### 4. Apply changes

```bash
asc web privacy apply --app "APP_ID" --file /tmp/privacy.json --allow-deletes --confirm
```

- `--allow-deletes` removes remote entries not in the local file
- `--confirm` confirms destructive operations
- This command **never auto-publishes**

### 5. Publish

```bash
asc web privacy publish --app "APP_ID" --confirm
```

This makes the declarations live. Must be done after apply.

### 6. Verify

```bash
asc web privacy pull --app "APP_ID" --pretty
```

## Common App Patterns

### Simple app with no tracking, no user accounts

```json
{
  "schemaVersion": 1,
  "dataUsages": [
    {
      "category": "CRASH_DATA",
      "purposes": ["ANALYTICS"],
      "dataProtections": ["DATA_NOT_LINKED_TO_YOU"]
    }
  ]
}
```

### App with user accounts + analytics

```json
{
  "schemaVersion": 1,
  "dataUsages": [
    {
      "category": "NAME",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "EMAIL_ADDRESS",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "USER_ID",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "PRODUCT_INTERACTION",
      "purposes": ["ANALYTICS"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "CRASH_DATA",
      "purposes": ["ANALYTICS"],
      "dataProtections": ["DATA_NOT_LINKED_TO_YOU"]
    }
  ]
}
```

### Health/fitness app

```json
{
  "schemaVersion": 1,
  "dataUsages": [
    {
      "category": "HEALTH",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "FITNESS",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    },
    {
      "category": "PRECISE_LOCATION",
      "purposes": ["APP_FUNCTIONALITY"],
      "dataProtections": ["DATA_LINKED_TO_YOU"]
    }
  ]
}
```

## Session Authentication

If `asc web privacy` commands fail with 401 or session errors, authenticate via the Blitz MCP tool:

```
Call the asc_web_auth MCP tool to open the Apple ID login window
```

Or ask the user to run in their terminal:
```
asc web auth login --apple-id "EMAIL"
```

## Validation Rules

- `DATA_NOT_COLLECTED` (empty `dataUsages` array) is mutually exclusive — cannot coexist with collected data entries
- Each collected-data entry requires at least one `purpose` and one `dataProtection`
- `DATA_USED_TO_TRACK_YOU` entries are stored without a purpose (tracking is category-wide)
- The `publish` step is required after `apply` — changes are not live until published

## Agent Behavior

- Always ask the user what data their app collects before creating the declaration
- If the user is unsure, analyze the source code for data collection patterns (SDKs, APIs, user auth)
- Use `plan` to preview changes before `apply` — show the diff to the user
- Always `publish` after successful `apply`
- Use `pull` to verify the final state
- **NEVER print session cookies.** All `asc web` commands handle auth internally
- If auth fails, call `asc_web_auth` MCP tool or ask user to run `asc web auth login`

## Notes

- Privacy nutrition labels are required for App Store submission
- Changes are not visible until published
- The declaration file format (`schemaVersion: 1`) is the canonical format used by `asc web privacy`
- Use `asc web privacy catalog` to get the full list of available tokens if needed
