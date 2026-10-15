select json_build_object(
 'database_bytes', pg_database_size(current_database()),
 'by_schema', (select json_agg(json_build_object('schema', nspname, 'mb', mb) order by mb desc) from (
               select nspname, round(sum(pg_total_relation_size(c.oid))/1048576.0, 1) as mb
               from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r','m') group by nspname) z),
 'top_relations', (select json_agg(z) from (select n.nspname||'.'||c.relname as rel, round(pg_relation_size(c.oid)/1048576.0,1) as heap_mb,
               round((pg_total_relation_size(c.oid)-pg_relation_size(c.oid)-pg_indexes_size(c.oid))/1048576.0,1) as toast_mb,
               round(pg_indexes_size(c.oid)/1048576.0,1) as idx_mb, s.n_live_tup as live, s.n_dead_tup as dead,
               s.last_autovacuum, s.last_vacuum
               from pg_class c join pg_namespace n on n.oid=c.relnamespace left join pg_stat_all_tables s on s.relid=c.oid
               where c.relkind='r' order by pg_total_relation_size(c.oid) desc limit 25) z)
) as r;
