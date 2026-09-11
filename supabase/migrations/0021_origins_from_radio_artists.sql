-- Artist origins, reading radio the way radio is actually written.
--
-- 0017 found the artists worth placing, and the scenes they name, by walking
-- artists -> recordings -> radio_appearances. In production that walk finds
-- nobody. No radio appearance carries a recording_id and no recording carries
-- an artist_id: an appearance resolves straight to an artist, which is what
-- `dig_radio_for_artists` in 0010 has always joined on. So the origin queue
-- ran every quarter hour and found no one — not one of 40,108 artists had an
-- origin_checked_at — and place-and-sound scenes never had a place to be named
-- after. 0020 fixed the same join in the portrait queue, which copied it from
-- here.
--
-- This is what starts real traffic to MusicBrainz, a volunteer-run service.
-- The queue's own pace is 0017's, unchanged: twenty artists every fifteen
-- minutes. What keeps the requests themselves polite is the worker, which now
-- spaces them a second apart; see `musicbrainz.ts`.
--
-- The smoke fixture that let the old join pass gave its appearances recordings
-- instead of artists. It is now shaped like the real tables.
--
-- Safe to re-run.

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
        join public.radio_appearances ap on ap.artist_id = a.id
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
        join public.radio_appearances ap on ap.artist_id = a.id
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
