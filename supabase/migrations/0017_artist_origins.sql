-- Where an artist is from, asked one artist at a time.
--
-- Scenes are a place and a sound. Radio supplies the sound for nothing —
-- an artist played across shows filed as dub techno is dub techno — and
-- supplies no place at all: an episode's location is the studio it went out
-- from, not the home of anybody on it.
--
-- So the place has to come from a catalogue, and the only one that carries it
-- per artist is MusicBrainz. What changes here is the question. Asking "who is
-- in New York jazz" is a search whose quality nobody can check and whose
-- results arrive a hundred at a time; asking "where is Basic Channel from" is
-- a lookup about a name we already hold, and the answer is either right or
-- absent. The second is a far better use of a slow upstream, and it turns a
-- scene into something derived from data we own rather than something fetched.
--
-- Safe to re-run.

alter table public.artists add column if not exists area text;
-- Folded, so a scene can be found by the same word that named it.
alter table public.artists add column if not exists area_key text;
alter table public.artists add column if not exists began_year int;
alter table public.artists add column if not exists musicbrainz_id text;
-- When the lookup last ran, whatever it found. Null means never asked; a
-- timestamp with no area means asked and not known, which is a different thing
-- and must not be asked again every twenty minutes.
alter table public.artists add column if not exists origin_checked_at timestamptz;

create index if not exists artists_area_idx on public.artists(area_key)
    where area_key is not null;

-- MARK: - Writing one

create or replace function public.record_artist_origin(
    p_artist_id uuid,
    p_area text,
    p_area_key text,
    p_country text,
    p_began int,
    p_mbid text
)
returns void
language sql
security definer
set search_path = public
as $$
    update public.artists
    set area = coalesce(nullif(p_area, ''), area),
        area_key = coalesce(nullif(p_area_key, ''), area_key),
        country = coalesce(nullif(p_country, ''), country),
        began_year = coalesce(p_began, began_year),
        musicbrainz_id = coalesce(nullif(p_mbid, ''), musicbrainz_id),
        origin_checked_at = now()
    where id = p_artist_id;
$$;

revoke all on function public.record_artist_origin(uuid, text, text, text, int, text) from public;
grant execute on function public.record_artist_origin(uuid, text, text, text, int, text)
    to service_role;

-- MARK: - Asking for the ones worth asking about

-- How long before an artist nobody could place is asked about again. Long: a
-- name MusicBrainz does not know today it will very likely not know next week,
-- and the point of recording the attempt is to stop paying for it.
create or replace function public.artist_origin_lifetime()
returns interval language sql immutable as $$ select interval '90 days' $$;

-- Queues origin lookups, most-played first.
--
-- Radio is what decides who is worth asking about. An artist independent radio
-- has played is one somebody may well dig into; the rest of the artist table is
-- everybody who ever appeared on a tracklist, and asking about all of them
-- would spend a slow upstream on names nobody will look for.
create or replace function public.enqueue_artist_origins(p_limit int default 20)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 20), 200));
begin
    for v_row in
        select a.id, a.name, count(*) as plays
        from public.artists a
        join public.recordings r on r.artist_id = a.id
        join public.radio_appearances ap on ap.recording_id = r.id
        where a.area_key is null
          and (
              a.origin_checked_at is null
              or a.origin_checked_at < now() - public.artist_origin_lifetime()
          )
          and coalesce(btrim(a.name), '') <> ''
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'musicbrainz'
                and j.job_type = 'fetch_artist_origin'
                and j.dedupe_key = a.id::text
                and j.status in ('pending', 'running')
          )
        group by a.id, a.name
        order by count(*) desc, a.name
        limit v_limit
    loop
        perform public.enqueue_enrichment_job(
            'musicbrainz',
            'fetch_artist_origin',
            v_row.id::text,
            jsonb_build_object('artist_id', v_row.id, 'name', v_row.name),
            -- Below the live radio crawl, above nothing. These are what make
            -- place-and-sound scenes possible at all.
            -1,
            'artist',
            v_row.id
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.enqueue_artist_origins(int) from public;
grant execute on function public.enqueue_artist_origins(int) to service_role;

-- MARK: - Scenes the artists themselves describe

-- Places crossed with the sounds radio plays their artists under.
--
-- This is the one that was missing. Every other seeder names a scene from a
-- station's own words; this names one from where the people are actually from,
-- which is what a scene is usually understood to mean. It needs both halves —
-- origins from the lookups above, sounds from the tracklists — and produces
-- nothing until some of each has landed.
create or replace function public.seed_scenes_from_artist_areas(p_limit int default 40)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_added int := 0;
begin
    for v_row in
        select a.area, a.area_key, tag.genre, count(distinct a.id) as artists
        from public.artists a
        join public.recordings r on r.artist_id = a.id
        join public.radio_appearances ap on ap.recording_id = r.id
        join public.radio_episodes e on e.id = ap.radio_episode_id
        cross join lateral unnest(e.genres || e.moods) as tag(genre)
        where coalesce(a.area_key, '') <> ''
          and coalesce(btrim(tag.genre), '') <> ''
        group by a.area, a.area_key, tag.genre
        -- Two artists from one place playing one sound is the smallest thing
        -- that is a scene rather than a person.
        having count(distinct a.id) >= 2
        order by count(distinct a.id) desc, a.area_key, tag.genre
        limit greatest(1, least(coalesce(p_limit, 40), 200))
    loop
        if public.seed_scene_roster(
            v_row.area, v_row.area_key, btrim(v_row.genre), lower(btrim(v_row.genre))
        ) then
            v_added := v_added + 1;
        end if;
    end loop;
    return v_added;
end $$;

revoke all on function public.seed_scenes_from_artist_areas(int) from public;
grant execute on function public.seed_scenes_from_artist_areas(int) to service_role;

-- MARK: - On the timer

create or replace function public.schedule_artist_origins()
returns text
language plpgsql
as $$
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
        '*/15 * * * *',
        $job$select public.enqueue_artist_origins(20)$job$);
    return 'indigo-artist-origins';
end $$;

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
            (null, '', 'Fourth World', 'fourth world'),
            (null, '', 'Spiritual Jazz', 'spiritual jazz'),
            (null, '', 'Musique Concrète', 'musique concrete'),
            (null, '', 'Free Improvisation', 'free improvisation'),
            (null, '', 'Library Music', 'library music'),
            (null, '', 'Field Recording', 'field recording'),
            ('Berlin', 'berlin', 'Dub Techno', 'dub techno'),
            ('Detroit', 'detroit', 'Techno', 'techno'),
            ('Chicago', 'chicago', 'House', 'house'),
            ('Bristol', 'bristol', 'Dub', 'dub'),
            ('Manchester', 'manchester', 'Hip Hop', 'hip hop'),
            ('New York', 'new york', 'No Wave', 'no wave'),
            ('Japan', 'japan', 'Environmental', 'environmental'),
            ('Italy', 'italy', 'Library Music', 'library music'),
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

    -- What the stations describe.
    v_added := v_added + public.seed_scenes_from_radio();
    -- And what the artists themselves do: where they are from, crossed with
    -- what radio plays them under. The only seeder here that means "a scene"
    -- in the way somebody would say it out loud.
    v_added := v_added + public.seed_scenes_from_artist_areas();

    return v_added;
end $$;

revoke all on function public.seed_scene_rosters() from public;
grant execute on function public.seed_scene_rosters() to service_role;

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

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;
