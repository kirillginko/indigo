-- The release cache, kept in Storage.
--
-- Measured 2026-09-16, after 0035: 394 MB of the free plan's 500 MB database,
-- with `metadata_cache` the largest table at 144 MB and growing while the
-- worker drains. Almost all of it is Discogs release payloads -- thirty
-- thousand whole documents, looked up by id and never queried inside.
--
-- The free plan's file storage is a separate 1 GB, and it was empty (0002's
-- `artwork` bucket was provisioned for re-hosting that was never built). A
-- document looked up by id is exactly what object storage is for, so the
-- payloads move there and the database keeps a row per release that says it is
-- cached and when -- which is all the freshness checks in 0027 ever read.
--
-- Nothing is trimmed. The user was offered a projection that would have saved
-- about 60 MB by dropping fields nothing reads yet, and declined it: per-track
-- credits, master ids and release dates would cost hours of Discogs budget to
-- fetch back. Every payload moves whole.
--
-- Only Discogs releases move. Searches, shelves and NTS payloads are a few MB
-- between them and stay inline, and every reader handles both shapes.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------------

-- Public for the same reason `metadata_cache` is readable by the app's key
-- (0001): this is Discogs' public catalogue data, and a public object is served
-- from the CDN with no signing round trip. Nothing private belongs here.
insert into storage.buckets (id, name, public)
values ('catalog-cache', 'catalog-cache', true)
on conflict (id) do update set public = true;

-- Read for everyone, writes for no one. The worker and `catalog-refresh`
-- upload as `service_role`, which bypasses RLS.
drop policy if exists catalog_cache_objects_read on storage.objects;
create policy catalog_cache_objects_read on storage.objects
    for select to anon, authenticated
    using (bucket_id = 'catalog-cache');

-- ---------------------------------------------------------------------------
-- The row that stays
-- ---------------------------------------------------------------------------

-- `payload_path` is the object's key inside `catalog-cache`, and a row has one
-- or the other. Always `releases/{id}.json`, never anything derived from the
-- payload, so a refetch overwrites the same object and Storage cannot fill up
-- with copies of one release.
alter table public.metadata_cache alter column payload drop not null;
alter table public.metadata_cache add column if not exists payload_path text;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'metadata_cache_payload_somewhere') then
        alter table public.metadata_cache add constraint metadata_cache_payload_somewhere
            check (payload is not null or payload_path is not null);
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Moving what is already stored
-- ---------------------------------------------------------------------------

-- A batch of payloads still held inline, for the worker to upload.
--
-- Deliberately no `for update skip locked`: the move is idempotent -- the same
-- document to the same key, then a mark that only touches rows still holding a
-- payload -- so two runs that pick the same rows waste a little work and harm
-- nothing, and a claim would need a transaction the worker cannot hold across
-- its uploads.
create or replace function public.release_payloads_to_offload(p_limit int default 250)
returns table(resource_id text, payload jsonb)
language sql
stable
set search_path = public
as $$
    select mc.resource_id, mc.payload
    from public.metadata_cache mc
    where mc.provider = 'discogs'
      and mc.resource_type = 'release'
      and mc.payload is not null
    order by mc.resource_id
    limit greatest(1, least(coalesce(p_limit, 250), 500));
$$;

-- After an upload succeeds: drop the inline copy and record where it went.
--
-- Only rows that still hold a payload. One that a fresh fetch has already moved
-- is left alone, so a slow batch cannot point a new row back at nothing.
create or replace function public.mark_release_payloads_offloaded(p_resource_ids text[])
returns int
language plpgsql
set search_path = public
as $$
declare
    v_marked int;
begin
    update public.metadata_cache mc
    set payload = null,
        payload_path = 'releases/' || mc.resource_id || '.json'
    where mc.provider = 'discogs'
      and mc.resource_type = 'release'
      and mc.resource_id = any(p_resource_ids)
      and mc.payload is not null;
    get diagnostics v_marked = row_count;
    return v_marked;
end $$;

-- How far along the move is. Zero means done, and the database keeps nothing
-- but rows.
create or replace function public.release_payloads_left()
returns bigint
language sql
stable
set search_path = public
as $$
    select count(*) from public.metadata_cache
    where provider = 'discogs' and resource_type = 'release' and payload is not null;
$$;

-- Internal. See 0023: revoking from PUBLIC leaves `anon` and `authenticated`
-- holding their own grants from the project's default privileges.
revoke all on function public.release_payloads_to_offload(int) from public, anon, authenticated;
revoke all on function public.mark_release_payloads_offloaded(text[]) from public, anon, authenticated;
revoke all on function public.release_payloads_left() from public, anon, authenticated;
grant execute on function public.release_payloads_to_offload(int) to service_role;
grant execute on function public.mark_release_payloads_offloaded(text[]) to service_role;
grant execute on function public.release_payloads_left() to service_role;

-- ---------------------------------------------------------------------------
-- The nightly prune, taught about Storage
-- ---------------------------------------------------------------------------

-- 0034 deletes cache rows a day past their expiry. For a release that now
-- lives in Storage that would delete the row and strand its object: SQL cannot
-- remove a Storage object, and deleting from `storage.objects` directly leaves
-- the file behind. Leaving the row costs a few hundred bytes, and the next
-- fetch of that release overwrites the same key, so nothing accumulates.
create or replace function public.prune_spent_rows()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_jobs bigint;
    v_cache bigint;
begin
    delete from public.enrichment_jobs
    where status in ('done', 'failed')
      and coalesce(updated_at, created_at) < now() - public.finished_job_retention();
    get diagnostics v_jobs = row_count;

    delete from public.metadata_cache
    where expires_at is not null
      and expires_at < now() - public.expired_cache_grace()
      and payload_path is null;
    get diagnostics v_cache = row_count;

    return jsonb_build_object(
        'jobs_removed', v_jobs,
        'cache_rows_removed', v_cache,
        'ran_at', now()
    );
end $$;

revoke all on function public.prune_spent_rows() from public, anon, authenticated;
grant execute on function public.prune_spent_rows() to service_role;
