with nb as materialized (select from_entity_id f, to_entity_id t, evidence_count e, coalesce(episode_count, (metadata->>'episodes')::int) ep from public.music_relationships where relationship_type='radio_neighbor'),
strong_route as materialized (
  select from_entity_id id from public.music_relationships where relationship_type='played_by'
  union select f from nb where e > 1 union select t from nb where e > 1
  union select r.artist_id from public.releases r where r.artist_id is not null),
weak_only as (select id from (select f id from nb where e = 1 union select t from nb where e = 1) w where not exists (select 1 from strong_route s where s.id = w.id))
select json_build_object(
 'radio_neighbor_by_evidence', (select json_object_agg(b, n) from (select case when e=1 then '1' when e=2 then '2' when e<=5 then '3-5' else '6+' end b, count(*) n from nb group by 1) z),
 'radio_neighbor_single_episode_single_adjacency', (select count(*) from nb where e = 1 and coalesce(ep,1) = 1),
 'artists_left_without_route_if_e1_neighbours_removed', (select count(*) from weak_only),
 'artwork', (select json_build_object('rows', count(*), 'misses', count(*) filter (where original_url is null), 'by_entity', json_object_agg(entity_type, 0)) from public.artwork),
 'artwork_by_entity', (select json_object_agg(entity_type, n) from (select entity_type, count(*) n from public.artwork group by 1) z),
 'jobs', (select json_object_agg(s, n) from (select status || ' ' || case when updated_at > now() - interval '1 day' then '<1d' when updated_at > now() - interval '7 days' then '1-7d' else '>7d' end s, count(*) n from public.enrichment_jobs group by 1) z),
 'jobs_by_type_done_old', (select json_object_agg(job_type, n) from (select job_type, count(*) n from public.enrichment_jobs where status in ('done','failed') and updated_at < now() - interval '3 days' group by 1 order by 2 desc limit 8) z),
 'identification_source', (select json_object_agg(coalesce(identification_source,'null'), n) from (select identification_source, count(*) n from public.radio_appearances group by 1) z),
 'media_url_distinct_per_episode', (select round(avg(n),2) from (select radio_episode_id, count(distinct media_url) n from public.radio_appearances where media_url is not null group by 1) z),
 'appearances_with_media_url', (select count(*) from public.radio_appearances where media_url is not null),
 'external_ids_source_url', (select json_object_agg(provider, json_build_object('rows', n, 'mb', mb, 'derivable', d)) from (select provider, count(*) n, round(sum(pg_column_size(source_url))/1048576.0,2) mb,
      count(*) filter (where source_url = 'https://www.discogs.com/' || entity_type || '/' || external_id) d from public.external_ids group by 1) z)
) as r;
