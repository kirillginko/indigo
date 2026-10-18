-- Fills every plan from the same staged lines, then builds indexes, so each
-- is measured freshly packed. Run by run.sh after the COPYs.

\set ON_ERROR_STOP on

-- A: every line, exactly as storeTracklist writes it ---------------------------

insert into radio_appearances (
    id, recording_id, offset_seconds, confidence, radio_episode_id, track_index,
    raw_artist_name, raw_track_title, normalized_artist_name, normalized_title,
    artist_id, identification_source, isrc, deezer_track_id, musicbrainz_recording_id,
    credited_artist_names, credited_artist_keys, media_url)
select id, recording_id, offset_seconds, confidence, radio_episode_id, track_index,
       raw_artist_name, raw_track_title, normalized_artist_name, normalized_title,
       artist_id, identification_source, isrc, deezer_track_id, musicbrainz_recording_id,
       credited_artist_names, credited_artist_keys, media_url
from staging_lines;

create unique index radio_appearances_slot_idx on radio_appearances (radio_episode_id, track_index);
create index radio_appearances_artist_idx on radio_appearances (artist_id);
create index radio_appearances_pending_artist_idx on radio_appearances (normalized_artist_name) where artist_id is null;
create index radio_appearances_credited_idx on radio_appearances using gin (credited_artist_keys) where credited_artist_keys is not null;
create index radio_appearances_pending_release_idx on radio_appearances (deezer_track_id) where deezer_track_id is not null and release_checked_at is null;
create index radio_appearances_archive_search_trgm on radio_appearances using gin (
    (' ' || coalesce(normalized_artist_name, '') || ' ' || coalesce(normalized_title, '')) gin_trgm_ops)
    where media_url is not null;

-- A, broadcast lines only: what the live table costs per broadcast line, for
-- a like-for-like comparison with the plans below (the trigram index is
-- partial on media_url, so it holds nothing here).

create table radio_appearances_broadcast (like radio_appearances including defaults);
alter table radio_appearances_broadcast add primary key (id);
insert into radio_appearances_broadcast select * from radio_appearances where media_url is null;
create unique index radio_appearances_broadcast_slot_idx on radio_appearances_broadcast (radio_episode_id, track_index);
create index radio_appearances_broadcast_artist_idx on radio_appearances_broadcast (artist_id);
create index radio_appearances_broadcast_pending_artist_idx on radio_appearances_broadcast (normalized_artist_name) where artist_id is null;
create index radio_appearances_broadcast_credited_idx on radio_appearances_broadcast using gin (credited_artist_keys) where credited_artist_keys is not null;
create index radio_appearances_broadcast_pending_release_idx on radio_appearances_broadcast (deezer_track_id) where deezer_track_id is not null and release_checked_at is null;

-- The broadcast lines every other plan holds --------------------------------------

create unlogged table broadcast as
select s.*, a.name as artist_name
from staging_lines s
left join artists a on a.id = s.artist_id
where s.media_url is null;

-- Every plan below assumes slots run 0..n-1 without gaps; a real conversion
-- would pad a dropped line with nulls.
do $$
begin
    if exists (select 1 from broadcast group by radio_episode_id having max(track_index) + 1 <> count(*)) then
        raise exception 'synthetic episodes have gaps in track_index';
    end if;
end $$;

-- C2 --------------------------------------------------------------------------

insert into radio_lines_c2
select radio_episode_id, track_index, artist_id, isrc, raw_track_title, offset_seconds
from broadcast;
create index radio_lines_c2_artist_idx on radio_lines_c2 (artist_id);

-- D1 --------------------------------------------------------------------------

insert into radio_tracklists
select radio_episode_id,
       array_agg(artist_id order by track_index),
       array_agg(raw_track_title order by track_index),
       case when bool_or(offset_seconds is not null) then array_agg(offset_seconds order by track_index) end,
       case when bool_or(recording_id is not null) then array_agg(recording_id order by track_index) end,
       case when bool_or(isrc is not null) then array_agg(isrc order by track_index) end,
       case when bool_or(deezer_track_id is not null) then array_agg(deezer_track_id order by track_index) end,
       case when bool_or(artist_id is null or raw_artist_name is distinct from artist_name)
            then array_agg(case when artist_id is null or raw_artist_name is distinct from artist_name
                                then raw_artist_name end order by track_index) end,
       case when bool_or(artist_id is null and normalized_artist_name is not null)
            then array_agg(case when artist_id is null then normalized_artist_name end order by track_index) end
from broadcast
group by radio_episode_id;
create index radio_tracklists_artists_gin on radio_tracklists using gin (artist_ids);
create index radio_tracklists_pending_gin on radio_tracklists using gin (pending_keys) where pending_keys is not null;

-- D2 --------------------------------------------------------------------------

insert into radio_tracklists_d2
select radio_episode_id, artist_ids, offsets, recording_ids, isrcs, deezer_ids, raw_artists, pending_keys
from radio_tracklists;
create index radio_tracklists_d2_artists_gin on radio_tracklists_d2 using gin (artist_ids);
create index radio_tracklists_d2_pending_gin on radio_tracklists_d2 using gin (pending_keys) where pending_keys is not null;

-- D3 --------------------------------------------------------------------------

insert into artist_numbers (artist_id)
select distinct artist_id from broadcast where artist_id is not null order by 1;

insert into radio_tracklists_d3
select t.radio_episode_id,
       (select array_agg(n.n order by u.i)
        from unnest(t.artist_ids) with ordinality u(a, i)
        left join artist_numbers n on n.artist_id = u.a),
       t.titles, t.offsets, t.recording_ids, t.isrcs, t.deezer_ids, t.raw_artists, t.pending_keys
from radio_tracklists t;
create index radio_tracklists_d3_artists_gin on radio_tracklists_d3 using gin (artist_ns);
create index radio_tracklists_d3_pending_gin on radio_tracklists_d3 using gin (pending_keys) where pending_keys is not null;

-- D1i: D1 plus an ISRC lookup ("where was this recording played"), which no
-- live reader has today. Built as an index only; its size is reported apart.

create index radio_tracklists_isrcs_gin on radio_tracklists using gin (isrcs) where isrcs is not null;

-- D1z: D1 with every row compressed. Postgres compresses a row only once it
-- passes toast_tuple_target (2 KB by default); lowering it to the minimum
-- makes almost every episode's arrays compress, with lz4.

create table radio_tracklists_d1z (like radio_tracklists including defaults) with (toast_tuple_target = 128);
alter table radio_tracklists_d1z add primary key (radio_episode_id);
alter table radio_tracklists_d1z alter column titles set compression lz4,
                                 alter column raw_artists set compression lz4,
                                 alter column artist_ids set compression lz4,
                                 alter column offsets set compression lz4,
                                 alter column isrcs set compression lz4,
                                 alter column deezer_ids set compression lz4;
insert into radio_tracklists_d1z select * from radio_tracklists;
create index radio_tracklists_d1z_artists_gin on radio_tracklists_d1z using gin (artist_ids);
create index radio_tracklists_d1z_pending_gin on radio_tracklists_d1z using gin (pending_keys) where pending_keys is not null;

-- E ---------------------------------------------------------------------------

insert into artist_postings
select artist_id,
       array_agg(radio_episode_id order by radio_episode_id, track_index),
       array_agg(track_index::int2 order by radio_episode_id, track_index)
from broadcast
where artist_id is not null
group by artist_id;

vacuum analyze;
