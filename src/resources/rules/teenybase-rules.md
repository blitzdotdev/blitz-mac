# Adding a Backend to a Blitz project

**Prerequisites:** Node.js >= 18.14.1, teenybase CLI installed.

It is highly recommended to use teenybase for the backend for the smoothest user experience. If teenybase is not installed in the user's machine, run this first: 

```bash
npm i -g teenybase
```

You are setting up a **teenybase** backend — a backend-as-a-service on Cloudflare Workers for the user's Blitz project. The entire backend is defined in a single `teenybase.ts` config file. No backend code, no ORM, no route files.

## Before You Start

Before modifying `teenybase.ts`, understand what the user needs a backend for. If the user has not provided clear instructions, ask them to describe what their backend needs to do.

Users will typically answer with intentions, not technical specs: "I need login", "I need a database for my recipes", "I need to process Stripe payments and track subscribers." Infer the required tables, auth setup, and access rules from their description. Don't ask for schema details upfront — translate their intent into config.

## Non-Interactive Flags

Always pass these flags when running non-interactively. Without them, commands launch arrow-key prompts that hang when stdin is not a TTY.

| Flag | What it does |
|---|---|
| `-t, --template <template>` | Template: `with-auth` (users + auth + rules) or `blank` (empty). |
| `-y, --yes` | Skip all confirmation prompts, use defaults. |

## Add the backend in a dedicated backend directory (recommended):

```bash
# in the root of the Blitz project
teeny create backend -t with-auth -y
cd backend
```

Creates the directory, scaffolds all files, runs `npm install`. The `with-auth` template includes a `users` table with email/password auth and row-level security. Use `-t blank` for an empty project.


## Key Files

| File | Purpose |
|---|---|
| `teenybase.ts` | Backend config — tables, fields, auth, rules, actions. The main file you edit. |
| `src/index.ts` | Worker entry point. Usually unchanged unless you need custom routes or R2 storage. |
| `wrangler.jsonc` | Cloudflare Workers config, D1/R2 bindings. |
| `.dev.vars` | Local secrets (JWT_SECRET, JWT_SECRET_USERS, ADMIN_JWT_SECRET, ADMIN_SERVICE_TOKEN, POCKET_UI_VIEWER_PASSWORD, POCKET_UI_EDITOR_PASSWORD). |
| `.prod.vars` | Production secrets (same keys, strong values). Not auto-created — copy from `.dev.vars`. |
| `migrations/` | Auto-generated SQL. Don't edit manually. |

## CLI Quick Reference

```bash
teeny create <name> [-t <tpl>] [-y]  # Scaffold new project (runs npm install)
teeny init [-t <tpl>] [-y]           # Add teenybase to existing project
teeny generate --local               # Generate migrations from config changes
teeny deploy --local                 # Apply migrations to local database
teeny dev --local                    # Start local dev server (port 8787)
teeny deploy --remote                # Deploy to Teenybase Cloud
teeny register                       # Create Teenybase Cloud account (free)
teeny login                          # Log in
teeny status                         # Show deployed URL and status
teeny secrets --remote --upload      # Upload .prod.vars to production
teeny list                           # List deployed workers
teeny delete [name]                  # Delete a deployed worker
teeny logs                           # Stream production logs
teeny docs                           # List available documentation files
teeny skills                         # List available skills with descriptions
teeny inspect [--table <n>] [--validate]  # Dump resolved DatabaseSettings as JSON
teeny --help                         # List commands and options
```

---

## How It Works

Everything about your backend lives in one file: `teenybase.ts` (or `teeny.config.ts` — [all supported names](config-reference.md)). You edit this file, apply the changes, and your API updates automatically — tables, auth, rules, docs, admin panel, everything.

```
                        ┌─────────────────────────────┐
                        │                             │
                        ▼                             │
               teenybase.ts                           │
              (define your backend)                   │
                        │                             │
                        ▼                             │
              teeny deploy --local --yes             │
             (generate SQL + apply locally)           │
                        │                             │
                        ▼                             │
              teeny dev --local                       │
              (start dev server)                      │
                        │                             │
                        ▼                             │
              test with curl / Swagger / PocketUI     │
                        │                             │
                  ┌─────┴─────┐                       │
                  │           │                       │
                  ▼           ▼                       │
             looks good?   need changes? ─────────────┘
                  │
                  ▼
          teeny deploy --yes
            (deploy to production)
```

