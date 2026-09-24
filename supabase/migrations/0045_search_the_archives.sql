-- Searching the archives by artist or record.
--
-- Everything an archive holds is already a row here (0041): every upload the
-- crawl has read is a `radio_appearances` line with an address in
-- `media_url`. So a search is a query of our own tables, never a request to
-- YouTube -- which would spend the day's quota on every keystroke and answer
-- for all of YouTube rather than the curators Indigo follows.
--
-- Matched on the normalized artist and title, which the app computes with the
-- same rules (RecordingKey.normalize, pinned to normalize.ts), so accents,
-- case and punctuation never decide whether something is found.
--
-- Safe to re-run.

-- No index: every word is matched against the lines of the 374 archive lists
-- (found by provider), which the existing episode index reaches directly --
-- about 75 ms for the whole set. A trigram index on the text went unused by
-- the planner and cost space the database is short of.
drop index if exists public.radio_appearances_archive_search_trgm;

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
begin
    if whole = '' then
        return;
    end if;

    -- Every word typed must begin a word of "artist title": "hino" finds
    -- Terumasa Hino, not rhinoceros. A leading space on both sides of the
    -- comparison is what makes it a word start.
    select array_agg('% ' || word || '%')
    into patterns
    from unnest(string_to_array(whole, ' ')) as word
    where length(word) > 0;

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
        from public.radio_episodes re
        join public.radio_appearances ra on ra.radio_episode_id = re.id
        join public.radio_shows rs on rs.id = re.radio_show_id
        left join public.artists a on a.id = ra.artist_id
        where re.provider = 'youtube'
          and ra.media_url is not null
          and (' ' || coalesce(ra.normalized_artist_name, '') || ' ' || coalesce(ra.normalized_title, ''))
              like all (patterns)
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

-- On the one list of what the app may call (see 0027 and 0023), carried
-- forward from 0029 with this added.
create or replace function public.app_callable_functions()
returns text[]
language sql
immutable
as $$
    select array[
        'app_callable_functions',
        'artist_radio_appearances',
        'artist_radio_relations',
        'artist_radio_summary',
        'credit_row_count',
        'dig_radio_for_artists',
        'enrichment_queue_health',
        'episode_tracklist',
        'label_radio_summary',
        'portraits_for_artists',
        'release_cache_coverage',
        'request_artist_shelf',
        'request_release_cache',
        'request_scene_roster',
        'search_archives',
        'search_catalog'
    ]
$$;
grant execute on function public.app_callable_functions() to anon, authenticated, service_role;
