-- What the nightly sweep removes, and what it must not.
--
-- The danger in a prune is not that it fails to delete; it is that it deletes
-- something still wanted. So every check below is paired: one row that should
-- go and one that should stay, differing only in the thing the sweep is
-- supposed to look at.

begin;

-- ---------------------------------------------------------------------------
-- Finished work goes; live work stays whatever its age
-- ---------------------------------------------------------------------------

insert into public.enrichment_jobs
    (provider, job_type, dedupe_key, status, payload, created_at, updated_at)
values
    -- Spent and old: the case this exists for.
    ('discogs', 'fetch_release', 'old-done',    'done',    '{"x":1}'::jsonb,
     now() - interval '90 days', now() - interval '90 days'),
    ('discogs', 'fetch_release', 'old-failed',  'failed',  '{"x":1}'::jsonb,
     now() - interval '90 days', now() - interval '90 days'),
    -- Spent but recent: still worth reading after a bad night.
    ('discogs', 'fetch_release', 'fresh-done',  'done',    '{"x":1}'::jsonb,
     now(), now()),
    -- Old and still queued. A job stuck in `running` for three months is a bug
    -- to look at, not rubbish to sweep -- and sweeping it would hide it.
    ('discogs', 'fetch_release', 'old-pending', 'pending', '{"x":1}'::jsonb,
     now() - interval '90 days', now() - interval '90 days'),
    ('discogs', 'fetch_release', 'old-running', 'running', '{"x":1}'::jsonb,
     now() - interval '90 days', now() - interval '90 days');

-- ---------------------------------------------------------------------------
-- Expired cache goes; unexpired and never-expiring stay
-- ---------------------------------------------------------------------------

insert into public.metadata_cache
    (provider, resource_type, resource_id, payload, fetched_at, expires_at)
values
    ('discogs', 'release', 'long-expired', '{"x":1}'::jsonb,
     now() - interval '90 days', now() - interval '30 days'),
    -- Just past expiry, inside the grace window: something may be mid-read.
    ('discogs', 'release', 'just-expired', '{"x":1}'::jsonb,
     now() - interval '2 days', now() - interval '1 hour'),
    ('discogs', 'release', 'still-fresh',  '{"x":1}'::jsonb,
     now(), now() + interval '30 days'),
    -- No expiry at all means keep: the reader has no basis to re-fetch it.
    ('discogs', 'release', 'never-expires', '{"x":1}'::jsonb,
     now() - interval '365 days', null);

-- Long expired, but its payload lives in Storage (0036). Deleting the row would
-- strand the object, so it stays.
insert into public.metadata_cache
    (provider, resource_type, resource_id, payload, payload_path, fetched_at, expires_at)
values
    ('discogs', 'release', 'in-storage', null, 'releases/in-storage.json',
     now() - interval '90 days', now() - interval '30 days');

-- Cron history: a week old goes, yesterday's stays (0038).
insert into cron.job_run_details (jobid, status, start_time, return_message)
values
    (1, 'succeeded', now() - interval '30 days', 'old-run'),
    (1, 'succeeded', now() - interval '1 day',   'recent-run');

select public.prune_spent_rows();

do $$
declare
    n int;
begin
    -- Jobs
    select count(*) into n from public.enrichment_jobs
    where dedupe_key in ('old-done', 'old-failed');
    if n <> 0 then raise exception 'spent jobs survived the sweep (% left)', n; end if;

    select count(*) into n from public.enrichment_jobs
    where dedupe_key in ('fresh-done', 'old-pending', 'old-running');
    if n <> 3 then
        raise exception 'the sweep took work it should have left (% of 3 remain)', n;
    end if;

    -- Cache
    select count(*) into n from public.metadata_cache where resource_id = 'long-expired';
    if n <> 0 then raise exception 'an expired payload survived the sweep'; end if;

    select count(*) into n from public.metadata_cache
    where resource_id in ('just-expired', 'still-fresh', 'never-expires', 'in-storage');
    if n <> 4 then
        raise exception 'the sweep took cache it should have left (% of 4 remain)', n;
    end if;

    -- Cron history
    if exists (select 1 from cron.job_run_details where return_message = 'old-run') then
        raise exception 'a cron run from a month ago survived the sweep';
    end if;
    if not exists (select 1 from cron.job_run_details where return_message = 'recent-run') then
        raise exception 'the sweep took yesterday''s cron run';
    end if;

    raise notice 'prune smoke: all checks passed';
end $$;

rollback;
