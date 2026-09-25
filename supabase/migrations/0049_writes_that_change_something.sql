-- Stop spending the disk budget on writes that change nothing.
--
-- Supabase warned the project was about to exhaust its Disk IO budget, after
-- which throughput falls to 5 MB/s. pg_stat_statements, since 3 September:
--
--   rebuild_radio_dig_edges   490 calls  24 GB read  37 GB written  9.5 GB temp
--   fill_scenes_from_radio    683 calls   2 GB read   6 GB written
--   enqueue_artist_portraits 2050 calls   4 GB read               1.3 GB temp
--   enqueue_artist_origins   1367 calls  0.6 GB read              1.3 GB temp
--
-- The writes are the tell. The graph rebuild upserted every edge every hour
-- with `on conflict do update ... where (...) is distinct from (...)`, which
-- 0037 added so unchanged edges would not be rewritten. They were not
-- rewritten -- but ON CONFLICT DO UPDATE locks the conflicting row even when
-- its WHERE is false, and taking the lock writes the row's page. So every
-- hourly run still dirtied the whole table: about 75 MB, written, to change
-- nothing. The scene fill's upsert had no guard at all, and rewrote every
-- member it matched, every half hour.
--
-- Both now update only the rows whose values differ and insert only the rows
-- that are missing; an unchanged row is not touched. And the scans that feed
-- them run less often: the graph every three hours, scenes every six, the
-- portrait and origin queues hourly with the same throughput per hour.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- The graph
-- ---------------------------------------------------------------------------

create or replace function public.rebuild_radio_dig_edges()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    written int := 0;
begin
    with wanted as materialized (
        -- Artist -> the programmes that play them.
        select
            'artist'::text as from_entity_type, played.artist_id as from_entity_id,
            'radio_show'::text as to_entity_type, played.radio_show_id as to_entity_id,
            'played_by'::text as relationship_type,
            least(0.95, 0.5 + 0.45 * (1 - 1.0 / (1 + played.episodes)))::double precision as confidence,
            'radio'::text as source,
            played.appearances::int as evidence_count,
            jsonb_build_object('episodes', played.episodes, 'appearances', played.appearances) as metadata
        from (
            select ra.artist_id,
                   re.radio_show_id,
                   count(*) as appearances,
                   count(distinct re.id) as episodes
            from public.radio_appearances ra
            join public.radio_episodes re on re.id = ra.radio_episode_id
            where ra.artist_id is not null and re.radio_show_id is not null
            group by ra.artist_id, re.radio_show_id
        ) as played

        union all

        -- Artist <-> artist, played next to each other in a tracklist. Stored
        -- once under the lower uuid: the relationship is symmetric.
        select
            'artist', near.low, 'artist', near.high,
            'radio_neighbor',
            least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + near.adjacencies)))::double precision,
            'radio',
            near.adjacencies::int,
            jsonb_build_object('adjacencies', near.adjacencies, 'episodes', near.episodes)
        from (
            select
                least(a.artist_id, b.artist_id) as low,
                greatest(a.artist_id, b.artist_id) as high,
                count(*) as adjacencies,
                count(distinct a.radio_episode_id) as episodes
            from public.radio_appearances a
            join public.radio_appearances b
                on b.radio_episode_id = a.radio_episode_id
               and b.track_index = a.track_index + 1
            where a.artist_id is not null
              and b.artist_id is not null
              and a.artist_id <> b.artist_id
            group by least(a.artist_id, b.artist_id), greatest(a.artist_id, b.artist_id)
        ) as near
    ),
    -- Only the edges whose evidence moved. Everything else is left as it is,
    -- unlocked and unwritten.
    changed as (
        update public.music_relationships m
        set confidence = w.confidence,
            evidence_count = w.evidence_count,
            metadata = w.metadata,
            updated_at = now()
        from wanted w
        where m.from_entity_type = w.from_entity_type
          and m.from_entity_id = w.from_entity_id
          and m.to_entity_type = w.to_entity_type
          and m.to_entity_id = w.to_entity_id
          and m.relationship_type = w.relationship_type
          and (m.confidence, m.evidence_count, m.metadata)
              is distinct from (w.confidence, w.evidence_count, w.metadata)
        returning 1
    ),
    -- And the ones that did not exist. DO NOTHING, never DO UPDATE: it does
    -- not lock, and a row it finds already there was written by somebody
    -- else a moment ago.
    added as (
        insert into public.music_relationships (
            from_entity_type, from_entity_id, to_entity_type, to_entity_id,
            relationship_type, confidence, source, evidence_count, metadata)
        select w.from_entity_type, w.from_entity_id, w.to_entity_type, w.to_entity_id,
               w.relationship_type, w.confidence, w.source, w.evidence_count, w.metadata
        from wanted w
        where not exists (
            select 1 from public.music_relationships m
            where m.from_entity_type = w.from_entity_type
              and m.from_entity_id = w.from_entity_id
              and m.to_entity_type = w.to_entity_type
              and m.to_entity_id = w.to_entity_id
              and m.relationship_type = w.relationship_type)
        on conflict do nothing
        returning 1
    )
    select (select count(*) from changed) + (select count(*) from added) into written;

    return written;
end $$;

revoke all on function public.rebuild_radio_dig_edges() from public, anon, authenticated;
grant execute on function public.rebuild_radio_dig_edges() to service_role;

-- ---------------------------------------------------------------------------
-- Scenes
-- ---------------------------------------------------------------------------

