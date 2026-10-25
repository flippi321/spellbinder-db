// Development helper: puts the app's `.env` test user back into a known state.
//
//   npm run seed:test-user            (asks before it changes anything; `-- --yes` skips the question)
//
// Reads EXPO_PUBLIC_SUPABASE_URL, EXPO_PUBLIC_SUPABASE_ANON_KEY, EXPO_PUBLIC_TEST_USER_EMAIL and
// EXPO_PUBLIC_TEST_USER_PASSWORD from ../spellbinder-app/.env, so it seeds whichever project the app points at.
// It signs in as the test user (signing up the first time, like the app) and works through RLS as that user: no
// secret key. Runs on Node 24+ with no dependencies (Node strips the types).
//
// 1. Parses the decklists in seed-test-user/ (TappedOut, pasted as is) and the extras list.
// 2. Finds every card and a printing for each finish, before changing anything, so a bad name changes nothing.
// 3. Deletes the user's decks and collection. Playgroups, loans and game nights are shared, so they stay.
// 4. Creates the decks and a collection of COLLECTION_SIZE cards: every deck card, plus extras up to the total.

import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';

import { parseDecklist, type Decklist, type Finish } from './seed-test-user/decklist.ts';

const COLLECTION_SIZE = 300;
const DECKS = [
  { file: 'jace.txt', name: "Jace's Universe", theme: 'Superfriends', bracket: 4 },
  { file: 'ur-dragon.txt', name: 'The Budget-Friendly Ur-Dragon', theme: 'Dragons', bracket: 2 },
];
// Cards per `in.(…)` filter, to keep URLs short.
const NAME_BATCH = 40;
// Parallel requests while picking printings.
const CONCURRENCY = 8;
const DISPLAY_NAME_MAX_LENGTH = 40; // spellbinder-app/src/utils/auth.ts

const SUPABASE_URL = requireEnv('EXPO_PUBLIC_SUPABASE_URL').replace(/\/$/, '');
const ANON_KEY = requireEnv('EXPO_PUBLIC_SUPABASE_ANON_KEY');
const EMAIL = requireEnv('EXPO_PUBLIC_TEST_USER_EMAIL').trim();
const PASSWORD = requireEnv('EXPO_PUBLIC_TEST_USER_PASSWORD');

type Json = Record<string, any>;

interface CardRow {
  id: string;
  name: string;
  layout: string;
  type_line: string;
  card_faces: { type_line?: string }[] | null;
}

interface Pick {
  versionId: string;
  finish: Finish;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing ${name} (set it in spellbinder-app/.env).`);
    process.exit(1);
  }
  return value;
}

const readData = (file: string) => readFileSync(new URL(`./seed-test-user/${file}`, import.meta.url), 'utf8');

async function request<T>(url: string, init: { method?: string; body?: unknown; token?: string; prefer?: string }) {
  const res = await fetch(url, {
    method: init.method ?? 'GET',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${init.token ?? ANON_KEY}`,
      'Content-Type': 'application/json',
      ...(init.prefer ? { Prefer: init.prefer } : {}),
    },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const error = new Error(`${init.method ?? 'GET'} ${url.split('?')[0]}: ${res.status} ${text}`);
    Object.assign(error, { code: json?.error_code ?? json?.code });
    throw error;
  }
  return json as T;
}

/** Signs in as the test user, or signs up when the account doesn't exist yet. */
async function signIn(): Promise<{ token: string; userId: string }> {
  const auth = (path: string, body: Json) => request<Json>(`${SUPABASE_URL}/auth/v1/${path}`, { method: 'POST', body });
  let session: Json;
  try {
    session = await auth('token?grant_type=password', { email: EMAIL, password: PASSWORD });
  } catch (error) {
    // Supabase answers an unknown email and a wrong password alike, so try creating the account.
    if ((error as { code?: string }).code !== 'invalid_credentials') throw error;
    const displayName = EMAIL.split('@')[0].slice(0, DISPLAY_NAME_MAX_LENGTH);
    try {
      session = await auth('signup', { email: EMAIL, password: PASSWORD, data: { display_name: displayName } });
    } catch (signUpError) {
      const code = (signUpError as { code?: string }).code ?? '';
      if (['user_already_exists', 'email_exists'].includes(code)) {
        throw new Error(`${EMAIL} exists, but EXPO_PUBLIC_TEST_USER_PASSWORD is not its password.`);
      }
      throw signUpError;
    }
    console.log(`Created the account ${EMAIL}.`);
  }
  if (!session.access_token) throw new Error('Signed up, but got no session: are email confirmations on?');
  return { token: session.access_token, userId: session.user.id };
}

