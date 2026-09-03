-- Indigo core metadata cache.
--
-- The listener's own library stays local in SwiftData. What lives here is the
-- shared music graph: normalized catalogue entities Indigo can serve instantly
-- instead of waiting on Discogs or MusicBrainz for every render.
--
-- Safe to re-run.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Entities
-- ---------------------------------------------------------------------------

create table if not exists public.artists (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    normalized_name text,
    country text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.labels (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    normalized_name text,
    country text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.releases (
    id uuid primary key default gen_random_uuid(),
    title text not null,
    artist_id uuid references public.artists(id) on delete set null,
    label_id uuid references public.labels(id) on delete set null,
    catalog_number text,
    release_year int,
    release_type text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.recordings (
    id uuid primary key default gen_random_uuid(),
    title text,
    artist_id uuid references public.artists(id) on delete set null,
    release_id uuid references public.releases(id) on delete set null,
    isrc text,
    musicbrainz_recording_id text,
    identification_status text not null default 'identified',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- The same Indigo entity carries many upstream identities. The Indigo UUID
-- stays canonical; this is how a Discogs or MusicBrainz id finds its way back
-- to it, and what makes an upstream fetch idempotent on the second run.
create table if not exists public.external_ids (
    id uuid primary key default gen_random_uuid(),
    entity_type text not null,
    entity_id uuid not null,
    provider text not null,
    external_id text not null,
    source_url text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique(provider, entity_type, external_id)
);

create table if not exists public.artwork (
    id uuid primary key default gen_random_uuid(),
    entity_type text not null,
    entity_id uuid not null,
    provider text,
    -- Kept side by side deliberately. Not every provider licenses permanent
    -- re-hosting, so an entity may legitimately have only the upstream URL.
    original_url text,
    storage_path text,
    thumbnail_path text,
    medium_path text,
    large_path text,
    width int,
    height int,
    fetched_at timestamptz,
    created_at timestamptz not null default now(),
    unique(entity_type, entity_id)
);

-- The escape hatch that lets Indigo cache a provider's response before anyone
-- has written a normalizer for it. Normalized tables are the goal; this keeps
-- the app fast in the meantime.
create table if not exists public.metadata_cache (
    id uuid primary key default gen_random_uuid(),
    provider text not null,
    resource_type text not null,
    resource_id text not null,
    payload jsonb not null,
    fetched_at timestamptz not null default now(),
    expires_at timestamptz,
    unique(provider, resource_type, resource_id)
);

-- ---------------------------------------------------------------------------
-- Keep the polymorphic columns honest
-- ---------------------------------------------------------------------------

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'external_ids_entity_type_check') then
        alter table public.external_ids add constraint external_ids_entity_type_check
            check (entity_type in ('artist', 'label', 'release', 'recording', 'radio_show'));
    end if;
    if not exists (select 1 from pg_constraint where conname = 'artwork_entity_type_check') then
        alter table public.artwork add constraint artwork_entity_type_check
            check (entity_type in ('artist', 'label', 'release', 'recording', 'radio_show'));
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

create index if not exists artists_normalized_name_idx on public.artists(normalized_name);
create index if not exists labels_normalized_name_idx on public.labels(normalized_name);
create index if not exists releases_catalog_number_idx on public.releases(catalog_number);
create index if not exists recordings_musicbrainz_id_idx on public.recordings(musicbrainz_recording_id);
create index if not exists recordings_isrc_idx on public.recordings(isrc);
create index if not exists external_ids_lookup_idx on public.external_ids(provider, entity_type, external_id);
create index if not exists external_ids_entity_idx on public.external_ids(entity_type, entity_id);
create index if not exists metadata_cache_lookup_idx on public.metadata_cache(provider, resource_type, resource_id);
create index if not exists metadata_cache_expiry_idx on public.metadata_cache(expires_at);

-- Postgres does not index foreign keys for you, and every DIG page is a join
-- back along one of these.
create index if not exists releases_artist_id_idx on public.releases(artist_id);
create index if not exists releases_label_id_idx on public.releases(label_id);
create index if not exists recordings_artist_id_idx on public.recordings(artist_id);
create index if not exists recordings_release_id_idx on public.recordings(release_id);

-- ---------------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------------

-- Staleness decides whether Indigo refetches, so updated_at has to mean
-- something. A default alone only records the insert.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end $$;

do $$
declare
    t text;
    trigger_name text;
begin
    foreach t in array array['artists', 'labels', 'releases', 'recordings', 'external_ids'] loop
        trigger_name := t || '_touch_updated_at';
        execute format('drop trigger if exists %I on public.%I', trigger_name, t);
        execute format(
            'create trigger %I before update on public.%I
             for each row execute function public.touch_updated_at()', trigger_name, t);
    end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

-- Read is open: this is shared catalogue data, and the app ships a publishable
-- key that anyone can extract. Write is granted to no one. The service-role
-- key bypasses RLS entirely, so the Edge Function that refreshes the cache
-- keeps working while the client stays read-only.

alter table public.artists        enable row level security;
alter table public.labels         enable row level security;
alter table public.releases       enable row level security;
alter table public.recordings     enable row level security;
alter table public.external_ids   enable row level security;
alter table public.artwork        enable row level security;
alter table public.metadata_cache enable row level security;

do $$
declare
    t text;
    policy_name text;
begin
    foreach t in array array['artists', 'labels', 'releases', 'recordings',
                             'external_ids', 'artwork', 'metadata_cache'] loop
        policy_name := t || '_read';
        execute format('drop policy if exists %I on public.%I', policy_name, t);
        execute format(
            'create policy %I on public.%I for select to anon, authenticated using (true)',
            policy_name, t);
    end loop;
end $$;
