# Getting Started with Teenybase

This guide walks you through creating a teenybase backend from scratch. By the end, you'll have a running API with user authentication, row-level security, auto-generated docs, and an admin panel.

**Time:** 10-15 minutes
**Prerequisites:** Node.js >= 18.14.1, teenybase installed via npm i teenybase

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

## 1. Create a Project

```bash
npx teeny create my-app
cd my-app
```

This creates a new directory with everything you need:

```
my-app/
  package.json          # dependencies (teenybase, hono, wrangler)
  wrangler.jsonc        # Cloudflare Workers config with D1 binding
  tsconfig.json         # TypeScript config with virtual:teenybase path
  teenybase.ts          # your backend schema
  src/index.ts          # worker entrypoint (5 lines)
  worker-configuration.d.ts  # type declarations
  .dev.vars             # local dev secrets
  .gitignore
  migrations/           # auto-generated SQL migrations
```

The default template (`with-auth`) includes a `users` table with email/password authentication and row-level security. Use `--template blank` for an empty project.

### Understanding the Config

Open `teenybase.ts` — this is your entire backend definition:

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

**Key concepts:** `$` prefix resolves env vars from `.dev.vars` / `.prod.vars`. Rules are expressions, not code — `auth.uid == id` becomes a SQL WHERE clause. Extensions add behavior (auth, rules, crud). Everything else is auto-generated: REST API, Swagger docs, admin panel.

## 2. Set Up the Local Database

```bash
npx teeny deploy --local --yes
```

This generates migration SQL from your config and applies it to the local SQLite database.

## 3. Start the Dev Server

```bash
npx teeny dev --local
```

Your API is now running at `http://localhost:8787`. Try these:

- **Health check:** `http://localhost:8787/api/v1/health`
- **Swagger UI:** `http://localhost:8787/api/v1/doc/ui`
- **Admin panel:** `http://localhost:8787/api/v1/pocket/`

## 4. Test the API

### Sign up a user

```bash
curl -X POST http://localhost:8787/api/v1/table/users/auth/sign-up \
  -H 'Content-Type: application/json' \
  -d '{
    "username": "testuser",
    "email": "test@example.com",
    "password": "mypassword",
    "name": "Test User"
  }'
```

Response includes a JWT `token` and `refresh_token`.

### Login

```bash
curl -X POST http://localhost:8787/api/v1/table/users/auth/login-password \
  -H 'Content-Type: application/json' \
  -d '{
    "identity": "test@example.com",
    "password": "mypassword"
  }'
```

### Query data (authenticated)

```bash
curl http://localhost:8787/api/v1/table/users/select \
  -H 'Authorization: Bearer <token-from-login>'
```

The rules extension ensures users can only see their own records (`auth.uid == id`).

## 5. Add a Second Table

The real power shows when you add relationships. Let's add a `posts` table linked to `users`.

First, add `sqlValue` to your teenybase import:

```typescript
import { DatabaseSettings, TableAuthExtensionData,
         TableRulesExtensionData, sqlValue } from 'teenybase'
```

Then add this as a second entry in your `tables` array (after the existing users table):

```typescript
{
    name: 'posts',
    autoSetUid: true,
    fields: [
        ...baseFields,
        {
            name: 'author_id', type: 'relation', sqlType: 'text', notNull: true,
            foreignKey: { table: 'users', column: 'id' },
        },
        { name: 'title', type: 'text', sqlType: 'text', notNull: true },
        { name: 'body', type: 'text', sqlType: 'text' },
        { name: 'published', type: 'bool', sqlType: 'boolean', default: sqlValue(false) },
    ],
    triggers: [createdTrigger, updatedTrigger],
    extensions: [
        {
            name: 'rules',
            listRule: 'published == true | auth.uid == author_id',   // public posts + own drafts
            viewRule: 'published == true | auth.uid == author_id',
            createRule: 'auth.uid != null & author_id == auth.uid',  // must set yourself as author
            updateRule: 'auth.uid == author_id',                     // only edit your own
            deleteRule: 'auth.uid == author_id',
        } as TableRulesExtensionData,
    ],
},
```

Apply the migration and restart:

```bash
npx teeny deploy --local --yes
npx teeny dev --local
```

Now try the new endpoints:

```bash
# Create a post (use the token from step 4)
curl -X POST http://localhost:8787/api/v1/table/posts/insert \
  -H 'Authorization: Bearer <your-token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "values": {
      "author_id": "<your-user-id>",
      "title": "Hello World",
      "body": "My first post"
    }
  }'

# List posts (public + your own drafts)
curl http://localhost:8787/api/v1/table/posts/select \
  -H 'Authorization: Bearer <your-token>'
```

Check Swagger UI at `http://localhost:8787/api/v1/doc/ui` — the posts endpoints are already documented with field types and examples.

## 6. Add Email, OAuth & More

Here's what makes the single-config approach powerful — email verification, password reset, Google login, and more are all just config entries in the same file. Here's what a more complete `teenybase.ts` looks like:

