-- A collection row is all your copies of one version in one finish: the key becomes (user_id, version_id, finish) and
-- the surrogate `id` goes. `quantity` counts the copies; `condition` is one value per row.
--
-- Why (TODO D-5): a copy is spare when you own more of the card than your decks use, so the app adds up `quantity` per
-- card and subtracts the deck slots. One row per version and finish keeps that sum simple.
--
-- BREAKING, in one step (an exception to the two-step rule in CLAUDE.md): the live table has no rows, the app's
-- Supabase layer changes in the same change, and the website doesn't exist. Rows that differ only in condition would
-- collide under the new key, so the migration stops if the table has any rows instead of merging them silently.

do $$
begin
  if exists (select 1 from public.collection_items) then
    raise exception 'collection_items has rows: merge them per (user_id, version_id, finish) before migration 0007';
  end if;
end;
$$;

-- The view names `id`, and `create or replace` can't drop a column.
drop view public.collection_item_prices;

alter table public.collection_items
  drop constraint collection_items_pkey,
  drop constraint collection_items_user_version_finish_condition_key,
  drop column id,
  add primary key (user_id, version_id, finish);
drop index public.collection_items_user_idx; -- the primary key leads with user_id

-- What each collection row is worth, priced by its finish. Security invoker, so collection_items' RLS applies.
create view public.collection_item_prices
with (security_invoker = true)
as
select
  c.user_id,
  c.version_id,
  c.card_id,
  c.finish,
  c.condition,
  c.quantity,
  case c.finish when 'foil' then p.eur_foil when 'etched' then p.eur_etched else p.eur end as unit_eur,
  case c.finish when 'foil' then p.usd_foil when 'etched' then p.usd_etched else p.usd end as unit_usd,
  p.updated_at as prices_updated_at
from public.collection_items c
left join public.card_prices p on p.version_id = c.version_id and p.source = 'scryfall';

revoke all on public.collection_item_prices from anon, authenticated;
grant select on public.collection_item_prices to authenticated;
