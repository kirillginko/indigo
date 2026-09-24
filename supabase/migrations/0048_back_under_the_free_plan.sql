-- Getting the database back toward the free plan's 500 MB.
--
-- At 844 MB. Nothing in it is a large file -- images are links, and the
-- release payloads already live in Storage (0036) -- so this removes rows
-- nothing reads, and stops a backfill that was adding more of them.
--
--   * 200,000 label -> programme edges (source 'radio.via_artist'), about
--     90 MB with their share of the indexes. No function and no screen reads
--     them: artist_radio_relations reads edges that touch an artist, DIG reads
--     artist -> artist, and a label page's radio summary is computed from the
--     appearances on the spot (label_radio_summary). The hourly rebuild no
--     longer makes them.
--
--   * 150,000 release artwork rows, about 57 MB. The app reads artwork only
--     for artist portraits (portraits_for_artists); a release's cover is in
--     its cached payload. discogs.ts no longer writes them.
--
--   * The shelf backfill: every artist's whole discography, walked ahead of
--     anyone asking, at about 2.4 KB of database per release across five
--     tables. 26,641 releases were queued. Stopped, and its queue cleared. A
--     page's own request still goes through the release-cache lane, which is
--     left running.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.rebuild_radio_dig_edges()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

    -- No label -> programme edges. Nothing read them (0048), and at 200,000
    -- rows they were the largest thing in the graph.
    return written;

end $function$;

delete from public.music_relationships
where from_entity_type = 'label'
  and to_entity_type = 'radio_show'
  and relationship_type = 'played_by';

delete from public.artwork where entity_type = 'release';

-- The backfill, not the lane: `indigo-drain-release-cache` also serves the
-- releases a page asks for, at priority 1, and keeps running.
create or replace function public.schedule_release_cache()
returns text
language plpgsql
as $$
begin
    if public.has_function('cron', 'schedule') then
        perform cron.unschedule(jobname) from cron.job
        where jobname in ('indigo-shelf-releases', 'indigo-drain-shelves');
    end if;
    return 'shelf backfill paused (0048)';
end $$;

select public.schedule_release_cache();

delete from public.enrichment_jobs
where status = 'pending'
  and priority <= 0
  and job_type in ('cache_discogs_release', 'cache_discogs_shelf');
