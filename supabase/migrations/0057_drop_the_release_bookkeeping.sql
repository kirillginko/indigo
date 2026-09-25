-- The rows 0056 made redundant.
--
-- Pushed only after the functions that stopped writing and reading them are
-- deployed; before that, the old worker would look a release up in
-- `external_ids`, find nothing, and file it a second time.
--
-- Each delete keeps anything the new columns do not already cover: an
-- `external_ids` row goes only when its release carries the same Discogs id,
-- and a cache row only when its release carries a stamp. The backfill runs
-- again first, for whatever the old code wrote after 0056.
--
-- ~152,000 of each: about 45 MB of `external_ids` with its indexes and 38 MB
-- of `metadata_cache`, freed for reuse -- the file only shrinks after a
-- VACUUM FULL of each, which is run by hand, not here.
--
-- Safe to re-run.

-- Stragglers only: the bulk was filled by hand in batches (see 0056).
select public.adopt_release_discogs_ids(5000);

-- A release the old worker cached again after its row was filled.
update public.releases r
set discogs_cached_at = mc.fetched_at
from public.metadata_cache mc
where mc.provider = 'discogs' and mc.resource_type = 'release'
  and mc.resource_id = r.discogs_id
  and mc.payload_path like 'r2:%'
  and (r.discogs_cached_at is null or r.discogs_cached_at < mc.fetched_at);

delete from public.external_ids x
using public.releases r
where x.provider = 'discogs' and x.entity_type = 'release'
  and r.id = x.entity_id
  and r.discogs_id = x.external_id;

delete from public.metadata_cache mc
using public.releases r
where mc.provider = 'discogs' and mc.resource_type = 'release'
  and r.discogs_id = mc.resource_id
  and r.discogs_cached_at is not null;
