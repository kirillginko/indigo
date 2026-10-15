-- Read-only baseline for the DIG remediation plan (SHARED-KNOWLEDGE.md §20).
-- A shared-catalogue dead end: an artist row from which the backend offers no
-- route anywhere -- no label it shares with another artist, and no
-- relationship row (radio neighbour, played-by, or any other) at either end.
-- Set-based, to fit the CLI's two-minute statement limit.
with junk(n) as (select unnest('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])),
real_label as materialized (
  select l.id from public.labels l
  where l.normalized_name not like 'not on label%' and l.normalized_name not in (select n from junk)),
label_size as materialized (
  select r.label_id, count(distinct r.artist_id) as artists
  from public.releases r join real_label l on l.id = r.label_id group by 1),
discogs as materialized (select distinct entity_id as id from public.external_ids where entity_type='artist' and provider='discogs'),
nts as materialized (select distinct entity_id as id from public.external_ids where entity_type='artist' and provider='nts'),
with_releases as materialized (select distinct artist_id as id from public.releases where artist_id is not null),
label_peer as materialized (select distinct r.artist_id as id from public.releases r join label_size s on s.label_id = r.label_id where s.artists > 1),
edged as materialized (
  select from_entity_id as id from public.music_relationships where from_entity_type='artist'
  union select to_entity_id from public.music_relationships where to_entity_type='artist'),
flags as (
  select a.id, d.id is not null as discogs, n.id is not null as nts, w.id is not null as releases,
         p.id is not null as label_peer, e.id is not null as edged
  from public.artists a
  left join discogs d on d.id = a.id left join nts n on n.id = a.id left join with_releases w on w.id = a.id
  left join label_peer p on p.id = a.id left join edged e on e.id = a.id)
select json_build_object(
  'artists', count(*),
  'with_discogs', count(*) filter (where discogs),
  'radio_only_rows', count(*) filter (where nts and not discogs),
  'with_releases', count(*) filter (where releases),
  'with_label_peer', count(*) filter (where label_peer),
  'with_relationship', count(*) filter (where edged),
  'dead_end', count(*) filter (where not label_peer and not edged),
  'dead_end_with_discogs', count(*) filter (where not label_peer and not edged and discogs),
  'dead_end_with_releases', count(*) filter (where not label_peer and not edged and releases),
  'dead_end_radio_only', count(*) filter (where not label_peer and not edged and nts and not discogs),
  'dead_end_no_identity', count(*) filter (where not label_peer and not edged and not nts and not discogs),
  'only_radio_routes', count(*) filter (where edged and not label_peer),
  'only_label_routes', count(*) filter (where label_peer and not edged),
  'releases_total', (select count(*) from public.releases),
  'releases_with_discogs_doc', (select count(*) from public.releases where discogs_cached_at is not null),
  'labels_real', (select count(*) from real_label),
  'labels_with_one_artist', (select count(*) from label_size where artists = 1),
  'labels_over_300_artists', (select count(*) from label_size where artists > 300)
) as baseline
from flags;
