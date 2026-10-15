-- 0073: explore_knowledge finds artists by identity, not only by name.
--
-- 0072 looked artists up by their normalised name, and the catalogue holds
-- some people twice: "Anika" from NTS, with her MusicBrainz id, and "Anika
-- (9)" from Discogs, with her Discogs id -- "(9)" being Discogs' way of saying
-- eight other artists share the name. Asked about "anika", it found the row
-- without the Discogs id, and her Discogs knowledge was out of reach. Stripping
-- the "(9)" and matching would join her to whichever namesake came first.
--
-- So an artist is now found by what identifies it: the name key as before,
-- and an MBID or a Discogs id when the app has one (new optional fields on each
-- node). From those rows it follows every Discogs identity they carry -- their
-- own, or one MusicBrainz records for them, which the worker's
-- link_discogs_identity job writes to external_ids as provider
-- musicbrainz_discogs -- to the catalogue rows filed under it. Each answer
-- lists the identities it used and how each was found ("identities": Discogs
-- id, via discogs or musicbrainz, and whether the catalogue holds data for
-- it), and edge targets carry Discogs ids for artists and labels where the
-- catalogue has them, so the app can fetch their knowledge bundles.
--
-- Same signature, same bounds, same rights: STABLE, security invoker,
-- read-only. The answer's format is 2.

create or replace function public.explore_knowledge(p_nodes jsonb, p_artists text[])
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $function$
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
neighbours as (
    select sa.node_id, m.to_entity_id as other, m.confidence, m.evidence_count
    from seed_artists sa join public.music_relationships m
      on m.from_entity_type = 'artist' and m.from_entity_id = sa.id
     and m.to_entity_type = 'artist' and m.relationship_type = 'radio_neighbor'
    union all
    select sa.node_id, m.from_entity_id, m.confidence, m.evidence_count
    from seed_artists sa join public.music_relationships m
      on m.to_entity_type = 'artist' and m.to_entity_id = sa.id
     and m.from_entity_type = 'artist' and m.relationship_type = 'radio_neighbor'
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
        'to', jsonb_build_object('kind', 'artist', 'name', name,
              'discogsID', (select min(e.external_id) from public.external_ids e
               where e.entity_type = 'artist' and e.entity_id = peers_kept.id and e.provider = 'discogs')))
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
        'to', jsonb_build_object('kind', 'artist', 'name', o.name,
              'discogsID', (select min(e.external_id) from public.external_ids e
               where e.entity_type = 'artist' and e.entity_id = o.id and e.provider = 'discogs')))
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
        'to', jsonb_build_object('kind', 'artist', 'name', name,
              'discogsID', (select min(e.external_id) from public.external_ids e
               where e.entity_type = 'artist' and e.entity_id = label_roster.id and e.provider = 'discogs')))
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
        'to', jsonb_build_object('kind', 'artist', 'name', a.name,
              'discogsID', (select min(e.external_id) from public.external_ids e
               where e.entity_type = 'artist' and e.entity_id = a.id and e.provider = 'discogs')))
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
$function$;

grant execute on function public.explore_knowledge(jsonb, text[]) to anon, authenticated, service_role;
