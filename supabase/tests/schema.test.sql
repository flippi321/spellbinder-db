-- Schema rules: card foreign keys, condition and finish enums, updated_at triggers, and the game → game night link.
-- Run: `npm run test:db`. Everything runs in one transaction and is rolled back.
--
-- A and B share playgroup G1; C is alone in G2. Card X has version VX, card Y has version VY.

begin;
create extension if not exists pgtap with schema extensions;
set local role postgres;
set local search_path = public, extensions;
select plan(23);

-- ── Setup (as postgres, bypassing RLS) ─────────────────────────────────────────────────────
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-4000-a000-000000000000', 'a@test.local'),
  ('bbbbbbbb-0000-4000-a000-000000000000', 'b@test.local'),
  ('cccccccc-0000-4000-a000-000000000000', 'c@test.local');

insert into public.cards (id, name, type_line) values
  ('22222222-0000-4000-a000-000000000000', 'Card X', 'Artifact'),
  ('55555555-0000-4000-a000-000000000000', 'Card Y', 'Instant');
insert into public.card_versions (id, card_id, set, collector_number) values
  ('11111111-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000', 'tst', '1'),
  ('66666666-0000-4000-a000-000000000000', '55555555-0000-4000-a000-000000000000', 'tst', '2');

insert into public.playgroups (id, name, created_by) values
  ('99999999-0000-4000-a000-000000000001', 'G1', 'aaaaaaaa-0000-4000-a000-000000000000'),
  ('99999999-0000-4000-a000-000000000002', 'G2', 'cccccccc-0000-4000-a000-000000000000');
insert into public.playgroup_members (playgroup_id, user_id, role) values
  ('99999999-0000-4000-a000-000000000001', 'aaaaaaaa-0000-4000-a000-000000000000', 'owner'),
  ('99999999-0000-4000-a000-000000000001', 'bbbbbbbb-0000-4000-a000-000000000000', 'member'),
  ('99999999-0000-4000-a000-000000000002', 'cccccccc-0000-4000-a000-000000000000', 'owner');

insert into public.decks (id, owner_id, name, commander_card_id, updated_at)
values ('dddddddd-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000', 'B''s deck',
        '22222222-0000-4000-a000-000000000000', '2000-01-01');
insert into public.game_nights (id, playgroup_id, starts_at, created_by) values
  ('eeeeeeee-0000-4000-a000-000000000001', '99999999-0000-4000-a000-000000000001', now(), 'aaaaaaaa-0000-4000-a000-000000000000'),
  ('eeeeeeee-0000-4000-a000-000000000002', '99999999-0000-4000-a000-000000000002', now(), 'cccccccc-0000-4000-a000-000000000000');

-- ── Every card reference must exist ────────────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.deck_cards (deck_id, card_id) values ('dddddddd-0000-4000-a000-000000000000', '00000000-dead-4000-a000-000000000000') $$,
  '23503', null, 'a deck card must be a known card');
select throws_ok(
  $$ insert into public.decks (owner_id, name, commander_card_id)
     values ('bbbbbbbb-0000-4000-a000-000000000000', 'Ghost', '00000000-dead-4000-a000-000000000000') $$,
  '23503', null, 'a commander must be a known card');
select throws_ok(
  $$ insert into public.loan_requests (card_id, requester_id, owner_id)
     values ('00000000-dead-4000-a000-000000000000', 'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000') $$,
  '23503', null, 'a loan must be for a known card');
select throws_ok(
  $$ insert into public.collection_items (user_id, version_id, card_id, quantity)
     values ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000000', '55555555-0000-4000-a000-000000000000', 1) $$,
  '23503', null, 'a collection item''s card must match its version');

-- ── Condition and finish ───────────────────────────────────────────────────────────────────
insert into public.collection_items (id, user_id, version_id, card_id, quantity)
values ('ffffffff-0000-4000-a000-000000000001', 'bbbbbbbb-0000-4000-a000-000000000000',
        '11111111-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000', 1);
select is((select condition::text from public.collection_items where id = 'ffffffff-0000-4000-a000-000000000001'), 'NM',
  'condition defaults to Near Mint');
select is((select finish::text from public.collection_items where id = 'ffffffff-0000-4000-a000-000000000001'), 'nonfoil',
  'finish defaults to nonfoil');
select throws_ok(
  $$ insert into public.collection_items (user_id, version_id, card_id, quantity, condition)
     values ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000', 1, 'MP') $$,
  '22P02', null, 'old US grades are not conditions');
