// Daily card sync (roadmap CC-2): Scryfall's `default_cards` bulk file → cards, card_versions and card_prices.
//
//   SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… node scripts/sync-cards.ts
//
// Runs on Node 24+ with no dependencies (Node strips the types). Scheduled by .github/workflows/sync-cards.yml.
// The key is the project's service-role or secret key: it bypasses RLS, so it only ever lives in Actions secrets.
//
// 1. Skips the run if the latest `ok` run already loaded this bulk file (SYNC_FORCE=true loads it anyway).
// 2. Streams the gzipped JSONL file (~80 MB compressed, ~110k paper printings) line by line.
// 3. Maps each printing the way the app does (slimCard + fromCard in spellbinder-app) and sends batches to the
//    `sync_card_batch` RPC, which only rewrites rows that changed. Nothing is ever deleted.
// 4. Snapshots the prices of owned versions into the history, compacts it, and logs the run in `card_sync_runs`.

import { createInterface } from 'node:readline';
import { Readable } from 'node:stream';
import { createGunzip } from 'node:zlib';

const BULK_TYPE = 'default_cards';
const SCRYFALL_API = 'https://api.scryfall.com';
// Scryfall asks every client to identify itself.
const USER_AGENT = 'Spellbinder/0.1 (+https://github.com/flippi321/spellbinder-db)';
const BATCH_SIZE = Number(process.env.SYNC_BATCH_SIZE ?? 1000);
const FORCE = process.env.SYNC_FORCE === 'true';
const FINISHES = ['nonfoil', 'foil', 'etched'];
// Not cards you can own or play: art cards from Art Series sets, and objects that only exist online.
const SKIPPED_LAYOUTS = ['art_series'];

const SUPABASE_URL = requireEnv('SUPABASE_URL').replace(/\/$/, '');
const SUPABASE_KEY = requireEnv('SUPABASE_SERVICE_ROLE_KEY');

type Json = Record<string, any>;

