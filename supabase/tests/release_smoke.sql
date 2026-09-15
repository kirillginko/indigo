-- Smoke test for the records behind a tracklist (0025) and the people playing
-- them (0026).
--
-- Both are write paths with no screen attached. A `record_track_release` that
-- files a second copy of an imprint Discogs already knows makes search offer
-- the listener the same label twice, one of the two with a page behind it; an
-- `adopt_named_artist` that inserts beside an existing row silently breaks
-- `resolve_radio_appearances`, which only ever resolves a name matching exactly
-- one artist. Neither failure raises anything, and neither is visible until
-- somebody notices the catalogue has gone quietly wrong.
--
--     psql -f supabase/tests/release_smoke.sql
--
-- Every check raises on failure, so a clean run means a clean run.

\set ON_ERROR_STOP on
begin;

-- Two shows, one episode each, so "every appearance of this record" has to
-- cross a programme boundary to be worth anything.
insert into public.radio_shows (provider, external_id, station, title)
values ('nts', 'test-a', 'NTS', 'Test A w/ Jane Fitz'),
       ('nts', 'test-b', 'NTS', 'In Focus');

insert into public.radio_episodes (radio_show_id, provider, external_id, aired_at, tracklist_status)
select rs.id, 'nts', rs.external_id || '/1',
       now() - interval '1 day', 'available'
from public.radio_shows rs where rs.provider = 'nts';

insert into public.artists (name, normalized_name) values ('Skee Mask', 'skee mask');

-- An imprint Discogs already filed, to be adopted rather than duplicated.
insert into public.labels (name, normalized_name) values ('Ilian Tape', 'ilian tape');

-- The same record, played on both programmes, plus a line with no identity at
-- all and one already resolved.
insert into public.radio_appearances
    (radio_episode_id, track_index, raw_artist_name, raw_track_title,
     normalized_artist_name, normalized_title, artist_id, deezer_track_id, isrc)
select re.id, 1, 'Skee Mask', 'Flyby VFR', 'skee mask', 'flyby vfr',
       (select id from public.artists where normalized_name = 'skee mask'),
       '111', 'DEAB12345678'
from public.radio_episodes re;

insert into public.radio_appearances
    (radio_episode_id, track_index, raw_artist_name, raw_track_title,
     normalized_artist_name, normalized_title)
select re.id, 2, 'Unknown', 'ID', null, 'id'
from public.radio_episodes re where re.external_id = 'test-a/1';

do $$
declare
    v_queued int;
    v_recording uuid;
    v_second uuid;
    v_label uuid;
    v_release uuid;
    v_artist uuid;
    v_before int;
