with wanted(label, discogs) as (values
  ('anika','3999072'),('anika','1982320'),('attilio novellino','1720124'),('duenn','3328071'),
  ('hype williams','398459'),('hype williams','1874027'),('joanne robertson','1053396'),
  ('mica levi','2576890'),('micachu','1172814'),('prefuse 73','3722'),('speedy j','316464'),('speedy j','823')),
by_id as (
  select w.label, w.discogs, a.id, a.name, a.normalized_name, a.musicbrainz_id, a.shelf_cached_at is not null as shelf,
    (select json_agg(json_build_object('p', e.provider, 'x', e.external_id) order by e.provider, e.external_id)
       from external_ids e where e.entity_type='artist' and e.entity_id=a.id) as ids,
    (select count(*) from releases r where r.artist_id=a.id) as releases,
    (select count(*) from releases r where r.artist_id=a.id and r.discogs_cached_at is not null) as cached_docs,
    (select json_agg(r.discogs_id order by r.discogs_id) from releases r where r.artist_id=a.id and r.discogs_cached_at is not null) as release_ids
  from wanted w
  left join external_ids x on x.provider='discogs' and x.entity_type='artist' and x.external_id=w.discogs
  left join artists a on a.id=x.entity_id),
by_name as (
  select n.label, a.id, a.name, a.musicbrainz_id,
    (select json_agg(json_build_object('p', e.provider, 'x', e.external_id) order by e.provider, e.external_id)
       from external_ids e where e.entity_type='artist' and e.entity_id=a.id) as ids
  from (values ('anika'),('annika henderson'),('attilio novellino'),('duenn'),('hype williams'),('joanne robertson'),
               ('mica levi'),('micachu'),('prefuse 73'),('prefuse73'),('speedy j')) n(label)
  join artists a on a.normalized_name = n.label)
select json_build_object('by_id', (select json_agg(b) from by_id b), 'by_name', (select json_agg(b) from by_name b)) as audit;
