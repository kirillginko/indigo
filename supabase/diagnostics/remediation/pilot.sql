-- Read-only: the catalogue-bundle pilot's inputs (DIG-REMEDIATION-PLAN.md §7
-- step 3). The 300 dead-end artists are sample.sql's, chosen the same way;
-- for each, its Discogs ids and every cached release the catalogue files
-- under any row with those ids (knowledge_live.ts `ownCachedReleases`).
-- Beside them, to resolve what the documents name, by Discogs id only:
-- every catalogued Discogs artist with its rows and whether all are dead
-- ends, and every Discogs label with how many catalogued artists it has.
with junk(n) as (select unnest('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])),
real_label as materialized (select l.id from public.labels l where l.normalized_name not like 'not on label%' and l.normalized_name not in (select n from junk)),
label_size as materialized (select r.label_id, count(distinct r.artist_id) as artists from public.releases r join real_label l on l.id = r.label_id group by 1),
label_peer as materialized (select distinct r.artist_id as id from public.releases r join label_size s on s.label_id = r.label_id where s.artists > 1),
edged as materialized (select from_entity_id as id from public.music_relationships where from_entity_type='artist' union select to_entity_id from public.music_relationships where to_entity_type='artist'),
dead as materialized (select a.id from public.artists a where not exists (select 1 from label_peer p where p.id=a.id) and not exists (select 1 from edged e where e.id=a.id)),
dead_releases as (select distinct on (r.artist_id) r.discogs_id, r.artist_id from public.releases r join dead d on d.id = r.artist_id
                  where r.discogs_cached_at is not null order by r.artist_id, md5(r.discogs_id || 'indigo')),
dead_sample as (select * from dead_releases order by md5(discogs_id || 'dead') limit 300),
pilot as (
    select a.id, a.name,
           (select array_agg(distinct e.external_id::bigint) from public.external_ids e
             where e.entity_type = 'artist' and e.entity_id = a.id and e.provider = 'discogs') as discogs
    from dead_sample s join public.artists a on a.id = s.artist_id
),
discogs_rows as materialized (
    select e.external_id::bigint as discogs, e.entity_id as row
    from public.external_ids e where e.entity_type = 'artist' and e.provider in ('discogs', 'musicbrainz_discogs')
)
select json_build_object(
  'pilot', (select json_agg(json_build_object('id', p.id, 'name', p.name, 'discogs', p.discogs,
      'releases', (select array_agg(distinct r.discogs_id) from public.releases r
                   where r.discogs_cached_at is not null and r.discogs_id is not null
                     and r.artist_id in (select d.row from discogs_rows d where d.discogs = any(p.discogs))
                      or (r.artist_id = p.id and r.discogs_cached_at is not null and r.discogs_id is not null))))
    from pilot p),
  'artists', (select json_object_agg(discogs, info) from (
      select d.discogs, json_build_object('rows', count(distinct d.row), 'dead', bool_and(x.id is not null)) as info
      from discogs_rows d left join dead x on x.id = d.row group by d.discogs) t),
  'labels', (select json_object_agg(discogs, artists) from (
      select e.external_id as discogs, count(distinct r.artist_id) as artists
      from public.external_ids e join public.releases r on r.label_id = e.entity_id
      where e.entity_type = 'label' and e.provider = 'discogs' group by 1) t)
) as pilot;
