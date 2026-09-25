-- A release carries its own Discogs id, and its own "cached at".
--
-- The database was back at 500 MB two days after being cut to 470, and the
-- growth is the release crawl: ~16,000 Discogs releases a day, each costing
-- a `releases` row, an `external_ids` row saying which Discogs id it is, and
-- a `metadata_cache` row saying its document is in R2 -- about 800 bytes, of
-- which the last two are bookkeeping for the first:
--
--   * `external_ids` (294 bytes a row with its three indexes) is a
--     polymorphic table built for entities several providers name. A Discogs
--     release is named by exactly one: 152,046 rows, one per release, no
--     release with two, none pointing at nothing. It becomes a column.
--   * `metadata_cache` (240 bytes) held `r2:releases/<id>.json` -- a path
--     made from the id alone -- plus when it was fetched. The path needs no
--     row, and the time becomes a column beside the id.
--
-- Two new columns on a row that already exists: ~20 bytes, against ~530.
--
-- This migration adds the columns, fills them and moves every reader over.
-- It deletes nothing: the old rows go in 0057, once the functions and the
-- app that stop reading them are deployed.
--
-- Safe to re-run.

alter table public.releases
    add column if not exists discogs_id text,
    add column if not exists discogs_cached_at timestamptz;

-- The backfill, a batch at a time: id and stamp together, so each row is
-- written once. Not run here. Every row it touches leaves a dead copy behind
-- until VACUUM, and all 152,000 in one transaction was ~80 MB of them -- a
-- first attempt timed out and left the database over its limit. Run by hand
-- with a plain VACUUM of `releases` between batches, so each reuses the space
-- the last one freed; 0057 runs it once more for stragglers.
--
-- Returns how many rows it filled; zero means done.
create or replace function public.adopt_release_discogs_ids(p_limit int default 20000)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_filled int;
begin
    update public.releases r
    set discogs_id = s.external_id,
        discogs_cached_at = coalesce(s.fetched_at, r.discogs_cached_at)
    from (
        select x.entity_id, x.external_id, mc.fetched_at
        from public.external_ids x
        join public.releases pending on pending.id = x.entity_id
        left join public.metadata_cache mc
            on mc.provider = 'discogs' and mc.resource_type = 'release'
           and mc.resource_id = x.external_id and mc.payload_path like 'r2:%'
        where x.provider = 'discogs' and x.entity_type = 'release'
          and pending.discogs_id is null
        limit greatest(1, coalesce(p_limit, 20000))
    ) as s
    where r.id = s.entity_id;
    get diagnostics v_filled = row_count;
    return v_filled;
end $$;

revoke all on function public.adopt_release_discogs_ids(int) from public, anon, authenticated;
grant execute on function public.adopt_release_discogs_ids(int) to service_role;

-- The identity, as `external_ids`' unique key was: two workers caching one
-- release race on this rather than filing it twice.
create unique index if not exists releases_discogs_id_key
    on public.releases (discogs_id) where discogs_id is not null;

-- ---------------------------------------------------------------------------
-- Readers
-- ---------------------------------------------------------------------------

