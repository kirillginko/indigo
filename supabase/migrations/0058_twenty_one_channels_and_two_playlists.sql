-- Twenty-one more curators, and two channels followed for one playlist each.
--
-- Sai Rav's "90s / Liquid DnB" and Shafeeq Khan's "Albums" are the lists
-- wanted, not everything those channels post. `playlist_ids` names them; null,
-- as for every channel before this, follows the whole channel. youtube.ts
-- reads only the named lists, and only those the channel owns.
--
-- Title formats:
--   * FOND/SOUND writes "Artist: Title (1985) [Album]" -- `artist_colon_title`.
--   * Sai Rav's list is made of "- Topic" uploads, titled with the song alone.
--     The artist is only in the uploading channel's name, which is a
--     streaming service's credit (see deezer.ts), so the lines claim nobody.
--
-- Safe to re-run.

alter table public.youtube_channels drop constraint if exists youtube_channels_title_format_check;
alter table public.youtube_channels add constraint youtube_channels_title_format_check
    check (title_format in ('artist_title', 'title_artist', 'artist_colon_title', 'title_only'));

alter table public.youtube_channels add column if not exists playlist_ids text[];
alter table public.youtube_channels drop constraint if exists youtube_channels_playlist_ids_check;
alter table public.youtube_channels add constraint youtube_channels_playlist_ids_check
    check (playlist_ids is null
           or (cardinality(playlist_ids) > 0
               and array_to_string(playlist_ids, ',') ~ '^PL[A-Za-z0-9_-]{10,}(,PL[A-Za-z0-9_-]{10,})*$'));

insert into public.youtube_channels (channel_id, name, note, title_format, playlist_ids) values
    ('UCowyry-xWRrdbQWlWkvq5fQ', 'Funked Up East', 'Soviet library, OST, jazz-funk and easy listening', 'artist_title', null),
    ('UC3fanss1f5LC2uFAa1rlP0g', 'Redface Radio', 'Digital-era club and dance oddities, 1990s to now', 'artist_title', null),
    ('UCECgXFAs9hItioqmVpVGICA', 'Dream Resort', 'Japanese and US new age and ambient, full albums', 'artist_title', null),
    ('UC9k4ZVyWf6N-T9nDEH5rDkg', 'Portal Records', 'Japanese jazz, library and soundtrack; a Tokyo record shop', 'artist_title', null),
    ('UCheA3e9JmjP5zFGwMOMdDtw', 'John Suzuki', 'Japanese indie, Shibuya-kei and folk, full albums', 'artist_title', null),
    ('UCTXyZFYkgx3E8Ugzwy6Uuqg', 'Slowly Submerge', 'Japanese rock bands, much of it live', 'artist_title', null),
    ('UCyvDDgWNL0gPlXCFQtofZLg', 'Selvatica', 'Ambient, new age and electronic, Japanese and European', 'artist_title', null),
    ('UCzdjotRUrg7-WWRKwmC5pvw', 'Funeral Tango', 'Japanese environmental and new age, full albums', 'artist_title', null),
    ('UCtk8o5vRvzqpQ6s8l3piWJA', 'Blitz3677', 'Roots reggae, dub and dancehall LPs', 'artist_title', null),
    ('UCjROj0TXDu6VsJmXBa36o1g', 'Mystery Circles', 'Ambient and synth label; its own releases', 'artist_title', null),
    ('UC3Gp3E-5ehV6LgzDGno9xzw', 'musicforplants', 'Ambient, minimal synth and new age', 'artist_title', null),
    ('UC3N5FSflR4maP3veQ3mZe4A', 'FOND/SOUND', 'Japanese ambient, new age and city pop; titles use a colon', 'artist_colon_title', null),
    ('UCzj3wQu9w57jroiP5JFqBrw', 'slapyaface', 'Rare cuts the uploader likes and radio does not play', 'artist_title', null),
    ('UC-RVESJTf_zSaFB8qGoxOnA', 'should be asleep', 'Japanese and US new age and relaxation, full albums', 'artist_title', null),
    ('UCDdlew413eQrVZBSYDKFwDw', 'Poniko_Strawberry', 'Shibuya-kei and 1990s Japanese indie, full releases', 'artist_title', null),
    ('UCKfbbsRdWZJGQffxT9IF8qA', 'Noka', 'Japanese, Korean and Taiwanese indie and pop', 'artist_title', null),
    ('UCg5gsnHrCPZ6Eo02CvTp62A', 'Aaron Levin', 'Kwaito, digital dancehall, boogie and balearic', 'artist_title', null),
    ('UC4rdJibQ4NfeJxGbg4rvNxw', 'ants kask', '1980s Japanese and Taiwanese city pop, side and track noted', 'artist_title', null),
    ('UC2QlZ0NIY12Tg-AGJZ3Cddw', 'SleazyEmotions', 'Library, soundtrack and jazz-funk', 'artist_title', null),
    ('UCZOV3oZvlTl-JRZS7LLcXZA', 'High Notes Archives', '1970s and 80s jazz LPs', 'artist_title', null),
    ('UCA_g11EnBViznYOWIN-QHlQ', 'Orca', 'Ambient, drone and new age, full albums', 'artist_title', null),
    ('UCdJEj0wuLWBZpSQabMAkDrw', 'Sai Rav', '"90s / Liquid DnB" playlist only; Topic uploads, no artist in titles', 'title_only',
        array['PLGvA4wOcSYU6FCrELJBJnsnNIz-lldGoL']),
    ('UC1NoPYkbQqpAT_bpHVEyWEw', 'Shafeeq Khan', '"Albums" playlist only', 'artist_title',
        array['PLc1-F8KicA-z4wnNzFd2SKXBzVnUyNapM'])
on conflict (channel_id) do update
    set title_format = excluded.title_format, playlist_ids = excluded.playlist_ids;

-- The lists travel with the job, as the format does (0042).
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
        select channel_id, title_format, playlist_ids from public.youtube_channels where enabled
    loop
        perform public.enqueue_enrichment_job(
            'youtube', 'crawl_youtube_channel', channel.channel_id,
            jsonb_build_object('channel_id', channel.channel_id,
                               'title_format', channel.title_format,
                               'playlist_ids', to_jsonb(channel.playlist_ids)),
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
