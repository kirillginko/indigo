-- The drain, thirty jobs at a time instead of fifteen.
--
-- One cron job drains the whole enrichment queue — the NTS crawl, scene
-- rosters, artist origins, portraits — fifteen jobs every five minutes, in
-- priority order. The NTS crawl alone puts up thirteen in that time, so the
-- lowest-priority work got what was left: portraits were written at sixty an
-- hour against a hundred and twenty offered, and 0021's origin lookups rank
-- above them and would have taken most of the rest.
--
-- The worker caps a batch itself, and that cap moves to thirty in the same
-- change; asking for more than it allows is silently asking for its cap.
--
-- Redefined again, as 0007, 0008, 0009, 0012 and 0013 each did, with one line
-- changed. A project that has already scheduled the drain has it moved to
-- thirty here as well, so nobody has to run the switch again; one that never
-- scheduled it is left alone, because the job reads its address and key out of
-- the vault and there may be nothing there to read.
--
-- Safe to re-run.

create or replace function public.schedule_indigo_enrichment()
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    scheduled text[] := '{}';
begin
    -- Callable, not merely installed. Enabling is only attempted when it is
    -- actually missing, so a project where cron is already usable never goes
    -- near CREATE EXTENSION.
    if not public.has_function('cron', 'schedule') then
        begin
            create extension if not exists pg_cron;
        exception when others then
            raise exception
                'pg_cron could not be enabled (%). Turn it on in the Supabase dashboard '
                'under Database -> Extensions, then run this again.', sqlerrm;
        end;
    end if;

    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is enabled but cron.schedule is not reachable from this role';
    end if;

    -- Ask NTS what it has just broadcast. Hourly, because a station puts out a
    -- few shows a day and asking more often would be asking for nothing.
    perform cron.schedule(
        'indigo-discover-fresh',
        '7 * * * *',
        $job$select public.enqueue_enrichment_job(
            'nts', 'discover_nts', 'fresh',
            jsonb_build_object('mode', 'fresh'), 5, null, null)$job$);
    scheduled := array_append(scheduled, 'indigo-discover-fresh');

    -- And walk backwards through the archive, a page of twelve every five
    -- minutes. Deduped on the key, so a page still waiting is never queued
    -- twice and the crawl cannot fork.
    perform cron.schedule(
        'indigo-discover-backfill',
        '*/5 * * * *',
        $job$select public.enqueue_enrichment_job(
            'nts', 'discover_nts', 'backfill',
            jsonb_build_object('mode', 'backfill'), 0, null, null)$job$);
    scheduled := array_append(scheduled, 'indigo-discover-backfill');

    -- Drain thirty at a time. Fifteen kept pace with the NTS crawl, which puts
    -- up thirteen jobs every five minutes, and left almost nothing for what
    -- 0017 and 0019 added below it: artist origins and portraits. Portraits
    -- were being written at sixty an hour against a hundred and twenty queued.
    -- Thirty at MusicBrainz's second apart is about forty seconds of work.
    if not public.has_function('net', 'http_post') then
        begin
            create extension if not exists pg_net with schema extensions;
        exception when others then
            raise notice 'pg_net could not be enabled (%)', sqlerrm;
        end;
    end if;

    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-queue',
            '*/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30)
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-queue');
    else
        raise notice
            'pg_net is unavailable, so nothing will drain the queue. Enable it under '
            'Database -> Extensions and run this again.';
    end if;

    -- These two need nothing outside Postgres, so cron calls them directly
    -- rather than paying for a round trip through an Edge Function.
    perform cron.schedule(
        'indigo-resolve-radio',
        '*/30 * * * *',
        $job$select public.resolve_radio_appearances(null)$job$);
    scheduled := array_append(scheduled, 'indigo-resolve-radio');

    perform cron.schedule(
        'indigo-rebuild-edges',
        '23 * * * *',
        $job$select public.rebuild_radio_dig_edges()$job$);
    scheduled := array_append(scheduled, 'indigo-rebuild-edges');

    -- Scenes, where that migration has been applied. Called and caught rather
    -- than checked for: `to_regproc` returns null for a name it finds more
    -- than one of, which is the trap 0007 and 0008 were both written to get
    -- out of — ask about what you are going to use, and here that means using
    -- it.
    -- Named from what was actually scheduled rather than from a literal.
    -- Scene scheduling puts up two jobs now, and a switch that reports one of
    -- them is the same lie 0009 was written about: say what is, not what was
    -- expected.
    begin
        scheduled := array_append(scheduled, public.schedule_scene_rosters());
    exception
        when undefined_function then
            raise notice 'scene scheduling not installed; skipping';
    end;

    return array_to_string(scheduled, ', ');
end $$;


-- The drain that is already running, if there is one.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue')
       and public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-queue',
            '*/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30)
            )$job$);
    end if;
end $$;
