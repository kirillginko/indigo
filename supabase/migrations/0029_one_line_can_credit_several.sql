-- A tracklist line can credit more than one person.
--
-- NTS writes a collaboration as one string and the ingest keyed
-- `normalized_artist_name` on the whole of it, so `adopt_radio_artists` made an
-- artist out of every one. Measured on the live project: 9,013 of 45,158 artist
-- rows -- twenty percent of the table -- are credits rather than artists.
-- "DJ Krush, Abijah". "Chuck Strangers, Billy Woods, Zeroh". "Jah Balla X
-- MikeyNYC X Ibu DaDon". Each has a page nobody can use, a row in search that
-- opens onto nothing, and radio plays taken off the people who made the record.
--
-- This migration only makes room for the fix. `nts.ts` now resolves a line to
-- its primary credit and keeps the rest here; the 9,013 rows already written
-- are cleaned up separately, once the ingest has been watched on real
-- tracklists. Deleting nine thousand artist rows is not something to do in the
-- same breath as changing what writes them.
--
-- Safe to re-run.

alter table public.radio_appearances
    add column if not exists credited_artist_names text[],
    add column if not exists credited_artist_keys text[];

-- Null for the ordinary line, which credits one artist and stores nothing here
-- -- `normalized_artist_name` already says who that is. Only a line the
-- splitter actually divided carries these, which is what makes the index worth
-- having.
create index if not exists radio_appearances_credited_idx
    on public.radio_appearances using gin (credited_artist_keys)
    where credited_artist_keys is not null;

-- ---------------------------------------------------------------------------
-- What is still filed as a credit
-- ---------------------------------------------------------------------------

-- The artists that are really credits, and the primary each one should collapse
-- to.
--
-- A view rather than a migration step, deliberately. It names what the cleanup
-- would touch without touching it, so the number can be read before anything is
-- deleted and read again afterwards to see it fall.
--
-- Matched against `credited_artist_keys`, which only the new ingest writes --
-- so an artist appears here once a line that credits them has been read again.
-- That is slower than matching the name in SQL and it is the only honest way:
-- splitting a credit is `ArtistName.split`'s job, it refuses to split "&"
-- because Holden & Zimpel is a duo, and a second implementation here would be
-- free to disagree and invent people.
create or replace view public.artists_that_are_credits as
select
    a.id as credit_id,
    a.name as credit_name,
    a.normalized_name as credit_key,
    (array_agg(ra.credited_artist_keys[1] order by ra.created_at))[1] as primary_key
from public.artists a
join public.radio_appearances ra
    on ra.normalized_artist_name = a.normalized_name
where ra.credited_artist_keys is not null
  and array_length(ra.credited_artist_keys, 1) > 1
  -- The row is the whole credit rather than one of the people in it.
  and a.normalized_name <> ra.credited_artist_keys[1]
group by a.id, a.name, a.normalized_name;

grant select on public.artists_that_are_credits to service_role;

-- How much of the artist table is credits rather than artists. Read by hand,
-- before and after the cleanup.
create or replace function public.credit_row_count()
returns jsonb
language sql
stable
as $$
    select jsonb_build_object(
        'artists', (select count(*) from public.artists),
        'known_credits', (select count(*) from public.artists_that_are_credits),
        'lines_with_several_credits', (
            select count(*) from public.radio_appearances
            where credited_artist_keys is not null
              and array_length(credited_artist_keys, 1) > 1)
    );
$$;

grant execute on function public.credit_row_count() to anon, authenticated, service_role;

-- Added to the one list, so 0023's sweep leaves it callable. See 0027.
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
        'episode_tracklist',
        'label_radio_summary',
        'portraits_for_artists',
        'release_cache_coverage',
        'request_artist_shelf',
        'request_release_cache',
        'request_scene_roster',
        'search_catalog'
    ]
$$;

grant execute on function public.app_callable_functions() to anon, authenticated, service_role;
