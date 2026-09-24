-- Curated YouTube channels, beside the stations.
--
-- Some channels do what a radio host does -- choose records and put them in
-- order -- for music that exists nowhere else online: an unreissued 1976 side
-- uploaded from somebody's shelf. André Navarro II posts one a day, titled
-- "ARTIST - Title", and sorts them into playlists by region.
--
-- Filed the way The Lot was (0039): no new graph. A channel is a
-- `radio_shows` row with `provider = 'youtube'`, each of its playlists and its
-- uploads is a `radio_episodes` row, and each video is a line of that list.
-- Artist resolution, the "played by" and "played next to" edges, and every
-- read model already key on those tables and not on who published them.
--
-- What is new is that a line can be heard on its own. A station's tracklist is
-- a set heard whole; a curator's list is separate recordings, each with its
-- own address. That address goes in `media_url`.
--
-- Read through the YouTube Data API when a key is configured, and through the
-- channel's public feed (fifteen newest uploads) until then. See
-- supabase/functions/_shared/youtube.ts.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Where a line can be heard
-- ---------------------------------------------------------------------------

alter table public.radio_appearances add column if not exists media_url text;

-- ---------------------------------------------------------------------------
-- Which channels are followed
-- ---------------------------------------------------------------------------

-- Written by hand, or by a migration like this one. Read only by the worker,
-- under the service role; RLS is on with no policy, so the app's key cannot
-- see or change the list. What the app shows is the `radio_shows` rows the
-- crawl writes.
create table if not exists public.youtube_channels (
    channel_id text primary key check (channel_id ~ '^UC[A-Za-z0-9_-]{22}$'),
    name text not null,
    -- Why it is followed: what it uploads that nothing else carries.
    note text,
    enabled boolean not null default true,
    added_at timestamptz not null default now()
);

alter table public.youtube_channels enable row level security;
revoke all on public.youtube_channels from anon, authenticated;

insert into public.youtube_channels (channel_id, name, note)
values ('UCv5OAW45h67CJEY6kJLyisg', 'André Navarro II',
        '1970s records from everywhere, mostly unreissued; ROVR curator')
on conflict (channel_id) do nothing;

-- ---------------------------------------------------------------------------
-- The tracklist, with where each line plays
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced: a function's result columns cannot be changed
-- in place. Granted back to the app below, and still named in
-- `app_callable_functions()`, so 0023's sweep leaves it alone.
drop function if exists public.episode_tracklist(uuid);

create function public.episode_tracklist(p_episode_id uuid)
returns table (
    appearance_id uuid,
    track_index int,
    raw_artist_name text,
    raw_track_title text,
    offset_seconds int,
    artist_id uuid,
    artist_name text,
    recording_id uuid,
    media_url text
)
language sql
stable
as $$
select
    ra.id, ra.track_index, ra.raw_artist_name, ra.raw_track_title, ra.offset_seconds,
    ra.artist_id, a.name, ra.recording_id, ra.media_url
from public.radio_appearances ra
left join public.artists a on a.id = ra.artist_id
where ra.radio_episode_id = p_episode_id
order by ra.track_index;
$$;

revoke all on function public.episode_tracklist(uuid) from public;
grant execute on function public.episode_tracklist(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

-- One job per followed channel, deduped on the channel, so a channel still
-- waiting is never queued twice and each has one writer.
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
        select channel_id from public.youtube_channels where enabled
    loop
        perform public.enqueue_enrichment_job(
            'youtube', 'crawl_youtube_channel', channel.channel_id,
            jsonb_build_object('channel_id', channel.channel_id), 1, null, null);
        queued := queued + 1;
    end loop;
    return queued;
end $$;

revoke all on function public.enqueue_youtube_channels() from public, anon, authenticated;
grant execute on function public.enqueue_youtube_channels() to service_role;

create or replace function public.schedule_youtube()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Hourly. A list that has not changed size is stepped over without being
    -- read, so a pass over a quiet channel is two requests; a new upload
    -- costs one read of the uploads list. Hourly also finishes a large
    -- channel's first read, which a single pass stops partway through (see
    -- TIME_BUDGET_MS). Every list is still re-read within the refresh window
    -- the API terms ask for.
    perform cron.schedule(
        'indigo-youtube-channels',
        '23 * * * *',
        $job$select public.enqueue_youtube_channels()$job$);

    return 'indigo-youtube-channels';
end $$;

-- Added to the umbrella, carrying 0039's composition forward unchanged, so a
-- project set up from scratch gets this alongside everything else.
create or replace function public.schedule_scene_rosters()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;

    perform cron.schedule(
        'indigo-resume-scenes',
        '*/10 * * * *',
        $job$select public.resume_scene_rosters(4)$job$);
    scheduled := array_append(scheduled, 'indigo-resume-scenes');

    perform cron.schedule(
        'indigo-seed-scenes',
        '41 3 * * *',
        $job$select public.seed_scene_rosters()$job$);
    scheduled := array_append(scheduled, 'indigo-seed-scenes');

    scheduled := array_append(scheduled, public.schedule_nts_retag());
    scheduled := array_append(scheduled, public.schedule_scene_radio_fill());
    scheduled := array_append(scheduled, public.schedule_artist_origins());
    scheduled := array_append(scheduled, public.schedule_artist_portraits());
    scheduled := array_append(scheduled, public.schedule_track_releases());
    scheduled := array_append(scheduled, public.schedule_nts_hosts());
    scheduled := array_append(scheduled, public.schedule_release_cache());
    scheduled := array_append(scheduled, public.schedule_artist_merge());
    scheduled := array_append(scheduled, public.schedule_claim_reclaim());
    scheduled := array_append(scheduled, public.schedule_artist_relabel());
    scheduled := array_append(scheduled, public.schedule_lotradio());
    scheduled := array_append(scheduled, public.schedule_youtube());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

-- Scheduled, and the first pass queued, only where the drain is running --
-- otherwise nothing would take the jobs this puts up.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_youtube();
        perform public.enqueue_youtube_channels();
    end if;
end $$;
