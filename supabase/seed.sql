-- Local development seed (runs on `npm run db:reset`; `db push` never sends it to the remote project).
-- Mirrors the playgroup in spellbinder-app's mock seed (src/data/mock/seed/playgroup.ts).
-- Collections and decks are not seeded yet (TODO SB-5).
--
-- Sign in with any of these, password `spellbinder-dev`:
--   you@spellbinder.test · jonas@spellbinder.test · mira@spellbinder.test · erik@spellbinder.test · sanna@spellbinder.test

-- ── Users (the on_auth_user_created trigger creates their profiles) ───────────────────────
with seed_users (id, email, display_name) as (
  values
    ('00000000-0000-4000-a000-000000000001'::uuid, 'you@spellbinder.test', 'You'),
    ('00000000-0000-4000-a000-000000000002'::uuid, 'jonas@spellbinder.test', 'Jonas'),
    ('00000000-0000-4000-a000-000000000003'::uuid, 'mira@spellbinder.test', 'Mira'),
    ('00000000-0000-4000-a000-000000000004'::uuid, 'erik@spellbinder.test', 'Erik'),
    ('00000000-0000-4000-a000-000000000005'::uuid, 'sanna@spellbinder.test', 'Sanna')
),
inserted as (
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  )
  select
    '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
    extensions.crypt('spellbinder-dev', extensions.gen_salt('bf')), now(),
    '{"provider": "email", "providers": ["email"]}'::jsonb, jsonb_build_object('display_name', display_name),
    now(), now(), '', '', '', ''
  from seed_users
  returning id, email
)
insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), id, id::text, 'email',
       jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true), now(), now(), now()
from inserted;

update public.profiles p
set initials = v.initials, avatar_color = v.color
from (
  values
    ('00000000-0000-4000-a000-000000000001'::uuid, 'YO', 'gold'),
    ('00000000-0000-4000-a000-000000000002'::uuid, 'JO', 'blue'),
    ('00000000-0000-4000-a000-000000000003'::uuid, 'MI', 'violet'),
    ('00000000-0000-4000-a000-000000000004'::uuid, 'ER', 'green'),
    ('00000000-0000-4000-a000-000000000005'::uuid, 'SA', 'red')
) as v (id, initials, color)
where p.id = v.id;

-- ── The Thursday Table (Jonas owns it) ──────────────────────────────────────────────────────
insert into public.playgroups (id, name, invite_code, created_by)
values ('00000000-0000-4000-b000-000000000001', 'The Thursday Table', 'THURS7Q2', '00000000-0000-4000-a000-000000000002');

insert into public.playgroup_members (playgroup_id, user_id, role)
select '00000000-0000-4000-b000-000000000001', id,
       case when id = '00000000-0000-4000-a000-000000000002' then 'owner' else 'member' end
from public.profiles;

-- ── Next game night: Thursday 19:00 Oslo time, 4 of 5 going ─────────────────────────────────
insert into public.game_nights (id, playgroup_id, starts_at, location, notes, created_by)
select '00000000-0000-4000-c000-000000000001', '00000000-0000-4000-b000-000000000001',
       case when thursday > now() then thursday else thursday + interval '7 days' end,
       'Jonas''s', 'Bracket 2–3 decks. Pizza at 18:30.', '00000000-0000-4000-a000-000000000002'
from (
  select (date_trunc('week', now() at time zone 'Europe/Oslo') + interval '3 days 19 hours') at time zone 'Europe/Oslo' as thursday
) t;

insert into public.rsvps (game_night_id, user_id, status)
values
  ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000001', 'going'),
  ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000002', 'going'),
  ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000003', 'going'),
  ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000004', 'going'),
  ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-a000-000000000005', 'maybe');

-- ── This season's 21 games, one a week, oldest first: Mira 7, Jonas 5, You 4, Erik 3, Sanna 2 ──
insert into public.games (playgroup_id, played_at, winner_id, player_count, created_by)
select '00000000-0000-4000-b000-000000000001',
       now() - (22 - n) * interval '7 days',
       ('00000000-0000-4000-a000-00000000000' || w)::uuid,
       4,
       ('00000000-0000-4000-a000-00000000000' || w)::uuid
from unnest(array[3, 2, 1, 3, 4, 2, 3, 5, 1, 3, 2, 4, 3, 1, 2, 5, 3, 4, 2, 1, 3]) with ordinality as s (w, n);

-- ── Loans ───────────────────────────────────────────────────────────────────────────────────
insert into public.loan_requests (card_oracle_id, requester_id, owner_id, status, note, created_at)
values
  -- Cyclonic Rift: Erik → you
  ('d75b9c82-1b49-4c3e-a1b5-aeef57d6644b', '00000000-0000-4000-a000-000000000001', '00000000-0000-4000-a000-000000000004',
   'lent', 'For Muldrotha until the next game night', '2026-09-24T18:00:00Z'),
  -- Lightning Greaves: you → Mira
  ('ca204b66-8d0c-431a-8d34-282f7c2d17da', '00000000-0000-4000-a000-000000000003', '00000000-0000-4000-a000-000000000001',
   'lent', null, '2026-09-17T19:30:00Z'),
  -- Rhystic Study: Jonas asks you
  ('53236dd7-845a-444c-96d5-f41ed7325d8f', '00000000-0000-4000-a000-000000000002', '00000000-0000-4000-a000-000000000001',
   'pending', 'Want to try it in my Kenrith deck on Thursday', '2026-10-11T09:12:00Z');
