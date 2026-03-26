---
name: asc-iap-attach
description: Attach in-app purchases and subscriptions to an app version for App Store review. Use when the user has IAPs or subscriptions in "Ready to Submit" state that need to be included with a first-time version submission. Works for both first-time and subsequent submissions.
---

# asc iap attach

Use this skill to attach in-app purchases and/or subscriptions to an app version for App Store review. This is the equivalent of checking the boxes in the "Add In-App Purchases or Subscriptions" modal on the version page in App Store Connect.

## When to use

- User is preparing an app version for submission and has IAPs or subscriptions to include
- User says "attach IAPs", "add subscriptions to version", "include in-app purchases for review", "select in-app purchases"
- The app version page in ASC shows an "In-App Purchases and Subscriptions" section with items to select
- IAPs/subscriptions have been created and are in "Ready to Submit" state

## Background

Apple's official App Store Connect API (`POST /v1/subscriptionSubmissions`, `POST /v1/inAppPurchaseSubmissions`) returns `FIRST_SUBSCRIPTION_MUST_BE_SUBMITTED_ON_VERSION` for first-time IAP/subscription submissions. The `reviewSubmissionItems` API also does not support `subscription` or `inAppPurchase` relationship types.

This skill uses Apple's internal iris API (`/iris/v1/subscriptionSubmissions`) via cached web session cookies, which supports the `submitWithNextAppStoreVersion` attribute that the public API lacks. This is the same mechanism the ASC web UI uses when you check the checkbox in the modal.

## Preconditions

- Web session file available at `~/.blitz/asc-agent/web-session.json`. If no session exists or it has expired (401), call the `asc_web_auth` MCP tool first — this opens the Apple ID login window in Blitz and captures the session automatically.
- Know your app ID.
- IAPs and/or subscriptions already exist and are in **Ready to Submit** state.
- A build is uploaded and attached to the current app version.

## Workflow

### 1. Check for an existing web session

```bash
test -f ~/.blitz/asc-agent/web-session.json && echo "SESSION_EXISTS" || echo "NO_SESSION"
```

- If `NO_SESSION`: call the `asc_web_auth` MCP tool first. Wait for it to complete before proceeding.
- If `SESSION_EXISTS`: proceed to the next step.

### 2. List subscriptions and IAPs to identify items to attach

Use the iris API to list subscription groups (with subscriptions) and in-app purchases. Replace `APP_ID` with the actual app ID.

```bash
python3 -c "
import json, os, urllib.request, sys

APP_ID = 'APP_ID_HERE'

session_path = os.path.expanduser('~/.blitz/asc-agent/web-session.json')
if not os.path.isfile(session_path):
    print('ERROR: No web session found. Call asc_web_auth MCP tool first.')
    sys.exit(1)
with open(session_path) as f:
    raw = f.read()

store = json.loads(raw)
session = store['sessions'][store['last_key']]
cookie_str = '; '.join(
    f'{c[\"name\"]}={c[\"value\"]}'
    for cl in session['cookies'].values() for c in cl
    if c.get('name') and c.get('value')
)

headers = {
    'Accept': 'application/json',
    'X-Requested-With': 'XMLHttpRequest',
    'Origin': 'https://appstoreconnect.apple.com',
    'Referer': 'https://appstoreconnect.apple.com/',
    'Cookie': cookie_str
}

def iris_get(path):
    url = f'https://appstoreconnect.apple.com/iris/v1/{path}'
    req = urllib.request.Request(url, method='GET', headers=headers)
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            print('ERROR: Session expired. Call asc_web_auth MCP tool to re-authenticate.')
            sys.exit(1)
        print(f'ERROR: HTTP {e.code} — {e.read().decode()[:200]}')
        sys.exit(1)

# List subscription groups with subscriptions included
print('=== Subscription Groups ===')
sg = iris_get(f'apps/{APP_ID}/subscriptionGroups?include=subscriptions&limit=300&fields%5Bsubscriptions%5D=productId,name,state,submitWithNextAppStoreVersion')
for group in sg.get('data', []):
    print(f'Group: {group[\"attributes\"][\"referenceName\"]} (id={group[\"id\"]})')
for sub in sg.get('included', []):
    if sub['type'] == 'subscriptions':
        a = sub['attributes']
        attached = a.get('submitWithNextAppStoreVersion', False)
        print(f'  Subscription: {a.get(\"name\",\"?\")} | productId={a.get(\"productId\",\"?\")} | state={a.get(\"state\",\"?\")} | attached={attached} | id={sub[\"id\"]}')

# List in-app purchases
print()
print('=== In-App Purchases ===')
iaps = iris_get(f'apps/{APP_ID}/inAppPurchasesV2?limit=300&fields%5BinAppPurchases%5D=productId,name,state,submitWithNextAppStoreVersion')
for iap in iaps.get('data', []):
    a = iap['attributes']
    attached = a.get('submitWithNextAppStoreVersion', False)
    print(f'IAP: {a.get(\"name\",\"?\")} | productId={a.get(\"productId\",\"?\")} | state={a.get(\"state\",\"?\")} | attached={attached} | id={iap[\"id\"]}')
"
```

Look for items with `state=READY_TO_SUBMIT` and `attached=False`. Note their IDs.

### 3. Attach subscriptions via iris API

Use the following script to attach subscriptions. **Do not print or log the cookies** — they contain sensitive session tokens.

