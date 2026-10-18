-- Rollback for 0087: the four functions exactly as live before it (equal to 0078),
-- the allowlist as in 0084, and artist_show_counts dropped.

CREATE OR REPLACE FUNCTION public.rebuild_radio_dig_edges()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET work_mem TO '16MB'
AS $function$
declare
    written int := 0;
begin
    with wanted as materialized (
        -- Artist -> the programmes that play them.
        select
            'artist'::text as from_entity_type, played.artist_id as from_entity_id,
            'radio_show'::text as to_entity_type, played.radio_show_id as to_entity_id,
            'played_by'::text as relationship_type,
            least(0.95, 0.5 + 0.45 * (1 - 1.0 / (1 + played.episodes)))::double precision as confidence,
            'radio'::text as source,
            played.appearances::int as evidence_count,
            played.episodes::smallint as episode_count
        from (
            select ra.artist_id,
                   re.radio_show_id,
                   count(*) as appearances,
                   count(distinct re.id) as episodes
            from public.radio_appearances ra
            join public.radio_episodes re on re.id = ra.radio_episode_id
            where ra.artist_id is not null and re.radio_show_id is not null
            group by ra.artist_id, re.radio_show_id
        ) as played

        union all

        -- Artist <-> artist, played next to each other in a tracklist. Stored
        -- once under the lower uuid: the relationship is symmetric.
        select
            'artist', near.low, 'artist', near.high,
            'radio_neighbor',
            least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + near.adjacencies)))::double precision,
            'radio',
            near.adjacencies::int,
            near.episodes::smallint
        from (
            select
                least(a.artist_id, b.artist_id) as low,
                greatest(a.artist_id, b.artist_id) as high,
                count(*) as adjacencies,
                count(distinct a.radio_episode_id) as episodes
            from public.radio_appearances a
            join public.radio_appearances b
                on b.radio_episode_id = a.radio_episode_id
               and b.track_index = a.track_index + 1
            where a.artist_id is not null
              and b.artist_id is not null
              and a.artist_id <> b.artist_id
            group by least(a.artist_id, b.artist_id), greatest(a.artist_id, b.artist_id)
            -- Twice or more (0078): a single adjacency is worked out by the
            -- readers from the appearances when asked, not stored.
            having count(*) >= 2
        ) as near
    ),
    -- Only the edges whose evidence moved. Everything else is left as it is,
    -- unlocked and unwritten. A row not yet converted is compared by the
    -- episode count its document holds, so it counts as unchanged.
    changed as (
        update public.music_relationships m
        set confidence = w.confidence,
            evidence_count = w.evidence_count,
            episode_count = w.episode_count,
            metadata = null,
            updated_at = now()
        from wanted w
        where m.from_entity_type = w.from_entity_type
          and m.from_entity_id = w.from_entity_id
          and m.to_entity_type = w.to_entity_type
          and m.to_entity_id = w.to_entity_id
          and m.relationship_type = w.relationship_type
          and (m.confidence, m.evidence_count,
               coalesce(m.episode_count, (m.metadata->>'episodes')::smallint))
              is distinct from (w.confidence, w.evidence_count, w.episode_count)
        returning 1
    ),
    -- And the ones that did not exist. DO NOTHING, never DO UPDATE: it does
    -- not lock, and a row it finds already there was written by somebody
    -- else a moment ago.
    added as (
        insert into public.music_relationships (
            from_entity_type, from_entity_id, to_entity_type, to_entity_id,
            relationship_type, confidence, source, evidence_count, episode_count)
        select w.from_entity_type, w.from_entity_id, w.to_entity_type, w.to_entity_id,
               w.relationship_type, w.confidence, w.source, w.evidence_count, w.episode_count
        from wanted w
        where not exists (
            select 1 from public.music_relationships m
            where m.from_entity_type = w.from_entity_type
              and m.from_entity_id = w.from_entity_id
              and m.to_entity_type = w.to_entity_type
              and m.to_entity_id = w.to_entity_id
              and m.relationship_type = w.relationship_type)
        on conflict do nothing
        returning 1
    )
    select (select count(*) from changed) + (select count(*) from added) into written;

    return written;
end $function$
;

CREATE OR REPLACE FUNCTION public.artist_radio_relations(p_artist_id uuid, p_limit integer DEFAULT 24)
 RETURNS TABLE(relationship_type text, entity_type text, entity_id uuid, title text, station text, provider text, external_id text, evidence_count integer, confidence double precision, metadata jsonb)
 LANGUAGE sql
 STABLE
