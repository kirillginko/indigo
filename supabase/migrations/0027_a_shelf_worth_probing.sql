-- A shelf worth probing.
--
-- `CatalogReleaseSource` has sat between the app and Discogs since the cache
-- was built, and it is switched off on any build holding a credential. Its own
-- comment says why, and says what would change it:
--
--     The shared cache holds a few dozen records against a catalogue of
--     millions, so today it nearly always is not -- which made every cold
--     release open pay for a question whose answer was no. Worth revisiting
--     when the cache is dense enough that the probe usually hits: this is the
--     line to flip.
--
-- Measured from `indigo-trace.txt`: one artist page costs about twenty-six
-- Discogs requests -- two for the artist, sixteen searches, and eight
-- `releases/{id}` reads, one per tile that needs its cover and its labels.
-- Against a credential allowed sixty a minute and shared by every copy of the
-- app, that is two pages a minute. The busiest minute in the trace ran a
-- hundred and fifty-nine, six pages deep, and everything after that sat in
-- `waitForRoom()` -- an eleven-second artist page with eight seconds of nothing
-- happening in the middle of it.
--
-- The eight release reads are the part that need not be spent at all. A release
-- does not change; Discogs describes it once and the answer is good for months.
-- Today every listener pays for it separately, on every page open, and 18% of
-- those reads in the trace were the same id fetched again -- one release
-- eighteen times.
--
-- So the cache gets filled deliberately rather than as a side effect of somebody
-- having opened a page. Two ways in, because they answer different questions:
-- the app says what it is looking at right now, and a slow crawl walks the
-- shelves of the artists radio says are worth having ready.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- What counts as cached
-- ---------------------------------------------------------------------------

-- Matches `MetadataRepository.Lifetime.release` in the app. Both sides decide
-- whether a row is worth reading, and they have to agree about it.
create or replace function public.release_cache_lifetime()
returns interval language sql immutable as $$ select interval '60 days' $$;

-- Shorter than a release's. A record never changes; an artist's discography
-- gains one whenever they put something out. Matches `SHELF_CACHE_TTL_SECONDS`
-- in `discogs.ts` and `MetadataRepository.Lifetime.artist` in the app.
create or replace function public.shelf_cache_lifetime()
returns interval language sql immutable as $$ select interval '30 days' $$;

-- Exactly the shape both queues below read: is this release cached, and is it
-- still good? `metadata_cache` is already unique on the triple, so this is the
-- covering half of it.
create index if not exists metadata_cache_release_idx
    on public.metadata_cache(resource_id)
    where provider = 'discogs' and resource_type = 'release';

-- Whether an artist's shelf has been walked, and when. On `artists` rather than
-- in a table of its own because it is one timestamp per artist and every reader
-- of it already has the row.
alter table public.artists
    add column if not exists shelf_cached_at timestamptz;

-- ---------------------------------------------------------------------------
-- What the app is looking at
-- ---------------------------------------------------------------------------

