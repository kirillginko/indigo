-- Name an artist after themselves, not after the line they turned up on.
--
-- 0029 taught the ingest to resolve a tracklist line to its primary credit, so
-- "Rrawun Maymuru, Nick Wales" now files its appearance under `rrawun maymuru`
-- rather than inventing an artist out of the whole string. The identity is
-- right. The label is not: `adopt_radio_artists` takes the name it shows from
-- `raw_artist_name`, which is still the whole line, so the artist created is
--
--     name: "Rrawun Maymuru, Nick Wales"   normalized_name: "rrawun maymuru"
--
-- One artist, correctly identified, wearing two people's names. It is what a
-- search result shows and what a page is titled.
--
-- The primary's own spelling is already on the row — `credited_artist_names[1]`,
-- kept by 0029 for exactly this kind of use — so nothing has to be re-read or
-- re-split to fix it.
--
-- Measured at 24 artists, against 41 still carrying the whole credit as their
-- identity from before 0029. Both grow with every episode the crawl re-reads,
-- which is why this is worth doing now rather than with the cleanup.
--
-- Safe to re-run.

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
               -- The primary credit's own spelling where the line named
               -- several people, and the line itself where it named one. The
               -- spelling the stations use most often is still the one to
               -- show; this only changes which part of the line that is.
               (array_agg(coalesce(ra.credited_artist_names[1], ra.raw_artist_name)
                          order by ra.created_at))[1] as display
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

revoke all on function public.adopt_radio_artists(uuid) from public, anon, authenticated;
grant execute on function public.adopt_radio_artists(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- The ones already labelled wrongly
-- ---------------------------------------------------------------------------

-- Renames, never merges. Every row here is already the right artist under the
-- right key; only what it is called is wrong, so there is nothing to join and
-- nothing to delete. The artists still carrying a whole credit as their
-- *identity* are a different population and are left for the cleanup, which has
-- to move appearances and edges before it can remove anything.
create or replace function public.relabel_credited_artists(p_limit int default 500)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_renamed int;
begin
    with wanted as (
        select distinct on (a.id) a.id, ra.credited_artist_names[1] as proper
        from public.artists a
        join public.radio_appearances ra
            on ra.normalized_artist_name = a.normalized_name
        where ra.credited_artist_keys is not null
          and array_length(ra.credited_artist_keys, 1) > 1
          and a.normalized_name = ra.credited_artist_keys[1]
          and coalesce(ra.credited_artist_names[1], '') <> ''
          and a.name is distinct from ra.credited_artist_names[1]
        order by a.id, ra.created_at
        limit greatest(1, least(coalesce(p_limit, 500), 5000))
    )
    update public.artists a
    set name = wanted.proper
    from wanted
    where a.id = wanted.id;

    get diagnostics v_renamed = row_count;
    return v_renamed;
end $$;

revoke all on function public.relabel_credited_artists(int) from public, anon, authenticated;
grant execute on function public.relabel_credited_artists(int) to service_role;

do $$
declare
    v_renamed int;
begin
    v_renamed := public.relabel_credited_artists(5000);
    if v_renamed > 0 then
        raise notice 'renamed % artists that were wearing a whole credit', v_renamed;
    end if;
end $$;

-- Every quarter hour, because the crawl keeps re-reading episodes and each one
-- can adopt another. Finds nothing once it has caught up, which costs one
-- query.
create or replace function public.schedule_artist_relabel()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    perform cron.schedule(
        'indigo-relabel-credits',
        '*/15 * * * *',
        $job$select public.relabel_credited_artists(500)$job$);

    return 'indigo-relabel-credits';
end $$;

-- Added to the umbrella, carrying 0030's composition forward unchanged, so a
-- project set up from scratch gets this alongside everything else rather than
-- only one whose drain is already running.
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
    scheduled := array_append(scheduled, public.schedule_release_cache());
    scheduled := array_append(scheduled, public.schedule_artist_merge());
    scheduled := array_append(scheduled, public.schedule_claim_reclaim());
    scheduled := array_append(scheduled, public.schedule_artist_relabel());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_artist_relabel();
    end if;
end $$;
