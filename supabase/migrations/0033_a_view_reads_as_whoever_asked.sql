-- A view reads as whoever asked, not as whoever wrote it.
--
-- Supabase's advisor calls both of the project's views critical, and the rule
-- it is enforcing is a real one. A Postgres view runs with the privileges of
-- its **owner** unless told otherwise, so row security is evaluated against
-- the owner rather than against whoever ran the query. A view is therefore a
-- hole in RLS by default: anybody who can select from it reads the base tables
-- as the owner, and the policies written on those tables never apply.
--
-- What that is worth here is less than "critical" suggests, and it is worth
-- saying why rather than only fixing it.
--
--   * Both views are granted to `service_role` and to nothing else. That role
--     bypasses RLS anyway, so no caller currently gains anything through the
--     view it did not already have directly.
--   * The base tables are `artists` and `external_ids`, whose policy from 0001
--     is `for select to anon, authenticated using (true)`. This is shared
--     catalogue data, open on purpose, because the app ships a publishable key
--     that anybody can extract. There is nothing behind these views that a
--     client could not read from the tables themselves.
--
-- So this closes a hole that nothing was falling through. It is still worth
-- closing: the reason it is harmless is a fact about today's grants and today's
-- policies, and neither is a thing the view itself states. A view that reads as
-- its owner is a trap left for whoever next writes a policy on `artists` and
-- reasonably expects it to hold everywhere -- which is exactly the shape of
-- 0023, where "revoke from public" was believed to settle a question it did
-- not.
--
-- `security_invoker` costs nothing to turn on. Both views are read only by the
-- worker, which connects as `service_role` and bypasses row security, so what
-- they return does not change. Were a client role ever granted one, it would
-- now see through the view exactly what it sees through the tables -- which is
-- everything, deliberately, and by a route that says so.
--
-- Requires Postgres 15, which is what the project runs.
--
-- Safe to re-run.

alter view public.split_artist_halves     set (security_invoker = on);
alter view public.artists_that_are_credits set (security_invoker = on);

-- And the grants restated, for the reason 0023 exists.
--
-- Default privileges on a Supabase project hand new objects in `public` to
-- `anon` and `authenticated` by name, and a `revoke ... from public` does not
-- touch a role holding its own grant. Neither view was ever meant to be
-- readable by the key the app ships with: they exist for a one-off merge run
-- by the worker.
revoke all on public.split_artist_halves      from public, anon, authenticated;
revoke all on public.artists_that_are_credits from public, anon, authenticated;
grant select on public.split_artist_halves      to service_role;
grant select on public.artists_that_are_credits to service_role;
