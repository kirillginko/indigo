-- Radio knowledge (1F) and the DIG relationship graph (1G).
--
-- The beginning of a dataset that is Indigo's own rather than borrowed: what
-- was played, where, and next to what. Everything before this migration is a
-- faster way to ask other people's catalogues; this is the part that answers
-- questions none of them can.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Radio
-- ---------------------------------------------------------------------------

create table if not exists public.radio_shows (
    id uuid primary key default gen_random_uuid(),
    provider text not null,
    external_id text not null,
    station text,
    title text,
    aired_at timestamptz,
    duration_seconds int,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique(provider, external_id)
);

create table if not exists public.radio_appearances (
    id uuid primary key default gen_random_uuid(),
    recording_id uuid references public.recordings(id) on delete cascade,
    radio_show_id uuid references public.radio_shows(id) on delete cascade,
    offset_seconds int,
    confidence double precision,
    created_at timestamptz not null default now()
);

-- A show plays a record once at a given point. Re-importing a tracklist should
-- correct that row, not add a second one — without this, confidence in "played
-- together" degrades every time an import runs twice.
create unique index if not exists radio_appearances_unique_idx
    on public.radio_appearances(radio_show_id, recording_id, coalesce(offset_seconds, -1));

create index if not exists radio_shows_aired_at_idx on public.radio_shows(aired_at desc);
create index if not exists radio_shows_station_idx on public.radio_shows(station);
create index if not exists radio_appearances_recording_idx on public.radio_appearances(recording_id);
create index if not exists radio_appearances_show_idx on public.radio_appearances(radio_show_id);

-- ---------------------------------------------------------------------------
-- The DIG graph
-- ---------------------------------------------------------------------------

-- Deliberately polymorphic: the interesting edges cross entity kinds --
-- artist -> released_on -> label, recording -> played_in -> radio_show,
-- artist -> alias_of -> artist, recording -> frequently_near -> recording.
create table if not exists public.music_relationships (
    id uuid primary key default gen_random_uuid(),
    from_entity_type text not null,
    from_entity_id uuid not null,
    to_entity_type text not null,
    to_entity_id uuid not null,
    relationship_type text not null,
    confidence double precision,
    source text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- An edge is the pair plus its kind. Re-deriving the graph must sharpen
-- confidence on the existing edge rather than pile up copies of it.
create unique index if not exists music_relationships_edge_idx
    on public.music_relationships(
        from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type);

-- Traversal runs both ways: "what came off this label" and "what label is this
-- on" are the same edge read from opposite ends.
create index if not exists music_relationships_from_idx
    on public.music_relationships(from_entity_type, from_entity_id, relationship_type);
create index if not exists music_relationships_to_idx
    on public.music_relationships(to_entity_type, to_entity_id, relationship_type);
create index if not exists music_relationships_confidence_idx
    on public.music_relationships(relationship_type, confidence desc);

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'music_relationships_from_type_check') then
        alter table public.music_relationships add constraint music_relationships_from_type_check
            check (from_entity_type in ('artist', 'label', 'release', 'recording', 'radio_show'));
    end if;
    if not exists (select 1 from pg_constraint where conname = 'music_relationships_to_type_check') then
        alter table public.music_relationships add constraint music_relationships_to_type_check
            check (to_entity_type in ('artist', 'label', 'release', 'recording', 'radio_show'));
    end if;
    if not exists (select 1 from pg_constraint where conname = 'music_relationships_confidence_check') then
        alter table public.music_relationships add constraint music_relationships_confidence_check
            check (confidence is null or (confidence >= 0 and confidence <= 1));
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- updated_at, RLS
-- ---------------------------------------------------------------------------

do $$
declare
    t text;
    trigger_name text;
begin
    foreach t in array array['radio_shows', 'music_relationships'] loop
        trigger_name := t || '_touch_updated_at';
        execute format('drop trigger if exists %I on public.%I', trigger_name, t);
        execute format(
            'create trigger %I before update on public.%I
             for each row execute function public.touch_updated_at()', trigger_name, t);
    end loop;
end $$;

alter table public.radio_shows          enable row level security;
alter table public.radio_appearances    enable row level security;
alter table public.music_relationships  enable row level security;

do $$
declare
    t text;
    policy_name text;
begin
    foreach t in array array['radio_shows', 'radio_appearances', 'music_relationships'] loop
        policy_name := t || '_read';
        execute format('drop policy if exists %I on public.%I', policy_name, t);
        execute format(
            'create policy %I on public.%I for select to anon, authenticated using (true)',
            policy_name, t);
    end loop;
end $$;
