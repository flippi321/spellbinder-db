-- Game nights get a title, a bracket range, repeating series, soft cancelling and "changed by" (PG-7).
--
-- Adds:
-- - Table game_night_series: one row per repeating plan (weekly or monthly, every 1 or 2), in the creator's IANA time
--   zone so 19:00 stays 19:00 across daylight saving. `generated_through` is the last occurrence ever created, so a
--   night a member deleted is never recreated; `ended_after` ends the series after that occurrence.
-- - game_nights: title, bracket_min / bracket_max (both null = Any), series_id + occurrence (unique per series),
--   cancelled_at / cancelled_by, updated_by.
-- - Triggers: updated_by = the signed-in user on every write to either table; moving a night (a new starts_at) deletes
--   its RSVPs so people answer again.
-- - RLS: members read, plan, change and delete series; any member (not only the creator) deletes a night.
-- - RPCs (security invoker, so RLS decides): plan_game_night, top_up_game_nights, change_game_nights,
--   cancel_game_nights. Nights exist up to two months ahead; the clients call top_up_game_nights on load.
--
-- Backward compatible: new table, new nullable columns or columns with defaults, a wider delete policy; today's app
-- keeps working.

-- ── Series ─────────────────────────────────────────────────────────────────────────────────
create table public.game_night_series (
  id                 uuid primary key default gen_random_uuid(),
  playgroup_id       uuid not null references public.playgroups (id) on delete cascade,
  title              text not null default 'Game night' check (char_length(title) between 1 and 60),
  location           text,
  notes              text,
  bracket_min        smallint check (bracket_min between 1 and 5),
  bracket_max        smallint check (bracket_max between 1 and 5),
  starts_at          timestamptz not null,  -- occurrence 0
  time_zone          text not null,         -- IANA, checked by the RPCs (pg_timezone_names)
  frequency          text not null check (frequency in ('weekly', 'monthly')),
  repeat_every       smallint not null default 1 check (repeat_every in (1, 2)),
  monthly_by         text check (monthly_by in ('weekday', 'date')),
  ended_after        integer check (ended_after >= -1),  -- last occurrence; -1 = none; null while running
  generated_through  integer not null default -1,        -- last occurrence created
  created_by         uuid not null default auth.uid() references public.profiles (id),
  updated_by         uuid references public.profiles (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint game_night_series_brackets_check
    check ((bracket_min is null) = (bracket_max is null) and (bracket_min is null or bracket_min <= bracket_max)),
  constraint game_night_series_monthly_rule_check check ((monthly_by is not null) = (frequency = 'monthly')),
  -- for the nights' (series_id, playgroup_id) key: a night belongs to a series of its own group
  constraint game_night_series_id_playgroup_key unique (id, playgroup_id)
);
create index game_night_series_playgroup_idx on public.game_night_series (playgroup_id);
create index game_night_series_created_by_idx on public.game_night_series (created_by);
create index game_night_series_updated_by_idx on public.game_night_series (updated_by);

create trigger game_night_series_touch_updated_at before update on public.game_night_series
  for each row execute function public.touch_updated_at();

-- ── New game_nights columns ────────────────────────────────────────────────────────────────
alter table public.game_nights
  add column title text not null default 'Game night' check (char_length(title) between 1 and 60),
  add column bracket_min smallint check (bracket_min between 1 and 5),
  add column bracket_max smallint check (bracket_max between 1 and 5),
  add column series_id uuid,
  add column occurrence integer check (occurrence >= 0),
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references public.profiles (id),
  add column updated_by uuid references public.profiles (id),
  add constraint game_nights_brackets_check
    check ((bracket_min is null) = (bracket_max is null) and (bracket_min is null or bracket_min <= bracket_max)),
  add constraint game_nights_series_occurrence_check check ((series_id is null) = (occurrence is null)),
  add constraint game_nights_cancelled_check check ((cancelled_at is null) = (cancelled_by is null)),
  add constraint game_nights_series_fkey
    foreign key (series_id, playgroup_id) references public.game_night_series (id, playgroup_id)
    on delete set null (series_id),
  -- each repeat exists once; also the index for series_id lookups
  add constraint game_nights_series_occurrence_key unique (series_id, occurrence);
create index game_nights_cancelled_by_idx on public.game_nights (cancelled_by);
create index game_nights_updated_by_idx on public.game_nights (updated_by);

-- ── Triggers ───────────────────────────────────────────────────────────────────────────────
-- Who wrote last. Without a signed-in user (service role, migrations) the row keeps what it had.
create or replace function private.stamp_updated_by()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_by := coalesce((select auth.uid()), new.updated_by);
  return new;
end;
$$;

create trigger game_nights_stamp_updated_by before insert or update on public.game_nights
  for each row execute function private.stamp_updated_by();
create trigger game_night_series_stamp_updated_by before insert or update on public.game_night_series
  for each row execute function private.stamp_updated_by();

-- A night whose series is deleted stays, as a one-off (the foreign key clears series_id; this clears occurrence).
create or replace function private.detach_game_night()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.series_id is null then
    new.occurrence := null;
  end if;
  return new;
end;
$$;

create trigger game_nights_detach before update of series_id on public.game_nights
  for each row execute function private.detach_game_night();

-- A night that moved keeps no RSVPs: people answer again. Security definer, because RLS only lets each member delete
-- their own RSVP.
create or replace function private.clear_rsvps_on_move()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.rsvps where game_night_id = new.id;
  return null;
end;
$$;

create trigger game_nights_clear_rsvps_on_move after update of starts_at on public.game_nights
  for each row when (new.starts_at is distinct from old.starts_at)
  execute function private.clear_rsvps_on_move();

revoke execute on function private.stamp_updated_by(), private.detach_game_night(), private.clear_rsvps_on_move()
  from public, anon, authenticated;

-- ── RLS ────────────────────────────────────────────────────────────────────────────────────
alter table public.game_night_series enable row level security;

create policy "game_night_series: members read" on public.game_night_series
  for select to authenticated using (private.is_playgroup_member(playgroup_id));
create policy "game_night_series: members plan" on public.game_night_series
  for insert to authenticated
  with check (private.is_playgroup_member(playgroup_id) and created_by = (select auth.uid()));
create policy "game_night_series: members update" on public.game_night_series
  for update to authenticated
  using (private.is_playgroup_member(playgroup_id)) with check (private.is_playgroup_member(playgroup_id));
create policy "game_night_series: members delete" on public.game_night_series
  for delete to authenticated using (private.is_playgroup_member(playgroup_id));

-- Anyone in the group may delete a night (groups run on trust; the app soft-cancels through cancel_game_nights).
drop policy if exists "game_nights: creator deletes" on public.game_nights;
create policy "game_nights: members delete" on public.game_nights
  for delete to authenticated using (private.is_playgroup_member(playgroup_id));

revoke all on public.game_night_series from anon;
grant select, insert, update, delete on public.game_night_series to authenticated;

-- ── Date rules ─────────────────────────────────────────────────────────────────────────────
-- The start of occurrence n of a series whose occurrence 0 is first_starts_at. Computed in the series' local time, so
-- 19:00 stays 19:00 across daylight saving.
-- - weekly: every repeat_every weeks, same weekday and time.
-- - monthly by date: the first night's day of the month; in a shorter month, its last day.
-- - monthly by weekday: the first night's nth weekday ("2nd Tuesday"); a 5th weekday means "the last <weekday>".
create or replace function private.game_night_occurrence(
  first_starts_at timestamptz, time_zone text, frequency text, repeat_every integer, monthly_by text, n integer
)
returns timestamptz
language plpgsql stable set search_path = ''
as $$
declare
  first_local timestamp := first_starts_at at time zone time_zone;
  month_start date;
  month_end date;
  weekday integer;
  week integer;
  target date;
begin
  if n = 0 then
    return first_starts_at;
  end if;

  if frequency = 'weekly' then
    return (first_local + make_interval(days => 7 * n * repeat_every)) at time zone time_zone;
  end if;

  month_start := (date_trunc('month', first_local) + make_interval(months => n * repeat_every))::date;
  month_end := (month_start + interval '1 month')::date - 1;

  if monthly_by = 'date' then
    target := least(month_start + (extract(day from first_local)::integer - 1), month_end);
  else
    weekday := extract(dow from first_local)::integer;
    week := (extract(day from first_local)::integer - 1) / 7 + 1;
    if week = 5 then
      target := month_end - (extract(dow from month_end)::integer - weekday + 7) % 7;
    else
      target := month_start + (weekday - extract(dow from month_start)::integer + 7) % 7 + 7 * (week - 1);
    end if;
  end if;

  return (target + first_local::time) at time zone time_zone;
end;
$$;

revoke execute on function private.game_night_occurrence(timestamptz, text, text, integer, text, integer)
  from public, anon;
grant execute on function private.game_night_occurrence(timestamptz, text, text, integer, text, integer)
  to authenticated;
