-- Radio storage prototype: the same synthetic lines in five shapes.
--
-- Runs only in the throwaway cluster that run.sh creates and deletes. None of
-- this is a migration, and nothing here touches the linked project.
--
-- A   radio_appearances, exactly as live (columns, defaults, all seven indexes).
-- C2  one compact row per line: the hybrid benchmark's artist-page shape.
-- D1  one row per episode, lines packed into parallel arrays, GIN on artists.
-- D2  D1 without titles: titles live only in the episode's R2 document.
-- D3  D1 with int4 artist numbers instead of uuids, via a dictionary.
-- E   one row per artist: the episodes and positions it was played at.
--
-- A is loaded with every line, to check the synthetic data against the live
-- table's size. The rest hold broadcast lines only (media_url null): YouTube
-- upload lists stay in A in every plan, because archive search and the Dig
-- track player read them line by line.

create extension if not exists pg_trgm;

-- Shared: the same in every plan -------------------------------------------

create table artists (
    id uuid primary key,
    name text not null,
    normalized_name text not null
);
create index artists_normalized_name_idx on artists (normalized_name);

create table radio_shows (
    id uuid primary key,
    title text,
    station text default 'synthetic',
    host_name text,
    provider text default 'synthetic',
    external_id text
);

create table radio_episodes (
    id uuid primary key,
    radio_show_id uuid,
    provider text not null,
    external_id text not null,
    title text,
    aired_at timestamptz,
    archive_url text,
    tracklist_status text,
    unique (provider, external_id)
);
create index radio_episodes_show_idx on radio_episodes (radio_show_id);

-- Staging: the generator's lines, as loaded ---------------------------------

create unlogged table staging_lines (
    id uuid,
    recording_id uuid,
    offset_seconds int,
    confidence double precision,
    radio_episode_id uuid,
    track_index int,
    raw_artist_name text,
    raw_track_title text,
    normalized_artist_name text,
    normalized_title text,
    artist_id uuid,
    identification_source text,
    isrc text,
    deezer_track_id text,
    musicbrainz_recording_id text,
    credited_artist_names text[],
    media_url text,
    credited_artist_keys text[]
);

-- A: live -------------------------------------------------------------------

create table radio_appearances (
    id uuid primary key default gen_random_uuid(),
    recording_id uuid,
    offset_seconds integer,
    confidence double precision,
    created_at timestamptz not null default now(),
    radio_episode_id uuid,
    track_index integer,
    raw_artist_name text,
    raw_track_title text,
    normalized_artist_name text,
    normalized_title text,
    artist_id uuid,
    end_offset_seconds integer,
    identification_source text,
    isrc text,
    deezer_track_id text,
    musicbrainz_recording_id text,
    release_checked_at timestamptz,
    credited_artist_names text[],
    credited_artist_keys text[],
    media_url text
);

-- C2: one compact row per line ------------------------------------------------

create table radio_lines_c2 (
    radio_episode_id uuid not null,
    track_index int2 not null,
    artist_id uuid,
    isrc text,
    raw_track_title text,
    offset_seconds int4,
    primary key (radio_episode_id, track_index)
);

-- D1: one row per episode ------------------------------------------------------
--
-- Element i (1-based) is track_index i-1. Arrays that would hold nothing but
-- nulls are stored as null. Raw artist text is kept only where it differs
-- from the resolved artist's name, or the line is unresolved -- that is what
-- the artist page and the resolver need; everything else is in R2.

create table radio_tracklists (
    radio_episode_id uuid primary key,
    artist_ids uuid[] not null,
    titles text[],
    offsets int4[],
    recording_ids uuid[],
    isrcs text[],
    -- NTS's release lookups (enqueue_track_releases) key on these.
    deezer_ids text[],
    raw_artists text[],
    pending_keys text[]
);

-- D2: D1 without titles ---------------------------------------------------------

create table radio_tracklists_d2 (like radio_tracklists including defaults);
alter table radio_tracklists_d2 drop column titles;

-- D3: int4 artist numbers ---------------------------------------------------------
--
-- Live, this number would be a column on `artists`; here it is a side table so
-- its own cost shows.

create table artist_numbers (
    n int4 generated always as identity primary key,
    artist_id uuid not null unique
);

create table radio_tracklists_d3 (
    radio_episode_id uuid primary key,
    artist_ns int4[] not null,
    titles text[],
    offsets int4[],
    recording_ids uuid[],
    isrcs text[],
    deezer_ids text[],
    raw_artists text[],
    pending_keys text[]
);

-- E: one row per artist ----------------------------------------------------------

create table artist_postings (
    artist_id uuid primary key,
    episode_ids uuid[] not null,
    positions int2[] not null
);
