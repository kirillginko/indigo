-- Two more unread indexes, and the cron log emptied, about 16 MB on a database
-- the free plan caps at 500. Both are returned to the operating system at once:
-- DROP INDEX deletes the file, and TRUNCATE gives the table a new one.
--
-- Scan counts are pg_stat_user_indexes from 2026-08-25 to 2026-10-01.
--
--   radio_appearances_recording_idx   2.9 MB   23 scans
--     Every reader that mentions `recording_id` filters it as `is null` or reads
--     it from a row it already has. What it was kept for is the foreign key's
--     ON DELETE SET NULL, and the only delete of a recording anywhere is the
--     one in `record_track_release` that undoes an insert made a moment before,
--     when no appearance can reference it yet.
--
--   radio_appearances_isrc_idx        1.5 MB   13 scans
--     Nothing looks an appearance up by ISRC. `requeue_nts_episodes` only asks
--     whether one is present, next to other conditions.
--
-- Kept, though it has one scan: radio_appearances_pending_release_idx, 0.4 MB.
-- It is the index `enqueue_track_releases` reads, and 11,254 appearances are
-- waiting in the Deezer lane that 0065 paused. One scan is that lane being off,
-- not the index being unread; resuming it would turn into a table scan.
--
-- The cron log
--
--   cron.job_run_details was 11 MB at a seven-day retention (23,621 rows, 0038).
--   Deleting old rows never shrinks the file, so shortening the retention alone
--   would change nothing visible. Nothing reads the log but `enrichment_status`,
--   which looks at the last five runs and fills again within five minutes, so it
--   is emptied now and kept for two days. The day-to-day volume is about 3,400
--   rows, so two days settles near 3 MB.
--
-- Safe to re-run.

drop index if exists public.radio_appearances_recording_idx;
drop index if exists public.radio_appearances_isrc_idx;

create or replace function public.cron_history_retention()
returns interval language sql immutable as $$ select interval '2 days' $$;

do $$
begin
    if to_regclass('cron.job_run_details') is not null then
        execute 'truncate table cron.job_run_details';
    end if;
end $$;
