-- Move the RLS helper functions out of the API.
--
-- is_playgroup_member() and shares_playgroup() are security definer helpers for RLS policies. In `public` they were
-- also callable as /rest/v1/rpc/… (Supabase advisor 0029). In `private`, which PostgREST doesn't expose, policies keep
-- using them (policies reference functions by oid, so nothing else changes) but clients can't call them.
-- create_playgroup() and join_playgroup() stay in `public`: they are the RPCs the clients call.
--
-- Backward compatible: no client calls these two functions.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

alter function public.is_playgroup_member(uuid) set schema private;
alter function public.shares_playgroup(uuid) set schema private;
