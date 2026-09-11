-- The backend's own machinery, out of reach of the key the app ships with.
--
-- Every migration since 0005 has closed its internal functions the Postgres
-- way, `revoke all ... from public`, and believed that settled it. It does not,
-- on Supabase: a project's default privileges grant EXECUTE on every new
-- function in `public` to `anon` and `authenticated` by name, and revoking from
-- PUBLIC takes nothing away from a role that holds its own grant. So the
-- publishable key, which is in every copy of the app, could call all of them:
-- fill the enrichment queue with whatever it liked, claim jobs so they sat in
-- `running` forever, write any URL in as an artist's portrait for everybody,
-- rewrite the vault secret the drain posts to, or unschedule the lot. None of
-- that had happened when this was written; the worker URL was still the
-- project's own and every portrait on file came from i.discogs.com.
--
-- Swept rather than listed. What went wrong was a rule applied one function at
-- a time, and a list would be the same rule. Every SECURITY DEFINER function in
-- `public` is closed to the two client roles unless the app is known to call
-- it. The worker is unaffected — it connects as `service_role`, which is
-- granted here explicitly — and so is cron, which runs as the owner.
--
-- An invoker function needs no such care: it runs with the caller's own
-- privileges, so row security still decides what it can see. None of the
-- app's read RPCs calls into anything closed here.
--
-- A function added after this migration is exposed again by the same default
-- privileges, so a new internal one has to be revoked from `anon` and
-- `authenticated` by name where it is created, not just from PUBLIC.
--
-- Safe to re-run.

do $$
declare
    -- Everything Indigo calls with the publishable key. `request_scene_roster`
    -- is the one definer among them, and it is meant to be: it is how a
    -- listener opening a scene asks the backend to go and read it.
    app_callable constant text[] := array[
        'artist_radio_appearances',
        'artist_radio_relations',
        'artist_radio_summary',
        'dig_radio_for_artists',
        'episode_tracklist',
        'label_radio_summary',
        'portraits_for_artists',
        'request_scene_roster',
        'search_catalog'
    ];
    fn regprocedure;
begin
    for fn in
        select p.oid::regprocedure
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.prosecdef
          and p.proname <> all (app_callable)
    loop
        execute format('revoke execute on function %s from public, anon, authenticated', fn);
        execute format('grant execute on function %s to service_role', fn);
    end loop;
end $$;
