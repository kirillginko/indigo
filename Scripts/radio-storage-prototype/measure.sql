-- Sizes of every plan, as Postgres reports them. Run by run.sh after build.sql.

\set ON_ERROR_STOP on

\echo
\echo == data
select (select count(*) from staging_lines) as lines,
       (select count(*) from broadcast) as broadcast_lines,
       (select count(*) from radio_episodes) as episodes,
       (select count(*) from radio_episodes where provider <> 'youtube') as broadcast_episodes,
       (select count(*) from artists) as artists,
       (select count(distinct artist_id) from broadcast) as broadcast_artists;

create temporary view plan_relations (plan, relation) as values
    ('A  live, all lines',            'radio_appearances'),
    ('A  live, broadcast lines',      'radio_appearances_broadcast'),
    ('C2 compact row per line',       'radio_lines_c2'),
    ('D1 row per episode',            'radio_tracklists'),
    ('D1z row per episode, lz4',      'radio_tracklists_d1z'),
    ('D2 row per episode, no titles', 'radio_tracklists_d2'),
    ('D3 row per episode, int4 ids',  'radio_tracklists_d3'),
    ('D3 row per episode, int4 ids',  'artist_numbers'),
    ('E  row per artist',             'artist_postings');

\echo
\echo == bytes per line (A all lines: per line of all; every other plan: per broadcast line)
select plan,
       sum(pg_relation_size(relation::regclass)) as heap,
       sum(pg_total_relation_size(relation::regclass) - pg_relation_size(relation::regclass)
           - pg_indexes_size(relation::regclass)) as toast,
       sum(pg_indexes_size(relation::regclass)) as indexes,
       sum(pg_total_relation_size(relation::regclass)) as total,
       round(sum(pg_total_relation_size(relation::regclass))::numeric
             / case when plan like 'A  live, all%' then (select count(*) from staging_lines)
                    else (select count(*) from broadcast) end, 1) as per_line
from plan_relations
group by plan
order by min(relation) = 'radio_appearances' desc, plan;

\echo
\echo == D1 without the ISRC lookup it carries for D1i (the D1 row above includes it)
select pg_total_relation_size('radio_tracklists') - pg_relation_size('radio_tracklists_isrcs_gin') as d1_without_isrc_lookup,
       pg_relation_size('radio_tracklists_isrcs_gin') as isrc_lookup,
       round((pg_total_relation_size('radio_tracklists') - pg_relation_size('radio_tracklists_isrcs_gin'))::numeric
             / (select count(*) from broadcast), 1) as d1_per_line,
       round(pg_relation_size('radio_tracklists_isrcs_gin')::numeric / (select count(*) from broadcast), 1) as isrc_lookup_per_line,
       round(pg_total_relation_size('radio_tracklists_d3')::numeric / (select count(*) from broadcast), 1) as d3_tracklists_only_per_line,
       round(pg_total_relation_size('artist_numbers')::numeric / (select count(*) from broadcast), 1) as d3_dictionary_per_line;

\echo
\echo == every index
select c.relname as index, i.indrelid::regclass as on_table, pg_relation_size(c.oid) as bytes
from pg_index i join pg_class c on c.oid = i.indexrelid
where i.indrelid::regclass::text in (select relation from plan_relations)
order by 2, 3 desc;

\echo
\echo == the shared tables every plan keeps
select relname, pg_total_relation_size(oid) as total
from pg_class where relname in ('radio_episodes', 'radio_shows', 'artists');
