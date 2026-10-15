-- 0077: two indexes nothing reads (DATABASE-CAPACITY-PLAN.md, operation A).
--
-- Checked 2026-10-12 against live statistics kept since 2026-08-25 (48 days):
--
--   radio_episodes_aired_at_idx (aired_at desc)   0 scans, ~370 kB
--   radio_shows_station_idx     (station)          0 scans,  ~56 kB
--
-- Neither backs a constraint and nothing depends on them. The one query that
-- orders episodes by date (RadioRepository.episodes(ofShow:)) filters by show
-- and the planner reads radio_episodes_show_idx then sorts; it asks for
-- `nulls last`, which this descending index (nulls first) could not supply
-- in order anyway. No app query, edge function or SQL function filters
-- shows by station.
--
-- Small tables: a plain drop holds its lock for milliseconds and runs inside
-- the migration's transaction (CONCURRENTLY cannot).

drop index if exists public.radio_episodes_aired_at_idx;
drop index if exists public.radio_shows_station_idx;
