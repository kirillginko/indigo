# Database capacity: audit and cleanup proposal

*2026-10-12. Read-only audit; nothing has been changed. Every operation below
needs explicit approval, one by one. Queries and outputs:
`supabase/diagnostics/capacity/`.*

Supabase Free, staying on Free. Target: reclaim 50–100 MB of **physical**
database storage without risky rewrites, data loss or behaviour changes.

## 1. Where the 497 MB is

`pg_database_size` = **497 MB** (limit 500). By schema: `public` 479 MB,
`pg_catalog` 11, `cron` 4.7, `auth` 1.1, everything else under 1.
In `public`, tables 255 MB and **indexes 223 MB**.

| Table | Heap | Indexes | Live rows | Dead rows |
|---|---|---|---|---|
| music_relationships | 73.9 | 61.7 | 383,066 | 2,020 |
| radio_appearances | 59.0 | 57.2 | 256,431 | 8,722 |
| releases | 26.4 | 29.2 | 176,933 | 165 |
| external_ids | 26.7 | 23.7 | 215,772 | 33 |
| artists | 14.5 | 22.4 | 119,804 | 8,097 |
| scene_members | 11.8 | 11.7 | 84,161 | 259 |
| artwork | 18.7 | 4.3 | 91,140 | 0 |
| radio_episodes, recordings, enrichment_jobs, labels, cron.job_run_details | 4–10 each | | | |

**There is little conventional bloat.** Dead tuples are low everywhere; the
CLI's bloat estimate finds ~30 MB of waste in total, most of it in one
trigram index (`radio_appearances_archive_search_trgm`, ~5 MB) and small
tables. `VACUUM` would not help: it makes space reusable but never shrinks
the files that count against the limit. Physical space comes back only by
**dropping an index** (immediate) or **rewriting a table** (`VACUUM FULL`,
`ALTER TABLE … USING`, `pg_repack` — available, not installed).

**A rewrite needs a second copy of what it rewrites, at the same time.** At
497/500, rewriting `music_relationships` as it is (136 MB with indexes)
would briefly need ~55 MB more than we have and could put the project into
read-only mode. So the one big win below is sequenced to keep the peak under
the limit.

## 2. What is redundant

| Finding | Size | Redundant? |
|---|---|---|
| **196,044 of 206,244 `radio_neighbor` edges have `evidence_count = 1`**: two artists played next to each other once, in one episode | ~half of `music_relationships` (≈ 70–80 MB with its indexes) | **Yes, derivable.** The rebuild computes them from `radio_appearances` (same episode, next track) every three hours; the same query answers them on demand. Removing them leaves **0** artists without a route (every one keeps a show or a release). |
| `music_relationships.metadata` | 19 MB | **Yes.** `appearances`/`adjacencies` copy `evidence_count` on every row; `episodes` belongs in `episode_count` (0071 began this; `supabase/pending/0072` held the rest "until a table rewrite is affordable") |
| `enrichment_jobs` finished rows kept 7 days | ~19,000 rows, 7.5 MB | Mostly. A day or two is enough for diagnostics |
| `radio_appearances_archive_search_trgm` | 19 MB, ~5 MB internal waste | Waste only (the index is used by archive search) |
| `radio_episodes_aired_at_idx`, `radio_shows_station_idx` | 0.4 MB | Never scanned (39 days of statistics) |
| `recordings_isrc_idx`, `recordings_musicbrainz_id_idx`, `recordings_deezer_track_idx`, `radio_appearances_pending_release_idx` | 2.5 MB | Unscanned, but they belong to the paused Deezer/track lanes (0065/0069): **keep** until that lane's future is decided |
| `external_ids.source_url` for Discogs | 2.3 MB | Derivable, but reclaiming it means rewriting a 50 MB table: **not worth it** |
| Trigram search indexes (`releases_title_trgm_idx` 12 MB, `artists_name_trgm_idx` 9.7 MB) | 22 MB | **Not redundant**: `search_catalog` uses them |
| `artwork` recorded misses (51,182 rows) | part of 23 MB | **Not redundant**: they stop the portrait lane re-asking |

### The single adjacencies, checked

- On demand, the busiest artist on the radio (John Coltrane, 106 neighbours)
  takes **76–133 ms**, all from cache (`derive-adjacency.sql`); typical
  artists are a small fraction of that — inside anon's 3 s.
