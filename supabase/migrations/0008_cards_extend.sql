-- Extend the card cache with the fields the features need, and add the lookups the clients call (roadmap SB-4).
--
--   cards              + game_changer (Commander Brackets), produced_mana (ramp/land stats), keywords, edhrec_rank
--   card_versions      + released_at, set_name, lang, digital
--   indexes            trigram index on cards.name (autocomplete, fuzzy names); one version per set, collector
--                      number and language (scanner lookup)
--   sync_card_batch    writes the new columns (same signature, so the sync script keeps working before and after)
--   search_card_names  autocomplete: distinct names, prefix matches first, then fuzzy ones
--   find_card          one card by name: exact, then case-insensitive, then a face's name, then the best fuzzy match
--   card_versions_of   a card's versions, newest first
--
-- Not in this migration:
--   * card_versions.scryfall_updated_at (in the roadmap): Scryfall's card objects have no update time to copy.
--     `updated_at`, which the sync only moves when a version changed, and card_sync_runs already tell how fresh the
--     data is.
--   * The RLS lockdown (only the service role writes cards and card_versions). The app still caches every card it
--     looks up, and the sync hasn't run on the remote project yet, so locking now would stop users adding cards. It
--     gets its own migration after the first remote sync, shipped with the app change that stops the writes (CC-3
--     step 4).
--
-- Backward compatible: new nullable or defaulted columns, new indexes and functions. `lang` has no default: a version
-- cached without one stays null (nulls never clash in the unique index) until the sync fills it.

create extension if not exists pg_trgm with schema extensions;

-- ── New columns ────────────────────────────────────────────────────────────────────────────
alter table public.cards
  add column game_changer   boolean not null default false,
  add column produced_mana  text[],                        -- null: makes no mana (as Scryfall omits it)
  add column keywords       text[] not null default '{}',
  add column edhrec_rank    integer;                       -- null: not ranked

alter table public.card_versions
  add column released_at  date,
  add column set_name     text,
  add column lang         text,                            -- Scryfall's language code: en, ja, de…
  add column digital      boolean not null default false;

-- ── Indexes ────────────────────────────────────────────────────────────────────────────────
-- Serves ilike and the trigram operators (%, <%) in the lookups below. pg_trgm folds case.
create index cards_name_trgm_idx on public.cards using gin (name extensions.gin_trgm_ops);
-- The scanner reads a set code and collector number; Scryfall has one printing per set, number and language.
create unique index card_versions_set_number_lang_key on public.card_versions (set, collector_number, lang);

-- ── sync_card_batch: same as 0006, plus the new columns ────────────────────────────────────
-- A changed edhrec_rank counts as a change, so a card whose rank moved is rewritten.
create or replace function public.sync_card_batch(card_rows jsonb, version_rows jsonb, price_rows jsonb)
returns integer
language plpgsql security invoker set search_path = ''
as $$
declare
  written integer;
  total integer := 0;
begin
  insert into public.cards as c (
    id, name, layout, mana_cost, cmc, type_line, rules_text, power, toughness, loyalty, colors, color_identity,
    legalities, card_faces, game_changer, produced_mana, keywords, edhrec_rank
  )
  select r.id, r.name, coalesce(r.layout, 'normal'), r.mana_cost, coalesce(r.cmc, 0), r.type_line, r.rules_text,
         r.power, r.toughness, r.loyalty, r.colors, coalesce(r.color_identity, '{}'), coalesce(r.legalities, '{}'),
         r.card_faces, coalesce(r.game_changer, false), r.produced_mana, coalesce(r.keywords, '{}'), r.edhrec_rank
  from jsonb_populate_recordset(null::public.cards, card_rows) r
  on conflict (id) do update set
    name = excluded.name, layout = excluded.layout, mana_cost = excluded.mana_cost, cmc = excluded.cmc,
    type_line = excluded.type_line, rules_text = excluded.rules_text, power = excluded.power,
    toughness = excluded.toughness, loyalty = excluded.loyalty, colors = excluded.colors,
    color_identity = excluded.color_identity, legalities = excluded.legalities, card_faces = excluded.card_faces,
    game_changer = excluded.game_changer, produced_mana = excluded.produced_mana, keywords = excluded.keywords,
    edhrec_rank = excluded.edhrec_rank, updated_at = now()
  where (c.name, c.layout, c.mana_cost, c.cmc, c.type_line, c.rules_text, c.power, c.toughness, c.loyalty, c.colors,
         c.color_identity, c.legalities, c.card_faces, c.game_changer, c.produced_mana, c.keywords, c.edhrec_rank)
        is distinct from
        (excluded.name, excluded.layout, excluded.mana_cost, excluded.cmc, excluded.type_line, excluded.rules_text,
         excluded.power, excluded.toughness, excluded.loyalty, excluded.colors, excluded.color_identity,
         excluded.legalities, excluded.card_faces, excluded.game_changer, excluded.produced_mana, excluded.keywords,
         excluded.edhrec_rank);
  get diagnostics written = row_count;
  total := total + written;

  -- card_id is never updated: collection_items reference (version_id, card_id) as a pair.
  insert into public.card_versions as v (
    id, card_id, set, collector_number, rarity, artist, image_uris, card_faces, finishes, released_at, set_name,
    lang, digital
  )
  select r.id, r.card_id, r.set, r.collector_number, coalesce(r.rarity, 'common'), r.artist, r.image_uris,
         r.card_faces, coalesce(r.finishes, '{nonfoil}'), r.released_at, r.set_name, r.lang, coalesce(r.digital, false)
  from jsonb_populate_recordset(null::public.card_versions, version_rows) r
  on conflict (id) do update set
    set = excluded.set, collector_number = excluded.collector_number, rarity = excluded.rarity,
    artist = excluded.artist, image_uris = excluded.image_uris, card_faces = excluded.card_faces,
    finishes = excluded.finishes, released_at = excluded.released_at, set_name = excluded.set_name,
    lang = excluded.lang, digital = excluded.digital, updated_at = now()
  where (v.set, v.collector_number, v.rarity, v.artist, v.image_uris, v.card_faces, v.finishes, v.released_at,
         v.set_name, v.lang, v.digital)
        is distinct from
        (excluded.set, excluded.collector_number, excluded.rarity, excluded.artist, excluded.image_uris,
         excluded.card_faces, excluded.finishes, excluded.released_at, excluded.set_name, excluded.lang,
         excluded.digital);
  get diagnostics written = row_count;
  total := total + written;

  insert into public.card_prices (version_id, source, usd, usd_foil, usd_etched, eur, eur_foil, eur_etched, tix)
  select r.version_id, coalesce(r.source, 'scryfall'), r.usd, r.usd_foil, r.usd_etched, r.eur, r.eur_foil,
         r.eur_etched, r.tix
  from jsonb_populate_recordset(null::public.card_prices, price_rows) r
  on conflict (version_id, source) do update set
    usd = excluded.usd, usd_foil = excluded.usd_foil, usd_etched = excluded.usd_etched, eur = excluded.eur,
    eur_foil = excluded.eur_foil, eur_etched = excluded.eur_etched, tix = excluded.tix, updated_at = now();
  get diagnostics written = row_count;
  total := total + written;

  return total;
