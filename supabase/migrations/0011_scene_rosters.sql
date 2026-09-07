-- Who is actually in a scene.
--
-- A scene page could only ever list artists the listener's own catalogue had
-- already met: eight names under "New York / Jazz", which is not a story about
-- a scene, it is a story about one record collection. The names that would
-- make it a scene are in MusicBrainz — an artist there carries an area and a
-- set of tags, which is exactly the two halves of a scene's address.
--
-- Fetched here rather than from the app, and that is the whole point of the
-- table. MusicBrainz asks for one request a second from a named client; a
-- phone opening a scene page cannot honour that on its own, and fifty copies
-- of the app cannot honour it at all. One crawler that paces itself fills this
-- in, and every copy of the app reads the answer.
--
-- Safe to re-run.

-- MARK: - Rosters

create table if not exists public.scene_rosters (
    id uuid primary key default gen_random_uuid(),

    -- The scene's address, as the app spells it. `place_key` and `sound_key`
    -- are the normalized forms the client already compares on, so a roster is
    -- found by the same words that named it.
    place text not null,
    place_key text not null,
    sound text,
    sound_key text not null default '',

    -- Where the names came from, so a roster assembled by hand later is
    -- distinguishable from one a crawler built.
    source text not null default 'musicbrainz',

    -- How far through the upstream listing the crawl has walked. MusicBrainz
    -- pages a hundred at a time and a scene can run to several hundred names.
    next_offset int not null default 0,
    total_available int,

    member_count int not null default 0,
    status text not null default 'pending',
    last_error text,

    -- When the roster was last completed, which is what decides whether it is
    -- worth walking again. Null until the first pass finishes.
    filled_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'scene_rosters_status_check') then
        alter table public.scene_rosters add constraint scene_rosters_status_check
            check (status in ('pending', 'filling', 'ready', 'failed'));
    end if;
end $$;

-- One roster per scene. A place and a sound is the address; the empty sound is
-- a place with nothing to distinguish it, which is a scene in the older sense.
create unique index if not exists scene_rosters_address_idx
    on public.scene_rosters(place_key, sound_key);

drop trigger if exists scene_rosters_touch_updated_at on public.scene_rosters;
create trigger scene_rosters_touch_updated_at before update on public.scene_rosters
    for each row execute function public.touch_updated_at();

-- MARK: - Members

create table if not exists public.scene_members (
    id uuid primary key default gen_random_uuid(),
    roster_id uuid not null references public.scene_rosters(id) on delete cascade,

    name text not null,
    normalized_name text not null,
    -- MusicBrainz's own id, which is the one identifier worth treating as
    -- stable — and what lets a name found here be joined to an artist the app
    -- already knows.
    mbid text,

    -- What the upstream entry said, kept so a page can show a scene in time
    -- and place rather than as a list of names.
    area text,
    began_year int,
    ended_year int,
    disambiguation text,

    -- How well the upstream search believed this artist answers the query.
    -- Kept so a roster can be shown best-first rather than alphabetically.
    score int not null default 0,

    created_at timestamptz not null default now()
);

create unique index if not exists scene_members_unique_idx
    on public.scene_members(roster_id, normalized_name);

create index if not exists scene_members_roster_idx
    on public.scene_members(roster_id, score desc);

-- MARK: - Reading

alter table public.scene_rosters enable row level security;
alter table public.scene_members enable row level security;

do $$
declare
    t text;
    policy_name text;
begin
    foreach t in array array['scene_rosters', 'scene_members'] loop
        policy_name := t || '_read';
        execute format('drop policy if exists %I on public.%I', policy_name, t);
        execute format(
            'create policy %I on public.%I for select to anon, authenticated using (true)',
            policy_name, t);
    end loop;
end $$;

-- MARK: - Asking for one

-- How long a filled roster stands before it is worth walking again. A scene
-- does not change quickly, and the reason this table exists is to keep the
-- crawler polite.
create or replace function public.scene_roster_lifetime()
returns interval
language sql
immutable
as $$ select interval '30 days' $$;

