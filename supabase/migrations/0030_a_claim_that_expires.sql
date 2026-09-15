-- A claim that expires.
--
-- `claim_enrichment_jobs` marks a job `running` and hands it to the worker, and
-- nothing ever marks it back. A worker invocation that is cut short -- the Edge
-- Function's wall clock, a deploy mid-batch, an upstream that never answers --
-- leaves its jobs `running` for ever. They are never claimed again, because the
-- claim only reads `pending`.
--
-- Measured on the live project: **90 jobs stuck**, the oldest for **96.7
-- hours**. 67 artist origins, 19 NTS episodes, 3 portraits. Each one is also
-- holding its dedupe key -- the unique index covers `pending` and `running`
-- together -- so the passes that would have re-queued that work found it
-- already there and did nothing. That is why the ISRC backfill from 0025 had
-- moved 184 rows in eight hours: the episodes it wanted were not queued behind
-- anything, they were gone.
--
-- A claim is a lease now. Past the lease the job is claimable again, and the
-- attempt it already spent still counts, so `max_attempts` bounds it exactly as
-- a failure does and nothing can retry for ever.
--
-- Safe to re-run.

-- How long a worker may hold a job before the claim lapses.
--
-- Well past any honest run: the drain takes thirty jobs and the slowest of them
-- is one upstream request, so a batch that has not reported in a quarter of an
-- hour is not still working. Short enough that work lost to a restart is back
-- within the hour rather than never.
create or replace function public.enrichment_claim_lease()
returns interval language sql immutable as $$ select interval '15 minutes' $$;

-- Puts back a claim nobody came back from.
--
-- A sweep rather than a change to `claim_enrichment_jobs`, deliberately. That
-- function is defined by 0024, which is re-runnable by contract and is
-- re-applied by `Scripts/test-migrations.sh` after every later migration — so
-- a newer body for it is silently replaced by the older one whenever 0024 runs
-- again. `app_callable_functions` learned the same lesson in 0027. Anything
-- that has to survive another migration being re-applied belongs somewhere
-- that migration does not touch.
--
-- Bounded so it cannot become a long transaction, and safe to run as often as
-- you like: a claim inside its lease is never touched, which is what keeps two
-- drains off the same job.
create or replace function public.reclaim_expired_enrichment_jobs(p_limit int default 200)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_reclaimed int;
begin
    with expired as (
        select id from public.enrichment_jobs
        where status = 'running'
          and updated_at < now() - public.enrichment_claim_lease()
        order by updated_at
        limit greatest(1, least(coalesce(p_limit, 200), 1000))
        for update skip locked
    )
    update public.enrichment_jobs j
    -- A job that has already burned its attempts is marked failed rather than
    -- queued again, which is what `complete_enrichment_job` would have done had
    -- anyone been there to call it.
    set status = case when j.attempts >= j.max_attempts then 'failed' else 'pending' end,
        next_attempt_at = now(),
        last_error = coalesce(j.last_error, 'claim expired: no worker reported back')
    from expired
    where j.id = expired.id;

    get diagnostics v_reclaimed = row_count;
    return v_reclaimed;
end $$;

revoke all on function public.reclaim_expired_enrichment_jobs(int)
    from public, anon, authenticated;
grant execute on function public.reclaim_expired_enrichment_jobs(int) to service_role;

-- Every five minutes, just ahead of the main drain at 0-59/5 so a reclaimed job
-- is waiting for it rather than a cycle behind.
create or replace function public.schedule_claim_reclaim()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    perform cron.schedule(
        'indigo-reclaim-claims',
        '4-59/5 * * * *',
        $job$select public.reclaim_expired_enrichment_jobs(200)$job$);

    return 'indigo-reclaim-claims';
end $$;

-- ---------------------------------------------------------------------------
-- The ones already lost
-- ---------------------------------------------------------------------------

-- Jobs that have been `running` since before this migration existed are not
-- going to be finished by whoever claimed them. Put back as pending, keeping
-- the attempts they spent.
--
-- A job that has already burned its attempts is marked failed instead, which is
-- what `complete_enrichment_job` would have done had anyone been there to call
-- it. Neither is retried for ever.
do $$
declare
    v_reclaimed int;
begin
    v_reclaimed := public.reclaim_expired_enrichment_jobs(1000);
    if v_reclaimed > 0 then
        raise notice 'put back % claims nobody came back from', v_reclaimed;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Seeing it happen again
-- ---------------------------------------------------------------------------

-- What the queue is doing, in one read.
--
-- There was no way to ask this without the service key, so ninety jobs sat
-- stopped for four days and the only symptom was a backfill that was not
-- moving. Counts only -- no payloads, nothing about what any one job is.
create or replace function public.enrichment_queue_health()
returns jsonb
language sql
stable
as $$
    select jsonb_build_object(
        'pending', count(*) filter (where status = 'pending'),
        'running', count(*) filter (where status = 'running'),
        'failed', count(*) filter (where status = 'failed'),
        'done', count(*) filter (where status = 'done'),
        -- The number that says a worker is dying mid-batch. Should be zero.
        'claims_expired', count(*) filter (
            where status = 'running'
              and updated_at < now() - public.enrichment_claim_lease()),
        'oldest_pending_hours', round(extract(epoch from
            coalesce(now() - min(created_at) filter (where status = 'pending'),
                     interval '0')) / 3600, 1)
    )
    from public.enrichment_jobs;
$$;

grant execute on function public.enrichment_queue_health() to anon, authenticated, service_role;

-- Added to the one list, so 0023's sweep leaves it callable. See 0027.
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
        'credit_row_count',
        'dig_radio_for_artists',
        'enrichment_queue_health',
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

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

-- Added to the umbrella, carrying 0028's composition forward unchanged.
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
    scheduled := array_append(scheduled, public.schedule_artist_merge());
    scheduled := array_append(scheduled, public.schedule_claim_reclaim());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_claim_reclaim();
    end if;
end $$;
