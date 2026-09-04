-- Enrichment queue (4F), radio-derived DIG edges (4G), and label radio (§10).
--
-- 0004 gave radio somewhere to live and nothing to connect to. Every appearance
-- it ingested landed with a null artist_id, because resolution only matched
-- against `artists`, and `artists` only gains rows as a side effect of
-- normalizing a Discogs release. Measured on the live database: 33 artists, all
-- from Discogs, against 17 distinct radio names — zero overlap. The graph could
-- not populate, so nothing radio-derived could ever appear on a page.
--
-- The change of position here is that an artist known only from radio is a real
-- artist. That is the whole premise of the app: the music worth digging for is
-- exactly the music no catalogue has filed. So a tracklist name that matches
-- nothing becomes an entity, with its provenance recorded, rather than being
-- discarded for failing to be in Discogs.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Edges gain their evidence
-- ---------------------------------------------------------------------------

-- A score with nothing behind it is the thing this app exists not to do. An
-- edge has to be able to say "nine independent episodes", or it should not be
-- on screen.
alter table public.music_relationships
    add column if not exists evidence_count int not null default 1,
    add column if not exists metadata jsonb;

create index if not exists music_relationships_evidence_idx
    on public.music_relationships(relationship_type, evidence_count desc);

-- ---------------------------------------------------------------------------
-- Artists adopted from radio
-- ---------------------------------------------------------------------------

-- Creates an artist for a tracklist name that matches nothing, and points the
-- appearances at it.
--
-- Only ever for names that match *nothing*. A name matching two existing
-- artists is genuine ambiguity — two different people who share a name — and
-- inventing a third would bury the problem rather than leave it visible.
--
-- Placeholder names never reach here: `normalized_artist_name` is left null for
-- them at ingest, so "Unknown", "ID" and "Unreleased" cannot become artists.
create or replace function public.adopt_radio_artists(p_episode_id uuid default null)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    candidate record;
    artist_uuid uuid;
    created int := 0;
begin
    for candidate in
        select ra.normalized_artist_name as key,
               -- The spelling the stations use most often is the one to show.
               (array_agg(ra.raw_artist_name order by ra.created_at))[1] as display
        from public.radio_appearances ra
        where ra.artist_id is null
          and coalesce(ra.normalized_artist_name, '') <> ''
          and (p_episode_id is null or ra.radio_episode_id = p_episode_id)
          and not exists (
              select 1 from public.artists a
              where a.normalized_name = ra.normalized_artist_name)
        group by ra.normalized_artist_name
    loop
        select entity_id into artist_uuid
        from public.external_ids
        where provider = 'nts' and entity_type = 'artist' and external_id = candidate.key;

        if artist_uuid is null then
            insert into public.artists (name, normalized_name)
            values (candidate.display, candidate.key)
            returning id into artist_uuid;

            begin
                -- Written second and unique, so it is the thing that decides
                -- who won a race rather than the artist row itself.
                insert into public.external_ids (entity_type, entity_id, provider, external_id, source_url)
                values ('artist', artist_uuid, 'nts', candidate.key, null);
                created := created + 1;
            exception when unique_violation then
                delete from public.artists where id = artist_uuid;
                select entity_id into artist_uuid
                from public.external_ids
                where provider = 'nts' and entity_type = 'artist' and external_id = candidate.key;
            end;
        end if;

        -- Deliberately not limited to the episode being ingested: a name
        -- adopted now should collect every appearance that has been waiting
        -- for it, which is what makes this pass worth re-running.
        if artist_uuid is not null then
            update public.radio_appearances
            set artist_id = artist_uuid,
                identification_source = coalesce(identification_source, 'radio_adopted')
            where artist_id is null
              and normalized_artist_name = candidate.key;
        end if;
    end loop;

    return created;
end $$;

revoke all on function public.adopt_radio_artists(uuid) from public;
grant execute on function public.adopt_radio_artists(uuid) to service_role;

-- Resolution now has three stages: match what exists, adopt what does not, then
-- reach for a recording. Replaces the two-stage version from 0004.
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

    -- Whatever is left named somebody nobody has catalogued.
    perform public.adopt_radio_artists(p_episode_id);

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

