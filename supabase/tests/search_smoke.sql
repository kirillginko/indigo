-- Smoke test for catalogue search.
--
-- `search_catalog` is the one query in the app that is not a lookup: nothing
-- else asks the catalogue a question it might answer wrongly rather than not
-- at all. Applying the migration proves the SQL parses; it does not prove that
-- "ilian" finds Ilian Tape, that an exact name outranks a substring, or that a
-- release carries the Discogs id that lets a result open a page. Each of those
-- would show in the app as a search field that returns the wrong thing, which
-- is worse than one that returns nothing.
--
-- Run against a throwaway Postgres 17 with the migrations applied:
--
--     psql -f supabase/tests/search_smoke.sql
--
-- Every check raises on failure, so a clean run means a clean run.

\set ON_ERROR_STOP on
begin;

insert into public.artists (name, normalized_name, country) values
    ('Skee Mask', 'skee mask', 'DE'),
    ('Skeleton Crew', 'skeleton crew', 'US'),
    ('Zenker Brothers', 'zenker brothers', 'DE');

insert into public.labels (name, normalized_name, country) values
    ('Ilian Tape', 'ilian tape', 'DE'),
    ('Blackest Ever Black', 'blackest ever black', 'GB');

insert into public.releases (title, artist_id, label_id, release_year, catalog_number)
select 'Compro',
       (select id from public.artists where normalized_name = 'skee mask'),
       (select id from public.labels where normalized_name = 'ilian tape'),
       2018,
       'ITLP07';

insert into public.external_ids (entity_type, entity_id, provider, external_id)
select 'release',
       (select id from public.releases where title = 'Compro'),
       'discogs',
       '12227218';

insert into public.external_ids (entity_type, entity_id, provider, external_id)
select 'label',
       (select id from public.labels where normalized_name = 'ilian tape'),
       'discogs',
       '54782';

-- ---------------------------------------------------------------------------
-- Finding things
-- ---------------------------------------------------------------------------

do $$
declare
    answer jsonb;
begin
    -- A half-typed label name. The whole point: `normalized_name = 'ilian'`
    -- finds nothing, and somebody typing has not finished the word yet.
    answer := public.search_catalog('ilian', 'ilian', 8);
    if jsonb_array_length(answer -> 'labels') <> 1 then
        raise exception 'a prefix should find one label, got %', answer -> 'labels';
    end if;
    if (answer -> 'labels' -> 0 ->> 'name') <> 'Ilian Tape' then
        raise exception 'wrong label for "ilian": %', answer -> 'labels';
    end if;
    -- Carried so the result opens the label Indigo already has a page for,
    -- rather than one guessed back from a name two labels might share.
    if (answer -> 'labels' -> 0 ->> 'discogs_id') <> '54782' then
        raise exception 'label lost its discogs id: %', answer -> 'labels';
    end if;

    -- A prefix that two artists share. Both come back.
    answer := public.search_catalog('ske', 'ske', 8);
    if jsonb_array_length(answer -> 'artists') <> 2 then
        raise exception '"ske" should find two artists, got %', answer -> 'artists';
    end if;

    -- Ranked, not merely returned: an exact match is the answer, whatever
    -- else contains the same letters.
    answer := public.search_catalog('Skee Mask', 'skee mask', 8);
    if (answer -> 'artists' -> 0 ->> 'name') <> 'Skee Mask' then
        raise exception 'an exact name should rank first, got %', answer -> 'artists';
    end if;

    -- A release, with the credit and the imprint the page needs to draw a row.
    answer := public.search_catalog('compro', 'compro', 8);
    if jsonb_array_length(answer -> 'releases') <> 1 then
        raise exception 'expected one release, got %', answer -> 'releases';
    end if;
    if (answer -> 'releases' -> 0 ->> 'artist_name') <> 'Skee Mask'
        or (answer -> 'releases' -> 0 ->> 'label_name') <> 'Ilian Tape'
        or (answer -> 'releases' -> 0 ->> 'catalog_number') <> 'ITLP07'
        or (answer -> 'releases' -> 0 ->> 'discogs_id') <> '12227218' then
        raise exception 'release came back thin: %', answer -> 'releases';
    end if;

    -- A name nobody has filed is three empty lists, not an error and not null.
    answer := public.search_catalog('qqzz', 'qqzz', 8);
    if jsonb_array_length(answer -> 'artists') <> 0
        or jsonb_array_length(answer -> 'labels') <> 0
        or jsonb_array_length(answer -> 'releases') <> 0 then
        raise exception 'a miss should be empty, got %', answer;
    end if;

    -- An empty query matches everything if it is allowed to, which on a real
    -- catalogue is the whole table.
    answer := public.search_catalog('', '', 8);
    if jsonb_array_length(answer -> 'artists') <> 0
        or jsonb_array_length(answer -> 'labels') <> 0
        or jsonb_array_length(answer -> 'releases') <> 0 then
        raise exception 'an empty query should match nothing, got %', answer;
    end if;

    -- Bounded, however many rows match and whatever the caller asks for.
    answer := public.search_catalog('e', 'e', 500);
    if jsonb_array_length(answer -> 'artists') > 25 then
        raise exception 'the limit is not being clamped: %',
            jsonb_array_length(answer -> 'artists');
    end if;

    raise notice 'search smoke: all checks passed';
end $$;

rollback;