AS $function$
with edge as (
    -- Shows, and neighbours seen twice or more, as stored. A stored single
    -- adjacency is never read (0078); single adjacencies are worked out
    -- below from the appearances, by the rebuild's own rule.
    select mr.relationship_type, mr.to_entity_type as kind, mr.to_entity_id as other,
           mr.evidence_count, mr.confidence,
           coalesce(mr.episode_count::int, (mr.metadata->>'episodes')::int) as episodes
    from public.music_relationships mr
    where mr.from_entity_type = 'artist' and mr.from_entity_id = p_artist_id
      and mr.source like 'radio%'
      and (mr.relationship_type <> 'radio_neighbor' or mr.evidence_count >= 2)
    union all
    select mr.relationship_type, mr.from_entity_type, mr.from_entity_id,
           mr.evidence_count, mr.confidence,
           coalesce(mr.episode_count::int, (mr.metadata->>'episodes')::int)
    from public.music_relationships mr
    where mr.to_entity_type = 'artist' and mr.to_entity_id = p_artist_id
      and mr.source like 'radio%'
      and (mr.relationship_type <> 'radio_neighbor' or mr.evidence_count >= 2)
    union all
    select 'radio_neighbor', 'artist', d.other, d.adjacencies,
           least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + d.adjacencies)))::double precision, d.episodes
    from (
        select b.artist_id as other, count(*)::int as adjacencies,
               count(distinct b.radio_episode_id)::int as episodes
        from public.radio_appearances a
        join public.radio_appearances b
          on b.radio_episode_id = a.radio_episode_id
         and b.track_index in (a.track_index - 1, a.track_index + 1)
        where a.artist_id = p_artist_id and b.artist_id is not null and b.artist_id <> p_artist_id
        group by b.artist_id
    ) d
    where not exists (
        select 1 from public.music_relationships m
        where m.from_entity_type = 'artist' and m.from_entity_id = least(p_artist_id, d.other)
          and m.to_entity_type = 'artist' and m.to_entity_id = greatest(p_artist_id, d.other)
          and m.relationship_type = 'radio_neighbor' and m.evidence_count >= 2)
)
select
    edge.relationship_type,
    edge.kind,
    edge.other,
    coalesce(rs.title, a.name),
    rs.station,
    rs.provider,
    rs.external_id,
    edge.evidence_count,
    edge.confidence,
    case edge.relationship_type
        when 'played_by' then
            jsonb_build_object('episodes', edge.episodes, 'appearances', edge.evidence_count)
        when 'radio_neighbor' then
            jsonb_build_object('adjacencies', edge.evidence_count, 'episodes', edge.episodes)
    end
from edge
left join public.radio_shows rs on edge.kind = 'radio_show' and rs.id = edge.other
left join public.artists a on edge.kind = 'artist' and a.id = edge.other
order by edge.evidence_count desc, edge.confidence desc
limit greatest(1, least(coalesce(p_limit, 24), 200));
$function$
;

