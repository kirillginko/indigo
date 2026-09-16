-- Let the queue report on itself.
--
-- `enrichment_queue_health` from 0030 answers zeros for everybody. It reads
-- `enrichment_jobs`, which has row level security on and no policy at all --
-- the queue is the backend's business and nothing was ever meant to select from
-- it -- so an invoker function sees an empty table and reports a perfectly
-- healthy queue holding nothing. Which is the worst possible answer: not an
-- error, just calm.
--
-- `security definer` is what the rest of the queue's functions use for the same
-- reason. What it exposes is counts and one age. No payloads, no dedupe keys,
-- nothing about any single job, and no way to reach one.
--
-- Safe to re-run.

create or replace function public.enrichment_queue_health()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select jsonb_build_object(
        'pending', count(*) filter (where status = 'pending'),
        'running', count(*) filter (where status = 'running'),
        'failed', count(*) filter (where status = 'failed'),
        'done', count(*) filter (where status = 'done'),
        -- The number that says a worker is dying mid-batch. Should be zero;
        -- it was ninety, the oldest for four days, and nothing said so.
        'claims_expired', count(*) filter (
            where status = 'running'
              and updated_at < now() - public.enrichment_claim_lease()),
        'oldest_pending_hours', round(extract(epoch from
            coalesce(now() - min(created_at) filter (where status = 'pending'),
                     interval '0')) / 3600, 1)
    )
    from public.enrichment_jobs;
$$;

-- On the list in 0027, so 0023's sweep leaves it callable rather than taking
-- the grant back the next time that migration is re-applied.
grant execute on function public.enrichment_queue_health() to anon, authenticated, service_role;
