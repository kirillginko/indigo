-- P2 runbook (DATABASE-CAPACITY-PLAN.md §9–11): single-broadcast played_by
-- deleted, music_relationships compacted. NOT EXECUTED. Each numbered block
-- is one `supabase db query --linked` call, run by hand, in order, only after
-- explicit approval. Rehearsed: Scripts/p2-rehearsal.sh, p2/rehearsal-*.txt.
--
-- Window: not within 10 minutes of :23 past 00/03/06/09/12/15/18/21 UTC
-- (indigo-rebuild-edges, job 6) or of 04:23 UTC (indigo-merge-split-artists,
-- job 34). Expected duration ~5 minutes, of which the exclusive lock is the
-- compaction (block 4): a few seconds.


-- ── 0. Backup (local, read-only; outside git) ─────────────────────────────
--   python3 -I Scripts/b2-export.py backups/p2-live/export
--   Then: bash Scripts/p2-rehearsal.sh backups/p2-live/export
--   (restore must report "all 16 slices match live"; the rehearsal must
--   pass every integrity line and the rollback line). Otherwise stop.


-- ── 1. Preflight (read-only). Abort unless every `ok_*` is true. ──────────
select json_build_object(
  'postgres_mib', round(pg_database_size('postgres') / 1048576.0, 1),
  'all_db_mb', round((select sum(pg_database_size(datname)) from pg_database) / 1e6, 1),
  'eligible', (select count(*) from public.music_relationships
               where relationship_type = 'played_by' and coalesce(episode_count, 0) < 2),
  'retained', (select count(*) from public.music_relationships
               where not (relationship_type = 'played_by' and coalesce(episode_count, 0) < 2)),
  'ok_headroom', (select sum(pg_database_size(datname)) from pg_database) < 470e6,
  'ok_rebuild_idle', not exists (select 1 from cron.job_run_details
                                 where jobid in (6, 34) and status in ('running', 'starting')),
  'ok_readers_on_0087', (select bool_and(pg_get_functiondef(p.oid) like '%episode_count >= 2%')
                         from pg_proc p where p.pronamespace = 'public'::regnamespace
                         and p.proname in ('artist_radio_relations', 'explore_knowledge', 'knowledge_answers')),
  'ok_writer_on_0087', (select pg_get_functiondef('public.rebuild_radio_dig_edges'::regproc)
                        like '%having count(distinct re.id) >= 2%'),
  'ok_no_long_xacts', not exists (select 1 from pg_stat_activity
                                  where xact_start < now() - interval '2 minutes' and state <> 'idle'
                                    and pid <> pg_backend_pid())
) as preflight;


-- ── 2. Pause the two writers (reversible) ─────────────────────────────────
select cron.alter_job(6, active := false), cron.alter_job(34, active := false);
select jobid, active from cron.job where jobid in (6, 34);   -- both false


-- ── 3. Delete, in ONE transaction that checks itself ──────────────────────
-- A DO block is one statement: any exception rolls the whole delete back
-- (the in-transaction rollback). The kept rows are fingerprinted before and
-- after inside the same transaction and must be identical.
do $$
declare
    expected bigint;
    deleted bigint;
    kept_before text;
    kept_after text;
begin
    set local lock_timeout = '5s';
    set local statement_timeout = '120s';
    select count(*) into expected from public.music_relationships
    where relationship_type = 'played_by' and coalesce(episode_count, 0) < 2;
    if expected not between 150000 and 161819 then
        raise exception 'P2: % eligible rows, outside the rehearsed range', expected;
    end if;
    select md5(string_agg(concat_ws('|', id, from_entity_id, to_entity_id, relationship_type, evidence_count,
               episode_count, confidence, updated_at, source), E'\n' order by id))
      into kept_before
    from public.music_relationships
    where not (relationship_type = 'played_by' and coalesce(episode_count, 0) < 2);

    delete from public.music_relationships
    where relationship_type = 'played_by' and coalesce(episode_count, 0) < 2;
    get diagnostics deleted = row_count;

    select md5(string_agg(concat_ws('|', id, from_entity_id, to_entity_id, relationship_type, evidence_count,
               episode_count, confidence, updated_at, source), E'\n' order by id))
      into kept_after
    from public.music_relationships;
    if deleted <> expected or kept_after is distinct from kept_before then
        raise exception 'P2: deleted % of %, kept rows %', deleted, expected,
            case when kept_after = kept_before then 'unchanged' else 'CHANGED' end;
    end if;
    raise notice 'P2: deleted %, kept % (fingerprint %)', deleted,
        (select count(*) from public.music_relationships), kept_after;
