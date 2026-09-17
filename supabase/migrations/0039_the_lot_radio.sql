-- The Lot Radio, beside NTS.
--
-- Everything downstream of a tracklist was already station-agnostic:
-- `resolve_radio_appearances`, `adopt_radio_artists`, `rebuild_radio_dig_edges`,
-- the scene fill and every read model key on `radio_episodes` and
-- `radio_appearances`, never on who broadcast them. So a second station needs
-- no new tables. Its broadcasts are rows with `provider = 'lotradio'`, its
-- presenters are adopted under the same name-key identity NTS's are, and an
-- artist played on both is one artist with both histories.
--
-- What it does need is a crawl. The Lot publishes no API; its archive index
-- embeds whole broadcasts, tracklists included, and pages further back through
-- a cursor the site signs itself. That cursor, and the id of the action that
-- accepts it, are the crawl's position -- text, not the integer offset
-- `enrichment_cursors` was built for -- so the table gains somewhere to keep
-- them. See supabase/functions/_shared/lotradio.ts.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Where the crawl has got to
-- ---------------------------------------------------------------------------

-- Written only by the worker, under the service role; the table has RLS on
-- and no policy, so the app's key cannot read the cursor or the action id.
alter table public.enrichment_cursors add column if not exists state jsonb;

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

create or replace function public.schedule_lotradio()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- What went out today. The index holds the newest thirty-two broadcasts,
    -- about three days of the station, so hourly never misses one; a broadcast
    -- already held with the same tracklist is stepped over, not rewritten.
    perform cron.schedule(
        'indigo-lotradio-fresh',
        '37 * * * *',
        $job$select public.enqueue_enrichment_job(
            'lotradio', 'discover_lotradio', 'fresh',
            jsonb_build_object('mode', 'fresh'), 5, null, null)$job$);

    -- And the archive, one page of thirty-two every ten minutes: one request
    -- to the station each time, about 3,600 broadcasts in under a day. Deduped
    -- on the key, so a page still waiting is never queued twice and the cursor
    -- has one writer. Once the walk reaches the end the job finds nothing to
    -- do and says so in one query.
    perform cron.schedule(
        'indigo-lotradio-backfill',
        '*/10 * * * *',
        $job$select public.enqueue_enrichment_job(
            'lotradio', 'discover_lotradio', 'backfill',
            jsonb_build_object('mode', 'backfill'), 0, null, null)$job$);

    return 'indigo-lotradio-fresh, indigo-lotradio-backfill';
end $$;

-- Added to the umbrella, carrying 0032's composition forward unchanged, so a
-- project set up from scratch gets this alongside everything else.
create or replace function public.schedule_scene_rosters()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;

    perform cron.schedule(
        'indigo-resume-scenes',
        '*/10 * * * *',
        $job$select public.resume_scene_rosters(4)$job$);
    scheduled := array_append(scheduled, 'indigo-resume-scenes');

    perform cron.schedule(
        'indigo-seed-scenes',
        '41 3 * * *',
        $job$select public.seed_scene_rosters()$job$);
    scheduled := array_append(scheduled, 'indigo-seed-scenes');

    scheduled := array_append(scheduled, public.schedule_nts_retag());
    scheduled := array_append(scheduled, public.schedule_scene_radio_fill());
    scheduled := array_append(scheduled, public.schedule_artist_origins());
    scheduled := array_append(scheduled, public.schedule_artist_portraits());
    scheduled := array_append(scheduled, public.schedule_track_releases());
    scheduled := array_append(scheduled, public.schedule_nts_hosts());
    scheduled := array_append(scheduled, public.schedule_release_cache());
    scheduled := array_append(scheduled, public.schedule_artist_merge());
    scheduled := array_append(scheduled, public.schedule_claim_reclaim());
    scheduled := array_append(scheduled, public.schedule_artist_relabel());
    scheduled := array_append(scheduled, public.schedule_lotradio());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

-- The drain that is already running, if there is one. One that never
-- scheduled it is left alone: nothing would drain the jobs this puts up.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_lotradio();
    end if;
end $$;
