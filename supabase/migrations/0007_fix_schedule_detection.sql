-- Fixes the scheduler refusing to start.
--
-- 0006 checked for pg_cron with `to_regproc('cron.schedule')`, which returns
-- NULL for a name it cannot resolve to exactly one function — and cron.schedule
-- is overloaded, with a two-argument and a three-argument form. So the check
-- reported "pg_cron is not installed" whether it was installed or not, and the
-- scheduler could never be turned on.
--
-- Catalogue lookups replace it: a name in pg_proc is a fact, and asks no
-- question about which overload was meant.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Is it actually there
-- ---------------------------------------------------------------------------

create or replace function public.has_function(p_schema text, p_name text)
returns boolean
language sql
stable
as $$
    select exists (
        select 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = p_schema and p.proname = p_name
    );
$$;

comment on function public.has_function(text, text) is
    'Overload-proof existence check. to_regproc returns NULL for an ambiguous name, '
    'which reads identically to "missing" and is how 0006 locked itself out.';

-- ---------------------------------------------------------------------------
-- Scheduling, again
-- ---------------------------------------------------------------------------

create or replace function public.schedule_indigo_enrichment()
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    scheduled text[] := '{}';
begin
    -- Try to enable it here rather than only in a migration. This runs as the
    -- function's owner, which is the role that is actually allowed to, and it
    -- means the whole thing is one call instead of a dashboard visit followed
    -- by a second attempt.
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
        begin
            create extension pg_cron;
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
    scheduled := scheduled || 'indigo-discover-fresh';

    -- And walk backwards through the archive, a page of twelve every five
    -- minutes. Deduped on the key, so a page still waiting is never queued
    -- twice and the crawl cannot fork.
    perform cron.schedule(
        'indigo-discover-backfill',
        '*/5 * * * *',
        $job$select public.enqueue_enrichment_job(
            'nts', 'discover_nts', 'backfill',
            jsonb_build_object('mode', 'backfill'), 0, null, null)$job$);
    scheduled := scheduled || 'indigo-discover-backfill';

    -- Drain, slightly faster than discovery fills, so the queue tends to empty
    -- rather than grow: a page of twelve plus its own discovery job is
    -- thirteen, against fifteen drained.
    if not exists (select 1 from pg_extension where extname = 'pg_net') then
        begin
            create extension pg_net with schema extensions;
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
        scheduled := scheduled || 'indigo-drain-queue';
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
    scheduled := scheduled || 'indigo-resolve-radio';

    perform cron.schedule(
        'indigo-rebuild-edges',
        '23 * * * *',
        $job$select public.rebuild_radio_dig_edges()$job$);
    scheduled := scheduled || 'indigo-rebuild-edges';

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
            stopped := stopped || job;
        exception when others then
            -- Not scheduled. Fine.
        end;
    end loop;

    return array_to_string(stopped, ', ');
end $$;

revoke all on function public.schedule_indigo_enrichment() from public;
revoke all on function public.unschedule_indigo_enrichment() from public;

-- ---------------------------------------------------------------------------
-- Say what is actually running
-- ---------------------------------------------------------------------------

-- 0006's status could say how much data there was but not whether anything was
-- scheduled to produce more, which is exactly the question when the answer is
-- "nothing is happening". Now it reports both, plus the last thing cron ran and
-- whether that run succeeded.
create or replace function public.enrichment_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    schedule jsonb := '[]'::jsonb;
    recent jsonb := '[]'::jsonb;
    secrets jsonb := '{}'::jsonb;
