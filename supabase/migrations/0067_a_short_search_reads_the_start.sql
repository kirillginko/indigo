-- A short search reads only what starts with it.
--
-- `search_catalog` matched a name that *contains* the query, whatever its
-- length. Three letters is a single trigram: "ric" is inside 6,251 artist
-- names, every one of which was fetched and scored to return eight. Warm
-- that is 375 ms. Cold -- the first search after the app has sat idle -- it
-- was 4.6 s against the 3 s `anon` is allowed, so the search failed and the
-- same search a moment later worked.
--
-- Under four characters somebody is still typing the start of a name, and
-- the start is what the prefix index answers. "Contains" begins at four,
-- where a query has enough trigrams to be selective.
--
-- Same signature and grants; only what a short query matches changes.

create or replace function public.search_catalog(p_query text, p_key text, p_limit integer default 8)
returns jsonb
language sql
stable
as $function$
with bounded as (
    select
        greatest(1, least(coalesce(p_limit, 8), 25)) as n,
        coalesce(nullif(btrim(p_query), ''), '') as q,
        coalesce(nullif(btrim(p_key), ''), '') as k,
        -- "Contains", from four characters. Null below that: `ilike null`
        -- matches nothing, and the index is not read to find that out.
        case when char_length(btrim(coalesce(p_query, ''))) >= 4
             then '%' || btrim(p_query) || '%' end as anywhere,
        -- A release has no normalized name to take a prefix of, so a short
        -- query matches the start of its title instead.
        case when char_length(btrim(coalesce(p_query, ''))) >= 4
             then '%' || btrim(p_query) || '%'
             else btrim(coalesce(p_query, '')) || '%' end as title_pattern
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
        on a.normalized_name like b.k || '%' or a.name ilike b.anywhere
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
        on l.normalized_name like b.k || '%' or l.name ilike b.anywhere
    where b.q <> ''
    order by tier, score desc, l.name
    limit (select n from bounded)
),
release_hits as (
    select r.id, r.title, r.release_year, r.catalog_number, r.discogs_id,
        ra.name as artist_name, rl.name as label_name,
        similarity(r.title, b.q) as score
    from bounded b
    join public.releases r on r.title ilike b.title_pattern
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
$function$;
