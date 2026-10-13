# Supabase SQL patterns for Spellbinder

Copied from `supabase/migrations/0001_init.sql`. Adapt; don't redefine the helpers (they already exist).
Wrap `auth.uid()` as `(select auth.uid())` inside policies so Postgres evaluates it once per query, not once per row.

## Existing helpers (0001, helpers moved to `private` in 0002)

```sql
private.is_playgroup_member(group_id uuid) returns boolean  -- caller is a member of that group
private.shares_playgroup(other_user uuid) returns boolean   -- caller shares at least one group with other_user
public.create_playgroup(group_name text) returns playgroups -- RPC: creates the group, caller becomes owner
public.join_playgroup(code text) returns playgroups         -- RPC: joins by invite code (case-insensitive)
public.touch_updated_at()                                   -- trigger fn: sets new.updated_at = now()
```
All are `security definer set search_path = ''` (except the trigger function) and only `authenticated` may execute them.
RLS-only helpers live in the `private` schema (not exposed by the API); only real RPCs go in `public`.

## A user-owned table (pattern of collection_items, decks)

```sql
create table if not exists public.wishlist_items (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  oracle_id   uuid not null,
  created_at  timestamptz not null default now()
);
create index if not exists wishlist_items_user_idx on public.wishlist_items (user_id);

alter table public.wishlist_items enable row level security;
grant select, insert, update, delete on public.wishlist_items to authenticated;

create policy "wishlist: read own and peers" on public.wishlist_items
  for select to authenticated using (user_id = (select auth.uid()) or private.shares_playgroup(user_id));
create policy "wishlist: insert own" on public.wishlist_items
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "wishlist: update own" on public.wishlist_items
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "wishlist: delete own" on public.wishlist_items
  for delete to authenticated using (user_id = (select auth.uid()));
```
Note `shares_playgroup(x)` is false for yourself, hence the `user_id = auth.uid() or …`.

## A child table that inherits its parent's owner (deck_cards)

Separate insert/update/delete policies — a `for all` policy would add a second permissive select policy.

```sql
create policy "deck_cards: read own and peers" on public.deck_cards
  for select to authenticated using (
    exists (select 1 from public.decks d
            where d.id = deck_id and (d.owner_id = (select auth.uid()) or private.shares_playgroup(d.owner_id))));
create policy "deck_cards: insert own" on public.deck_cards
  for insert to authenticated
  with check (exists (select 1 from public.decks d where d.id = deck_id and d.owner_id = (select auth.uid())));
-- …update own / delete own likewise
```

## Playgroup-scoped table (game_nights, games)

```sql
create policy "games: members read" on public.games
  for select to authenticated using (private.is_playgroup_member(playgroup_id));
create policy "games: members log" on public.games
  for insert to authenticated
  with check (private.is_playgroup_member(playgroup_id) and created_by = (select auth.uid()));
```

## Business rules that RLS can't express → a `before update` trigger

See `public.enforce_loan_update()`: RLS decides *who* may update a row, the trigger decides *which changes* are allowed
(e.g. only the owner moves a loan from `pending` to `lent`). Let `auth.uid() is null` (service role) through.

## Testing a policy (pgTAP, `supabase/tests/*.test.sql`)

```sql
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "<user uuid>", "role": "authenticated"}', true);
select is((select count(*)::int from public.wishlist_items), 0, 'a stranger sees nothing');
select throws_ok($$ insert into … $$, '42501', null, 'RLS blocks the insert');
reset role;
```
