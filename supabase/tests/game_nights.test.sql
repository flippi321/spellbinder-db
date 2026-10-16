-- Game nights (0010): titles, brackets, series, "changed by", members delete, RSVPs cleared when a night moves, the
-- repeat date rules, and the plan / top-up / change / cancel RPCs. Run: `npm run test:db`.
-- Everything runs in one transaction and is rolled back.
--
-- A and B share playgroup G1; C is alone in G2 (a stranger to G1).
-- Act as a user with `set local role authenticated` + request.jwt.claims; `set local role postgres` switches back.

begin;
create extension if not exists pgtap with schema extensions;
set local role postgres;
set local search_path = public, extensions;
select plan(112);

-- ── Setup (as postgres, bypassing RLS) ─────────────────────────────────────────────────────
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-4000-a000-000000000000', 'a@test.local'),
  ('bbbbbbbb-0000-4000-a000-000000000000', 'b@test.local'),
  ('cccccccc-0000-4000-a000-000000000000', 'c@test.local');
insert into public.playgroups (id, name, created_by) values
  ('99999999-0000-4000-a000-000000000001', 'G1', 'aaaaaaaa-0000-4000-a000-000000000000'),
  ('99999999-0000-4000-a000-000000000002', 'G2', 'cccccccc-0000-4000-a000-000000000000');
insert into public.playgroup_members (playgroup_id, user_id, role) values
  ('99999999-0000-4000-a000-000000000001', 'aaaaaaaa-0000-4000-a000-000000000000', 'owner'),
  ('99999999-0000-4000-a000-000000000001', 'bbbbbbbb-0000-4000-a000-000000000000', 'member'),
  ('99999999-0000-4000-a000-000000000002', 'cccccccc-0000-4000-a000-000000000000', 'owner');

-- ══ Schema: titles, brackets, updated_by, RSVPs on a move, members delete, series RLS ══════════
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);

insert into public.game_nights (id, playgroup_id, starts_at)
values ('eeeeeeee-0000-4000-a000-000000000001', '99999999-0000-4000-a000-000000000001', now() + interval '3 days');
select is((select title from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000001'), 'Game night',
  'a night planned without a title is called Game night');
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, title)
     values ('99999999-0000-4000-a000-000000000001', now(), repeat('x', 61)) $$,
  '23514', null, 'a title is at most 60 characters');
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, title) values ('99999999-0000-4000-a000-000000000001', now(), '') $$,
  '23514', null, 'a title is not empty');

-- Brackets: both null (Any) or both set, 1–5, min <= max.
select lives_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, bracket_min, bracket_max) values ('99999999-0000-4000-a000-000000000001', now(), 2, 3) $$,
  'brackets 2–3 are fine');
select lives_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, bracket_min, bracket_max) values ('99999999-0000-4000-a000-000000000001', now(), null, null) $$,
  'no brackets (Any) is fine');
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, bracket_min, bracket_max) values ('99999999-0000-4000-a000-000000000001', now(), 3, 2) $$,
  '23514', null, 'the lowest bracket cannot be above the highest');
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, bracket_min, bracket_max) values ('99999999-0000-4000-a000-000000000001', now(), 2, null) $$,
  '23514', null, 'brackets are both set or both empty');
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, bracket_min, bracket_max) values ('99999999-0000-4000-a000-000000000001', now(), 0, 1) $$,
  '23514', null, 'brackets start at 1');

