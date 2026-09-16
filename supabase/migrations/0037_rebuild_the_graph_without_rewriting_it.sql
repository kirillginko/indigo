-- Rebuild the graph without rewriting it.
--
-- `indigo-rebuild-edges` runs `rebuild_radio_dig_edges()` every hour, and all
-- three of its upserts ended `do update set ... updated_at = now()` with no
-- condition. So every one of the ~183,000 edges was written again every hour,
-- whether or not its evidence had moved.
--
-- Postgres writes an update as a new copy of the row and reclaims the old one
-- later, so an hourly rewrite of the whole table holds it at roughly twice its
-- live size. Measured on 2026-09-16: `music_relationships` was vacuumed from
-- 164 MB to 69 MB, and within two hours it was back at 140 MB with bloat of
-- 2.1x -- which hid most of what moving the release cache to Storage (0036)
-- had saved.
--
-- Now an edge is written only when what it says has changed. Rebuilding
-- identical evidence touches nothing, so there is no new copy to reclaim.
--
-- One meaning moves with it: `updated_at` is now when an edge last *changed*,
-- not when a rebuild last passed over it. Nothing reads it -- checked across
-- every migration, both Edge Functions and the app -- and the rebuild never
-- deletes edges by age, so nothing depended on it moving hourly.
--
-- The body is otherwise exactly 0005's, which was confirmed identical to the
-- definition running in production before this was written.
--
-- Safe to re-run.

create or replace function public.rebuild_radio_dig_edges()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    written int := 0;
    touched int;
begin
    -- Artist -> the programmes that play them.
    insert into public.music_relationships (
        from_entity_type, from_entity_id, to_entity_type, to_entity_id,
        relationship_type, confidence, source, evidence_count, metadata)
    select
        'artist', played.artist_id, 'radio_show', played.radio_show_id,
        'played_by',
        least(0.95, 0.5 + 0.45 * (1 - 1.0 / (1 + played.episodes))),
        'radio',
        played.appearances,
        jsonb_build_object('episodes', played.episodes, 'appearances', played.appearances)
    from (
        select ra.artist_id,
               re.radio_show_id,
               count(*) as appearances,
               count(distinct re.id) as episodes
        from public.radio_appearances ra
        join public.radio_episodes re on re.id = ra.radio_episode_id
        where ra.artist_id is not null and re.radio_show_id is not null
        group by ra.artist_id, re.radio_show_id
    ) as played
    on conflict (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type)
    do update set
        confidence = excluded.confidence,
        evidence_count = excluded.evidence_count,
        metadata = excluded.metadata,
        updated_at = now()
    where (music_relationships.confidence, music_relationships.evidence_count,
           music_relationships.metadata)
        is distinct from (excluded.confidence, excluded.evidence_count, excluded.metadata);

    get diagnostics touched = row_count;
    written := written + touched;

    -- Artist <-> artist, played next to each other in a tracklist.
    --
    -- Stored once under the lower uuid rather than in both directions: the
    -- relationship is symmetric, and two rows saying the same thing would each
    -- have to be kept in step. Readers already have an index on either end.
    insert into public.music_relationships (
        from_entity_type, from_entity_id, to_entity_type, to_entity_id,
        relationship_type, confidence, source, evidence_count, metadata)
    select
        'artist', near.low, 'artist', near.high,
        'radio_neighbor',
        least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + near.adjacencies))),
        'radio',
        near.adjacencies,
        jsonb_build_object('adjacencies', near.adjacencies, 'episodes', near.episodes)
    from (
        select
            least(a.artist_id, b.artist_id) as low,
            greatest(a.artist_id, b.artist_id) as high,
            count(*) as adjacencies,
            count(distinct a.radio_episode_id) as episodes
        from public.radio_appearances a
        join public.radio_appearances b
            on b.radio_episode_id = a.radio_episode_id
           and b.track_index = a.track_index + 1
        where a.artist_id is not null
          and b.artist_id is not null
          and a.artist_id <> b.artist_id
        group by least(a.artist_id, b.artist_id), greatest(a.artist_id, b.artist_id)
    ) as near
    on conflict (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type)
    do update set
        confidence = excluded.confidence,
        evidence_count = excluded.evidence_count,
        metadata = excluded.metadata,
        updated_at = now()
    where (music_relationships.confidence, music_relationships.evidence_count,
           music_relationships.metadata)
        is distinct from (excluded.confidence, excluded.evidence_count, excluded.metadata);

    get diagnostics touched = row_count;
    written := written + touched;

    -- Label -> the programmes that play its artists.
    --
    -- Through the artist, not through the recording. The recording-level path
    -- is the one §10 describes and it is the better claim, but it needs
    -- appearances matched to recordings, and almost none are yet. This says
    -- "this show plays artists who release on this label", which is true, and
    -- is marked as such so a stronger derivation can replace it later.
    insert into public.music_relationships (
        from_entity_type, from_entity_id, to_entity_type, to_entity_id,
        relationship_type, confidence, source, evidence_count, metadata)
    select
        'label', played.label_id, 'radio_show', played.radio_show_id,
        'played_by',
        least(0.85, 0.35 + 0.45 * (1 - 1.0 / (1 + played.episodes))),
        'radio.via_artist',
        played.appearances,
        jsonb_build_object(
            'episodes', played.episodes,
            'appearances', played.appearances,
            'artists', played.artists,
            'derivation', 'artist_roster')
    from (
        select roster.label_id,
               re.radio_show_id,
               count(*) as appearances,
               count(distinct re.id) as episodes,
               count(distinct ra.artist_id) as artists
        from public.radio_appearances ra
        join public.radio_episodes re on re.id = ra.radio_episode_id
        -- Distinct, and that is load-bearing. Joining `releases` directly
        -- multiplies every appearance by the number of records the artist has
        -- on the label, so one play by an artist with twelve releases would be
        -- counted as twelve plays.
        join (
            select distinct artist_id, label_id
            from public.releases
            where artist_id is not null and label_id is not null
        ) as roster on roster.artist_id = ra.artist_id
        where ra.artist_id is not null
          and re.radio_show_id is not null
        group by roster.label_id, re.radio_show_id
    ) as played
    on conflict (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type)
    do update set
        confidence = excluded.confidence,
        evidence_count = excluded.evidence_count,
        metadata = excluded.metadata,
        updated_at = now()
    where (music_relationships.confidence, music_relationships.evidence_count,
           music_relationships.metadata)
        is distinct from (excluded.confidence, excluded.evidence_count, excluded.metadata);

    get diagnostics touched = row_count;
    return written + touched;
end $$;