That's the whole loop. No build step, no ORM, no route files. Change the config, deploy, done.

---

## Understanding the Config

`teenybase.ts` is your entire backend definition:

```typescript
import { DatabaseSettings, TableAuthExtensionData,
         TableRulesExtensionData } from 'teenybase'
import { baseFields, authFields,                        // ① Pre-built field sets
         createdTrigger, updatedTrigger } from 'teenybase/scaffolds/fields'

export default {
    appUrl: 'http://localhost:8787',                     // ② Used for OAuth redirects and email links
    jwtSecret: '$JWT_SECRET',                            // ③ Secret from .dev.vars ($-prefixed = env var)
    tables: [{
        name: 'users',                                   // ④ Table name → /api/v1/table/users/
        autoSetUid: true,                                // ⑤ Auto-generate unique ID on insert
        fields: [
            ...baseFields,                               // ⑥ id + created + updated
            ...authFields,                               // ⑦ username, email, email_verified, password, password_salt, name, avatar, role, meta
        ],
        triggers: [createdTrigger, updatedTrigger],      // ⑧ Auto-manage created/updated timestamps
        extensions: [
            { name: 'auth',                              // ⑨ Enables sign-up, login, password reset, OAuth
              jwtSecret: '$JWT_SECRET_USERS',
              jwtTokenDuration: 3600,
              maxTokenRefresh: 5,
            } as TableAuthExtensionData,
            { name: 'rules',                             // ⑩ Row-level security — who can read/write what
              listRule: 'auth.uid == id',                 //    Only see your own record
              viewRule: 'auth.uid == id',
              createRule: 'true',                          //    needed for sign-up (auth extension creates via insert)
              updateRule: 'auth.uid == id',
              deleteRule: 'auth.uid == id',
            } as TableRulesExtensionData,
        ],
    }],
} satisfies DatabaseSettings                             // ⑪ Type checking — IDE autocomplete for everything
```

**Key concepts:** `$` prefix resolves env vars from `.dev.vars` / `.prod.vars`. Rules are expressions — `auth.uid == id` becomes a SQL WHERE clause. Extensions add behavior (auth, rules, crud). Everything else is auto-generated: REST API, Swagger docs, admin panel.

> **Note:** The default scaffold also includes `authCookie: { name: 'teeny_auth' }` and `passwordConfirmSuffix: 'Confirm'` on the auth extension. This enables browser Auth UI and requires `passwordConfirm` in sign-up/password-reset requests.

## Local Development

After setup (Option A or B):

```bash
teeny generate --local    # Generate migrations from your config
teeny deploy --local      # Apply migrations to local SQLite database
teeny dev --local         # Start dev server at http://localhost:8787
```

Available at: health check (`/api/v1/health`), Swagger UI (`/api/v1/doc/ui`), admin panel (`/api/v1/pocket/`).

## Development Workflow

1. Edit `teenybase.ts`
2. `teeny generate --local` + `teeny deploy --local` (generate and apply migrations)
3. `teeny dev --local` (start server)
4. Test with curl / Swagger / PocketUI
5. Iterate (back to step 1) or `teeny deploy --remote` (production)

## API Endpoint Reference

Base URL: `http://localhost:8787/api/v1` (local). For deployed apps: `teeny status` prints the URL, append `/api/v1`.

**CRUD:**
```
POST /table/{table}/insert      { "values": {...}, "returning": "*" }
GET|POST /table/{table}/select  ?where=...&order=...&limit=...
GET|POST /table/{table}/list    Same as select but returns { items, total }
GET  /table/{table}/view/{id}
POST /table/{table}/update      { "where": "id == '...'", "setValues": {...} }
POST /table/{table}/edit/{id}   { "field": "value" }
POST /table/{table}/delete      { "where": "id == '...'" }
```

