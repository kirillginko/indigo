-- Read-only: the four recommendation paths the backend does not reach for
-- this Mac's Development rows (SHARED-KNOWLEDGE.md §19), at their sources.
with
labels as (select l.id, l.name, l.normalized_name from public.labels l
           where l.normalized_name in ('opal tapes', 'music on vinyl')),
by_label as (
  select lb.name as label, a.name as artist, a.id as artist_id, count(*) as releases,
         count(*) filter (where r.discogs_id is not null) as with_discogs
  from labels lb join public.releases r on r.label_id = lb.id join public.artists a on a.id = r.artist_id
  group by 1, 2, 3)
select json_build_object(
 'labels', (select json_agg(json_build_object('id', id, 'name', name)) from labels),
 'roster_sizes', (select json_object_agg(label, n) from (select label, count(*) as n from by_label group by 1) z),
 'opal_tapes', (select json_agg(b) from by_label b where b.label ilike 'opal tapes' and b.artist ~* '^(duenn|ciro vitiello)$'),
 'music_on_vinyl', (select json_agg(b) from by_label b where b.label ilike 'music on vinyl' and b.artist ~* '^(eric kloss|ryuichi sakamoto|坂本龍一)$'),
 'mov_rank_of_sakamoto', (select json_build_object('roster', count(*), 'sakamoto_rank', min(rk) filter (where artist ~* 'sakamoto'))
      from (select artist, row_number() over (order by releases desc, artist) as rk from by_label where label ilike 'music on vinyl') z),
 'ciro_rows', (select json_agg(json_build_object('id', a.id, 'name', a.name, 'labels', (select json_agg(distinct l.name) from public.releases r join public.labels l on l.id=r.label_id where r.artist_id=a.id)))
               from public.artists a where a.normalized_name = 'ciro vitiello'),
 'duenn_labels', (select json_agg(distinct l.name) from public.releases r join public.labels l on l.id = r.label_id join public.artists a on a.id = r.artist_id where a.normalized_name = 'duenn'),
 'eric_kloss_now', (select json_agg(json_build_object('title', r.title, 'discogs', r.discogs_id, 'cached', r.discogs_cached_at is not null, 'label', (select name from public.labels where id = r.label_id)))
                    from public.releases r join public.artists a on a.id = r.artist_id where a.normalized_name = 'eric kloss' and r.title ilike 'now%'),
 'eric_kloss_releases', (select count(*) from public.releases r join public.artists a on a.id = r.artist_id where a.normalized_name = 'eric kloss'),
 'seibert_rows', (select json_agg(json_build_object('id', a.id, 'name', a.name)) from public.artists a where a.normalized_name like 'frederick seibert%' or a.normalized_name like 'fred seibert%'),
 'show_239ef', (select json_agg(json_build_object('id', s.id, 'provider', s.provider, 'external_id', s.external_id, 'title', s.title,
                 'episodes', (select count(*) from public.radio_episodes e where e.radio_show_id = s.id)))
                from public.radio_shows s where s.title ilike '%239ef%' or s.external_id ilike '%239ef%'),
 'episodes_239ef', (select json_agg(json_build_object('id', e.id, 'external_id', e.external_id, 'title', e.title, 'aired', e.aired_at, 'tracklist', e.tracklist_status,
                 'appearances', (select count(*) from public.radio_appearances ra where ra.radio_episode_id = e.id),
                 'anika_or_blunt', (select json_agg(json_build_object('raw', ra.raw_artist_name, 'artist', a.name, 'artist_id', ra.artist_id))
                                    from public.radio_appearances ra left join public.artists a on a.id = ra.artist_id
                                    where ra.radio_episode_id = e.id and (ra.normalized_artist_name ~ '(anika|dean blunt)' or a.normalized_name ~ '(anika|dean blunt)'))))
                from public.radio_episodes e join public.radio_shows s on s.id = e.radio_show_id where s.title ilike '%239ef%' or s.external_id ilike '%239ef%' or e.title ilike '%239ef%'),
 'played_by_239ef', (select json_agg(json_build_object('artist', a.name, 'episode_count', m.episode_count))
                     from public.music_relationships m join public.radio_shows s on s.id = m.to_entity_id join public.artists a on a.id = m.from_entity_id
                     where m.relationship_type = 'played_by' and (s.title ilike '%239ef%' or s.external_id ilike '%239ef%') and a.normalized_name ~ '^(anika|dean blunt)$')
) as r;
