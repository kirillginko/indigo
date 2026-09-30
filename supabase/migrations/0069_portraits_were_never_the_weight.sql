-- Puts the artist portrait lane back.
--
-- 0065 paused it with the lanes that were filling the database, and it was
-- not one of them. A portrait is one `artwork` row of about 265 bytes; the
-- lane files 2,880 a day, which is under a megabyte, and the 24,853 radio
-- artists still without one come to about 7 MB in all. The weight was the
-- Deezer track -> release lane, which stays paused, as does MusicBrainz
-- origins.
--
-- What pausing it cost was the listener's: an artist with no portrait here is
-- one the app searches Discogs for itself, one request every 1.7 seconds out
-- of a budget every page shares, and the For You page is made of exactly the
-- artists this lane covers.

create or replace function public.pause_growth_lanes()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if public.has_function('cron', 'schedule') then
        perform cron.unschedule(jobname) from cron.job
        where jobname in ('indigo-track-releases', 'indigo-artist-origins');
    end if;

    delete from public.enrichment_jobs
    where status = 'pending'
      and (provider, job_type) in (
          ('deezer', 'fetch_track_release'),
          ('musicbrainz', 'fetch_artist_origin')
      );

    return 'growth lanes paused (0069: portraits are not one of them)';
end $$;

do $$
begin
    if not public.has_function('cron', 'schedule') then
        return;
    end if;

    perform cron.schedule('indigo-artist-portraits', '7 * * * *',
        $job$select public.enqueue_artist_portraits(120)$job$);

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

    -- The hour's worth now, rather than at seven minutes past.
    perform public.enqueue_artist_portraits(120);
end $$;
