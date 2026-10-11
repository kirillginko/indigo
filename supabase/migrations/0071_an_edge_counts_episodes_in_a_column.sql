-- An edge counts its episodes in a column, not in a jsonb document.
--
-- `music_relationships.metadata` is 19 MB, 57 bytes on each of 353,347 rows,
-- and every row holds one of two shapes:
--
--   played_by       {"episodes": e, "appearances": a}
--   radio_neighbor  {"adjacencies": a, "episodes": e}
--
-- Measured 2026-10-01 on all of them:
--
--   * `appearances` equals `evidence_count` on all 163,100 played_by rows, and
--     `adjacencies` equals it on all 190,247 radio_neighbor rows. The writer
--     stores the same number twice, so those two keys carry nothing.
--   * `episodes` is the only one with no column. It is a distinct count of
--     broadcasts, 1 to 16, never above `evidence_count`.
--
-- So the lossless replacement is one smallint, `episode_count`.
--
-- The reader keeps returning a `metadata` object in the same two shapes, built
-- from the columns, so the app (Catalog.RadioRelation.Evidence) needs no change
-- and builds already installed keep working.
--
-- This migration rewrites no rows. Adding a nullable column is a catalog change.
-- The writer compares `episode_count`, falling back to the old document for a
-- row that has not been converted, so a row whose evidence has not moved is
-- not rewritten, and the first rebuild does not touch all 353,347 rows at once
-- (the rolled-back 152k update of 0048's era put the database over 500 MB).
-- A row that did change is written with the column and no document.
--
-- Converting the rest, and dropping the column, is a separate step and is not
-- here: see supabase/pending/0072_drop_relationship_metadata.sql.
--
-- Safe to re-run.

alter table public.music_relationships
    add column if not exists episode_count smallint;

-- ---------------------------------------------------------------------------
-- Reader. Same signature, same columns, same shapes.
-- ---------------------------------------------------------------------------

create or replace function public.artist_radio_relations(
    p_artist_id uuid,
    p_limit integer default 24
)
returns table(
    relationship_type text, entity_type text, entity_id uuid, title text,
    station text, provider text, external_id text, evidence_count integer,
    confidence double precision, metadata jsonb)
language sql
stable
as $function$
with edge as (
    select mr.relationship_type, mr.to_entity_type as kind, mr.to_entity_id as other,
           mr.evidence_count, mr.confidence,
           coalesce(mr.episode_count::int, (mr.metadata->>'episodes')::int) as episodes
    from public.music_relationships mr
    where mr.from_entity_type = 'artist' and mr.from_entity_id = p_artist_id
      and mr.source like 'radio%'
    union all
    select mr.relationship_type, mr.from_entity_type, mr.from_entity_id,
           mr.evidence_count, mr.confidence,
           coalesce(mr.episode_count::int, (mr.metadata->>'episodes')::int)
    from public.music_relationships mr
    where mr.to_entity_type = 'artist' and mr.to_entity_id = p_artist_id
      and mr.source like 'radio%'
)
select
    edge.relationship_type,
    edge.kind,
    edge.other,
    coalesce(rs.title, a.name),
    rs.station,
    rs.provider,
    rs.external_id,
    edge.evidence_count,
    edge.confidence,
    case edge.relationship_type
        when 'played_by' then
            jsonb_build_object('episodes', edge.episodes, 'appearances', edge.evidence_count)
        when 'radio_neighbor' then
            jsonb_build_object('adjacencies', edge.evidence_count, 'episodes', edge.episodes)
    end
from edge
left join public.radio_shows rs on edge.kind = 'radio_show' and rs.id = edge.other
left join public.artists a on edge.kind = 'artist' and a.id = edge.other
order by edge.evidence_count desc, edge.confidence desc
limit greatest(1, least(coalesce(p_limit, 24), 200));
$function$;

-- ---------------------------------------------------------------------------
-- Writer. As 0049/0050, writing `episode_count` instead of the document.
-- ---------------------------------------------------------------------------

create or replace function public.rebuild_radio_dig_edges()
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
set work_mem to '16MB'
as $function$
declare
    written int := 0;
begin
    with wanted as materialized (
        -- Artist -> the programmes that play them.
        select
            'artist'::text as from_entity_type, played.artist_id as from_entity_id,
            'radio_show'::text as to_entity_type, played.radio_show_id as to_entity_id,
            'played_by'::text as relationship_type,
            least(0.95, 0.5 + 0.45 * (1 - 1.0 / (1 + played.episodes)))::double precision as confidence,
            'radio'::text as source,
            played.appearances::int as evidence_count,
            played.episodes::smallint as episode_count
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

        union all

        -- Artist <-> artist, played next to each other in a tracklist. Stored
        -- once under the lower uuid: the relationship is symmetric.
        select
            'artist', near.low, 'artist', near.high,
            'radio_neighbor',
            least(0.9, 0.4 + 0.5 * (1 - 1.0 / (1 + near.adjacencies)))::double precision,
            'radio',
            near.adjacencies::int,
            near.episodes::smallint
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
    ),
    -- Only the edges whose evidence moved. Everything else is left as it is,
    -- unlocked and unwritten. A row not yet converted is compared by the
    -- episode count its document holds, so it counts as unchanged.
    changed as (
        update public.music_relationships m
        set confidence = w.confidence,
            evidence_count = w.evidence_count,
            episode_count = w.episode_count,
            metadata = null,
            updated_at = now()
        from wanted w
        where m.from_entity_type = w.from_entity_type
          and m.from_entity_id = w.from_entity_id
          and m.to_entity_type = w.to_entity_type
          and m.to_entity_id = w.to_entity_id
          and m.relationship_type = w.relationship_type
          and (m.confidence, m.evidence_count,
               coalesce(m.episode_count, (m.metadata->>'episodes')::smallint))
              is distinct from (w.confidence, w.evidence_count, w.episode_count)
        returning 1
    ),
    -- And the ones that did not exist. DO NOTHING, never DO UPDATE: it does
    -- not lock, and a row it finds already there was written by somebody
    -- else a moment ago.
    added as (
        insert into public.music_relationships (
            from_entity_type, from_entity_id, to_entity_type, to_entity_id,
            relationship_type, confidence, source, evidence_count, episode_count)
        select w.from_entity_type, w.from_entity_id, w.to_entity_type, w.to_entity_id,
               w.relationship_type, w.confidence, w.source, w.evidence_count, w.episode_count
        from wanted w
        where not exists (
            select 1 from public.music_relationships m
            where m.from_entity_type = w.from_entity_type
              and m.from_entity_id = w.from_entity_id
              and m.to_entity_type = w.to_entity_type
              and m.to_entity_id = w.to_entity_id
              and m.relationship_type = w.relationship_type)
        on conflict do nothing
        returning 1
    )
    select (select count(*) from changed) + (select count(*) from added) into written;

    return written;
end $function$;
