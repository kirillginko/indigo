-- Read-only: single adjacencies derived on demand vs stored, for the busiest
-- artists, timed.
explain (analyze, buffers, format json)
with me as (select ra.radio_episode_id, ra.track_index from public.radio_appearances ra
            where ra.artist_id = (select artist_id from public.radio_appearances where artist_id is not null group by 1 order by count(*) desc limit 1)),
near as (
  select b.artist_id as other, count(*) as adjacencies, count(distinct b.radio_episode_id) as episodes
  from me join public.radio_appearances b
    on b.radio_episode_id = me.radio_episode_id and b.track_index in (me.track_index - 1, me.track_index + 1)
  where b.artist_id is not null
  group by b.artist_id)
select count(*) filter (where adjacencies = 1), count(*) from near;
