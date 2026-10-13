-- Card prices: read-only for users, written by the service role, history only for owned versions, compaction, and the
-- collection_item_prices view. Run: `npm run test:db`. Everything runs in one transaction and is rolled back.
--
-- B owns version V1 (a foil and a nonfoil stack) and V3 (no prices yet). Nobody owns V2. C is a stranger.

begin;
create extension if not exists pgtap with schema extensions;
set local role postgres;
set local search_path = public, extensions;
select plan(18);

-- ── Setup (as postgres, bypassing RLS) ─────────────────────────────────────────────────────
insert into auth.users (id, email) values
  ('bbbbbbbb-0000-4000-a000-000000000000', 'b@test.local'),
  ('cccccccc-0000-4000-a000-000000000000', 'c@test.local');

insert into public.cards (id, name, type_line) values ('22222222-0000-4000-a000-000000000000', 'Card X', 'Artifact');
insert into public.card_versions (id, card_id, set, collector_number) values
  ('11111111-0000-4000-a000-000000000001', '22222222-0000-4000-a000-000000000000', 'tst', '1'),
  ('11111111-0000-4000-a000-000000000002', '22222222-0000-4000-a000-000000000000', 'tst', '2'),
  ('11111111-0000-4000-a000-000000000003', '22222222-0000-4000-a000-000000000000', 'tst', '3');
insert into public.collection_items (user_id, version_id, card_id, quantity, finish) values
  ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000001', '22222222-0000-4000-a000-000000000000', 2, 'nonfoil'),
  ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000001', '22222222-0000-4000-a000-000000000000', 1, 'foil'),
  ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000003', '22222222-0000-4000-a000-000000000000', 1, 'nonfoil');

-- Fetched yesterday, so the history row is dated yesterday.
insert into public.card_prices (version_id, usd, usd_foil, eur, eur_foil, updated_at) values
  ('11111111-0000-4000-a000-000000000001', 1.50, 4.00, 1.20, 3.50, now() - interval '1 day'),
  ('11111111-0000-4000-a000-000000000002', 9.99, null, 8.50, null, now() - interval '1 day'),
  ('11111111-0000-4000-a000-000000000003', null, null, null, null, now() - interval '1 day');

-- ── Users read prices but never write them ─────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is((select count(*)::int from public.card_prices where version_id::text like '11111111-%'), 3, 'a user reads current prices');
select throws_ok(
  $$ insert into public.card_prices (version_id, usd) values ('11111111-0000-4000-a000-000000000002', 0.01) $$,
  '42501', null, 'a user cannot add a price');
select throws_ok($$ update public.card_prices set usd = 0.01 $$, '42501', null, 'a user cannot change a price');
select throws_ok(
  $$ insert into public.card_price_history (version_id, source, captured_on, usd)
     values ('11111111-0000-4000-a000-000000000001', 'scryfall', current_date, 0.01) $$,
  '42501', null, 'a user cannot write price history');
select throws_ok($$ select public.snapshot_card_prices() $$, '42501', null, 'a user cannot take a snapshot');
select throws_ok($$ select public.compact_card_price_history() $$, '42501', null, 'a user cannot compact the history');

-- ── The view: priced by finish, and only your own or your peers' stacks ────────────────────
select is((select count(*)::int from public.collection_item_prices), 0, 'a stranger sees no one''s stacks');

select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is(
  (select unit_eur from public.collection_item_prices where version_id = '11111111-0000-4000-a000-000000000001' and finish = 'nonfoil'),
  1.20, 'a nonfoil stack is priced at eur');
select is(
  (select unit_usd from public.collection_item_prices where version_id = '11111111-0000-4000-a000-000000000001' and finish = 'foil'),
  4.00, 'a foil stack is priced at usd_foil');
select is(
  (select unit_eur from public.collection_item_prices where version_id = '11111111-0000-4000-a000-000000000003'), null,
  'a version without prices has no value');

-- ── The service role snapshots owned versions ──────────────────────────────────────────────
set local role service_role;
select is(public.snapshot_card_prices(), 1, 'the snapshot writes one row: V1 (V2 is not owned, V3 has no prices)');
select is(
  (select captured_on from public.card_price_history where version_id = '11111111-0000-4000-a000-000000000001'),
  ((now() - interval '1 day') at time zone 'utc')::date, 'the row is dated the day the price was fetched');

update public.card_prices set eur = 1.25 where version_id = '11111111-0000-4000-a000-000000000001';
select is(public.snapshot_card_prices(), 1, 'running it again rewrites the same row');
select is((select count(*)::int from public.card_price_history), 1, 'still one history row');
select is((select eur from public.card_price_history), 1.25, 'with the latest price');

-- ── Compaction: daily for 90 days, then Mondays ────────────────────────────────────────────
insert into public.card_price_history (version_id, source, captured_on, eur)
select '11111111-0000-4000-a000-000000000001', 'scryfall', d, 1.00
from (values
  (date_trunc('week', current_date - 120)::date),      -- an old Monday
  (date_trunc('week', current_date - 120)::date + 1),  -- the Tuesday after it
  (current_date - 10)                                  -- recent
) as v (d);

select is(public.compact_card_price_history(), 1, 'compaction deletes the old Tuesday');
select is(
  (select count(*)::int from public.card_price_history where captured_on = date_trunc('week', current_date - 120)::date), 1,
  'the old Monday stays');
select is((select count(*)::int from public.card_price_history), 3, 'recent rows stay');

set local role postgres;
select * from finish();
rollback;