revoke all on function public.resolve_radio_appearances(uuid) from public;
grant execute on function public.resolve_radio_appearances(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 4F — the enrichment queue
-- ---------------------------------------------------------------------------

-- Slow upstream work, moved off the path of a screen that is trying to draw.
-- The app asks for an episode and gets an answer; filling in everything behind
-- it happens here, in its own time, and can be retried without anybody waiting.
create table if not exists public.enrichment_jobs (
    id uuid primary key default gen_random_uuid(),

    entity_type text,
    entity_id uuid,

    provider text not null,
    job_type text not null,

    -- What the job is about, in one string: an NTS "show/episode", an artist
    -- uuid. Only used to keep the queue from holding the same work twice.
    dedupe_key text,

    priority int not null default 0,
    status text not null default 'pending',

    attempts int not null default 0,
    max_attempts int not null default 5,
    next_attempt_at timestamptz not null default now(),
    last_error text,

    payload jsonb,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'enrichment_jobs_status_check') then
        alter table public.enrichment_jobs add constraint enrichment_jobs_status_check
            check (status in ('pending', 'running', 'done', 'failed'));
    end if;
end $$;

-- The same episode queued by five people at once is one job. Only live rows
-- are constrained, so the work can legitimately be requested again later.
create unique index if not exists enrichment_jobs_dedupe_idx
    on public.enrichment_jobs(provider, job_type, dedupe_key)
    where status in ('pending', 'running');

-- Exactly the shape the claim below reads.
create index if not exists enrichment_jobs_ready_idx
    on public.enrichment_jobs(priority desc, created_at)
    where status = 'pending';

drop trigger if exists enrichment_jobs_touch_updated_at on public.enrichment_jobs;
create trigger enrichment_jobs_touch_updated_at before update on public.enrichment_jobs
    for each row execute function public.touch_updated_at();

alter table public.enrichment_jobs enable row level security;
-- No policy at all: the queue is the backend's business. The app enqueues
-- through a function and never reads the table.

-- Adds work, or leaves it alone if the same work is already waiting.
create or replace function public.enqueue_enrichment_job(
    p_provider text,
    p_job_type text,
    p_dedupe_key text,
    p_payload jsonb default null,
    p_priority int default 0,
    p_entity_type text default null,
    p_entity_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    job_id uuid;
begin
    insert into public.enrichment_jobs
        (provider, job_type, dedupe_key, payload, priority, entity_type, entity_id)
    values
        (p_provider, p_job_type, p_dedupe_key, p_payload,
         coalesce(p_priority, 0), p_entity_type, p_entity_id)
    on conflict do nothing
    returning id into job_id;

    if job_id is null then
        select id into job_id
        from public.enrichment_jobs
        where provider = p_provider and job_type = p_job_type
          and dedupe_key is not distinct from p_dedupe_key
          and status in ('pending', 'running')
        limit 1;

        -- Somebody asking again is evidence it matters.
        update public.enrichment_jobs
        set priority = greatest(priority, coalesce(p_priority, 0))
        where id = job_id;
    end if;

    return job_id;
end $$;

-- Takes the next batch of work and marks it running, in one statement.
--
-- `skip locked` is what makes more than one worker safe: a row another worker
-- is already holding is stepped over rather than waited for, so two workers
-- never take the same job and neither blocks.
create or replace function public.claim_enrichment_jobs(p_limit int default 5)
returns setof public.enrichment_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    return query
    update public.enrichment_jobs j
    set status = 'running',
        attempts = j.attempts + 1,
        updated_at = now()
    where j.id in (
        select candidate.id
        from public.enrichment_jobs candidate
        where candidate.status = 'pending'
          and candidate.next_attempt_at <= now()
        order by candidate.priority desc, candidate.created_at
        for update skip locked
        limit greatest(1, least(coalesce(p_limit, 5), 50))
    )
    returning j.*;
end $$;

-- Finishes a job, or puts it back with a longer fuse.
--
-- A job that has burned its attempts is marked failed rather than retried for
-- ever: an NTS episode that 404s is not going to start existing.
create or replace function public.complete_enrichment_job(
    p_job_id uuid,
    p_succeeded boolean,
    p_error text default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
    update public.enrichment_jobs
    set status = case
            when p_succeeded then 'done'
            when attempts >= max_attempts then 'failed'
            else 'pending'
        end,
        last_error = case when p_succeeded then null else left(coalesce(p_error, ''), 500) end,
        next_attempt_at = case
            when p_succeeded then next_attempt_at
            -- 1, 2, 4, 8 … minutes, capped at an hour.
            else now() + (least(60, power(2, least(attempts, 6))::int) || ' minutes')::interval
        end
    where id = p_job_id;
$$;

revoke all on function public.enqueue_enrichment_job(text, text, text, jsonb, int, text, uuid) from public;
revoke all on function public.claim_enrichment_jobs(int) from public;
revoke all on function public.complete_enrichment_job(uuid, boolean, text) from public;
grant execute on function public.enqueue_enrichment_job(text, text, text, jsonb, int, text, uuid) to service_role;
grant execute on function public.claim_enrichment_jobs(int) to service_role;
grant execute on function public.complete_enrichment_job(uuid, boolean, text) to service_role;

-- ---------------------------------------------------------------------------
-- 4G — radio-derived DIG edges
-- ---------------------------------------------------------------------------

-- Rebuilt from the appearances rather than accumulated as they arrive, so the
-- graph is a function of the evidence and re-running can only ever make it
-- agree with the data. Every edge carries the count it was derived from.
create or replace function public.rebuild_radio_dig_edges()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    written int := 0;
    touched int;
begin
    -- Artist -> the programmes that play them.
    insert into public.music_relationships (
        from_entity_type, from_entity_id, to_entity_type, to_entity_id,
        relationship_type, confidence, source, evidence_count, metadata)
    select
        'artist', played.artist_id, 'radio_show', played.radio_show_id,
        'played_by',
        least(0.95, 0.5 + 0.45 * (1 - 1.0 / (1 + played.episodes))),
        'radio',
        played.appearances,
        jsonb_build_object('episodes', played.episodes, 'appearances', played.appearances)
    from (
        select ra.artist_id,
               re.radio_show_id,
               count(*) as appearances,
               count(distinct re.id) as episodes
        from public.radio_appearances ra
        join public.radio_episodes re on re.id = ra.radio_episode_id
        where ra.artist_id is not null and re.radio_show_id is not null
        group by ra.artist_id, re.radio_show_id
    ) as played
    on conflict (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type)
    do update set
        confidence = excluded.confidence,
        evidence_count = excluded.evidence_count,
        metadata = excluded.metadata,
        updated_at = now();

    get diagnostics touched = row_count;
    written := written + touched;

    -- Artist <-> artist, played next to each other in a tracklist.
    --
    -- Stored once under the lower uuid rather than in both directions: the
    -- relationship is symmetric, and two rows saying the same thing would each
    -- have to be kept in step. Readers already have an index on either end.
    insert into public.music_relationships (
        from_entity_type, from_entity_id, to_entity_type, to_entity_id,
        relationship_type, confidence, source, evidence_count, metadata)
    select
        'artist', near.low, 'artist', near.high,
        'radio_neighbor',
        least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + near.adjacencies))),
        'radio',
        near.adjacencies,
        jsonb_build_object('adjacencies', near.adjacencies, 'episodes', near.episodes)
    from (
        select
            least(a.artist_id, b.artist_id) as low,
            greatest(a.artist_id, b.artist_id) as high,
            count(*) as adjacencies,
            count(distinct a.radio_episode_id) as episodes
        from public.radio_appearances a
        join public.radio_appearances b
            on b.radio_episode_id = a.radio_episode_id
           and b.track_index = a.track_index + 1
        where a.artist_id is not null
          and b.artist_id is not null
          and a.artist_id <> b.artist_id
        group by least(a.artist_id, b.artist_id), greatest(a.artist_id, b.artist_id)
    ) as near
    on conflict (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type)
    do update set
        confidence = excluded.confidence,
        evidence_count = excluded.evidence_count,
        metadata = excluded.metadata,
        updated_at = now();

    get diagnostics touched = row_count;
    written := written + touched;

    -- Label -> the programmes that play its artists.
    --
    -- Through the artist, not through the recording. The recording-level path
    -- is the one §10 describes and it is the better claim, but it needs
    -- appearances matched to recordings, and almost none are yet. This says
    -- "this show plays artists who release on this label", which is true, and
    -- is marked as such so a stronger derivation can replace it later.
    insert into public.music_relationships (
        from_entity_type, from_entity_id, to_entity_type, to_entity_id,
        relationship_type, confidence, source, evidence_count, metadata)
    select
        'label', played.label_id, 'radio_show', played.radio_show_id,
        'played_by',
        least(0.85, 0.35 + 0.45 * (1 - 1.0 / (1 + played.episodes))),
        'radio.via_artist',
        played.appearances,
        jsonb_build_object(
            'episodes', played.episodes,
            'appearances', played.appearances,
            'artists', played.artists,
            'derivation', 'artist_roster')
    from (
        select roster.label_id,
               re.radio_show_id,
               count(*) as appearances,
               count(distinct re.id) as episodes,
               count(distinct ra.artist_id) as artists
        from public.radio_appearances ra
        join public.radio_episodes re on re.id = ra.radio_episode_id
        -- Distinct, and that is load-bearing. Joining `releases` directly
        -- multiplies every appearance by the number of records the artist has
        -- on the label, so one play by an artist with twelve releases would be
        -- counted as twelve plays.
        join (
            select distinct artist_id, label_id
            from public.releases
            where artist_id is not null and label_id is not null
        ) as roster on roster.artist_id = ra.artist_id
        where ra.artist_id is not null
          and re.radio_show_id is not null
        group by roster.label_id, re.radio_show_id
    ) as played
    on conflict (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type)
    do update set
        confidence = excluded.confidence,
        evidence_count = excluded.evidence_count,
        metadata = excluded.metadata,
        updated_at = now();

    get diagnostics touched = row_count;
    return written + touched;