begin
    -- MARK: queueing

    v_queued := public.enqueue_track_releases(40);
    if v_queued <> 1 then
        raise exception 'one deezer id across two shows is one job, got %', v_queued;
    end if;
    if not exists (
        select 1 from public.enrichment_jobs
        where job_type = 'fetch_track_release' and dedupe_key = '111'
    ) then
        raise exception 'the wrong track was queued';
    end if;

    -- A line with no identity is not a question anyone can ask.
    if (select count(*) from public.enrichment_jobs
        where job_type = 'fetch_track_release') <> 1 then
        raise exception 'a tracklist line with no deezer id was queued anyway';
    end if;

    -- Already waiting, so it is not queued a second time.
    if public.enqueue_track_releases(40) <> 0 then
        raise exception 'the same track was queued twice';
    end if;

    -- MARK: writing down what came back

    v_recording := public.record_track_release(
        p_deezer_track_id := '111',
        p_track_title := 'Flyby VFR',
        p_title_key := 'flyby vfr',
        p_album_title := 'Compro',
        p_deezer_album_id := 'alb-1',
        p_label := 'Ilian Tape',
        p_label_key := 'ilian tape',
        p_release_year := 2018,
        p_isrc := 'DEAB12345678');

    if v_recording is null then
        raise exception 'a resolved track should produce a recording';
    end if;

    -- The imprint Discogs already knew, adopted rather than filed again.
    if (select count(*) from public.labels where normalized_name = 'ilian tape') <> 1 then
        raise exception 'a label that already existed was duplicated';
    end if;
    select id into v_label from public.labels where normalized_name = 'ilian tape';

    select r.id, r.label_id, r.artist_id into v_release, v_label, v_artist
    from public.releases r where r.title = 'Compro';
    if v_release is null then
        raise exception 'no release was filed';
    end if;
    if v_label is null then
        raise exception 'the release was filed without its imprint';
    end if;
    if v_artist is distinct from (select id from public.artists where normalized_name = 'skee mask') then
        raise exception 'the release took its credit from somewhere other than the appearances';
    end if;

    -- Every appearance of the record, on both programmes.
    if (select count(*) from public.radio_appearances
        where deezer_track_id = '111' and recording_id = v_recording) <> 2 then
        raise exception 'the same record on two shows did not both point at it';
    end if;
    if (select count(*) from public.radio_appearances
        where deezer_track_id = '111' and release_checked_at is null) <> 0 then
        raise exception 'a looked-up track was not stamped';
    end if;

    -- Stamped, so the queue leaves it alone now.
    if public.enqueue_track_releases(40) <> 0 then
        raise exception 'a resolved track came back round';
    end if;

    -- MARK: a second track off the same album

    insert into public.radio_appearances
        (radio_episode_id, track_index, raw_artist_name, raw_track_title,
         normalized_artist_name, normalized_title, deezer_track_id)
    select re.id, 3, 'Skee Mask', 'Rev8617', 'skee mask', 'rev8617', '222'
    from public.radio_episodes re where re.external_id = 'test-a/1';

    v_second := public.record_track_release(
        p_deezer_track_id := '222',
        p_track_title := 'Rev8617',
        p_title_key := 'rev8617',
        p_album_title := 'Compro',
        p_deezer_album_id := 'alb-1',
        p_label := 'Ilian Tape',
        p_label_key := 'ilian tape',
        p_release_year := 2018);

    if v_second = v_recording then
        raise exception 'two different tracks became one recording';
    end if;
    if (select count(*) from public.releases where title = 'Compro') <> 1 then
        raise exception 'a second track off one album filed the album twice';
    end if;
    if (select release_id from public.recordings where id = v_second) is distinct from v_release then
        raise exception 'the second recording did not land on the album already filed';
    end if;

    -- Idempotent: the same answer written twice changes nothing.
    if public.record_track_release(
        p_deezer_track_id := '222', p_track_title := 'Rev8617', p_title_key := 'rev8617',
        p_album_title := 'Compro', p_deezer_album_id := 'alb-1',
        p_label := 'Ilian Tape', p_label_key := 'ilian tape') is distinct from v_second then
        raise exception 'writing the same track twice made a second recording';
    end if;
    if (select count(*) from public.releases where title = 'Compro') <> 1
       or (select count(*) from public.labels where normalized_name = 'ilian tape') <> 1 then
        raise exception 'a repeated write duplicated the catalogue';
    end if;

    -- MARK: a track Deezer cannot place

    insert into public.radio_appearances
        (radio_episode_id, track_index, raw_artist_name, raw_track_title,
         normalized_artist_name, normalized_title, deezer_track_id)
    select re.id, 4, 'Nobody', 'Untraceable', 'nobody', 'untraceable', '333'
    from public.radio_episodes re where re.external_id = 'test-a/1';

    v_before := (select count(*) from public.releases);
    if public.record_track_release(p_deezer_track_id := '333') is not null then
        raise exception 'a track with no album should produce no recording';
    end if;
    if (select count(*) from public.releases) <> v_before then
        raise exception 'an unresolved track filed a release anyway';
    end if;
    -- The whole point: it was asked about, and the queue now knows that.
    if (select release_checked_at from public.radio_appearances
        where deezer_track_id = '333') is null then
        raise exception 'a track Deezer could not place was not written down';
    end if;
    if public.enqueue_track_releases(40) <> 0 then
        raise exception 'a track already asked about came back round';
    end if;

    raise notice 'release smoke: writes all checked out';
