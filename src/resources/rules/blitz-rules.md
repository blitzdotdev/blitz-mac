# Blitz MCP Integration

This project is open in **Blitz**, a native macOS iOS development environment.
Two MCP servers are active in `.mcp.json`:

- **`blitz-macos`** — Controls Blitz: navigate tabs, read project/simulator state,
  manage builds, fill App Store Connect forms, manage settings.
- **`blitz-iphone`** — Controls the iOS simulator/device: tap, swipe, type text,
  take screenshots, inspect UI hierarchy. See blitz-iphone tool docs for full command list.

Additionally, the **`asc`** CLI (a bundled Go binary for App Store Connect) is available at `~/.blitz/bin/asc`. It shares credentials with Blitz MCP tools automatically via an auth bridge — no separate login required.

## When to use Blitz MCP tools vs `asc` CLI vs direct API calls

**Default to MCP tools.** They are opinionated, safe, and designed for common workflows with built-in approval prompts for mutating operations. **When MCP tools don't cover an operation, use `asc` CLI** — it has 60+ subcommands covering nearly every App Store Connect API endpoint. **Direct API calls (python scripts, curl to api.appstoreconnect.apple.com, urllib, etc.) should be an absolute last resort** — only when both MCP tools AND `asc` CLI genuinely cannot accomplish the task. The `asc` CLI already handles JWT auth, pagination, error handling, and retries; writing raw API scripts bypasses all of that and is fragile.

### Use MCP tools when:
- **Filling ASC forms** — `asc_fill_form` handles app information, monetization, age rating, review contact with validation and auto-navigation
- **Reading app/tab state** — `get_tab_state` returns structured data (form values, submission readiness, builds, versions) without parsing CLI output
- **Build pipeline** — `app_store_setup_signing` → `app_store_build` → `app_store_upload` is the standard flow with progress tracking in Blitz UI
- **Creating IAPs/subscriptions** — `asc_create_iap` and `asc_create_subscription` handle the full creation flow (product + localization + pricing) in one call
- **Setting prices** — `asc_set_app_price` for app pricing, including scheduled price changes
- **Managing screenshots** — `screenshots_add_asset` → `screenshots_set_track` → `screenshots_save` for screenshot upload workflow
- **Submission** — `asc_open_submit_preview` checks readiness and opens the submit modal
- **Anything with a dedicated MCP tool** — the tool exists because it handles the common case safely

### Use `asc` CLI when:
- **Listing/querying resources** — `asc builds list`, `asc versions list`, `asc apps list` for quick lookups not exposed by MCP
- **Bulk operations** — updating localizations for multiple locales, managing many IAPs at once
- **Certificate/profile management** — `asc certificates list`, `asc profiles list`, `asc devices list` for inspecting signing state beyond what `app_store_setup_signing` manages
- **TestFlight management** — `asc testflight` for beta group management, tester invitations, build distribution beyond what MCP exposes
- **Analytics/finance** — `asc analytics`, `asc finance` for pulling reports
- **Release management** — `asc releases`, `asc versions` for version-level operations (phased release, platform-specific versioning)
- **Submission management** — `asc submit create`, `asc submit cancel` for creating/cancelling review submissions
- **Custom product pages** — `asc product-pages` for A/B testing store listings
- **Xcode Cloud** — `asc xcode-cloud` for CI/CD workflow management
- **Game Center** — `asc game-center` for leaderboards and achievements
- **Offer codes** — `asc offer-codes` for subscription promotional codes
- **Any operation not covered by an MCP tool** — check `asc --help` and `asc <command> --help` before resorting to other approaches

### Direct API calls (last resort only):
Writing raw Python/curl/urllib scripts against `api.appstoreconnect.apple.com` should only happen when you have confirmed that **both** MCP tools and `asc` CLI cannot do what's needed. Before writing a script, always:
1. Check if there's an MCP tool for it
2. Run `asc --help` and `asc <command> --help` to see if `asc` covers it
3. Only then consider a direct API call

The `asc` CLI covers 60+ command groups — it almost certainly has what you need. Even for uncommon operations like cancelling a stuck review submission or creating API keys, try `asc` first.

### Examples: MCP vs CLI side-by-side

| Task | MCP tool (preferred) | `asc` CLI (fallback/advanced) |
|---|---|---|
| Set app title & description | `asc_fill_form` tab="appInformation" | `asc metadata update --locale en-US --name "..." --description "..."` |
| Check if ready to submit | `get_tab_state` tab="ascOverview" | `asc versions list` + manual field checks |
| Create a subscription | `asc_create_subscription` (one call) | `asc subscriptions create` + `asc subscriptions add-localization` + `asc pricing set` (three steps) |
| List all builds | Not available via MCP | `asc builds list` |
| Add beta testers | Not available via MCP | `asc testflight add-tester --email user@example.com` |
| Upload IPA | `app_store_upload` (with polling) | `asc builds upload --path ./app.ipa` |
| Get financial reports | Not available via MCP | `asc finance download --period 2026-01` |
| Manage provisioning profiles | `app_store_setup_signing` (automated) | `asc profiles list`, `asc profiles create` (manual control) |

### Auth bridge

Both MCP tools and `asc` CLI share the same App Store Connect API key credentials. When you authenticate in Blitz (via `asc_set_credentials` or the Settings UI), the auth bridge automatically syncs credentials to `~/.blitz/asc-agent/config.json`. The `asc` wrapper at `~/.blitz/bin/asc` reads from this config — no separate `asc auth init` needed.

If `asc` is not on PATH, add it: `export PATH="$HOME/.blitz/bin:$PATH"`

## Testing workflow

After making code changes:
1. Wait briefly for hot reload / rebuild
2. `blitz-iphone` `describe_screen` — verify the UI updated as expected
3. `blitz-iphone` `device_action` — interact (tap buttons, type text, swipe)
4. `blitz-iphone` `describe_screen` — confirm the result
