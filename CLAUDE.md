# Spellbinder DB — project memory for Claude Code

The Supabase backend for Spellbinder, a free Magic: The Gathering Commander companion app for a small group of
friends. It is shared by two clients in separate repos: the mobile app (`../spellbinder-app`, Expo) and the future
website (`../spellbinder-web`). Product vision: `../spellbinder-app/docs/VISION.md`.

Remote project ref: `fobbpfvhnelpforjqugd`. This repo is linked to it, and it is the **live** backend the apps use:
migrations pushed from here change the real database. The local stack is only for development and tests.

## What lives here
- `supabase/migrations/` — the schema, RLS policies, RPCs and triggers. **The single source of truth for the database.**
- `supabase/functions/` — Edge Functions (Deno). `oracle` is a stub for the AI deck advisor.
- `supabase/tests/` — pgTAP tests for every access rule.
- `supabase/seed.sql` — local-only dev data (five users, password `spellbinder-dev`). Never pushed.
- `scripts/sync-cards.ts` + `.github/workflows/sync-cards.yml` — the daily Scryfall card + price sync (README → Card sync).
- `supabase/config.toml` — local stack settings, and the auth settings pushed with `supabase config push`.

## Commands
- Local stack (Podman, see README): `npm run db:start` / `db:stop` / `db:status`
- Re-apply migrations + seed locally: `npm run db:reset`
- Tests: `npm run test:db` · Lint: `npm run db:lint`
- Card sync against the local stack: `npm run sync:cards` (needs `.env`, see README → Card sync)
- Types for a client: `npm run types --silent > <client>/src/types/database.ts` (or `types:local`)

Before saying a change is done, run `db:reset`, `test:db` and `db:lint` locally.

## Workflow (Superpowers) and working alongside other agents

The **Superpowers** plugin is enabled for this repo (`.claude/settings.json`). Its skills (`superpowers:*`) say *how* to
work: brainstorm, plan, test first, review, verify, finish. This repo's skills say *what* the backend needs.
**Where Superpowers and this file disagree, this file wins**, and the Hard rules below always apply.

Several agents may work on this repo and `../spellbinder-app` at the same time. The process (claiming an item,
worktrees, hot spots, specs and plans, finishing) is in **`../WORKFLOW.md`**, and the work list is **`../BACKLOG.md`**
with one file per item in `../backlog/`. Both live in the workspace folder that holds the two repos
(`C:\Users\chrbre\Spellbinder`), which is where sessions start. Specs and plans live there too
(`../docs/superpowers/`), not in this repo.

This repo's rules for that process:

- **Migration numbers** are claimed in the item before the SQL file exists, so two agents never both write `0009_…`
  (`../WORKFLOW.md` → *Migration numbers*).
- **Test first:** `superpowers:test-driven-development` applies to migrations: write the pgTAP cases for a rule before
  the policy, function or trigger, and watch them fail. Same for `scripts/`.
- **Verification:** `db:reset`, `test:db` and `db:lint` are the evidence `superpowers:verification-before-completion`
  asks for. Only one local Supabase stack runs per machine (fixed ports): coordinate `db:reset` / `test:db` as
  `../WORKFLOW.md` → *Local Supabase stack* says.
- **Review:** `superpowers:requesting-code-review` between tasks.
- **Finishing:** in `superpowers:finishing-a-development-branch`, always pick **"Keep the branch as-is"**. Don't merge,
  push or open a PR unless the user asks for it in this session, and never push to the remote project (see Hard rules).
  Keep the worktree. This holds even when you work here without the workspace.

## Hard rules
- **Never run anything against the remote project without asking first:** `db push`, `config push`, `functions deploy`,
  `secrets set`, `db reset --linked`, or SQL through the MCP. Show the dry run / diff and wait for a yes.
- Never edit a migration that has been applied remotely (`npx supabase migration list`). Add a new one.
- **Two clients:** migrations are additive first. Renames and drops are two steps (add new → both clients switch →
  drop old in a later migration). Write the plan in the migration's header comment.
- Every table has RLS enabled with explicit policies, plus a pgTAP test for each rule.
- No secrets in the repo. The Anthropic key lives in Supabase secrets; service-role keys never leave the dashboard.
- Auth is email + password with confirmations off. The only email is the password-reset code, sent through Gmail SMTP
  set in the dashboard (README → Auth; decision D-6 in `../backlog/decisions/`).
- The card cache (`cards`, `card_versions`, `card_prices`) only stores Scryfall data and image **URLs**, never images.
- Card identity: a **card** (`cards.id` = Scryfall oracle_id) has **versions** (`card_versions.id` = Scryfall id).
  Every other table says `card_id` / `version_id`, with a foreign key; "oracle" only means the AI feature.
- Tables rows change in have `updated_at`, stamped by a `before update` trigger (`public.touch_updated_at()`).

## Skills (`.claude/skills/`)
Domain skills: use the matching one inside each plan task. Process skills come from Superpowers (above).
- `supabase-migration` — any schema change: migration + RLS + tests, then regenerate types in the clients.
- `oracle-edge` — the Oracle Edge Function and Claude API integration.

## MCP
`.mcp.json` adds the Supabase MCP in **read-only** mode: use it to inspect tables, read logs, run `get_advisors` and
search the docs. Schema changes go through migration files and the CLI, never `apply_migration`.
