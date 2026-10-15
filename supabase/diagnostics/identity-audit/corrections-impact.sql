-- Read-only impact audit for the two identity corrections (SHARED-KNOWLEDGE.md §18).
with rows(label, id) as (values
  ('hype williams (radio)', '5dbab0e3'), ('hype williams (2) (duo)', '8c74e06d'),
  ('prefuse73 (radio)', 'cc290916'), ('prefuse 73', '36133fd1')),
r as (select x.label, a.* from rows x join public.artists a on a.id::text like x.id || '%')
select json_build_object(
 'rows', (select json_agg(json_build_object('label', r.label, 'id', r.id, 'name', r.name, 'normalized', r.normalized_name,
     'mbid', r.musicbrainz_id, 'created', r.created_at, 'shelf', r.shelf_cached_at,
     'ids', (select json_agg(json_build_object('p', e.provider, 'x', e.external_id, 'url', e.source_url, 'at', e.created_at) order by e.provider)
             from public.external_ids e where e.entity_type = 'artist' and e.entity_id = r.id),
     'releases', (select json_agg(json_build_object('title', rel.title, 'discogs', rel.discogs_id, 'year', rel.release_year,
                    'label', (select l.name from public.labels l where l.id = rel.label_id), 'cached', rel.discogs_cached_at is not null))
                  from public.releases rel where rel.artist_id = r.id),
     'relationships', (select json_object_agg(t, n) from (select m.relationship_type as t, count(*) as n from public.music_relationships m where m.from_entity_id = r.id or m.to_entity_id = r.id group by 1) z),
     'radio', (select count(*) from public.radio_appearances ra where ra.artist_id = r.id),
     'scenes', (select count(*) from public.scene_members s where s.normalized_name = r.normalized_name),
     'split', (select count(*) from public.split_artist_halves h where h.keep_id = r.id or h.merge_id = r.id),
     'credit_rows', (select count(*) from public.artists_that_are_credits c where c.credit_id = r.id)))
   from r),
 'discogs_398459', (select json_agg(e) from public.external_ids e where e.external_id = '398459'),
 'discogs_1874027', (select json_agg(e) from public.external_ids e where e.external_id = '1874027'),
 'discogs_3722', (select json_agg(e) from public.external_ids e where e.external_id = '3722'),
 'other_hype', (select json_agg(json_build_object('id', a.id, 'name', a.name)) from public.artists a where a.normalized_name like 'hype williams%'),
 'other_prefuse', (select json_agg(json_build_object('id', a.id, 'name', a.name, 'norm', a.normalized_name)) from public.artists a where a.normalized_name in ('prefuse73', 'prefuse 73', 'prefuse'))
) as impact;
