-- Portraits get a drain of their own.
--
-- One drain takes the queue in priority order, and portraits were queued at
-- -2, the bottom of it. That was fine while there was room at the bottom. Then
-- 0021 started artist origins working at -1, and between them and the NTS
-- crawl there are always thirty jobs above the first portrait: the live queue
-- held 633 portrait jobs, none failed, none ever attempted, and not one had
-- been written since the origins started. Thirty at a time did not help,
-- because thirty was still all spoken for.
--
-- Raising portraits in the order would only starve whatever they overtook.
-- They are a different kind of work anyway — one Discogs search each, well
-- under a second, where the jobs above them wait a second apart on
-- MusicBrainz — so they get their own lane: the same worker, called with a job
-- type, claiming only that type. It runs two minutes after the main drain so
-- the two never start on top of each other.
--
-- Thirty a run, a second apart in the worker, is thirty requests inside one
-- minute of every five against a credential allowed sixty a minute: the other
-- half is left for catalog-refresh, which answers listeners. Three hundred and
-- sixty an hour against a hundred and twenty queued, so the backlog clears in
-- a few hours and the lane keeps pace after that.
--
-- Safe to re-run.

-- The claim, optionally narrowed to one job type. Replaced rather than
-- overloaded: with both `(int)` and `(int, text default null)` in place,
-- PostgREST cannot choose between them for a call that names only the limit,
-- and the main drain, which is exactly that call, would stop claiming anything.
drop function if exists public.claim_enrichment_jobs(int);

create or replace function public.claim_enrichment_jobs(
    p_limit int default 5,
    p_job_type text default null
)
returns setof public.enrichment_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    return query
    update public.enrichment_jobs j
    set status = 'running',
        attempts = j.attempts + 1,
        updated_at = now()
    where j.id in (
        select candidate.id
        from public.enrichment_jobs candidate
        where candidate.status = 'pending'
          and candidate.next_attempt_at <= now()
          and (p_job_type is null or candidate.job_type = p_job_type)
        order by candidate.priority desc, candidate.created_at
        for update skip locked
        limit greatest(1, least(coalesce(p_limit, 5), 50))
    )
    returning j.*;
end $$;

-- By name as well as from PUBLIC; see 0023 for why PUBLIC alone is not enough.
revoke all on function public.claim_enrichment_jobs(int, text) from public, anon, authenticated;
grant execute on function public.claim_enrichment_jobs(int, text) to service_role;

-- The lane, scheduled with the portrait queue it drains. `schedule_scene_rosters`
-- calls this, so a project set up from scratch gets it along with everything
-- else.
create or replace function public.schedule_artist_portraits()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Twenty every ten minutes is a hundred and twenty an hour against a
    -- budget of sixty a minute, which leaves the credential almost entirely
    -- free. There is no hurry: nobody is waiting, and the backlog only has to
    -- be walked once for everybody rather than once per listener.
    perform cron.schedule(
        'indigo-artist-portraits',
        '*/10 * * * *',
        $job$select public.enqueue_artist_portraits(20)$job$);
    scheduled := array_append(scheduled, 'indigo-artist-portraits');

    -- Addressed and authorised exactly as the main drain is, out of the vault.
    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-portraits',
            '2-59/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30, 'job_type', 'fetch_artist_portrait')
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-portraits');
    end if;

    return array_to_string(scheduled, ', ');
end $$;

-- A project whose drain is already running gets the lane now. One that never
-- scheduled the drain is left alone, as 0022 left it: the lane reads the same
-- vault secrets, and there may be nothing there to read.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_artist_portraits();
    end if;
end $$;
