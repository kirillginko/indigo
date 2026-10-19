-- The live readers, written twice -- once over the per-line table (A, broadcast
-- lines) and once over one-row-per-episode (D1) -- then checked for identical
-- answers and timed. Run by run.sh after build.sql.

\set ON_ERROR_STOP on

-- Artist page: artist_radio_appearances (0004), minus appearance_id, which is
-- a random uuid in A and derived from (episode, slot) in D1. -----------------

create function a_artist_appearances(p uuid, lim int default 50)
returns table (episode_id uuid, episode_title text, aired_at timestamptz, show_title text,
               track_index int, raw_artist_name text, raw_track_title text, offset_seconds int, recording_id uuid)
language sql stable as $$
select re.id, re.title, re.aired_at, rs.title,
       ra.track_index, ra.raw_artist_name, ra.raw_track_title, ra.offset_seconds, ra.recording_id
from radio_appearances_broadcast ra
join radio_episodes re on re.id = ra.radio_episode_id
left join radio_shows rs on rs.id = re.radio_show_id
where ra.artist_id = p
order by re.aired_at desc nulls last, ra.track_index, re.id
limit lim;
$$;

create function d_artist_appearances(p uuid, lim int default 50)
returns table (episode_id uuid, episode_title text, aired_at timestamptz, show_title text,
               track_index int, raw_artist_name text, raw_track_title text, offset_seconds int, recording_id uuid)
language sql stable as $$
select re.id, re.title, re.aired_at, rs.title,
       (u.i - 1)::int,
       coalesce(t.raw_artists[u.i], a.name),
       t.titles[u.i], t.offsets[u.i], t.recording_ids[u.i]
from radio_tracklists t
cross join lateral unnest(t.artist_ids) with ordinality as u(artist_id, i)
join radio_episodes re on re.id = t.radio_episode_id
left join radio_shows rs on rs.id = re.radio_show_id
left join artists a on a.id = u.artist_id
where t.artist_ids @> array[p] and u.artist_id = p
order by re.aired_at desc nulls last, u.i, re.id
limit lim;
$$;

-- What D1 would hand the app as appearance_id: stable across reads and
-- rewrites of the same slot.
create function d_appearance_id(episode uuid, slot int) returns uuid
language sql immutable as $$ select md5(episode::text || ':' || slot)::uuid $$;

-- Artist summary: artist_radio_summary's counts (0004). ---------------------------

create function a_artist_summary(p uuid)
returns table (appearances bigint, episodes bigint, shows bigint, first_at timestamptz, last_at timestamptz)
language sql stable as $$
select count(*), count(distinct re.id), count(distinct re.radio_show_id), min(re.aired_at), max(re.aired_at)
from radio_appearances_broadcast ra join radio_episodes re on re.id = ra.radio_episode_id
where ra.artist_id = p;
$$;

create function d_artist_summary(p uuid)
returns table (appearances bigint, episodes bigint, shows bigint, first_at timestamptz, last_at timestamptz)
language sql stable as $$
select count(*), count(distinct re.id), count(distinct re.radio_show_id), min(re.aired_at), max(re.aired_at)
from radio_tracklists t
cross join lateral unnest(t.artist_ids) as u(artist_id)
join radio_episodes re on re.id = t.radio_episode_id
where t.artist_ids @> array[p] and u.artist_id = p;
$$;

-- Neighbours on demand: artist_radio_relations' single-adjacency branch (0078).

create function a_neighbours(p uuid)
returns table (other uuid, adjacencies int, episodes int)
language sql stable as $$
select b.artist_id, count(*)::int, count(distinct b.radio_episode_id)::int
from radio_appearances_broadcast a
join radio_appearances_broadcast b
  on b.radio_episode_id = a.radio_episode_id
 and b.track_index in (a.track_index - 1, a.track_index + 1)
where a.artist_id = p and b.artist_id is not null and b.artist_id <> p
group by b.artist_id;
$$;

