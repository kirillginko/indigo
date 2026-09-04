-- Radio provenance: shows, episodes, and what was played in them.
--
-- 0003 modelled radio as one flat table where a "show" was really a single
-- broadcast. That cannot answer the question the feature exists for — "which
-- shows have played this artist" — because there was no show to count, only
-- broadcasts. A programme, its broadcasts, and the tracks inside them are
-- three different things, so they get three tables.
--
-- The other change is that an appearance no longer requires a canonical
-- recording. NTS hands us "Skee Mask - Flyby VFR" long before Indigo has a
-- recording row to point at, and throwing that away would discard exactly the
-- music this app exists for: white labels, dubplates, unreleased edits. The
-- raw strings are kept on the row and resolved later, repeatedly, as the
-- catalogue fills in.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Recordings gain a matchable title
-- ---------------------------------------------------------------------------

-- Matching a tracklist line to a recording needs the same normalized form the
-- artist lookup already uses. Written by the Edge Function's normalizer, never
-- computed here, so one implementation decides what "the same title" means
-- (supabase/functions/_shared/normalize.ts, pinned by NormalizationParityTests).
alter table public.recordings add column if not exists normalized_title text;

create index if not exists recordings_normalized_title_idx
    on public.recordings(artist_id, normalized_title);

-- ---------------------------------------------------------------------------
-- Episodes
-- ---------------------------------------------------------------------------

create table if not exists public.radio_episodes (
    id uuid primary key default gen_random_uuid(),

    -- Nullable on purpose: an episode discovered before its programme is one
    -- fetch behind, not an error. The show is filled in when it arrives.
    radio_show_id uuid references public.radio_shows(id) on delete set null,

    provider text not null,
    external_id text not null,

    title text,
    description text,
    aired_at timestamptz,
    duration_seconds int,

    archive_url text,
    image_url text,

    -- Distinguishes "we have not looked" from "we looked and NTS publishes no
    -- tracklist for this one". Without it every re-import re-asks upstream for
    -- an answer that will not change.
    tracklist_status text not null default 'unknown',

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique(provider, external_id)
);

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'radio_episodes_tracklist_status_check') then
        alter table public.radio_episodes add constraint radio_episodes_tracklist_status_check
            check (tracklist_status in ('unknown', 'available', 'partial', 'unavailable', 'processed'));
    end if;
end $$;

-- Rows written under 0003 are broadcasts wearing the word "show". Move them
-- across keeping their ids, so the appearances pointing at them survive the
-- rename below without a lookup table.
--
-- Dynamic because a second run has no `aired_at` on radio_shows to select, and
-- Postgres resolves column names when it parses the statement, not when the
-- guard around it decides whether to run.
do $$
begin
    if exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'radio_shows' and column_name = 'aired_at'
    ) then
        execute '
            insert into public.radio_episodes
                (id, provider, external_id, title, aired_at, duration_seconds)
            select id, provider, external_id, title, aired_at, duration_seconds
            from public.radio_shows
            on conflict do nothing';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Appearances
-- ---------------------------------------------------------------------------

alter table public.radio_appearances
    add column if not exists radio_episode_id uuid,
    -- The position in the published tracklist. This, not the offset, is what
    -- identifies a row: NTS reports an estimated offset for most episodes and
    -- a re-import would otherwise land beside the old row rather than on it.
    add column if not exists track_index int,
    add column if not exists raw_artist_name text,
    add column if not exists raw_track_title text,
    add column if not exists normalized_artist_name text,
    add column if not exists normalized_title text,
    -- Kept alongside recording_id. An artist match is reachable long before a
    -- recording match is — the artist page only needs to know it was played.
    add column if not exists artist_id uuid,
    add column if not exists end_offset_seconds int,
    add column if not exists identification_source text;

do $$
begin
    if exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'radio_appearances'
          and column_name = 'radio_show_id'
    ) then
        update public.radio_appearances
        set radio_episode_id = radio_show_id
        where radio_episode_id is null;

        -- Dropped before the column it keys on. Its identity — episode plus
        -- recording plus offset — stops working the moment recording_id may be
        -- null, because Postgres treats every null as distinct and the same
        -- unresolved track would insert without limit.
        drop index if exists public.radio_appearances_unique_idx;
        alter table public.radio_appearances drop column radio_show_id;
    end if;
end $$;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'radio_appearances_episode_fkey') then
        alter table public.radio_appearances
            add constraint radio_appearances_episode_fkey
            foreign key (radio_episode_id) references public.radio_episodes(id) on delete cascade;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'radio_appearances_artist_fkey') then
        alter table public.radio_appearances
            add constraint radio_appearances_artist_fkey
            foreign key (artist_id) references public.artists(id) on delete set null;
    end if;

    -- Cascading on a recording was right when an appearance could not exist
    -- without one. Now that it can, merging two recordings must not delete the
    -- evidence that produced them.
    if exists (select 1 from pg_constraint where conname = 'radio_appearances_recording_id_fkey') then
        alter table public.radio_appearances drop constraint radio_appearances_recording_id_fkey;
    end if;
    if not exists (select 1 from pg_constraint where conname = 'radio_appearances_recording_fkey') then
        alter table public.radio_appearances
            add constraint radio_appearances_recording_fkey
            foreign key (recording_id) references public.recordings(id) on delete set null;
    end if;