create or replace function public.fill_scene_from_radio(p_roster_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_roster public.scene_rosters%rowtype;
    v_added int := 0;
begin
    select * into v_roster from public.scene_rosters where id = p_roster_id;
    if not found or coalesce(v_roster.sound_key, '') = '' then
        -- A place with no sound cannot be read out of a genre list.
        return 0;
    end if;

    with tagged as (
        select e.id
        from public.radio_episodes e
        where exists (
            select 1
            from unnest(e.genres || e.moods) as tag
            where lower(btrim(tag)) = v_roster.sound_key
        )
        -- A roster naming a place reads as the shows that went out from it.
        and (
            coalesce(v_roster.place_key, '') = ''
            or lower(btrim(coalesce(e.location, ''))) = v_roster.place_key
        )
    ),
    played as (
        select
            a.normalized_artist_name as key,
            min(a.raw_artist_name) as name,
            count(distinct a.radio_episode_id)::int as plays
        from public.radio_appearances a
        join tagged t on t.id = a.radio_episode_id
        where coalesce(a.normalized_artist_name, '') <> ''
        group by a.normalized_artist_name
        having count(distinct a.radio_episode_id) >= public.scene_member_play_threshold()
    ),
    -- Raised only where the radio count is higher than what is held. A name
    -- the crawler already found keeps its own source: it was put there by a
    -- catalogue that knows more about it than a tracklist does.
    raised as (
        update public.scene_members m
        set plays = greatest(m.plays, p.plays),
            score = greatest(m.score, p.plays)
        from played p
        where m.roster_id = p_roster_id
          and m.normalized_name = p.key
          and (greatest(m.plays, p.plays), greatest(m.score, p.plays))
              is distinct from (m.plays, m.score)
        returning 1
    ),
    added as (
        insert into public.scene_members
            (roster_id, name, normalized_name, source, plays, score)
        select p_roster_id, coalesce(p.name, p.key), p.key, 'radio', p.plays, p.plays
        from played p
        where not exists (
            select 1 from public.scene_members m
            where m.roster_id = p_roster_id and m.normalized_name = p.key)
        on conflict do nothing
        returning 1
    )
    select (select count(*) from raised) + (select count(*) from added) into v_added;

    -- The count only when it moved: rewriting the same number is still a
    -- write.
    if v_added > 0 then
        update public.scene_rosters r
        set member_count = c.n
        from (select count(*)::int as n from public.scene_members where roster_id = p_roster_id) c
        where r.id = p_roster_id
          and r.member_count is distinct from c.n;
    end if;

    return v_added;
end $$;

revoke all on function public.fill_scene_from_radio(uuid) from public, anon, authenticated;
grant execute on function public.fill_scene_from_radio(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- How often
-- ---------------------------------------------------------------------------

-- The schedule functions are redefined, not only the jobs, so running the
-- setup again cannot put the old cadence back. Each is the live definition
-- with its timing changed and nothing else.

CREATE OR REPLACE FUNCTION public.schedule_indigo_enrichment()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
        '23 */3 * * *',
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
end $function$;

CREATE OR REPLACE FUNCTION public.schedule_artist_portraits()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Twenty every ten minutes is a hundred and twenty an hour against a
    -- budget of sixty a minute, which leaves the credential almost entirely
    -- free. There is no hurry: nobody is waiting, and the backlog only has to
    -- be walked once for everybody rather than once per listener.
    perform cron.schedule(
        'indigo-artist-portraits',
        '7 * * * *',
        $job$select public.enqueue_artist_portraits(120)$job$);
    scheduled := array_append(scheduled, 'indigo-artist-portraits');

    -- Addressed and authorised exactly as the main drain is, out of the vault.
    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-portraits',
            '2-59/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30, 'job_type', 'fetch_artist_portrait')
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-portraits');
    end if;

    return array_to_string(scheduled, ', ');
end $function$;

CREATE OR REPLACE FUNCTION public.schedule_artist_origins()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;
    -- Twenty every fifteen minutes: about 1,900 a day, sharing a drain with
    -- the archive crawl and the retag pass. It empties itself — once an artist
    -- has been asked about, they are not asked again for ninety days whether
    -- or not the answer was useful.
    perform cron.schedule(
        'indigo-artist-origins',
        '37 * * * *',
        $job$select public.enqueue_artist_origins(80)$job$);
    return 'indigo-artist-origins';
end $function$;

CREATE OR REPLACE FUNCTION public.schedule_scene_radio_fill()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;
    -- Every half hour. It reads what has been ingested since, and nothing it
    -- does leaves the database.
    perform cron.schedule(
        'indigo-scene-radio-fill',
        '13 */6 * * *',
        $job$select public.fill_scenes_from_radio(60)$job$);
    return 'indigo-scene-radio-fill';
end $function$;

-- Applied now, where the jobs exist.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-rebuild-edges') then
        perform cron.schedule('indigo-rebuild-edges', '23 */3 * * *',
            $job$select public.rebuild_radio_dig_edges()$job$);
        perform cron.schedule('indigo-scene-radio-fill', '13 */6 * * *',
            $job$select public.fill_scenes_from_radio(60)$job$);
        perform cron.schedule('indigo-artist-portraits', '7 * * * *',
            $job$select public.enqueue_artist_portraits(120)$job$);
        perform cron.schedule('indigo-artist-origins', '37 * * * *',
            $job$select public.enqueue_artist_origins(80)$job$);
    end if;
end $$;
