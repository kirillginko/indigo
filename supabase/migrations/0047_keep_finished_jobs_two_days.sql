-- Keep finished jobs for two days, not seven.
--
-- About 21,000 jobs finish a day, so a week of them was 150,000 rows and
-- 62 MB -- the seventh-largest table, for rows nothing reads. Nothing depends
-- on them: a job's dedupe only ever conflicts with one still `pending` or
-- `running` (enrichment_jobs_dedupe_idx), so a finished job can be forgotten
-- without anything being fetched twice. Two days is enough to see from the
-- table what the worker did yesterday.
--
-- Safe to re-run.

create or replace function public.finished_job_retention()
returns interval language sql immutable as $$ select interval '2 days' $$;

-- Now rather than at 04:17, so the space is reusable today.
select public.prune_spent_rows();