CREATE OR REPLACE FUNCTION public.explore_knowledge(p_nodes jsonb, p_artists text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
    if p_nodes is null or jsonb_typeof(p_nodes) <> 'array' then
        raise exception 'explore_knowledge: p_nodes must be an array' using errcode = '22023';
    end if;
    if jsonb_array_length(p_nodes) > 12 then
        raise exception 'explore_knowledge: at most 12 nodes' using errcode = '22023';
    end if;
    if coalesce(cardinality(p_artists), 0) > 50 then
        raise exception 'explore_knowledge: at most 50 artists' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(p_nodes) n
               where jsonb_typeof(n) <> 'object' or length(n::text) > 600)
       or exists (select 1 from unnest(coalesce(p_artists, '{}')) a where length(a) > 300) then
        raise exception 'explore_knowledge: an input is malformed or too long' using errcode = '22023';
    end if;

    return (
-- QUERY BEGIN
with
nodes as (
    select n->>'id' as node_id, n->>'kind' as kind, coalesce(n->>'key', '') as key,
           case n->>'provider' when 'lot' then 'lotradio' else n->>'provider' end as provider,
           coalesce(n->>'handle', '') as handle,
           lower(coalesce(n->>'mbid', '')) as mbid,
           coalesce(n->>'discogsID', '') as discogs
    from jsonb_array_elements(p_nodes) n
),
wanted as (select distinct a as key from unnest(coalesce(p_artists, '{}')) a where a <> ''),
-- The starting points that are artists: the rows their key, their MBID or
-- their Discogs id name...
seed_rows as (
    select s.node_id, a.id from nodes s join public.artists a on a.normalized_name = s.key
    where s.kind = 'artist' and s.key <> ''
    union
    select s.node_id, a.id from nodes s join public.artists a on a.musicbrainz_id = s.mbid
    where s.kind = 'artist' and s.mbid <> ''
    union
    select s.node_id, e.entity_id from nodes s join public.external_ids e
      on e.provider = 'discogs' and e.entity_type = 'artist' and e.external_id = s.discogs
    where s.kind = 'artist' and s.discogs <> ''
),
-- ...every Discogs identity those rows carry -- their own, or one
-- MusicBrainz records for them (the worker's link_discogs_identity job;
-- provider musicbrainz_discogs) -- and the catalogue rows filed under each, which is
-- where the Discogs knowledge is. A linked id with no catalogue row is
-- reported but reads nothing: that is an alias for a later stage.
seed_links as (
    select r.node_id, e.external_id as discogs_id,
           case e.provider when 'discogs' then 'discogs' else 'musicbrainz' end as via
    from seed_rows r join public.external_ids e
      on e.entity_type = 'artist' and e.entity_id = r.id and e.provider in ('discogs', 'musicbrainz_discogs')
),
seed_catalogued as (
    select l.node_id, l.discogs_id, e.entity_id
    from seed_links l join public.external_ids e
      on e.provider = 'discogs' and e.entity_type = 'artist' and e.external_id = l.discogs_id
),
seed_artists as (
    select distinct x.node_id, a.id, a.name, s.key
    from (select node_id, id from seed_rows union select node_id, entity_id from seed_catalogued) x
    join public.artists a on a.id = x.id
    join nodes s on s.node_id = x.node_id
),
node_identities as (
    select l.node_id, jsonb_agg(distinct jsonb_build_object(
               'discogsID', l.discogs_id, 'via', l.via,
               'catalogued', exists (select 1 from seed_catalogued c where c.node_id = l.node_id and c.discogs_id = l.discogs_id)))
           as identities
    from seed_links l group by l.node_id
),
seed_labels as (
    select sa.node_id, l.id as label_id,
           (select min(e.external_id) from public.external_ids e
            where e.provider = 'discogs' and e.entity_type = 'label' and e.entity_id = l.id) as label_discogs,
           trim(regexp_replace(replace(regexp_replace(l.name, '\s*\(\d+\)', '', 'g'), '*', ''), '\s{2,}', ' ', 'g')) as label,
           count(distinct r.id) as releases
    from seed_artists sa
    join public.releases r on r.artist_id = sa.id
    join public.labels l on l.id = r.label_id
    where l.normalized_name not like 'not on label%'
      and l.normalized_name <> all('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])
      and l.normalized_name <> sa.key
    group by 1, 2, 3, 4
),
peers as (
    select sl.node_id, a.id, a.name, sl.label, count(distinct r.id) as shared
    from seed_labels sl
    join nodes n on n.node_id = sl.node_id
    join public.releases r on r.label_id = sl.label_id
    join public.artists a on a.id = r.artist_id
    where a.normalized_name <> n.key
      and not exists (select 1 from seed_artists x where x.node_id = sl.node_id and x.id = a.id)
    group by 1, 2, 3, 4
),
peers_kept as (
    select * from (
        select p.*, row_number() over (partition by p.node_id order by p.shared desc, p.name, p.label) as rank
        from peers p) ranked
    where rank <= 300
),
-- Played next to each other on the radio (0078). Twice or more: the stored
-- edge, as the rebuild keeps it. Once: worked out here from the appearances
-- by the rebuild's own rule (same episode, next track) and its confidence
-- formula -- a stored single adjacency is never read; those are retired.
neighbours as (
    select sa.node_id, m.to_entity_id as other, m.confidence, m.evidence_count
    from seed_artists sa join public.music_relationships m
      on m.from_entity_type = 'artist' and m.from_entity_id = sa.id
     and m.to_entity_type = 'artist' and m.relationship_type = 'radio_neighbor'
    where m.evidence_count >= 2
    union all
    select sa.node_id, m.from_entity_id, m.confidence, m.evidence_count
    from seed_artists sa join public.music_relationships m
      on m.to_entity_type = 'artist' and m.to_entity_id = sa.id
     and m.from_entity_type = 'artist' and m.relationship_type = 'radio_neighbor'
    where m.evidence_count >= 2
    union all
    select d.node_id, d.other,
           least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + d.adjacencies)))::double precision, d.adjacencies
    from (
        select sa.node_id, sa.id, b.artist_id as other, count(*)::int as adjacencies
        from seed_artists sa
        join public.radio_appearances a on a.artist_id = sa.id
        join public.radio_appearances b
          on b.radio_episode_id = a.radio_episode_id
         and b.track_index in (a.track_index - 1, a.track_index + 1)
        where b.artist_id is not null and b.artist_id <> sa.id
        group by sa.node_id, sa.id, b.artist_id
    ) d
    where not exists (
        select 1 from public.music_relationships m
        where m.from_entity_type = 'artist' and m.from_entity_id = least(d.id, d.other)
          and m.to_entity_type = 'artist' and m.to_entity_id = greatest(d.id, d.other)
          and m.relationship_type = 'radio_neighbor' and m.evidence_count >= 2)
),
seed_label_nodes as (
    select s.node_id, l.id, l.name from nodes s join public.labels l on l.normalized_name = s.key
    where s.kind = 'label' and s.key <> ''
      and l.normalized_name not like 'not on label%'
      and l.normalized_name <> all('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])
),
label_roster as (
    select * from (
        select sl.node_id, a.id, a.name, sl.name as label,
               row_number() over (partition by sl.node_id order by count(distinct r.id) desc, a.name) as rank
        from seed_label_nodes sl
        join public.releases r on r.label_id = sl.id
        join public.artists a on a.id = r.artist_id
        group by sl.node_id, a.id, a.name, sl.name) ranked
    where rank <= 300
),
seed_episodes as (
    select s.node_id, e.id, coalesce(e.title, '') as title
    from nodes s join public.radio_episodes e on e.provider = s.provider and e.external_id = s.handle
    where s.kind = 'broadcast'
),
seed_shows as (
    select s.node_id, rs.id, coalesce(rs.title, '') as title
    from nodes s join public.radio_shows rs on rs.provider = s.provider and rs.external_id = s.handle
    where s.kind = 'broadcast'
),
edges as (
    select node_id, jsonb_build_object(
        'kind', 'sharedLabel', 'reason', 'Releases on ' || label, 'confidence', 0.88, 'occurrences', releases,
        'to', jsonb_build_object('kind', 'label', 'name', label, 'discogsID', label_discogs)) as edge
    from seed_labels
    union all
    select node_id, jsonb_build_object(
        'kind', 'sharedLabel', 'reason', 'Both release on ' || label, 'confidence', 0.8, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'artist', 'name', name))
    from peers_kept
    union all
    select sa.node_id, jsonb_build_object(
        'kind', 'appearsOnRelease', 'reason', 'Released ' || r.title, 'confidence', 0.9, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'release', 'name', r.title, 'discogsID', r.discogs_id, 'year', r.release_year))
    from seed_artists sa join public.releases r on r.artist_id = sa.id
    where r.discogs_id is not null
    union all
    select n.node_id, jsonb_build_object(
        'kind', 'frequentlyPlayedNearby',
        'reason', case when n.evidence_count = 1 then 'Played next to each other on the radio'
                       else 'Played next to each other ' || n.evidence_count || ' times on the radio' end,
        'confidence', n.confidence, 'occurrences', n.evidence_count,
        'to', jsonb_build_object('kind', 'artist', 'name', o.name))
    from neighbours n join public.artists o on o.id = n.other
    union all
    select sa.node_id, jsonb_build_object(
        'kind', 'playedInShow', 'reason', 'Played on ' || coalesce(rs.title, ''), 'confidence', m.confidence,
        'occurrences', coalesce(m.episode_count, 1),
        'to', jsonb_build_object('kind', 'broadcast', 'name', coalesce(rs.title, ''),
              'providerID', case rs.provider when 'lotradio' then 'lot' else rs.provider end, 'handle', rs.external_id))
    from seed_artists sa
    join public.music_relationships m
      on m.from_entity_type = 'artist' and m.from_entity_id = sa.id
     and m.to_entity_type = 'radio_show' and m.relationship_type = 'played_by'
    join public.radio_shows rs on rs.id = m.to_entity_id
    union all
    select node_id, jsonb_build_object(
        'kind', 'sharedLabel', 'reason', 'Releases on ' || label, 'confidence', 0.88, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'artist', 'name', name))
    from label_roster
    union all
    select es.node_id, jsonb_build_object(
        'kind', 'playedInShow', 'reason', 'Played on ' || es.title, 'confidence', 0.7, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'artist', 'name', coalesce(a.name, ra.raw_artist_name)))
    from seed_episodes es
    join public.radio_appearances ra on ra.radio_episode_id = es.id
    left join public.artists a on a.id = ra.artist_id
    where coalesce(a.name, ra.raw_artist_name) is not null
    union all
    select ss.node_id, jsonb_build_object(
        'kind', 'playedInShow', 'reason', 'Played on ' || ss.title, 'confidence', m.confidence,
        'occurrences', coalesce(m.episode_count, 1),
        'to', jsonb_build_object('kind', 'artist', 'name', a.name))
    from seed_shows ss
    join public.music_relationships m
      on m.to_entity_type = 'radio_show' and m.to_entity_id = ss.id and m.relationship_type = 'played_by'
     and m.from_entity_type = 'artist'
    join public.artists a on a.id = m.from_entity_id
),
node_edges as (
    select node_id, jsonb_agg(edge order by edge::text) as edges from edges group by node_id
),
found_nodes as (
    select node_id from seed_artists union select node_id from seed_label_nodes
    union select node_id from seed_episodes union select node_id from seed_shows
),
node_answers as (
    select s.node_id,
           jsonb_build_object(
               'status', case
                   when s.kind not in ('artist', 'label', 'broadcast') then 'unsupported'
                   when f.node_id is not null then 'found'
                   else 'unknown' end,
               'edges', coalesce(ne.edges, '[]'::jsonb),
               'identities', coalesce(ni.identities, '[]'::jsonb)
           ) as answer
    from nodes s
    left join node_identities ni on ni.node_id = s.node_id
    left join (select distinct node_id from found_nodes) f on f.node_id = s.node_id
    left join node_edges ne on ne.node_id = s.node_id
),
-- Artists: where they were played, which scenes they are in, what those
-- broadcasts were tagged.
wanted_named as (select w.key, a.id from wanted w join public.artists a on a.normalized_name = w.key),
wanted_links as (
    select r.key, e.external_id as discogs_id,
           case e.provider when 'discogs' then 'discogs' else 'musicbrainz' end as via
    from wanted_named r join public.external_ids e
      on e.entity_type = 'artist' and e.entity_id = r.id and e.provider in ('discogs', 'musicbrainz_discogs')
),
wanted_catalogued as (
    select l.key, l.discogs_id, e.entity_id as id
    from wanted_links l join public.external_ids e
      on e.provider = 'discogs' and e.entity_type = 'artist' and e.external_id = l.discogs_id
),
wanted_rows as (select key, id from wanted_named union select key, id from wanted_catalogued),
wanted_identities as (
    select l.key, jsonb_agg(distinct jsonb_build_object(
               'discogsID', l.discogs_id, 'via', l.via,
               'catalogued', exists (select 1 from wanted_catalogued c where c.key = l.key and c.discogs_id = l.discogs_id)))
           as identities
    from wanted_links l group by l.key
),
artist_episodes as (
    select * from (
        select wr.key, e.id, e.provider, e.external_id, coalesce(e.title, '') as title, e.image_url, e.genres,
               row_number() over (partition by wr.key order by e.aired_at desc nulls last, e.id) as rank
        from (select distinct wr.key, ra.radio_episode_id
              from wanted_rows wr join public.radio_appearances ra on ra.artist_id = wr.id) wr
        join public.radio_episodes e on e.id = wr.radio_episode_id and e.tracklist_status = 'available') ranked
    where rank <= 60
),
artist_genres as (
    select key, jsonb_agg(g order by n desc, g) filter (where rank <= 8) as genres from (
        select key, g, n, row_number() over (partition by key order by n desc, g) as rank from (
            select ae.key, g, count(*) as n
            from artist_episodes ae, unnest(coalesce(ae.genres, '{}')) g
            group by 1, 2) counted) ranked
    group by key
),
roster_hits as (
    select w.key, r.id, r.place, r.place_key, r.sound, r.member_count
    from wanted w
    join public.scene_members m on m.normalized_name = w.key
    join public.scene_rosters r on r.id = m.roster_id
    where r.place is not null and r.place_key is not null and r.place_key <> ''
),
countries as (
    select distinct on (country) area_key
    from (select country, area_key, count(*) as n from public.artists
          where country is not null and area_key is not null
            and area_key in (select place_key from roster_hits)
          group by 1, 2) counted
    order by country, n desc, area_key
),
episodes_by_key as (
    select key, jsonb_agg(jsonb_build_object(
            'providerID', case provider when 'lotradio' then 'lot' else provider end,
            'showID', external_id, 'title', title, 'image', image_url,
            'genres', coalesce(to_jsonb(genres), '[]'::jsonb)) order by provider, external_id) as episodes
    from artist_episodes group by key
),
rosters_by_key as (
    select rh.key, jsonb_agg(jsonb_build_object(
            'place', rh.place, 'sound', rh.sound, 'members', rh.member_count) order by rh.place_key, rh.sound) as rosters
    from roster_hits rh
    where rh.place_key not in (select area_key from countries)
    group by rh.key
),
artist_answers as (
    select w.key, jsonb_build_object(
        'status', case when f.key is not null then 'found' else 'unknown' end,
        'episodes', coalesce(eb.episodes, '[]'::jsonb),
        'rosters', coalesce(rb.rosters, '[]'::jsonb),
        'genres', coalesce(ag.genres, '[]'::jsonb),
        'identities', coalesce(wi.identities, '[]'::jsonb)
    ) as answer
    from wanted w
    left join wanted_identities wi on wi.key = w.key
    left join (select distinct key from wanted_rows) f on f.key = w.key
    left join episodes_by_key eb on eb.key = w.key
    left join rosters_by_key rb on rb.key = w.key
    left join artist_genres ag on ag.key = w.key
)
select jsonb_build_object(
    'format', 2,
    'asOf', now(),
    -- The edge rebuild runs at 23 minutes past every third hour (UTC); its
    -- slot names the generation an answer's edges come from, and when the
    -- next one is due, so a device knows when asking again could change it.
    'generation', 'edges-' || floor((extract(epoch from now()) - 23 * 60) / 10800)::bigint,
    'nextGenerationAt', to_timestamp((floor((extract(epoch from now()) - 23 * 60) / 10800) + 1) * 10800 + 23 * 60),
    'nodes', coalesce((select jsonb_object_agg(node_id, answer) from node_answers), '{}'::jsonb),
    'artists', coalesce((select jsonb_object_agg(key, answer) from artist_answers), '{}'::jsonb)
)
-- QUERY END
    );
