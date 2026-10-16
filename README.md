# Spellbinder DB

Supabase backend (Postgres, Auth, Row Level Security, Edge Functions) for Spellbinder. It is shared by the mobile
app (`spellbinder-app`) and the website.

## Setup

1. `npm install` installs the Supabase CLI locally; run it with `npx supabase`.
2. **Container runtime:** the local stack runs on Docker or Podman. With Podman on Windows:
   ```
   podman machine set --rootful
   podman machine start
   ```
   Podman serves the Docker API on `npipe:////./pipe/docker_engine`, so no `DOCKER_HOST` is needed.
   `[analytics]` is disabled in `config.toml` because its log collector needs a Docker socket mount.
3. `npm run db:start` starts the local stack, applies the migrations and seeds it.
   - API: `http://127.0.0.1:54321`
   - Studio: `http://127.0.0.1:54323`
   - `npx supabase status` prints the local keys.
4. To work with the remote project:
   ```
   npx supabase login
   npx supabase link --project-ref fobbpfvhnelpforjqugd
   ```

## Making a schema change

1. Add `supabase/migrations/<NNNN>_<description>.sql`. Use the `supabase-migration` skill.
2. Run `npm run db:reset`, `npm run test:db` and `npm run db:lint`.
3. Run `npx supabase db push --dry-run`, then `npm run db:push`.
4. In each client, regenerate the types: `npm run types --silent > ../spellbinder-app/src/types/database.ts`.
   Then update that client's queries.

## Auth

Sign-in is email + password with email confirmation turned off, so signing up sends no email. The only emails are the
password-reset code (`supabase/templates/recovery.html`) and the "password changed" notice. The settings live in
`[auth]` / `[auth.email]` in `config.toml`; apply them to the remote project with `npx supabase config push`
(it shows a diff and asks per service).

- **SMTP** (Gmail with an app password) is set only in the dashboard: Authentication → Emails → SMTP Settings. It is
  deliberately not declared in `config.toml`, so `config push` never touches it.
- On the free tier, Supabase rejects custom email templates until custom SMTP is configured. If the push fails with
  "Email template modification is not available", set up SMTP first.
- Emails per hour (`auth.rate_limit.email_sent`) can't be pushed. Set it in the dashboard under Authentication → Rate Limits.
- Locally, every email goes to the test mailbox at `http://127.0.0.1:54324`.

Local seed users: `you`, `jonas`, `mira`, `erik` and `sanna` `@spellbinder.test`, all with password `spellbinder-dev`.

## Clients

The apps only need the project URL and the **publishable** key (Dashboard → Project Settings → API Keys). In the
Expo app, these go in `EXPO_PUBLIC_SUPABASE_URL` / `EXPO_PUBLIC_SUPABASE_ANON_KEY` with
`EXPO_PUBLIC_DATA_MODE=supabase`. Never give a client a secret or service-role key.

## Game nights

Any member plans, changes and cancels a group's game nights (migration `0010`). A night has a title, a time, an
optional place and notes, and a bracket range (`bracket_min` / `bracket_max`, both null = Any). Repeating nights
belong to a `game_night_series` (weekly or monthly, every 1 or 2; monthly by weekday or by date), and each repeat is
its own row with its own RSVPs. Repeat dates are computed in the series' IANA time zone, so 19:00 stays 19:00 across
daylight saving. The clients use four RPCs (security invoker, so RLS applies):

| RPC | Does |
|---|---|
| `plan_game_night(group_id, title, starts_at, location, notes, bracket_min, bracket_max, repeat)` | A one-off (`repeat` null) or a series (`{frequency, repeat_every, monthly_by, time_zone}`) and its nights. Returns the first night. |
| `top_up_game_nights(group_id)` | Creates the missing upcoming nights of every running series up to **two months** ahead (nights that have passed are skipped). Idempotent; a night someone deleted is not made again. The app calls it for each group it loads, before reading nights. |
| `change_game_nights(night_id, scope, patch)` | `this` changes one night; `later` changes it and every later night of its series (the repeat rule too) by starting a new series there. A `repeat` in the patch keeps the old rule's values for keys it leaves out, so send the whole rule. |
| `cancel_game_nights(night_id, scope)` | Soft cancel (`cancelled_at` / `cancelled_by`): `this` night, or `later` ones too, which ends the series. |

Moving a night (a new `starts_at`) deletes its RSVPs so people answer again; a new place, title or bracket keeps
them. `updated_by` records who changed a night last. Callers outside the group get `Not a member of this playgroup`
or `Game night not found`. The comments in `supabase/migrations/0010_game_night_series.sql` give the details.

## Oracle Edge Function

`supabase/functions/oracle` is a stub. To deploy it:
```
npx supabase secrets set ANTHROPIC_API_KEY=...
npx supabase functions deploy oracle
```

## Card sync

`scripts/sync-cards.ts` loads Scryfall's `default_cards` bulk file (every paper printing, ~110k rows) into `cards`,
`card_versions` and `card_prices`, snapshots the prices of owned versions into `card_price_history`, and logs the
run in `card_sync_runs`. It skips a file it has already loaded, only rewrites cards and versions that changed, and
never deletes anything. Node 24, no dependencies.

**Schedule:** `.github/workflows/sync-cards.yml` runs it daily at 10:30 UTC (Scryfall publishes around 09:00 UTC).
Run it by hand from the Actions tab (*Sync cards → Run workflow*; tick *force* to reload the same file). It needs two
repository secrets under Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `SUPABASE_URL` | `https://fobbpfvhnelpforjqugd.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Dashboard → Project Settings → API Keys → a **secret** key (`sb_secret_…`) |

The key bypasses RLS: it lives only in Actions secrets, never in a client or in this repo. GitHub turns scheduled
workflows off after 60 days without a commit to the repo; if the app's "Card data updated" gets old, re-enable it in
the Actions tab.

**Locally**, against `npm run db:start`: put the values from `npx supabase status` in `.env` (git-ignored):
```
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_SERVICE_ROLE_KEY=<SECRET_KEY from supabase status>
```
then `npm run sync:cards` (`SYNC_FORCE=true` reloads the same file). A full load takes about 20 s locally and
~115 MB of database space; a day with no new file exits in a second.