create function d_neighbours(p uuid)
returns table (other uuid, adjacencies int, episodes int)
language sql stable as $$
select n.other, count(*)::int, count(distinct n.radio_episode_id)::int
from radio_tracklists t
cross join lateral unnest(t.artist_ids) with ordinality as u(artist_id, i)
cross join lateral (values (t.artist_ids[u.i - 1]), (t.artist_ids[u.i + 1])) as v(other)
cross join lateral (select v.other, t.radio_episode_id) as n
where t.artist_ids @> array[p] and u.artist_id = p and n.other is not null and n.other <> p
group by n.other;
$$;

-- Explore's tracklists: episode -> ordered (slot, artist), ListenerRetrieval.swift.

create function a_slots(e uuid[])
returns table (radio_episode_id uuid, track_index int, artist_id uuid)
language sql stable as $$
select radio_episode_id, track_index, artist_id from radio_appearances_broadcast
where radio_episode_id = any (e) and artist_id is not null
order by radio_episode_id, track_index;
$$;

create function d_slots(e uuid[])
returns table (radio_episode_id uuid, track_index int, artist_id uuid)
language sql stable as $$
select t.radio_episode_id, (u.i - 1)::int, u.artist_id
from radio_tracklists t
cross join lateral unnest(t.artist_ids) with ordinality as u(artist_id, i)
where t.radio_episode_id = any (e) and u.artist_id is not null
order by 1, 2;
$$;

-- The rebuild's two aggregates (rebuild_radio_dig_edges, 0078). -------------------

create function a_played_by()
returns table (artist_id uuid, radio_show_id uuid, appearances bigint, episodes bigint)
language sql stable as $$
select ra.artist_id, re.radio_show_id, count(*), count(distinct re.id)
from radio_appearances_broadcast ra join radio_episodes re on re.id = ra.radio_episode_id
where ra.artist_id is not null and re.radio_show_id is not null
group by 1, 2;
$$;

create function d_played_by()
returns table (artist_id uuid, radio_show_id uuid, appearances bigint, episodes bigint)
language sql stable as $$
select u.artist_id, re.radio_show_id, count(*), count(distinct re.id)
from radio_tracklists t
cross join lateral unnest(t.artist_ids) as u(artist_id)
join radio_episodes re on re.id = t.radio_episode_id
where u.artist_id is not null and re.radio_show_id is not null
group by 1, 2;
$$;

create function a_neighbour_pairs()
returns table (low uuid, high uuid, adjacencies bigint, episodes bigint)
language sql stable as $$
select least(a.artist_id, b.artist_id), greatest(a.artist_id, b.artist_id), count(*), count(distinct a.radio_episode_id)
from radio_appearances_broadcast a
join radio_appearances_broadcast b on b.radio_episode_id = a.radio_episode_id and b.track_index = a.track_index + 1
where a.artist_id is not null and b.artist_id is not null and a.artist_id <> b.artist_id
group by 1, 2 having count(*) >= 2;
$$;

create function d_neighbour_pairs()
returns table (low uuid, high uuid, adjacencies bigint, episodes bigint)
language sql stable as $$
-- Each episode's artists zipped against themselves shifted by one: the pairs
-- of neighbouring slots, without a sort or a self-join.
select least(x, y), greatest(x, y), count(*), count(distinct radio_episode_id)
from radio_tracklists t
cross join lateral unnest(t.artist_ids[1:cardinality(t.artist_ids) - 1], t.artist_ids[2:]) as p(x, y)
where x is not null and y is not null and x <> y
group by 1, 2 having count(*) >= 2;
$$;

-- Checks -------------------------------------------------------------------------

create unlogged table sample_artists as
(select artist_id from radio_appearances_broadcast where artist_id is not null
 group by artist_id order by count(*) desc, artist_id limit 25)
union
(select artist_id from (select distinct artist_id from radio_appearances_broadcast where artist_id is not null) d
 order by md5(artist_id::text) limit 300);

create unlogged table sample_episodes as
select id from radio_episodes where provider <> 'youtube' order by md5(id::text) limit 300;

