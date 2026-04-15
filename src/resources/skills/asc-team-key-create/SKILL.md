---
name: asc-team-key-create
description: Create a new App Store Connect Team API Key with Admin permissions, download the one-time .p8 private key, and store it in ~/.blitz. Use when the user needs a new ASC API key for CLI auth, CI/CD, or external tooling.
---

# asc team key create

Use this skill to create a new App Store Connect API Key with Admin permissions via Apple's iris API, download the one-time .p8 private key, and save it to `~/.blitz`.

## When to use

- User asks to "create an API key", "generate a team key", "new ASC key"
- User needs a fresh key for `asc auth login`, CI/CD pipelines, or external tooling
- User wants to rotate or replace an existing API key

## Preconditions

- Web session file available at `~/.blitz/asc-agent/web-session.json`. If no session exists or it has expired (401), call the `asc_web_auth` MCP tool first — this opens the Apple ID login window in Blitz and captures the session automatically.
- The authenticated Apple ID must have Account Holder or Admin role.

## Workflow

### 1. Check for an existing web session

Before anything else, check if a web session file already exists:

```bash
test -f ~/.blitz/asc-agent/web-session.json && echo "SESSION_EXISTS" || echo "NO_SESSION"
```

- If `NO_SESSION`: call the `asc_web_auth` MCP tool first to open the Apple ID login window in Blitz. Wait for it to complete before proceeding.
- If `SESSION_EXISTS`: proceed to the next step.

### 2. Ask the user for a key name

Ask the user what they want to name the key (the `nickname` field in ASC). This is a required input — do not guess or use a default.

### 3. Create the key, download the .p8, and save it

Use the following self-contained script. Replace `KEY_NAME` with the user's chosen name. **Do not print or log cookies** — they contain sensitive session tokens.

```bash
python3 -c "
import json, urllib.request, base64, os, sys, time

KEY_NAME = 'KEY_NAME_HERE'

# Read web session file (silent — never print these)
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
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'X-Requested-With': 'XMLHttpRequest',
    'Origin': 'https://appstoreconnect.apple.com',
    'Referer': 'https://appstoreconnect.apple.com/',
    'Cookie': cookie_str
}

# Step 1: Create the API key
create_body = json.dumps({
    'data': {
        'type': 'apiKeys',
        'attributes': {
            'nickname': KEY_NAME,
            'roles': ['ADMIN'],
            'allAppsVisible': True,
            'keyType': 'PUBLIC_API'
        }
    }
}).encode()

req = urllib.request.Request(
    'https://appstoreconnect.apple.com/iris/v1/apiKeys',
    data=create_body, method='POST', headers=headers)
try:
    resp = urllib.request.urlopen(req)
    create_data = json.loads(resp.read().decode())
except urllib.error.HTTPError as e:
    body = e.read().decode()
    if e.code == 401:
        print('ERROR: Session expired. Call asc_web_auth MCP tool to re-authenticate.')
    elif e.code == 409:
        print(f'ERROR: A key with this name may already exist. Details: {body[:300]}')
    else:
        print(f'ERROR creating key: HTTP {e.code} — {body[:300]}')
    sys.exit(1)

key_id = create_data['data']['id']
can_download = create_data['data']['attributes'].get('canDownload', False)
print(f'Created API key \"{KEY_NAME}\" — Key ID: {key_id}')

if not can_download:
    print('ERROR: Key created but canDownload is false. Cannot retrieve private key.')
    sys.exit(1)

# Step 2: Download the one-time private key
time.sleep(0.5)
dl_headers = dict(headers)
dl_headers.pop('Content-Type', None)
req = urllib.request.Request(
    f'https://appstoreconnect.apple.com/iris/v1/apiKeys/{key_id}?fields%5BapiKeys%5D=privateKey',
    method='GET', headers=dl_headers)
try:
    resp = urllib.request.urlopen(req)
    dl_data = json.loads(resp.read().decode())
except urllib.error.HTTPError as e:
    print(f'ERROR downloading key: HTTP {e.code} — {e.read().decode()[:300]}')
    sys.exit(1)

pk_b64 = dl_data['data']['attributes'].get('privateKey')
if not pk_b64:
    print('ERROR: No privateKey in response. The key may have already been downloaded.')
    sys.exit(1)

private_key_pem = base64.b64decode(pk_b64).decode()

# Step 3: Get the issuer ID from the provider relationship
time.sleep(0.35)
req = urllib.request.Request(
    f'https://appstoreconnect.apple.com/iris/v1/apiKeys/{key_id}?include=provider',
    method='GET', headers=dl_headers)
try:
    resp = urllib.request.urlopen(req)
    provider_data = json.loads(resp.read().decode())
    issuer_id = None
    for inc in provider_data.get('included', []):
        if inc['type'] == 'contentProviders':
            issuer_id = inc['id']
            break
    if not issuer_id:
        issuer_id = provider_data['data']['relationships']['provider']['data']['id']
except Exception:
    issuer_id = 'UNKNOWN'

# Step 4: Save .p8 file to ~/.blitz
blitz_dir = os.path.expanduser('~/.blitz')
os.makedirs(blitz_dir, exist_ok=True)
p8_path = os.path.join(blitz_dir, f'AuthKey_{key_id}.p8')
with open(p8_path, 'w') as f:
    f.write(private_key_pem)
os.chmod(p8_path, 0o600)

print(f'Private key saved to: {p8_path}')
print(f'Issuer ID: {issuer_id}')
print(f'Key ID: {key_id}')
print()
print('To use with asc CLI:')
print(f'  asc auth login --key-id {key_id} --issuer-id {issuer_id} --private-key-path {p8_path}')
print()
print('WARNING: This .p8 file can only be downloaded ONCE. Keep it safe.')
"
```