end $$;

-- ---------------------------------------------------------------------------
-- 0026 — the people playing the records
-- ---------------------------------------------------------------------------

do $$
declare
    v_jane uuid;
    v_again uuid;
    v_before int;
    v_queued int;
begin
    -- A tracklist line naming somebody nobody has catalogued yet, waiting.
    insert into public.radio_appearances
        (radio_episode_id, track_index, raw_artist_name, raw_track_title,
         normalized_artist_name, normalized_title)
    select re.id, 5, 'Jane Fitz', 'Ad Infinitum', 'jane fitz', 'ad infinitum'
    from public.radio_episodes re where re.external_id = 'test-b/1';

    v_jane := public.adopt_named_artist('Jane Fitz', 'jane fitz',
                                        'https://www.nts.live/shows/test-a');
    if v_jane is null then
        raise exception 'a presenter should become an artist';
    end if;

    -- And collects what was waiting for the name.
    if (select artist_id from public.radio_appearances
        where normalized_artist_name = 'jane fitz') is distinct from v_jane then
        raise exception 'adopting a name did not collect the lines waiting for it';
    end if;

    -- Twice is once. Two rows for one presenter would stop
    -- `resolve_radio_appearances` ever resolving that name again.
    v_again := public.adopt_named_artist('Jane Fitz', 'jane fitz');
    if v_again is distinct from v_jane then
        raise exception 'a presenter was adopted twice';
    end if;
    if (select count(*) from public.artists where normalized_name = 'jane fitz') <> 1 then
        raise exception 'a second row was filed for one presenter';
    end if;

    -- Somebody already in the catalogue from a tracklist is the same person,
    -- not a new one.
    if public.adopt_named_artist('Skee Mask', 'skee mask')
       is distinct from (select id from public.artists where normalized_name = 'skee mask') then
        raise exception 'an artist adopted from radio was filed again as a presenter';
    end if;

    -- Nothing to adopt is not an error.
    v_before := (select count(*) from public.artists);
    if public.adopt_named_artist('', '') is not null
       or public.adopt_named_artist('Someone', null) is not null then
        raise exception 'a name with no key was adopted';
    end if;
    if (select count(*) from public.artists) <> v_before then
        raise exception 'an empty name was filed';
    end if;

    -- MARK: going back for the programmes already described

    v_queued := public.requeue_nts_shows(20);
    if v_queued <> 1 then
        raise exception 'only the programme whose title names somebody should be read again, got %', v_queued;
    end if;
    if (select payload->>'alias' from public.enrichment_jobs
        where job_type = 'fetch_nts_show') <> 'test-a' then
        raise exception 'the wrong programme was queued';
    end if;
    if public.requeue_nts_shows(20) <> 0 then
        raise exception 'the same programme was queued twice';
    end if;

    -- MARK: going back for the episodes ingested before the ids were kept

    -- test-a/1 carries a deezer id, so it has already been read by a version
    -- that keeps them. test-b/1 carries one too; give it a slot that does not,
    -- to prove the test is about the episode rather than the row.
    if public.requeue_nts_episodes(20) <> 0 then
        raise exception 'an episode whose lines already carry ids was read again';
    end if;

    update public.radio_appearances set deezer_track_id = null, isrc = null
    where radio_episode_id = (select id from public.radio_episodes where external_id = 'test-b/1');

    if public.requeue_nts_episodes(20) <> 1 then
        raise exception 'an episode with no identities on it should be read again';
    end if;
    if (select payload->>'show' from public.enrichment_jobs
        where job_type = 'fetch_nts_episode') <> 'test-b' then
        raise exception 'the episode was queued without the show it belongs to';
    end if;

    raise notice 'release smoke: all checks passed';
end $$;

-- ---------------------------------------------------------------------------
-- 0027 — the release cache
-- ---------------------------------------------------------------------------

do $$
declare
    v_answer jsonb;
    v_many text[];
    v_queued int;
    v_skee uuid;
