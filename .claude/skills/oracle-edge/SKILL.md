---
name: oracle-edge
description: Build or change the real Spellbinder Oracle — the Supabase Edge Function `oracle` that builds deck/collection context server-side and calls the Claude API, returning an OracleAnswer. Use for any work on supabase/functions/oracle, the Oracle prompt or answer schema, OracleContext, or switching EXPO_PUBLIC_ORACLE_MODE to edge.
argument-hint: <oracle change>
---

# The Oracle (Edge Function + Claude)

Implement `$ARGUMENTS`. **Before writing any Claude API code, load the `claude-api` skill** for current model ids,
SDK usage, tool use / structured output and prompt caching. Don't write model names or SDK calls from memory.

## Architecture (fixed)
```
app → useOracleStore.ask() → askOracle() (../spellbinder-app/src/services/oracle.ts)
    → edgeOracle: supabase.functions.invoke('oracle', { body: { question, context } })
    → supabase/functions/oracle/index.ts (Deno) → Claude API → { answer: OracleAnswer }
```
- **The Anthropic key never reaches the client.** It lives in Supabase secrets as `ANTHROPIC_API_KEY` and is read with
  `Deno.env.get` inside the function. Nothing Oracle-related goes in `EXPO_PUBLIC_*` except `EXPO_PUBLIC_ORACLE_MODE`.
- `mockOracle` + `src/services/oracleAnswers.ts` stay as they are: they're the preview, the test fixture, and the
  fallback when `EXPO_PUBLIC_ORACLE_MODE` isn't `edge`.

## The contract — `../spellbinder-app/src/types/oracle.ts`
The function must return `{ answer: OracleAnswer }`:
- `intro` (string), optional `featured` (`name`, `colors: ManaColor[]`, `typeLine`, `stats?`, `note`),
- `sections[]` (`title`, `paragraphs[]`, optional `chips[]` of `{ name, note, tone: 'neutral' | 'friend' }`),
- optional `action`: `applySwaps` (deckName, remove[], add[{name, category}]) · `createDeck` (commanderName) ·
  `requestLoan` (cardName, ownerName). The UI only knows these three — add a kind on the client before the model can emit it.

Get JSON from Claude with a forced tool call (or structured outputs, per the `claude-api` skill) whose input schema
mirrors `OracleAnswer`, then **validate it on the server** before returning it. Bad output → a friendly fallback answer,
never a 500 with the model's raw text.

## Edge Function checklist — `supabase/functions/oracle/index.ts`
1. CORS preflight (`OPTIONS`) for the future website; POST only.
2. **Auth:** require the `Authorization: Bearer <jwt>` header; create the Supabase client with the anon key and that
   header so **every query runs under the caller's RLS**. Take the user id from `auth.getUser()`, **not** from
   `context.userId` in the body (the client can send anything).
3. **Build the context server-side** (never trust card lists from the client):
   - the asked-about deck(s) from `context.deckIds` (filtered to decks the caller can read): commander, bracket,
     theme, cards grouped by category, joined to `cards` for name, type line, mana value and oracle text;
   - the caller's collection: owned oracle ids with quantities, and which are spare (in no deck);
   - playgroup members' cards that matter (friend-owned cards that fit the deck's color identity), with owner names.
   - Keep it compact: names + short fields, no image URIs. Put stable instructions in a cached system prompt.
4. **Prompt rules for the model:** Commander format and Brackets; only recommend real cards; prefer cards the user owns,
   then friend-owned ("Jonas has one", tone `friend`), then missing; respect the deck's color identity and bracket;
   the tone is the Oracle (warm, concise, no emoji).
5. **Validate chips:** every chip / featured name should exist in the `cards` cache or Scryfall
   (`/cards/collection`, rate-limited). Drop or fix the unknown ones.
6. Limits: cap question length, per-user rate limit (a small table or KV), model `max_tokens`, request timeout.
   Log errors without logging the user's whole collection.
7. Return `{ answer }` with status 200; auth failures 401; validation failures 400.

The function lives in this repo (`spellbinder-db`); the client code is in `../spellbinder-app`. Functions are Deno: use `npm:` / `jsr:` imports, and test it with
`npx supabase functions serve oracle --env-file supabase/.env.local` (gitignored) if the user has the CLI.

## Client side
- `../spellbinder-app/src/services/oracle.ts` → `edgeOracle` already calls the function; extend `OracleContext` only with ids, never data.
- `useOracleStore` turns thrown errors into an in-chat answer — keep that behavior.
- When `oracleMode === 'edge'`, the "Test data · preview" header copy and the free-text fallback should go away;
  the suggestion chips stay.
- Actions (`applySwaps`, `createDeck`, `requestLoan`) run through the normal stores/repos, after a confirmation step.

## Safety
- **Ask before** `supabase secrets set`, `supabase functions deploy`, or anything else that touches a remote project.
  Never write the key to a committed file, a log, or the chat.
- Don't send other members' data beyond what RLS already lets the caller read.

## Done when
- [ ] Key only in Supabase secrets; JWT checked; user id taken from the JWT; RLS-scoped queries.
- [ ] Output validated against `OracleAnswer`; unknown cards handled; fallback answer on failure.
- [ ] Mock mode unchanged and still the default; client tests pass with the mock.
- [ ] The `preflight` skill passes.