interface BulkFile {
  updated_at: string;
  jsonl_download_uri: string;
  compressed_size?: number;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing ${name}.`);
    process.exit(1);
  }
  return value;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Retries network and 5xx errors with backoff (1 s, 4 s); 4xx errors fail at once. */
async function withRetry<T>(what: string, attempt: () => Promise<T>): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await attempt();
    } catch (error) {
      if (i >= 3 || (error as { retry?: boolean }).retry === false) throw error;
      console.warn(`${what} failed (attempt ${i}): ${(error as Error).message}. Retrying.`);
      await sleep(1000 * 4 ** (i - 1));
    }
  }
}

/** A PostgREST request with the service-role key. */
async function rest<T>(path: string, init: { method?: string; body?: unknown; prefer?: string } = {}): Promise<T> {
  return withRetry(`${init.method ?? 'GET'} ${path.split('?')[0]}`, async () => {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
      method: init.method ?? 'GET',
      headers: {
        apikey: SUPABASE_KEY,
        Authorization: `Bearer ${SUPABASE_KEY}`,
        'Content-Type': 'application/json',
        ...(init.prefer ? { Prefer: init.prefer } : {}),
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
    if (!res.ok) {
      const error = new Error(`${res.status} ${await res.text()}`);
      Object.assign(error, { retry: res.status >= 500 });
      throw error;
    }
    const text = await res.text();
    return (text ? JSON.parse(text) : null) as T;
  });
}

async function getBulkFile(): Promise<BulkFile> {
  const res = await fetch(`${SCRYFALL_API}/bulk-data/${BULK_TYPE.replace('_', '-')}`, {
    headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' },
  });
  if (!res.ok) throw new Error(`Scryfall /bulk-data: ${res.status} ${await res.text()}`);
  const file = (await res.json()) as BulkFile;
  if (!file.jsonl_download_uri) throw new Error('Scryfall /bulk-data has no jsonl_download_uri: the format changed.');
  return file;
}

async function lastLoadedFile(): Promise<string | null> {
  const rows = await rest<{ bulk_updated_at: string }[]>(
    `card_sync_runs?select=bulk_updated_at&bulk_type=eq.${BULK_TYPE}&status=eq.ok&order=finished_at.desc&limit=1`,
  );
  return rows[0]?.bulk_updated_at ?? null;
}

// ── Mapping (keep in step with slimCard in spellbinder-app/src/utils/cards.ts and fromCard in
//    spellbinder-app/src/data/supabase/mappers.ts) ─────────────────────────────────────────

const slimImages = (uris: Json | undefined) =>
  uris ? { small: uris.small, normal: uris.normal, large: uris.large, art_crop: uris.art_crop } : null;

/** Splits a Scryfall printing into its `cards`, `card_versions` and `card_prices` rows. */
function toRows(c: Json) {
  const faces: Json[] | undefined = c.card_faces;
  // Reversible cards only carry the oracle id on their faces (getCardId in the app).
  const cardId: string = c.oracle_id ?? faces?.[0]?.oracle_id ?? c.id;
  const finishes = (c.finishes ?? []).filter((f: string) => FINISHES.includes(f));
  const prices: Json = c.prices ?? {};
  // Both faces of a reversible card are the same card as its plain printings (same oracle id), so its rules come
  // from one face. Otherwise the shared `cards` row would read "Norin the Wary // Norin the Wary".
  const rules: Json =
    c.layout === 'reversible_card' && faces?.[0] ? { ...c, ...faces[0], layout: 'normal', card_faces: undefined } : c;
  const ruleFaces: Json[] | undefined = rules.card_faces;
  return {
    card: {
      id: cardId,
      name: rules.name,
      layout: rules.layout,
      mana_cost: rules.mana_cost ?? null,
      cmc: rules.cmc ?? 0,
      type_line: rules.type_line ?? '',
      rules_text: rules.oracle_text ?? null,
      power: rules.power ?? null,
      toughness: rules.toughness ?? null,
      loyalty: rules.loyalty ?? null,
      colors: rules.colors ?? null,
      color_identity: rules.color_identity ?? [],
      legalities: { commander: rules.legalities?.commander },
      card_faces:
        ruleFaces?.map((f) => ({
          name: f.name,
          mana_cost: f.mana_cost,
          type_line: f.type_line,
          rules_text: f.oracle_text,
          colors: f.colors,
          power: f.power,
          toughness: f.toughness,
          loyalty: f.loyalty,
        })) ?? null,
    },
    version: {
      id: c.id,
      card_id: cardId,
      set: c.set,
      collector_number: c.collector_number,
      rarity: c.rarity,
      artist: c.artist ?? null,
      image_uris: slimImages(c.image_uris),
      card_faces: faces?.map((f) => ({ image_uris: slimImages(f.image_uris) ?? undefined, artist: f.artist })) ?? null,
      finishes: finishes.length > 0 ? finishes : ['nonfoil'],
    },
    price: {
      version_id: c.id,
      source: 'scryfall',
      usd: prices.usd ?? null,
      usd_foil: prices.usd_foil ?? null,
      usd_etched: prices.usd_etched ?? null,
      eur: prices.eur ?? null,
      eur_foil: prices.eur_foil ?? null,
      eur_etched: prices.eur_etched ?? null,
      tix: prices.tix ?? null,
    },
  };
}

// ── The run ──────────────────────────────────────────────────────────────────────────────

async function load(file: BulkFile): Promise<{ read: number; upserted: number }> {
  const res = await fetch(file.jsonl_download_uri, { headers: { 'User-Agent': USER_AGENT } });
  if (!res.ok || !res.body) throw new Error(`Bulk download: ${res.status}`);
  const lines = createInterface({
    input: Readable.fromWeb(res.body as any).pipe(createGunzip()),
    crlfDelay: Infinity,
  });

  const sentCards = new Set<string>(); // a card is sent with the first batch that has one of its versions
  let cards: Json[] = [];
  let versions: Json[] = [];
  let prices: Json[] = [];
  let read = 0;
  let upserted = 0;
  const started = Date.now();

  const flush = async () => {
    if (versions.length === 0) return;
    upserted += await rest<number>('rpc/sync_card_batch', {
      method: 'POST',
      body: { card_rows: cards, version_rows: versions, price_rows: prices },
    });
    cards = [];
    versions = [];
    prices = [];
  };

  for await (const line of lines) {
    if (!line.trim()) continue;
    const scryfall = JSON.parse(line);
    if (scryfall.digital || SKIPPED_LAYOUTS.includes(scryfall.layout)) continue;
    const { card, version, price } = toRows(scryfall);
    if (!sentCards.has(card.id)) {
      sentCards.add(card.id);
      cards.push(card);
    }
    versions.push(version);
    prices.push(price);
    read++;
    if (versions.length >= BATCH_SIZE) {
      await flush();
      if (read % (BATCH_SIZE * 10) === 0) {
        const seconds = (Date.now() - started) / 1000;
        console.log(`${read} versions, ${upserted} rows written, ${Math.round(read / seconds)} versions/s`);
      }
    }
  }
  await flush();
  console.log(`Loaded ${read} versions of ${sentCards.size} cards in ${Math.round((Date.now() - started) / 1000)} s.`);
  return { read, upserted };
}

async function main() {
  const file = await getBulkFile();
  const size = file.compressed_size ? `, ${Math.round(file.compressed_size / 1e6)} MB` : '';
  console.log(`Scryfall ${BULK_TYPE}: updated ${file.updated_at}${size}`);

  const last = await lastLoadedFile();
  if (!FORCE && last && new Date(last).getTime() === new Date(file.updated_at).getTime()) {
    console.log('Already loaded this file. Nothing to do (set SYNC_FORCE=true to load it again).');
    return;
  }

  const [run] = await rest<{ id: string }[]>('card_sync_runs?select=id', {
    method: 'POST',
    body: { bulk_type: BULK_TYPE, bulk_updated_at: file.updated_at },
    prefer: 'return=representation',
  });
  const finishRun = (fields: Json) =>
    rest(`card_sync_runs?id=eq.${run.id}`, {
      method: 'PATCH',
      body: { finished_at: new Date().toISOString(), ...fields },
    });

  try {
    const { read, upserted } = await load(file);
    const snapshotted = await rest<number>('rpc/snapshot_card_prices', { method: 'POST', body: {} });
    const compacted = await rest<number>('rpc/compact_card_price_history', { method: 'POST', body: {} });
    console.log(`Price history: ${snapshotted} rows snapshotted, ${compacted} old rows compacted.`);
    await finishRun({ status: 'ok', rows_read: read, rows_upserted: upserted });
    console.log(`Done: ${upserted} rows written.`);
  } catch (error) {
    await finishRun({ status: 'failed', error: String((error as Error).message ?? error).slice(0, 2000) }).catch(
      (e) => console.error('Could not mark the run as failed:', e),
    );
    throw error;
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
