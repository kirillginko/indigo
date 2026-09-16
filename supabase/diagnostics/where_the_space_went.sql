-- Where the space went.
--
-- Paste into the Supabase SQL editor. Reads only; nothing here changes
-- anything.
--
-- The free plan has two quotas and the dashboard reports both as "storage",
-- but only one of them can be the problem here: **the database**, ~500 MB.
--
-- Indigo does not re-host images. It stores the provider's URL —
-- `artwork.original_url`, written by 0019 — and the device fetches from that
-- CDN itself. 0002 provisions an `artwork` bucket and `artwork` carries
-- `thumbnail_path` / `medium_path` / `large_path` for a cache that was planned
-- and never built: nothing in any migration, Edge Function or the app writes
-- those columns, and nothing uploads an object. The bucket is empty.
--
-- Section 3 is kept only to prove that, because it is the kind of claim worth
-- checking rather than believing.

-- ---------------------------------------------------------------------------
-- 1. The database, biggest first
-- ---------------------------------------------------------------------------
select
    relname                                              as table_name,
    pg_size_pretty(pg_total_relation_size(c.oid))        as total,
    pg_size_pretty(pg_relation_size(c.oid))              as rows_only,
    pg_size_pretty(pg_indexes_size(c.oid))               as indexes,
    (select reltuples::bigint from pg_class where oid = c.oid) as approx_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by pg_total_relation_size(c.oid) desc;

-- And the whole database as one number, to compare against the 500 MB.
select pg_size_pretty(pg_database_size(current_database())) as database_total;

-- ---------------------------------------------------------------------------
-- 2. How much of it is cache nobody is reading
-- ---------------------------------------------------------------------------

-- Rows past their own expiry. Nothing deletes these: `expires_at` is written
-- and indexed, and then only ever read.
select
    count(*)                                                   as expired_rows,
    pg_size_pretty(sum(pg_column_size(payload))::bigint)       as payload_bytes,
    min(fetched_at)::date                                      as oldest
from public.metadata_cache
where expires_at is not null and expires_at < now();

-- The same table by provider and resource, so a single fat payload shape shows
-- itself rather than hiding in a total.
select
    provider,
    resource_type,
    count(*)                                             as rows,
    pg_size_pretty(sum(pg_column_size(payload))::bigint) as payload_bytes,
    pg_size_pretty(avg(pg_column_size(payload))::bigint) as avg_row
from public.metadata_cache
group by provider, resource_type
order by sum(pg_column_size(payload)) desc;

-- Queue rows that have already done their work. Nothing deletes these either.
select
    status,
    count(*)            as rows,
    min(created_at)::date as oldest,
    pg_size_pretty(sum(pg_column_size(payload) + pg_column_size(last_error))::bigint)
                        as payload_bytes
from public.enrichment_jobs
group by status
order by count(*) desc;

-- ---------------------------------------------------------------------------
-- 3. The bucket, which should be empty
-- ---------------------------------------------------------------------------

-- Expect no rows. Anything here means something is uploading after all, and
-- the paragraph at the top of this file is wrong.
select
    split_part(name, '/', 1)                                       as kind,
    split_part(name, '/', 3)                                       as variant,
    count(*)                                                       as objects,
    pg_size_pretty(sum((metadata->>'size')::bigint))               as total,
    pg_size_pretty(avg((metadata->>'size')::bigint)::bigint)       as avg_object
from storage.objects
where bucket_id = 'artwork'
group by 1, 2
order by sum((metadata->>'size')::bigint) desc nulls last;

select
    count(*)                                          as artwork_objects,
    pg_size_pretty(sum((metadata->>'size')::bigint))  as artwork_total
from storage.objects
where bucket_id = 'artwork';
