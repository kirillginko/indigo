-- Smoke test for who can reach the queue, and for claiming one kind of job.
--
-- Both halves failed silently in production. The internal functions were all
-- callable with the publishable key while every test said otherwise, because a
-- plain Postgres does not grant EXECUTE to `anon` by name the way a Supabase
-- project does (the stubs now do; see 0023). And portraits sat unclaimed under
-- higher-priority work without a single job failing (see 0024).
--
--     psql -f supabase/tests/queue_smoke.sql
--
-- Every check raises on failure, so a clean run means a clean run.

\set ON_ERROR_STOP on
begin;

do $$
declare
    exposed text;
    claimed text[];
begin
    -- Nothing that runs as the owner is callable by the app's key, bar what
    -- the app actually calls. Checked after every migration has run, so a
    -- later one that recreates a function and forgets the revoke fails here.
    select string_agg(p.oid::regprocedure::text, ', ') into exposed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and p.proname <> 'request_scene_roster'
      and (has_function_privilege('anon', p.oid, 'execute')
           or has_function_privilege('authenticated', p.oid, 'execute'));
    if exposed is not null then
        raise exception 'callable with the publishable key: %', exposed;
    end if;

    -- Looked up by name, so a signature changing later does not make these
    -- pass by pointing at nothing.
    if exists (
        select 1 from unnest(array[
            'claim_enrichment_jobs', 'complete_enrichment_job', 'enqueue_enrichment_job',
            'record_artist_portrait', 'record_artist_origin', 'record_scene_members'
        ]) as wanted(name)
        where not exists (
            select 1 from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = wanted.name
              and has_function_privilege('service_role', p.oid, 'execute'))
    ) then
        raise exception 'the worker has lost a function it calls';
    end if;

    -- The app's own calls still work for the app.
    if exists (
        select 1 from unnest(array[
            'request_scene_roster', 'portraits_for_artists', 'search_catalog',
            'dig_radio_for_artists', 'artist_radio_relations', 'label_radio_summary'
        ]) as wanted(name)
        where not exists (
            select 1 from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = wanted.name
              and has_function_privilege('anon', p.oid, 'execute'))
    ) then
        raise exception 'the app has lost a function it calls';
    end if;

    -- One claim function, not two. Both overloads at once and PostgREST
    -- cannot pick one for a call naming only the limit.
    if to_regprocedure('public.claim_enrichment_jobs(int)') is not null then
        raise exception 'the one-argument claim is still there beside the two-argument one';
    end if;

    -- The queue, shaped the way production had it: portraits at the bottom
    -- under more higher-priority work than one drain takes.
    delete from public.enrichment_jobs;
    insert into public.enrichment_jobs (provider, job_type, dedupe_key, priority)
    select 'musicbrainz', 'fetch_artist_origin', 'origin-' || i, -1 from generate_series(1, 5) i;
    insert into public.enrichment_jobs (provider, job_type, dedupe_key, priority)
    select 'discogs', 'fetch_artist_portrait', 'portrait-' || i, -2 from generate_series(1, 3) i;

    -- The main drain is unchanged: priority first, so a small batch is all origins.
    select array_agg(job_type) into claimed from public.claim_enrichment_jobs(3);
    if claimed <> array['fetch_artist_origin', 'fetch_artist_origin', 'fetch_artist_origin'] then
        raise exception 'an unnarrowed claim should take the highest priority first: %', claimed;
    end if;

    -- The lane takes portraits past the origins still waiting above them.
    select array_agg(job_type) into claimed from public.claim_enrichment_jobs(10, 'fetch_artist_portrait');
    if cardinality(claimed) <> 3 or 'fetch_artist_origin' = any (claimed) then
        raise exception 'a narrowed claim should take only its own type: %', claimed;
    end if;

    -- And leaves the rest for the main drain.
    if (select count(*) from public.enrichment_jobs
        where job_type = 'fetch_artist_origin' and status = 'pending') <> 2 then
        raise exception 'the lane touched jobs that are not its own';
    end if;

    raise notice 'queue smoke: all checks passed';
end $$;

rollback;
