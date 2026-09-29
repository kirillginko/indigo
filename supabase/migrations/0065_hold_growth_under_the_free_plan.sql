-- Holds the database under the free plan's 500 MB until the upgrade to Pro.
--
-- Measured 2026-09-29 at 556 MB (sum of pg_database_size), up from 469 MB two
-- days before. Nothing was badly bloated -- about 55 MB of dead space in all,
-- reclaimed by hand after this -- so the rest is growth, and growth has to
-- stop, not be vacuumed after.
--
-- Three lanes add rows as fast as they are fed, and none of them is something
-- a listener is waiting on:
--
--   * Deezer track -> release lookups: a release, a label, a recording, their
--     external ids and graph edges per line resolved. 4,018 were queued.
--   * Discogs artist portraits: an artwork row per artist. 6,420 in two days.
--   * MusicBrainz artist origins: 4,240 queued.
--
-- Paused rather than dropped, with `resume_growth_lanes()` to put them back
-- exactly as they were. The queued jobs are removed, not kept: each lane picks
-- its work from rows it has not checked yet, so the same work is queued again
-- on resume and nothing is lost. Left queued, the main drain -- which takes
-- every job type -- would have carried on adding rows regardless.
--
-- Also here, because they are the same audit:
--
--   * The archive channels are crawled every six hours, not every hour. All 78
--     were read hourly -- 1,872 channel lookups a day against YouTube's quota --
--     to find that about five had changed.
--   * `request_scene_roster` refuses what no listener would send. It is callable
--     with the app's public key and inserted a row for any text it was given,
--     of any length, as fast as it was asked.

-- MARK: - Growth lanes

create or replace function public.pause_growth_lanes()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if public.has_function('cron', 'schedule') then
        perform cron.unschedule(jobname) from cron.job
        where jobname in (
            'indigo-track-releases',
            'indigo-artist-portraits',
            'indigo-artist-origins',
            -- Its own drain lane: with nothing being queued it would call
            -- the worker every five minutes to find nothing to do.
            'indigo-drain-portraits'
        );
    end if;

    delete from public.enrichment_jobs
    where status = 'pending'
      and (provider, job_type) in (
          ('deezer', 'fetch_track_release'),
          ('discogs', 'fetch_artist_portrait'),
          ('musicbrainz', 'fetch_artist_origin')
      );

    return 'growth lanes paused (0065)';
end $$;

-- Puts back what `pause_growth_lanes` took out, on the schedules they had.
-- Run once the project is on Pro: `select public.resume_growth_lanes();`
create or replace function public.resume_growth_lanes()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'no pg_cron';
    end if;

    perform cron.schedule('indigo-track-releases', '*/5 * * * *',
        $job$select public.enqueue_track_releases(40)$job$);
    perform cron.schedule('indigo-artist-portraits', '7 * * * *',
        $job$select public.enqueue_artist_portraits(120)$job$);
    perform cron.schedule('indigo-artist-origins', '37 * * * *',
        $job$select public.enqueue_artist_origins(80)$job$);

    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-portraits',
            '2-59/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30, 'job_type', 'fetch_artist_portrait')
            )$job$);
    end if;

    return 'growth lanes resumed';
end $$;

revoke all on function public.pause_growth_lanes() from public, anon, authenticated;
revoke all on function public.resume_growth_lanes() from public, anon, authenticated;
grant execute on function public.pause_growth_lanes() to service_role;
grant execute on function public.resume_growth_lanes() to service_role;

select public.pause_growth_lanes();

-- MARK: - Archive channels

do $$
begin
    if public.has_function('cron', 'schedule')
       and exists (select 1 from cron.job where jobname = 'indigo-youtube-channels') then
        -- Same minute as before, a quarter as often. A playlist whose size has
        -- not moved is skipped by the crawl anyway (see `isUnchanged`); what
        -- this saves is asking.
        perform cron.schedule(
            'indigo-youtube-channels',
            '23 */6 * * *',
            $job$select public.enqueue_youtube_channels()$job$);
    end if;
end $$;

-- MARK: - Scene rosters

-- The listener's app sends a place and a sound it has already normalised; the
-- longest ever stored is 23 characters. Anything far past that, or carrying
-- control characters, is not from the app. And a burst of new rosters is not
-- a listener browsing either: past `v_hourly_cap` new ones in an hour, only
-- rosters that already exist are answered.
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
    v_max_length constant int := 80;
    v_hourly_cap constant int := 60;
    v_roster public.scene_rosters%rowtype;
begin
    if v_place_key = ''
       or length(v_place_key) > v_max_length
       or length(v_sound_key) > v_max_length
       or length(coalesce(p_place, '')) > v_max_length
       or length(coalesce(p_sound, '')) > v_max_length
       or concat(p_place, p_place_key, p_sound, p_sound_key) ~ '[[:cntrl:]]' then
        return jsonb_build_object('status', 'invalid');
    end if;

    select * into v_roster
    from public.scene_rosters
    where place_key = v_place_key and sound_key = v_sound_key;

    if not found then
        if (select count(*) from public.scene_rosters
            where created_at > now() - interval '1 hour') >= v_hourly_cap then
            return jsonb_build_object('status', 'busy');
        end if;

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