end $$;

-- One episode, one slot in its tracklist. Re-importing corrects the row it
-- already wrote rather than stacking a second copy beside it, which is what
-- keeps "played together nine times" worth believing.
create unique index if not exists radio_appearances_slot_idx
    on public.radio_appearances(radio_episode_id, track_index);

-- ---------------------------------------------------------------------------
-- Shows become programmes
-- ---------------------------------------------------------------------------

-- The broadcast-shaped columns moved to radio_episodes above; what is left
-- here describes the programme itself.
alter table public.radio_shows
    add column if not exists description text,
    add column if not exists host_name text,
    add column if not exists image_url text,
    add column if not exists provider_url text;

delete from public.radio_shows rs
where exists (select 1 from public.radio_episodes re where re.id = rs.id);

alter table public.radio_shows
    drop column if exists aired_at,
    drop column if exists duration_seconds;

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

create index if not exists radio_episodes_show_idx on public.radio_episodes(radio_show_id);
create index if not exists radio_episodes_aired_at_idx on public.radio_episodes(aired_at desc);
create index if not exists radio_episodes_tracklist_status_idx
    on public.radio_episodes(tracklist_status);

create index if not exists radio_appearances_episode_idx
    on public.radio_appearances(radio_episode_id, track_index);
create index if not exists radio_appearances_artist_idx on public.radio_appearances(artist_id);

-- The resolution pass reads exactly this: rows still missing an artist, by the
-- name they arrived under.
create index if not exists radio_appearances_pending_artist_idx
    on public.radio_appearances(normalized_artist_name)
    where artist_id is null;

-- ---------------------------------------------------------------------------
-- Entity types
-- ---------------------------------------------------------------------------

-- An episode is addressable now: it can carry artwork and an upstream id.
do $$
declare
    spec record;
begin
    for spec in
        select * from (values
            ('external_ids',        'external_ids_entity_type_check',           'entity_type'),
            ('artwork',             'artwork_entity_type_check',                'entity_type'),
            ('music_relationships', 'music_relationships_from_type_check',      'from_entity_type'),
            ('music_relationships', 'music_relationships_to_type_check',        'to_entity_type')
        ) as t(table_name, constraint_name, column_name)
    loop
        execute format(
            'alter table public.%I drop constraint if exists %I',
            spec.table_name, spec.constraint_name);
        execute format(
            'alter table public.%I add constraint %I check (%I in
                (''artist'', ''label'', ''release'', ''recording'', ''radio_show'', ''radio_episode''))',
            spec.table_name, spec.constraint_name, spec.column_name);
    end loop;
end $$;

-- ---------------------------------------------------------------------------
-- updated_at, RLS
-- ---------------------------------------------------------------------------

drop trigger if exists radio_episodes_touch_updated_at on public.radio_episodes;
create trigger radio_episodes_touch_updated_at before update on public.radio_episodes
    for each row execute function public.touch_updated_at();

alter table public.radio_episodes enable row level security;

drop policy if exists radio_episodes_read on public.radio_episodes;
create policy radio_episodes_read on public.radio_episodes
    for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

