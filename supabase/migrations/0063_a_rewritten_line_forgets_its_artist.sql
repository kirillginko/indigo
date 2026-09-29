-- A rewritten line forgets whom it was resolved to.
--
-- `storeTracklist` upserts a tracklist on (episode, track_index) and never
-- writes `artist_id` or `recording_id`; `resolve_radio_appearances` only fills
-- those where they are null. So when a list is rewritten with its lines in
-- new places, each slot takes the new line's text and keeps the old line's
-- artist. A YouTube channel's uploads are listed newest first: every new
-- upload moves every line down one slot, and every line inherits its
-- neighbour's artist.
--
-- Measured on the live project, 2026-09-26: 14,917 YouTube lines (in 11
-- uploads lists) resolved to an artist whose name is not the one on the line
-- -- "Zotodorpo - Habaki" filed under µ-Ziq -- and 109 to another line's
-- recording. Lot Radio, whose broadcasts are rewritten when their tracklists
-- are corrected, had 145.
--
-- From now on an update that changes a line's artist clears its artist, and
-- one that changes its artist or title clears its recording and the release
-- check, so the resolver and the release lookup take the line afresh. An
-- update that changes neither -- a list read again as it was -- keeps both.
--
-- NTS is not backfilled here: its mismatches are credits resolved to a
-- combined artist row ("Saint Etienne, Autechre") and Deezer-identified
-- recordings, which are different problems with different fixes.
--
-- Safe to re-run.

create or replace function public.radio_appearance_forgets_on_rewrite()
returns trigger
language plpgsql
as $$
begin
    if new.normalized_artist_name is distinct from old.normalized_artist_name
       and new.artist_id is not distinct from old.artist_id then
        new.artist_id := null;
    end if;
    if (new.normalized_artist_name is distinct from old.normalized_artist_name
        or new.normalized_title is distinct from old.normalized_title)
       and new.recording_id is not distinct from old.recording_id then
        new.recording_id := null;
        new.release_checked_at := null;
    end if;
    return new;
end $$;

drop trigger if exists radio_appearance_forgets_on_rewrite on public.radio_appearances;
create trigger radio_appearance_forgets_on_rewrite
    before update of normalized_artist_name, normalized_title on public.radio_appearances
    for each row execute function public.radio_appearance_forgets_on_rewrite();

-- ---------------------------------------------------------------------------
-- What has already drifted
-- ---------------------------------------------------------------------------

-- Dropped at the end rather than `on commit drop`: the test harness runs a
-- migration a statement at a time, where that drops it before the next line.
create temporary table drifted (id uuid primary key, episode_id uuid not null);

-- YouTube: any line resolved to an artist of another name. Merges only ever
-- join rows of one name (0028), so none of these is a merge.
insert into drifted
select a.id, a.radio_episode_id
from public.radio_appearances a
join public.radio_episodes e on e.id = a.radio_episode_id
join public.artists ar on ar.id = a.artist_id
where e.provider = 'youtube'
  and ar.normalized_name is distinct from a.normalized_artist_name
on conflict do nothing;

-- Lot Radio: stricter, as its credits can be several names -- only where some
-- other artist holds the line's name exactly.
insert into drifted
select a.id, a.radio_episode_id
from public.radio_appearances a
join public.radio_episodes e on e.id = a.radio_episode_id
join public.artists ar on ar.id = a.artist_id
where e.provider = 'lotradio'
  and ar.normalized_name is distinct from a.normalized_artist_name
  and exists (select 1 from public.artists m
              where m.normalized_name = a.normalized_artist_name and m.id <> a.artist_id)
on conflict do nothing;

update public.radio_appearances a
set artist_id = null, recording_id = null, release_checked_at = null
from drifted d
where a.id = d.id;

-- YouTube lines on another line's recording, whatever their artist.
insert into drifted
select a.id, a.radio_episode_id
from public.radio_appearances a
join public.radio_episodes e on e.id = a.radio_episode_id
join public.recordings r on r.id = a.recording_id
where e.provider = 'youtube'
  and r.normalized_title is distinct from a.normalized_title
on conflict do nothing;

update public.radio_appearances a
set recording_id = null, release_checked_at = null
from drifted d
where a.id = d.id and a.recording_id is not null;

-- Resolved again now, episode by episode, rather than left for the backlog.
do $$
declare
    episode uuid;
begin
    for episode in select distinct episode_id from drifted loop
        perform public.resolve_radio_appearances(episode);
    end loop;
end $$;

drop table drifted;

select public.enqueue_enrichment_job('indigo', 'rebuild_dig_edges', 'radio', null, -1, null, null);
