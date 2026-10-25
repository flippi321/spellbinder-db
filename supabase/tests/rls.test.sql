-- RLS and business-rule tests for the schema's access rules. Run: `npm run test:db` (local) or `npx supabase test db --linked`.
-- Everything runs in one transaction and is rolled back, so it leaves no data behind.
--
-- Users: A and B end up in the same playgroup; C is a stranger.
-- Act as a user with `set local role authenticated` + request.jwt.claims; `set local role postgres` switches back.

begin;
create extension if not exists pgtap with schema extensions;
set local role postgres; -- the remote CLI logs in as a temporary role; act as postgres like a local run
set local search_path = public, extensions;
select plan(43);

-- ── Setup (as postgres, bypassing RLS) ─────────────────────────────────────────────────────
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-4000-a000-000000000000', 'a@test.local', '{"display_name": "Alice"}'),
  ('bbbbbbbb-0000-4000-a000-000000000000', 'b@test.local', '{"display_name": "Bob"}'),
  ('cccccccc-0000-4000-a000-000000000000', 'c@test.local', null);

select is(
  (select count(*)::int from public.profiles
   where id in ('aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000', 'cccccccc-0000-4000-a000-000000000000')),
  3, 'signing up creates a profile');
select is(
  (select display_name from public.profiles where id = 'cccccccc-0000-4000-a000-000000000000'),
  'c', 'display name falls back to the email name');

insert into public.cards (id, name, type_line) values ('22222222-0000-4000-a000-000000000000', 'Sol Ring', 'Artifact');
insert into public.card_versions (id, card_id, set, collector_number)
values ('11111111-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000', 'cmm', '1');
insert into public.collection_items (user_id, version_id, card_id, quantity)
values ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000', 2);
insert into public.decks (id, owner_id, name, commander_card_id)
values ('dddddddd-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000', 'Bob''s deck', '22222222-0000-4000-a000-000000000000');
insert into public.deck_cards (deck_id, card_id) values ('dddddddd-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000');

-- ── Before sharing a playgroup: A sees nothing of B's ──────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);

select is((select count(*)::int from public.profiles where id = 'bbbbbbbb-0000-4000-a000-000000000000'), 0, 'A cannot see B''s profile yet');
select is((select count(*)::int from public.collection_items), 0, 'A cannot see B''s collection yet');
select is((select count(*)::int from public.decks), 0, 'A cannot see B''s decks yet');
select throws_ok(
  $$ insert into public.loan_requests (card_id, requester_id, owner_id)
     values ('22222222-0000-4000-a000-000000000000', 'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000') $$,
  '42501', null, 'A cannot ask a stranger for a loan');
select isnt((select (public.create_playgroup('Test Table')).id), null, 'A creates a playgroup');
select is((select role from public.playgroup_members where user_id = 'aaaaaaaa-0000-4000-a000-000000000000'), 'owner', 'creator becomes owner');

