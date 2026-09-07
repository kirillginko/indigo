-- Let the stations name the scenes.
--
-- The shelf 0013 put up is editorial: a list written by hand because the
-- backend had no way to work out that Manchester has a hip hop scene. It knew
-- artist names from tracklists and nothing else — no genre column anywhere, and
-- an `artists.country` that nothing fills.
--
-- Except it was being told, and throwing it away. Every NTS episode carries the
-- genres and moods the station files it under and the city it was broadcast
-- from, and the ingest read past all three. That is the listing scenes never
-- had: not somebody's opinion about what a scene is, but what independent radio
-- itself says it plays and where from.
--
-- Safe to re-run.

-- MARK: - Keep what the station said

alter table public.radio_episodes add column if not exists genres text[] not null default '{}';
alter table public.radio_episodes add column if not exists moods text[] not null default '{}';
alter table public.radio_episodes add column if not exists location text;

create index if not exists radio_episodes_genres_idx
    on public.radio_episodes using gin (genres);

-- MARK: - Read the scenes out of it

-- How often a sound has to turn up before it is a scene rather than one show's
-- description. Low, because independent radio is specific by nature — a genre
-- used on three separate broadcasts is a real strand of programming, and the
-- interesting ones are rarely the common ones.
create or replace function public.scene_seed_threshold()
returns int language sql immutable as $$ select 3 $$;

-- Scenes the stations have described, as rosters.
--
-- Two shapes, matching what a scene is. A genre used often enough anywhere is a
-- sound worth crawling on its own; a genre used often enough *from one city* is
-- a place and a sound, which is the stronger claim and the reason the location
-- is worth keeping.
--
-- Normalization is done here with `lower`, which is not the app's normalizer
-- and does not need to be: these keys are only ever compared against other keys
-- made the same way, and the app's own scenes arrive through
-- `request_scene_roster` already folded. What matters is that "Dub Techno" and
-- "dub techno" are one roster, and lower does that.
create or replace function public.seed_scenes_from_radio(p_limit int default 40)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_added int := 0;
    v_row record;
    v_limit int := greatest(1, least(coalesce(p_limit, 40), 200));
begin
    -- Sounds, wherever they were played.
    for v_row in
        select genre, count(*) as uses
        from (
            select unnest(genres) as genre from public.radio_episodes
            union all
            select unnest(moods) as genre from public.radio_episodes
        ) as tagged
        where btrim(genre) <> ''
        group by genre
        having count(*) >= public.scene_seed_threshold()
        order by count(*) desc, genre
        limit v_limit
    loop
        if public.seed_scene_roster(
            null, '', btrim(v_row.genre), lower(btrim(v_row.genre))
        ) then
            v_added := v_added + 1;
        end if;
    end loop;

    -- And sounds that belong to a city.
    for v_row in
        select location, genre, count(*) as uses
        from (
            select location, unnest(genres) as genre
            from public.radio_episodes
            where coalesce(btrim(location), '') <> ''
        ) as placed
        where btrim(genre) <> ''
        group by location, genre
        having count(*) >= public.scene_seed_threshold()
        order by count(*) desc, location, genre
        limit v_limit
    loop
        if public.seed_scene_roster(
            btrim(v_row.location), lower(btrim(v_row.location)),
            btrim(v_row.genre), lower(btrim(v_row.genre))
        ) then
            v_added := v_added + 1;
        end if;
    end loop;

    return v_added;
end $$;

revoke all on function public.seed_scenes_from_radio(int) from public;
grant execute on function public.seed_scenes_from_radio(int) to service_role;

-- MARK: - On the timer

-- Folded into the nightly seed rather than given a job of its own: the two
-- answer the same question and one of them is a list that never changes.
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

    -- The stations have far more to say than the list above, and they keep
    -- saying more. Whatever they have described since the last pass is added
    -- to the shelf.
    v_added := v_added + public.seed_scenes_from_radio();

    return v_added;
end $$;

revoke all on function public.seed_scene_rosters() from public;
grant execute on function public.seed_scene_rosters() to service_role;
