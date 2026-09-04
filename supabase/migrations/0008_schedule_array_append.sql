-- Fixes the scheduler failing on its own bookkeeping.
--
-- `scheduled := scheduled || 'indigo-discover-fresh'` looks like appending a
-- string to a text[], and is not. Postgres has both `anyarray || anyelement`
-- and `anyarray || anyarray`, an unadorned literal is of unknown type, and the
-- array/array form wins — so the literal gets parsed as an array and fails with
-- "malformed array literal". `array_append` says which one was meant.
--
-- Also stops gating on the extension being registered and starts gating on the
-- function being callable, which is the thing actually needed. Same reason 0007
-- moved off `to_regproc`: ask about what you are going to use.
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

    -- Drain, slightly faster than discovery fills, so the queue tends to empty
    -- rather than grow: a page of twelve plus its own discovery job is
    -- thirteen, against fifteen drained.
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
                body := jsonb_build_object('limit', 15)
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

    return array_to_string(scheduled, ', ');
end $$;

create or replace function public.unschedule_indigo_enrichment()
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    job text;
    stopped text[] := '{}';
begin
    if not public.has_function('cron', 'unschedule') then
        return 'pg_cron is not installed; nothing to stop';
    end if;

    foreach job in array array[
        'indigo-discover-fresh', 'indigo-discover-backfill', 'indigo-drain-queue',
        'indigo-resolve-radio', 'indigo-rebuild-edges'
    ] loop
        begin
            perform cron.unschedule(job);
            stopped := array_append(stopped, job);
        exception when others then
            -- Not scheduled. Fine.
        end;
    end loop;

    return array_to_string(stopped, ', ');
end $$;

revoke all on function public.schedule_indigo_enrichment() from public;
revoke all on function public.unschedule_indigo_enrichment() from public;
