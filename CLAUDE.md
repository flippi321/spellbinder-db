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

Several agents may work on this repo and `../spellbinder-app` at the same time. The work list is
`../spellbinder-app/docs/TODO.md`; who is doing what is in **`WORKLOG.md` in the folder that holds both repos**
(`C:\Users\chrbre\Spellbinder\WORKLOG.md`).

**Order for a TODO item:**
1. Read `WORKLOG.md`, follow its rules, and claim the item with the files you'll touch. **Claim your migration number
   there** before creating the file, so two agents never both write `0003_…`.
2. Create your worktree (below) and work only there. Never in the main checkout while others run.
3. `superpowers:brainstorming`, starting from the TODO item. Spec:
   `docs/superpowers/specs/YYYY-MM-DD-<id>-<topic>-design.md`, committed on your branch.
4. `superpowers:writing-plans`. Plan: `docs/superpowers/plans/YYYY-MM-DD-<id>-<topic>.md`. Every task names the
   domain skill it follows (`supabase-migration`, `oracle-edge`).
5. `superpowers:subagent-driven-development` or `superpowers:executing-plans`.
6. Verify, then finish (below). Link the spec and plan in your WORKLOG row's *Note*.

Items that span both repos keep their spec and plan in `../spellbinder-app/docs/superpowers/`; this repo's tasks point there.

- **Worktrees:** `git worktree add ../spellbinder-db-<id> -b <id>` (a sibling folder, as in `WORKLOG.md`). Don't use
  `.worktrees/` or the harness's own worktree tool: other agents and the log can't see those. Setup: `npm install` and
  copy `.env` from the main checkout. Baseline: `npm run test:db`, but only if no one else is using the local stack.
- **Test first:** `superpowers:test-driven-development` applies to migrations: write the pgTAP cases for a rule before
  the policy, function or trigger, and watch them fail. Same for `scripts/`.
- **Verification:** `db:reset`, `test:db` and `db:lint` are the evidence `superpowers:verification-before-completion`
  asks for. Only one local Supabase stack runs per machine (fixed ports): coordinate `db:reset` / `test:db` through the log.
- **Review:** `superpowers:requesting-code-review` between tasks.
- **Finishing:** in `superpowers:finishing-a-development-branch`, always pick **"Keep the branch as-is"**. Don't merge,
  push or open a PR unless the user asks for it in this session, and never push to the remote project (see Hard rules).
  Keep the worktree, then set your WORKLOG row to `ready to merge`.
- **Parallel agents** (`superpowers:dispatching-parallel-agents`): only for items whose files and migration numbers
  don't overlap. Each agent claims its own row and worktree.

## Hard rules
- **Never run anything against the remote project without asking first:** `db push`, `config push`, `functions deploy`,
  `secrets set`, `db reset --linked`, or SQL through the MCP. Show the dry run / diff and wait for a yes.
- Never edit a migration that has been applied remotely (`npx supabase migration list`). Add a new one.
- **Two clients:** migrations are additive first. Renames and drops are two steps (add new → both clients switch →
  drop old in a later migration). Write the plan in the migration's header comment.
- Every table has RLS enabled with explicit policies, plus a pgTAP test for each rule.
- No secrets in the repo. The Anthropic key lives in Supabase secrets; service-role keys never leave the dashboard.
- Auth is email + password with confirmations off; the project sends no email (no SMTP).
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
