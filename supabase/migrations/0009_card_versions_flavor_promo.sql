-- Record each printing's flavor name and whether it's a promo, for the scanner (backlog SB-14, D-3 step 3 and (c)).
--
--   card_versions    + flavor_name (the name some printings carry instead of the card's: the Godzilla series, some
--                      Secret Lairs; a double-faced printing stores its front face's), promo
--   sync_card_batch  writes both and counts a change in either as a change (same signature, so the sync script keeps
--                    working before and after)
--
-- Not in this migration:
--   * An index on flavor_name: only a few hundred printings have one, and the scanner matches names on the device. It
--     can come with a server lookup that needs it (SC-4).
--   * Mapping the columns in the app (SB-17).
--
-- Backward compatible: a new nullable column, a new defaulted column, a function replaced with the same signature. The
-- updated sync script also works without this migration: jsonb_populate_recordset ignores keys the table lacks.

alter table public.card_versions
  add column flavor_name  text,                            -- null: printed with the card's own name
  add column promo        boolean not null default false;

-- ── sync_card_batch: same as 0008, plus flavor_name and promo on versions ──────────────────
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
    lang, digital, flavor_name, promo
  )
  select r.id, r.card_id, r.set, r.collector_number, coalesce(r.rarity, 'common'), r.artist, r.image_uris,
         r.card_faces, coalesce(r.finishes, '{nonfoil}'), r.released_at, r.set_name, r.lang, coalesce(r.digital, false),
         r.flavor_name, coalesce(r.promo, false)
  from jsonb_populate_recordset(null::public.card_versions, version_rows) r
  on conflict (id) do update set
    set = excluded.set, collector_number = excluded.collector_number, rarity = excluded.rarity,
    artist = excluded.artist, image_uris = excluded.image_uris, card_faces = excluded.card_faces,
    finishes = excluded.finishes, released_at = excluded.released_at, set_name = excluded.set_name,
    lang = excluded.lang, digital = excluded.digital, flavor_name = excluded.flavor_name, promo = excluded.promo,
    updated_at = now()
  where (v.set, v.collector_number, v.rarity, v.artist, v.image_uris, v.card_faces, v.finishes, v.released_at,
         v.set_name, v.lang, v.digital, v.flavor_name, v.promo)
        is distinct from
        (excluded.set, excluded.collector_number, excluded.rarity, excluded.artist, excluded.image_uris,
         excluded.card_faces, excluded.finishes, excluded.released_at, excluded.set_name, excluded.lang,
         excluded.digital, excluded.flavor_name, excluded.promo);
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
