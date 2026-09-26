-- Zoto's channel: the records in his uploads, not his own guitar noodling.
--
-- 483 of his 1,244 uploads are "Zoto Guitar Noodling #N", and three of his
-- four playlists are his own work. He is followed for his uploads alone, now
-- that `playlist_ids` can name a channel's "UU" uploads list, and
-- `skip_titles` leaves out any video whose title it matches (case-insensitive,
-- read by the worker as a JavaScript pattern).
--
-- What was already written goes: the three playlists, the noodling lines in
-- the uploads, and the checkpoint, so the next pass re-reads the uploads.
--
-- Safe to re-run.

alter table public.youtube_channels add column if not exists skip_titles text;

alter table public.youtube_channels drop constraint if exists youtube_channels_playlist_ids_check;
alter table public.youtube_channels add constraint youtube_channels_playlist_ids_check
    check (playlist_ids is null
           or (cardinality(playlist_ids) > 0
               and array_to_string(playlist_ids, ',') ~ '^(PL|UU)[A-Za-z0-9_-]{10,}(,(PL|UU)[A-Za-z0-9_-]{10,})*$'));

update public.youtube_channels
set playlist_ids = array['UUnPwj5wZIQt2thUTPCO56zw'],
    skip_titles = 'guitar noodling',
    note = 'Techno, ambient and electronic uploads; his own noodling left out'
where channel_id = 'UCnPwj5wZIQt2thUTPCO56zw';

create or replace function public.enqueue_youtube_channels()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    channel record;
    queued int := 0;
begin
    for channel in
        select channel_id, title_format, playlist_ids, skip_titles
        from public.youtube_channels where enabled
    loop
        perform public.enqueue_enrichment_job(
            'youtube', 'crawl_youtube_channel', channel.channel_id,
            jsonb_build_object('channel_id', channel.channel_id,
                               'title_format', channel.title_format,
                               'playlist_ids', to_jsonb(channel.playlist_ids),
                               'skip_titles', channel.skip_titles),
            1, null, null);
        queued := queued + 1;
    end loop;
    return queued;
end $$;

revoke all on function public.enqueue_youtube_channels() from public, anon, authenticated;
grant execute on function public.enqueue_youtube_channels() to service_role;

delete from public.radio_episodes e
using public.radio_shows s
where e.radio_show_id = s.id
  and s.provider = 'youtube' and s.external_id = 'UCnPwj5wZIQt2thUTPCO56zw'
  and e.external_id <> 'UUnPwj5wZIQt2thUTPCO56zw';

delete from public.radio_appearances a
using public.radio_episodes e
where a.radio_episode_id = e.id
  and e.provider = 'youtube' and e.external_id = 'UUnPwj5wZIQt2thUTPCO56zw'
  and a.raw_track_title ~* 'guitar noodling';

delete from public.enrichment_cursors where name = 'youtube.UCnPwj5wZIQt2thUTPCO56zw';

-- A job already queued carries the old payload; it is replaced by one that
-- carries the new one.
delete from public.enrichment_jobs
where job_type = 'crawl_youtube_channel' and dedupe_key = 'UCnPwj5wZIQt2thUTPCO56zw'
  and status = 'pending';

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.enqueue_youtube_channels();
    end if;
end $$;
