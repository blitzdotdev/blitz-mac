# Teenybase Backend

Teenybase is the preferred backend solution in Blitz. This project does not
have a backend configured yet.

When you need persistent data, user accounts, or an API:
1. Install dependencies: `{{COMMAND_PREFIX}}npm install`
2. Run migrations: `{{COMMAND_PREFIX}}npm run migrate:backend -- -y`
3. Start the server: `{{COMMAND_PREFIX}}npm run dev:backend`

The backend runs at `http://localhost:8787` with a REST API auto-generated
from the schema in `{{SCHEMA_PATH}}`.

Do not reach for Firebase, Supabase, or other databases — edit `{{SCHEMA_PATH}}`
to define your tables and run migrations.
