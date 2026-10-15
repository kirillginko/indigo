-- 0078: single adjacencies worked out when asked, in a transaction rolled
-- back. Every reader must answer exactly what the old stored edges would
-- have: pairs seen once (derived), pairs seen twice or more (stored, or
-- derived if the rebuild has not stored them yet), and never a stored single
-- adjacency whose appearances are gone.

begin;

insert into public.artists (id, name, normalized_name) values
    ('31000000-0000-0000-0000-00000000000a', 'Adjacent A', 'adjacent a'),
    ('31000000-0000-0000-0000-00000000000b', 'Adjacent B', 'adjacent b'),   -- next to A once
    ('31000000-0000-0000-0000-00000000000c', 'Adjacent C', 'adjacent c'),   -- next to A twice
    ('31000000-0000-0000-0000-00000000000d', 'Adjacent D', 'adjacent d'),   -- a stale stored single
    ('31000000-0000-0000-0000-00000000000e', 'Adjacent E', 'adjacent e');   -- twice, after the rebuild
insert into public.radio_shows (id, provider, external_id, station, title)
values ('31000000-0000-0000-0000-0000000000d1', 'nts', 'adjacency-show', 'NTS', 'Adjacency Show');
insert into public.radio_episodes (id, radio_show_id, provider, external_id, title, aired_at, tracklist_status) values
    ('31000000-0000-0000-0000-0000000000e1', '31000000-0000-0000-0000-0000000000d1', 'nts', 'adjacency-show/1', 'One', now() - interval '3 days', 'available'),
    ('31000000-0000-0000-0000-0000000000e2', '31000000-0000-0000-0000-0000000000d1', 'nts', 'adjacency-show/2', 'Two', now() - interval '2 days', 'available'),
    ('31000000-0000-0000-0000-0000000000e3', '31000000-0000-0000-0000-0000000000d1', 'nts', 'adjacency-show/3', 'Three', now() - interval '1 days', 'available');
-- Episode 1: B, A, C.   Episode 2: C, A.   (A-B once, A-C twice)
insert into public.radio_appearances (radio_episode_id, track_index, raw_artist_name, raw_track_title, normalized_artist_name, normalized_title, artist_id) values
    ('31000000-0000-0000-0000-0000000000e1', 0, 'Adjacent B', 't1', 'adjacent b', 't1', '31000000-0000-0000-0000-00000000000b'),
    ('31000000-0000-0000-0000-0000000000e1', 1, 'Adjacent A', 't2', 'adjacent a', 't2', '31000000-0000-0000-0000-00000000000a'),
    ('31000000-0000-0000-0000-0000000000e1', 2, 'Adjacent C', 't3', 'adjacent c', 't3', '31000000-0000-0000-0000-00000000000c'),
    ('31000000-0000-0000-0000-0000000000e2', 0, 'Adjacent C', 't4', 'adjacent c', 't4', '31000000-0000-0000-0000-00000000000c'),
    ('31000000-0000-0000-0000-0000000000e2', 1, 'Adjacent A', 't5', 'adjacent a', 't5', '31000000-0000-0000-0000-00000000000a');

select public.rebuild_radio_dig_edges();

do $$
begin
    if exists (select 1 from public.music_relationships where relationship_type = 'radio_neighbor' and evidence_count < 2
               and '31000000-0000-0000-0000-00000000000a' in (from_entity_id, to_entity_id)) then
        raise exception 'the rebuild stored a single adjacency';
    end if;
    if not exists (select 1 from public.music_relationships where relationship_type = 'radio_neighbor' and evidence_count = 2
                   and from_entity_id = least('31000000-0000-0000-0000-00000000000a'::uuid, '31000000-0000-0000-0000-00000000000c'::uuid)) then
        raise exception 'the rebuild did not store the pair seen twice';
    end if;
end $$;

-- After the rebuild: E plays next to A twice (not stored yet), and a stale
-- single adjacency A-D sits in the table with nothing behind it.
insert into public.radio_appearances (radio_episode_id, track_index, raw_artist_name, raw_track_title, normalized_artist_name, normalized_title, artist_id) values
    ('31000000-0000-0000-0000-0000000000e3', 0, 'Adjacent E', 't6', 'adjacent e', 't6', '31000000-0000-0000-0000-00000000000e'),
    ('31000000-0000-0000-0000-0000000000e3', 1, 'Adjacent A', 't7', 'adjacent a', 't7', '31000000-0000-0000-0000-00000000000a'),
    ('31000000-0000-0000-0000-0000000000e3', 2, 'Adjacent E', 't8', 'adjacent e', 't8', '31000000-0000-0000-0000-00000000000e');
