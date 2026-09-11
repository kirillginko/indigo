-- Portraits, filled once for everybody instead of once per listener.
--
-- The app fills these itself: a background loop that walks the artists on a
-- listener's shelves and asks Discogs for a picture of each. It works, and it
-- is the single largest consumer of Indigo's Discogs budget — its own comment
-- puts it at forty requests a minute out of sixty. That budget is not per
-- listener. Every copy of the app carries the same credential and Discogs
-- meters per credential, so the fill on one machine is spending the same sixty
-- that a search on another is trying to use, and adding listeners makes it
-- worse for all of them.
--
-- Done here it happens once. A portrait found for Purelink today is a portrait
-- every listener has tomorrow, the work is bounded by how many artists exist
-- rather than by how many people are running the app, and the whole of the
-- client's budget is left for things somebody is waiting on.
--
-- Safe to re-run.

-- MARK: - Asking for the ones worth asking about

-- How long before an artist nobody could find a picture of is asked about
-- again. A name Discogs has no image for today it very likely will not next
-- week, and recording the attempt is what stops it being paid for twice.
create or replace function public.artist_portrait_lifetime()
returns interval language sql immutable as $$ select interval '90 days' $$;

-- Queues portrait lookups, most-played first.
--
-- Same rule as `enqueue_artist_origins`, and for the same reason: radio decides
-- who is worth asking about. The rest of the artist table is everybody who ever
-- appeared on a tracklist, and fetching a picture of all of them would spend
-- the budget this migration exists to protect.
create or replace function public.enqueue_artist_portraits(p_limit int default 20)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 20), 200));
begin
    for v_row in
        select a.id, a.name, count(*) as plays
        from public.artists a
        left join public.artwork w
            on w.entity_type = 'artist' and w.entity_id = a.id
        join public.recordings r on r.artist_id = a.id
        join public.radio_appearances ap on ap.recording_id = r.id
        where coalesce(btrim(a.name), '') <> ''
          -- Never looked, or looked long enough ago that it is worth another
          -- try. A row with a null `original_url` is a recorded miss, not an
          -- absence: see `record_artist_portrait`.
          and (
              w.id is null
              or (w.original_url is null
                  and w.fetched_at < now() - public.artist_portrait_lifetime())
          )
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'discogs'
                and j.job_type = 'fetch_artist_portrait'
                and j.dedupe_key = a.id::text
                and j.status in ('pending', 'running')
          )
        group by a.id, a.name, w.id
        order by count(*) desc, a.name
        limit v_limit
    loop
        perform public.enqueue_enrichment_job(
            'discogs',
            'fetch_artist_portrait',
            v_row.id::text,
            jsonb_build_object('artist_id', v_row.id, 'name', v_row.name),
            -- Below the live radio crawl and below origins. Nobody is waiting
            -- on a picture; that is the entire premise of moving it here.
            -2,
            'artist',
            v_row.id
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.enqueue_artist_portraits(int) from public;
grant execute on function public.enqueue_artist_portraits(int) to service_role;

-- MARK: - Writing down what was found, including nothing

-- Records the outcome of one lookup.
--
-- A null url is a *finding* rather than a failure: it says this artist was
-- looked for on this date and Discogs had no picture. Written down, the queue
-- stops asking for ninety days. Not written down, the same name comes back
-- round on every pass forever, which is the behaviour this replaces.
create or replace function public.record_artist_portrait(
    p_artist_id uuid,
    p_url text default null,
    p_width int default null,
    p_height int default null
)
returns void
language sql
security definer
set search_path = public
as $$
    insert into public.artwork (
        entity_type, entity_id, provider, original_url, width, height, fetched_at
    )
    values (
        'artist', p_artist_id, 'discogs',
        nullif(btrim(coalesce(p_url, '')), ''), p_width, p_height, now()
    )
    on conflict (entity_type, entity_id) do update
        set provider = excluded.provider,
            original_url = excluded.original_url,
            width = excluded.width,
            height = excluded.height,
            fetched_at = excluded.fetched_at;
$$;

revoke all on function public.record_artist_portrait(uuid, text, int, int) from public;
grant execute on function public.record_artist_portrait(uuid, text, int, int) to service_role;

-- MARK: - Reading them back

-- Portraits for a set of names, in one request.
--
-- The app knows artists by name — its portrait table is keyed on a normalized
-- one, because most of the artists on a DIG page have no catalogue row at all.
-- Asking per name would be one round trip each for a page of forty
-- neighbours, which is the shape of the problem the client-side fill already
-- has. So this takes the whole set, exactly as `dig_radio_for_artists` does.
--
-- Names with no portrait are simply absent from the answer, which the caller
-- reads as "ask Discogs yourself if you like".
create or replace function public.portraits_for_artists(p_names text[])
returns jsonb
language sql
stable
as $$
    select coalesce(
        jsonb_object_agg(found.normalized_name, found.original_url),
        '{}'::jsonb
    )
    from (
        select distinct on (a.normalized_name)
            a.normalized_name,
            w.original_url
        from public.artists a
        join public.artwork w
            on w.entity_type = 'artist' and w.entity_id = a.id
        where a.normalized_name = any(p_names)
          and w.original_url is not null
        order by a.normalized_name, w.fetched_at desc nulls last
    ) as found;
$$;

grant execute on function public.portraits_for_artists(text[]) to anon, authenticated;

-- MARK: - Scheduling

create or replace function public.schedule_artist_portraits()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Twenty every ten minutes is a hundred and twenty an hour against a
    -- budget of sixty a minute, which leaves the credential almost entirely
    -- free. There is no hurry: nobody is waiting, and the backlog only has to
    -- be walked once for everybody rather than once per listener.
    perform cron.schedule(
        'indigo-artist-portraits',
        '*/10 * * * *',
        $job$select public.enqueue_artist_portraits(20)$job$);

    return 'indigo-artist-portraits';
end $$;

-- Added to the umbrella so a project scheduled before this migration existed
-- picks it up on the next run, rather than needing the job added by hand.
create or replace function public.schedule_scene_rosters()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;

    perform cron.schedule(
        'indigo-resume-scenes',
        '*/10 * * * *',
        $job$select public.resume_scene_rosters(4)$job$);
    scheduled := array_append(scheduled, 'indigo-resume-scenes');

    perform cron.schedule(
        'indigo-seed-scenes',
        '41 3 * * *',
        $job$select public.seed_scene_rosters()$job$);
    scheduled := array_append(scheduled, 'indigo-seed-scenes');

    scheduled := array_append(scheduled, public.schedule_nts_retag());
    scheduled := array_append(scheduled, public.schedule_scene_radio_fill());
    scheduled := array_append(scheduled, public.schedule_artist_origins());
    scheduled := array_append(scheduled, public.schedule_artist_portraits());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;