-- updated_by follows whoever wrote last.
select is((select updated_by from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000001'),
  'aaaaaaaa-0000-4000-a000-000000000000'::uuid, 'planning a night stamps updated_by');

select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
update public.game_nights set location = 'B''s place' where id = 'eeeeeeee-0000-4000-a000-000000000001';
select is((select updated_by from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000001'),
  'bbbbbbbb-0000-4000-a000-000000000000'::uuid, 'changing a night stamps updated_by with the member who changed it');

-- RSVPs survive a change of place, not a change of time (even when someone else moves the night).
insert into public.rsvps (game_night_id, user_id, status)
values ('eeeeeeee-0000-4000-a000-000000000001', 'bbbbbbbb-0000-4000-a000-000000000000', 'going');

select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
update public.game_nights set location = 'A''s place' where id = 'eeeeeeee-0000-4000-a000-000000000001';
select is((select count(*)::int from public.rsvps where game_night_id = 'eeeeeeee-0000-4000-a000-000000000001'), 1,
  'a new place keeps the RSVPs');
update public.game_nights set bracket_min = 1, bracket_max = 4, title = 'Moved'
where id = 'eeeeeeee-0000-4000-a000-000000000001';
select is((select count(*)::int from public.rsvps where game_night_id = 'eeeeeeee-0000-4000-a000-000000000001'), 1,
  'a new title or bracket keeps the RSVPs');
update public.game_nights set starts_at = starts_at + interval '1 hour' where id = 'eeeeeeee-0000-4000-a000-000000000001';
select is((select count(*)::int from public.rsvps where game_night_id = 'eeeeeeee-0000-4000-a000-000000000001'), 0,
  'a new time clears the RSVPs');

-- Any member deletes a night; a stranger can't.
insert into public.game_nights (id, playgroup_id, starts_at)
values ('eeeeeeee-0000-4000-a000-000000000002', '99999999-0000-4000-a000-000000000001', now() + interval '4 days');

select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
delete from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000002';
set local role postgres;
select is((select count(*)::int from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000002'), 1,
  'a stranger cannot delete a night');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
delete from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000002';
set local role postgres;
select is((select count(*)::int from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000002'), 0,
  'any member deletes a night, not only its creator');

-- Series: members read, plan, change and delete them; strangers see and change nothing.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select lives_ok(
  $$ insert into public.game_night_series (id, playgroup_id, starts_at, time_zone, frequency)
     values ('5e5e5e5e-0000-4000-a000-000000000001', '99999999-0000-4000-a000-000000000001', now(), 'Europe/Oslo', 'weekly') $$,
  'a member plans a series');
select is((select (title, created_by, updated_by, generated_through)::text from public.game_night_series
           where id = '5e5e5e5e-0000-4000-a000-000000000001'),
  '("Game night",bbbbbbbb-0000-4000-a000-000000000000,bbbbbbbb-0000-4000-a000-000000000000,-1)',
  'a series has a default title, its creator, updated_by and nothing generated yet');
select throws_ok(
  $$ insert into public.game_night_series (playgroup_id, starts_at, time_zone, frequency, monthly_by)
     values ('99999999-0000-4000-a000-000000000001', now(), 'Europe/Oslo', 'weekly', 'date') $$,
  '23514', null, 'a weekly series has no monthly_by');
select throws_ok(
  $$ insert into public.game_night_series (playgroup_id, starts_at, time_zone, frequency)
     values ('99999999-0000-4000-a000-000000000001', now(), 'Europe/Oslo', 'monthly') $$,
  '23514', null, 'a monthly series says by weekday or by date');
select throws_ok(
  $$ insert into public.game_night_series (playgroup_id, starts_at, time_zone, frequency, repeat_every)
     values ('99999999-0000-4000-a000-000000000001', now(), 'Europe/Oslo', 'weekly', 3) $$,
  '23514', null, 'a series repeats every week or every other one');

select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
update public.game_night_series set title = 'Thursdays' where id = '5e5e5e5e-0000-4000-a000-000000000001';
select is((select (title, updated_by)::text from public.game_night_series where id = '5e5e5e5e-0000-4000-a000-000000000001'),
  '(Thursdays,aaaaaaaa-0000-4000-a000-000000000000)', 'another member changes the series, and updated_by says who');

select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select is((select count(*)::int from public.game_night_series), 0, 'a stranger sees no series');
select throws_ok(
  $$ insert into public.game_night_series (playgroup_id, starts_at, time_zone, frequency)
     values ('99999999-0000-4000-a000-000000000001', now(), 'Europe/Oslo', 'weekly') $$,
  '42501', null, 'a stranger cannot plan a series in the group');
update public.game_night_series set title = 'Hijacked';
delete from public.game_night_series;

set local role postgres;
select is((select title from public.game_night_series where id = '5e5e5e5e-0000-4000-a000-000000000001'), 'Thursdays',
  'a stranger cannot change or delete a series');

-- A series night has an occurrence number, and a cancelled night says who cancelled it.
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, series_id)
     values ('99999999-0000-4000-a000-000000000001', now(), '5e5e5e5e-0000-4000-a000-000000000001') $$,
  '23514', null, 'a series night needs an occurrence number');
select set_config('request.jwt.claims', '', true);
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, cancelled_at, created_by)
     values ('99999999-0000-4000-a000-000000000001', now(), now(), 'aaaaaaaa-0000-4000-a000-000000000000') $$,
  '23514', null, 'a cancelled night says who cancelled it (also without a signed-in user)');
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, series_id, occurrence, created_by)
     values ('99999999-0000-4000-a000-000000000002', now(), '5e5e5e5e-0000-4000-a000-000000000001', 0,
             'cccccccc-0000-4000-a000-000000000000') $$,
  '23503', null, 'a night belongs to a series of its own group');

-- Deleting a series keeps its nights, as one-offs.
insert into public.game_nights (id, playgroup_id, starts_at, series_id, occurrence, created_by)
values ('eeeeeeee-0000-4000-a000-000000000003', '99999999-0000-4000-a000-000000000001', now(),
        '5e5e5e5e-0000-4000-a000-000000000001', 0, 'aaaaaaaa-0000-4000-a000-000000000000');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
delete from public.game_night_series where id = '5e5e5e5e-0000-4000-a000-000000000001';
select is((select (series_id, occurrence)::text from public.game_nights where id = 'eeeeeeee-0000-4000-a000-000000000003'),
  '(,)', 'a member deletes a series; its nights stay as one-offs');

-- ══ Date rules: private.game_night_occurrence(first, time_zone, frequency, repeat_every, monthly_by, n) ═══════
-- Called as a member, the way the invoker RPCs call it. Europe/Oslo leaves daylight saving on 2026-10-25.
select is(private.game_night_occurrence('2026-10-15 17:00Z', 'Europe/Oslo', 'weekly', 1, null, 1), '2026-10-22 17:00Z'::timestamptz,
  'weekly: the next Thursday at 19:00 Oslo');
