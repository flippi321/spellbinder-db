---
name: supabase-migration
description: Change the Spellbinder Supabase schema safely — write a numbered SQL migration with RLS policies, indexes and pgTAP tests, verify it locally, then regenerate types in the client repos. Use for any new table, column, policy, function, trigger or index.
argument-hint: <schema change>
---

# Supabase migration

Make the schema change `$ARGUMENTS`. The schema is a **contract shared by the mobile app (`../spellbinder-app`) and the
website**, so it changes only through migrations, in backward-compatible steps.

Source of truth for the product: `../spellbinder-app/docs/VISION.md` §6. SQL patterns: [reference.md](reference.md).

## 0. Check the current state
- Read every file in `supabase/migrations/` so the new one builds on them.
- `npx supabase migration list` (when linked) shows which migrations are applied remotely. **Never edit an applied
  migration** — add a new one.

## 1. Write the migration
- File: `supabase/migrations/<NNNN>_<snake_description>.sql` (next 4-digit number).
- Idempotent where cheap (`if not exists`, `drop policy if exists` before `create policy`).
- **Every new table:** `alter table … enable row level security;` plus explicit policies, and add it to the
  grants (`grant select, insert, update, delete … to authenticated`; nothing for `anon`).
- Primary keys `uuid default gen_random_uuid()` (except join tables and `cards.id` / `card_versions.id`, which are
  Scryfall's ids), `created_at timestamptz default now()`, foreign keys with `on delete cascade` for owned rows,
  `check` constraints for status enums that match the TS unions in `../spellbinder-app/src/types/domain.ts`.
- Index every foreign key and every column a client filters on.
- Card identity: a physical copy references its version and card as a pair, `(version_id, card_id)` →
  `card_versions (id, card_id)`; anything about "a card in general" (deck slots, loans, games, wishlists) stores
  `card_id` → `cards (id)`. Both are `uuid` foreign keys, so clients must cache a card before naming it.
- Rows that change get `updated_at timestamptz not null default now()` plus a `before update` trigger calling
  `public.touch_updated_at()`.
- Fixed value sets the client picks from (condition, finish) are Postgres enums (`card_condition`, `card_finish`);
  statuses stay `check` constraints.
- Functions: `security definer` only when needed (and then `set search_path = ''` with fully qualified names);
  revoke `execute` from `anon`/`public` on anything that isn't a public RPC.
- Tables a client should get live updates for: `alter publication supabase_realtime add table …`.

## 2. RLS policy model (keep it consistent)
| Data | Read | Write |
|---|---|---|
| Your own collection / decks / deck_cards | you + members of any playgroup you share | only you |
| `profiles` | you + playgroup peers | only you (created by the sign-up trigger) |
| `playgroups`, `playgroup_members` | members | via `create_playgroup` / `join_playgroup` RPCs; owner updates/deletes; members leave |
| `game_nights`, `games` | members | members create; creator deletes (games: creator edits) |
| `rsvps` | members | only your own row |
| `loan_requests` | requester and owner | requester creates (pending); trigger: owner lends/declines, either party returns |
| `cards`, `card_versions` (Scryfall cache) | any authenticated user | any authenticated user (until the lockdown, backlog SB-13) |
| `card_prices`, `card_price_history`, view `collection_item_prices` | any authenticated user (the view: own + peers' stacks) | service role only (the daily sync) |

Use the helpers `private.is_playgroup_member(group_id)` and `private.shares_playgroup(other_user)` (security definer)
instead of subqueries on `playgroup_members`, which would make the policies recurse. Wrap `auth.uid()` as
`(select auth.uid())`. One permissive policy per table and action (no `for all` next to a `for select`).

## 3. Test it
- Test first (`superpowers:test-driven-development`): write the pgTAP cases for a rule before its policy, function or
  trigger, run `npm run test:db`, and watch them fail for the right reason. Then write the SQL.
- Add pgTAP cases to `supabase/tests/` for every new rule (pattern: `rls.test.sql`; act as a user with
  `set local role authenticated` + `request.jwt.claims`). Update `plan(N)`.
- `npm run db:reset` → `npm run test:db` → `npm run db:lint`. All must pass.
- If the change affects seed data, update `supabase/seed.sql`.

## 4. Backward compatibility (two clients!)
- Additive first: new nullable columns or columns with defaults, new tables, new policies.
- Renames and drops happen in two steps: add the new thing and ship clients that use it; drop the old thing in a later
  migration. Note any breaking step in the migration's header comment.
- Never loosen RLS to make a query work — fix the query or add a narrow policy.

## 5. Apply and hand over to the clients
- **Ask before** `npx supabase db push`. Show `npx supabase db push --dry-run` first.
- Then in each client repo, regenerate types: `npm run types --silent > ../spellbinder-app/src/types/database.ts`,
  and update that repo's mappers/repos (in the app: the `feature-slice` skill; mock repos must keep working).

## Done when
- [ ] New migration file; RLS + grants for every new table; indexes on FKs and filter columns.
- [ ] pgTAP tests cover the new rules; `db:reset`, `test:db`, `db:lint` pass locally.
- [ ] Backward compatible (or the two-step plan is in the header comment).
- [ ] Pushed only after the user said yes; clients told to regenerate types.