\echo
\echo == parity: each reader, A against D1 (mismatching artists or sets; 0 is identical)
select 'artist page' as reader, count(*) filter (where a is distinct from d) as mismatches, count(*) as checked
from (select s.artist_id,
             (select md5(string_agg(x::text, '|')) from a_artist_appearances(s.artist_id, 500) x) a,
             (select md5(string_agg(x::text, '|')) from d_artist_appearances(s.artist_id, 500) x) d
      from sample_artists s) c
union all
select 'artist summary', count(*) filter (where a is distinct from d), count(*)
from (select (select x::text from a_artist_summary(s.artist_id) x) a,
             (select x::text from d_artist_summary(s.artist_id) x) d
      from sample_artists s) c
union all
select 'neighbours on demand', count(*) filter (where a is distinct from d), count(*)
from (select (select md5(string_agg(x::text, '|' order by x::text)) from a_neighbours(s.artist_id) x) a,
             (select md5(string_agg(x::text, '|' order by x::text)) from d_neighbours(s.artist_id) x) d
      from sample_artists s) c
union all
select 'episode slots (300 episodes)',
       (select count(*) from ((select * from a_slots((select array_agg(id) from sample_episodes)))
                              except all (select * from d_slots((select array_agg(id) from sample_episodes)))) x)
     + (select count(*) from ((select * from d_slots((select array_agg(id) from sample_episodes)))
                              except all (select * from a_slots((select array_agg(id) from sample_episodes)))) x),
       (select count(*) from a_slots((select array_agg(id) from sample_episodes)))
union all
select 'played_by (whole table)',
       (select count(*) from ((select * from a_played_by()) except all (select * from d_played_by())) x)
     + (select count(*) from ((select * from d_played_by()) except all (select * from a_played_by())) x),
       (select count(*) from a_played_by())
union all
select 'neighbour pairs >= 2 (whole table)',
       (select count(*) from ((select * from a_neighbour_pairs()) except all (select * from d_neighbour_pairs())) x)
     + (select count(*) from ((select * from d_neighbour_pairs()) except all (select * from a_neighbour_pairs())) x),
       (select count(*) from a_neighbour_pairs());

-- Timing -------------------------------------------------------------------------
--
-- Warm cache, one laptop, this cluster: ratios between plans mean something;
-- absolute milliseconds are not Supabase's.

create function time_per_artist(fn text) returns numeric
language plpgsql as $$
declare
    started timestamptz;
    ids uuid[] := array(select artist_id from sample_artists);
    id uuid;
    ignored bigint;
begin
    foreach id in array ids loop execute format('select count(*) from %s($1)', fn) into ignored using id; end loop;  -- warm
    started := clock_timestamp();
    foreach id in array ids loop execute format('select count(*) from %s($1)', fn) into ignored using id; end loop;
    return round(extract(epoch from clock_timestamp() - started) * 1000 / cardinality(ids), 3);
end $$;

create function time_once(query text) returns numeric
language plpgsql as $$
declare started timestamptz; ignored bigint;
begin
    execute format('select count(*) from (%s) x', query) into ignored;  -- warm
    started := clock_timestamp();
    execute format('select count(*) from (%s) x', query) into ignored;
    return round(extract(epoch from clock_timestamp() - started) * 1000, 1);
end $$;

\echo
\echo == timing: mean ms per call over the sampled artists, and whole-table aggregates once
select 'artist page' as reader, time_per_artist('a_artist_appearances') as a_ms, time_per_artist('d_artist_appearances') as d1_ms
union all select 'artist summary', time_per_artist('a_artist_summary'), time_per_artist('d_artist_summary')
union all select 'neighbours on demand', time_per_artist('a_neighbours'), time_per_artist('d_neighbours')
union all select 'played_by (whole)', time_once('select * from a_played_by()'), time_once('select * from d_played_by()')
union all select 'neighbour pairs (whole)', time_once('select * from a_neighbour_pairs()'), time_once('select * from d_neighbour_pairs()');