insert into public.music_relationships (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type, confidence, source, evidence_count, episode_count)
values ('artist', '31000000-0000-0000-0000-00000000000a', 'artist', '31000000-0000-0000-0000-00000000000d', 'radio_neighbor', 0.65, 'radio', 1, 1);

do $$
declare rel jsonb; dig jsonb; ans jsonb; exp jsonb;
    a uuid := '31000000-0000-0000-0000-00000000000a';
    want jsonb := '{"Adjacent B": 1, "Adjacent C": 2, "Adjacent E": 2}';
begin
    -- The DIG artist page.
    select jsonb_object_agg(coalesce(x.title, ''), x.evidence_count) into rel
    from public.artist_radio_relations(a, 50) x where x.relationship_type = 'radio_neighbor';
    if rel <> want then raise exception 'artist_radio_relations: %', rel; end if;
    if (select x.confidence from public.artist_radio_relations(a, 50) x where x.title = 'Adjacent B') <> 0.65 then
        raise exception 'a single adjacency is not scored as the rebuild scores it';
    end if;
    if (select x.metadata from public.artist_radio_relations(a, 50) x where x.title = 'Adjacent B')
       <> '{"adjacencies": 1, "episodes": 1}'::jsonb then
        raise exception 'a single adjacency''s evidence shape changed';
    end if;
    if (select count(*) from public.artist_radio_relations(a, 50) x where x.relationship_type = 'played_by') <> 1 then
        raise exception 'the show disappeared from the page';
    end if;

    -- DIG's radio block.
    select jsonb_object_agg(e->>'name', (e->>'evidence_count')::int) into dig
    from jsonb_array_elements(public.dig_radio_for_artists(array['adjacent a'], 50)->'alongside') e;
    if dig <> want then raise exception 'dig_radio_for_artists: %', dig; end if;

    -- The knowledge answers.
    select jsonb_object_agg(e->'to'->>'name', (e->>'occurrences')::int) into ans
    from jsonb_array_elements(public.knowledge_answers(
        '[{"id":"artist:adjacent a","kind":"artist","key":"adjacent a","provider":"","handle":""}]', '{}')
        ->'nodes'->'artist:adjacent a'->'edges') e
    where e->>'kind' = 'frequentlyPlayedNearby';
    if ans <> want then raise exception 'knowledge_answers: %', ans; end if;
    select jsonb_object_agg(e->'to'->>'name', (e->>'occurrences')::int) into exp
    from jsonb_array_elements(public.explore_knowledge(
        '[{"id":"artist:adjacent a","kind":"artist","key":"adjacent a","provider":"","handle":""}]', '{}')
        ->'nodes'->'artist:adjacent a'->'edges') e
    where e->>'kind' = 'frequentlyPlayedNearby';
    if exp <> want then raise exception 'explore_knowledge: %', exp; end if;

    -- And from B's side: the one adjacency, symmetric.
    if (select jsonb_object_agg(x.title, x.evidence_count) from public.artist_radio_relations('31000000-0000-0000-0000-00000000000b', 50) x
        where x.relationship_type = 'radio_neighbor') <> '{"Adjacent A": 1}'::jsonb then
        raise exception 'the single adjacency is not symmetric';
    end if;
end $$;

-- Removing every stored single adjacency (what B2 does) changes no answer.
create temp table before_delete as
select x.title, x.evidence_count, x.confidence, x.metadata
from public.artist_radio_relations('31000000-0000-0000-0000-00000000000a', 50) x;
delete from public.music_relationships where relationship_type = 'radio_neighbor' and evidence_count = 1;
do $$
begin
    if exists (select title, evidence_count, confidence, metadata from public.artist_radio_relations('31000000-0000-0000-0000-00000000000a', 50)
               except select * from before_delete)
       or exists (select * from before_delete
                  except select title, evidence_count, confidence, metadata from public.artist_radio_relations('31000000-0000-0000-0000-00000000000a', 50)) then
        raise exception 'deleting stored single adjacencies changed the page';
    end if;
end $$;

rollback;

select 'radio adjacency: singles derived, pairs stored, stale singles gone, every reader agrees, deleting singles changes nothing' as ok;