-- Turns raw tracklist strings into graph edges, and is meant to be run again
-- and again: a line that matched nothing in March matches in June because a
-- Discogs release normalized the artist in between. Nothing is deleted when it
-- fails to match — the raw names stay, which is the whole point.
--
-- Only ever resolves an unambiguous match. Two artists sharing a normalized
-- name is common ("Nova", "Origin"), and guessing between them would put an
-- appearance on the wrong artist's page with no way to tell it had happened.
create or replace function public.resolve_radio_appearances(
    p_episode_id uuid default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    resolved int := 0;
    touched int;
begin
    with candidate as (
        -- array_agg rather than min: Postgres 17 has no min() for uuid, and
        -- the `having` below has already established there is only one.
        select ra.id, (array_agg(a.id))[1] as artist_id
        from public.radio_appearances ra
        join public.artists a on a.normalized_name = ra.normalized_artist_name
        where ra.artist_id is null
          and coalesce(ra.normalized_artist_name, '') <> ''
          and (p_episode_id is null or ra.radio_episode_id = p_episode_id)
        group by ra.id
        having count(distinct a.id) = 1
    )
    update public.radio_appearances ra
    set artist_id = candidate.artist_id,
        identification_source = coalesce(ra.identification_source, 'normalized_artist')
    from candidate
    where candidate.id = ra.id;

    get diagnostics touched = row_count;
    resolved := resolved + touched;

    with candidate as (
        select ra.id, (array_agg(r.id))[1] as recording_id
        from public.radio_appearances ra
        join public.recordings r
            on r.artist_id = ra.artist_id
           and r.normalized_title = ra.normalized_title
        where ra.recording_id is null
          and ra.artist_id is not null
          and coalesce(ra.normalized_title, '') <> ''
          and (p_episode_id is null or ra.radio_episode_id = p_episode_id)
        group by ra.id
        having count(distinct r.id) = 1
    )
    update public.radio_appearances ra
    set recording_id = candidate.recording_id,
        identification_source = 'normalized_recording',
        confidence = greatest(coalesce(ra.confidence, 0), 0.8)
    from candidate
    where candidate.id = ra.id;

    get diagnostics touched = row_count;
    return resolved + touched;
end $$;

-- Writes, so it is the service role's alone. The app ships a read-only key and
-- never calls it; the Edge Function does, once per episode it ingests.
revoke all on function public.resolve_radio_appearances(uuid) from public;
grant execute on function public.resolve_radio_appearances(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------

-- The artist page's radio header, in one round trip. Counting shows, hosts and
-- episodes client-side would mean shipping every appearance to do arithmetic
-- Postgres already did while finding them.
create or replace function public.artist_radio_summary(p_artist_id uuid)
returns jsonb
language sql
stable
as $$
with appearance as (
    select ra.id, ra.radio_episode_id, re.radio_show_id, re.aired_at
    from public.radio_appearances ra
    join public.radio_episodes re on re.id = ra.radio_episode_id
    where ra.artist_id = p_artist_id
),
top_show as (
    select rs.id, rs.provider, rs.external_id, rs.title, rs.station, rs.host_name,
           count(*) as appearance_count
    from appearance a
    join public.radio_shows rs on rs.id = a.radio_show_id
    group by rs.id, rs.provider, rs.external_id, rs.title, rs.station, rs.host_name
    order by count(*) desc, rs.title
    limit 8
)
select jsonb_build_object(
    'artist_id', p_artist_id,
    'appearance_count', (select count(*) from appearance),
    'episode_count', (select count(distinct radio_episode_id) from appearance),
    'show_count', (select count(distinct radio_show_id) from appearance),
    'host_count', (select count(distinct rs.host_name)
                   from appearance a
                   join public.radio_shows rs on rs.id = a.radio_show_id
                   where rs.host_name is not null),
    'first_appearance_at', (select min(aired_at) from appearance),
    'latest_appearance_at', (select max(aired_at) from appearance),
    'top_shows', coalesce((
        select jsonb_agg(jsonb_build_object(
            'show_id', id,
            'provider', provider,
            'external_id', external_id,
            'title', title,
            'station', station,
            'host_name', host_name,
            'appearance_count', appearance_count))
        from top_show), '[]'::jsonb)
);
$$;

-- Every broadcast this artist turned up in, newest first. The raw title is
-- returned rather than the resolved recording's, because what a show announced
-- is the record of what was played — and for most of these there is no
-- resolved recording yet.
create or replace function public.artist_radio_appearances(
    p_artist_id uuid,
    p_limit int default 50
)
returns table (
    appearance_id uuid,
    episode_id uuid,
    episode_title text,
    aired_at timestamptz,
    archive_url text,
    episode_external_id text,
    provider text,
    show_id uuid,
    show_title text,
    station text,
    host_name text,
    track_index int,
    raw_artist_name text,
    raw_track_title text,
    offset_seconds int,
    recording_id uuid
)
language sql
stable
as $$
select
    ra.id, re.id, re.title, re.aired_at, re.archive_url, re.external_id, re.provider,
    rs.id, rs.title, rs.station, rs.host_name,
    ra.track_index, ra.raw_artist_name, ra.raw_track_title, ra.offset_seconds, ra.recording_id
from public.radio_appearances ra
join public.radio_episodes re on re.id = ra.radio_episode_id
left join public.radio_shows rs on rs.id = re.radio_show_id
where ra.artist_id = p_artist_id
order by re.aired_at desc nulls last, ra.track_index
limit greatest(1, least(coalesce(p_limit, 50), 500));
$$;

-- An episode read back from Indigo rather than from NTS. Carries the resolved
-- artist id where there is one, so every line in a tracklist can be a way into
-- DIG instead of a piece of text.
create or replace function public.episode_tracklist(p_episode_id uuid)
returns table (
    appearance_id uuid,
    track_index int,
    raw_artist_name text,
    raw_track_title text,
    offset_seconds int,
    artist_id uuid,
    artist_name text,
    recording_id uuid
)
language sql
stable
as $$
select
    ra.id, ra.track_index, ra.raw_artist_name, ra.raw_track_title, ra.offset_seconds,
    ra.artist_id, a.name, ra.recording_id
from public.radio_appearances ra
left join public.artists a on a.id = ra.artist_id
where ra.radio_episode_id = p_episode_id
order by ra.track_index;
$$;

grant execute on function public.artist_radio_summary(uuid) to anon, authenticated;
grant execute on function public.artist_radio_appearances(uuid, int) to anon, authenticated;
grant execute on function public.episode_tracklist(uuid) to anon, authenticated;