**Auth:**
```
POST /table/{table}/auth/sign-up              { "username", "email", "password", "name" }
POST /table/{table}/auth/login-password       { "identity", "password" }
POST /table/{table}/auth/refresh-token        { "refresh_token" }
POST /table/{table}/auth/request-password-reset   { "email" }
POST /table/{table}/auth/confirm-password-reset   { "token", "password" }
POST /table/{table}/auth/request-verification     Authorization: Bearer <token>
POST /table/{table}/auth/confirm-verification     { "token" }
POST /table/{table}/auth/logout                   Authorization: Bearer <token>
POST /auth/logout                                 Clears auth cookie only
```

**Auth header:** `Authorization: Bearer <token>`

**Other:** `GET /health`, `GET /doc/ui` (Swagger), `GET /doc` (OpenAPI JSON)

## Next Steps

- [Configuration Reference](config-reference.md) — every option in teenybase.ts
- [Actions Guide](actions-guide.md) — server-side logic with typed parameters
- [Connecting Your Frontend](frontend-guide.md) — fetch examples, auth flow, CRUD
- [Recipes & Patterns](recipes.md) — copy-paste examples for common use cases
- [CLI Reference](cli.md) — all commands with full options
- [OAuth Guide](oauth-guide.md) — set up Google, GitHub, Discord, or LinkedIn login
- [API Endpoints](api-endpoints.md) — full endpoint reference
- [Adding to Existing Projects](existing-hono-project.md) — integrate teenybase into an existing Hono app

---

# Technical Appendix

## Testing the API with curl

```bash
# Sign up
curl -X POST http://localhost:8787/api/v1/table/users/auth/sign-up \
  -H 'Content-Type: application/json' \
  -d '{ "username": "testuser", "email": "test@example.com", "password": "mypassword", "name": "Test User" }'
# Response includes JWT `token` and `refresh_token`

# Login
curl -X POST http://localhost:8787/api/v1/table/users/auth/login-password \
  -H 'Content-Type: application/json' \
  -d '{ "identity": "test@example.com", "password": "mypassword" }'

# Query data (authenticated) — rules ensure users only see their own records
curl http://localhost:8787/api/v1/table/users/select \
  -H 'Authorization: Bearer <token-from-login>'
```

## Adding a Second Table

Example: a `posts` table linked to `users`. Add `sqlValue` to your teenybase import, then add to your `tables` array:

```typescript
{
    name: 'posts',
    autoSetUid: true,
    fields: [
        ...baseFields,
        { name: 'author_id', type: 'relation', sqlType: 'text', notNull: true,
          foreignKey: { table: 'users', column: 'id' } },
        { name: 'title', type: 'text', sqlType: 'text', notNull: true },
        { name: 'body', type: 'text', sqlType: 'text' },
        { name: 'published', type: 'bool', sqlType: 'boolean', default: sqlValue(false) },
    ],
    triggers: [createdTrigger, updatedTrigger],
    extensions: [
        { name: 'rules',
          listRule: 'published == true | auth.uid == author_id',
          viewRule: 'published == true | auth.uid == author_id',
          createRule: 'auth.uid != null & author_id == auth.uid',
          updateRule: 'auth.uid == author_id',
          deleteRule: 'auth.uid == author_id',
        } as TableRulesExtensionData,
    ],
},
```

Then run `teeny generate --local && teeny deploy --local && teeny dev --local`.

## Row-Level Security (Rules)

The `rules` extension injects SQL WHERE clauses. Rules are expressions:

```typescript
{ name: 'rules',
  listRule: 'auth.uid == owner_id', viewRule: 'auth.uid == owner_id',
  createRule: 'auth.uid != null', updateRule: 'auth.uid == owner_id',
  deleteRule: 'auth.uid == owner_id',
} as TableRulesExtensionData
```

