-- Twelve more curators, and a way to say a channel's titles name no artist.
--
-- Most of these title uploads "Artist - Title", as André Navarro II does, in
-- one spelling or another (a tilde, an en dash behind an invisible direction
-- mark, a year left on the end) that youtube.ts now reads. Two do not:
--
--   * aranjuez records titles the record alone: "Sketches of Spain".
--   * aldino puts the song first and himself second: "Stop and Go - aldino
--     remix". Read as "Artist - Title" that adopts every song as a person.
--
-- Those are followed with `title_format = 'title_only'`: each upload is filed
-- and playable, and claims no artist, so it adds nothing false to the graph.
--
-- Safe to re-run.

alter table public.youtube_channels
    add column if not exists title_format text not null default 'artist_title'
    check (title_format in ('artist_title', 'title_only'));

insert into public.youtube_channels (channel_id, name, note, title_format) values
    ('UCfnH9uGrnYRbUT6kM-wSOQw', 'Jazz Obscurities', 'Out-of-print spiritual and free jazz, full albums', 'artist_title'),
    ('UCG69MN8vYfzISOCe2tBOLoQ', 'Saint Coltrane', 'Spiritual jazz, lost tapes and festival recordings, full albums', 'artist_title'),
    ('UCAwv4KIKzlFSlf3Uhb0pFhA', 'jazznote89', 'Post-bop and 1970s jazz sides; titles use "~"', 'artist_title'),
    ('UCvfvL23cqylaa8y1BEfhWFg', 'spiritualarchive', 'Spiritual jazz, minimalism, Brazilian and Japanese', 'artist_title'),
    ('UC4v4daPYllI8HxABEBcFRNA', 'aranjuez records', 'Jazz guitar LPs; titles name the record only', 'title_only'),
    ('UCH2WLzdh4_LNEKRUQUonz1w', 'Brother John', 'Soul jazz and 1970s jazz-funk cuts', 'artist_title'),
    ('UCpDevXNRc7_JNEnr8pr0vzQ', 'aldino', 'Remixes of library and soundtrack music; titles are "Song - aldino remix"', 'title_only'),
    ('UCd7ey8Rtw2-onwjiAx9ymlQ', 'lunarmountains', 'Early-1970s UK prog, folk and psych', 'artist_title'),
    ('UCS1RKsNJOf4PjM7rCTP7XIA', 'aquarianrealm', 'Japanese and European 1970s jazz, rare pressings', 'artist_title'),
    ('UCkNsGraHaYqVxw1F4oifHgQ', 'careless air', 'Private-press folk, AOR and regional oddities', 'artist_title'),
    ('UCAWQkp1_aoRI6VYHEBPc80w', 'StumbledOnThis', 'European radio big bands and library jazz', 'artist_title'),
    ('UCbraK865Jh0OtIKefKCU7GA', 'Noomade', 'Soul, boogie and jazz-funk deep cuts', 'artist_title')
on conflict (channel_id) do update set title_format = excluded.title_format;

-- The format travels with the job, so the worker needs no second read to
-- know how to take a channel's titles.
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
        select channel_id, title_format from public.youtube_channels where enabled
    loop
        perform public.enqueue_enrichment_job(
            'youtube', 'crawl_youtube_channel', channel.channel_id,
            jsonb_build_object('channel_id', channel.channel_id,
                               'title_format', channel.title_format),
            1, null, null);
        queued := queued + 1;
    end loop;
    return queued;
end $$;

revoke all on function public.enqueue_youtube_channels() from public, anon, authenticated;
grant execute on function public.enqueue_youtube_channels() to service_role;

-- The new channels' first read, now rather than at the top of the hour.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.enqueue_youtube_channels();
    end if;
end $$;