end;
$$;

-- create or replace keeps the grants from 0006 (service role only).

-- ── Lookups (RPCs for signed-in users; security invoker, so the cards' RLS applies) ─────────
-- User input goes into ilike patterns with its wildcards escaped. The fuzzy steps use pg_trgm: `<%` (word similarity,
-- a match anywhere in the name) for autocomplete, `%` (similarity of the whole name) for find_card.

-- Up to `lim` (1–50) distinct names for what the user has typed so far.
create or replace function public.search_card_names(q text, lim integer default 20)
returns table (name text)
language sql stable security invoker set search_path = ''
as $$
  with term as (
    select btrim(q) as q,
           replace(replace(replace(btrim(q), '\', '\\'), '%', '\%'), '_', '\_') || '%' as prefix
  )
  select c.name
  from public.cards c, term t
  where t.q <> ''
    and (c.name ilike t.prefix or t.q operator(extensions.<%) c.name)
  group by c.name
  order by bool_or(c.name ilike t.prefix) desc,
           max(extensions.word_similarity(t.q, c.name)) desc,
           max(extensions.similarity(t.q, c.name)) desc, -- on a tie, the name closest as a whole
           c.name
  limit least(greatest(coalesce(lim, 20), 1), 50);
$$;

-- The card a scanned or typed name means, or nothing. A face's name ("Delver of Secrets") finds the whole card;
-- a fuzzy match needs a similarity of at least 0.4.
create or replace function public.find_card(name text)
returns setof public.cards
language sql stable security invoker set search_path = ''
as $$
  with term as (
    select btrim(find_card.name) as q,
           replace(replace(replace(btrim(find_card.name), '\', '\\'), '%', '\%'), '_', '\_') as pattern
  )
  select c.*
  from public.cards c, term t
  where t.q <> ''
    and (lower(c.name) = lower(t.q)
         or c.name ilike t.pattern || ' // %'
         or c.name ilike '% // ' || t.pattern
         or (t.q operator(extensions.%) c.name and extensions.similarity(t.q, c.name) >= 0.4))
  order by
    case
      when c.name = t.q then 1
      when lower(c.name) = lower(t.q) then 2
      when c.name ilike t.pattern || ' // %' or c.name ilike '% // ' || t.pattern then 3
      else 4
    end,
    extensions.similarity(t.q, c.name) desc,
    c.name,
    c.id
  limit 1;
$$;

-- Every version of a card, newest first.
create or replace function public.card_versions_of(card uuid)
returns setof public.card_versions
language sql stable security invoker set search_path = ''
as $$
  select v.*
  from public.card_versions v
  where v.card_id = card_versions_of.card
  order by v.released_at desc nulls last, v.set, length(v.collector_number), v.collector_number, v.id;
$$;

revoke execute on function public.search_card_names(text, integer), public.find_card(text),
  public.card_versions_of(uuid) from public, anon;
grant execute on function public.search_card_names(text, integer), public.find_card(text),
  public.card_versions_of(uuid) to authenticated;
