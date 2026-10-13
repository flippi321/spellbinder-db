-- Split the card cache into cards and card versions, name every card reference after them, and type a collection
-- item's condition and finish.
--
--   cards          one row per card, whatever the printing. `id` is Scryfall's oracle_id.
--   card_versions  one row per printing. `id` is Scryfall's id; `card_id` → cards.
--
-- Every other table now says `card_id` / `version_id` (was oracle_id / scryfall_id), with real foreign keys, so
-- "oracle" in the schema only means the AI feature. `oracle_text` becomes `cards.rules_text`.
--
-- BREAKING, in one step (an exception to the two-step rule in CLAUDE.md): no client runs in Supabase mode yet
-- (the app defaults to mock data and has no sign-in UI; the website doesn't exist), and the app's Supabase layer is
-- updated in the same change. From here on, renames go back to two steps.

-- ── Enums ──────────────────────────────────────────────────────────────────────────────────
-- Cardmarket's grading scale.
create type public.card_condition as enum ('M', 'NM', 'EX', 'GD', 'LP', 'PL', 'PO');
create type public.card_finish as enum ('nonfoil', 'foil', 'etched');

-- ── card_versions (the old `cards` table, one row per printing) ──────────────────────────────
alter table public.cards rename to card_versions;
alter table public.card_versions rename column scryfall_id to id;
alter table public.card_versions rename column oracle_id to card_id;
alter table public.card_versions rename constraint cards_pkey to card_versions_pkey;
alter index public.cards_oracle_idx rename to card_versions_card_idx;
drop index public.cards_name_idx; -- the name moves to `cards`
alter policy "cards: read" on public.card_versions rename to "card_versions: read";
alter policy "cards: insert" on public.card_versions rename to "card_versions: insert";
alter policy "cards: refresh" on public.card_versions rename to "card_versions: refresh";
comment on column public.card_versions.id is 'Scryfall id of this printing.';

-- ── cards (one row per card) ───────────────────────────────────────────────────────────────
create table public.cards (
  id              uuid primary key,
  name            text not null,
  layout          text not null default 'normal',
  mana_cost       text,
  cmc             numeric not null default 0,
  type_line       text not null,
  rules_text      text,
  power           text,
  toughness       text,
  loyalty         text,
  colors          text[],
  color_identity  text[] not null default '{}',
  legalities      jsonb not null default '{}'::jsonb,
  card_faces      jsonb, -- rules per face: name, mana_cost, type_line, rules_text, colors, power, toughness, loyalty
  updated_at      timestamptz not null default now()
);
create index cards_name_idx on public.cards (lower(name));
comment on column public.cards.id is 'Scryfall oracle_id: the same for every printing of the card.';

insert into public.cards (
  id, name, layout, mana_cost, cmc, type_line, rules_text, power, toughness, loyalty, colors, color_identity,
  legalities, card_faces, updated_at
)
select distinct on (v.card_id)
  v.card_id, v.name, v.layout, v.mana_cost, v.cmc, v.type_line, v.oracle_text, v.power, v.toughness, v.loyalty,
  v.colors, v.color_identity, v.legalities,
  (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'name', f -> 'name', 'mana_cost', f -> 'mana_cost', 'type_line', f -> 'type_line',
            'rules_text', f -> 'oracle_text', 'colors', f -> 'colors', 'power', f -> 'power',
            'toughness', f -> 'toughness', 'loyalty', f -> 'loyalty')) order by n)
   from jsonb_array_elements(v.card_faces) with ordinality as faces (f, n)),
  v.updated_at
from public.card_versions v
order by v.card_id, v.updated_at desc;

-- A version keeps only what differs per printing; its faces keep their images and artist.
update public.card_versions v
set card_faces = (
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('image_uris', f -> 'image_uris', 'artist', f -> 'artist')) order by n)
  from jsonb_array_elements(v.card_faces) with ordinality as faces (f, n)
)
where v.card_faces is not null;

alter table public.card_versions
  drop column name,
  drop column layout,
  drop column mana_cost,
  drop column cmc,
  drop column type_line,
  drop column oracle_text,
  drop column power,
  drop column toughness,
  drop column loyalty,
  drop column colors,
  drop column color_identity,
  drop column legalities,
  add column finishes public.card_finish[] not null default '{nonfoil}',
  add constraint card_versions_card_id_fkey foreign key (card_id) references public.cards (id) on delete restrict,
  add constraint card_versions_id_card_id_key unique (id, card_id); -- target of collection_items' pair key

