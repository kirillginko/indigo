-- Smoke test for joining an artist filed twice (0028).
--
-- This one is dangerous in a way the others are not: it deletes artist rows.
-- Merging two halves of one artist is right; merging Disorder (2) into
-- Disorder (3) destroys a band's page and there is nothing on screen to say it
-- happened. So most of what is checked here is what the merge *refuses* to do.
--
--     psql -f supabase/tests/merge_smoke.sql
--
-- Every check raises on failure, so a clean run means a clean run.

\set ON_ERROR_STOP on
begin;

-- MARK: - One artist, two halves

insert into public.artists (name, normalized_name, country) values
    ('The Beatles', 'the beatles', 'GB'),       -- adopted from radio
    ('The Beatles', 'the beatles', null);       -- written by a page open

-- Genuine namesakes: Discogs numbers them, so they are two artists.
insert into public.artists (name, normalized_name) values
    ('Disorder', 'disorder'),
    ('Disorder', 'disorder');

-- An artist only radio knows, with nobody to merge with.
insert into public.artists (name, normalized_name) values ('Purelink', 'purelink');

insert into public.radio_shows (provider, external_id, station, title)
values ('nts', 'merge-show', 'NTS', 'Merge Test');
insert into public.radio_episodes (radio_show_id, provider, external_id, aired_at)
select id, 'nts', 'merge-show/1', now() from public.radio_shows where external_id = 'merge-show';

do $$
declare
    v_keep uuid;
    v_merge uuid;
    v_d1 uuid;
    v_d2 uuid;
    v_pure uuid;
    v_episode uuid;
    v_merged int;
begin
    select id into v_keep from public.artists
    where normalized_name = 'the beatles' and country = 'GB';
    select id into v_merge from public.artists
    where normalized_name = 'the beatles' and country is null;
    select id into v_pure from public.artists where normalized_name = 'purelink';
    select id into v_episode from public.radio_episodes where external_id = 'merge-show/1';

    select array_agg(id) into strict v_d1 from (select id from public.artists
        where normalized_name = 'disorder' limit 1) s;

    -- The radio half: a name key, the appearances, an edge, a portrait.
    insert into public.external_ids (entity_type, entity_id, provider, external_id)
    values ('artist', v_keep, 'nts', 'the beatles');
    insert into public.radio_appearances
        (radio_episode_id, track_index, raw_artist_name, normalized_artist_name, artist_id)
    values (v_episode, 1, 'The Beatles', 'the beatles', v_keep);
    insert into public.music_relationships
        (from_entity_type, from_entity_id, to_entity_type, to_entity_id,
         relationship_type, evidence_count)
    values ('artist', v_keep, 'artist', v_pure, 'radio_neighbor', 3);
    insert into public.artwork (entity_type, entity_id, provider, original_url)
    values ('artist', v_keep, 'discogs', 'https://img.test/beatles.jpg');

    -- The Discogs half: an id, and an edge to the same neighbour.
    insert into public.external_ids (entity_type, entity_id, provider, external_id)
    values ('artist', v_merge, 'discogs', '82730');
    insert into public.music_relationships
        (from_entity_type, from_entity_id, to_entity_type, to_entity_id,
         relationship_type, evidence_count)
    values ('artist', v_merge, 'artist', v_pure, 'radio_neighbor', 2);
    insert into public.releases (title, artist_id) values ('Revolver', v_merge);

    -- Both Disorders carry a Discogs id, which is Discogs saying they are two.
    for v_d1 in select id from public.artists where normalized_name = 'disorder' loop
        insert into public.external_ids (entity_type, entity_id, provider, external_id)
        values ('artist', v_d1, 'discogs', 'disorder-' || v_d1::text);
    end loop;

    -- MARK: what the view names

    if not exists (select 1 from public.split_artist_halves
                   where normalized_name = 'the beatles') then
        raise exception 'one radio row and one discogs row is a split artist';
    end if;
    if exists (select 1 from public.split_artist_halves where normalized_name = 'disorder') then
        raise exception 'two discogs ids are two artists, not one filed twice';
    end if;
    if exists (select 1 from public.split_artist_halves where normalized_name = 'purelink') then
        raise exception 'an artist filed once is not a split artist';
    end if;

    -- MARK: the merge

    v_merged := public.merge_split_artists(50);
    if v_merged <> 1 then
        raise exception 'exactly one pair should have merged, got %', v_merged;
    end if;

    if (select count(*) from public.artists where normalized_name = 'the beatles') <> 1 then
        raise exception 'the artist is still filed twice';
    end if;
    if not exists (select 1 from public.artists where id = v_keep) then
        raise exception 'the half holding the radio history is the half that survives';
    end if;

    -- The Discogs id moved onto the row that has the appearances.
    if not exists (
        select 1 from public.external_ids
        where entity_type = 'artist' and entity_id = v_keep
          and provider = 'discogs' and external_id = '82730'
    ) then
        raise exception 'the surviving row did not inherit the discogs id';
    end if;
    if not exists (
        select 1 from public.external_ids
        where entity_type = 'artist' and entity_id = v_keep and provider = 'nts'
    ) then
        raise exception 'the surviving row lost its own name key';
    end if;

    -- And what was filed against the losing row came with it.
    if (select artist_id from public.releases where title = 'Revolver') is distinct from v_keep then
        raise exception 'a release stayed behind on the deleted row';
    end if;

    -- One neighbour seen from both halves is one edge that has been seen five
    -- times, not two edges.
    if (select count(*) from public.music_relationships
        where relationship_type = 'radio_neighbor'
          and (from_entity_id = v_keep or to_entity_id = v_keep)) <> 1 then
        raise exception 'the merge left two edges where there is one relationship';
    end if;
    if (select evidence_count from public.music_relationships
        where relationship_type = 'radio_neighbor' and from_entity_id = v_keep) <> 5 then
        raise exception 'the evidence from both halves was not added up';
    end if;

    -- Nothing is left pointing at a row that no longer exists.
    if exists (select 1 from public.external_ids
               where entity_type = 'artist' and entity_id = v_merge) then
        raise exception 'an identity outlived the row it belonged to';
    end if;

    -- MARK: what it refuses

    if (select count(*) from public.artists where normalized_name = 'disorder') <> 2 then
        raise exception 'two namesakes were merged into one';
    end if;

    -- Idempotent: nothing left to merge.
    if public.merge_split_artists(50) <> 0 then
        raise exception 'a second pass merged something that was already joined';
    end if;

    -- And a merge asked to join a row to itself does nothing at all.
    perform public.merge_artist_halves(v_keep, v_keep);
    if not exists (select 1 from public.artists where id = v_keep) then
        raise exception 'merging a row into itself deleted it';
    end if;

    raise notice 'merge smoke: all checks passed';
end $$;

rollback;