-- ── B joins with the invite code ───────────────────────────────────────────────────────────
set local role postgres;
select set_config('test.code', (select invite_code from public.playgroups where name = 'Test Table'), true);
select set_config('test.group', (select id::text from public.playgroups where name = 'Test Table'), true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select throws_ok($$ select public.join_playgroup('NOPE1234') $$, 'P0001', 'Invalid invite code', 'a wrong code is rejected');
select lives_ok($$ select public.join_playgroup(lower(current_setting('test.code'))) $$, 'B joins with the code (case-insensitive)');
select is((select count(*)::int from public.playgroup_members), 2, 'B sees both members');

-- ── Precon flag (DK-10): the owner sets it ─────────────────────────────────────────────────
select is((select is_precon from public.decks where id = 'dddddddd-0000-4000-a000-000000000000'), false,
  'a deck created without the flag is not a precon');
select lives_ok(
  $$ update public.decks set is_precon = true where id = 'dddddddd-0000-4000-a000-000000000000' $$,
  'B marks their deck as a precon');
select is((select is_precon from public.decks where id = 'dddddddd-0000-4000-a000-000000000000'), true,
  'B''s deck is now a precon');

-- ── Peers read but never write each other's rows ───────────────────────────────────────────
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is((select count(*)::int from public.profiles), 2, 'A now sees B''s profile');
select is((select count(*)::int from public.collection_items), 1, 'A now sees B''s collection');
select is((select count(*)::int from public.deck_cards), 1, 'A now sees B''s deck cards');

select is((select is_precon from public.decks where id = 'dddddddd-0000-4000-a000-000000000000'), true,
  'A reads B''s precon flag');

-- A blocked update changes 0 rows, it doesn't throw, so each case reads the value back.
update public.collection_items set quantity = 99;
update public.decks set is_precon = false;
delete from public.decks;
select is((select quantity from public.collection_items), 2, 'A cannot change B''s collection');
select is((select is_precon from public.decks where id = 'dddddddd-0000-4000-a000-000000000000'), true,
  'A cannot change B''s precon flag');
select is((select count(*)::int from public.decks), 1, 'A cannot delete B''s deck');
select throws_ok(
  $$ insert into public.collection_items (user_id, version_id, card_id, quantity)
     values ('bbbbbbbb-0000-4000-a000-000000000000', '11111111-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000', 1) $$,
  '42501', null, 'A cannot add cards to B''s binder');

-- ── Loans ──────────────────────────────────────────────────────────────────────────────────
select throws_ok(
  $$ insert into public.loan_requests (card_id, requester_id, owner_id, status)
     values ('22222222-0000-4000-a000-000000000000', 'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000', 'lent') $$,
  '42501', null, 'a new request must be pending');
select lives_ok(
  $$ insert into public.loan_requests (card_id, requester_id, owner_id)
     values ('22222222-0000-4000-a000-000000000000', 'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000') $$,
  'A asks playgroup peer B for a loan');
select throws_ok($$ update public.loan_requests set status = 'lent' $$, 'P0001', null, 'the requester cannot approve their own request');

select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select lives_ok($$ update public.loan_requests set status = 'lent' $$, 'the owner lends the card');

select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select lives_ok($$ update public.loan_requests set status = 'returned' $$, 'the requester marks it returned');
select throws_ok($$ update public.loan_requests set status = 'pending' $$, 'P0001', null, 'a returned loan cannot reopen');

-- Cancelling is a delete, and only the requester's pending request goes. A blocked delete removes 0 rows, it doesn't
-- throw, so each case counts what's left.
select lives_ok(
  $$ insert into public.loan_requests (id, card_id, requester_id, owner_id)
     values ('e1000000-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000',
             'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000') $$,
  'A asks B again');
delete from public.loan_requests where id = 'e1000000-0000-4000-a000-000000000000';
select is((select count(*)::int from public.loan_requests where id = 'e1000000-0000-4000-a000-000000000000'), 0,
  'the requester cancels their own pending request');

insert into public.loan_requests (id, card_id, requester_id, owner_id) values
  ('e2000000-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000',
   'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000'),
  ('e3000000-0000-4000-a000-000000000000', '22222222-0000-4000-a000-000000000000',
   'aaaaaaaa-0000-4000-a000-000000000000', 'bbbbbbbb-0000-4000-a000-000000000000');

select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
delete from public.loan_requests where id = 'e2000000-0000-4000-a000-000000000000';
select is((select count(*)::int from public.loan_requests where id = 'e2000000-0000-4000-a000-000000000000'), 1,
  'the owner cannot delete a pending request');
update public.loan_requests set status = 'lent' where id = 'e2000000-0000-4000-a000-000000000000';
update public.loan_requests set status = 'declined' where id = 'e3000000-0000-4000-a000-000000000000';

select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
delete from public.loan_requests where id = 'e2000000-0000-4000-a000-000000000000';
select is((select status from public.loan_requests where id = 'e2000000-0000-4000-a000-000000000000'), 'lent',
  'the requester cannot cancel a lent loan');
delete from public.loan_requests where id = 'e3000000-0000-4000-a000-000000000000';
select is((select status from public.loan_requests where id = 'e3000000-0000-4000-a000-000000000000'), 'declined',
  'the requester cannot delete a declined request');

select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is((select count(*)::int from public.loan_requests where id in ('e2000000-0000-4000-a000-000000000000', 'e3000000-0000-4000-a000-000000000000')), 0,
  'a stranger cannot see either party''s loans');
delete from public.loan_requests where id in ('e2000000-0000-4000-a000-000000000000', 'e3000000-0000-4000-a000-000000000000');

select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is((select count(*)::int from public.loan_requests where id in ('e2000000-0000-4000-a000-000000000000', 'e3000000-0000-4000-a000-000000000000')), 2,
  'a stranger''s delete removes nothing');

-- ── Game nights and RSVPs ──────────────────────────────────────────────────────────────────
select lives_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at) values (current_setting('test.group')::uuid, now() + interval '2 days') $$,
  'a member plans a game night');
select throws_ok(
  $$ insert into public.rsvps (game_night_id, user_id, status)
     select id, 'bbbbbbbb-0000-4000-a000-000000000000', 'going' from public.game_nights $$,
  '42501', null, 'A cannot RSVP for B');

-- ── A stranger sees nothing ────────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is(
  (select count(*)::int from public.playgroups) + (select count(*)::int from public.game_nights)
    + (select count(*)::int from public.loan_requests) + (select count(*)::int from public.collection_items),
  0, 'C sees no playgroup, game night, loan or collection');
select is((select count(*)::int from public.cards where id = '22222222-0000-4000-a000-000000000000'), 1, 'any signed-in user reads cards');
select is((select count(*)::int from public.card_versions where id = '11111111-0000-4000-a000-000000000000'), 1, 'any signed-in user reads card versions');

-- ── Signed out ─────────────────────────────────────────────────────────────────────────────
set local role postgres;
set local role anon;
select throws_ok($$ select * from public.profiles $$, '42501', null, 'anon cannot read profiles');
select throws_ok($$ select * from public.cards $$, '42501', null, 'anon cannot read cards');
select throws_ok($$ select * from public.card_versions $$, '42501', null, 'anon cannot read card versions');

set local role postgres;
select * from finish();
rollback;
