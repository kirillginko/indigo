-- 0079: done jobs go after two days, failed ones after two weeks. Rolled back.
begin;
insert into public.enrichment_jobs (provider, job_type, dedupe_key, status, payload, created_at, updated_at, last_error) values
    ('discogs', 'fetch_release', 'retention-done-5d',    'done',   '{}'::jsonb, now() - interval '5 days',  now() - interval '5 days',  null),
    ('discogs', 'fetch_release', 'retention-failed-5d',  'failed', '{}'::jsonb, now() - interval '5 days',  now() - interval '5 days',  'boom'),
    ('discogs', 'fetch_release', 'retention-failed-20d', 'failed', '{}'::jsonb, now() - interval '20 days', now() - interval '20 days', 'old boom'),
    ('discogs', 'fetch_release', 'retention-done-1d',    'done',   '{}'::jsonb, now() - interval '1 day',   now() - interval '1 day',   null);
select public.prune_spent_rows();
do $$
begin
    if exists (select 1 from public.enrichment_jobs where dedupe_key = 'retention-done-5d') then
        raise exception 'a five-day-old finished job survived';
    end if;
    if not exists (select 1 from public.enrichment_jobs where dedupe_key = 'retention-failed-5d' and last_error = 'boom') then
        raise exception 'a five-day-old failed job, and its error, were swept';
    end if;
    if exists (select 1 from public.enrichment_jobs where dedupe_key = 'retention-failed-20d') then
        raise exception 'a twenty-day-old failed job survived';
    end if;
    if not exists (select 1 from public.enrichment_jobs where dedupe_key = 'retention-done-1d') then
        raise exception 'yesterday''s finished job was swept';
    end if;
end $$;
rollback;
select 'job retention: done after two days, failed (with errors) after two weeks' as ok;
