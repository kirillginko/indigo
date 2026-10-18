-- Two questions the sizes cannot answer. Run by run.sh after queries.sql.
--
-- 1. Can old and new live side by side? Half the providers stay per line (A),
--    half move to one row per episode (D1), and every reader answers over
--    both. The answer must equal the all-A answer exactly; that is what lets
--    a provider move at a time without NTS, Lot or YouTube noticing.
--
-- 2. What do writes cost? A corrected tracklist and a late artist resolution,
--    done to both shapes, measured as growth before vacuum.

\set ON_ERROR_STOP on

-- 1. Side by side ------------------------------------------------------------------

create table mixed_lines as
select ra.* from radio_appearances_broadcast ra
join radio_episodes re on re.id = ra.radio_episode_id
where re.provider = 'nts';
create index on mixed_lines (artist_id);
create unique index on mixed_lines (radio_episode_id, track_index);

create table mixed_tracklists as
select t.* from radio_tracklists t
join radio_episodes re on re.id = t.radio_episode_id
where re.provider = 'lotradio';
alter table mixed_tracklists add primary key (radio_episode_id);
create index on mixed_tracklists using gin (artist_ids);
analyze mixed_lines;
analyze mixed_tracklists;

-- The artist page over both: each half answers its own rows, ordered and
-- limited once over the union, as the RPC would.
create function m_artist_appearances(p uuid, lim int default 50)
returns table (episode_id uuid, episode_title text, aired_at timestamptz, show_title text,
               track_index int, raw_artist_name text, raw_track_title text, offset_seconds int, recording_id uuid)
language sql stable as $$
select * from (
    select re.id as episode_id, re.title as episode_title, re.aired_at, rs.title as show_title,
           ra.track_index, ra.raw_artist_name, ra.raw_track_title, ra.offset_seconds, ra.recording_id
    from mixed_lines ra
    join radio_episodes re on re.id = ra.radio_episode_id
    left join radio_shows rs on rs.id = re.radio_show_id
    where ra.artist_id = p
    union all
    select re.id, re.title, re.aired_at, rs.title,
           (u.i - 1)::int, coalesce(t.raw_artists[u.i], a.name), t.titles[u.i], t.offsets[u.i], t.recording_ids[u.i]
    from mixed_tracklists t
    cross join lateral unnest(t.artist_ids) with ordinality as u(artist_id, i)
    join radio_episodes re on re.id = t.radio_episode_id
    left join radio_shows rs on rs.id = re.radio_show_id
    left join artists a on a.id = u.artist_id
    where t.artist_ids @> array[p] and u.artist_id = p
) both_halves
order by aired_at desc nulls last, track_index, episode_id
limit lim;
$$;

create function m_played_by()
returns table (artist_id uuid, radio_show_id uuid, appearances bigint, episodes bigint)
language sql stable as $$
select artist_id, radio_show_id, count(*), count(distinct episode_id)
from (
    select ra.artist_id, re.radio_show_id, re.id as episode_id
    from mixed_lines ra join radio_episodes re on re.id = ra.radio_episode_id
    union all
    select u.artist_id, re.radio_show_id, re.id
    from mixed_tracklists t
    cross join lateral unnest(t.artist_ids) as u(artist_id)
    join radio_episodes re on re.id = t.radio_episode_id
) lines
where artist_id is not null and radio_show_id is not null
group by 1, 2;
$$;

\echo
\echo == side by side: half the providers per line, half per episode, against all per line
select 'lines held per line / per episode' as check,
       (select count(*) from mixed_lines)::text || ' / ' ||
       (select sum(cardinality(artist_ids)) from mixed_tracklists)::text as result
union all
select 'artist page mismatches (325 artists, 500 rows each)',
       count(*) filter (where a is distinct from m)::text
from (select (select md5(string_agg(x::text, '|')) from a_artist_appearances(s.artist_id, 500) x) a,
             (select md5(string_agg(x::text, '|')) from m_artist_appearances(s.artist_id, 500) x) m
      from sample_artists s) c
union all
select 'played_by mismatches (whole table)',
       ((select count(*) from ((select * from a_played_by()) except all (select * from m_played_by())) x)
      + (select count(*) from ((select * from m_played_by()) except all (select * from a_played_by())) x))::text
union all
select 'artist page ms, mixed (mean)', time_per_artist('m_artist_appearances')::text;