```typescript
import { DatabaseSettings, TableAuthExtensionData,
         TableRulesExtensionData } from 'teenybase'
import { baseFields, authFields,
         createdTrigger, updatedTrigger } from 'teenybase/scaffolds/fields'

export default {
    appUrl: 'http://localhost:8787',
    jwtSecret: '$JWT_SECRET',

    email: {                                                // ← Email verification & password reset
        from: 'noreply@yourdomain.com',
        mock: true,                                         //   logs to console in dev (no provider needed)
        variables: {
            company_name: 'My App',
            company_url: 'http://localhost:8787',
            company_address: '',
            company_copyright: '© 2025 My App',
            support_email: 'support@yourdomain.com',
        },
        // For production, add: resend: { RESEND_API_KEY: '$RESEND_API_KEY' }
    },

    authProviders: [                                        // ← Google login (GitHub, Discord, LinkedIn too)
        {
            name: 'google',                                 //   preset — URLs and scopes auto-configured
            clientId: '$GOOGLE_CLIENT_ID',
            clientSecret: '$GOOGLE_CLIENT_SECRET',
        },
    ],

    tables: [{
        name: 'users',
        autoSetUid: true,
        fields: [...baseFields, ...authFields],
        triggers: [createdTrigger, updatedTrigger],
        extensions: [
            { name: 'auth', jwtSecret: '$JWT_SECRET_USERS', jwtTokenDuration: 3600, maxTokenRefresh: 5 } as TableAuthExtensionData,
            { name: 'rules',
              listRule: 'auth.uid == id', viewRule: 'auth.uid == id',
              createRule: 'true', updateRule: 'auth.uid == id', deleteRule: 'auth.uid == id',
            } as TableRulesExtensionData,
        ],
    }],
} satisfies DatabaseSettings
```

> **That's it.** Adding `email` enables verification and password reset endpoints. Adding `authProviders` enables OAuth login endpoints. No extra packages, no route files, no middleware wiring. See the [OAuth Guide](oauth-guide.md) for provider setup and the [Configuration Reference](config-reference.md) for all options.

## 7. Deploy to Production

### Option A: Teenybase Cloud

No Cloudflare account needed. Teenybase Cloud hosts your backend for you.

```bash
npx teeny register      # create account (one-time)
npx teeny deploy --remote --yes
```

Your backend is live. Run `npx teeny status` to see the URL.

### Option B: Self-Hosted (Your Cloudflare Account)

```bash
# 1. Authenticate with Cloudflare
npx wrangler login

# 2. Create a D1 database
npx wrangler d1 create my-app-db
# Replace the placeholder database_id (00000000-...) in wrangler.jsonc with the real ID from the output

# 3. Create production secrets
cp .dev.vars .prod.vars
# Edit .prod.vars with production values (strong JWT secrets, etc.)

# 4. Deploy
npx teeny deploy --remote --yes

# 5. Upload secrets
npx teeny secrets --remote --upload
```

---

## Custom Domain (Self-Hosted)

By default, your worker is available at `https://<name>.<subdomain>.workers.dev`. To use your own domain, add a `routes` entry to `wrangler.jsonc`:

```jsonc
{
    "routes": [
        { "pattern": "api.myapp.com", "custom_domain": true }
    ]
}
```

Then deploy:

```bash
npx teeny deploy --remote --yes
```

The domain must have its DNS managed by Cloudflare (orange-clouded in the dashboard). Cloudflare provisions the SSL certificate automatically.

> **Important:** If you set a custom domain, update `appUrl` in `teenybase.ts` to match (e.g., `https://api.myapp.com`). `appUrl` is used for OAuth redirect validation and email template links.

---

## Field Scaffolds

Teenybase provides pre-built field sets to speed up schema definition:

### `baseFields`
Standard fields for every table:
- `id` — text primary key (auto-generated UID)
- `created` — timestamp (auto-set on insert)
- `updated` — timestamp (auto-set on update)

### `authFields`
Fields for user authentication (use with the `auth` extension):
- `username` — unique text
- `email` — unique text
- `email_verified` — boolean (default false)
- `password` — text (hidden from API responses)
- `password_salt` — text (hidden from API responses)
- `name` — text
- `avatar` — file (stored in R2)
- `role` — text (audience/role claim in JWT)
- `meta` — json (arbitrary metadata)

### Triggers
- `createdTrigger` — prevents updating the `created` column after insert
- `updatedTrigger` — auto-updates the `updated` column on every update

Import from `teenybase/scaffolds/fields`:
```typescript
import { baseFields, authFields, createdTrigger, updatedTrigger } from 'teenybase/scaffolds/fields'
```

---

## Row-Level Security (Rules)

The `rules` extension adds access control by injecting SQL WHERE clauses. Rules are JavaScript-like expressions:

```typescript
{
    name: 'rules',
    listRule: 'auth.uid == owner_id',       // can list only own records
    viewRule: 'auth.uid == owner_id',       // can view only own records
    createRule: 'auth.uid != null',          // must be logged in to create
    updateRule: 'auth.uid == owner_id',     // can update only own records
    deleteRule: 'auth.uid == owner_id',     // can delete only own records
} as TableRulesExtensionData
```

