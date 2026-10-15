-- Read-only, run once per slice (:'slice' = one hex digit): of the stored
-- single adjacencies, how many the appearances still reproduce exactly, how
-- many they reproduce with a different count, and how many they no longer
-- reproduce (stale: the pair is not adjacent in any episode now).
with singles as (
  select from_entity_id f, to_entity_id t from public.music_relationships
  where relationship_type = 'radio_neighbor' and evidence_count = 1
    and left(from_entity_id::text, 1) = :'slice'),
live as (
  select s.f, s.t, (select count(*) from public.radio_appearances a join public.radio_appearances b
        on b.radio_episode_id = a.radio_episode_id and b.track_index in (a.track_index - 1, a.track_index + 1)
        where a.artist_id = s.f and b.artist_id = s.t) as n
  from singles s)
select json_build_object('slice', :'slice', 'singles', count(*), 'exact', count(*) filter (where n = 1),
  'now_more', count(*) filter (where n > 1), 'stale', count(*) filter (where n = 0)) as r from live;