select is(private.game_night_occurrence('2026-10-15 17:00Z', 'Europe/Oslo', 'weekly', 1, null, 2), '2026-10-29 18:00Z'::timestamptz,
  'weekly: still 19:00 Oslo after daylight saving ends, so an hour later in UTC');
select is(private.game_night_occurrence('2026-10-15 17:00Z', 'Europe/Oslo', 'weekly', 2, null, 1), '2026-10-29 18:00Z'::timestamptz,
  'every other week skips a week');
select is(private.game_night_occurrence('2026-10-13 19:00 Europe/Oslo', 'Europe/Oslo', 'monthly', 1, 'weekday', 1),
  '2026-11-10 19:00 Europe/Oslo'::timestamptz, 'monthly by weekday: the 2nd Tuesday of November');
select is(private.game_night_occurrence('2026-10-13 19:00 Europe/Oslo', 'Europe/Oslo', 'monthly', 1, 'weekday', 2),
  '2026-12-08 19:00 Europe/Oslo'::timestamptz, 'monthly by weekday: the 2nd Tuesday of December');
select is(private.game_night_occurrence('2026-10-29 19:00 Europe/Oslo', 'Europe/Oslo', 'monthly', 1, 'weekday', 1),
  '2026-11-26 19:00 Europe/Oslo'::timestamptz, 'monthly by weekday: a 5th Thursday becomes the last Thursday');
select is(private.game_night_occurrence('2026-10-31 19:00 Europe/Oslo', 'Europe/Oslo', 'monthly', 1, 'date', 1),
  '2026-11-30 19:00 Europe/Oslo'::timestamptz, 'monthly by date: the 31st becomes the last day of a shorter month');
select is(private.game_night_occurrence('2026-10-31 19:00 Europe/Oslo', 'Europe/Oslo', 'monthly', 1, 'date', 2),
  '2026-12-31 19:00 Europe/Oslo'::timestamptz, 'monthly by date: back to the 31st when the month has one');
select is(private.game_night_occurrence('2026-10-14 19:00 Europe/Oslo', 'Europe/Oslo', 'monthly', 2, 'date', 1),
  '2026-12-14 19:00 Europe/Oslo'::timestamptz, 'every other month by date skips a month');
select is(private.game_night_occurrence('2026-03-26 19:00 Europe/Oslo', 'Europe/Oslo', 'weekly', 1, null, 1),
  '2026-04-02 19:00 Europe/Oslo'::timestamptz, 'weekly: still 19:00 Oslo after daylight saving starts');
select is(
  array[private.game_night_occurrence('2026-10-15 17:00Z', 'Europe/Oslo', 'weekly', 2, null, 0),
        private.game_night_occurrence('2026-10-15 17:00Z', 'Europe/Oslo', 'monthly', 1, 'weekday', 0),
        private.game_night_occurrence('2026-10-15 17:00Z', 'Europe/Oslo', 'monthly', 2, 'date', 0)],
  array['2026-10-15 17:00Z', '2026-10-15 17:00Z', '2026-10-15 17:00Z']::timestamptz[],
  'occurrence 0 is the first night for every rule');

-- ══ plan_game_night and top_up_game_nights ═════════════════════════════════════════════════
-- Start from an empty group.
set local role postgres;
delete from public.game_nights;
delete from public.game_night_series;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);

-- A one-off.
select set_config('test.oneoff', (
  select id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Cube night', starts_at => now() + interval '5 days',
    location => 'A''s place', notes => 'Bring sleeves', bracket_min => 2::smallint, bracket_max => 3::smallint,
    repeat => null)), true);
select is(
  (select (title, location, notes, bracket_min, bracket_max, series_id, occurrence, created_by)::text
   from public.game_nights where id = current_setting('test.oneoff')::uuid),
  '("Cube night","A''s place","Bring sleeves",2,3,,,aaaaaaaa-0000-4000-a000-000000000000)',
  'plan_game_night without a repeat makes one night as given');

-- A weekly series starting tomorrow: nights up to two months ahead.
select set_config('test.weekly_start', (now() + interval '1 day')::text, true);
select set_config('test.weekly_count', (
  select count(*)::text from generate_series(0, 20) n
  where private.game_night_occurrence(current_setting('test.weekly_start')::timestamptz, 'Europe/Oslo', 'weekly', 1, null, n)
        <= now() + interval '2 months'), true);