-- As 0027, asking `releases` whether the document is held and fresh.
create or replace function public.request_release_cache(p_discogs_ids text[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id text;
    v_queued int := 0;
    v_cached int := 0;
    v_seen text[] := '{}';
begin
    if p_discogs_ids is null then
        return jsonb_build_object('queued', 0, 'cached', 0);
    end if;

    foreach v_id in array p_discogs_ids loop
        v_id := btrim(coalesce(v_id, ''));
        continue when v_id !~ '^[0-9]{1,12}$';
        -- One id named twice in a call is one id.
        continue when v_id = any(v_seen);
        v_seen := array_append(v_seen, v_id);
        exit when cardinality(v_seen) > 50;

        if exists (
            select 1 from public.releases r
            where r.discogs_id = v_id
              and r.discogs_cached_at > now() - public.release_cache_lifetime()
        ) then
            v_cached := v_cached + 1;
            continue;
        end if;

        perform public.enqueue_enrichment_job(
            'discogs',
            'cache_discogs_release',
            v_id,
            jsonb_build_object('release_id', v_id),
            -- Above the shelf crawl below and above portraits. Somebody is
            -- looking at this page now; the crawl is for pages nobody has
            -- opened yet.
            1,
            null,
            null
        );
        v_queued := v_queued + 1;
    end loop;

    return jsonb_build_object('queued', v_queued, 'cached', v_cached);
end $$;

create or replace function public.release_cache_coverage()
returns jsonb
language sql
stable
as $$
    select jsonb_build_object(
        'cached', count(*) filter (
            where r.discogs_cached_at > now() - public.release_cache_lifetime()),
        'stale', count(*) filter (
            where r.discogs_cached_at <= now() - public.release_cache_lifetime()),
        'shelves_walked', (select count(*) from public.artists where shelf_cached_at is not null),
        'shelves_outstanding', (
            select count(*)
            from public.artists a
            join public.external_ids x
                on x.entity_type = 'artist' and x.entity_id = a.id and x.provider = 'discogs'
            where a.shelf_cached_at is null)
    )
    from public.releases r
    where r.discogs_cached_at is not null;
$$;

-- As 0018, with a release's Discogs id read off the release itself.
create or replace function public.search_catalog(p_query text, p_key text, p_limit integer default 8)
returns jsonb
language sql
stable
as $$
with bounded as (
    select
        greatest(1, least(coalesce(p_limit, 8), 25)) as n,
        coalesce(nullif(btrim(p_query), ''), '') as q,
        coalesce(nullif(btrim(p_key), ''), '') as k
),
-- Discogs ids for whatever the three searches below turn up, so a result can
-- open the page Indigo already has for it rather than a page built from a
-- name. Read once per entity type instead of per row.
artist_hits as (
    select a.id, a.name, a.country,
        case
            when a.normalized_name = b.k then 0
            when a.normalized_name like b.k || '%' then 1
            else 2
        end as tier,
        similarity(a.name, b.q) as score
    from bounded b
    join public.artists a
        on a.normalized_name like b.k || '%' or a.name ilike '%' || b.q || '%'
    where b.q <> ''
    order by tier, score desc, a.name
    limit (select n from bounded)
),
label_hits as (
    select l.id, l.name, l.country,
        case
            when l.normalized_name = b.k then 0
            when l.normalized_name like b.k || '%' then 1
            else 2
        end as tier,
        similarity(l.name, b.q) as score
    from bounded b
    join public.labels l
        on l.normalized_name like b.k || '%' or l.name ilike '%' || b.q || '%'
    where b.q <> ''
    order by tier, score desc, l.name
    limit (select n from bounded)
),
release_hits as (
    select r.id, r.title, r.release_year, r.catalog_number, r.discogs_id,
        ra.name as artist_name, rl.name as label_name,
        similarity(r.title, b.q) as score
    from bounded b
    join public.releases r on r.title ilike '%' || b.q || '%'
    left join public.artists ra on ra.id = r.artist_id
    left join public.labels rl on rl.id = r.label_id
    where b.q <> ''
    order by score desc, r.release_year desc nulls last, r.title
    limit (select n from bounded)
)
select jsonb_build_object(
    'artists', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', h.id,
            'name', h.name,
            'country', h.country,
            'discogs_id', x.external_id) order by h.tier, h.score desc, h.name)
        from artist_hits h
        left join public.external_ids x
            on x.entity_type = 'artist' and x.entity_id = h.id and x.provider = 'discogs'
    ), '[]'::jsonb),
    'labels', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', h.id,
            'name', h.name,
            'country', h.country,
            'discogs_id', x.external_id) order by h.tier, h.score desc, h.name)
        from label_hits h
        left join public.external_ids x
            on x.entity_type = 'label' and x.entity_id = h.id and x.provider = 'discogs'
    ), '[]'::jsonb),
    'releases', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', h.id,
            'title', h.title,
            'artist_name', h.artist_name,
            'label_name', h.label_name,
            'release_year', h.release_year,
            'catalog_number', h.catalog_number,
            'discogs_id', h.discogs_id) order by h.score desc, h.title)
        from release_hits h
    ), '[]'::jsonb)
);
$$;

-- ---------------------------------------------------------------------------
-- Finished release jobs
-- ---------------------------------------------------------------------------

-- As 0055, except that a finished `cache_discogs_release` is deleted rather
-- than kept as `done`. Its document in R2 and `discogs_cached_at` already say
-- it happened, dedupe only ever looks at pending and running jobs, and the
-- two days `prune_spent_rows` kept them for was ~30,000 rows, ~10 MB, that
-- nothing read. A failed one is kept, as every failure is.
create or replace function public.complete_enrichment_jobs(p_results jsonb)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_done int;
    v_removed int;
begin
    with r as (
        select (x->>'id')::uuid as id
        from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) as x
        where coalesce((x->>'ok')::boolean, false)
    )
    delete from public.enrichment_jobs j
    using r
    where j.id = r.id and j.job_type = 'cache_discogs_release';
    get diagnostics v_removed = row_count;

    with r as (
        select (x->>'id')::uuid as id,
               coalesce((x->>'ok')::boolean, false) as ok,
               x->>'error' as error
        from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) as x
    )
    update public.enrichment_jobs j
    set status = case
            when r.ok then 'done'
            when j.attempts >= j.max_attempts then 'failed'
            else 'pending'
        end,
        last_error = case when r.ok then null else left(coalesce(r.error, ''), 500) end,
        next_attempt_at = case
            when r.ok then j.next_attempt_at
            -- 1, 2, 4, 8 … minutes, capped at an hour. As 0005.
            else now() + (least(60, power(2, least(j.attempts, 6))::int) || ' minutes')::interval
        end
    from r
    where j.id = r.id;
    get diagnostics v_done = row_count;

    return v_done + v_removed;
end $$;

revoke all on function public.complete_enrichment_jobs(jsonb) from public, anon, authenticated;
grant execute on function public.complete_enrichment_jobs(jsonb) to service_role;
