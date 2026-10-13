-- Card lookups (0008): search_card_names for autocomplete, find_card for scanned and typed names, card_versions_of for
-- a card's printings, and one version per set, collector number and language. Run: `npm run test:db`.
-- Everything runs in one transaction and is rolled back.
--
-- The names are made up so that real cards (after a sync) never match them.

begin;
create extension if not exists pgtap with schema extensions;
set local role postgres;
set local search_path = public, extensions;
select plan(20);

-- ── Setup (as postgres, bypassing RLS) ─────────────────────────────────────────────────────
insert into auth.users (id, email) values ('cccccccc-0000-4000-a000-000000000000', 'c@test.local');
insert into public.cards (id, name, type_line) values
  ('66666666-0000-4000-a000-000000000001', 'Glimmerquox Ring', 'Artifact'),
  ('66666666-0000-4000-a000-000000000002', 'Glimmerquox Ring', 'Artifact'), -- two cards, one name (Un-sets)
  ('66666666-0000-4000-a000-000000000003', 'Glimmerquox Talisman', 'Artifact'),
  ('66666666-0000-4000-a000-000000000004', 'Glimmerquoxian Sage', 'Creature'),
  ('66666666-0000-4000-a000-000000000005', 'Ring of Glimmerquox', 'Artifact'),
  ('66666666-0000-4000-a000-000000000006', 'Quoxwick Delver // Quoxwick Aberration', 'Creature // Creature'),
  ('66666666-0000-4000-a000-000000000007', 'Quoxwick Delvers', 'Creature');
insert into public.card_versions (id, card_id, set, collector_number, released_at, lang) values
  ('77777777-0000-4000-a000-000000000001', '66666666-0000-4000-a000-000000000001', 'qx1', '2', '2020-01-01', 'en'),
  ('77777777-0000-4000-a000-000000000002', '66666666-0000-4000-a000-000000000001', 'qx2', '10', '2024-06-01', 'en'),
  ('77777777-0000-4000-a000-000000000003', '66666666-0000-4000-a000-000000000001', 'qx3', '1', null, null),
  ('77777777-0000-4000-a000-000000000004', '66666666-0000-4000-a000-000000000003', 'qx1', '3', '2020-01-01', 'en');

select has_index('public', 'cards', 'cards_name_trgm_idx', 'card names have a trigram index');

-- ── As a signed-in user ────────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);

-- search_card_names
select is(
  (select array_agg(s.name order by s.n) from public.search_card_names('glimmerquox') with ordinality s (name, n)),
  array['Glimmerquox Ring', 'Glimmerquox Talisman', 'Glimmerquoxian Sage', 'Ring of Glimmerquox'],
  'autocomplete lists each name once, names that start with the query first, then names with the word inside');
select ok(
  'Glimmerquox Talisman' = any(array(select name from public.search_card_names('glimerquox talis'))),
  'autocomplete forgives a typo');
select is((select count(*)::int from public.search_card_names('glimmerquox', 2)), 2, 'autocomplete returns at most lim names');
select is((select count(*)::int from public.search_card_names('   ')), 0, 'a blank query finds nothing');
select is((select count(*)::int from public.search_card_names('%')), 0, 'a % in the query is a literal percent sign');
select is(
  (select count(*)::int from public.search_card_names('_', 50) where name not like '\_%'), 0,
  'an _ in the query is a literal underscore (real names start with one: "_____ Goblin")');

-- find_card
select is((select array_agg(name) from public.find_card('Glimmerquox Ring')), array['Glimmerquox Ring'],
  'the exact name finds one card, even when two cards share it');
select is((select name from public.find_card('  glimmerquox TALISMAN ')), 'Glimmerquox Talisman',
  'case and surrounding spaces don''t matter');
select is((select name from public.find_card('Quoxwick Delver')), 'Quoxwick Delver // Quoxwick Aberration',
  'a front face finds its card, ahead of a closer fuzzy match');
select is((select name from public.find_card('quoxwick aberration')), 'Quoxwick Delver // Quoxwick Aberration',
  'a back face finds its card');
select is((select name from public.find_card('Glimmerquox Talisnam')), 'Glimmerquox Talisman',
  'a misread name finds the most similar card');
select is((select count(*)::int from public.find_card('Qwzvplk Mnbrtx')), 0, 'a name like no card finds nothing');
select is(
  (select count(*)::int from public.find_card('%')) + (select count(*)::int from public.find_card('_'))
    + (select count(*)::int from public.find_card('')),
  0, 'a wildcard or a blank name finds nothing');

-- card_versions_of
select is(
  (select array_agg(v.id order by v.ordinality)
   from public.card_versions_of('66666666-0000-4000-a000-000000000001') with ordinality v),
  array['77777777-0000-4000-a000-000000000002', '77777777-0000-4000-a000-000000000001',
        '77777777-0000-4000-a000-000000000003']::uuid[],
  'a card''s versions come newest first, undated last, and only its own');

-- ── One version per set, collector number and language ─────────────────────────────────────
set local role postgres;
select throws_ok(
  $$ insert into public.card_versions (id, card_id, set, collector_number, lang)
     values ('77777777-0000-4000-a000-000000000009', '66666666-0000-4000-a000-000000000001', 'qx1', '2', 'en') $$,
  '23505', null, 'a second version with the same set, number and language is rejected');
select lives_ok(
  $$ insert into public.card_versions (id, card_id, set, collector_number, lang) values
       ('77777777-0000-4000-a000-000000000010', '66666666-0000-4000-a000-000000000001', 'qx1', '2', 'ja'),
       ('77777777-0000-4000-a000-000000000011', '66666666-0000-4000-a000-000000000001', 'qx9', '1', null),
       ('77777777-0000-4000-a000-000000000012', '66666666-0000-4000-a000-000000000001', 'qx9', '1', null) $$,
  'another language, or versions with no language yet, are fine');

-- ── Signed out ─────────────────────────────────────────────────────────────────────────────
set local role anon;
select throws_ok($$ select * from public.search_card_names('glimmerquox') $$, '42501', null, 'anon cannot autocomplete');
select throws_ok($$ select * from public.find_card('Glimmerquox Ring') $$, '42501', null, 'anon cannot look up a card');
select throws_ok(
  $$ select * from public.card_versions_of('66666666-0000-4000-a000-000000000001') $$,
  '42501', null, 'anon cannot list versions');

set local role postgres;
select * from finish();
rollback;
