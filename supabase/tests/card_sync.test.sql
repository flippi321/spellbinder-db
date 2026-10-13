-- The card sync: card_sync_runs is read-only for users, and sync_card_batch (service role only) upserts cards,
-- versions and prices, rewriting cards and versions only when something changed. Run: `npm run test:db`.
-- Everything runs in one transaction and is rolled back.
--
-- One card K with two versions K1 and K2, sent as JSON the way scripts/sync-cards.ts sends it.

begin;
create extension if not exists pgtap with schema extensions;
set local role postgres;
set local search_path = public, extensions;
select plan(22);

-- ── Setup (as postgres, bypassing RLS) ─────────────────────────────────────────────────────
insert into auth.users (id, email) values ('cccccccc-0000-4000-a000-000000000000', 'c@test.local');
insert into public.card_sync_runs (bulk_type, bulk_updated_at, status, finished_at)
values ('test_cards', '2026-10-13 09:06:00+00', 'ok', now());

create temp table batch (card_rows jsonb, version_rows jsonb, price_rows jsonb) on commit drop;
grant select on batch to authenticated, service_role;
insert into batch values (
  '[{"id": "33333333-0000-4000-a000-000000000000", "name": "Card K", "layout": "normal", "mana_cost": "{1}{G}",
     "cmc": 2, "type_line": "Creature — Elf", "rules_text": "Draw a card.", "power": "1", "toughness": "1",
     "colors": ["G"], "color_identity": ["G"], "legalities": {"commander": "legal"}}]',
  '[{"id": "44444444-0000-4000-a000-000000000001", "card_id": "33333333-0000-4000-a000-000000000000", "set": "tst",
     "collector_number": "1", "rarity": "rare", "artist": "A. Artist", "image_uris": {"normal": "https://x/1.jpg"},
     "finishes": ["nonfoil", "foil"]},
    {"id": "44444444-0000-4000-a000-000000000002", "card_id": "33333333-0000-4000-a000-000000000000", "set": "tst",
     "collector_number": "2", "rarity": "rare", "finishes": ["etched"]}]',
  '[{"version_id": "44444444-0000-4000-a000-000000000001", "source": "scryfall", "usd": "1.50", "eur": "1.20",
     "usd_foil": "4.00"},
    {"version_id": "44444444-0000-4000-a000-000000000002", "source": "scryfall"}]'
);

-- ── Users read the run log but write nothing ───────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is((select count(*)::int from public.card_sync_runs where bulk_type = 'test_cards'), 1, 'a user reads the sync runs (whatever real runs the database already has)');
select throws_ok(
  $$ insert into public.card_sync_runs (bulk_type, bulk_updated_at) values ('default_cards', now()) $$,
  '42501', null, 'a user cannot log a run');
select throws_ok($$ update public.card_sync_runs set status = 'failed' $$, '42501', null, 'a user cannot change a run');
select throws_ok(
  $$ select public.sync_card_batch(card_rows, version_rows, price_rows) from batch $$,
  '42501', null, 'a user cannot call sync_card_batch');

set local role anon;
select throws_ok($$ select count(*) from public.card_sync_runs $$, '42501', null, 'anon cannot read the sync runs');

-- ── The service role loads a batch ─────────────────────────────────────────────────────────
set local role service_role;
select is(
  (select public.sync_card_batch(card_rows, version_rows, price_rows) from batch), 5,
  'the first load writes 1 card, 2 versions and 2 prices');

set local role postgres;
select is((select layout || '/' || type_line from public.cards where id = '33333333-0000-4000-a000-000000000000'),
  'normal/Creature — Elf', 'the card is stored');
select is((select legalities ->> 'commander' from public.cards where id = '33333333-0000-4000-a000-000000000000'),
  'legal', 'legalities are stored as JSON');
select is(
  (select finishes from public.card_versions where id = '44444444-0000-4000-a000-000000000001'),
  '{nonfoil,foil}'::public.card_finish[], 'a JSON array of finishes becomes the enum array');
select is(
  (select rarity || '/' || coalesce(artist, '-') from public.card_versions where id = '44444444-0000-4000-a000-000000000002'),
  'rare/-', 'missing keys become null');
select is(
  (select (usd, usd_foil, eur, tix)::text from public.card_prices where version_id = '44444444-0000-4000-a000-000000000001'),
  '(1.50,4.00,1.20,)', 'prices sent as strings become numbers');
select is(
  (select count(*)::int from public.card_prices
   where version_id = '44444444-0000-4000-a000-000000000002' and coalesce(usd, eur, tix) is null),
  1, 'a version without prices still gets a price row');

-- ── Unchanged rows are left alone; prices are always refreshed ─────────────────────────────
update public.cards set updated_at = '2026-01-01' where id = '33333333-0000-4000-a000-000000000000';
update public.card_versions set updated_at = '2026-01-01' where card_id = '33333333-0000-4000-a000-000000000000';
update public.card_prices set updated_at = '2026-01-01' where version_id::text like '44444444-%';

set local role service_role;
select is(
  (select public.sync_card_batch(card_rows, version_rows, price_rows) from batch), 2,
  'loading the same batch again only refreshes the 2 prices');

set local role postgres;
select is((select updated_at from public.cards where id = '33333333-0000-4000-a000-000000000000'),
  '2026-01-01'::timestamptz, 'an unchanged card keeps its updated_at');
select is(
  (select count(*)::int from public.card_versions
   where card_id = '33333333-0000-4000-a000-000000000000' and updated_at = '2026-01-01'),
  2, 'unchanged versions keep their updated_at');
select is(
  (select count(*)::int from public.card_prices where version_id::text like '44444444-%' and updated_at = now()),
  2, 'prices get a new updated_at, so the snapshot dates them today');

-- ── A changed card or version is rewritten ─────────────────────────────────────────────────
update batch set
  card_rows = jsonb_set(card_rows, '{0,rules_text}', '"Draw two cards."'),
  version_rows = jsonb_set(version_rows, '{1,artist}', '"B. Artist"');

set local role service_role;
select is(
  (select public.sync_card_batch(card_rows, version_rows, price_rows) from batch), 4,
  'a rules change and an artist change rewrite 1 card and 1 version, plus the 2 prices');

set local role postgres;
select is((select rules_text from public.cards where id = '33333333-0000-4000-a000-000000000000'),
  'Draw two cards.', 'the rules change is stored');
select is((select updated_at from public.cards where id = '33333333-0000-4000-a000-000000000000'),
  now(), 'the changed card gets a new updated_at');
select is(
  (select count(*)::int from public.card_versions
   where card_id = '33333333-0000-4000-a000-000000000000' and updated_at = '2026-01-01'),
  1, 'only the changed version gets a new updated_at');

-- ── A version never moves to another card ──────────────────────────────────────────────────
insert into public.cards (id, name, type_line) values ('33333333-0000-4000-a000-000000000009', 'Card L', 'Instant');
update batch set version_rows = jsonb_set(version_rows, '{0,card_id}', '"33333333-0000-4000-a000-000000000009"');
set local role service_role;
select lives_ok($$ select public.sync_card_batch(card_rows, version_rows, price_rows) from batch $$, 'a batch naming another card for a version still loads');
set local role postgres;
select is((select card_id from public.card_versions where id = '44444444-0000-4000-a000-000000000001'),
  '33333333-0000-4000-a000-000000000000'::uuid, 'card_id is never updated');

set local role postgres;
select * from finish();
rollback;
