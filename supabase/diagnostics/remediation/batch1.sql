-- Read-only: the first enrichment batch after the pilot (DIG-REMEDIATION-PLAN.md
-- §12). Artists with a Discogs identity and cached release documents, outside
-- the 300-artist pilot, ranked by how little the catalogue offers them today:
-- label peers plus relationship rows, fewest first (dead ends, then sparse),
-- ties by a stable hash. Each with its own cached releases (ownCachedReleases).
with junk(n) as (select unnest('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])),
real_label as materialized (select l.id from public.labels l where l.normalized_name not like 'not on label%' and l.normalized_name not in (select n from junk)),
label_size as materialized (select r.label_id, count(distinct r.artist_id) as artists from public.releases r join real_label l on l.id = r.label_id group by 1),
peers as materialized (select r.artist_id as id, count(distinct r.label_id) filter (where s.artists > 1) as labels
                       from public.releases r join label_size s on s.label_id = r.label_id group by 1),
edges as materialized (select id, count(*) as n from (
        select from_entity_id as id from public.music_relationships where from_entity_type = 'artist'
        union all select to_entity_id from public.music_relationships where to_entity_type = 'artist') e group by 1),
identified as materialized (
    select e.entity_id as id, min(e.external_id::bigint) as discogs
    from public.external_ids e
    where e.entity_type = 'artist' and e.provider = 'discogs' and e.external_id ~ '^[0-9]+$'
    group by 1),
cached as materialized (
    select r.artist_id as id, array_agg(distinct r.discogs_id) as releases
    from public.releases r where r.discogs_cached_at is not null and r.discogs_id is not null group by 1),
ranked as (
    select i.discogs, a.name, c.releases,
           coalesce(p.labels, 0) as label_peers, coalesce(x.n, 0) as relationships
    from identified i
    join public.artists a on a.id = i.id
    join cached c on c.id = i.id
    left join peers p on p.id = i.id
    left join edges x on x.id = i.id
    where not (i.discogs = any(:'pilot'::bigint[]))
    order by coalesce(p.labels, 0) + coalesce(x.n, 0), md5(i.discogs::text || 'batch1')
    limit 3000
)
select json_build_object(
  'batch', (select json_agg(json_build_object('discogs', discogs, 'name', name, 'releases', releases,
                                               'labelPeers', label_peers, 'relationships', relationships)) from ranked),
  'by_routes', (select json_object_agg(b, n) from (select least(label_peers + relationships, 10) b, count(*) n from ranked group by 1) t)
) as batch;
