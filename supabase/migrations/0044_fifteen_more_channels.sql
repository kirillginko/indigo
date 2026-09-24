-- Fifteen more curators, and channels that title the song before the artist.
--
-- souljazzsax1969 writes "Happy Frame Of Mind - Horace Parlan": the usual
-- split, the other way round. `title_artist` reads it so. J-DIGS
-- ("ROOM (Akira Sakata/坂田明, 1980)") and T C's numbered folk songs name no
-- artist a dash can find, so they are titles only.
--
-- oleg_samples is the largest channel followed, at 5,358 uploads; youtube.ts
-- reads up to 6,000 from one list.
--
-- Safe to re-run.

alter table public.youtube_channels drop constraint if exists youtube_channels_title_format_check;
alter table public.youtube_channels add constraint youtube_channels_title_format_check
    check (title_format in ('artist_title', 'title_artist', 'title_only'));

insert into public.youtube_channels (channel_id, name, note, title_format) values
    ('UCFUNdJq1S_hoZCAuK-pcC8g', 'tendingthepalebloom', '1960s-70s UK and US pop-psych and sunshine singles', 'artist_title'),
    ('UCdK82a9RqKVY81__z9FaCzg', 'J-DIGS', 'Japanese jazz; titles carry the artist in brackets', 'title_only'),
    ('UCLMhXnDMVE2AaXujORfQu6Q', 'Üllar Siir', 'African and US boogie, disco and gospel, 1980s', 'artist_title'),
    ('UCUtzfAs4YF2pN3OEElDA21w', 'PerryCoxPF93', 'Live bootlegs and rarities', 'artist_title'),
    ('UCY8_y20lxQhhBe8GZl5A9rw', 'Music for empty rooms', 'Worldwide soul, psych, library; titles end in country and genres', 'artist_title'),
    ('UC-g-sYmtdxN8EMJX01uagJA', 'Andrew Mats74', 'Ethiopian jazz and funk', 'artist_title'),
    ('UCAMuwfmjImYPY2Xq_PACrvQ', 'Adventures In Silence', 'Library and soundtrack cuts', 'artist_title'),
    ('UCggYp9hIV1Am-mN_xi7gb6g', 'souljazzsax1969', 'Soul jazz; titles put the song first', 'title_artist'),
    ('UC-45_Vtx7fLHHYWwxCRK3Sg', 'TheVinylNoise', 'Japanese kayōkyoku and psych; titles in two scripts', 'artist_title'),
    ('UCyreaPjSUH6MygyMIe_GgVA', 'T C', 'Japanese folk songs, numbered; no artist named', 'title_only'),
    ('UCKif-hj_9Vf_Ia2cQwXA-zA', 'Vinyl-Life 3345', 'Easy listening, lounge and European jazz LPs', 'artist_title'),
    ('UCrZIJtZnAMW6tBVE9nJJ-LA', 'Praguedive', 'Jazz and art rock, live and rare', 'artist_title'),
    ('UCQPiEaKPDcftkFss7RC8j4w', 'Z3nti', 'Library, TV and soundtrack music, much of it Japanese', 'artist_title'),
    ('UCJo5gcloXHre_w8r2WnZXUA', 'sphinxe', 'Home recordings, drone and lo-fi', 'artist_title'),
    ('UC47qc6t2RelhfvI-OjgIY2A', 'Rare Samples & Songs Oleg Tsoy', 'Soviet estrada, Eastern European and funk rarities', 'artist_title')
on conflict (channel_id) do update set title_format = excluded.title_format;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.enqueue_youtube_channels();
    end if;
end $$;