**Available variables in rules:**
- `auth.uid` — the authenticated user's ID (null if not logged in)
- Any column name from the table (e.g., `owner_id`, `published`, `role`)
- `true` / `false` — allow/deny all
- `null` — deny all (rule not set)

**Operators:** `==`, `!=`, `>`, `<`, `>=`, `<=`, `~` (LIKE), `!~` (NOT LIKE), `in`, `@@` (FTS), `&` (AND), `|` (OR). [Full syntax reference](config-reference.md#expression-syntax).

---

## Environment Variables (Secrets)

Values prefixed with `$` in `teenybase.ts` are resolved from environment variables:

- **Local development:** `.dev.vars` file (auto-loaded by wrangler dev)
- **Production:** `.prod.vars` file, uploaded via `teeny secrets --remote --upload`

Default `.dev.vars` (generated by `teeny create`):

> `JWT_SECRET` and `JWT_SECRET_USERS` are **concatenated** to form the signing key for user auth tokens. Use different values for each. See [How JWT Signing Works](config-reference.md#how-jwt-signing-works).

```env
JWT_SECRET=dev-jwt-secret-change-in-production
JWT_SECRET_USERS=dev-users-jwt-secret-change-in-production
ADMIN_JWT_SECRET=dev-admin-jwt-secret-change-in-production
ADMIN_SERVICE_TOKEN=dev-admin-token
POCKET_UI_VIEWER_PASSWORD=viewer
POCKET_UI_EDITOR_PASSWORD=editor
```

`apiRoute` is stored in the `infra.jsonc` file (CLI project config, committed to git) rather than in secrets files. It is auto-saved when you deploy.

For production, generate strong random secrets and never commit `.prod.vars`.

---

## API Docs (OpenAPI)

Your app auto-generates an OpenAPI 3.1.0 spec at `/api/v1/doc` and interactive Swagger UI at `/api/v1/doc/ui`. Every CRUD endpoint, auth route, and action is included with request/response schemas.

The OpenAPI extension is added in your worker entry point:

```typescript
import { OpenApiExtension } from 'teenybase/worker'

db.extensions.push(new OpenApiExtension(db))
```

To disable the Swagger UI (keep only the JSON spec):

```typescript
db.extensions.push(new OpenApiExtension(db, false))
```

See [Configuration Reference — OpenAPI Extension](config-reference.md#openapi-extension) for details.

---

## Admin Panel (PocketUI)

Every teenybase app includes a built-in admin panel at `/api/v1/pocket/`. It lets you browse tables, view/edit records, and manage data.

The PocketUI extension is added in your worker entry point:

```typescript
import { PocketUIExtension } from 'teenybase/worker'

db.extensions.push(new PocketUIExtension(db))
```

**Login credentials** are set in `.dev.vars` (local) or `.prod.vars` (production):

```env
POCKET_UI_VIEWER_PASSWORD=viewer     # read-only access
POCKET_UI_EDITOR_PASSWORD=editor     # read + write access
```

The admin panel also accepts the `ADMIN_SERVICE_TOKEN` for superadmin access.

**Routes:**
- `/api/v1/pocket/` — admin panel UI
- `/api/v1/pocket/login` — login page (GET) / authenticate (POST)
- `/api/v1/pocket/logout` — logout, clears session cookie

> **Important:** Change these passwords before deploying to production. The default values (`viewer`, `editor`) are for local development only.

See [Configuration Reference — PocketUI Extension](config-reference.md#pocketui-extension) for advanced options.

---

## Auto-Generated Secrets

On first `teeny deploy --remote`, the CLI detects missing secrets and auto-generates them:

- `JWT_SECRET`, `JWT_SECRET_USERS` — random 64-char hex strings for JWT signing
- `ADMIN_JWT_SECRET`, `ADMIN_SERVICE_TOKEN` — for admin API access
- `POCKET_UI_VIEWER_PASSWORD`, `POCKET_UI_EDITOR_PASSWORD` — for admin panel access

These are saved to `.prod.vars` and uploaded to the worker. You can also generate them manually with strong random values.

---

## Next Steps

- **Stream production logs** — run `teeny logs` to see live requests and errors from your deployed worker
- [Configuration Reference](config-reference.md) — every option in teenybase.ts
- [Actions Guide](actions-guide.md) — server-side logic with typed parameters
- [Connecting Your Frontend](frontend-guide.md) — fetch examples, auth flow, CRUD
- [Recipes & Patterns](recipes.md) — copy-paste examples for common use cases
- [CLI Reference](cli.md) — all commands with full options
- [OAuth Guide](oauth-guide.md) — set up Google, GitHub, Discord, or LinkedIn login
- [API Endpoints](api-endpoints.md) — full endpoint reference
- [Adding to Existing Projects](existing-hono-project.md) — integrate teenybase into an existing Hono app
