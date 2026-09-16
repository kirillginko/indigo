-- A cache that forgets, and a queue that clears its finished work.
--
-- Two tables grow without bound because nothing was ever written to prune
-- them. Neither is why the project reached 467 MB of its 500 MB plan -- no
-- cached payload has expired yet, since the lifetimes are thirty and sixty days
-- and the project is thirteen days old; see 0035 -- but both would have
-- been, given time.
--
--   * `metadata_cache` has carried `expires_at` since 0001, and an index on
--     it. Both are only ever *read* — a lookup asks whether a row is still
--     fresh and re-fetches when it is not, which overwrites that row but
--     leaves every other expired one where it is. A provider payload the app
--     stopped asking about is kept for good.
--
--   * `enrichment_jobs` keeps every job it has ever run, each with its
--     `payload` and whatever `last_error` it collected on the way. The drain
--     marks a job `done` and moves on. Nothing deletes it.
--
-- Neither is data: one is a copy of what a provider said, the other is
-- bookkeeping about work already finished. Anything removed here is either
-- re-fetchable or spent. The catalogue tables -- artists, releases,
-- recordings, radio_appearances -- are untouched.
--
-- The artwork bucket is not the problem and needs no decision: Indigo stores
-- the provider's URL and the device fetches from that CDN, so nothing has ever
-- been uploaded. 0002 provisions a bucket and `artwork` carries path columns
-- for a re-hosting cache that was planned and never built.
--
-- Deliberately not a one-off `delete`. A migration that tidies once leaves the
-- project to fill up again, which is what got it here.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- How long spent work is kept
-- ---------------------------------------------------------------------------

-- Long enough to read a trace after a bad night, short enough that the queue
-- is not an archive. Functions rather than literals so the window is one place
-- to change, the way every other interval in this schema is done.
create or replace function public.finished_job_retention()
returns interval language sql immutable as $$ select interval '7 days' $$;

-- An expired payload is already useless -- a reader that finds one re-fetches
-- rather than trusting it -- so this only has to be long enough to be sure
-- nothing is mid-read.
create or replace function public.expired_cache_grace()
returns interval language sql immutable as $$ select interval '1 day' $$;

-- ---------------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------------

-- Reports what it removed, so the cron log says whether it is keeping up
-- rather than only that it ran.
create or replace function public.prune_spent_rows()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_jobs bigint;
    v_cache bigint;
begin
    -- Finished means finished: `pending` and `running` are left alone whatever
    -- their age, because a job stuck in `running` is a bug to look at rather
    -- than rubbish to sweep, and 0030 already expires those claims.
    delete from public.enrichment_jobs
    where status in ('done', 'failed')
      and coalesce(updated_at, created_at) < now() - public.finished_job_retention();
    get diagnostics v_jobs = row_count;

    delete from public.metadata_cache
    where expires_at is not null
      and expires_at < now() - public.expired_cache_grace();
    get diagnostics v_cache = row_count;

    return jsonb_build_object(
        'jobs_removed', v_jobs,
        'cache_rows_removed', v_cache,
        'ran_at', now()
    );
end $$;

-- Internal, and closed to the app's key by name. See 0023: revoking from
-- PUBLIC leaves `anon` holding its own grant from the project's default
-- privileges, which is how every earlier migration got this wrong.
revoke all on function public.prune_spent_rows() from public, anon, authenticated;
grant execute on function public.prune_spent_rows() to service_role;

-- ---------------------------------------------------------------------------
-- Nightly
-- ---------------------------------------------------------------------------

-- Once a day, off the hour the other jobs use. There is no hurry and no
-- listener waiting: what matters is that it happens at all.
do $$
begin
    if public.has_function('cron', 'schedule') then
        perform cron.unschedule('indigo-prune-spent')
        where exists (select 1 from cron.job where jobname = 'indigo-prune-spent');
        perform cron.schedule(
            'indigo-prune-spent',
            '17 4 * * *',
            $job$select public.prune_spent_rows()$job$);
    end if;
end $$;
