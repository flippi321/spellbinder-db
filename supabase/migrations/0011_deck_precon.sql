-- Decks get a precon flag (DK-10).
--
-- Adds:
-- - decks.is_precon: the owner says the deck is a preconstructed deck. The cards can't tell, and WotC puts a precon in
--   Bracket 2, so the app (DK-11) treats a precon as at least Bracket 2 when it works the bracket out from the cards.
--
-- No policy changes: the deck policies in 0001_init.sql already let owners insert, update and delete their decks and
-- playgroup peers read them.
--
-- Backward compatible: a new column with a default, so existing decks read false and today's app keeps working.
-- decks.bracket stays for now; the app stops reading and writing it in DK-11, and a later migration drops it once
-- nothing reads it (the test-user seed script still sends it).

alter table public.decks add column if not exists is_precon boolean not null default false;

comment on column public.decks.is_precon is
  'Preconstructed deck; the app treats a precon as at least Bracket 2 (DK-11).';
