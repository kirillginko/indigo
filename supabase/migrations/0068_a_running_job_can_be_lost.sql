-- Three faults that kept work from ever finishing, found 2026-09-30.
--
-- 1. Asking for a job again kept a dead one alive.
--
--    `enqueue_enrichment_job` answers a repeat request by raising the waiting
--    job's priority. It ran that update whether or not the priority changed,
--    and `enrichment_jobs_touch_updated_at` stamps every update -- so each
--    repeat request moved `updated_at` to now. `updated_at` is also what
--    `reclaim_expired_enrichment_jobs` reads to decide a worker has died: a
--    claim is given back after fifteen minutes of silence.
--
--    Anything a schedule asks for more often than that was therefore never
--    given back. A worker died holding the NTS backfill on 11 September, four
--    scene rosters the same day and the Lot Radio backfill on the 24th; their
--    crons asked again every five or ten minutes, and all six sat `running`
--    with nobody running them until this was written.
--
--    Now only a job still waiting is touched, and only when the priority
--    actually rises.
--
-- 2. A page of a scene with two artists of one name could not be recorded.
--
--    `record_scene_members` upserts a page in one statement, keyed on the
--    normalized name. MusicBrainz's first page for "modern classical" has two
--    John Williamses and for "psychedelic rock" two Alice Coopers, and one
--    statement may not touch a row twice -- so that page failed every time
--    and the roster never got past it. The better-scored of a name is kept.
--
-- 3. The same four rosters were resumed for ever.
--
--    `resume_scene_rosters` took the four oldest unfinished rosters. When
--    those four could not finish (1 and 2), the 86 behind them were never
--    reached. It now takes the ones longest left alone and marks each as it
--    goes, so a roster that fails goes to the back of the line.
--
-- And the queued `rebuild_dig_edges` jobs are cleared: the worker no longer
-- queues them (the API's eight-second limit cancelled every one), and
-- `indigo-rebuild-edges` does the rebuild on its own schedule.

-- MARK: - 1

create or replace function public.enqueue_enrichment_job(
    p_provider text,
    p_job_type text,
    p_dedupe_key text,
    p_payload jsonb default null,
    p_priority integer default 0,
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

        -- Somebody asking again is evidence it matters. Only for a job still
        -- waiting, and only when it changes something: any update stamps
        -- `updated_at`, which is the claim's lease. See the note above.
        update public.enrichment_jobs
        set priority = coalesce(p_priority, 0)
        where id = job_id
          and status = 'pending'
          and priority < coalesce(p_priority, 0);
    end if;

    return job_id;
end $$;

-- MARK: - 2

create or replace function public.record_scene_members(
    p_roster_id uuid,
    p_members jsonb,
    p_next_offset integer,
    p_total integer,
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
    -- One of each name a page: the roster is keyed on it, and a statement
    -- may not write the same row twice.
    select distinct on (m ->> 'normalized_name')
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
    order by m ->> 'normalized_name', coalesce((m ->> 'score')::int, 0) desc
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

-- MARK: - 3

create or replace function public.resume_scene_rosters(p_limit integer default 4)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_roster public.scene_rosters%rowtype;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 4), 20));
begin
    for v_roster in
        select *
        from public.scene_rosters
        where
            status in ('pending', 'filling')
            or (status = 'ready'
                and filled_at is not null
                and filled_at < now() - public.scene_roster_lifetime())
            or (status = 'failed' and updated_at < now() - interval '6 hours')
        -- Longest left alone first, and stamped below, so the ones asked
        -- for last time are at the back of the line this time.
        order by updated_at
        limit v_limit
    loop
        perform public.enqueue_enrichment_job(
            'musicbrainz',
            'fetch_scene_roster',
            v_roster.place_key || '|' || v_roster.sound_key,
            jsonb_build_object(
                'roster_id', v_roster.id,
                'place', v_roster.place,
                'sound', v_roster.sound
            ),
            0,
            null,
            null
        );
        update public.scene_rosters set updated_at = now() where id = v_roster.id;
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

-- MARK: - Cleared

delete from public.enrichment_jobs
where provider = 'indigo' and job_type = 'rebuild_dig_edges' and status = 'pending';
