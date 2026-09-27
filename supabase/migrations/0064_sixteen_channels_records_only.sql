-- Sixteen more curators, read for records only, and the big ones capped.
--
-- Every channel here is followed for its uploads alone, with
-- `require_artist`: a video whose title names no artist -- an interview, a
-- documentary, "What Is This Unknown Song?", a mix intro -- is left out.
--
-- The database was at 466 of 500 MB on 2026-09-27, and these channels hold
-- 26,344 uploads between them, about 600 bytes a line before artists and
-- edges. The seven largest are read to their newest 1,000 uploads
-- (`max_items`); that keeps the batch near 10,000 lines.
--
-- Vinyle Archéologie writes "Artist / Title" (`artist_slash_title`).
-- 紅谷のまったりJazz日和 was asked for and left out: it names artists only
-- in katakana ("チェット・ベイカー"), which would file a second artist for
-- everyone it plays.
--
-- Safe to re-run.

alter table public.youtube_channels drop constraint if exists youtube_channels_title_format_check;
alter table public.youtube_channels add constraint youtube_channels_title_format_check
    check (title_format in ('artist_title', 'title_artist', 'artist_colon_title',
                            'artist_slash_title', 'title_only'));

alter table public.youtube_channels add column if not exists max_items int
    check (max_items is null or max_items between 1 and 6000);

insert into public.youtube_channels
    (channel_id, name, note, title_format, playlist_ids, require_artist, max_items) values
    ('UC8xh2F0XsAq7nWnZkWDupIw', 'holy warbles', 'Early electronic, modern classical and spoken word; titles use "~"', 'artist_title', array['UU8xh2F0XsAq7nWnZkWDupIw'], true, null),
    ('UCKydEBEvAU5zkN8o1snt62A', 'Vinyle Archéologie', 'Crate digging and breaks from everywhere; titles use "/"', 'artist_slash_title', array['UUKydEBEvAU5zkN8o1snt62A'], true, 1000),
    ('UCnNHqzzJ1sRYa5yDoRmb_lw', 'PARAĐIGMAS', 'Hypnotic techno, ambient and d&b; label in 【】', 'artist_title', array['UUnNHqzzJ1sRYa5yDoRmb_lw'], true, 1000),
    ('UCekevJPGTZ44nn_i4SWJDIw', 'The Voice of Anton', 'Library, soundtrack and lounge jazz; hashtags after the title', 'artist_title', array['UUekevJPGTZ44nn_i4SWJDIw'], true, 1000),
    ('UC2xLCkq2twf355YoQggRTyQ', 'foreal', 'Obscure jazz, soul, MPB and funk singles', 'artist_title', array['UU2xLCkq2twf355YoQggRTyQ'], true, 1000),
    ('UCafzP_1RoAjtjMYuB7hmXoA', 'gkugno', 'Italo, synth-pop and boogie remixes and extended versions', 'artist_title', array['UUafzP_1RoAjtjMYuB7hmXoA'], true, null),
    ('UCZYYbJH5eJ3zIJUU5qvpLuQ', 'Funkissman 78', 'Deep funk and Japanese OST rarities', 'artist_title', array['UUZYYbJH5eJ3zIJUU5qvpLuQ'], true, null),
    ('UC3Oq_hsL2yRyz2VSchhnIMw', 'MoogMelodiya', 'Private-press prog, fusion, Christian and synth, 1970s-80s', 'artist_title', array['UU3Oq_hsL2yRyz2VSchhnIMw'], true, null),
    ('UCnRTgPDq6xRbIMRK5SIr8VQ', 'ultravillage', 'Underground ambient, new age and minimal cassettes', 'artist_title', array['UUnRTgPDq6xRbIMRK5SIr8VQ'], true, null),
    ('UCfZaKaaD5CNN1zm5JfDt53A', 'theuppermostinlife', 'Dark electronic, wave and experimental', 'artist_title', array['UUfZaKaaD5CNN1zm5JfDt53A'], true, 1000),
    ('UChS0SPpEqGMGRim7mebedPg', 'TheIDMMaster', 'IDM and electronica', 'artist_title', array['UUhS0SPpEqGMGRim7mebedPg'], true, 1000),
    ('UCdXwULsPq5pqby0d77GcVDg', 'Temple Records', 'Label channel: its own releases and reissues', 'artist_title', array['UUdXwULsPq5pqby0d77GcVDg'], true, null),
    ('UCwkOiBuB-vcqMsetAqnJODw', 'sipsun8', 'Jazz, rock and art-film sound; documentaries left out', 'artist_title', array['UUwkOiBuB-vcqMsetAqnJODw'], true, null),
    ('UC_t-cY19rfQIRYQ2uYXOj9w', 'Sarah K', 'Fourth-world and ambient full albums, some Russian rap', 'artist_title', array['UU_t-cY19rfQIRYQ2uYXOj9w'], true, null),
    ('UCG9inuDQ1ROLufVWNmItj_g', 'Ricardo Maraña', 'Italian library, soundtrack and easy listening', 'artist_title', array['UUG9inuDQ1ROLufVWNmItj_g'], true, 1000),
    ('UC5HkRLyvYU6NAOjVaL_4ISA', 'PsychoRock', 'Latin American and European psych and prog rock albums', 'artist_title', array['UU5HkRLyvYU6NAOjVaL_4ISA'], true, null)
on conflict (channel_id) do update
    set title_format = excluded.title_format, playlist_ids = excluded.playlist_ids,
        require_artist = excluded.require_artist, max_items = excluded.max_items;

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
        select channel_id, title_format, playlist_ids, skip_titles, require_artist, max_items
        from public.youtube_channels where enabled
    loop
        perform public.enqueue_enrichment_job(
            'youtube', 'crawl_youtube_channel', channel.channel_id,
            jsonb_build_object('channel_id', channel.channel_id,
                               'title_format', channel.title_format,
                               'playlist_ids', to_jsonb(channel.playlist_ids),
                               'skip_titles', channel.skip_titles,
                               'require_artist', channel.require_artist,
                               'max_items', channel.max_items),
            1, null, null);
        queued := queued + 1;
    end loop;
    return queued;
end $$;

revoke all on function public.enqueue_youtube_channels() from public, anon, authenticated;
grant execute on function public.enqueue_youtube_channels() to service_role;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.enqueue_youtube_channels();
    end if;
end $$;
