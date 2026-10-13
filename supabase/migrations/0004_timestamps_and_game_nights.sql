-- `updated_at` on every table that rows change in, and an optional link from a game to the game night it was played at.
--
-- Backward compatible: only new columns with defaults, triggers and a nullable foreign key.
--
-- Tables that keep the timestamp they have: rsvps (updated_at), cards / card_versions (updated_at, set by the writer),
-- playgroup_members (joined_at).

-- ── updated_at ─────────────────────────────────────────────────────────────────────────────
alter table public.profiles add column updated_at timestamptz not null default now();
alter table public.playgroups add column updated_at timestamptz not null default now();
alter table public.decks add column updated_at timestamptz not null default now();
alter table public.collection_items add column updated_at timestamptz not null default now();
alter table public.loan_requests add column updated_at timestamptz not null default now();
alter table public.game_nights add column updated_at timestamptz not null default now();
alter table public.games
  add column created_at timestamptz not null default now(),
  add column updated_at timestamptz not null default now();

-- Existing rows: last changed when they were made (before the triggers exist, so they don't overwrite it).
update public.profiles set updated_at = created_at;
update public.playgroups set updated_at = created_at;
update public.decks set updated_at = created_at;
update public.collection_items set updated_at = created_at;
update public.loan_requests set updated_at = created_at;
update public.game_nights set updated_at = created_at;
update public.games set created_at = played_at, updated_at = played_at;

create trigger profiles_touch_updated_at before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger playgroups_touch_updated_at before update on public.playgroups
  for each row execute function public.touch_updated_at();
create trigger decks_touch_updated_at before update on public.decks
  for each row execute function public.touch_updated_at();
create trigger collection_items_touch_updated_at before update on public.collection_items
  for each row execute function public.touch_updated_at();
create trigger loan_requests_touch_updated_at before update on public.loan_requests
  for each row execute function public.touch_updated_at();
create trigger game_nights_touch_updated_at before update on public.game_nights
  for each row execute function public.touch_updated_at();
create trigger games_touch_updated_at before update on public.games
  for each row execute function public.touch_updated_at();

-- Changing a deck's cards counts as changing the deck. Security invoker: only the deck's owner can write its cards,
-- and the owner may update the deck.
create or replace function public.touch_deck()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    update public.decks set updated_at = now() where id = old.deck_id;
  end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.deck_id <> old.deck_id) then
    update public.decks set updated_at = now() where id = new.deck_id;
  end if;
  return null;
end;
$$;

create trigger deck_cards_touch_deck after insert or update or delete on public.deck_cards
  for each row execute function public.touch_deck();

revoke execute on function public.touch_deck() from public, anon, authenticated;

-- ── games → game_nights (optional) ─────────────────────────────────────────────────────────
-- The pair key keeps a game in the same playgroup as its night. Ad-hoc games leave game_night_id null, and deleting
-- a night keeps its games (only game_night_id is cleared).
alter table public.game_nights add constraint game_nights_id_playgroup_key unique (id, playgroup_id);
alter table public.games add column game_night_id uuid;
alter table public.games
  add constraint games_game_night_fkey
  foreign key (game_night_id, playgroup_id) references public.game_nights (id, playgroup_id)
  on delete set null (game_night_id);
create index games_game_night_idx on public.games (game_night_id, playgroup_id);
