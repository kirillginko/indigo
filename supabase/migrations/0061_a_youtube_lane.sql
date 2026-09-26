-- A drain lane for the YouTube crawl.
--
-- Sixty channels are queued every hour, one job each. The worker now starts
-- nothing after thirty seconds into a batch and hands the rest back, so a
-- long crawl can no longer drag the batch past the function's wall clock --
-- but that also caps what one main-drain batch gets through. A lane of their
-- own, a minute after the main drain, gives the crawls a pass to themselves:
-- a quiet channel is two requests and about a second, so one pass clears most
-- of the hour's queue.
--
-- Safe to re-run.

create or replace function public.schedule_youtube()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Hourly, as 0041 set it.
    perform cron.schedule(
        'indigo-youtube-channels',
        '23 * * * *',
        $job$select public.enqueue_youtube_channels()$job$);
    scheduled := array_append(scheduled, 'indigo-youtube-channels');

    -- Addressed and authorised exactly as the main drain is, out of the vault.
    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-youtube',
            '1-59/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30, 'job_type', 'crawl_youtube_channel')
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-youtube');
    end if;

    return array_to_string(scheduled, ', ');
end $$;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_youtube();
    end if;
end $$;