begin
    -- Vault is always there on Supabase and never on a bare Postgres, and a
    -- status call that dies rather than reports is the least useful thing this
    -- could do.
    begin
        select jsonb_build_object(
            'indigo_worker_url', exists (
                select 1 from vault.decrypted_secrets where name = 'indigo_worker_url'),
            'indigo_worker_key', exists (
                select 1 from vault.decrypted_secrets where name = 'indigo_worker_key'))
        into secrets;
    exception when others then
        secrets := jsonb_build_object('error', sqlerrm);
    end;

    if public.has_function('cron', 'schedule') then
        execute $q$
            select coalesce(jsonb_agg(jsonb_build_object(
                'job', jobname, 'schedule', schedule, 'active', active)
                order by jobname), '[]'::jsonb)
            from cron.job where jobname like 'indigo-%'
        $q$ into schedule;

        begin
            execute $q$
                select coalesce(jsonb_agg(jsonb_build_object(
                    'job', j.jobname, 'status', d.status, 'ran', d.start_time,
                    'detail', left(coalesce(d.return_message, ''), 200))
                    order by d.start_time desc), '[]'::jsonb)
                from (select * from cron.job_run_details order by start_time desc limit 5) d
                join cron.job j on j.jobid = d.jobid
            $q$ into recent;
        exception when others then
            recent := '[]'::jsonb;
        end;
    end if;

    return jsonb_build_object(
        'extensions', jsonb_build_object(
            'pg_cron', exists (select 1 from pg_extension where extname = 'pg_cron'),
            'pg_net', exists (select 1 from pg_extension where extname = 'pg_net')),
        'schedule', schedule,
        'recent_runs', recent,
        'secrets', secrets,
        'jobs', coalesce((
            select jsonb_object_agg(status, n)
            from (select status, count(*) as n from public.enrichment_jobs group by status) as s
        ), '{}'::jsonb),
        'by_type', coalesce((
            select jsonb_object_agg(job_type, n)
            from (select job_type, count(*) as n from public.enrichment_jobs
                  where status in ('pending', 'running') group by job_type) as t
        ), '{}'::jsonb),
        'cursors', coalesce((
            select jsonb_object_agg(name, position) from public.enrichment_cursors
        ), '{}'::jsonb),
        'radio', jsonb_build_object(
            'shows', (select count(*) from public.radio_shows),
            'episodes', (select count(*) from public.radio_episodes),
            'appearances', (select count(*) from public.radio_appearances),
            'resolved_appearances', (select count(*) from public.radio_appearances
                                     where artist_id is not null),
            'artists', (select count(*) from public.artists),
            'radio_edges', (select count(*) from public.music_relationships
                            where source like 'radio%')),
        'last_error', (select last_error from public.enrichment_jobs
                       where last_error is not null order by updated_at desc limit 1));
end $$;

grant execute on function public.enrichment_status() to anon, authenticated;
grant execute on function public.has_function(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- One call to start it
-- ---------------------------------------------------------------------------

-- Writes a secret Vault has not seen, or replaces one it has.
--
-- Separate from the scheduler because "the key rotated" and "start crawling"
-- are different intentions and should not have to be the same command.
create or replace function public.set_indigo_secret(p_name text, p_value text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    existing uuid;
begin
    select id into existing from vault.secrets where name = p_name;

    if existing is null then
        perform vault.create_secret(p_value, p_name, 'Indigo enrichment scheduler');
    else
        perform vault.update_secret(existing, p_value, p_name, 'Indigo enrichment scheduler');
    end if;
end $$;

-- Everything in one statement: store where the worker lives, then start.
--
--   select public.schedule_indigo_enrichment(
--       'https://<project-ref>.supabase.co/functions/v1/enrichment-worker',
--       '<publishable-anon-key>');
--
-- The key is the publishable one on purpose. The worker only drains a queue
-- that anon cannot fill, so the service role has no business being written into
-- a cron job that runs unattended for months.
create or replace function public.schedule_indigo_enrichment(
    p_worker_url text,
    p_worker_key text
)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
    if coalesce(p_worker_url, '') = '' or coalesce(p_worker_key, '') = '' then
        raise exception 'both the worker URL and a key are required';
    end if;

    perform public.set_indigo_secret('indigo_worker_url', p_worker_url);
    perform public.set_indigo_secret('indigo_worker_key', p_worker_key);

    return public.schedule_indigo_enrichment();
end $$;

revoke all on function public.set_indigo_secret(text, text) from public;
revoke all on function public.schedule_indigo_enrichment(text, text) from public;
