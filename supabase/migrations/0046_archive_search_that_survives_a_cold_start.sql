-- Archive search that finishes inside the app's three seconds when cold.
--
-- 0045 matched by walking every line of the 374 archive lists. Warm, that is
-- about 100 ms. Cold -- the first search after the database has been idle and
-- those rows are on disk -- it read all 51,000 of them, and PostgREST calls it
-- as `anon`, whose statement_timeout is 3s. pg_stat_statements showed a
-- 2,474 ms call among the app's first twenty; the ones past 3s were cancelled,
-- which it does not record. So the listener's first search sometimes failed
-- and the second, over rows now in memory, worked.
--
-- A trigram index answers the most selective word directly, and only the
-- lines it finds are read. The index is on exactly the expression searched,
-- and partial: only archive lines carry `media_url`.
--
-- Safe to re-run.

create index if not exists radio_appearances_archive_search_trgm
    on public.radio_appearances
    using gin ((' ' || coalesce(normalized_artist_name, '') || ' ' || coalesce(normalized_title, '')) gin_trgm_ops)
    where media_url is not null;

create or replace function public.search_archives(p_query text, p_limit int default 60)
returns table (
    appearance_id uuid,
    media_url text,
    raw_artist_name text,
    raw_track_title text,
    artist_id uuid,
    artist_name text,
    archive_id uuid,
    archive_title text
)
language plpgsql
stable
-- Invoker's rights: it reads only what the app can already read, the same
-- tables `episode_tracklist` does.
as $$
declare
    whole text := btrim(coalesce(p_query, ''));
    patterns text[];
    lead_pattern text;
begin
    if whole = '' then
        return;
    end if;

    -- Every word typed must begin a word of "artist title": "hino" finds
    -- Terumasa Hino, not rhinoceros. The leading space on both sides makes it
    -- a word start.
    select array_agg('% ' || word || '%' order by length(word) desc)
    into patterns
    from unnest(string_to_array(whole, ' ')) as word
    where length(word) > 0;

    -- The longest word leads, as a single pattern the trigram index can
    -- answer; `like all` over an array cannot use it. The rest filter what
    -- it found.
    lead_pattern := patterns[1];

    return query
    select h.id, h.media_url, h.raw_artist_name, h.raw_track_title,
           h.artist_id, h.artist_name, h.archive_id, h.archive_title
    from (
        -- One row per video: the same upload sits in a channel's uploads and
        -- in any playlist it was sorted into. The uploads copy is kept.
        select distinct on (ra.media_url)
            ra.id, ra.media_url, ra.raw_artist_name, ra.raw_track_title,
            ra.artist_id, a.name as artist_name,
            rs.id as archive_id, rs.title as archive_title,
            ra.normalized_artist_name as artist_key,
            ra.normalized_title as title_key
        from public.radio_appearances ra
        join public.radio_episodes re on re.id = ra.radio_episode_id
        join public.radio_shows rs on rs.id = re.radio_show_id
        left join public.artists a on a.id = ra.artist_id
        where ra.media_url is not null
          and (' ' || coalesce(ra.normalized_artist_name, '') || ' ' || coalesce(ra.normalized_title, ''))
              like lead_pattern
          and (' ' || coalesce(ra.normalized_artist_name, '') || ' ' || coalesce(ra.normalized_title, ''))
              like all (patterns)
          and re.provider = 'youtube'
        order by ra.media_url, (re.external_id like 'UU%') desc, ra.track_index
    ) as h
    order by
        -- The artist named exactly, then an artist whose name starts with it,
        -- then a record by that title, then everything else. Coalesced,
        -- because a line with no artist compares as null, and nulls sort
        -- first in a descending order.
        coalesce(h.artist_key = whole, false) desc,
        coalesce(h.artist_key like whole || '%', false) desc,
        coalesce(h.title_key = whole, false) desc,
        h.artist_key nulls last,
        h.title_key
    limit least(greatest(coalesce(p_limit, 60), 1), 200);
end $$;

revoke all on function public.search_archives(text, int) from public;
grant execute on function public.search_archives(text, int) to anon, authenticated, service_role;
