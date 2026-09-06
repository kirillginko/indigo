-- Go back for the genres the ingest used to read past.
--
-- 0014 started keeping what the station files a broadcast under. It could not
-- do anything about the episodes already in the table: those were ingested by
-- a worker that dropped the field, so they sit there untagged and count for
-- nothing when the scenes are read out. On an archive that has been crawling
-- for a while that is most of them.
--
-- Fetching one again is a job that already exists — `fetch_nts_episode` upserts
-- on (provider, external_id), and the upsert now writes genres. So this is not
-- a new kind of work, it is the same work asked for again, and everything that
-- makes that safe already holds: the dedupe index stops an episode being
-- queued twice, and the drain paces it.
--
-- Safe to re-run.

-- How many to ask for in one pass.
--
-- Small on purpose. These share a queue and a drain with the archive crawl,
-- and an impatient backfill of the past would stop the present being read —
-- what NTS broadcast this morning matters more than tagging something from
-- 2019.
create or replace function public.retag_nts_episodes(p_limit int default 20)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 20), 200));
    v_show text;
    v_episode text;
begin
    for v_row in
        select e.external_id
        from public.radio_episodes e
        where e.provider = 'nts'
          and e.genres = '{}'
          and e.moods = '{}'
          and e.external_id like '%/%'
          -- And not already waiting. `enqueue_enrichment_job` absorbs a repeat
          -- through the dedupe index and says nothing, so a pass that did not
          -- check would report work it had not created and pick the same
          -- episodes again every twenty minutes until one of them ran.
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'nts'
                and j.job_type = 'fetch_nts_episode'
                and j.dedupe_key = e.external_id
                and j.status in ('pending', 'running')
          )
        -- Newest first: the recent archive is what somebody browsing is most
        -- likely to land in.
        order by coalesce(e.aired_at, e.created_at) desc
        limit v_limit
    loop
        v_show := split_part(v_row.external_id, '/', 1);
        v_episode := split_part(v_row.external_id, '/', 2);
        continue when v_show = '' or v_episode = '';

        perform public.enqueue_enrichment_job(
            'nts',
            'fetch_nts_episode',
            v_row.external_id,
            jsonb_build_object('show', v_show, 'episode', v_episode),
            -- Below the live crawl. Yesterday's tags are worth having and are
            -- not worth delaying today's broadcasts for.
            -1,
            null,
            null
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.retag_nts_episodes(int) from public;
grant execute on function public.retag_nts_episodes(int) to service_role;

-- MARK: - On the timer

-- Every twenty minutes, twenty at a time — about 1,400 a day against a drain
-- that takes fifteen every five minutes and is mostly working through the
-- archive crawl. It stops on its own: once every episode carries something the
-- select finds nothing and the pass costs one query.
create or replace function public.schedule_nts_retag()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;
    perform cron.schedule(
        'indigo-retag-nts',
        '*/20 * * * *',
        $job$select public.retag_nts_episodes(20)$job$);
    return 'indigo-retag-nts';
end $$;

-- Folded into the scene switch, which is already where scene-shaped scheduling
-- lives — the tags exist to be read as scenes.
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

    -- Put the shelf up now rather than at three tomorrow morning, so a project
    -- that has just been switched on has something to crawl tonight.
    perform public.seed_scene_rosters();

    return array_to_string(scheduled, ', ');
end $$;
