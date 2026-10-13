# Spellbinder DB — project memory for Claude Code

The Supabase backend for Spellbinder, a free Magic: The Gathering Commander companion app for a small group of
friends. It is shared by two clients in separate repos: the mobile app (`../spellbinder-app`, Expo) and the future
website (`../spellbinder-web`). Product vision: `../spellbinder-app/docs/VISION.md`.

Remote project ref: `fobbpfvhnelpforjqugd`.

## What lives here
- `supabase/migrations/` — the schema, RLS policies, RPCs and triggers. **The single source of truth for the database.**
- `supabase/functions/` — Edge Functions (Deno). `oracle` is a stub for the AI deck advisor.
- `supabase/tests/` — pgTAP tests for every access rule.
- `supabase/seed.sql` — local-only dev data (five users, password `spellbinder-dev`). Never pushed.
- `supabase/config.toml` — local stack settings, and the auth settings pushed with `supabase config push`.

## Commands
- Local stack (Podman, see README): `npm run db:start` / `db:stop` / `db:status`
- Re-apply migrations + seed locally: `npm run db:reset`
- Tests: `npm run test:db` · Lint: `npm run db:lint`
- Types for a client: `npm run types --silent > <client>/src/types/database.ts` (or `types:local`)

Before saying a change is done, run `db:reset`, `test:db` and `db:lint` locally.

## Hard rules
- **Never run anything against the remote project without asking first:** `db push`, `config push`, `functions deploy`,
  `secrets set`, `db reset --linked`, or SQL through the MCP. Show the dry run / diff and wait for a yes.
- Never edit a migration that has been applied remotely (`npx supabase migration list`). Add a new one.
- **Two clients:** migrations are additive first. Renames and drops are two steps (add new → both clients switch →
  drop old in a later migration). Write the plan in the migration's header comment.
- Every table has RLS enabled with explicit policies, plus a pgTAP test for each rule.
- No secrets in the repo. The Anthropic key lives in Supabase secrets; service-role keys never leave the dashboard.
- Auth is email + password with confirmations off; the project sends no email (no SMTP).
- The `cards` table only stores Scryfall data and image **URLs**, never images.

## Skills (`.claude/skills/`)
- `supabase-migration` — any schema change: migration + RLS + tests, then regenerate types in the clients.
- `oracle-edge` — the Oracle Edge Function and Claude API integration.

## MCP
`.mcp.json` adds the Supabase MCP in **read-only** mode: use it to inspect tables, read logs, run `get_advisors` and
search the docs. Schema changes go through migration files and the CLI, never `apply_migration`.
