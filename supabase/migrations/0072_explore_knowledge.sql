-- 0072: For You's shared knowledge, read by entity.
--
-- For You ranks on the device from two things: the listener's own rows, and
-- what is known about music around them. Until now the second came from each
-- device's own caches, so the Mac and the phone ranked from different
-- knowledge. This is the read that lets them rank from the same knowledge: a
-- shadow source at first, compared on the device against the caches, not
-- shown.
--
-- Shaped so its answers can be kept by identity. It is asked about entities --
-- starting points (an artist, a label, a broadcast) and artists -- and every
-- answer is about that entity alone, never about who asked or what else they
-- keep. Personal taste and exclusions are worked out on the device. A play
-- that does not change the starting points asks for nothing new.
--
--   explore_knowledge(p_nodes, p_artists) -> jsonb
--   p_nodes:   [{id, kind, key, provider, handle}], at most 12 -- what to walk
--              one step out of. `kind` is the app's node kind; `provider` the
--              app's provider id (`lot`, not `lotradio`).
--   p_artists: normalised artist keys, at most 50 -- whose broadcasts, scene
--              rosters and genres to return.
--
-- The bounds are what keeps one call inside anon's three-second statement
-- timeout. Measured on the live database (2026-10-08), the worst case of the
-- most-played artists in the catalogue -- 12 starting points and 50 artists --
-- ran in 0.5-1.6s; this device's real For You (12 starting points, 148
-- artists asked in three calls) in about 130ms a call, warm. Larger asks are
-- batched by the app: every answer is about one entity, so a batch changes
-- nothing about what is answered.
--
-- One statement, STABLE: every row it reads is from one snapshot of the
-- database, so a response never mixes an edge rebuild with half of the next.
-- Read-only and SECURITY INVOKER: it reads what anon can already read, under
-- the same row policies (SELECT-only), and needs no other right.
--
-- Cleaning matches the app, which applies its own rules to the answer again
-- (it is the authority); these exist so the answer is small and not crowded:
-- - labels: "Not On Label…" and the placeholder names in LabelName.swift are
--   not labels; Discogs' disambiguators ("Stroom (2)") and asterisks are
--   stripped from names, as DiscogsClient.withoutDisambiguator does; an
--   artist's own name as its label is skipped (LabelName.isOwnName);
-- - stations: Supabase's `lotradio` is the app's `lot`;
-- - places: a roster with no place, or whose place is a country, is not a
--   scene. A country is the area most of a country code's artists are filed
--   under (MusicBrainz files most artists by country), which is what the app
--   reads as the part after the slash in an origin.

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
           coalesce(n->>'handle', '') as handle
    from jsonb_array_elements(p_nodes) n
),
wanted as (select distinct a as key from unnest(coalesce(p_artists, '{}')) a where a <> ''),
-- The starting points that are artists, and every artist row under their key.
seed_artists as (
    select s.node_id, a.id, a.name, s.key
    from nodes s join public.artists a on a.normalized_name = s.key
    where s.kind = 'artist' and s.key <> ''
),
seed_labels as (
    select sa.node_id, l.id as label_id,
           trim(regexp_replace(replace(regexp_replace(l.name, '\s*\(\d+\)', '', 'g'), '*', ''), '\s{2,}', ' ', 'g')) as label,
           count(distinct r.id) as releases
    from seed_artists sa
    join public.releases r on r.artist_id = sa.id
    join public.labels l on l.id = r.label_id
    where l.normalized_name not like 'not on label%'
      and l.normalized_name <> all('{"","unknown label","no label","none","unknown","self released","self release","self releases","selfrelease","selfreleased","self published","self issued","self titled","selftitled","independent","independently released","diy","white label","no label records","own label","private press","bootleg"}'::text[])
      and l.normalized_name <> sa.key
    group by 1, 2, 3
),
peers as (
    select sl.node_id, a.name, sl.label, count(distinct r.id) as shared
    from seed_labels sl
    join nodes n on n.node_id = sl.node_id
    join public.releases r on r.label_id = sl.label_id
    join public.artists a on a.id = r.artist_id
    where a.normalized_name <> n.key
    group by 1, 2, 3
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
        select sl.node_id, a.name, sl.name as label,
               row_number() over (partition by sl.node_id order by count(distinct r.id) desc, a.name) as rank
        from seed_label_nodes sl
        join public.releases r on r.label_id = sl.id
        join public.artists a on a.id = r.artist_id
        group by sl.node_id, a.name, sl.name) ranked
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
        'to', jsonb_build_object('kind', 'label', 'name', label)) as edge
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
               'edges', coalesce(ne.edges, '[]'::jsonb)
           ) as answer
    from nodes s
    left join (select distinct node_id from found_nodes) f on f.node_id = s.node_id
    left join node_edges ne on ne.node_id = s.node_id
),
-- Artists: where they were played, which scenes they are in, what those
-- broadcasts were tagged.
wanted_rows as (select w.key, a.id from wanted w join public.artists a on a.normalized_name = w.key),
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
        'genres', coalesce(ag.genres, '[]'::jsonb)
    ) as answer
    from wanted w
    left join (select distinct key from wanted_rows) f on f.key = w.key
    left join episodes_by_key eb on eb.key = w.key
    left join rosters_by_key rb on rb.key = w.key
    left join artist_genres ag on ag.key = w.key
)
select jsonb_build_object(
    'format', 1,
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

revoke all on function public.explore_knowledge(jsonb, text[]) from public, anon, authenticated;
grant execute on function public.explore_knowledge(jsonb, text[]) to anon, authenticated, service_role;

-- The one list of what the app may call (see 0023). A function not named here
-- loses anon's EXECUTE the next time that sweep runs.
create or replace function public.app_callable_functions()
returns text[]
language sql
immutable
as $$
    select array[
        'app_callable_functions',
        'artist_radio_appearances',
        'artist_radio_relations',
        'artist_radio_summary',
        'credit_row_count',
        'dig_radio_for_artists',
        'enrichment_queue_health',
        'episode_tracklist',
        'explore_knowledge',
        'label_radio_summary',
        'portraits_for_artists',
        'release_cache_coverage',
        'request_artist_shelf',
        'request_release_cache',
        'request_scene_roster',
        'search_archives',
        'search_catalog'
    ]
$$;
grant execute on function public.app_callable_functions() to anon, authenticated, service_role;
