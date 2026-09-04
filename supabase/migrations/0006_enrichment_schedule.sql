-- Scheduled enrichment: filling the database when nobody is using the app.
--
-- Until now the graph only grew when somebody opened something. That makes the
-- radio features weakest exactly when they would be most useful — on a fresh
-- install, or for an artist the listener has not already been reading about.
--
-- NTS publishes its whole archive newest-first as `collections/recently-added`
-- (89,856 episodes at time of writing), and its robots.txt is `Allow: /` with
-- no crawl-delay and two published sitemaps. So this walks that feed: a page of
-- twelve at a time, enqueued rather than fetched, and drained at a rate that
-- keeps Indigo a polite client.
--
-- Nothing here starts on its own. `schedule_indigo_enrichment()` has to be
-- called deliberately, because a migration that silently began crawling a radio
-- station from every developer's laptop would be a rude thing to ship.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Where the crawl has got to
-- ---------------------------------------------------------------------------

create table if not exists public.enrichment_cursors (
    name text primary key,
    position int not null default 0,
    updated_at timestamptz not null default now()
);

alter table public.enrichment_cursors enable row level security;
-- No policy: the backend's bookkeeping, not the app's.

-- Hands out the next window and moves the cursor in one statement, so two
-- workers can never be given the same page of the archive.
create or replace function public.advance_enrichment_cursor(
    p_name text,
    p_by int default 12
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    previous int;
begin
    insert into public.enrichment_cursors (name, position)
    values (p_name, 0)
    on conflict (name) do nothing;

    update public.enrichment_cursors
    set position = position + greatest(1, p_by),
        updated_at = now()
    where name = p_name
    returning position - greatest(1, p_by) into previous;

    return coalesce(previous, 0);
end $$;

-- Walked to the end, or starting again after the archive grew.
create or replace function public.reset_enrichment_cursor(p_name text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
    update public.enrichment_cursors
    set position = 0, updated_at = now()
    where name = p_name;
$$;

revoke all on function public.advance_enrichment_cursor(text, int) from public;
revoke all on function public.reset_enrichment_cursor(text) from public;
grant execute on function public.advance_enrichment_cursor(text, int) to service_role;
grant execute on function public.reset_enrichment_cursor(text) to service_role;

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

-- pg_cron runs the SQL; pg_net is only needed for the one job that has to reach
-- outside Postgres. Both are on Supabase's allow-list, but a local stack may
-- have neither, and failing a migration over a scheduler nobody asked for yet
-- would be the wrong trade.
do $$
begin
    begin
        create extension if not exists pg_cron;
    exception when others then
        raise notice 'pg_cron unavailable (%); scheduling will be skipped', sqlerrm;
    end;
    begin
        create extension if not exists pg_net with schema extensions;
    exception when others then
        raise notice 'pg_net unavailable (%); the worker cannot be woken by cron', sqlerrm;
    end;
end $$;

-- Turns the schedule on. Call it once, deliberately.
--
-- The worker's URL and key are read from Vault at run time rather than written
-- into the job definition: `cron.job.command` is readable by any database user,
-- and this keeps the schedule portable between projects instead of baking one
-- project's ref into a committed migration.
--
--   select vault.create_secret(
--       'https://<project-ref>.supabase.co/functions/v1/enrichment-worker',
--       'indigo_worker_url');
--   select vault.create_secret('<publishable-anon-key>', 'indigo_worker_key');
--   select public.schedule_indigo_enrichment();
--
-- The anon key is enough: the worker only ever drains a queue that anon cannot
-- fill, so nothing here needs the service role.
create or replace function public.schedule_indigo_enrichment()
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    scheduled text[] := '{}';
begin
    if to_regproc('cron.schedule') is null then
        raise exception 'pg_cron is not installed; enable it before scheduling';
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

    -- And walk backwards through the archive, one page of twelve every five
    -- minutes. Deduped on the key, so a page still waiting is never queued
    -- twice and the crawl cannot fork.
    --
    -- Twelve every five minutes is about 3,400 episodes a day, so NTS's 90,000
    -- takes roughly a month — and costs some two and a half requests a minute,
    -- which is a rate a station will not notice. Both numbers are the knob:
    -- raise this to '*/2' and the drain to 30 and it is a fortnight instead.
    perform cron.schedule(
        'indigo-discover-backfill',
        '*/5 * * * *',
        $job$select public.enqueue_enrichment_job(
            'nts', 'discover_nts', 'backfill',
            jsonb_build_object('mode', 'backfill'), 0, null, null)$job$);
    scheduled := scheduled || 'indigo-discover-backfill';

    -- Drain, slightly faster than discovery fills, so the queue tends to empty
    -- rather than grow: a page of twelve plus its own discovery job is thirteen,
    -- against fifteen drained.
    if to_regproc('net.http_post') is null then
        raise notice 'pg_net missing: the queue will fill but nothing will drain it';
    else
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
    end if;

    -- These two need nothing outside Postgres, so cron calls them directly
    -- rather than paying for a round trip through an Edge Function.
    --
    -- Resolution is the pass that goes back for names that matched nothing the
    -- first time: an artist Discogs normalized last week makes an appearance
    -- from March resolvable today.
    perform cron.schedule(
        'indigo-resolve-radio',
        '*/30 * * * *',
        $job$select public.resolve_radio_appearances(null)$job$);
    scheduled := scheduled || 'indigo-resolve-radio';

    -- The graph is a function of the appearances, so rebuilding it is only ever
    -- worth doing after a batch of them has landed.
    perform cron.schedule(
        'indigo-rebuild-edges',
        '23 * * * *',
        $job$select public.rebuild_radio_dig_edges()$job$);
    scheduled := scheduled || 'indigo-rebuild-edges';

    return array_to_string(scheduled, ', ');
end $$;

-- Turns it off again. Worth having: an unattended crawl somebody cannot stop
-- from the same place they started it is a trap.
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
    if to_regproc('cron.unschedule') is null then
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
-- Watching it work
-- ---------------------------------------------------------------------------

-- What the queue is doing, in one row per state. Enough to answer "is it
-- running, and is it getting anywhere" without reading the table.
create or replace function public.enrichment_status()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
select jsonb_build_object(
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
                   where last_error is not null order by updated_at desc limit 1)
);
$$;

grant execute on function public.enrichment_status() to anon, authenticated;