select set_config('test.first', (
  select id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Thursday Commander',
    starts_at => current_setting('test.weekly_start')::timestamptz, location => 'Jonas''s',
    bracket_min => 2::smallint, bracket_max => 3::smallint,
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select set_config('test.series', (select series_id::text from public.game_nights where id = current_setting('test.first')::uuid), true);

select is(
  (select (occurrence, starts_at = current_setting('test.weekly_start')::timestamptz)::text
   from public.game_nights where id = current_setting('test.first')::uuid),
  '(0,t)', 'plan_game_night with a repeat returns occurrence 0');
select is(
  (select count(*)::text from public.game_nights where series_id = current_setting('test.series')::uuid),
  current_setting('test.weekly_count'), 'a weekly series has its nights up to two months ahead');
select is(
  (select count(*)::int from public.game_nights
   where series_id = current_setting('test.series')::uuid and title = 'Thursday Commander' and location = 'Jonas''s'
     and bracket_min = 2 and bracket_max = 3),
  current_setting('test.weekly_count')::int, 'every night of the series has its title, place and brackets');
select is(
  (select (generated_through, frequency, repeat_every, monthly_by, time_zone)::text
   from public.game_night_series where id = current_setting('test.series')::uuid),
  format('(%s,weekly,1,,Europe/Oslo)', current_setting('test.weekly_count')::int - 1),
  'the series remembers its rule and the last occurrence it created');
select is(
  (select max(starts_at) from public.game_nights where series_id = current_setting('test.series')::uuid),
  private.game_night_occurrence(current_setting('test.weekly_start')::timestamptz, 'Europe/Oslo', 'weekly', 1, null,
    current_setting('test.weekly_count')::int - 1),
  'the last night falls on the series'' date for its number');

-- Idempotent.
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 0, 'a top-up right after planning creates nothing');
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 0, 'a second top-up creates nothing');
select is(
  (select count(*)::text from public.game_nights where series_id = current_setting('test.series')::uuid),
  current_setting('test.weekly_count'), 'top-ups never duplicate a night');

-- A night a member deleted stays deleted.
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
delete from public.game_nights where series_id = current_setting('test.series')::uuid and occurrence = 2;
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 0, 'a top-up after a delete creates nothing');
select is(
  (select count(*)::int from public.game_nights where series_id = current_setting('test.series')::uuid and occurrence = 2), 0,
  'a deleted night is not recreated');

-- Time passing (simulated): the last three nights don't exist yet, so a top-up creates exactly those.
set local role postgres;
delete from public.game_nights
where series_id = current_setting('test.series')::uuid and occurrence > current_setting('test.weekly_count')::int - 4;
update public.game_night_series set generated_through = generated_through - 3 where id = current_setting('test.series')::uuid;
set local role authenticated;
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 3, 'a top-up creates the missing nights');
select is(
  (select (count(*), count(distinct occurrence))::text from public.game_nights where series_id = current_setting('test.series')::uuid),
  format('(%s,%s)', current_setting('test.weekly_count')::int - 1, current_setting('test.weekly_count')::int - 1),
  'each night once (all but the deleted one)');

-- A lost generated_through still never duplicates a night.
set local role postgres;
update public.game_night_series set generated_through = generated_through - 3 where id = current_setting('test.series')::uuid;
set local role authenticated;
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 0,
  'a top-up over nights that exist creates nothing');
select is(
  (select generated_through from public.game_night_series where id = current_setting('test.series')::uuid),
  current_setting('test.weekly_count')::int - 1, 'and catches generated_through up');

-- Other repeats.
select set_config('test.monthly', (
  select series_id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Monthly', starts_at => now() + interval '3 days',
    repeat => '{"frequency": "monthly", "repeat_every": 2, "time_zone": "Europe/Oslo"}')), true);
select is(
  (select (frequency, repeat_every, monthly_by)::text from public.game_night_series where id = current_setting('test.monthly')::uuid),
  '(monthly,2,weekday)', 'a monthly series goes by weekday unless it says otherwise');
