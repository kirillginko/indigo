-- 0075: knowledge_cut — one consistent cut of the knowledge For You reads,
-- for the publishing worker only (SHARED-KNOWLEDGE.md §9–10).
--
-- Two functions, neither callable with the app's key:
--
--   knowledge_answers(p_nodes, p_artists) -> jsonb
--     explore_knowledge's query (0074) for one batch, with every artist
--     target carrying the catalogue row it came from and what identifies
--     it: `rowID`, a Discogs id with its `idEvidence`, and `sharedName` when
--     two rows under one starting point share a name (two "speedy j" rows
--     stay two). Evidence follows the route as well as the row: through a
--     Discogs release document, `discogs-document`; through radio, a radio
--     name whose Discogs id was joined to it by name, `adopted-by-name`;
--     through a release with no Discogs id, `name-matched`. Each node also
--     lists its seed rows and how each was reached, with `ambiguousName`
--     when its name matched more than one row (explore_knowledge walks them
--     as one starting point; the walk is kept, and said). Strip those fields
--     and the answer is explore_knowledge's, from the same snapshot.
--     explore_knowledge itself is unchanged; the app keeps calling it.
--
--   knowledge_cut(p_day, p_demand) -> jsonb
--     The whole demand set as ONE statement, so every answer comes from one
--     database snapshot: STABLE functions called from a query use that
--     query's snapshot. Before answering anything it requires, inside the
--     same statement:
--       - p_day is today (UTC);
--       - the demand set is the frozen pilot set (its jsonb digest), within
--         bounds;
--       - pg_cron's `indigo-rebuild-edges` succeeded in today's 00:23 slot
--         and finished before this statement began.
--     Otherwise it answers nothing and says why. The clock-derived
--     `generation` label in each batch answer is left as it is and is not
--     proof of anything; the cut's own `rebuild` block is.
--
-- Read-only. SECURITY DEFINER (owner postgres) because the rebuild proof
-- reads cron.job_run_details, which the client roles cannot; revoked from
-- PUBLIC, anon and authenticated by name (0023: Supabase's default
-- privileges grant new public functions to both), executable by
-- service_role only, and not in app_callable_functions().
--
-- Measured (2026-10-12, live, as one SELECT): 589 ms warm, 69,213 buffer
-- hits, no disk reads, 950 KB for the pilot set. service_role has no
-- statement timeout; none is changed here.

create or replace function public.knowledge_answers(p_nodes jsonb, p_artists text[])
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $function$
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
$function$;

create or replace function public.knowledge_cut(p_day date, p_demand jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
with
-- The frozen pilot demand set (supabase/functions/_shared/testdata/
-- pilot_demand_v1.json; file sha256 4058f30a…bad57d), by the digest of its
-- jsonb text. A different set is refused until the next stage says otherwise.
frozen as (select '5754856d891959f5454fc88e44d536269b8a223bb1ac3f1d4bafa9e7c06c88e0'::text as digest),
demand as (
    select encode(sha256(convert_to(coalesce(p_demand, 'null'::jsonb)::text, 'UTF8')), 'hex') as digest,
           coalesce(jsonb_array_length(case when jsonb_typeof(p_demand->'nodes') = 'array' then p_demand->'nodes' end), -1) as nodes,
           coalesce(jsonb_array_length(case when jsonb_typeof(p_demand->'artists') = 'array' then p_demand->'artists' end), -1) as artists
),
slot as (select (p_day::timestamp + interval '23 minutes') at time zone 'UTC' as starts),
-- The day's 00:23 rebuild: started in its slot, succeeded, and finished
-- before this statement began (pg_cron writes end_time after the job's own
-- transaction committed, so this snapshot includes it).
proof as (
    select d.jobid, d.runid, d.start_time, d.end_time
    from cron.job j join cron.job_run_details d on d.jobid = j.jobid, slot
    where j.jobname = 'indigo-rebuild-edges' and d.status = 'succeeded'
      and d.start_time >= slot.starts and d.start_time < slot.starts + interval '7 minutes'
      and d.end_time is not null and d.end_time < statement_timestamp()
    order by d.start_time limit 1
),
-- The newest finished rebuild this snapshot includes: the edges watermark.
latest as (
    select d.jobid, d.runid, d.start_time, d.end_time
    from cron.job j join cron.job_run_details d on d.jobid = j.jobid
    where j.jobname = 'indigo-rebuild-edges' and d.status = 'succeeded'
      and d.end_time is not null and d.end_time < statement_timestamp()
    order by d.end_time desc limit 1
),
refusal as (
    select case
        when p_day is distinct from (statement_timestamp() at time zone 'UTC')::date then 'not-today'
        when (select digest from demand) <> (select digest from frozen) then 'not-the-frozen-demand-set'
        when (select nodes from demand) not between 0 and 48 or (select artists from demand) not between 0 and 400 then 'out-of-bounds'
        when not exists (select 1 from proof) then 'no-completed-rebuild-today'
    end as reason
),
nodes as (
    select n - 'why' as node, (row_number() over (order by n->>'id') - 1) / 12 as batch
    from jsonb_array_elements(case when (select reason from refusal) is null then p_demand->'nodes' else '[]'::jsonb end) n
),
artists as (
    select a->>'key' as key, (row_number() over (order by a->>'key') - 1) / 50 as batch
    from jsonb_array_elements(case when (select reason from refusal) is null then p_demand->'artists' else '[]'::jsonb end) a
),
batches as (select batch from nodes union select batch from artists),
answers as (
    select b.batch, public.knowledge_answers(
        coalesce((select jsonb_agg(n.node order by n.node->>'id') from nodes n where n.batch = b.batch), '[]'::jsonb),
        coalesce((select array_agg(a.key order by a.key) from artists a where a.batch = b.batch), '{}'::text[])) as answer
    from batches b
)
select jsonb_build_object(
    'format', 'indigo.knowledge-cut/1',
    'status', case when (select reason from refusal) is null then 'ok' else 'refused' end,
    'reason', (select reason from refusal),
    'day', p_day,
    'statementAt', statement_timestamp(),
    'snapshot', pg_current_snapshot()::text,
    'demandDigest', (select digest from demand),
    'rebuild', jsonb_build_object(
        'proof', (select to_jsonb(p) from proof p),
        'latest', (select to_jsonb(l) from latest l)),
    'nodes', coalesce((select jsonb_object_agg(k, v) from answers, jsonb_each(answer->'nodes') as e(k, v)), '{}'::jsonb),
    'artists', coalesce((select jsonb_object_agg(k, v) from answers, jsonb_each(answer->'artists') as e(k, v)), '{}'::jsonb),
    'batches', (select count(*) from answers)
)
$function$;

-- Closed to the app's key by name (0023), open to the publishing worker only.
revoke all on function public.knowledge_answers(jsonb, text[]) from public, anon, authenticated;
revoke all on function public.knowledge_cut(date, jsonb) from public, anon, authenticated;
grant execute on function public.knowledge_answers(jsonb, text[]) to service_role;
grant execute on function public.knowledge_cut(date, jsonb) to service_role;
