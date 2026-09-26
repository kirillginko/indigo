-- Nine more curators and Marcelo Sandoval's "Acid & Groove" list; Sai Rav's
-- "90s / Liquid DnB" list is dropped.
--
-- Acid & Groove is made of "- Topic" uploads, like the DnB list was: the
-- title is the song alone, so the lines are filed as titles only (see 0058).
--
-- Sai Rav's lines named no artist, so no edge was built from them; removing
-- the episode (its lines go with it) and the show leaves nothing behind.
--
-- Safe to re-run.

insert into public.youtube_channels (channel_id, name, note, title_format, playlist_ids) values
    ('UCs1wifUE3KHxsXAM-qOm67A', 'Jackson Brown', 'UK bass, garage and techno 12"s; titles open with the catalogue number', 'artist_title', null),
    ('UCWpz1Obl5TikffoX3eQnY_Q', 'Enig. Ma.', 'Noise, harsh noise and experimental, full albums', 'artist_title', null),
    ('UCvnWZbgKfSApc1BM1AHen0A', 'Adrian Roffiel', 'Peruvian punk, electronic and assorted rarities', 'artist_title', null),
    ('UCxEMo0SDaLWRpA50h0pxPXg', 'F K S', 'Illbient, minimal synth, new age and balearic; genres in brackets', 'artist_title', null),
    ('UCnPwj5wZIQt2thUTPCO56zw', 'Zoto''s Channel', 'Mostly the owner''s guitar improvisations, some ambient', 'artist_title', null),
    ('UCSVkmss7B4JT2TbaTuHLmzw', 'GROOVE BLENDER', 'Rare synth-pop, post-punk, disco and psych, full albums', 'artist_title', null),
    ('UChYyHX88JbOfWgCtOWDSVMg', 'Richard Holter', 'Downtempo, trip-hop and ambient techno, full albums', 'artist_title', null),
    ('UC-jln7H9BVxgX1zZvDcDatg', 'Kuma''s campfire', 'Japanese city pop, Shibuya-kei and left-field pop, full albums', 'artist_title', null),
    ('UCHAn-JG23KCNCS4ekBnJxCw', 'When Dubs Cry', 'Ambient, kosmische and American primitive guitar, full albums', 'artist_title', null),
    ('UCRytgEdNgXrtorV96-ywWLw', 'Marcelo Sandoval', '"Acid & Groove" playlist only; Topic uploads, no artist in titles', 'title_only',
        array['PLa-t-_X7rpy71oMB8A0GIepmez6Sb8RNk'])
on conflict (channel_id) do update
    set title_format = excluded.title_format, playlist_ids = excluded.playlist_ids;

-- Sai Rav: the follow, anything queued for it, its checkpoint, and what it wrote.
delete from public.youtube_channels where channel_id = 'UCdJEj0wuLWBZpSQabMAkDrw';
delete from public.enrichment_jobs
where job_type = 'crawl_youtube_channel' and dedupe_key = 'UCdJEj0wuLWBZpSQabMAkDrw'
  and status in ('pending', 'failed');
delete from public.enrichment_cursors where name = 'youtube.UCdJEj0wuLWBZpSQabMAkDrw';
delete from public.radio_episodes
where radio_show_id in (select id from public.radio_shows
                        where provider = 'youtube' and external_id = 'UCdJEj0wuLWBZpSQabMAkDrw');
delete from public.radio_shows where provider = 'youtube' and external_id = 'UCdJEj0wuLWBZpSQabMAkDrw';

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.enqueue_youtube_channels();
    end if;
end $$;
