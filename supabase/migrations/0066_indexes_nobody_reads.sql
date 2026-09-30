-- Indexes that repeat another or are not read, about 34 MB on a database the
-- free plan caps at 500.
--
-- Scan counts are pg_stat_user_indexes from 2026-08-25 to 2026-09-29, five
-- weeks of the app and every worker lane.
--
--   music_relationships_from_idx      15.7 MB     2,618 scans
--     (from_entity_type, from_entity_id, relationship_type) is a prefix of the
--     unique edge index, (from_entity_type, from_entity_id, to_entity_type,
--     to_entity_id, relationship_type), which took 116 million scans. A node's
--     edges are few enough that filtering the type after the prefix costs
--     nothing.
--
--   external_ids_pkey                   6.2 MB         0 scans
--   artwork_pkey                        2.6 MB         1 scan
--     Nothing references either `id` or looks a row up by it. Each table
--     already has a unique natural key -- the one every lookup and upsert
--     uses -- so that becomes the primary key and the surrogate's index goes.
--     The `id` columns stay.
--
--   artists_normalized_name_idx         3.4 MB   370,402 scans
--   labels_normalized_name_idx          1.5 MB        15 scans
--     Each duplicates `*_normalized_name_prefix_idx` on the same column. That
--     one is text_pattern_ops, whose operator class includes `=`, so equality
--     lookups move over to it; it is already the busier of the two.
--
--   labels_name_trgm_idx                2.9 MB         0 scans
--     Label search is `normalized_name like k% or name ilike %q%` over 41k
--     rows, which the planner answers with a scan whether this exists or not.
--
--   music_relationships_evidence_idx    2.1 MB         2 scans

drop index if exists public.music_relationships_from_idx;
drop index if exists public.music_relationships_evidence_idx;
drop index if exists public.artists_normalized_name_idx;
drop index if exists public.labels_normalized_name_idx;
drop index if exists public.labels_name_trgm_idx;

-- One statement per table, so there is no moment without a unique key for a
-- concurrent upsert to miss.
alter table public.external_ids
    drop constraint external_ids_pkey,
    drop constraint external_ids_provider_entity_type_external_id_key,
    add constraint external_ids_pkey primary key (provider, entity_type, external_id);

alter table public.artwork
    drop constraint artwork_pkey,
    drop constraint artwork_entity_type_entity_id_key,
    add constraint artwork_pkey primary key (entity_type, entity_id);