/** A PostgREST `in.(…)` list, quoted so commas and apostrophes in names survive. */
const inList = (values: string[]) =>
  encodeURIComponent(`(${values.map((v) => `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`).join(',')})`);

/** Exact names first, in batches; then `find_card` for the rest (a double-faced card by its front face). */
async function findCards(names: string[], token: string): Promise<Map<string, CardRow>> {
  const found = new Map<string, CardRow>();
  const isPlayable = (card: CardRow) => !/token|emblem/.test(card.layout);
  for (let i = 0; i < names.length; i += NAME_BATCH) {
    const batch = names.slice(i, i + NAME_BATCH);
    const rows = await request<CardRow[]>(
      `${SUPABASE_URL}/rest/v1/cards?select=id,name,layout,type_line,card_faces&name=in.${inList(batch)}`,
      { token },
    );
    for (const row of rows.filter(isPlayable)) found.set(row.name.toLowerCase(), row);
  }
  const result = new Map<string, CardRow>();
  const missing: string[] = [];
  for (const name of names) {
    let card = found.get(name.toLowerCase());
    if (!card) {
      [card] = await request<CardRow[]>(`${SUPABASE_URL}/rest/v1/rpc/find_card`, {
        method: 'POST',
        body: { name },
        token,
      });
      if (card) console.log(`  "${name}" → ${card.name}`);
    }
    if (card) result.set(name, card);
    else missing.push(name);
  }
  if (missing.length > 0) throw new Error(`No card named: ${missing.join('; ')}. Nothing was changed.`);
  return result;
}

/** The newest English paper printing in that finish, not a promo; nonfoil when no printing has it. */
async function pickVersion(card: CardRow, finish: Finish, token: string): Promise<Pick> {
  const tryFinish = async (wanted: Finish) => {
    const rows = await request<Json[]>(
      `${SUPABASE_URL}/rest/v1/card_versions?select=*&card_id=eq.${card.id}&digital=is.false&lang=eq.en` +
        `&finishes=cs.%7B${wanted}%7D&order=released_at.desc.nullslast&limit=20`,
      { token },
    );
    return rows.find((v) => !v.promo && !v.flavor_name) ?? rows[0];
  };
  const version = await tryFinish(finish);
  if (version) return { versionId: version.id, finish };
  if (finish !== 'nonfoil') {
    const nonfoil = await tryFinish('nonfoil');
    if (nonfoil) {
      console.warn(`  ${card.name}: no English ${finish} printing, using nonfoil.`);
      return { versionId: nonfoil.id, finish: 'nonfoil' };
    }
  }
  throw new Error(`${card.name}: no English paper printing. Nothing was changed.`);
}

/** Runs `work` over `items`, a few at a time. */
async function pool<T, R>(items: T[], work: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await work(items[i]);
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  return results;
}

/** The deck category the app gives a new card: `defaultCategoryFor` in spellbinder-app/src/utils/category.ts. */
function categoryOf(card: CardRow): string {
  const typeLine = card.card_faces?.[0]?.type_line ?? card.type_line;
  if (typeLine.includes('Land')) return 'Lands';
  if (typeLine.includes('Creature')) return 'Creatures';
  if (typeLine.includes('Planeswalker')) return 'Planeswalkers';
  return 'Other';
}

