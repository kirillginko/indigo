-- The people playing the records.
--
-- `adopt_radio_artists` builds the artist table out of what programmes play, so
-- the one group of names it structurally cannot reach is the people doing the
-- playing. A selector is rarely in their own tracklist. Measured: twenty real
-- artist names typed into search, eighteen answered instantly out of 44,696
-- rows, and the two misses were Ben UFO and Jane Fitz -- both NTS residents,
-- both with hundreds of hours on the station, neither with a row.
--
-- NTS has no host field. It has a naming convention: "Pacing The Platform w/
-- upsammy", "Peking Spring w/ Jon K", "Ben Sims Presents: Run It Red". In a
-- sample of 120 programmes, 46 are the first form. `host_name` has been on
-- `radio_shows` since 0004 and is null on every one of the 333 rows, because
-- nothing ever wrote it.
--
-- Parsing stays in `nts.ts`, where the payload is and where the normalizer is.
-- What is here is the write it makes, and a way to go back for the programmes
-- described before it existed.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Adopting one name
-- ---------------------------------------------------------------------------

-- An artist by name, created if nobody has that name yet.
--
-- The generalisation of the loop body in `adopt_radio_artists`, and it shares
-- that function's identity deliberately: `provider = 'nts'` keyed on the
-- normalized name. A selector who also turns up in somebody else's tracklist is
-- then one artist carrying both, rather than two rows that never meet.
--
-- The key is the caller's, as it is in 0018 and 0025, because the app's
-- normalizer is the one every other lookup in Indigo agrees with.
create or replace function public.adopt_named_artist(
    p_name text,
    p_key text,
    p_source_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_name text := nullif(btrim(coalesce(p_name, '')), '');
    v_key text := nullif(btrim(coalesce(p_key, '')), '');
    v_artist uuid;
begin
    if v_name is null or v_key is null then return null; end if;

    -- Whoever already answers to this name, however they were filed. Adopting
    -- rather than inserting beside them is what keeps `resolve_radio_appearances`
    -- unambiguous: it only ever resolves a name that matches exactly one artist,
    -- so a second row for a presenter would quietly stop every tracklist line
    -- naming them from resolving at all.
    select id into v_artist
    from public.artists where normalized_name = v_key limit 1;
    if v_artist is not null then
        return v_artist;
    end if;

    select entity_id into v_artist
    from public.external_ids
    where provider = 'nts' and entity_type = 'artist' and external_id = v_key;
    if v_artist is not null then
        return v_artist;
    end if;

    insert into public.artists (name, normalized_name)
    values (v_name, v_key)
    returning id into v_artist;

    begin
        -- Written second and unique, so it decides who won a race rather than
        -- the artist row itself. Same bargain as `adopt_radio_artists`.
        insert into public.external_ids
            (entity_type, entity_id, provider, external_id, source_url)
        values ('artist', v_artist, 'nts', v_key, nullif(btrim(coalesce(p_source_url, '')), ''));
    exception when unique_violation then
        delete from public.artists where id = v_artist;
        select entity_id into v_artist
        from public.external_ids
        where provider = 'nts' and entity_type = 'artist' and external_id = v_key;
    end;

    -- A name adopted now collects every tracklist line that has been waiting
    -- for it. This is what makes a presenter's own page worth opening the
    -- moment they are created: a resident is played by other residents.
    if v_artist is not null then
        update public.radio_appearances
        set artist_id = v_artist,
            identification_source = coalesce(identification_source, 'radio_adopted')
        where artist_id is null and normalized_artist_name = v_key;
    end if;

    return v_artist;
end $$;

revoke all on function public.adopt_named_artist(text, text, text)
    from public, anon, authenticated;
grant execute on function public.adopt_named_artist(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Going back for the programmes already described
-- ---------------------------------------------------------------------------

-- `describeShow` runs once per programme, the first time one of its broadcasts
-- arrives, and every programme in the live project has already had its turn.
-- Re-reading one is a single request to NTS and the job type already exists, so
-- the backfill is a queue of `fetch_nts_show` rather than anything new.
create or replace function public.requeue_nts_shows(p_limit int default 20)
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
        select rs.external_id
        from public.radio_shows rs
        where rs.provider = 'nts'
          and rs.host_name is null
          -- Only the ones whose title says there is somebody to credit. A
          -- programme called "In Focus" would come back round for ever
          -- otherwise, and re-reading it would never produce a host.
          and (rs.title like '% w/ %' or rs.title ~* '^.+ presents(:| )')
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'nts'
                and j.job_type = 'fetch_nts_show'
                and j.dedupe_key = rs.external_id
                and j.status in ('pending', 'running')
          )
        order by rs.updated_at
        limit v_limit
    loop
        perform public.enqueue_enrichment_job(
            'nts',
            'fetch_nts_show',
            v_row.external_id,
            jsonb_build_object('alias', v_row.external_id),
            -- Below the live crawl. These programmes have been on air for
            -- years; they will keep.
            -1,
            null,
            null
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.requeue_nts_shows(int) from public, anon, authenticated;
grant execute on function public.requeue_nts_shows(int) to service_role;

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

create or replace function public.schedule_nts_hosts()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Ten every half hour against about 150 programmes whose titles name
    -- somebody: done inside a day, and a query that finds nothing after that.
    -- Each one also re-enqueues that residency's last dozen broadcasts, which
    -- is the same work the crawl does anyway and is why this is not faster.
    perform cron.schedule(
        'indigo-nts-hosts',
        '*/30 * * * *',
        $job$select public.requeue_nts_shows(10)$job$);

    return 'indigo-nts-hosts';
end $$;

-- Added to the umbrella, carrying 0025's composition forward unchanged.
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
    scheduled := array_append(scheduled, public.schedule_track_releases());
    scheduled := array_append(scheduled, public.schedule_nts_hosts());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_nts_hosts();
    end if;
end $$;