select set_config('test.far', (
  select series_id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Far off', starts_at => now() + interval '3 months',
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select is(
  (select count(*)::int from public.game_nights where series_id = current_setting('test.far')::uuid),
  1, 'a series that starts beyond two months still gets its first night');

-- Errors.
select throws_ok(
  $$ select public.plan_game_night(group_id => '99999999-0000-4000-a000-000000000001', title => 'Mars',
       starts_at => now(), repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Mars/Olympus"}') $$,
  'P0001', 'Unknown time zone', 'an unknown time zone is refused');

set local role postgres;
select set_config('test.g1_nights', (select count(*)::text from public.game_nights), true);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.plan_game_night(group_id => '99999999-0000-4000-a000-000000000001', title => 'Sneaky', starts_at => now(),
       repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}') $$,
  '42501', 'Not a member of this playgroup', 'a stranger cannot plan a night in the group');
select throws_ok(
  $$ select public.top_up_game_nights('99999999-0000-4000-a000-000000000001') $$,
  '42501', 'Not a member of this playgroup', 'a stranger cannot top up the group');
set local role postgres;
select is((select count(*)::text from public.game_nights), current_setting('test.g1_nights'), 'and nothing was added');

-- ══ change_game_nights and cancel_game_nights ══════════════════════════════════════════════
-- S1: "Thursdays", weekly from next week's Thursday 19:00 Oslo, at Jonas's, brackets 2–3. test.nK = its night K.
set local role postgres;
delete from public.game_nights;
delete from public.game_night_series;
select set_config('test.thursday',
  ((date_trunc('week', now() at time zone 'Europe/Oslo') + interval '10 days 19 hours') at time zone 'Europe/Oslo')::text, true);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select set_config('test.s1', (
  select series_id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Thursdays',
    starts_at => current_setting('test.thursday')::timestamptz, location => 'Jonas''s',
    bracket_min => 2::smallint, bracket_max => 3::smallint,
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select set_config('test.n' || n,
  (select id::text from public.game_nights where series_id = current_setting('test.s1')::uuid and occurrence = n), true)
from generate_series(0, 5) n;

-- B is going to nights 1, 2, 3 and 5.
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
insert into public.rsvps (game_night_id, user_id, status)
select current_setting('test.n' || n)::uuid, 'bbbbbbbb-0000-4000-a000-000000000000', 'going' from unnest(array[1, 2, 3, 5]) n;

-- Just this night.
select lives_ok(
  $$ select public.change_game_nights(current_setting('test.n1')::uuid, 'this', jsonb_build_object('starts_at',
       private.game_night_occurrence(current_setting('test.thursday')::timestamptz, 'Europe/Oslo', 'weekly', 1, null, 1)
       + interval '1 day')) $$,
  'B moves one night a day later');
select is(
  (select (starts_at = private.game_night_occurrence(current_setting('test.thursday')::timestamptz, 'Europe/Oslo', 'weekly', 1, null, 1)
                       + interval '1 day', updated_by, series_id = current_setting('test.s1')::uuid)::text
   from public.game_nights where id = current_setting('test.n1')::uuid),
  '(t,bbbbbbbb-0000-4000-a000-000000000000,t)', 'that night moved, B changed it, and it stays in its series');
select is((select count(*)::int from public.rsvps where game_night_id = current_setting('test.n1')::uuid), 0,
  'the moved night''s RSVPs are cleared');
select is(
  (select ((select count(*) from public.rsvps r where r.game_night_id = g.id),
           starts_at = private.game_night_occurrence(current_setting('test.thursday')::timestamptz, 'Europe/Oslo', 'weekly', 1, null, 2))::text
   from public.game_nights g where id = current_setting('test.n2')::uuid),
  '(1,t)', 'the next night keeps its time and RSVPs');

select public.change_game_nights(current_setting('test.n2')::uuid, 'this', '{"location": "Mira''s"}');
select is(
  (select (g.location, (select count(*) from public.rsvps r where r.game_night_id = g.id),
           (select location from public.game_nights where id = current_setting('test.n3')::uuid))::text
   from public.game_nights g where id = current_setting('test.n2')::uuid),
  '(Mira''s,1,Jonas''s)', 'a new place for just this night keeps its RSVPs and leaves the others');

-- Night 3 gets its own change, night 4 is cancelled: "this and later" from night 2 must handle both.
select public.change_game_nights(current_setting('test.n3')::uuid, 'this', jsonb_build_object('location', 'Elsewhere',
  'starts_at', (select starts_at + interval '2 hours' from public.game_nights where id = current_setting('test.n3')::uuid)));
select is(public.cancel_game_nights(current_setting('test.n4')::uuid, 'this'), 1, 'cancelling just this night cancels one');
select is(
  (select (cancelled_by, (select count(*) from public.game_nights c
                          where c.series_id = current_setting('test.s1')::uuid and c.cancelled_at is not null))::text
   from public.game_nights where id = current_setting('test.n4')::uuid),
  '(bbbbbbbb-0000-4000-a000-000000000000,1)', 'the night stays, cancelled by B, and no other night is cancelled');

-- This and later from night 2: Thursdays become Tuesdays (A changes it).
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select set_config('test.tuesday', (
  private.game_night_occurrence(current_setting('test.thursday')::timestamptz, 'Europe/Oslo', 'weekly', 1, null, 2)
  - interval '2 days')::text, true);
select lives_ok(
  $$ select public.change_game_nights(current_setting('test.n2')::uuid, 'later',
       jsonb_build_object('starts_at', current_setting('test.tuesday')::timestamptz)) $$,
  'A moves night 2 and every later night to Tuesdays');
select set_config('test.s2', (select series_id::text from public.game_nights where id = current_setting('test.n2')::uuid), true);
select is((select ended_after from public.game_night_series where id = current_setting('test.s1')::uuid), 1,
  'the old series ends before night 2');
select is(
  (select array_agg(id order by occurrence) from public.game_nights
   where series_id = current_setting('test.s1')::uuid and cancelled_at is null),
  array[current_setting('test.n0')::uuid, current_setting('test.n1')::uuid], 'nights 0 and 1 stay on the old series');
select is(
  (select (series_id <> current_setting('test.s1')::uuid, occurrence, starts_at = current_setting('test.tuesday')::timestamptz)::text
   from public.game_nights where id = current_setting('test.n2')::uuid),
  '(t,0,t)', 'night 2 starts a new series on the Tuesday');
select is(
  (select (count(*) filter (where extract(isodow from starts_at at time zone 'Europe/Oslo') <> 2
                               or (starts_at at time zone 'Europe/Oslo')::time <> '19:00'),
           count(*) >= 4)::text
   from public.game_nights where series_id = current_setting('test.s2')::uuid),
  '(0,t)', 'every night of the new series is a Tuesday at 19:00 Oslo');
select is(
  (select count(*)::int from public.rsvps r join public.game_nights g on g.id = r.game_night_id
   where g.series_id = current_setting('test.s2')::uuid),
  0, 'the moved nights lose their RSVPs');
select is(
  (select (series_id = current_setting('test.s2')::uuid, occurrence, location,
           starts_at = private.game_night_occurrence(current_setting('test.tuesday')::timestamptz, 'Europe/Oslo', 'weekly', 1, null, 1))::text
   from public.game_nights where id = current_setting('test.n3')::uuid),
  '(t,1,Mira''s,t)', 'night 3''s own change is overwritten by the new series (night 2 as changed)');
select is(
  (select (series_id = current_setting('test.s1')::uuid, occurrence, cancelled_at is not null,
           starts_at = private.game_night_occurrence(current_setting('test.thursday')::timestamptz, 'Europe/Oslo', 'weekly', 1, null, 4))::text
   from public.game_nights where id = current_setting('test.n4')::uuid),
  '(t,4,t,t)', 'the cancelled night 4 stays cancelled on the old series, on its old date');
select is(
  (select count(*)::int from public.game_nights where series_id = current_setting('test.s2')::uuid and occurrence = 2), 0,
  'the new series skips the cancelled week');
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 0, 'a later top-up creates nothing new');
select is((select count(*)::int from public.game_nights where series_id = current_setting('test.s1')::uuid), 3,
  'the old series gets no new nights');
select is(
  (select (private.game_night_occurrence(s.starts_at, s.time_zone, s.frequency, s.repeat_every, s.monthly_by, s.generated_through + 1)
             > now() + interval '2 months',
           (select max(occurrence) from public.game_nights g where g.series_id = s.id) = s.generated_through)::text
   from public.game_night_series s where id = current_setting('test.s2')::uuid),
  '(t,t)', 'the new series runs up to two months ahead');

-- This and later with only new brackets: the times stay, so the RSVPs do.
select set_config('test.s2_3',
  (select id::text from public.game_nights where series_id = current_setting('test.s2')::uuid and occurrence = 3), true);
select set_config('request.jwt.claims', '{"sub": "bbbbbbbb-0000-4000-a000-000000000000", "role": "authenticated"}', true);
insert into public.rsvps (game_night_id, user_id, status)
values (current_setting('test.s2_3')::uuid, 'bbbbbbbb-0000-4000-a000-000000000000', 'going');
select lives_ok(
  $$ select public.change_game_nights(current_setting('test.n3')::uuid, 'later', '{"bracket_min": 1, "bracket_max": 2}') $$,
  'B changes the brackets of night 3 and later');
select is(
  (select (count(*) filter (where (bracket_min, bracket_max) is distinct from (1::smallint, 2::smallint)),
           (select (bracket_min, bracket_max) from public.game_nights where id = current_setting('test.n2')::uuid))::text
   from public.game_nights
   where series_id = (select series_id from public.game_nights where id = current_setting('test.n3')::uuid)),
  '(0,"(2,3)")', 'every later night has brackets 1–2; the night before keeps 2–3');
select is((select count(*)::int from public.rsvps where game_night_id = current_setting('test.s2_3')::uuid), 1,
  'a later night whose time did not change keeps its RSVPs');

-- This and later from the first night (occurrence 0) replaces the whole series.
select set_config('test.m0', (
  select id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Mondays',
    starts_at => current_setting('test.thursday')::timestamptz + interval '4 days',
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select set_config('test.s4', (select series_id::text from public.game_nights where id = current_setting('test.m0')::uuid), true);
select lives_ok(
  $$ select public.change_game_nights(current_setting('test.m0')::uuid, 'later', '{"title": "Renamed"}') $$,
  'renaming the first night and every later one');
select is(
  (select (ended_after, (select count(*) from public.game_nights g where g.series_id = s.id))::text
   from public.game_night_series s where id = current_setting('test.s4')::uuid),
  '(-1,0)', 'the old series is left empty and ended before its first night');
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 0, 'top-up never extends the replaced series');
select set_config('test.s5', (select series_id::text from public.game_nights where id = current_setting('test.m0')::uuid), true);
select is(
  (select (count(*) filter (where title <> 'Renamed'), count(*) > 1)::text
   from public.game_nights where series_id = current_setting('test.s5')::uuid),
  '(0,t)', 'the new series has every night, renamed');

-- This and later with "repeat": null: the night becomes a one-off and the later nights go.
select set_config('test.m1',
  (select id::text from public.game_nights where series_id = current_setting('test.s5')::uuid and occurrence = 1), true);
select lives_ok(
  $$ select public.change_game_nights(current_setting('test.m1')::uuid, 'later', '{"repeat": null}') $$,
  'stop repeating from night 1');
select is((select (series_id, occurrence)::text from public.game_nights where id = current_setting('test.m1')::uuid), '(,)',
  'night 1 is a one-off');
select is(
  (select (ended_after, (select count(*) from public.game_nights g where g.series_id = s.id))::text
   from public.game_night_series s where id = current_setting('test.s5')::uuid),
  '(0,1)', 'the series ends after night 0, and the nights after night 1 are gone');

-- This and later with a repeat on a one-off: it becomes the first night of a new series.
select set_config('test.o1', (
  select id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Once',
    starts_at => current_setting('test.thursday')::timestamptz + interval '1 day')), true);
select lives_ok(
  $$ select public.change_game_nights(current_setting('test.o1')::uuid, 'later',
       '{"repeat": {"frequency": "weekly", "repeat_every": 2, "time_zone": "Europe/Oslo"}}') $$,
  'a one-off starts repeating every other week');
select is(
  (select (g.occurrence, s.repeat_every,
           (select count(*) from public.game_nights x where x.series_id = s.id)
           = (select count(*) from generate_series(0, 20) n
              where private.game_night_occurrence(g.starts_at, 'Europe/Oslo', 'weekly', 2, null, n) <= now() + interval '2 months'))::text
   from public.game_nights g join public.game_night_series s on s.id = g.series_id
   where g.id = current_setting('test.o1')::uuid),
  '(0,2,t)', 'it is occurrence 0 of a new series with its nights up to two months ahead');

select set_config('test.o2', (
  select id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Once more', starts_at => now() + interval '6 days')), true);
select public.change_game_nights(current_setting('test.o2')::uuid, 'later', '{"title": "Just once"}');
select is((select (title, series_id)::text from public.game_nights where id = current_setting('test.o2')::uuid),
  '("Just once",)', 'this and later on a one-off without a repeat changes just that night');

-- Cancel this and later.
select set_config('test.s6', (
  select series_id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Fridays',
    starts_at => current_setting('test.thursday')::timestamptz + interval '1 day',
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select set_config('test.s6_later',
  (select count(*)::text from public.game_nights where series_id = current_setting('test.s6')::uuid and occurrence >= 2), true);
select is(
  public.cancel_game_nights(
    (select id from public.game_nights where series_id = current_setting('test.s6')::uuid and occurrence = 2), 'later')::text,
  current_setting('test.s6_later'), 'cancelling night 2 and later cancels each of them');
select is(
  (select count(*)::int from public.game_nights
   where series_id = current_setting('test.s6')::uuid
     and (occurrence >= 2) <> (cancelled_by is not distinct from 'bbbbbbbb-0000-4000-a000-000000000000')),
  0, 'nights 2 and later are cancelled by B; nights 0 and 1 are not');
select is((select ended_after from public.game_night_series where id = current_setting('test.s6')::uuid), 1,
  'the series ends after night 1');
set local role postgres;
delete from public.game_nights where series_id = current_setting('test.s6')::uuid and occurrence > 3;
update public.game_night_series set generated_through = 3 where id = current_setting('test.s6')::uuid;
set local role authenticated;
select is(public.top_up_game_nights('99999999-0000-4000-a000-000000000001'), 0,
  'top-up creates nothing after a cancelled series');

-- This and later never brings back the last nights created when they were cancelled or deleted.
select set_config('test.s7', (
  select series_id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Wednesdays',
    starts_at => current_setting('test.thursday')::timestamptz + interval '6 days',
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select set_config('test.s7_last', (select generated_through::text from public.game_night_series where id = current_setting('test.s7')::uuid), true);
select public.cancel_game_nights(
  (select id from public.game_nights where series_id = current_setting('test.s7')::uuid
     and occurrence = current_setting('test.s7_last')::int), 'this');
delete from public.game_nights
where series_id = current_setting('test.s7')::uuid and occurrence = current_setting('test.s7_last')::int - 1;
select public.change_game_nights(
  (select id from public.game_nights where series_id = current_setting('test.s7')::uuid and occurrence = 2), 'later',
  '{"bracket_min": 1, "bracket_max": 2}');
select is(
  (select count(*)::int from public.game_nights g, public.game_night_series s
   where s.id = current_setting('test.s7')::uuid and g.title = 'Wednesdays' and g.cancelled_at is null
     and g.starts_at in (
       private.game_night_occurrence(s.starts_at, s.time_zone, s.frequency, s.repeat_every, s.monthly_by, current_setting('test.s7_last')::int),
       private.game_night_occurrence(s.starts_at, s.time_zone, s.frequency, s.repeat_every, s.monthly_by, current_setting('test.s7_last')::int - 1))),
  0, 'a later change does not bring back the last nights when they were cancelled or deleted');
select is(
  (select generated_through from public.game_night_series s
   where s.id = (select series_id from public.game_nights where title = 'Wednesdays' and occurrence = 0
                 and series_id <> current_setting('test.s7')::uuid)),
  current_setting('test.s7_last')::int - 2, 'the new series counts on from where the old one stopped');

-- This and later with a new repeat rule.
select set_config('test.s8', (
  select series_id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Rule change',
    starts_at => current_setting('test.thursday')::timestamptz + interval '5 days',
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select set_config('test.r1',
  (select id::text from public.game_nights where series_id = current_setting('test.s8')::uuid and occurrence = 1), true);
select public.change_game_nights(current_setting('test.r1')::uuid, 'later',
  '{"repeat": {"frequency": "weekly", "repeat_every": 2, "time_zone": "Europe/Oslo"}}');
select set_config('test.s9', (select series_id::text from public.game_nights where id = current_setting('test.r1')::uuid), true);
select is(
  (select (s.repeat_every,
           (select count(*) from public.game_nights g where g.series_id = s.id
              and g.starts_at <> private.game_night_occurrence(s.starts_at, s.time_zone, s.frequency, s.repeat_every, s.monthly_by, g.occurrence)),
           (select count(*) from public.game_nights g where g.series_id = s.id)
           = (select count(*) from generate_series(0, 20) n
              where private.game_night_occurrence(s.starts_at, s.time_zone, s.frequency, s.repeat_every, s.monthly_by, n)
                    <= now() + interval '2 months'))::text
   from public.game_night_series s where s.id = current_setting('test.s9')::uuid),
  '(2,0,t)', 'weekly becomes every other week from night 1 on, up to two months ahead');
select set_config('test.r2',
  (select id::text from public.game_nights where series_id = current_setting('test.s9')::uuid and occurrence = 1), true);
select public.change_game_nights(current_setting('test.r2')::uuid, 'later',
  '{"repeat": {"frequency": "monthly", "repeat_every": 1, "monthly_by": "date", "time_zone": "Europe/Oslo"}}');
select is(
  (select (s.frequency, s.repeat_every, s.monthly_by,
           (select count(*) from public.game_nights g where g.series_id = s.id
              and g.starts_at <> private.game_night_occurrence(s.starts_at, s.time_zone, s.frequency, s.repeat_every, s.monthly_by, g.occurrence)),
           (select count(*) from public.game_nights g where g.series_id = s.id)
           = (select count(*) from generate_series(0, 20) n
              where private.game_night_occurrence(s.starts_at, s.time_zone, s.frequency, s.repeat_every, s.monthly_by, n)
                    <= now() + interval '2 months'))::text
   from public.game_night_series s
   where s.id = (select series_id from public.game_nights where id = current_setting('test.r2')::uuid)),
  '(monthly,1,date,0,t)', 'every other week becomes monthly by date');

-- A series row always has a known time zone, even when written directly.
select throws_ok(
  $$ insert into public.game_night_series (playgroup_id, starts_at, time_zone, frequency)
     values ('99999999-0000-4000-a000-000000000001', now(), 'Mars/Olympus', 'weekly') $$,
  '22023', null, 'a series needs a known time zone');

-- Top-up doesn't fill in nights that have already passed.
select set_config('test.s10', (
  select series_id::text from public.plan_game_night(
    group_id => '99999999-0000-4000-a000-000000000001', title => 'Started earlier', starts_at => now() - interval '15 days',
    repeat => '{"frequency": "weekly", "repeat_every": 1, "time_zone": "Europe/Oslo"}')), true);
select is(
  (select (count(*) filter (where starts_at < now()), count(*) filter (where starts_at > now()) >= 8)::text
   from public.game_nights where series_id = current_setting('test.s10')::uuid),
  '(1,t)', 'a series that started in the past gets only its first night and the upcoming ones');

-- cancelled_by is always whoever cancelled.
select set_config('test.f0',
  (select id::text from public.game_nights where series_id = current_setting('test.s6')::uuid and occurrence = 0), true);
update public.game_nights set cancelled_at = now(), cancelled_by = 'aaaaaaaa-0000-4000-a000-000000000000'
where id = current_setting('test.f0')::uuid;
select is((select cancelled_by from public.game_nights where id = current_setting('test.f0')::uuid),
  'bbbbbbbb-0000-4000-a000-000000000000'::uuid, 'cancelling a night directly records the member who did it');
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
update public.game_nights set location = 'Somewhere', cancelled_by = 'aaaaaaaa-0000-4000-a000-000000000000'
where id = current_setting('test.f0')::uuid;
select is((select cancelled_by from public.game_nights where id = current_setting('test.f0')::uuid),
  'bbbbbbbb-0000-4000-a000-000000000000'::uuid, 'a later change keeps who cancelled it');

-- Errors.
select set_config('request.jwt.claims', '{"sub": "cccccccc-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.change_game_nights(current_setting('test.n0')::uuid, 'this', '{"title": "Hijacked"}') $$,
  'P0001', 'Game night not found', 'a stranger cannot change a night');
select throws_ok(
  $$ select public.cancel_game_nights(current_setting('test.n0')::uuid, 'later') $$,
  'P0001', 'Game night not found', 'a stranger cannot cancel a night');
set local role postgres;
select is((select (title, cancelled_at)::text from public.game_nights where id = current_setting('test.n0')::uuid),
  '(Thursdays,)', 'and the night is unchanged');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "aaaaaaaa-0000-4000-a000-000000000000", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.change_game_nights(current_setting('test.n0')::uuid, 'all', '{"title": "All"}') $$,
  'P0001', 'Unknown scope', 'change: the scope is this or later');
select throws_ok(
  $$ select public.cancel_game_nights(current_setting('test.n0')::uuid, 'all') $$,
  'P0001', 'Unknown scope', 'cancel: the scope is this or later');
select throws_ok(
  $$ select public.change_game_nights(current_setting('test.n0')::uuid, 'this', '{"repeat": null}') $$,
  'P0001', 'Repeat changes need scope later', 'the repeat changes only with this and later');
select throws_ok(
  $$ select public.change_game_nights(current_setting('test.n0')::uuid, 'this', '{"bracket_min": 1}') $$,
  'P0001', 'bracket_min and bracket_max go together', 'brackets change together');

set local role postgres;
select is(
  array[has_function_privilege('anon', 'public.plan_game_night(uuid, text, timestamptz, text, text, smallint, smallint, jsonb)', 'execute'),
        has_function_privilege('anon', 'public.top_up_game_nights(uuid)', 'execute'),
        has_function_privilege('anon', 'public.change_game_nights(uuid, text, jsonb)', 'execute'),
        has_function_privilege('anon', 'public.cancel_game_nights(uuid, text)', 'execute')],
  array[false, false, false, false], 'signed-out clients cannot call the game night RPCs');

set local role postgres;
select * from finish();
rollback;