- Derived and stored agree for Coltrane except that **2 of the 108 stored
  edges no longer exist in the appearances**: the rebuild inserts and
  updates but never deletes, so stored neighbours go stale. Derived ones
  cannot.
- Readers to change so nothing disappears from DIG: `artist_radio_relations`
  (the DIG artist page's radio section), `dig_radio_for_artists`,
  `explore_knowledge`, `knowledge_answers`; the writer:
  `rebuild_radio_dig_edges` (materialise only `adjacencies ≥ 2`).

## 3. Proposed operations

In order. Each line is one approval.

### A. Two never-used indexes — ~0.4 MB, no risk

```sql
drop index concurrently if exists public.radio_episodes_aired_at_idx;
drop index concurrently if exists public.radio_shows_station_idx;
```

### B. Radio single adjacencies on demand + the metadata column — **≈ 80–85 MB**

**B1 (migration, no space change):** the writer stops materialising
single adjacencies; the four readers return stored neighbours (`≥ 2`) plus
single adjacencies derived from `radio_appearances`, with the same shapes,
reasons and confidence formula the rebuild uses. Tested in the throwaway
database (same output as today for fixtures, on demand) and on live
read-only (for a sample of artists, the DIG radio section's rows before vs.
after: same artists, same counts, minus stale edges). Deployed and watched
for one rebuild cycle before B2.

**B2 (maintenance window, ~10 minutes, statement by statement):**

| Step | Operation | DB size after |
|---|---|---|
| 0 | Pause cron jobs that write `music_relationships` (`indigo-rebuild-edges`, `indigo-merge-split-artists`, `indigo-resolve-radio`); record row counts and an `md5` of `id‖updated_at` for edges with `evidence_count ≥ 2` and for `played_by` | 497 |
| 1 | `delete from music_relationships where relationship_type = 'radio_neighbor' and evidence_count = 1` (no growth: a delete adds no index entries) | 497 |
| 2 | `drop index music_relationships_edge_idx; drop index music_relationships_to_idx;` (frees ~48 MB immediately; nothing writes during the window) | ~449 |
| 3 | One rewrite that keeps only live rows, nulls the duplicate document and fills `episode_count` — triggers do not fire, so `updated_at` is preserved: `alter table music_relationships alter column episode_count type smallint using coalesce(episode_count, (metadata->>'episodes')::smallint), alter column metadata type jsonb using null;` | **peak ~481**, then ~393 |
| 4 | `create unique index music_relationships_edge_idx …` (same definition); `create index music_relationships_to_idx …`; `analyze` | ~415 |
| 5 | Verify: the md5s and counts from step 0 match for the rows kept; zero `radio_neighbor` with evidence 1; `episode_count` non-null wherever `metadata` had episodes; DIG radio sections for the sample artists identical to B1's check | |
| 6 | Resume the cron jobs | |

Peak stays **~19 MB under** the limit. Every step is transactional except
the index builds, which can simply be re-run (the data is unique by
construction). Later, `drop column metadata` (a catalog change; pending
0072's reader/writer cleanup).

**Rollback:** before step 1, nothing has changed. After it, re-running the
old rebuild re-materialises the single adjacencies (but only once there is
room for them again).

### C. Finished jobs: keep two days — ~4 MB

Shorten `prune_spent_rows`' retention for `done` jobs from 7 days to 2, then
`vacuum full public.enrichment_jobs` (a 7.5 MB table; the copy is small).
Failed jobs keep their longer retention.

### D. Archive search index — ~5 MB

`reindex index concurrently public.radio_appearances_archive_search_trgm;`
after B (it needs ~19 MB of temporary room).

### Expected result

| | MB |
|---|---|
| Now | 497 |
| A | −0.4 |
| B | −80 to −85 |
| C | −4 |
| D | −5 |
| **After** | **≈ 400–405** |

## 4. Not proposed

- `VACUUM FULL` of large tables as they are, `pg_repack`, or any rewrite
  before B2's index drops — peak space.
- Dropping search indexes — DIG search uses them.
- Dropping recorded portrait misses — they prevent re-fetch loops.
- The paused lanes' indexes — decide with the lanes.
- Rewriting `external_ids` for 2.3 MB.

## 5. To decide

1. Approve A.
2. Approve B1 (code, no space change), then B2's window separately.
3. Approve C and D.
4. Optional: install `pgstattuple` (an extension; catalog-only) to measure
   exact index fill before B2, which would tighten the peak estimate.
