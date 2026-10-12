-- 0079: a failed job is kept for two weeks; a finished one for two days, as
-- before (DATABASE-CAPACITY-PLAN.md, operation C as approved 2026-10-12).
--
-- Finished jobs have been kept two days since 0047, and the queue holds about
-- three days of churn between nightly sweeps (19,260 done rows, 4.7 MB, on
-- 2026-10-12): there is nothing to reclaim by shortening it. What the
-- approval asked for is the other side: that failed jobs and their errors
-- stay long enough to recover from a bad night or a bad week. They were swept
-- after the same two days. They are few -- 91 rows, 20 kB, every one with its
-- last_error -- so two weeks of them is a few hundred rows.
--
-- `prune_spent_rows()` is otherwise unchanged: same signature, same result.

create or replace function public.failed_job_retention()
returns interval language sql immutable as $$ select interval '14 days' $$;

create or replace function public.prune_spent_rows()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
    v_jobs bigint;
    v_cache bigint;
    v_runs bigint := 0;
begin
    delete from public.enrichment_jobs
    where (status = 'done'
           and coalesce(updated_at, created_at) < now() - public.finished_job_retention())
       or (status = 'failed'
           and coalesce(updated_at, created_at) < now() - public.failed_job_retention());
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
end $function$;
