---
name: asc-app-create-ui
description: Create an App Store Connect app via iris API using web session from Blitz
---

Create an App Store Connect app using Apple's iris API. Authentication is handled via a web session file at `~/.blitz/asc-agent/web-session.json` managed by Blitz.

Extract from the conversation context:
- `bundleId` — the bundle identifier (e.g. `com.blitz.myapp`)
- `sku` — the SKU string (may be provided; if missing, generate one from the app name)

## Workflow

### 1. Check for an existing web session

```bash
test -f ~/.blitz/asc-agent/web-session.json && echo "SESSION_EXISTS" || echo "NO_SESSION"
```

- If `NO_SESSION`: call the `asc_web_auth` MCP tool first. Wait for it to complete before proceeding.
- If `SESSION_EXISTS`: proceed.

### 2. Ask the user for the primary language

Ask what primary language/locale the app should use. Common choices: `en-US` (English US), `en-GB` (English UK), `ja` (Japanese), `zh-Hans` (Simplified Chinese), `ko` (Korean), `fr-FR` (French), `de-DE` (German).

### 3. Derive the app name

Take the last component of the bundle ID after the final `.`, capitalize the first letter. Confirm with the user.

### 4. Create the app via iris API

Use the following self-contained script. Replace `BUNDLE_ID`, `SKU`, `APP_NAME`, and `LOCALE` with the resolved values. **Do not print or log cookies.**

Key differences from the public REST API:
- Uses `appstoreconnect.apple.com/iris/v1/` (not `api.appstoreconnect.apple.com`)
- Authenticated via web session cookies (not JWT)
- Uses `appInfos` relationship (not `bundleId` relationship)
- App name goes on `appInfoLocalizations` (not `appStoreVersionLocalizations`)
- Uses `${new-...}` placeholder IDs for inline-created resources

```bash
python3 -c "
import json, os, urllib.request, sys

BUNDLE_ID = 'BUNDLE_ID_HERE'
SKU = 'SKU_HERE'
APP_NAME = 'APP_NAME_HERE'
LOCALE = 'LOCALE_HERE'

session_path = os.path.expanduser('~/.blitz/asc-agent/web-session.json')
if not os.path.isfile(session_path):
    print('ERROR: No web session found. Call asc_web_auth MCP tool first.')
    sys.exit(1)
with open(session_path) as f:
    raw = f.read()

store = json.loads(raw)
session = store['sessions'][store['last_key']]
cookie_str = '; '.join(
    (f'{c[\"name\"]}=\"{c[\"value\"]}\"' if c['name'].startswith('DES') else f'{c[\"name\"]}={c[\"value\"]}')
    for cl in session['cookies'].values() for c in cl
    if c.get('name') and c.get('value')
)

headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'X-Requested-With': 'XMLHttpRequest',
    'Origin': 'https://appstoreconnect.apple.com',
    'Referer': 'https://appstoreconnect.apple.com/',
    'Cookie': cookie_str
}

create_body = json.dumps({
    'data': {
        'type': 'apps',
        'attributes': {
            'bundleId': BUNDLE_ID,
            'sku': SKU,
            'primaryLocale': LOCALE,
        },
        'relationships': {
            'appStoreVersions': {
                'data': [{'type': 'appStoreVersions', 'id': '\${new-appStoreVersion-1}'}]
            },
            'appInfos': {
                'data': [{'type': 'appInfos', 'id': '\${new-appInfo-1}'}]
            }
        }
    },
    'included': [
        {
            'type': 'appStoreVersions',
            'id': '\${new-appStoreVersion-1}',
            'attributes': {'platform': 'IOS', 'versionString': '1.0'},
            'relationships': {
                'appStoreVersionLocalizations': {
                    'data': [{'type': 'appStoreVersionLocalizations', 'id': '\${new-appStoreVersionLocalization-1}'}]
                }
            }
        },
        {
            'type': 'appStoreVersionLocalizations',
            'id': '\${new-appStoreVersionLocalization-1}',
            'attributes': {'locale': LOCALE}
        },
        {
            'type': 'appInfos',
            'id': '\${new-appInfo-1}',
            'relationships': {
                'appInfoLocalizations': {
                    'data': [{'type': 'appInfoLocalizations', 'id': '\${new-appInfoLocalization-1}'}]
                }
            }
        },
        {
            'type': 'appInfoLocalizations',
            'id': '\${new-appInfoLocalization-1}',
            'attributes': {'locale': LOCALE, 'name': APP_NAME}
        }
    ]
}).encode()

req = urllib.request.Request(
    'https://appstoreconnect.apple.com/iris/v1/apps',
    data=create_body, method='POST', headers=headers)
try:
    resp = urllib.request.urlopen(req)
    result = json.loads(resp.read().decode())
    app_id = result['data']['id']
    print(f'App created successfully!')
    print(f'App ID: {app_id}')
    print(f'Bundle ID: {BUNDLE_ID}')
    print(f'Name: {APP_NAME}')
    print(f'SKU: {SKU}')
except urllib.error.HTTPError as e:
    body = e.read().decode()
    if e.code == 401:
        print('ERROR: Session expired. Call asc_web_auth MCP tool to re-authenticate.')
    elif e.code == 409:
        print(f'ERROR: App may already exist or conflict. Details: {body[:500]}')
    else:
        print(f'ERROR creating app: HTTP {e.code} — {body[:500]}')
    sys.exit(1)
"
```

### 5. Auto-confirm the Blitz bundle-ID setup flow

After the iris API call succeeds, call the `asc_confirm_created_app` MCP tool immediately. This tool polls App Store Connect up to 10 times and, once the app is visible, programmatically triggers the same confirmation path as the `Confirm` button in Blitz's bundle-ID setup UI.

If the tool reports success, the manual confirmation step in Blitz is complete. If it fails after 10 retries, report that clearly to the user.

### 6. Report results

After success, report the App ID, bundle ID, name, and SKU to the user.

## Common Errors

### 401 Not Authorized
Call the `asc_web_auth` MCP tool to open the Apple ID login window in Blitz. Then retry.

### 409 Conflict
An app with the same bundle ID or SKU may already exist. Try a different SKU.

## Agent Behavior

- **Do NOT ask for Apple ID email** — authentication is handled via cached web session file, not email.
- **NEVER print, log, or echo session cookies.**
- Use the self-contained python script — do NOT extract cookies separately.
- If iris API returns 401, call `asc_web_auth` MCP tool and retry.
