-- Fill a scene from what the stations played in it.
--
-- The roster crawl asks MusicBrainz who is in a scene. Independent radio has
-- already answered a version of that question and the answer is sitting in
-- these tables: an episode carries the genres the station files it under, and
-- its tracklist carries who was played. An artist turning up repeatedly across
-- shows filed as dub techno is dub techno, on better evidence than a
-- catalogue tag — somebody chose to play them there.
--
-- No upstream request at all. This is one aggregate over two indexed tables,
-- which is the whole reason it is worth having beside a crawler that has to
-- ask permission a page at a time.
--
-- What it deliberately does not claim is where anybody is from. An episode's
-- location is the studio the show went out from, not the home of the artists
-- on it — a London show plays records from everywhere. So a place-and-sound
-- roster reads here as "played by shows broadcast from there", which is a real
-- thing and a different one, and `source` is what keeps the two apart.
--
-- Safe to re-run.

alter table public.scene_members
    add column if not exists source text not null default 'musicbrainz';
alter table public.scene_members
    add column if not exists plays int not null default 0;

create index if not exists scene_members_source_idx
    on public.scene_members(roster_id, source, plays desc);

-- How many separate broadcasts an artist needs before the radio counts them as
-- part of a scene. Two: once is a selector reaching for something, twice is a
-- pattern, and this is evidence about an artist rather than about a show.
create or replace function public.scene_member_play_threshold()
returns int language sql immutable as $$ select 2 $$;

-- Everybody the stations have played in one scene.
create or replace function public.fill_scene_from_radio(p_roster_id uuid)
returns int
language plpgsql
security definer
set search_path = public
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
        -- See this file's header: that is not where the artists are from.
        and (
            coalesce(v_roster.place_key, '') = ''
            or lower(btrim(coalesce(e.location, ''))) = v_roster.place_key
        )
    ),
    played as (
        select
            a.normalized_artist_name as key,
            min(a.raw_artist_name) as name,
            count(distinct a.radio_episode_id) as plays
        from public.radio_appearances a
        join tagged t on t.id = a.radio_episode_id
        where coalesce(a.normalized_artist_name, '') <> ''
        group by a.normalized_artist_name
        having count(distinct a.radio_episode_id) >= public.scene_member_play_threshold()
    )
    insert into public.scene_members
        (roster_id, name, normalized_name, source, plays, score)
    select
        p_roster_id,
        coalesce(p.name, p.key),
        p.key,
        'radio',
        p.plays,
        p.plays
    from played p
    on conflict (roster_id, normalized_name) do update
        set plays = greatest(public.scene_members.plays, excluded.plays),
            -- A name the crawler already found keeps its own source: it was
            -- put there by a catalogue that knows more about it than a
            -- tracklist does.
            score = greatest(public.scene_members.score, excluded.score);

    get diagnostics v_added = row_count;

    update public.scene_rosters
    set member_count = (
            select count(*) from public.scene_members where roster_id = p_roster_id
        )
    where id = p_roster_id;

    return v_added;
end $$;

revoke all on function public.fill_scene_from_radio(uuid) from public;
grant execute on function public.fill_scene_from_radio(uuid) to service_role;

-- MARK: - Across the shelf

-- Every roster, refreshed from radio.
--
-- Cheap enough to do wholesale rather than a queue at a time: no upstream is
-- involved, and the answer changes every time a tracklist lands.
create or replace function public.fill_scenes_from_radio(p_limit int default 60)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_total int := 0;
begin
    for v_row in
        select id from public.scene_rosters
        where coalesce(sound_key, '') <> ''
        order by coalesce(filled_at, created_at)
        limit greatest(1, least(coalesce(p_limit, 60), 500))
    loop
        v_total := v_total + public.fill_scene_from_radio(v_row.id);
    end loop;
    return v_total;
end $$;

revoke all on function public.fill_scenes_from_radio(int) from public;
grant execute on function public.fill_scenes_from_radio(int) to service_role;

-- MARK: - On the timer

create or replace function public.schedule_scene_radio_fill()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;
    -- Every half hour. It reads what has been ingested since, and nothing it
    -- does leaves the database.
    perform cron.schedule(
        'indigo-scene-radio-fill',
        '13,43 * * * *',
        $job$select public.fill_scenes_from_radio(60)$job$);
    return 'indigo-scene-radio-fill';
end $$;

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

    perform public.seed_scene_rosters();
    -- And read what radio already knows, so a project switched on today has
    -- scenes with people in them before MusicBrainz has been asked anything.
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;
