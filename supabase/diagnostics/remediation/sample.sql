-- Read-only: a reproducible sample of cached release documents, catalogue-wide
-- and from dead-end artists (§20). setseed makes the sample repeatable.
with junk(n) as (select unnest('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])),
real_label as materialized (select l.id from public.labels l where l.normalized_name not like 'not on label%' and l.normalized_name not in (select n from junk)),
label_size as materialized (select r.label_id, count(distinct r.artist_id) as artists from public.releases r join real_label l on l.id = r.label_id group by 1),
label_peer as materialized (select distinct r.artist_id as id from public.releases r join label_size s on s.label_id = r.label_id where s.artists > 1),
edged as materialized (select from_entity_id as id from public.music_relationships where from_entity_type='artist' union select to_entity_id from public.music_relationships where to_entity_type='artist'),
dead as materialized (select a.id from public.artists a where not exists (select 1 from label_peer p where p.id=a.id) and not exists (select 1 from edged e where e.id=a.id)),
seed as (select setseed(0.42)),
everyone as (select r.discogs_id, r.artist_id from public.releases r, seed where r.discogs_cached_at is not null order by md5(r.discogs_id || 'indigo') limit 600),
dead_releases as (select distinct on (r.artist_id) r.discogs_id, r.artist_id from public.releases r join dead d on d.id = r.artist_id
                  where r.discogs_cached_at is not null order by r.artist_id, md5(r.discogs_id || 'indigo')),
dead_sample as (select * from dead_releases order by md5(discogs_id || 'dead') limit 300)
select json_build_object(
  'everyone', (select json_agg(json_build_object('r', discogs_id, 'a', artist_id)) from everyone),
  'dead', (select json_agg(json_build_object('r', discogs_id, 'a', artist_id)) from dead_sample),
  'dead_with_cached_doc', (select count(distinct artist_id) from dead_releases)
) as sample;
