-- Read-only: the radio data's shape, for the granularity workstream (§20).
with per_artist_show as materialized (
  select ra.artist_id, e.radio_show_id, count(distinct e.id) as episodes
  from public.radio_appearances ra join public.radio_episodes e on e.id = ra.radio_episode_id
  where ra.artist_id is not null group by 1, 2)
select json_build_object(
  'shows', (select count(*) from public.radio_shows),
  'shows_by_provider', (select json_object_agg(provider, n) from (select provider, count(*) n from public.radio_shows group by 1) z),
  'episodes', (select count(*) from public.radio_episodes),
  'episodes_with_tracklist', (select count(*) from public.radio_episodes where tracklist_status = 'available'),
  'appearances', (select count(*) from public.radio_appearances),
  'appearances_resolved', (select count(*) from public.radio_appearances where artist_id is not null),
  'artists_with_appearances', (select count(distinct artist_id) from public.radio_appearances where artist_id is not null),
  'artist_show_pairs', (select count(*) from per_artist_show),
  'artist_episode_pairs', (select sum(episodes) from per_artist_show),
  'pairs_in_one_episode', (select count(*) from per_artist_show where episodes = 1),
  'pairs_in_5_plus', (select count(*) from per_artist_show where episodes >= 5),
  'played_by_edges', (select count(*) from public.music_relationships where relationship_type = 'played_by'),
  'played_by_with_episode_count', (select count(*) from public.music_relationships where relationship_type = 'played_by' and episode_count is not null),
  'radio_neighbor_edges', (select count(*) from public.music_relationships where relationship_type = 'radio_neighbor')
) as radio;