### 4. Fill the credential form via MCP

After the script succeeds, call the `asc_set_credentials` MCP tool to pre-fill the Blitz credential form:

```
asc_set_credentials(issuerId: "<issuer_id>", privateKeyPath: "~/.blitz/AuthKey_<key_id>.p8")
```

`keyId` is optional here because Blitz can derive it from Apple's default `AuthKey_<KEYID>.p8` filename.
This lets the user visually verify the values and confirm in Blitz.

### 5. Report results to the user

After the script runs, report:
- Key name and Key ID
- Issuer ID
- File path of the saved .p8
- That the credential form has been pre-filled — they should verify and confirm in Blitz

## Common Errors

### 401 Not Authorized
The web session has expired or doesn't exist. Call the `asc_web_auth` MCP tool — this opens the Apple ID login window in Blitz and refreshes `~/.blitz/asc-agent/web-session.json` automatically. Then retry the key creation script.

### 409 Conflict
A key with the same name may already exist, or another conflict occurred. Try a different name.

### "No privateKey in response"
The key's one-time download window has passed (`canDownload` flipped to `false`). This happens if the key was already downloaded. The key must be revoked and a new one created.

## Agent Behavior

- **Always ask the user for the key name** before creating. Do not use defaults.
- **NEVER print, log, or echo session cookies.** The python script handles cookies internally.
- Use the self-contained python script above — do NOT extract cookies separately or pass them as shell variables.
- After creation, confirm the .p8 file exists and report the path.
- If iris API returns 401, tell the user to re-authenticate via Blitz or `asc web auth login`.
- The iris API is rate-limited; the script includes 350ms+ delays between requests.
- The .p8 private key file is saved with `0600` permissions (owner read/write only).

## Notes

- The private key can only be downloaded **once** from Apple. After the first download, `canDownload` flips to `false` permanently. The saved .p8 file is the only copy.
- The issuer ID is the same for all keys in the team — it's the content provider UUID.
- Keys are created with `allAppsVisible: true` (access to all apps in the team).
- To revoke a key later, use `PATCH /iris/v1/apiKeys/{keyId}` with `{"data": {"type": "apiKeys", "id": "KEY_ID", "attributes": {"isActive": false}}}`.
