// Supabase Edge Function `oracle` (Deno) — STUB.
//
// The app never holds the Anthropic key: it calls this function with the user's Supabase JWT,
// and the key lives in Supabase secrets.
//
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//   supabase functions deploy oracle
//
// Then set EXPO_PUBLIC_ORACLE_MODE=edge in the app's .env.

import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

/** Matches OracleAnswer in src/types/oracle.ts — the app renders this shape. */
interface OracleAnswer {
  intro: string;
  featured?: { name: string; colors: string[]; typeLine: string; stats?: string; note: string };
  sections: { title: string; paragraphs: string[]; chips?: { name: string; note: string; tone: 'neutral' | 'friend' }[] }[];
}

interface OracleRequest {
  question?: unknown;
  context?: { userId?: string; deckIds?: string[] };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) return json({ error: 'The Oracle is not configured (ANTHROPIC_API_KEY is missing).' }, 500);

  // Validate the caller. The gateway also verifies JWTs unless verify_jwt is turned off,
  // but we need the user anyway — and this client queries *as them*, so RLS applies.
  const authHeader = req.headers.get('Authorization') ?? '';
  const token = authHeader.replace(/^Bearer\s+/i, '');
  if (!token) return json({ error: 'Missing bearer token' }, 401);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return json({ error: 'Invalid or expired session' }, 401);

  let body: OracleRequest;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Body must be JSON: { question, context }' }, 400);
  }
  const question = typeof body.question === 'string' ? body.question.trim() : '';
  if (!question || question.length > 2000) return json({ error: 'Ask a question (up to 2,000 characters).' }, 400);

  // TODO(context): build compact, stable-ordered context with RLS-scoped queries as this user:
  //   - decks + deck_cards (categories), joined to `cards` for names, types and mana costs
  //   - collection_items: owned card ids, quantities, spares (= copies owned minus copies the user's decks use, D-5)
  //   - playgroup peers' collection_items, so answers can say "Jonas has one"
  // Sort everything deterministically so the prompt prefix stays cacheable.

  // TODO(claude): replace the placeholder below with a structured-output call, e.g.:
  //
  //   import Anthropic from 'npm:@anthropic-ai/sdk';
  //   import { zodOutputFormat } from 'npm:@anthropic-ai/sdk/helpers/zod';
  //   import { z } from 'npm:zod';
  //
  //   const Chip = z.object({ name: z.string(), note: z.string(), tone: z.enum(['neutral', 'friend']) });
  //   const Answer = z.object({
  //     intro: z.string(),
  //     sections: z.array(z.object({ title: z.string(), paragraphs: z.array(z.string()), chips: z.array(Chip) })),
  //   });
  //
  //   const client = new Anthropic({ apiKey });
  //   const response = await client.messages.parse({
  //     model: 'claude-opus-5-5',
  //     max_tokens: 16000,
  //     // Adaptive thinking is always on for this model; effort defaults to 'medium' — set it explicitly.
  //     output_config: { effort: 'high', format: zodOutputFormat(Answer) },
  //     system: [{ type: 'text', text: ORACLE_SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
  //     messages: [{ role: 'user', content: `<binders>\n${context}\n</binders>\n\n${question}` }],
  //   });
  //   if (response.stop_reason === 'refusal') return json({ answer: { intro: 'The Oracle can’t help with that one.', sections: [] } });
  //   return json({ answer: response.parsed_output });
  //
  // Also opt into server-side refusal fallbacks (beta `server-side-fallback-2026-07-01` with
  // `fallbacks: 'default'` on client.beta.messages) — check the current docs for combining it
  // with structured outputs. Card actions (apply swaps, ask a friend) stay client-side.

  const answer: OracleAnswer = {
    intro: `The Oracle isn’t connected to Claude yet, but your question reached the server: “${question}”.`,
    sections: [
      {
        title: 'Next step',
        paragraphs: ['Build the deck/collection context and call the Claude API where the TODOs are in supabase/functions/oracle/index.ts.'],
      },
    ],
  };
  return json({ answer });
});
