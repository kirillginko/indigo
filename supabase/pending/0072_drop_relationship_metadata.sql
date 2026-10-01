-- NOT YET A MIGRATION. Held outside supabase/migrations on purpose.
--
-- Run after 0071 is live AND every row has been converted:
--
--   select count(*) from public.music_relationships
--   where episode_count is null and metadata is not null;      -- must be 0
--
-- Converting is a batched UPDATE with a plain VACUUM between batches, run
-- statement by statement (a migration cannot VACUUM).
--
-- updated_at is preserved. `touch_updated_at` stamps now() on every UPDATE, and
-- `enrichment_status` and the writer both read that column; a storage change
-- must not make 353k relationships look newly changed. So each batch is one DO
-- block, which is one transaction, that disables exactly that trigger, copies
-- the old value back explicitly, and turns the trigger on again. ALTER TABLE
-- ... DISABLE TRIGGER takes SHARE ROW EXCLUSIVE, so a concurrent writer (the
-- rebuild, merge_artist_halves) waits for the batch instead of slipping a write
-- past the disabled trigger; if the batch fails the trigger comes back with the
-- rollback.
--
--   do $$
--   begin
--       alter table public.music_relationships
--           disable trigger music_relationships_touch_updated_at;
--       with b as (
--           select id from public.music_relationships
--           where episode_count is null and metadata is not null
--           limit 20000 for update skip locked)
--       update public.music_relationships m
--       set episode_count = (m.metadata->>'episodes')::smallint,
--           metadata = null,
--           updated_at = m.updated_at
--       from b where m.id = b.id;
--       alter table public.music_relationships
--           enable trigger music_relationships_touch_updated_at;
--   end $$;
--   vacuum public.music_relationships;
--
-- Before the first batch and after the last, compare
--
--   select md5(string_agg(id::text || updated_at::text, ',' order by id))
--   from public.music_relationships;
--
-- Run both between rebuilds (cron 23 */3 * * *): a rebuild legitimately moves
-- updated_at on the edges whose evidence changed. After the last batch confirm
-- the trigger is back: select tgenabled from pg_trigger
-- where tgname = 'music_relationships_touch_updated_at'; -- 'O'
--
-- One side effect remains: almost no update here can be HOT (the page has no
-- room for both versions), so each batch adds index entries to all six indexes.
--
-- This file removes the fallback from the reader and the writer, then drops the
-- column. The drop is a catalog change; the 19 MB is returned only when the
-- table is next rewritten (see the estimate).

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
           mr.evidence_count, mr.confidence, mr.episode_count::int as episodes
    from public.music_relationships mr
    where mr.from_entity_type = 'artist' and mr.from_entity_id = p_artist_id
      and mr.source like 'radio%'
    union all
    select mr.relationship_type, mr.from_entity_type, mr.from_entity_id,
           mr.evidence_count, mr.confidence, mr.episode_count::int
    from public.music_relationships mr
    where mr.to_entity_type = 'artist' and mr.to_entity_id = p_artist_id
      and mr.source like 'radio%'
)
select
    edge.relationship_type, edge.kind, edge.other,
    coalesce(rs.title, a.name), rs.station, rs.provider, rs.external_id,
    edge.evidence_count, edge.confidence,
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

-- rebuild_radio_dig_edges(): 0071's body with one change, in `changed`:
--     and (m.confidence, m.evidence_count, m.episode_count)
--         is distinct from (w.confidence, w.evidence_count, w.episode_count)
-- and `metadata = null,` removed from its SET list. (Pasted in full when this
-- is promoted, so the migration stands alone.)

alter table public.music_relationships drop column metadata;
