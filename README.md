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

## Oracle Edge Function

`supabase/functions/oracle` is a stub. To deploy it:
```
npx supabase secrets set ANTHROPIC_API_KEY=...
npx supabase functions deploy oracle
```