end $$;
-- After this commits, undoing it is a restore (block 7), not a rollback.


-- ── 4. Compact — its OWN call, after block 3 has committed ────────────────
-- 4a. Nothing may still see the deleted rows, or the copy keeps them.
-- Its own call; every count must be 0.
select (select count(*) from pg_stat_activity
        where backend_xmin is not null and pid <> pg_backend_pid()
          and xact_start < now() - interval '1 second') as old_snapshots,
       (select count(*) from pg_replication_slots where xmin is not null) as slots_holding_xmin,
       (select count(*) from pg_prepared_xacts) as prepared;
-- 4b. CLUSTER rewrites the heap and every index like VACUUM FULL, but unlike
-- VACUUM it may run in a transaction, so it can carry a lock timeout: it
-- waits at most 5 s for its lock instead of queueing every reader behind it.
-- (The CLI sends one call as one implicit transaction; VACUUM FULL there
-- fails with 25001, and with no lock_timeout it could not be bounded.)
-- Never in the same call as block 3: in its own transaction CLUSTER copies
-- the rows that transaction deleted, and frees nothing (rehearsed).
set local lock_timeout = '5s';
set local statement_timeout = '120s';
cluster public.music_relationships using music_relationships_pkey;
alter table public.music_relationships set without cluster;
analyze public.music_relationships;
-- On a lock timeout: nothing changed (rehearsed); run 4 again. Until it
-- succeeds the space stays allocated; reads are correct either way.


-- ── 5. Verify (read-only) ─────────────────────────────────────────────────
select json_build_object(
  'postgres_mib', round(pg_database_size('postgres') / 1048576.0, 1),         -- expect ~376
  'all_db_mb', round((select sum(pg_database_size(datname)) from pg_database) / 1e6, 1),  -- expect ~410
  'table_mib', round(pg_total_relation_size('public.music_relationships') / 1048576.0, 2),  -- expect ~8.7
  'rows', (select count(*) from public.music_relationships),                  -- expect = retained
  'single_broadcast_left', (select count(*) from public.music_relationships
                            where relationship_type = 'played_by' and coalesce(episode_count, 0) < 2),  -- 0
  'pkey', exists (select 1 from pg_constraint where conname = 'music_relationships_pkey' and contype = 'p'),
  'edge_idx_unique', (select indisunique from pg_index where indexrelid = 'public.music_relationships_edge_idx'::regclass),
  'to_idx', to_regclass('public.music_relationships_to_idx') is not null,
  'trigger', exists (select 1 from pg_trigger where tgname = 'music_relationships_touch_updated_at'),
  'rls', (select relrowsecurity from pg_class where oid = 'public.music_relationships'::regclass)
) as verify;
-- Then the reader capture, compared with the one taken in block 1's minute:
--   python3 Scripts/p1-capture.py sql <sample> supabase/functions/_shared/testdata/pilot_demand_v1.json > cap.sql
--   supabase db query --linked -f cap.sql > after.json
--   python3 Scripts/p1-capture.py compare before.json after.json   -- every reader: changed 0


-- ── 6. Resume the writers; watch the next rebuild ─────────────────────────
select cron.alter_job(6, active := true), cron.alter_job(34, active := true);
-- After the next :23 run: status succeeded, and
select count(*) as single_broadcast_created
from public.music_relationships
where relationship_type = 'played_by' and coalesce(episode_count, 0) < 2;   -- 0


-- ── 7. Restore after commit (only if something above failed) ─────────────
-- (a) Exact: re-insert the deleted rows, every column and id, from the block-0
--     export, `on conflict do nothing` (rehearsed: 2.6 s locally, all 16
--     slices equal live after). Needs ~45 MiB of room, which P2 created, and
--     a way to send ~40 MB of rows: the CLI takes SQL text, so in slices
--     (16 statements of `insert … select from json_populate_recordset(…)`),
--     or over a direct psql connection with \copy.
-- (b) Derived: run supabase/diagnostics/capacity/p1/rollback-0087.sql, then
--     the rebuild once: it re-materialises every current single-broadcast
--     pair from the appearances (new ids and timestamps; not the 266 stale
--     pairs, which are in the export).
-- Neither is needed for correctness: no reader reads these rows (0087).