-- Same access as card_versions: a shared cache any signed-in user reads and fills (locked down in SB-4).
alter table public.cards enable row level security;
revoke all on public.cards from anon;
grant select, insert, update, delete on public.cards to authenticated;
create policy "cards: read" on public.cards for select to authenticated using (true);
create policy "cards: insert" on public.cards for insert to authenticated with check (true);
create policy "cards: refresh" on public.cards for update to authenticated using (true) with check (true);

-- ── collection_items: version_id + card_id, typed condition and finish ─────────────────────────
alter table public.collection_items drop constraint collection_items_scryfall_id_fkey;
alter table public.collection_items drop constraint collection_items_user_id_scryfall_id_foil_condition_key;
alter table public.collection_items drop constraint collection_items_condition_check;
alter table public.collection_items rename column scryfall_id to version_id;
alter table public.collection_items rename column oracle_id to card_id;
drop index public.collection_items_scryfall_idx;
alter index public.collection_items_oracle_idx rename to collection_items_card_idx;
create index collection_items_version_idx on public.collection_items (version_id, card_id);
-- The pair key means a stack's card always matches its version.
alter table public.collection_items
  add constraint collection_items_version_fkey
  foreign key (version_id, card_id) references public.card_versions (id, card_id);

-- Old US grades map to their Cardmarket equivalents.
alter table public.collection_items alter column condition drop default;
alter table public.collection_items
  alter column condition type public.card_condition using (
    case condition
      when 'NM' then 'NM'
      when 'LP' then 'EX'
      when 'MP' then 'GD'
      when 'HP' then 'PL'
      when 'DMG' then 'PO'
    end
  )::public.card_condition;
alter table public.collection_items alter column condition set default 'NM';

alter table public.collection_items add column finish public.card_finish not null default 'nonfoil';
update public.collection_items set finish = 'foil' where foil;
alter table public.collection_items drop column foil;
alter table public.collection_items
  add constraint collection_items_user_version_finish_condition_key unique (user_id, version_id, finish, condition);

-- ── Every other card reference → card_id, with a foreign key ─────────────────────────────────
alter table public.deck_cards rename column oracle_id to card_id;
alter index public.deck_cards_oracle_idx rename to deck_cards_card_idx;
alter table public.deck_cards add constraint deck_cards_card_id_fkey foreign key (card_id) references public.cards (id);

alter table public.decks rename column commander_oracle_id to commander_card_id;
alter table public.decks rename column partner_oracle_id to partner_card_id;
alter table public.decks
  add constraint decks_commander_card_id_fkey foreign key (commander_card_id) references public.cards (id),
  add constraint decks_partner_card_id_fkey foreign key (partner_card_id) references public.cards (id);
create index decks_commander_card_idx on public.decks (commander_card_id);
create index decks_partner_card_idx on public.decks (partner_card_id);

alter table public.loan_requests rename column card_oracle_id to card_id;
alter table public.loan_requests add constraint loan_requests_card_id_fkey foreign key (card_id) references public.cards (id);
create index loan_requests_card_idx on public.loan_requests (card_id);

alter table public.games rename column winner_commander_oracle_id to winner_commander_card_id;
alter table public.games
  add constraint games_winner_commander_card_id_fkey foreign key (winner_commander_card_id) references public.cards (id);
create index games_winner_commander_card_idx on public.games (winner_commander_card_id);

-- The loan rules name the renamed column.
create or replace function public.enforce_loan_update()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null then
    return new; -- service role / SQL editor
  end if;
  if new.card_id <> old.card_id or new.requester_id <> old.requester_id or new.owner_id <> old.owner_id then
    raise exception 'A loan''s card and parties cannot change';
  end if;
  if new.status = old.status then
    return new;
  end if;
  if old.status = 'pending' and new.status in ('lent', 'declined') and me = old.owner_id then
    return new;
  end if;
  if old.status = 'lent' and new.status = 'returned' then
    return new;
  end if;
  raise exception 'Loan cannot go from % to %', old.status, new.status;
end;
$$;