end $$;

revoke all on function public.rebuild_radio_dig_edges() from public;
grant execute on function public.rebuild_radio_dig_edges() to service_role;

-- ---------------------------------------------------------------------------
-- Reading the graph
-- ---------------------------------------------------------------------------

-- Everything radio has to say about an artist that is not simply a list of
-- broadcasts: the programmes that play them, and the artists they get played
-- beside. An edge is only worth rendering with its evidence attached, so the
-- count comes back with it.
create or replace function public.artist_radio_relations(
    p_artist_id uuid,
    p_limit int default 24
)
returns table (
    relationship_type text,
    entity_type text,
    entity_id uuid,
    title text,
    station text,
    provider text,
    external_id text,
    evidence_count int,
    confidence double precision,
    metadata jsonb
)
language sql
stable
as $$
with edge as (
    select mr.relationship_type, mr.to_entity_type as kind, mr.to_entity_id as other,
           mr.evidence_count, mr.confidence, mr.metadata
    from public.music_relationships mr
    where mr.from_entity_type = 'artist' and mr.from_entity_id = p_artist_id
      and mr.source like 'radio%'
    union all
    select mr.relationship_type, mr.from_entity_type, mr.from_entity_id,
           mr.evidence_count, mr.confidence, mr.metadata
    from public.music_relationships mr
    where mr.to_entity_type = 'artist' and mr.to_entity_id = p_artist_id
      and mr.source like 'radio%'
)
select
    edge.relationship_type,
    edge.kind,
    edge.other,
    coalesce(rs.title, a.name),
    rs.station,
    rs.provider,
    rs.external_id,
    edge.evidence_count,
    edge.confidence,
    edge.metadata