-- Asks for a scene to be filled in, and hands back what is already known.
--
-- Granted to the app, unlike `enqueue_enrichment_job`, and the difference is
-- deliberate. The queue is the backend's business and a caller must not be
-- able to name an arbitrary fetch; this names a scene, which is two words that
-- go into one upstream query. What it will not do is queue the same scene
-- twice, or re-walk one that was filled recently — so pressing a page
-- repeatedly costs one row and no upstream requests at all.
--
-- The keys are passed in rather than derived. There is no normalizer in SQL:
-- the app and the worker each carry one and `NormalizationParityTests` keeps
-- them in step, so a third here would be a third thing to drift.
create or replace function public.request_scene_roster(
    p_place text,
    p_place_key text,
    p_sound text default null,
    p_sound_key text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_place_key text := trim(coalesce(p_place_key, ''));
    v_sound_key text := trim(coalesce(p_sound_key, ''));
    v_roster public.scene_rosters%rowtype;
begin
    if v_place_key = '' then
        return jsonb_build_object('status', 'invalid');
    end if;

    select * into v_roster
    from public.scene_rosters
    where place_key = v_place_key and sound_key = v_sound_key;

    if not found then
        insert into public.scene_rosters (place, place_key, sound, sound_key)
        values (p_place, v_place_key, nullif(p_sound, ''), v_sound_key)
        on conflict (place_key, sound_key) do update set updated_at = now()
        returning * into v_roster;
    end if;

    -- Walked again only when what is there has gone stale. Everything else
    -- reads what is already in the table.
    if v_roster.status in ('pending', 'failed')
       or v_roster.filled_at is null
       or v_roster.filled_at < now() - public.scene_roster_lifetime() then
        perform public.enqueue_enrichment_job(
            'musicbrainz',
            'fetch_scene_roster',
            v_place_key || '|' || v_sound_key,
            jsonb_build_object(
                'roster_id', v_roster.id,
                'place', v_roster.place,
                'sound', v_roster.sound
            ),
            0,
            null,
            null
        );
    end if;

    return jsonb_build_object(
        'roster_id', v_roster.id,
        'status', v_roster.status,
        'member_count', v_roster.member_count
    );
end $$;

revoke all on function public.request_scene_roster(text, text, text, text) from public;
grant execute on function public.request_scene_roster(text, text, text, text)
    to anon, authenticated, service_role;

-- MARK: - Writing one

-- Records a page of the upstream listing. Called only by the worker.
create or replace function public.record_scene_members(
    p_roster_id uuid,
    p_members jsonb,
    p_next_offset int,
    p_total int,
    p_finished boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.scene_members (
        roster_id, name, normalized_name, mbid, area, began_year, ended_year,
        disambiguation, score
    )
    select
        p_roster_id,
        m ->> 'name',
        m ->> 'normalized_name',
        nullif(m ->> 'mbid', ''),
        nullif(m ->> 'area', ''),
        nullif(m ->> 'began', '')::int,
        nullif(m ->> 'ended', '')::int,
        nullif(m ->> 'disambiguation', ''),
        coalesce((m ->> 'score')::int, 0)
    from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) as m
    -- The worker normalizes, for the same reason the app does: one
    -- implementation of that per language and no more.
    where coalesce(m ->> 'normalized_name', '') <> ''
    on conflict (roster_id, normalized_name) do update
        set score = greatest(public.scene_members.score, excluded.score),
            mbid = coalesce(public.scene_members.mbid, excluded.mbid),
            area = coalesce(public.scene_members.area, excluded.area);

    update public.scene_rosters
    set next_offset = p_next_offset,
        total_available = coalesce(p_total, total_available),
        member_count = (
            select count(*) from public.scene_members where roster_id = p_roster_id
        ),
        status = case when p_finished then 'ready' else 'filling' end,
        filled_at = case when p_finished then now() else filled_at end,
        last_error = null
    where id = p_roster_id;
end $$;

revoke all on function public.record_scene_members(uuid, jsonb, int, int, boolean) from public;
grant execute on function public.record_scene_members(uuid, jsonb, int, int, boolean) to service_role;
