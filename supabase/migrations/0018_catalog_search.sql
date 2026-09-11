-- Searching the shared catalogue by name.
--
-- Every read of `artists`, `labels` and `releases` so far has been a lookup:
-- you already know which entity you mean and you are asking for its row. That
-- is why the only name query in the app matches `normalized_name` exactly.
-- Somebody typing into a search field does not know the name — that is what
-- they are asking — so "ilian" has to find Ilian Tape and "boards of" has to
-- find Boards Of Canada.
--
-- Trigram indexes rather than full text search: these are names, not prose.
-- `to_tsvector` would stem them, lose the punctuation that distinguishes
-- several of them, and still not match a prefix somebody has half-typed.
--
-- The caller sends both the raw query and its normalized key. The app's own
-- normalizer is the one everything else in Indigo agrees with — see
-- RecordingKey.normalize and NormalizationParityTests — and reimplementing it
-- here would be a second definition free to drift from the first.
--
-- Safe to re-run.

create extension if not exists pg_trgm;

create index if not exists artists_name_trgm_idx
    on public.artists using gin (name gin_trgm_ops);
create index if not exists labels_name_trgm_idx
    on public.labels using gin (name gin_trgm_ops);
create index if not exists releases_title_trgm_idx
    on public.releases using gin (title gin_trgm_ops);

-- Prefix matching on the normalized name wants a btree that LIKE can use, and
-- the default collation's does not qualify. `text_pattern_ops` is what makes
-- `normalized_name like 'ilian%'` an index scan rather than a table read.
create index if not exists artists_normalized_name_prefix_idx
    on public.artists (normalized_name text_pattern_ops);
create index if not exists labels_normalized_name_prefix_idx
    on public.labels (normalized_name text_pattern_ops);

create or replace function public.search_catalog(
    p_query text,
    p_key text,
    p_limit int default 8
)
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
    select r.id, r.title, r.release_year, r.catalog_number,
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
            'discogs_id', x.external_id) order by h.score desc, h.title)
        from release_hits h
        left join public.external_ids x
            on x.entity_type = 'release' and x.entity_id = h.id and x.provider = 'discogs'
    ), '[]'::jsonb)
);
$$;

grant execute on function public.search_catalog(text, text, int) to anon, authenticated;