end
$function$
;

CREATE OR REPLACE FUNCTION public.knowledge_answers(p_nodes jsonb, p_artists text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
    if p_nodes is null or jsonb_typeof(p_nodes) <> 'array' then
        raise exception 'knowledge_answers: p_nodes must be an array' using errcode = '22023';
    end if;
    if jsonb_array_length(p_nodes) > 12 then
        raise exception 'knowledge_answers: at most 12 nodes' using errcode = '22023';
    end if;
    if coalesce(cardinality(p_artists), 0) > 50 then
        raise exception 'knowledge_answers: at most 50 artists' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(p_nodes) n
               where jsonb_typeof(n) <> 'object' or length(n::text) > 600)
       or exists (select 1 from unnest(coalesce(p_artists, '{}')) a where length(a) > 300) then
        raise exception 'knowledge_answers: an input is malformed or too long' using errcode = '22023';
    end if;

    return (
-- QUERY BEGIN
with
nodes as (
    select n->>'id' as node_id, n->>'kind' as kind, coalesce(n->>'key', '') as key,
           case n->>'provider' when 'lot' then 'lotradio' else n->>'provider' end as provider,
           coalesce(n->>'handle', '') as handle,
           lower(coalesce(n->>'mbid', '')) as mbid,
           coalesce(n->>'discogsID', '') as discogs
    from jsonb_array_elements(p_nodes) n
),
wanted as (select distinct a as key from unnest(coalesce(p_artists, '{}')) a where a <> ''),
-- The starting points that are artists: the rows their key, their MBID or
-- their Discogs id name...
seed_rows_by as (
    select s.node_id, a.id, 'name' as by from nodes s join public.artists a on a.normalized_name = s.key
    where s.kind = 'artist' and s.key <> ''
    union
    select s.node_id, a.id, 'mbid' from nodes s join public.artists a on a.musicbrainz_id = s.mbid
    where s.kind = 'artist' and s.mbid <> ''
    union
    select s.node_id, e.entity_id, 'discogs' from nodes s join public.external_ids e
      on e.provider = 'discogs' and e.entity_type = 'artist' and e.external_id = s.discogs
    where s.kind = 'artist' and s.discogs <> ''
),
-- The same rows explore_knowledge's seed_rows finds; the route that found
-- each is kept for the seed listing below.
seed_rows as (select distinct node_id, id from seed_rows_by),
-- ...every Discogs identity those rows carry -- their own, or one
-- MusicBrainz records for them (the worker's link_discogs_identity job;
-- provider musicbrainz_discogs) -- and the catalogue rows filed under each, which is
-- where the Discogs knowledge is. A linked id with no catalogue row is
-- reported but reads nothing: that is an alias for a later stage.
seed_links as (
    select r.node_id, e.external_id as discogs_id,
           case e.provider when 'discogs' then 'discogs' else 'musicbrainz' end as via
    from seed_rows r join public.external_ids e
      on e.entity_type = 'artist' and e.entity_id = r.id and e.provider in ('discogs', 'musicbrainz_discogs')
),
seed_catalogued as (
    select l.node_id, l.discogs_id, e.entity_id
    from seed_links l join public.external_ids e
      on e.provider = 'discogs' and e.entity_type = 'artist' and e.external_id = l.discogs_id
),
seed_artists as (
    select distinct x.node_id, a.id, a.name, s.key
    from (select node_id, id from seed_rows union select node_id, entity_id from seed_catalogued) x
    join public.artists a on a.id = x.id
    join nodes s on s.node_id = x.node_id
),
node_identities as (
    select l.node_id, jsonb_agg(distinct jsonb_build_object(
               'discogsID', l.discogs_id, 'via', l.via,
               'catalogued', exists (select 1 from seed_catalogued c where c.node_id = l.node_id and c.discogs_id = l.discogs_id)))
           as identities
    from seed_links l group by l.node_id
),
seed_labels as (
    select sa.node_id, l.id as label_id,
           (select min(e.external_id) from public.external_ids e
            where e.provider = 'discogs' and e.entity_type = 'label' and e.entity_id = l.id) as label_discogs,
           trim(regexp_replace(replace(regexp_replace(l.name, '\s*\(\d+\)', '', 'g'), '*', ''), '\s{2,}', ' ', 'g')) as label,
           count(distinct r.id) as releases
    from seed_artists sa
    join public.releases r on r.artist_id = sa.id
    join public.labels l on l.id = r.label_id
    where l.normalized_name not like 'not on label%'
      and l.normalized_name <> all('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])
      and l.normalized_name <> sa.key
    group by 1, 2, 3, 4
),
peers as (
    select sl.node_id, a.id, a.name, sl.label, count(distinct r.id) as shared,
           bool_or(r.discogs_id is not null) as via_discogs
    from seed_labels sl
    join nodes n on n.node_id = sl.node_id
    join public.releases r on r.label_id = sl.label_id
    join public.artists a on a.id = r.artist_id
    where a.normalized_name <> n.key
      and not exists (select 1 from seed_artists x where x.node_id = sl.node_id and x.id = a.id)
    group by 1, 2, 3, 4
),
peers_kept as (
    select * from (
        select p.*, row_number() over (partition by p.node_id order by p.shared desc, p.name, p.label) as rank
        from peers p) ranked
    where rank <= 300
),
-- Played next to each other on the radio (0078). Twice or more: the stored
-- edge, as the rebuild keeps it. Once: worked out here from the appearances
-- by the rebuild's own rule (same episode, next track) and its confidence
-- formula -- a stored single adjacency is never read; those are retired.
neighbours as (
    select sa.node_id, m.to_entity_id as other, m.confidence, m.evidence_count
    from seed_artists sa join public.music_relationships m
      on m.from_entity_type = 'artist' and m.from_entity_id = sa.id
     and m.to_entity_type = 'artist' and m.relationship_type = 'radio_neighbor'
    where m.evidence_count >= 2
    union all
    select sa.node_id, m.from_entity_id, m.confidence, m.evidence_count
    from seed_artists sa join public.music_relationships m
      on m.to_entity_type = 'artist' and m.to_entity_id = sa.id
     and m.from_entity_type = 'artist' and m.relationship_type = 'radio_neighbor'
    where m.evidence_count >= 2
    union all
    select d.node_id, d.other,
           least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + d.adjacencies)))::double precision, d.adjacencies
    from (
        select sa.node_id, sa.id, b.artist_id as other, count(*)::int as adjacencies
        from seed_artists sa
        join public.radio_appearances a on a.artist_id = sa.id
        join public.radio_appearances b
          on b.radio_episode_id = a.radio_episode_id
         and b.track_index in (a.track_index - 1, a.track_index + 1)
        where b.artist_id is not null and b.artist_id <> sa.id
        group by sa.node_id, sa.id, b.artist_id
    ) d
    where not exists (
        select 1 from public.music_relationships m
        where m.from_entity_type = 'artist' and m.from_entity_id = least(d.id, d.other)
          and m.to_entity_type = 'artist' and m.to_entity_id = greatest(d.id, d.other)
          and m.relationship_type = 'radio_neighbor' and m.evidence_count >= 2)
),
seed_label_nodes as (
    select s.node_id, l.id, l.name from nodes s join public.labels l on l.normalized_name = s.key
    where s.kind = 'label' and s.key <> ''
      and l.normalized_name not like 'not on label%'
      and l.normalized_name <> all('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])
),
label_roster as (
    select * from (
        select sl.node_id, a.id, a.name, sl.name as label,
               bool_or(r.discogs_id is not null) as via_discogs,
               row_number() over (partition by sl.node_id order by count(distinct r.id) desc, a.name) as rank
        from seed_label_nodes sl
        join public.releases r on r.label_id = sl.id
        join public.artists a on a.id = r.artist_id
        group by sl.node_id, a.id, a.name, sl.name) ranked
    where rank <= 300
),
seed_episodes as (
    select s.node_id, e.id, coalesce(e.title, '') as title
    from nodes s join public.radio_episodes e on e.provider = s.provider and e.external_id = s.handle
    where s.kind = 'broadcast'
),
seed_shows as (
    select s.node_id, rs.id, coalesce(rs.title, '') as title
    from nodes s join public.radio_shows rs on rs.provider = s.provider and rs.external_id = s.handle
    where s.kind = 'broadcast'
),
edges as (
    select node_id, null::uuid as row_id, null::text as route, jsonb_build_object(
        'kind', 'sharedLabel', 'reason', 'Releases on ' || label, 'confidence', 0.88, 'occurrences', releases,
        'to', jsonb_build_object('kind', 'label', 'name', label, 'discogsID', label_discogs)) as edge
    from seed_labels
    union all
    select node_id, id, case when via_discogs then 'discogs' else 'catalogue' end, jsonb_build_object(
        'kind', 'sharedLabel', 'reason', 'Both release on ' || label, 'confidence', 0.8, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'artist', 'name', name))
    from peers_kept
    union all
    select sa.node_id, null::uuid, null::text, jsonb_build_object(
        'kind', 'appearsOnRelease', 'reason', 'Released ' || r.title, 'confidence', 0.9, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'release', 'name', r.title, 'discogsID', r.discogs_id, 'year', r.release_year))
    from seed_artists sa join public.releases r on r.artist_id = sa.id
    where r.discogs_id is not null
    union all
    select n.node_id, o.id, 'radio', jsonb_build_object(
        'kind', 'frequentlyPlayedNearby',
        'reason', case when n.evidence_count = 1 then 'Played next to each other on the radio'
                       else 'Played next to each other ' || n.evidence_count || ' times on the radio' end,
        'confidence', n.confidence, 'occurrences', n.evidence_count,
        'to', jsonb_build_object('kind', 'artist', 'name', o.name))
    from neighbours n join public.artists o on o.id = n.other
    union all
    select sa.node_id, null::uuid, null::text, jsonb_build_object(
        'kind', 'playedInShow', 'reason', 'Played on ' || coalesce(rs.title, ''), 'confidence', m.confidence,
        'occurrences', coalesce(m.episode_count, 1),
        'to', jsonb_build_object('kind', 'broadcast', 'name', coalesce(rs.title, ''),
              'providerID', case rs.provider when 'lotradio' then 'lot' else rs.provider end, 'handle', rs.external_id))
    from seed_artists sa
    join public.music_relationships m
      on m.from_entity_type = 'artist' and m.from_entity_id = sa.id
     and m.to_entity_type = 'radio_show' and m.relationship_type = 'played_by'
    join public.radio_shows rs on rs.id = m.to_entity_id
    union all
    select node_id, id, case when via_discogs then 'discogs' else 'catalogue' end, jsonb_build_object(
        'kind', 'sharedLabel', 'reason', 'Releases on ' || label, 'confidence', 0.88, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'artist', 'name', name))
    from label_roster
    union all
    select es.node_id, a.id, 'radio', jsonb_build_object(
        'kind', 'playedInShow', 'reason', 'Played on ' || es.title, 'confidence', 0.7, 'occurrences', 1,
        'to', jsonb_build_object('kind', 'artist', 'name', coalesce(a.name, ra.raw_artist_name)))
    from seed_episodes es
    join public.radio_appearances ra on ra.radio_episode_id = es.id
    left join public.artists a on a.id = ra.artist_id
    where coalesce(a.name, ra.raw_artist_name) is not null
    union all
    select ss.node_id, a.id, 'radio', jsonb_build_object(
        'kind', 'playedInShow', 'reason', 'Played on ' || ss.title, 'confidence', m.confidence,
        'occurrences', coalesce(m.episode_count, 1),
        'to', jsonb_build_object('kind', 'artist', 'name', a.name))
    from seed_shows ss
    join public.music_relationships m
      on m.to_entity_type = 'radio_show' and m.to_entity_id = ss.id and m.relationship_type = 'played_by'
     and m.from_entity_type = 'artist'
    join public.artists a on a.id = m.from_entity_id
),
-- What identifies each artist target. A Discogs id is carried as
-- `discogs-document` only when a Discogs release document reached the row
-- (label peers and rosters through a release with a Discogs id); reached by
-- radio, any id the row holds was joined to a radio name by name and is
-- `adopted-by-name`; reached through a release with no Discogs id, it is
-- `name-matched`. Nothing here derives an id from a name.
target_ids as (
    select e.row_id, min(x.external_id) as discogs_id, count(distinct x.external_id) as ids
    from (select distinct row_id from edges where row_id is not null) e
    join public.external_ids x on x.entity_type = 'artist' and x.entity_id = e.row_id and x.provider = 'discogs'
    group by e.row_id
),
shared_names as (
    select node_id, lower(edge->'to'->>'name') as name
    from edges where row_id is not null
    group by 1, 2 having count(distinct row_id) > 1
),
evidenced as (
    select e.node_id,
           case when e.row_id is null then e.edge
                else jsonb_set(e.edge, '{to}', (e.edge->'to') || jsonb_strip_nulls(jsonb_build_object(
                    'rowID', e.row_id,
                    'discogsID', case when t.ids = 1 then t.discogs_id end,
                    'idEvidence', case when t.ids is null then null
                                       when t.ids > 1 then 'several-ids'
                                       when e.route = 'discogs' then 'discogs-document'
                                       when e.route = 'radio' then 'adopted-by-name'
                                       else 'name-matched' end,
                    'sharedName', case when s.name is not null then true end)))
           end as edge
    from edges e
    left join target_ids t on t.row_id = e.row_id
    left join shared_names s on s.node_id = e.node_id and s.name = lower(e.edge->'to'->>'name')
),
node_edges as (
    select node_id, jsonb_agg(edge order by edge::text) as edges from evidenced group by node_id
),
found_nodes as (
    select node_id from seed_artists union select node_id from seed_label_nodes
    union select node_id from seed_episodes union select node_id from seed_shows
),
-- The catalogue rows a starting point was walked from, and how each was
-- reached. explore_knowledge walks every row its name matches as one
-- starting point (two "speedy j" rows are one neighbourhood); that walk is
-- kept, and said: `ambiguousName` when the name matched more than one row.
seed_detail as (
    select r.node_id,
           jsonb_agg(jsonb_build_object(
               'rowID', r.id, 'name', a.name, 'by', to_jsonb(r.by),
               'discogsID', (select min(e.external_id) from public.external_ids e
                             where e.entity_type = 'artist' and e.entity_id = r.id and e.provider = 'discogs'))
               order by r.id) as seeds,
           count(*) filter (where 'name' = any(r.by)) > 1 as ambiguous
    from (select x.node_id, x.id, array_agg(distinct x.by order by x.by) as by
          from (select node_id, id, by from seed_rows_by
                union
                select c.node_id, c.entity_id, 'identity' from seed_catalogued c) x
          group by x.node_id, x.id) r
    join public.artists a on a.id = r.id
    group by r.node_id
),
node_answers as (
    select s.node_id,
           jsonb_build_object(
               'status', case
                   when s.kind not in ('artist', 'label', 'broadcast') then 'unsupported'
                   when f.node_id is not null then 'found'
                   else 'unknown' end,
               'edges', coalesce(ne.edges, '[]'::jsonb),
               'identities', coalesce(ni.identities, '[]'::jsonb)
           ) || jsonb_strip_nulls(jsonb_build_object(
               'seeds', sd.seeds,
               'ambiguousName', case when sd.ambiguous then true end)) as answer
    from nodes s
    left join seed_detail sd on sd.node_id = s.node_id
    left join node_identities ni on ni.node_id = s.node_id
    left join (select distinct node_id from found_nodes) f on f.node_id = s.node_id
    left join node_edges ne on ne.node_id = s.node_id
),
-- Artists: where they were played, which scenes they are in, what those
-- broadcasts were tagged.
wanted_named as (select w.key, a.id from wanted w join public.artists a on a.normalized_name = w.key),
wanted_links as (
    select r.key, e.external_id as discogs_id,
           case e.provider when 'discogs' then 'discogs' else 'musicbrainz' end as via
    from wanted_named r join public.external_ids e
      on e.entity_type = 'artist' and e.entity_id = r.id and e.provider in ('discogs', 'musicbrainz_discogs')
),
wanted_catalogued as (
    select l.key, l.discogs_id, e.entity_id as id
    from wanted_links l join public.external_ids e
      on e.provider = 'discogs' and e.entity_type = 'artist' and e.external_id = l.discogs_id
),
wanted_rows as (select key, id from wanted_named union select key, id from wanted_catalogued),
wanted_identities as (
    select l.key, jsonb_agg(distinct jsonb_build_object(
               'discogsID', l.discogs_id, 'via', l.via,
               'catalogued', exists (select 1 from wanted_catalogued c where c.key = l.key and c.discogs_id = l.discogs_id)))
           as identities
    from wanted_links l group by l.key
),
artist_episodes as (
    select * from (
        select wr.key, e.id, e.provider, e.external_id, coalesce(e.title, '') as title, e.image_url, e.genres,
               row_number() over (partition by wr.key order by e.aired_at desc nulls last, e.id) as rank
        from (select distinct wr.key, ra.radio_episode_id
              from wanted_rows wr join public.radio_appearances ra on ra.artist_id = wr.id) wr
        join public.radio_episodes e on e.id = wr.radio_episode_id and e.tracklist_status = 'available') ranked
    where rank <= 60
),
artist_genres as (
    select key, jsonb_agg(g order by n desc, g) filter (where rank <= 8) as genres from (
        select key, g, n, row_number() over (partition by key order by n desc, g) as rank from (
            select ae.key, g, count(*) as n
            from artist_episodes ae, unnest(coalesce(ae.genres, '{}')) g
            group by 1, 2) counted) ranked
    group by key
),
roster_hits as (
    select w.key, r.id, r.place, r.place_key, r.sound, r.member_count
    from wanted w
    join public.scene_members m on m.normalized_name = w.key
    join public.scene_rosters r on r.id = m.roster_id
    where r.place is not null and r.place_key is not null and r.place_key <> ''
),
countries as (
    select distinct on (country) area_key
    from (select country, area_key, count(*) as n from public.artists
          where country is not null and area_key is not null
            and area_key in (select place_key from roster_hits)
          group by 1, 2) counted
    order by country, n desc, area_key
),
episodes_by_key as (
    select key, jsonb_agg(jsonb_build_object(
            'providerID', case provider when 'lotradio' then 'lot' else provider end,
            'showID', external_id, 'title', title, 'image', image_url,
            'genres', coalesce(to_jsonb(genres), '[]'::jsonb)) order by provider, external_id) as episodes
    from artist_episodes group by key
),
rosters_by_key as (
    select rh.key, jsonb_agg(jsonb_build_object(
            'place', rh.place, 'sound', rh.sound, 'members', rh.member_count) order by rh.place_key, rh.sound) as rosters
    from roster_hits rh
    where rh.place_key not in (select area_key from countries)
    group by rh.key
),
artist_answers as (
    select w.key, jsonb_build_object(
        'status', case when f.key is not null then 'found' else 'unknown' end,
        'episodes', coalesce(eb.episodes, '[]'::jsonb),
        'rosters', coalesce(rb.rosters, '[]'::jsonb),
        'genres', coalesce(ag.genres, '[]'::jsonb),
        'identities', coalesce(wi.identities, '[]'::jsonb)
    ) as answer
    from wanted w
    left join wanted_identities wi on wi.key = w.key
    left join (select distinct key from wanted_rows) f on f.key = w.key
    left join episodes_by_key eb on eb.key = w.key
    left join rosters_by_key rb on rb.key = w.key
    left join artist_genres ag on ag.key = w.key
)
select jsonb_build_object(
    'format', 3,
    'asOf', now(),
    -- The edge rebuild runs at 23 minutes past every third hour (UTC); its
    -- slot names the generation an answer's edges come from, and when the
    -- next one is due, so a device knows when asking again could change it.
    'generation', 'edges-' || floor((extract(epoch from now()) - 23 * 60) / 10800)::bigint,
    'nextGenerationAt', to_timestamp((floor((extract(epoch from now()) - 23 * 60) / 10800) + 1) * 10800 + 23 * 60),
    'nodes', coalesce((select jsonb_object_agg(node_id, answer) from node_answers), '{}'::jsonb),
    'artists', coalesce((select jsonb_object_agg(key, answer) from artist_answers), '{}'::jsonb)
)
-- QUERY END
    );
end
$function$
;

create or replace function public.app_callable_functions()
returns text[]
language sql
immutable
as $function$
    select array[
        'app_callable_functions',
        'artist_radio_appearances',
        'artist_radio_relations',
        'artist_radio_summary',
        'credit_row_count',
        'dig_enrichment_config',
        'dig_radio_for_artists',
        'enrichment_queue_health',
        'episode_tracklist',
        'explore_knowledge',
        'label_radio_summary',
        'portrait_changes_since',
        'portrait_states_for_artists',
        'portraits_for_artists',
        'release_cache_coverage',
        'request_artist_shelf',
        'request_release_cache',
        'request_scene_roster',
        'search_archives',
        'search_catalog'
    ]
$function$;

drop function if exists public.artist_show_counts(uuid[]);
