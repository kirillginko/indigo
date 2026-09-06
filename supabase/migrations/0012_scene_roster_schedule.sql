-- Keep the scene crawl going without anybody watching it.
--
-- `request_scene_roster` starts a scene off when a page asks for one, and the
-- worker enqueues its own next page as it walks. Both of those are fine while
-- something is happening; neither survives a hiccup. A drain that fails, a
-- worker that times out mid-page, a scene that finished a month ago and has
-- gone stale — in every one of those the roster simply stops, and stays
-- stopped until somebody happens to open that page again.
--
-- This is the pass that picks them back up. It enqueues nothing new: it only
-- resumes what is half-walked and refreshes what has aged out, which is why it
-- is safe to run on a timer.
--
-- Safe to re-run.

-- How many scenes to move along in one pass.
--
-- Deliberately small. Each one becomes a MusicBrainz request when the queue
-- drains, and the whole reason this table exists is to be a polite client —
-- a pass that queued every stale roster at once would undo that in a single
-- statement.
create or replace function public.resume_scene_rosters(p_limit int default 4)
returns int
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
            -- Half-walked, and nothing is carrying it forward.
            status in ('pending', 'filling')
            -- Or finished long enough ago to be worth asking again.
            or (status = 'ready'
                and filled_at is not null
                and filled_at < now() - public.scene_roster_lifetime())
            -- Or it failed, and enough time has passed to try once more.
            or (status = 'failed' and updated_at < now() - interval '6 hours')
        -- Oldest first, so one scene cannot starve the rest by being large.
        order by coalesce(filled_at, created_at)
        limit v_limit
    loop
        -- Deduped on the same key `request_scene_roster` and the worker use,
        -- so a scene already waiting is never queued a second time and the
        -- crawl cannot fork.
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
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.resume_scene_rosters(int) from public;
grant execute on function public.resume_scene_rosters(int) to service_role;

-- MARK: - On the timer

-- Added to the existing schedule rather than replacing it, so a project that
-- has already run `schedule_indigo_enrichment()` picks this up by running it
-- again. Everything in there is `cron.schedule`, which replaces a job of the
-- same name, so running it twice is not two schedules.
create or replace function public.schedule_scene_rosters()
returns text
language plpgsql
as $$
begin
    -- Callable, not merely installed — `to_regproc` returns null for a name
    -- it finds more than one of, and `cron.schedule` has two overloads. That
    -- is the trap 0007 and 0008 were both written to get out of, and the one
    -- the test stubs carry an overload on purpose to catch.
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;

    -- Every ten minutes, four at a time. Against a drain that runs every five
    -- and takes fifteen, that is a trickle beside the radio crawl rather than
    -- something competing with it — and at one upstream request per page it
    -- stays far inside what MusicBrainz asks of a named client.
    --
    -- This is the knob. A project that wants a scene filled in an afternoon
    -- rather than over a week raises the count, not the frequency: the pacing
    -- that matters is the drain's, and it is shared with everything else.
    perform cron.schedule(
        'indigo-resume-scenes',
        '*/10 * * * *',
        $job$select public.resume_scene_rosters(4)$job$);

    return 'indigo-resume-scenes';
end $$;

create or replace function public.unschedule_scene_rosters()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'unschedule') then
        return 'pg_cron not installed';
    end if;
    perform cron.unschedule('indigo-resume-scenes');
    return 'indigo-resume-scenes';
exception
    when others then return 'not scheduled';
end $$;

-- MARK: - The one switch

-- Redefined here rather than edited in place, which is what 0007, 0008 and
-- 0009 each did to this same function: a migration already applied is history
-- and changing it changes nothing on a database that has run it.
--
-- Carried forward unchanged from 0008 apart from the scene job at the end. The
-- two-argument wrapper in 0009 delegates to this one and is untouched, so
-- `schedule_indigo_enrichment(url, key)` remains the single switch.

create or replace function public.schedule_indigo_enrichment()
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    scheduled text[] := '{}';
begin
    -- Callable, not merely installed. Enabling is only attempted when it is
    -- actually missing, so a project where cron is already usable never goes
    -- near CREATE EXTENSION.
    if not public.has_function('cron', 'schedule') then
        begin
            create extension if not exists pg_cron;
        exception when others then
            raise exception
                'pg_cron could not be enabled (%). Turn it on in the Supabase dashboard '
                'under Database -> Extensions, then run this again.', sqlerrm;
        end;
    end if;

    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is enabled but cron.schedule is not reachable from this role';
    end if;

    -- Ask NTS what it has just broadcast. Hourly, because a station puts out a
    -- few shows a day and asking more often would be asking for nothing.
    perform cron.schedule(
        'indigo-discover-fresh',
        '7 * * * *',
        $job$select public.enqueue_enrichment_job(
            'nts', 'discover_nts', 'fresh',
            jsonb_build_object('mode', 'fresh'), 5, null, null)$job$);
    scheduled := array_append(scheduled, 'indigo-discover-fresh');

    -- And walk backwards through the archive, a page of twelve every five
    -- minutes. Deduped on the key, so a page still waiting is never queued
    -- twice and the crawl cannot fork.
    perform cron.schedule(
        'indigo-discover-backfill',
        '*/5 * * * *',
        $job$select public.enqueue_enrichment_job(
            'nts', 'discover_nts', 'backfill',
            jsonb_build_object('mode', 'backfill'), 0, null, null)$job$);
    scheduled := array_append(scheduled, 'indigo-discover-backfill');

    -- Drain, slightly faster than discovery fills, so the queue tends to empty
    -- rather than grow: a page of twelve plus its own discovery job is
    -- thirteen, against fifteen drained.
    if not public.has_function('net', 'http_post') then
        begin
            create extension if not exists pg_net with schema extensions;
        exception when others then
            raise notice 'pg_net could not be enabled (%)', sqlerrm;
        end;
    end if;

    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-queue',
            '*/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 15)
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-queue');
    else
        raise notice
            'pg_net is unavailable, so nothing will drain the queue. Enable it under '
            'Database -> Extensions and run this again.';
    end if;

    -- These two need nothing outside Postgres, so cron calls them directly
    -- rather than paying for a round trip through an Edge Function.
    perform cron.schedule(
        'indigo-resolve-radio',
        '*/30 * * * *',
        $job$select public.resolve_radio_appearances(null)$job$);
    scheduled := array_append(scheduled, 'indigo-resolve-radio');

    perform cron.schedule(
        'indigo-rebuild-edges',
        '23 * * * *',
        $job$select public.rebuild_radio_dig_edges()$job$);
    scheduled := array_append(scheduled, 'indigo-rebuild-edges');

    -- Scenes, where that migration has been applied. Called and caught rather
    -- than checked for: `to_regproc` returns null for a name it finds more
    -- than one of, which is the trap 0007 and 0008 were both written to get
    -- out of — ask about what you are going to use, and here that means using
    -- it.
    begin
        perform public.schedule_scene_rosters();
        scheduled := array_append(scheduled, 'indigo-resume-scenes');
    exception
        when undefined_function then
            raise notice 'scene scheduling not installed; skipping';
    end;

    return array_to_string(scheduled, ', ');
end $$;