begin
    -- MARK: what the app asks for

    -- A cached release is not asked about again; an uncached one is queued.
    insert into public.metadata_cache (provider, resource_type, resource_id, payload, fetched_at)
    values ('discogs', 'release', '111111', '{"id":111111}'::jsonb, now());

    v_answer := public.request_release_cache(array['111111', '222222']);
    if (v_answer->>'cached')::int <> 1 or (v_answer->>'queued')::int <> 1 then
        raise exception 'a warm id and a cold id should be told apart: %', v_answer;
    end if;
    if not exists (
        select 1 from public.enrichment_jobs
        where job_type = 'cache_discogs_release' and dedupe_key = '222222'
    ) then
        raise exception 'the cold release was not queued';
    end if;

    -- A release cached long ago is cold again.
    update public.metadata_cache set fetched_at = now() - interval '200 days'
    where resource_id = '111111';
    v_answer := public.request_release_cache(array['111111']);
    if (v_answer->>'queued')::int <> 1 then
        raise exception 'a release cached beyond its lifetime should be asked for again';
    end if;

    -- Anything that is not digits is refused. The id goes into a URL the
    -- worker builds, and this is the app's key calling.
    v_answer := public.request_release_cache(
        array['../../etc', '12 34', '', 'releases/9', '1234567890123']);
    if (v_answer->>'queued')::int <> 0 then
        raise exception 'a release id that is not digits was accepted: %', v_answer;
    end if;

    -- Named twice in one call is once.
    v_answer := public.request_release_cache(array['333333', '333333', '333333']);
    if (v_answer->>'queued')::int <> 1 then
        raise exception 'one id named three times should be one job: %', v_answer;
    end if;

    -- Bounded. A page shows two dozen tiles; anything past fifty is not a page.
    select array_agg((400000 + g)::text) into v_many from generate_series(1, 80) g;
    v_answer := public.request_release_cache(v_many);
    if (v_answer->>'queued')::int > 50 then
        raise exception 'more than fifty releases were accepted in one call: %', v_answer;
    end if;

    -- Null is not an error, it is nothing to do.
    if public.request_release_cache(null) is null then
        raise exception 'a null list should answer, not fail';
    end if;

    -- MARK: the shelves worth having ready

    select id into v_skee from public.artists where normalized_name = 'skee mask';

    -- No Discogs id, so there is no shelf to walk.
    if public.enqueue_shelf_releases(5) <> 0 then
        raise exception 'an artist with no discogs id has no shelf';
    end if;

    insert into public.external_ids (entity_type, entity_id, provider, external_id)
    values ('artist', v_skee, 'discogs', '12345');

    v_queued := public.enqueue_shelf_releases(5);
    if v_queued <> 1 then
        raise exception 'an artist with a discogs id and radio plays should be walked, got %', v_queued;
    end if;
    if (select payload->>'discogs_id' from public.enrichment_jobs
        where job_type = 'cache_discogs_shelf') <> '12345' then
        raise exception 'the shelf job did not carry the discogs id';
    end if;

    -- Already waiting, so not queued twice.
    if public.enqueue_shelf_releases(5) <> 0 then
        raise exception 'the same shelf was queued twice';
    end if;

    -- Walked, so the crawl leaves it alone -- including an artist whose shelf
    -- turned out to be empty, which is the case that would otherwise come
    -- back every quarter hour for ever.
    update public.enrichment_jobs set status = 'done' where job_type = 'cache_discogs_shelf';
    perform public.record_shelf_cached(v_skee);
    if public.enqueue_shelf_releases(5) <> 0 then
        raise exception 'a shelf already walked came back round';
    end if;

    -- MARK: the shelf a page is waiting on

    v_answer := public.request_artist_shelf('5087');
    if (v_answer->>'queued')::int <> 1 then
        raise exception 'a shelf nobody holds should be queued: %', v_answer;
    end if;
    if (select payload->>'discogs_id' from public.enrichment_jobs
        where job_type = 'cache_discogs_shelf' and dedupe_key = '5087') <> '5087' then
        raise exception 'the shelf job did not carry the id the app asked about';
    end if;

    -- Asked twice is queued once.
    if (public.request_artist_shelf('5087')->>'queued')::int <> 0 then
        raise exception 'the same shelf was queued twice';
    end if;

    -- Not digits, so it never reaches a URL.
    if (public.request_artist_shelf('../../etc')->>'queued')::int <> 0
       or (public.request_artist_shelf('')->>'queued')::int <> 0
       or (public.request_artist_shelf(null)->>'queued')::int <> 0 then
        raise exception 'a shelf id that is not digits was accepted';
    end if;

    -- Already held and still fresh, so the app simply lost a race.
    insert into public.metadata_cache (provider, resource_type, resource_id, payload, fetched_at)
    values ('discogs', 'artists/9999/releases',
            'artists/9999/releases?per_page=50&sort=year&sort_order=desc',
            '{"releases":[]}'::jsonb, now());
    v_answer := public.request_artist_shelf('9999');
    if (v_answer->>'cached')::int <> 1 or (v_answer->>'queued')::int <> 0 then
        raise exception 'a shelf already cached should not be fetched again: %', v_answer;
    end if;

    -- And one cached long enough ago is worth reading again.
    update public.metadata_cache set fetched_at = now() - interval '100 days'
    where resource_type = 'artists/9999/releases';
    if (public.request_artist_shelf('9999')->>'queued')::int <> 1 then
        raise exception 'a shelf past its lifetime should be asked for again';
    end if;

    -- MARK: the number the flip rests on

    if (public.release_cache_coverage()->>'cached') is null then
        raise exception 'coverage should report what is cached';
    end if;

    raise notice 'release smoke: the cache checks out';
