-- Let the Lot Radio walk go ahead of the release cache.
--
-- 0039 queued the archive walk at priority 0, beside everything else that is
-- not urgent. The queue takes equal priorities oldest first, and on the day it
-- went live there were 7,580 `cache_discogs_release` jobs at priority 0 older
-- than the first page, draining at about 360 every half hour. So the first
-- page would have waited most of a day, and every page after it would have
-- joined the back of the same line again.
--
-- One job every ten minutes, a few seconds of work and one request to the
-- station, costs the cache nothing measurable. Priority 1 puts it ahead of the
-- backlog and still behind the fresh pass (5).
--
-- `enqueue_enrichment_job` raises a waiting job to the greater of its priority
-- and the one asked for, so the page already waiting is lifted on the next
-- tick; nothing has to be touched by hand.
--
-- Safe to re-run.

create or replace function public.schedule_lotradio()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    perform cron.schedule(
        'indigo-lotradio-fresh',
        '37 * * * *',
        $job$select public.enqueue_enrichment_job(
            'lotradio', 'discover_lotradio', 'fresh',
            jsonb_build_object('mode', 'fresh'), 5, null, null)$job$);

    perform cron.schedule(
        'indigo-lotradio-backfill',
        '*/10 * * * *',
        $job$select public.enqueue_enrichment_job(
            'lotradio', 'discover_lotradio', 'backfill',
            jsonb_build_object('mode', 'backfill'), 1, null, null)$job$);

    return 'indigo-lotradio-fresh, indigo-lotradio-backfill';
end $$;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_lotradio();
    end if;
end $$;
