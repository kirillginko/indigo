-- Two more curators, both titled "Artist - Title".
--
-- Safe to re-run.

insert into public.youtube_channels (channel_id, name, note, title_format) values
    ('UCulqr-P-isJtgcvsXkMY_pg', 'Rhythm and Life', 'Spiritual jazz, dub, new age and Brazilian', 'artist_title'),
    ('UCUlbrPQSZ2Zn8YTWNWqpilg', 'Selected Sounds', 'Jazz, easy listening and soul from the owner''s shelves', 'artist_title')
on conflict (channel_id) do nothing;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.enqueue_youtube_channels();
    end if;
end $$;
