with derived as (
  select ra.artist_id, re.radio_show_id, count(*)::int as appearances, count(distinct re.id)::int as episodes
  from radio_appearances ra join radio_episodes re on re.id = ra.radio_episode_id
  where ra.artist_id is not null and re.radio_show_id is not null
  group by 1,2
), stored as (
  select from_entity_id artist_id, to_entity_id radio_show_id, evidence_count, episode_count, confidence
  from music_relationships where relationship_type='played_by'
)
select
  case when d.artist_id is null then 'stored_only_stale'
       when s.artist_id is null then 'derived_only_unstored'
       when (s.evidence_count, s.episode_count) = (d.appearances, d.episodes)
            and s.confidence = least(0.95, 0.5 + 0.45 * (1 - 1.0 / (1 + d.episodes)))::double precision then 'exact'
       else 'differs' end as cls,
  coalesce(s.episode_count, -1) = 1 as stored_single,
  coalesce(d.episodes, -1) = 1 as derived_single,
  count(*)
from stored s full join derived d using (artist_id, radio_show_id)
group by 1,2,3 order by 1,2,3