async function confirm(question: string): Promise<boolean> {
  if (process.argv.includes('--yes')) return true;
  if (!process.stdin.isTTY) {
    console.error('Not a terminal: pass --yes to run without the question.');
    return false;
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const answer = await rl.question(`${question} [y/N] `);
  rl.close();
  return /^y(es)?$/i.test(answer.trim());
}

async function main() {
  const decks = DECKS.map((deck) => ({ ...deck, list: parseDecklist(readData(deck.file)) }));
  const deckLines = (list: Decklist) => [{ ...list.commander, quantity: 1 }, ...list.cards];
  const inDecks = decks.flatMap((deck) => deckLines(deck.list));
  const deckTotal = inDecks.reduce((sum, line) => sum + line.quantity, 0);
  const deckNames = new Set(inDecks.map((line) => line.name.toLowerCase()));
  const extras = readData('extras.txt')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#') && !deckNames.has(line.toLowerCase()))
    .slice(0, COLLECTION_SIZE - deckTotal)
    .map((name) => ({ name, quantity: 1, finish: 'nonfoil' as Finish }));
  if (deckTotal + extras.length !== COLLECTION_SIZE) {
    throw new Error(`The decks hold ${deckTotal} cards and extras.txt has ${extras.length} more: add extras.`);
  }

  const host = new URL(SUPABASE_URL).host;
  console.log(`Project: ${host}\nUser:    ${EMAIL}`);
  console.log(`Plan:    delete their decks and collection, then add ${decks.length} decks (${deckTotal} cards) and a`);
  console.log(`         collection of ${COLLECTION_SIZE} (${extras.length} outside the decks).`);
  if (!(await confirm(`Reseed ${EMAIL} on ${host}?`))) return console.log('Nothing changed.');

  const { token, userId } = await signIn();
  const rest = (path: string, init: { method?: string; body?: unknown; prefer?: string } = {}) =>
    request<Json[]>(`${SUPABASE_URL}/rest/v1/${path}`, { ...init, token });

  console.log('Finding cards…');
  const lines = [...inDecks, ...extras];
  const cards = await findCards([...new Set(lines.map((line) => line.name))], token);
  console.log('Picking printings…');
  const wanted = [...new Map(lines.map((line) => [`${line.name}|${line.finish}`, line])).values()];
  const picks = new Map(
    await pool(wanted, async (line) => [
      `${line.name}|${line.finish}`,
      await pickVersion(cards.get(line.name)!, line.finish, token),
    ] as const),
  );

  console.log('Clearing the old decks and collection…');
  const oldDecks = await rest(`decks?owner_id=eq.${userId}&select=id`, { method: 'DELETE', prefer: 'return=representation' });
  const oldItems = await rest(`collection_items?user_id=eq.${userId}&select=version_id`, {
    method: 'DELETE',
    prefer: 'return=representation',
  });
  console.log(`  removed ${oldDecks.length} decks and ${oldItems.length} collection rows`);

  for (const deck of decks) {
    const commander = cards.get(deck.list.commander.name)!;
    const [row] = await rest('decks?select=id', {
      method: 'POST',
      prefer: 'return=representation',
      body: { owner_id: userId, name: deck.name, commander_card_id: commander.id, theme: deck.theme, bracket: deck.bracket },
    });
    // One row per card: a card in two finishes is one deck entry.
    const deckCards = new Map<string, Json>([
      [commander.id, { deck_id: row.id, card_id: commander.id, quantity: 1, category: 'Commander', is_commander: true }],
    ]);
    for (const line of deck.list.cards) {
      const card = cards.get(line.name)!;
      const entry = deckCards.get(card.id);
      if (entry) entry.quantity += line.quantity;
      else {
        // A bulk insert needs the same keys in every row.
        deckCards.set(card.id, {
          deck_id: row.id,
          card_id: card.id,
          quantity: line.quantity,
          category: categoryOf(card),
          is_commander: false,
        });
      }
    }
    await rest('deck_cards', { method: 'POST', body: [...deckCards.values()] });
    console.log(`  ${deck.name}: ${[...deckCards.values()].reduce((sum, c) => sum + c.quantity, 0)} cards`);
  }

  // One row per printing and finish (the table's unique key, with condition).
  const items = new Map<string, Json>();
  for (const line of lines) {
    const pick = picks.get(`${line.name}|${line.finish}`)!;
    const key = `${pick.versionId}|${pick.finish}`;
    const item = items.get(key);
    if (item) item.quantity += line.quantity;
    else {
      items.set(key, {
        user_id: userId,
        version_id: pick.versionId,
        card_id: cards.get(line.name)!.id,
        quantity: line.quantity,
        finish: pick.finish,
        condition: 'NM',
      });
    }
  }
  await rest('collection_items', { method: 'POST', body: [...items.values()] });
  const owned = [...items.values()].reduce((sum, item) => sum + item.quantity, 0);
  console.log(`Done: ${EMAIL} (${userId}) owns ${owned} cards in ${items.size} rows, ${deckTotal} of them in decks.`);
}

main().catch((error) => {
  console.error((error as Error).message);
  process.exit(1);
});