```bash
python3 -c "
import json, os, urllib.request, sys

session_path = os.path.expanduser('~/.blitz/asc-agent/web-session.json')
if not os.path.isfile(session_path):
    print('ERROR: No web session found. Call asc_web_auth MCP tool first.')
    sys.exit(1)
with open(session_path) as f:
    raw = f.read()

store = json.loads(raw)
session = store['sessions'][store['last_key']]
cookie_str = '; '.join(
    f'{c[\"name\"]}={c[\"value\"]}'
    for cl in session['cookies'].values() for c in cl
    if c.get('name') and c.get('value')
)

def iris_attach_subscription(sub_id):
    body = json.dumps({'data': {
        'type': 'subscriptionSubmissions',
        'attributes': {'submitWithNextAppStoreVersion': True},
        'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}}}
    }}).encode()
    req = urllib.request.Request(
        'https://appstoreconnect.apple.com/iris/v1/subscriptionSubmissions',
        data=body, method='POST',
        headers={
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'Origin': 'https://appstoreconnect.apple.com',
            'Referer': 'https://appstoreconnect.apple.com/',
            'Cookie': cookie_str
        })
    try:
        resp = urllib.request.urlopen(req)
        print(f'Attached subscription {sub_id}: HTTP {resp.status}')
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if 'already set to submit' in body:
            print(f'Subscription {sub_id} already attached (OK)')
        elif e.code == 401:
            print(f'ERROR: Session expired. Call asc_web_auth MCP tool to re-authenticate.')
        else:
            print(f'ERROR attaching {sub_id}: HTTP {e.code} — {body[:200]}')

# Replace with actual subscription IDs:
iris_attach_subscription('SUB_ID_1')
iris_attach_subscription('SUB_ID_2')
"
```

For in-app purchases (non-subscription), change the type and relationship:

```bash
python3 -c "
import json, os, urllib.request, sys

session_path = os.path.expanduser('~/.blitz/asc-agent/web-session.json')
if not os.path.isfile(session_path):
    print('ERROR: No web session found. Call asc_web_auth MCP tool first.')
    sys.exit(1)
with open(session_path) as f:
    raw = f.read()

store = json.loads(raw)
session = store['sessions'][store['last_key']]
cookie_str = '; '.join(
    f'{c[\"name\"]}={c[\"value\"]}'
    for cl in session['cookies'].values() for c in cl
    if c.get('name') and c.get('value')
)

def iris_attach_iap(iap_id):
    body = json.dumps({'data': {
        'type': 'inAppPurchaseSubmissions',
        'attributes': {'submitWithNextAppStoreVersion': True},
        'relationships': {'inAppPurchaseV2': {'data': {'type': 'inAppPurchases', 'id': iap_id}}}
    }}).encode()
    req = urllib.request.Request(
        'https://appstoreconnect.apple.com/iris/v1/inAppPurchaseSubmissions',
        data=body, method='POST',
        headers={
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'Origin': 'https://appstoreconnect.apple.com',
            'Referer': 'https://appstoreconnect.apple.com/',
            'Cookie': cookie_str
        })
    try:
        resp = urllib.request.urlopen(req)
        print(f'Attached IAP {iap_id}: HTTP {resp.status}')
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if 'already set to submit' in body:
            print(f'IAP {iap_id} already attached (OK)')
        elif e.code == 401:
            print(f'ERROR: Session expired. Call asc_web_auth MCP tool to re-authenticate.')
        else:
            print(f'ERROR attaching {iap_id}: HTTP {e.code} — {body[:200]}')

# Replace with actual IAP IDs:
iris_attach_iap('IAP_ID')
"
```

### 4. Verify attachments

After attachment, call `get_tab_state` for `ascOverview` to refresh the submission readiness checklist. The MCP tool auto-refreshes monetization data and will reflect the updated attachment state.

## Common Errors

### "Subscription is already set to submit with next AppStoreVersion"
The subscription is already attached — this is safe to ignore. HTTP 409 with this message means the item was previously attached.

### 401 Not Authorized (iris API)
The web session has expired. Call the `asc_web_auth` MCP tool to open the Apple ID login window in Blitz — this captures a fresh session and refreshes `~/.blitz/asc-agent/web-session.json` automatically. The user will need to complete Apple ID login + 2FA in the popup. After the tool returns success, retry the iris API calls.

## Agent Behavior

- Always list IAPs and subscriptions first (using Step 2) to identify which are in `READY_TO_SUBMIT` state.
- If the user specifies particular items, match by reference name or product ID.
- If the user says "all", attach every item in `READY_TO_SUBMIT` state.
- **NEVER print, log, or echo session cookies.** The python scripts handle cookies internally without exposing them.
- Use the self-contained python scripts above — do NOT extract cookies separately or pass them as shell variables.
- If iris API returns 409 "already set to submit", treat as success.
- If iris API returns 401, call the `asc_web_auth` MCP tool to open the login window in Blitz, then retry.
- After attachment, call `get_tab_state` for `ascOverview` to refresh the submission readiness checklist.

## Notes

- This skill handles the "attach to version" step only.
- The iris API (`/iris/v1`) mirrors the official ASC API resource types (same JSON:API format) but supports additional attributes like `submitWithNextAppStoreVersion` that the public API lacks.
- The iris API is rate-limited; keep a minimum 350ms interval between requests.