end $$;

-- ---------------------------------------------------------------------------
-- 0032 — an artist named after themselves
-- ---------------------------------------------------------------------------

do $$
declare
    v_episode uuid;
    v_id uuid;
begin
    select id into v_episode from public.radio_episodes where external_id = 'merge-show/1';
    if v_episode is null then
        select id into v_episode from public.radio_episodes limit 1;
    end if;

    -- A line crediting two people, as the ingest writes it since 0029: the
    -- appearance belongs to the primary, and both names are kept beside it.
    insert into public.radio_appearances
        (radio_episode_id, track_index, raw_artist_name, normalized_artist_name,
         credited_artist_names, credited_artist_keys)
    values (v_episode, 90, 'Rrawun Maymuru, Nick Wales', 'rrawun maymuru',
            array['Rrawun Maymuru', 'Nick Wales'], array['rrawun maymuru', 'nick wales']);

    -- Adoption files it under the right key, and must label it with the right
    -- name rather than the whole line.
    perform public.adopt_radio_artists(null);

    select id into v_id from public.artists where normalized_name = 'rrawun maymuru';
    if v_id is null then
        raise exception 'the primary credit should have been adopted';
    end if;
    if (select name from public.artists where id = v_id) <> 'Rrawun Maymuru' then
        raise exception 'an artist was named after the whole line: %',
            (select name from public.artists where id = v_id);
    end if;

    -- And nobody was invented out of the rest of the line.
    if exists (select 1 from public.artists where normalized_name = 'rrawun maymuru nick wales') then
        raise exception 'the whole credit became an artist';
    end if;

    -- MARK: the ones already labelled wrongly

    update public.artists set name = 'Rrawun Maymuru, Nick Wales' where id = v_id;
    if public.relabel_credited_artists(500) <> 1 then
        raise exception 'the wrongly labelled artist was not renamed';
    end if;
    if (select name from public.artists where id = v_id) <> 'Rrawun Maymuru' then
        raise exception 'the rename did not take';
    end if;

    -- Idempotent, and it renames nothing that is already right.
    if public.relabel_credited_artists(500) <> 0 then
        raise exception 'a second pass renamed something that was already correct';
    end if;

    -- A line crediting one artist is never touched by any of this.
    if (select count(*) from public.artists where normalized_name = 'skee mask') <> 1 then
        raise exception 'a single credit was disturbed';
    end if;

    raise notice 'release smoke: an artist is named after themselves';
end $$;

rollback;
