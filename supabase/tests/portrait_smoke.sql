-- Smoke test for server-side portraits.
--
-- This one exists because the whole feature is invisible when it goes wrong.
-- A queue that re-asks about an artist Discogs has no picture of just spends
-- the budget quietly forever; a read path that matches on the wrong spelling
-- of a name returns nothing and the app falls back to exactly the per-listener
-- fill this replaces, with nobody any the wiser.
--
--     psql -f supabase/tests/portrait_smoke.sql
--
-- Every check raises on failure, so a clean run means a clean run.

\set ON_ERROR_STOP on
begin;

insert into public.artists (name, normalized_name) values
    ('Purelink', 'purelink'),
    ('Skee Mask', 'skee mask'),
    ('Nobody Plays This One', 'nobody plays this one');

-- Radio evidence, which is what decides who is worth asking about.
insert into public.radio_shows (title, station, provider, external_id)
values ('Test Show', 'nts', 'nts', 'test-show');

insert into public.radio_episodes (radio_show_id, provider, external_id, aired_at)
select id, 'nts', 'test-show/1', now() from public.radio_shows where external_id = 'test-show';

-- Shaped the way production writes it: resolved to an artist and never to a
-- recording. This fixture used to fill both links, and 0019's query passed it
-- while finding nobody at all in the real tables, where not one of 65,671
-- appearances has a recording_id. See migration 0020.
insert into public.radio_appearances (radio_episode_id, artist_id, track_index)
select e.id, a.id, 1
from public.radio_episodes e, public.artists a
where e.external_id = 'test-show/1' and a.normalized_name = 'purelink';

do $$
declare
    queued int;
    purelink uuid;
    answer jsonb;
begin
    select id into purelink from public.artists where normalized_name = 'purelink';

    -- Played on radio and has no picture, so it is asked about.
    queued := public.enqueue_artist_portraits(20);
    if queued < 1 then
        raise exception 'an artist with radio plays and no portrait should be queued';
    end if;
    if not exists (
        select 1 from public.enrichment_jobs
        where job_type = 'fetch_artist_portrait' and dedupe_key = purelink::text
    ) then
        raise exception 'the wrong artist was queued';
    end if;

    -- An artist nobody has played is not worth a request. The artist table is
    -- everybody who ever appeared on a tracklist.
    if exists (
        select 1 from public.enrichment_jobs j
        join public.artists a on a.id::text = j.dedupe_key
        where j.job_type = 'fetch_artist_portrait'
          and a.normalized_name = 'nobody plays this one'
    ) then
        raise exception 'an unplayed artist should not be queued';
    end if;

    -- Already queued, so a second pass adds nothing. Without this the cron job
    -- would enqueue the same name every ten minutes forever.
    if public.enqueue_artist_portraits(20) <> 0 then
        raise exception 'a pending job should not be queued twice';
    end if;

    -- A found picture.
    perform public.record_artist_portrait(purelink, 'https://img.test/purelink.jpg', 150, 150);
    if not exists (
        select 1 from public.artwork
        where entity_type = 'artist' and entity_id = purelink
          and original_url = 'https://img.test/purelink.jpg'
    ) then
        raise exception 'the portrait was not recorded';
    end if;

    -- Read back by the name the app asks with, not by id.
    answer := public.portraits_for_artists(array['purelink', 'skee mask']);
    if (answer ->> 'purelink') <> 'https://img.test/purelink.jpg' then
        raise exception 'portraits_for_artists missed a portrait it has: %', answer;
    end if;
    -- An artist with no picture is absent rather than null, so the app knows
    -- to look it up itself.
    if answer ? 'skee mask' then
        raise exception 'an artist with no portrait should not be in the answer: %', answer;
    end if;

    -- A recorded miss. This is the half that stops the budget leaking: an
    -- artist Discogs has no picture of must not come round again next pass.
    delete from public.enrichment_jobs where job_type = 'fetch_artist_portrait';
    perform public.record_artist_portrait(
        (select id from public.artists where normalized_name = 'purelink'), null);

    if public.enqueue_artist_portraits(20) <> 0 then
        raise exception 'a recorded miss should not be asked about again today';
    end if;

    -- But it is worth another try eventually. A catalogue gains pictures.
    update public.artwork
       set fetched_at = now() - public.artist_portrait_lifetime() - interval '1 day'
     where entity_type = 'artist' and entity_id = purelink;

    if public.enqueue_artist_portraits(20) <> 1 then
        raise exception 'a miss older than its lifetime should be asked about again';
    end if;

    -- An empty set is an empty answer rather than an error.
    if public.portraits_for_artists(array[]::text[]) <> '{}'::jsonb then
        raise exception 'no names should mean no portraits';
    end if;

    raise notice 'portrait smoke: all checks passed';
end $$;

rollback;
