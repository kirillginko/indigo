-- Zoto's channel: only uploads that name an artist and a title.
--
-- After 0060 his uploads still held 43 videos with no artist in the title
-- ("Zoto Album Pick Of The Week #12", "Pinch harmonic fest", emoji) and 67
-- of his own tracks and mixes, credited to Zotodorpo. `require_artist` leaves
-- out any video whose title names no artist; the Zotodorpo credit joins the
-- noodling in `skip_titles`.
--
-- The checkpoint is cleared so the next pass re-reads the uploads and
-- rewrites the list without them.
--
-- Safe to re-run.

alter table public.youtube_channels add column if not exists require_artist boolean not null default false;

update public.youtube_channels
set require_artist = true,
    skip_titles = 'guitar noodling|^zotodorpo\s*[-–—~]'
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
        select channel_id, title_format, playlist_ids, skip_titles, require_artist
        from public.youtube_channels where enabled
    loop
        perform public.enqueue_enrichment_job(
            'youtube', 'crawl_youtube_channel', channel.channel_id,
            jsonb_build_object('channel_id', channel.channel_id,
                               'title_format', channel.title_format,
                               'playlist_ids', to_jsonb(channel.playlist_ids),
                               'skip_titles', channel.skip_titles,
                               'require_artist', channel.require_artist),
            1, null, null);
        queued := queued + 1;
    end loop;
    return queued;
end $$;

revoke all on function public.enqueue_youtube_channels() from public, anon, authenticated;
grant execute on function public.enqueue_youtube_channels() to service_role;

delete from public.enrichment_cursors where name = 'youtube.UCnPwj5wZIQt2thUTPCO56zw';
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
