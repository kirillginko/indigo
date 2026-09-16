-- Forget old cron runs.
--
-- pg_cron writes a row to `cron.job_run_details` for every run of every job and
-- never removes one. Indigo's drains run every few minutes, so the table only
-- grows: 16,784 rows back to the project's first day, 8.5 MB, measured
-- 2026-09-16. It is a log, and nothing reads it.
--
-- So the nightly prune from 0034 clears runs older than a week, alongside the
-- finished jobs and expired cache it already clears. A week keeps enough
-- history to see a drain that has started failing.
--
-- Aged by `start_time` rather than `end_time`: a run that started a week ago
-- finished long since, and a run still in progress has no `end_time` to test.
--
-- Guarded by `to_regclass`, and deleted through dynamic SQL, so the function
-- still compiles and runs in an environment without pg_cron.
--
-- Safe to re-run.

create or replace function public.cron_history_retention()
returns interval language sql immutable as $$ select interval '7 days' $$;

create or replace function public.prune_spent_rows()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_jobs bigint;
    v_cache bigint;
    v_runs bigint := 0;
begin
    delete from public.enrichment_jobs
    where status in ('done', 'failed')
      and coalesce(updated_at, created_at) < now() - public.finished_job_retention();
    get diagnostics v_jobs = row_count;

    -- Rows whose payload lives in Storage are left alone; see 0036.
    delete from public.metadata_cache
    where expires_at is not null
      and expires_at < now() - public.expired_cache_grace()
      and payload_path is null;
    get diagnostics v_cache = row_count;

    if to_regclass('cron.job_run_details') is not null then
        execute 'delete from cron.job_run_details where start_time < now() - $1'
            using public.cron_history_retention();
        get diagnostics v_runs = row_count;
    end if;

    return jsonb_build_object(
        'jobs_removed', v_jobs,
        'cache_rows_removed', v_cache,
        'cron_runs_removed', v_runs,
        'ran_at', now()
    );
end $$;

revoke all on function public.prune_spent_rows() from public, anon, authenticated;
grant execute on function public.prune_spent_rows() to service_role;