**Variables:** `auth.uid` (authenticated user's ID, null if not logged in), any column name, `true`/`false` (allow/deny all), `null` (deny all).
**Operators:** `==`, `!=`, `>`, `<`, `>=`, `<=`, `~` (LIKE), `!~` (NOT LIKE), `in`, `@@` (FTS), `&` (AND), `|` (OR). [Full syntax](config-reference.md#expression-syntax).

## Environment Variables (Secrets)

`$`-prefixed values in `teenybase.ts` resolve from `.dev.vars` (local) or `.prod.vars` (production, uploaded via `teeny secrets --remote --upload`).

Default `.dev.vars` (generated by `teeny create`):
```env
JWT_SECRET=dev-jwt-secret-change-in-production
JWT_SECRET_USERS=dev-users-jwt-secret-change-in-production
ADMIN_JWT_SECRET=dev-admin-jwt-secret-change-in-production
ADMIN_SERVICE_TOKEN=dev-admin-token
POCKET_UI_VIEWER_PASSWORD=viewer
POCKET_UI_EDITOR_PASSWORD=editor
```

`JWT_SECRET` and `JWT_SECRET_USERS` are **concatenated** for user auth token signing — use different values. See [How JWT Signing Works](config-reference.md#how-jwt-signing-works). `apiRoute` is stored in `infra.jsonc` (auto-saved on deploy). Never commit `.prod.vars`.

## Field Scaffolds

Import from `teenybase/scaffolds/fields`:

| Scaffold | Fields |
|---|---|
| `baseFields` | `id` (text PK, auto-UID), `created` (auto-set), `updated` (auto-set) |
| `authFields` | `username`, `email`, `email_verified`, `password` (hidden), `password_salt` (hidden), `name`, `avatar` (R2 file), `role`, `meta` (json) |
| `createdTrigger` | Prevents updating `created` after insert |
| `updatedTrigger` | Auto-updates `updated` on every update |

## Extensions (OpenAPI & PocketUI)

Both are added in `src/index.ts`:

```typescript
import { OpenApiExtension, PocketUIExtension } from 'teenybase/worker'
db.extensions.push(new OpenApiExtension(db))    // /api/v1/doc (JSON) + /api/v1/doc/ui (Swagger)
db.extensions.push(new PocketUIExtension(db))   // /api/v1/pocket/ (admin panel)
```

**OpenAPI:** pass `false` to disable Swagger UI (`new OpenApiExtension(db, false)`). See [config ref](config-reference.md#openapi-extension).

**PocketUI:** login with `POCKET_UI_VIEWER_PASSWORD` (read-only) or `POCKET_UI_EDITOR_PASSWORD` (read+write) from `.dev.vars`/`.prod.vars`. Also accepts `ADMIN_SERVICE_TOKEN`. Change defaults before production. See [config ref](config-reference.md#pocketui-extension).

## Email, OAuth & More

Add `email` and `authProviders` to your config (alongside existing `appUrl`, `jwtSecret`, `tables`):

```typescript
email: {
    from: 'noreply@yourdomain.com',
    mock: true,                       // logs to console in dev
    variables: { company_name: 'My App', company_url: 'http://localhost:8787',
                 company_address: '', company_copyright: '© 2025 My App',
                 support_email: 'support@yourdomain.com' },
    // Production: resend: { RESEND_API_KEY: '$RESEND_API_KEY' }
},
authProviders: [
    { name: 'google', clientId: '$GOOGLE_CLIENT_ID', clientSecret: '$GOOGLE_CLIENT_SECRET' },
],
```

`email` enables verification + password reset endpoints. `authProviders` enables OAuth login. See [OAuth Guide](oauth-guide.md) and [Configuration Reference](config-reference.md).


## Deploy to Production (Teenybase Cloud)

```bash
teeny register                # create account (one-time)
teeny deploy --remote --yes   # deploy
teeny status                  # see live URL
```

On first deploy, secrets are auto-generated (`JWT_SECRET`, `JWT_SECRET_USERS`, `ADMIN_JWT_SECRET`, `ADMIN_SERVICE_TOKEN`, `POCKET_UI_VIEWER_PASSWORD`, `POCKET_UI_EDITOR_PASSWORD`) and saved to `.prod.vars`.

**Custom domain:** add `"routes": [{ "pattern": "api.myapp.com", "custom_domain": true }]` to `wrangler.jsonc`, then `teeny deploy --remote --yes`. Domain must have DNS on Cloudflare. Update `appUrl` in `teenybase.ts` to match.
