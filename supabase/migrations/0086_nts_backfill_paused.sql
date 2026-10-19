-- 0086: pauses the NTS backfill lane. Approved 2026-10-18.
--
-- Since 2026-10-10 NTS refuses `collections/recently-added` above an offset of
-- about 240 (HTTP 422, "The requested offset is not allowed"). The backfill
-- advanced its cursor before fetching and only reset on an empty page, so it
-- walked past the cap and failed every five minutes: 233 failed jobs, cursor
-- at 43,680. The worker now treats a 4xx as the end of the walk and resets,
-- but with the cap at 240 a running lane would only go round the top of the
-- feed, which `indigo-discover-fresh` already reads. So it stops here.
--
-- The history is reachable another way -- NTS's sitemaps list all ~91,000
-- episodes, and `shows/{alias}/episodes` is not capped -- but a full backfill
-- does not fit the database (419/500 MB; radio_appearances is ~466 B a row).
-- That redesign waits for the storage decision (radio-tracklist-audit §7, §10).
--
-- The fresh lane, the cursor and the failed rows are left alone. To put the
-- lane back:
--
--   select cron.schedule('indigo-discover-backfill', '*/5 * * * *',
--       $job$select public.enqueue_enrichment_job(
--           'nts', 'discover_nts', 'backfill',
--           jsonb_build_object('mode', 'backfill'), 0, null, null)$job$);

do $$
begin
    if public.has_function('cron', 'schedule') then
        perform cron.unschedule(jobname) from cron.job
        where jobname = 'indigo-discover-backfill';
    end if;
end $$;

delete from public.enrichment_jobs
where status = 'pending'
  and provider = 'nts'
  and job_type = 'discover_nts'
  and dedupe_key = 'backfill';
