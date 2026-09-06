-- Give the crawler something to crawl without anybody opening the app.
--
-- `resume_scene_rosters` keeps a roster moving and `request_scene_roster`
-- starts one when a page asks — so between them, nothing happens on a project
-- nobody is using. The NTS crawler does not have that problem because it seeds
-- itself: `discover_nts` reads an upstream listing and enqueues what it finds.
--
-- Scenes have no such listing. The backend knows artist names from radio
-- tracklists and nothing else about them — `artists.country` exists and nothing
-- fills it, and there is no genre column at all — so it cannot work out that
-- Manchester has a hip hop scene. That is not a gap to paper over with a
-- guess: naming scenes is editorial, which is why the plan this came from
-- lists them by hand rather than deriving them.
--
-- So this is that list. It is a starting shelf, not a definition: everything a
-- listener's own catalogue produces still arrives through
-- `request_scene_roster`, and these are simply worth having in the table before
-- anybody asks.
--
-- Safe to re-run: seeding an existing roster leaves it alone.

-- A scene can be a sound with no place — Fourth World is not from anywhere,
-- and neither is spiritual jazz. Both halves cannot be empty.
alter table public.scene_rosters alter column place drop not null;
alter table public.scene_rosters alter column place_key set default '';

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'scene_rosters_address_check') then
        alter table public.scene_rosters add constraint scene_rosters_address_check
            check (coalesce(place_key, '') <> '' or coalesce(sound_key, '') <> '');
    end if;
end $$;

-- Adds a scene to the shelf without disturbing one already there.
create or replace function public.seed_scene_roster(
    p_place text,
    p_place_key text,
    p_sound text,
    p_sound_key text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_place_key text := trim(coalesce(p_place_key, ''));
    v_sound_key text := trim(coalesce(p_sound_key, ''));
begin
    if v_place_key = '' and v_sound_key = '' then return false; end if;

    insert into public.scene_rosters (place, place_key, sound, sound_key)
    values (nullif(p_place, ''), v_place_key, nullif(p_sound, ''), v_sound_key)
    on conflict (place_key, sound_key) do nothing;

    return found;
end $$;

revoke all on function public.seed_scene_roster(text, text, text, text) from public;
grant execute on function public.seed_scene_roster(text, text, text, text) to service_role;

-- The shelf.
--
-- Chosen for the music Indigo is about rather than for coverage: these are the
-- clusters independent radio actually plays through, and the ones a listener
-- digging here is most likely to walk into. The keys are written out because
-- there is no normalizer in SQL — see `request_scene_roster` for why — and
-- these are all plain lowercase ASCII, which is what that normalizer produces.
create or replace function public.seed_scene_rosters()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_added int := 0;
    v_row record;
begin
    for v_row in
        select * from (values
            -- Sounds with no particular home.
            (null, '', 'Fourth World', 'fourth world'),
            (null, '', 'Spiritual Jazz', 'spiritual jazz'),
            (null, '', 'Ambient', 'ambient'),
            (null, '', 'Drone', 'drone'),
            (null, '', 'Dub Techno', 'dub techno'),
            (null, '', 'Musique Concrète', 'musique concrete'),
            (null, '', 'Free Improvisation', 'free improvisation'),
            (null, '', 'New Age', 'new age'),
            (null, '', 'Library Music', 'library music'),
            (null, '', 'Field Recording', 'field recording'),
            -- And the places that have one.
            ('Berlin', 'berlin', 'Dub Techno', 'dub techno'),
            ('Berlin', 'berlin', 'Ambient', 'ambient'),
            ('Detroit', 'detroit', 'Techno', 'techno'),
            ('Chicago', 'chicago', 'House', 'house'),
            ('Bristol', 'bristol', 'Dub', 'dub'),
            ('Manchester', 'manchester', 'Hip Hop', 'hip hop'),
            ('London', 'london', 'Jazz', 'jazz'),
            ('London', 'london', 'Grime', 'grime'),
            ('New York', 'new york', 'Jazz', 'jazz'),
            ('New York', 'new york', 'No Wave', 'no wave'),
            ('Tokyo', 'tokyo', 'Ambient', 'ambient'),
            ('Japan', 'japan', 'Environmental', 'environmental'),
            ('Italy', 'italy', 'Library Music', 'library music'),
            ('Bristol', 'bristol', 'Trip Hop', 'trip hop'),
            ('Glasgow', 'glasgow', 'Electronic', 'electronic'),
            ('Lisbon', 'lisbon', 'Batida', 'batida'),
            ('Kingston', 'kingston', 'Dub', 'dub'),
            ('Cologne', 'cologne', 'Minimal', 'minimal')
        ) as t(place, place_key, sound, sound_key)
    loop
        if public.seed_scene_roster(
            v_row.place, v_row.place_key, v_row.sound, v_row.sound_key
        ) then
            v_added := v_added + 1;
        end if;
    end loop;
    return v_added;
end $$;

revoke all on function public.seed_scene_rosters() from public;
grant execute on function public.seed_scene_rosters() to service_role;

-- MARK: - On the timer

-- Seeding is idempotent and cheap — it inserts rows and enqueues nothing — so
-- it runs daily rather than being a thing somebody has to remember. What
-- actually walks these is `resume_scene_rosters`, which already picks up
-- anything pending.
create or replace function public.schedule_scene_seeding()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;
    perform cron.schedule(
        'indigo-seed-scenes',
        '41 3 * * *',
        $job$select public.seed_scene_rosters()$job$);
    return 'indigo-seed-scenes';
end $$;

-- Folded into the one switch, the way 0012 did.
create or replace function public.schedule_scene_rosters()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;

    perform cron.schedule(
        'indigo-resume-scenes',
        '*/10 * * * *',
        $job$select public.resume_scene_rosters(4)$job$);

    perform public.schedule_scene_seeding();

    -- Put the shelf up now rather than at three tomorrow morning, so a project
    -- that has just been switched on has something to crawl tonight.
    perform public.seed_scene_rosters();

    return 'indigo-resume-scenes, indigo-seed-scenes';
end $$;

-- MARK: - The one switch

-- Redefined again, as 0007, 0008, 0009 and 0012 each did: a migration already
-- applied is history. Carried forward from 0012 with one line changed — the
-- scene jobs are named from what scheduling them returned.

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