-- 2. Writes ----------------------------------------------------------------------
--
-- 800 episodes get one title corrected; then 2,000 unresolved lines get an
-- artist. Each shape is measured before and after, without vacuum, so the
-- growth is the dead versions and new index entries a write leaves behind.

create unlogged table write_sample as
select radio_episode_id from radio_tracklists order by md5(radio_episode_id::text) limit 800;

create unlogged table resolve_sample as
select radio_episode_id, track_index, (select id from artists order by md5(id::text) limit 1) as artist_id
from radio_appearances_broadcast where artist_id is null
order by md5(id::text) limit 2000;

create function plan_bytes(relation text) returns bigint
language sql as $$ select pg_total_relation_size(relation::regclass) $$;

create unlogged table write_cost (shape text, operation text, rows_written bigint, growth bigint);

do $$
declare before bigint; touched bigint;
begin
    before := plan_bytes('radio_appearances_broadcast');
    update radio_appearances_broadcast ra set raw_track_title = raw_track_title || ' (edit)'
    from write_sample w where ra.radio_episode_id = w.radio_episode_id and ra.track_index = 0;
    get diagnostics touched = row_count;
    insert into write_cost values ('A per line', 'correct one title in 800 episodes', touched, plan_bytes('radio_appearances_broadcast') - before);

    before := plan_bytes('radio_tracklists');
    update radio_tracklists t set titles[1] = titles[1] || ' (edit)'
    from write_sample w where t.radio_episode_id = w.radio_episode_id;
    get diagnostics touched = row_count;
    insert into write_cost values ('D1 per episode', 'correct one title in 800 episodes', touched, plan_bytes('radio_tracklists') - before);

    before := plan_bytes('radio_appearances_broadcast');
    update radio_appearances_broadcast ra set artist_id = r.artist_id
    from resolve_sample r where ra.radio_episode_id = r.radio_episode_id and ra.track_index = r.track_index;
    get diagnostics touched = row_count;
    insert into write_cost values ('A per line', 'resolve 2,000 pending lines', touched, plan_bytes('radio_appearances_broadcast') - before);

    before := plan_bytes('radio_tracklists');
    -- One write per episode, whatever number of its lines resolve.
    update radio_tracklists t
    set artist_ids = (select array_agg(coalesce(r.artist_id, u.a) order by u.i)
                      from unnest(t.artist_ids) with ordinality u(a, i)
                      left join resolve_sample r on r.radio_episode_id = t.radio_episode_id and r.track_index = u.i - 1)
    where t.radio_episode_id in (select radio_episode_id from resolve_sample);
    get diagnostics touched = row_count;
    insert into write_cost values ('D1 per episode', 'resolve 2,000 pending lines', touched, plan_bytes('radio_tracklists') - before);
end $$;

\echo
\echo == writes: growth before vacuum (dead row versions and new index entries)
select shape, operation, rows_written, growth, round(growth::numeric / greatest(rows_written, 1)) as bytes_per_row_written
from write_cost order by operation, shape;

-- 3. The app reads the table by name ------------------------------------------------
--
-- Dig (TrackDiscoverySource.swift) and Explore (ListenerRetrieval.swift) query
-- `radio_appearances` directly through PostgREST, filtering on artist_id. A view
-- of that name over both halves keeps them working, but the per-episode half
-- cannot use its GIN index through a plain `artist_id in (...)` filter.

create view mixed_view as
select ra.radio_episode_id, ra.track_index, ra.artist_id, ra.raw_track_title, ra.offset_seconds, ra.media_url
from mixed_lines ra
union all
select t.radio_episode_id, (u.i - 1)::int, u.artist_id, t.titles[u.i], t.offsets[u.i], null::text
from mixed_tracklists t
cross join lateral unnest(t.artist_ids) with ordinality as u(artist_id, i);

create function time_view(ids uuid[]) returns numeric
language plpgsql as $$
declare started timestamptz; ignored bigint;
begin
    select count(*) into ignored from mixed_view where artist_id = any (ids);
    started := clock_timestamp();
    select count(*) into ignored from mixed_view where artist_id = any (ids);
    return round(extract(epoch from clock_timestamp() - started) * 1000, 1);
end $$;

\echo
\echo == a compatibility view named like the table, filtered the way the app filters it
select 'view: artist_id in (20 artists), ms' as check,
       time_view(array(select artist_id from sample_artists order by artist_id limit 20))::text as result
union all
select 'per-line half alone, ms',
       time_once('select 1 from mixed_lines where artist_id = any (array(select artist_id from sample_artists order by artist_id limit 20))')::text;