from edge
left join public.radio_shows rs on edge.kind = 'radio_show' and rs.id = edge.other
left join public.artists a on edge.kind = 'artist' and a.id = edge.other
order by edge.evidence_count desc, edge.confidence desc
limit greatest(1, least(coalesce(p_limit, 24), 200));
$$;

-- §10. What radio knows about a label.
--
-- Reached through the label's artists rather than its records, for the reason
-- given in rebuild_radio_dig_edges: recording-level matches barely exist yet.
-- `derivation` says so on the way out, so a page can be honest about what it
-- is claiming.
create or replace function public.label_radio_summary(p_label_id uuid)
returns jsonb
language sql
stable
as $$
with appearance as (
    select ra.id, ra.artist_id, ra.radio_episode_id, re.radio_show_id, re.aired_at
    from public.radio_appearances ra
    join public.radio_episodes re on re.id = ra.radio_episode_id
    where ra.artist_id in (
        select distinct rel.artist_id
        from public.releases rel
        where rel.label_id = p_label_id and rel.artist_id is not null)
),
top_show as (
    select rs.id, rs.provider, rs.external_id, rs.title, rs.station,
           count(*) as appearance_count
    from appearance a
    join public.radio_shows rs on rs.id = a.radio_show_id
    group by rs.id, rs.provider, rs.external_id, rs.title, rs.station
    order by count(*) desc, rs.title
    limit 8
),
top_artist as (
    select ar.id, ar.name, count(*) as appearance_count
    from appearance a
    join public.artists ar on ar.id = a.artist_id
    group by ar.id, ar.name
    order by count(*) desc, ar.name
    limit 8
)
select jsonb_build_object(
    'label_id', p_label_id,
    'derivation', 'artist_roster',
    'appearance_count', (select count(*) from appearance),
    'episode_count', (select count(distinct radio_episode_id) from appearance),
    'show_count', (select count(distinct radio_show_id) from appearance),
    'artist_count', (select count(distinct artist_id) from appearance),
    'first_appearance_at', (select min(aired_at) from appearance),
    'latest_appearance_at', (select max(aired_at) from appearance),
    'top_shows', coalesce((
        select jsonb_agg(jsonb_build_object(
            'show_id', id, 'provider', provider, 'external_id', external_id,
            'title', title, 'station', station, 'appearance_count', appearance_count))
        from top_show), '[]'::jsonb),
    'top_artists', coalesce((
        select jsonb_agg(jsonb_build_object(
            'artist_id', id, 'name', name, 'appearance_count', appearance_count))
        from top_artist), '[]'::jsonb)
);
$$;

grant execute on function public.artist_radio_relations(uuid, int) to anon, authenticated;
grant execute on function public.label_radio_summary(uuid) to anon, authenticated;
