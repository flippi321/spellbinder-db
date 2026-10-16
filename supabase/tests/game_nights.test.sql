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
select plan(60);

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
select throws_ok(
  $$ insert into public.game_nights (playgroup_id, starts_at, cancelled_at) values ('99999999-0000-4000-a000-000000000001', now(), now()) $$,
  '23514', null, 'a cancelled night says who cancelled it');
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

set local role postgres;
select * from finish();
rollback;
