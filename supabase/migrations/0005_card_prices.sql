-- Card prices from external sources: the current price of every version, and a daily history for versions someone
-- owns.
--
--   card_prices         one row per version and source, overwritten by each sync.
--   card_price_history  one row per version, source and day, for owned versions only (so it stays small).
--
-- Only the service role writes prices. The daily sync (GitHub Actions, roadmap CC-2/CC-3) upserts card_prices, then
-- calls snapshot_card_prices() and compact_card_price_history(). Columns mirror Scryfall's `prices` object: usd is
-- TCGplayer, eur is Cardmarket, tix is Cardhoarder.
--
-- Backward compatible: new types, tables, functions and a view.

create type public.price_source as enum ('scryfall'); -- add sources with `alter type … add value`

create table public.card_prices (
  version_id  uuid not null references public.card_versions (id) on delete cascade,
  source      public.price_source not null default 'scryfall',
  usd         numeric(10, 2),
  usd_foil    numeric(10, 2),
  usd_etched  numeric(10, 2),
  eur         numeric(10, 2),
  eur_foil    numeric(10, 2),
  eur_etched  numeric(10, 2),
  tix         numeric(10, 2),
  updated_at  timestamptz not null default now(),
  primary key (version_id, source)
);

create table public.card_price_history (
  version_id   uuid not null references public.card_versions (id) on delete cascade,
  source       public.price_source not null,
  captured_on  date not null,
  usd          numeric(10, 2),
  usd_foil     numeric(10, 2),
  usd_etched   numeric(10, 2),
  eur          numeric(10, 2),
  eur_foil     numeric(10, 2),
  eur_etched   numeric(10, 2),
  tix          numeric(10, 2),
  primary key (version_id, source, captured_on)
);

-- Read-only for signed-in users; the service role (which bypasses RLS) writes.
alter table public.card_prices enable row level security;
alter table public.card_price_history enable row level security;
revoke all on public.card_prices, public.card_price_history from anon, authenticated;
grant select on public.card_prices, public.card_price_history to authenticated;
create policy "card_prices: read" on public.card_prices for select to authenticated using (true);
create policy "card_price_history: read" on public.card_price_history for select to authenticated using (true);

-- Copy today's prices of owned versions into the history. The day is the day the price was fetched, so a late or
-- repeated run never mislabels a day; running it twice changes nothing. Returns the rows written.
create or replace function public.snapshot_card_prices()
returns integer
language sql security invoker set search_path = ''
as $$
  with written as (
    insert into public.card_price_history
      (version_id, source, captured_on, usd, usd_foil, usd_etched, eur, eur_foil, eur_etched, tix)
    select p.version_id, p.source, (p.updated_at at time zone 'utc')::date,
           p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil, p.eur_etched, p.tix
    from public.card_prices p
    where exists (select 1 from public.collection_items c where c.version_id = p.version_id)
      and coalesce(p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil, p.eur_etched, p.tix) is not null
    on conflict (version_id, source, captured_on) do update set
      usd = excluded.usd, usd_foil = excluded.usd_foil, usd_etched = excluded.usd_etched,
      eur = excluded.eur, eur_foil = excluded.eur_foil, eur_etched = excluded.eur_etched, tix = excluded.tix
    returning 1
  )
  select count(*)::integer from written;
$$;

-- Keep daily rows for `keep_daily_days`, then one per week (Mondays). Returns the rows deleted.
create or replace function public.compact_card_price_history(keep_daily_days integer default 90)
returns integer
language sql security invoker set search_path = ''
as $$
  with deleted as (
    delete from public.card_price_history
    where captured_on < current_date - keep_daily_days
      and extract(isodow from captured_on) <> 1
    returning 1
  )
  select count(*)::integer from deleted;
$$;

revoke execute on function public.snapshot_card_prices(), public.compact_card_price_history(integer)
  from public, anon, authenticated;
grant execute on function public.snapshot_card_prices(), public.compact_card_price_history(integer) to service_role;

-- What each collection stack is worth, priced by its finish. Security invoker, so collection_items' RLS applies.
create view public.collection_item_prices
with (security_invoker = true)
as
select
  c.id,
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