select lives_ok(
  $$ insert into public.collection_items (user_id, version_id, card_id, quantity, condition, finish)
     values ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000', 1, 'EX', 'etched') $$,
  'an Excellent etched copy is its own stack');

-- ── updated_at: an update always stamps now(), whatever the client sends ───────────────────
insert into public.loan_requests (id, card_id, requester_id, owner_id)
values ('abababab-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000',
        'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000');
insert into public.games (id, playgroup_id, winner_id, created_by)
values ('cdcdcdcd-0000-4000-a000-000000000000', '99999999-0000-4000-a000-000000000001',
        'aaaaaaaa-0000-4000-a000-000000000000', 'aaaaaaaa-0000-4000-a000-000000000000');

update public.profiles set updated_at = '2000-01-01' where id = 'aaaaaaaa-0000-4000-a000-000000000000';
select is((select updated_at from public.profiles where id = 'aaaaaaaa-0000-4000-a000-000000000000'), now(), 'profiles stamp updated_at');
update public.playgroups set updated_at = '2000-01-01' where id = '99999999-0000-4000-a000-000000000001';
select is((select updated_at from public.playgroups where id = '99999999-0000-4000-a000-000000000001'), now(), 'playgroups stamp updated_at');
update public.collection_items set updated_at = '2000-01-01' where id = 'ffffffff-0000-4000-a000-000000000001';
select is((select updated_at from public.collection_items where id = 'ffffffff-0000-4000-a000-000000000001'), now(), 'collection items stamp updated_at');
update public.loan_requests set updated_at = '2000-01-01' where id = 'abababab-0000-4000-a000-000000000000';
select is((select updated_at from public.loan_requests where id = 'abababab-0000-4000-a000-000000000000'), now(), 'loan requests stamp updated_at');
update public.game_nights set updated_at = '2000-01-01' where id = 'eeeeeeee-0000-4000-a000-000000000001';
select is((select updated_at from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000001'), now(), 'game nights stamp updated_at');
update public.games set updated_at = '2000-01-01' where id = 'cdcdcdcd-0000-4000-a000-000000000000';
select is((select updated_at from public.games where id = 'cdcdcdcd-0000-4000-a000-000000000000'), now(), 'games stamp updated_at');

-- The deck was inserted with updated_at 2000-01-01; its owner adding a card bumps it.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select lives_ok(
  $$ insert into public.deck_cards (deck_id, card_id) values ('dddddddd-0000-4000-a000-000000000000', '55555555-0000-4000-a000-000000000000') $$,
  'the owner adds a card to their deck');
select is((select updated_at from public.decks where id = 'dddddddd-0000-4000-a000-000000000000'), now(),
  'adding a card bumps the deck''s updated_at');
update public.decks set updated_at = '2000-01-01' where id = 'dddddddd-0000-4000-a000-000000000000';
select is((select updated_at from public.decks where id = 'dddddddd-0000-4000-a000-000000000000'), now(), 'decks stamp updated_at');
select lives_ok($$ delete from public.decks where id = 'dddddddd-0000-4000-a000-000000000000' $$,
  'deleting a deck with cards still works');
select is((select count(*)::int from public.deck_cards where deck_id = 'dddddddd-0000-4000-a000-000000000000'), 0,
  'its cards go with it');

-- ── Games and game nights ──────────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select throws_ok(
  $$ insert into public.games (playgroup_id, winner_id, game_night_id)
     values ('99999999-0000-4000-a000-000000000001', 'aaaaaaaa-0000-4000-a000-000000000000', 'eeeeeeee-0000-4000-a000-000000000002') $$,
  '23503', null, 'a game cannot belong to another playgroup''s game night');
select lives_ok(
  $$ insert into public.games (id, playgroup_id, winner_id, game_night_id)
     values ('cdcdcdcd-0000-4000-a000-000000000001', '99999999-0000-4000-a000-000000000001',
             'aaaaaaaa-0000-4000-a000-000000000000', 'eeeeeeee-0000-4000-a000-000000000001') $$,
  'a member logs a game at their group''s game night');
select lives_ok(
  $$ insert into public.games (playgroup_id, winner_id) values ('99999999-0000-4000-a000-000000000001', 'bbbbbbbb-0000-4000-a000-000000000000') $$,
  'a game needs no game night');

delete from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000001';
select is((select game_night_id from public.games where id = 'cdcdcdcd-0000-4000-a000-000000000001'), null,
  'deleting the night keeps the game and clears its game night');

set local role postgres;
select * from finish();
rollback;
