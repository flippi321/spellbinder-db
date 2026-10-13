-- The daily card sync (roadmap CC-2/CC-3): a log of its runs, and the RPC it writes each batch through.
--
--   card_sync_runs   one row per run of `scripts/sync-cards.ts` (GitHub Actions, daily). The app reads the latest
--                    `ok` row to show "Card data updated 3 h ago"; the script reads it to skip a bulk file it has
--                    already loaded.
--   sync_card_batch  upserts one batch of cards, card_versions and card_prices in one transaction, in foreign-key
--                    order. Cards and versions are only rewritten when a column changed, so a quiet day doesn't
--                    rewrite ~150k rows. Prices always get a new `updated_at`: snapshot_card_prices() (0005) dates
--                    the history row from it.
--
-- Only the service role writes. The sync never deletes cards or versions: collections, decks, loans and games
-- reference them. The cards / card_versions RLS lockdown is a separate step (SB-4, migration 0007), once the sync
-- has run on the remote project.
--
-- Backward compatible: a new table and a new function.

create table public.card_sync_runs (
  id               uuid primary key default gen_random_uuid(),
  started_at       timestamptz not null default now(),
  finished_at      timestamptz,
  bulk_type        text not null,         -- Scryfall bulk file, e.g. 'default_cards'
  bulk_updated_at  timestamptz not null,  -- the file's `updated_at`; a run with the same value and status ok is skipped
  rows_read        integer not null default 0,
  rows_upserted    integer not null default 0,  -- rows actually inserted or changed
  status           text not null default 'running' check (status in ('running', 'ok', 'failed')),
  error            text
);
create index card_sync_runs_started_idx on public.card_sync_runs (started_at desc);

-- Read-only for signed-in users; the service role (which bypasses RLS) writes.
alter table public.card_sync_runs enable row level security;
revoke all on public.card_sync_runs from anon, authenticated;
grant select on public.card_sync_runs to authenticated;
create policy "card_sync_runs: read" on public.card_sync_runs for select to authenticated using (true);

-- Each argument is a JSON array of rows shaped like the table (missing keys become null). Returns the rows written.
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
    legalities, card_faces
  )
  select r.id, r.name, coalesce(r.layout, 'normal'), r.mana_cost, coalesce(r.cmc, 0), r.type_line, r.rules_text,
         r.power, r.toughness, r.loyalty, r.colors, coalesce(r.color_identity, '{}'), coalesce(r.legalities, '{}'),
         r.card_faces
  from jsonb_populate_recordset(null::public.cards, card_rows) r
  on conflict (id) do update set
    name = excluded.name, layout = excluded.layout, mana_cost = excluded.mana_cost, cmc = excluded.cmc,
    type_line = excluded.type_line, rules_text = excluded.rules_text, power = excluded.power,
    toughness = excluded.toughness, loyalty = excluded.loyalty, colors = excluded.colors,
    color_identity = excluded.color_identity, legalities = excluded.legalities, card_faces = excluded.card_faces,
    updated_at = now()
  where (c.name, c.layout, c.mana_cost, c.cmc, c.type_line, c.rules_text, c.power, c.toughness, c.loyalty, c.colors,
         c.color_identity, c.legalities, c.card_faces)
        is distinct from
        (excluded.name, excluded.layout, excluded.mana_cost, excluded.cmc, excluded.type_line, excluded.rules_text,
         excluded.power, excluded.toughness, excluded.loyalty, excluded.colors, excluded.color_identity,
         excluded.legalities, excluded.card_faces);
  get diagnostics written = row_count;
  total := total + written;

  -- card_id is never updated: collection_items reference (version_id, card_id) as a pair.
  insert into public.card_versions as v (
    id, card_id, set, collector_number, rarity, artist, image_uris, card_faces, finishes
  )
  select r.id, r.card_id, r.set, r.collector_number, coalesce(r.rarity, 'common'), r.artist, r.image_uris,
         r.card_faces, coalesce(r.finishes, '{nonfoil}')
  from jsonb_populate_recordset(null::public.card_versions, version_rows) r
  on conflict (id) do update set
    set = excluded.set, collector_number = excluded.collector_number, rarity = excluded.rarity,
    artist = excluded.artist, image_uris = excluded.image_uris, card_faces = excluded.card_faces,
    finishes = excluded.finishes, updated_at = now()
  where (v.set, v.collector_number, v.rarity, v.artist, v.image_uris, v.card_faces, v.finishes)
        is distinct from
        (excluded.set, excluded.collector_number, excluded.rarity, excluded.artist, excluded.image_uris,
         excluded.card_faces, excluded.finishes);
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

revoke execute on function public.sync_card_batch(jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.sync_card_batch(jsonb, jsonb, jsonb) to service_role;