-- Releases a page wants cached, asked for in bulk.
--
-- App-callable, like `request_scene_roster` and for the same reason: the app is
-- the only thing that knows what somebody is reading. It cannot reach
-- `enqueue_enrichment_job`, which is revoked from `anon` -- what it can do is
-- name Discogs release ids, and the only work that can follow is a fetch of
-- exactly those releases.
--
-- Bounded twice over. Fifty ids a call, because a page shows two dozen tiles and
-- anything larger is not a page. And every id must be digits: the id goes into a
-- URL the worker builds, and `isSafeID` in catalog-refresh makes the same check
-- on the other side.
--
-- Returns what it did rather than nothing, so the app can tell a cold page from
-- a warm one without a second round trip.
create or replace function public.request_release_cache(p_discogs_ids text[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id text;
    v_queued int := 0;
    v_cached int := 0;
    v_seen text[] := '{}';
begin
    if p_discogs_ids is null then
        return jsonb_build_object('queued', 0, 'cached', 0);
    end if;

    foreach v_id in array p_discogs_ids loop
        v_id := btrim(coalesce(v_id, ''));
        continue when v_id !~ '^[0-9]{1,12}$';
        -- One id named twice in a call is one id.
        continue when v_id = any(v_seen);
        v_seen := array_append(v_seen, v_id);
        exit when cardinality(v_seen) > 50;

        if exists (
            select 1 from public.metadata_cache mc
            where mc.provider = 'discogs'
              and mc.resource_type = 'release'
              and mc.resource_id = v_id
              and mc.fetched_at > now() - public.release_cache_lifetime()
        ) then
            v_cached := v_cached + 1;
            continue;
        end if;

        perform public.enqueue_enrichment_job(
            'discogs',
            'cache_discogs_release',
            v_id,
            jsonb_build_object('release_id', v_id),
            -- Above the shelf crawl below and above portraits. Somebody is
            -- looking at this page now; the crawl is for pages nobody has
            -- opened yet.
            1,
            null,
            null
        );
        v_queued := v_queued + 1;
    end loop;

    return jsonb_build_object('queued', v_queued, 'cached', v_cached);
end $$;

-- ---------------------------------------------------------------------------
-- The shelf a page is waiting on
-- ---------------------------------------------------------------------------

-- Queues the listing behind an artist page, when the app could not read it.
--
-- `artists/{id}/releases` is the slowest request a cold artist makes and the
-- one it cannot draw without: 2,727ms for Ryuichi Sakamoto, 1,916ms for Haruomi
-- Hosono, on a Discogs that was refusing nothing. The crawl above already
-- fetches exactly that listing for the artists radio says matter, and now keeps
-- it -- but the artist somebody opens is very often not one of those yet.
--
-- So the app says which shelf it wanted and had to fetch itself. The next
-- listener to open that artist reads it out of Postgres, and so does this one
-- tomorrow.
--
-- Bounded the same way `request_release_cache` is: digits only, because the id
-- goes into a URL the worker builds.
create or replace function public.request_artist_shelf(p_discogs_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id text := btrim(coalesce(p_discogs_id, ''));
    v_path text;
begin
    if v_id !~ '^[0-9]{1,12}$' then
        return jsonb_build_object('queued', 0, 'cached', 0);
    end if;

    v_path := 'artists/' || v_id || '/releases';

    -- Already held and still worth reading, so the app simply missed a race
    -- with another listener.
    if exists (
        select 1 from public.metadata_cache mc
        where mc.provider = 'discogs'
          and mc.resource_type = v_path
          and mc.fetched_at > now() - public.shelf_cache_lifetime()
    ) then
        return jsonb_build_object('queued', 0, 'cached', 1);
    end if;

    -- Already waiting, whether the crawl queued it or another listener did.
    -- `enqueue_enrichment_job` would dedupe it anyway; what this adds is
    -- saying so, so the app can tell a shelf that is coming from one it has
    -- just asked for.
    if exists (
        select 1 from public.enrichment_jobs j
        where j.provider = 'discogs'
          and j.job_type = 'cache_discogs_shelf'
          and j.dedupe_key = v_id
          and j.status in ('pending', 'running')
    ) then
        return jsonb_build_object('queued', 0, 'cached', 0);
    end if;

    perform public.enqueue_enrichment_job(
        'discogs',
        'cache_discogs_shelf',
        -- Keyed on the Discogs id rather than the artist row, so a shelf the
        -- crawl has queued and a shelf a page has asked for are one job.
        v_id,
        jsonb_build_object('discogs_id', v_id),
        -- Above the crawl's own shelves at 0: somebody is looking at this one.
        1,
        null,
        null
    );

    return jsonb_build_object('queued', 1, 'cached', 0);
end $$;

revoke all on function public.request_artist_shelf(text) from public;
grant execute on function public.request_artist_shelf(text)
    to anon, authenticated, service_role;

-- MARK: - What the app is allowed to call

-- The allow-list 0023 sweeps against, as a function rather than a literal.
--
-- 0023 revokes every SECURITY DEFINER function in `public` from `anon` except
-- the names it holds in an array, and it is safe to re-run -- which means a
-- function added afterwards has its grant taken away again the next time 0023
-- is applied. `Scripts/test-migrations.sh` re-applies it deliberately, and that
-- is how this was caught: `request_release_cache` was granted, swept, and the
-- privilege test passed by agreeing it should not be callable.
--
-- One definition, read by the sweep below and by `queue_smoke.sql`, so adding
-- an app-callable function is one edit and the test cannot drift from the
-- grant.
create or replace function public.app_callable_functions()
returns text[]
language sql
immutable
as $$
    select array[
        'app_callable_functions',
        'artist_radio_appearances',
        'artist_radio_relations',
        'artist_radio_summary',
        'dig_radio_for_artists',
        'episode_tracklist',
        'label_radio_summary',
        'portraits_for_artists',
        'release_cache_coverage',
        'request_artist_shelf',
        'request_release_cache',
        'request_scene_roster',
        'search_catalog'
    ]
$$;

grant execute on function public.app_callable_functions() to anon, authenticated, service_role;

-- 0023's sweep, re-run against the list above. Everything internal stays the
-- backend's; everything the app actually calls keeps its grant.
do $$
declare
    fn regprocedure;
begin
    for fn in
        select p.oid::regprocedure
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.prosecdef
          and p.proname <> all (public.app_callable_functions())
    loop
        execute format('revoke execute on function %s from public, anon, authenticated', fn);
        execute format('grant execute on function %s to service_role', fn);
    end loop;
end $$;

revoke all on function public.request_release_cache(text[]) from public;
grant execute on function public.request_release_cache(text[])
    to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The shelves worth having ready
-- ---------------------------------------------------------------------------

-- Walks one artist's shelf per job, most-played first.
--
-- Radio decides who, exactly as it does for origins and portraits: the artist
-- table is everybody who ever turned up on a tracklist, and walking all of them
-- would spend a budget that is not ours alone. An artist needs a Discogs id to
-- have a shelf at all, which today is 677 of them -- and that number grows as
-- `fetch_artist_portrait` resolves more.
create or replace function public.enqueue_shelf_releases(p_limit int default 5)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 5), 50));
begin
    for v_row in
        select a.id, a.name, x.external_id as discogs_id, count(*) as plays
        from public.artists a
        join public.external_ids x
            on x.entity_type = 'artist' and x.entity_id = a.id and x.provider = 'discogs'
        join public.radio_appearances ap on ap.artist_id = a.id
        where (
                a.shelf_cached_at is null
                or a.shelf_cached_at < now() - public.release_cache_lifetime()
              )
          and x.external_id ~ '^[0-9]{1,12}$'
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'discogs'
                and j.job_type = 'cache_discogs_shelf'
                and j.dedupe_key = x.external_id
                and j.status in ('pending', 'running')
          )
        group by a.id, a.name, x.external_id
        order by count(*) desc, a.name
        limit v_limit
    loop
        perform public.enqueue_enrichment_job(
            'discogs',
            'cache_discogs_shelf',
            -- The Discogs id, not the artist row, so this and
            -- `request_artist_shelf` are the same job rather than two fetches
            -- of one listing.
            v_row.discogs_id,
            jsonb_build_object(
                'artist_id', v_row.id,
                'discogs_id', v_row.discogs_id,
                'name', v_row.name),
            0,
            'artist',
            v_row.id
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.enqueue_shelf_releases(int) from public, anon, authenticated;
grant execute on function public.enqueue_shelf_releases(int) to service_role;

-- Records that an artist's shelf has been walked.
--
-- Written whether or not the shelf had anything on it. An artist Discogs files
-- no releases under is a finding, and the crawl must not come back for them
-- every quarter hour for ever.
create or replace function public.record_shelf_cached(p_artist_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
    update public.artists set shelf_cached_at = now() where id = p_artist_id;
$$;

revoke all on function public.record_shelf_cached(uuid) from public, anon, authenticated;
grant execute on function public.record_shelf_cached(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- How dense it actually is
-- ---------------------------------------------------------------------------

-- The number the decision to flip `canReachProviderDirectly` rests on.
--
-- A probe is worth making when it usually hits. Nothing in the app can see that
-- from the outside -- a miss and a hit cost the same round trip -- so the
-- backend has to be able to say. Read by hand, not on any page's path.
create or replace function public.release_cache_coverage()
returns jsonb
language sql
stable
as $$
    select jsonb_build_object(
        'cached', count(*) filter (
            where mc.fetched_at > now() - public.release_cache_lifetime()),
        'stale', count(*) filter (
            where mc.fetched_at <= now() - public.release_cache_lifetime()),
        'shelves_walked', (select count(*) from public.artists where shelf_cached_at is not null),
        'shelves_outstanding', (
            select count(*)
            from public.artists a
            join public.external_ids x
                on x.entity_type = 'artist' and x.entity_id = a.id and x.provider = 'discogs'
            where a.shelf_cached_at is null)
    )
    from public.metadata_cache mc
    where mc.provider = 'discogs' and mc.resource_type = 'release';
$$;

grant execute on function public.release_cache_coverage() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

create or replace function public.schedule_release_cache()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Five shelves every fifteen minutes. A shelf is one listing request plus
    -- one read per release on it, so five of them is roughly a hundred and
    -- fifty requests spread over the quarter hour the lane has to spend them
    -- in -- ten a minute against sixty, leaving the rest for portraits, for
    -- catalog-refresh, and for the listeners this is all for.
    --
    -- Deliberately slow. Filling the cache faster than that would make the
    -- thing it is meant to fix worse in the meantime, because it is the same
    -- credential either way.
    perform cron.schedule(
        'indigo-shelf-releases',
        '*/15 * * * *',
        $job$select public.enqueue_shelf_releases(5)$job$);
    scheduled := array_append(scheduled, 'indigo-shelf-releases');

    -- Its own lane, so a page's own request -- queued at 1 -- is never behind
    -- the NTS crawl. Three minutes past, between the portrait lane at two and
    -- the release lane at four.
    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-release-cache',
            '3-59/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30, 'job_type', 'cache_discogs_release')
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-release-cache');

        -- The shelf walk is its own lane again: one job fans out into thirty
        -- release jobs, so a handful of them per run is the whole point.
        perform cron.schedule(
            'indigo-drain-shelves',
            '13-59/15 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 5, 'job_type', 'cache_discogs_shelf')
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-shelves');
    end if;

    return array_to_string(scheduled, ', ');
end $$;

-- Added to the umbrella, carrying 0026's composition forward unchanged.
create or replace function public.schedule_scene_rosters()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;

    perform cron.schedule(
        'indigo-resume-scenes',
        '*/10 * * * *',
        $job$select public.resume_scene_rosters(4)$job$);
    scheduled := array_append(scheduled, 'indigo-resume-scenes');

    perform cron.schedule(
        'indigo-seed-scenes',
        '41 3 * * *',
        $job$select public.seed_scene_rosters()$job$);
    scheduled := array_append(scheduled, 'indigo-seed-scenes');

    scheduled := array_append(scheduled, public.schedule_nts_retag());
    scheduled := array_append(scheduled, public.schedule_scene_radio_fill());
    scheduled := array_append(scheduled, public.schedule_artist_origins());
    scheduled := array_append(scheduled, public.schedule_artist_portraits());
    scheduled := array_append(scheduled, public.schedule_track_releases());
    scheduled := array_append(scheduled, public.schedule_nts_hosts());
    scheduled := array_append(scheduled, public.schedule_release_cache());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_release_cache();
    end if;
end $$;
