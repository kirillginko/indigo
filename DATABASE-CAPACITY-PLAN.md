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

### C. Job retention — corrected (done 2026-10-12, 0079)

The audit's premise was wrong: finished jobs have been kept **two** days
since 0047, not seven, and the queue is at steady state (~3 days of churn
between nightly sweeps). There is nothing to reclaim. What the approval's
condition pointed at was real, though: failed jobs were swept after the same
two days. 0079 keeps **failed jobs (with their errors) for 14 days** and
finished jobs for 2, as before. A few hundred rows; no space effect.

### D. Archive search index — ~5 MB

`reindex index concurrently public.radio_appearances_archive_search_trgm;`
after B (it needs ~19 MB of temporary room).

### Expected result

| | MB |
|---|---|
| Now | 497 |
| A | −0.4 |
| B | −80 to −85 |
| C | 0 (corrected, see above) |
| D | −5 |
| **After** | **≈ 405–410** |

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

## 6. Progress (2026-10-12)

| | Status | Commit |
|---|---|---|
| A — two never-scanned indexes | **Done.** Final check: 0 scans since statistics began (2026-08-25), no constraint, no dependants; the episode list uses `radio_episodes_show_idx`; nothing filters shows by station. Freed 424 kB. | `cf026e2` (0077) |
| B1 — single adjacencies on demand | **Done and validated** (below). Frees nothing by itself. | `f89cccf` (0078) |
| C — job retention | **Done** as corrected above. | `5b0081d` (0079) |
| B2 — deletion and rewrite | Not executed. Readiness below. | — |
| D — archive index | Deferred until after B2. | — |

Note on units: `pg_database_size` is 520.9 million bytes = **496.8 MiB**.
The project has not gone read-only above 500 million bytes, so the limit is
500 MiB (524.3 million bytes), and the headroom is ~3.2 MiB. All figures
here are MiB.

### B1 validation

`Scripts/b1-capture.py` captured all four readers for 60 artists sampled by
radio popularity (12 each: the most played — John Coltrane 250 appearances,
Miles Davis 231, Sun Ra 228 — and the 5th, 25th, 50th and 95th percentiles)
plus the pilot's 16 starting artists, before and after deployment
(`supabase/diagnostics/capacity/b1/`).

- **Whole neighbour sets, no page limit:** identical for all 60 artists —
  2,134 neighbours under both rules — except 84 stored edges whose pair is no
  longer adjacent in any episode (stale), which are no longer shown
  (`b1/fullset.sql`).
- **The DIG page reader** (`artist_radio_relations`, ≤ 200 rows): 46 of 60
  pages identical; the 14 others are the most played artists, where single
  adjacencies tie at (evidence 1, confidence 0.65) under the 200-row limit
  and which tied rows are kept was arbitrary before and after; plus stale
  edges dropped.
- **`dig_radio_for_artists`**: 52 of 60 identical; the rest the same tie
  under its limit, and stale edges.
- **`knowledge_answers` / `explore_knowledge`** (76 starting points each):
  56 identical; every one of the 94 differing edges (by row) is a stale
  stored edge. No current neighbour lost, none invented.
- **`knowledge_cut`** (frozen pilot set): `ok`, 24/163; 355 nearby edges vs
  335 in the October 11 generation — 10 stale pairs dropped, 8 the same rows
  renamed in the catalogue since ("Young Thug" → "YOUNG THUG", "Björk" →
  "Bjork"), 38 adjacencies new since then. Future generations keep their
  radio relationships.
- **Timing** (warm, anon): `explore_knowledge` batches unchanged (median
  110–180 ms vs 105–131 before). The DIG page reader: median and obscure
  artists 1–6 ms warm, ≤ 70 ms cold; **the most played artists 14–82 ms warm
  (was 3–9 ms) and 0.4–1.9 s on a cold first call** (Coltrane 1.9 s, Sun Ra
  1.15 s). Inside anon's 3 s, but a real cold-cache cost on the busiest pages;
  the first call of the heaviest `explore_knowledge` batch was 2.3–3.4 s cold
  (the app retries a timeout once). Remedy below.
- **Rollback**: `b1/rollback-0078.sql` restores the five functions exactly.

### B2 readiness

| Check (from the approval) | Status |
|---|---|
| B1 against real pages, popular and obscure, all four readers | Done (above) |
| `knowledge_cut`, future generations and the backend shadow keep radio relationships | Done (above) |
| Deletion removes nothing unreconstructable | **Measured catalogue-wide** (`b2-reconstructable.sql`, 16 slices): of 196,044 stored single adjacencies, **193,545 (98.7%) are reproduced exactly** from `radio_appearances`; **2,499 (1.3%) are stale** — the pair is adjacent in no episode now (appearances re-resolved since). None became stronger unseen. The 2,499 are already hidden by B1; they are exported before deletion (below). |
| Peak disk, including rewrite, indexes, temporary files, WAL, concurrent growth | Below |
| `pgstattuple` | Proposed, needs approval (an extension; catalog-only) |
| Backup and recovery | Procedure below; the export is read-only and runs at the start of the window |
| Pause/resume and integrity checks | Runbook below |
| Free more before the rewrite | Yes — drop the primary key too (below) |

**Peak, revised to free more first.** Current: database 496.8 MiB;
`music_relationships` heap 73.9, `edge_idx` 39.0, `pkey` 13.9, `to_idx`
8.8. After the deletion the table keeps 187,022 rows; estimated rewritten
heap ~26 MiB (≈140 bytes a row without `metadata`), rebuilt `pkey` ~6,
`edge_idx` ~17, `to_idx` ~5.

| Step | Database |
|---|---|
| Start | 496.8 |
| Drop `edge_idx`, `to_idx` **and the primary key** (constraint dropped, rows untouched; nothing writes in the window) | ~435 |
| Rewrite (`alter … using`): new heap only, no index to build | **peak ~461**, then ~387 |
| Recreate primary key, `edge_idx` (unique), `to_idx`; `analyze` | ~415 |

Peak margin ~39 MiB (vs ~19 with the primary key kept).

- **Temporary files** (sorts for the index builds) live in `pgsql_tmp`,
  outside the database directory `pg_database_size` measures; index builds
  run one at a time after the heap is rewritten and the old one released.
- **WAL**: the rewrite and builds write roughly their own size (~55 MiB) of
  WAL. WAL is not part of the database size (it was 128 MiB at the audit);
  it is recycled at checkpoints.
- **Concurrent growth**: in the window, the cron jobs that write
  `music_relationships` are paused; radio ingest (`discover_*`, the drains)
  writes `radio_appearances`/`radio_episodes` at ~7,000 jobs a day — well
  under 1 MiB in ten minutes. They can be paused too for a strict bound.
- `pgstattuple` (if approved) would replace the "~140 bytes a row" estimate
  with measured tuple and index density.

**Backup and recovery** (Supabase Free has no downloadable backups or
point-in-time recovery, so the backup is ours):

1. Export, read-only, in slices: every row B2 deletes (196,044 single
   adjacencies, all columns) and `id, metadata` for every row whose
   `episode_count` is still null — ~60 MB of JSON, kept outside the repo.
2. Verify: load it into the throwaway Postgres (`Scripts/test-migrations.sh`'s
   schema) and compare row counts and an `md5(string_agg(id‖…))` per slice
   with live.
3. Restore path, if needed after B2: re-insert from the export (the rows
   have their ids; `on conflict do nothing`), then re-run the rebuild once.
   Needs ~70 MiB of room, which B2 creates.
4. Before step 1 of the window, rollback is a no-op; the rewrite is one
   transaction (fails → nothing changed); index builds can be re-run.

**Window runbook** (statement by statement, ~10 minutes):

1. Export and verify the backup (above).
2. Pause cron: `indigo-rebuild-edges`, `indigo-merge-split-artists`,
   `indigo-resolve-radio` (and, for a strict bound, the drains).
3. Record: row counts by type; `md5` of `id‖updated_at‖evidence_count` for
   `played_by` and for `radio_neighbor` with evidence ≥ 2; the B1 capture.
4. Delete `radio_neighbor` with `evidence_count = 1`.
5. Drop `music_relationships_to_idx`, `music_relationships_edge_idx`, and the
   primary key constraint.
6. Rewrite: `alter table music_relationships alter column episode_count type
   smallint using coalesce(episode_count, (metadata->>'episodes')::smallint),
   alter column metadata type jsonb using null;`
7. Recreate the primary key, `edge_idx` (unique, same definition), `to_idx`;
   `analyze`.
8. Verify: the md5s and counts from step 3 match; zero stored single
   adjacencies; `episode_count` set wherever `metadata` had episodes; the B1
   capture identical to step 3's; `pg_database_size`.
9. Resume cron; watch one rebuild (00:23/03:23… UTC) for errors and size.

**Cold-call remedy (after B2, separately):** an index covering the
adjacency lookup — `radio_appearances (artist_id) include (radio_episode_id,
track_index)` and `(radio_episode_id, track_index) include (artist_id)` —
would make the derivation index-only and remove most of the cold cost on the
busiest pages, for ~8 MiB. It does not fit before B2.

## 7. B2 pre-execution checks (2026-10-13) — not executed

`pgstattuple` installed (0080; +8 kB; revoked from anon and authenticated).

### Density, measured

| | Now | Measured |
|---|---|---|
| Heap | 73.9 MiB | 95.5% live tuples, 0.68% free, 193 B per row of which `metadata` 52.4 B |
| Primary key | 13.9 | leaf density 75%, fragmentation 50% |
| `edge_idx` | 39.0 | leaf density 73%, fragmentation 50% |
| `to_idx` | 8.8 | leaf density 84%, fragmentation 50% |

### Dropping the primary key: what depends on it

- **Foreign keys**: none reference `music_relationships`.
- **Constraints**: three CHECKs and the primary key; nothing else uses it.
- **Replication**: the table is in no publication (`supabase_realtime` is
  not all-tables); replica identity `default` has no effect.
- **Upserts**: the rebuild's `on conflict do nothing` uses `edge_idx`
  (unique), recreated in step 7; no writer runs in the window.
- **Writers**: exactly two functions write the table —
  `rebuild_radio_dig_edges` (cron `indigo-rebuild-edges`, job 6, `23 */3 * * *`)
  and `merge_artist_halves` via `merge_split_artists` (cron
  `indigo-merge-split-artists`, job 34, `23 4 * * *`). The worker's
  `rebuild_dig_edges` job type was retired by 0068: no function enqueues it
  (one old failed row remains). Both cron jobs are owned by `postgres`, and
  `cron.alter_job(…, active := false)` (pg_cron 1.6.4) pauses them
  reversibly.
- **App code**: nothing reads or writes the table directly; it reads through
  `artist_radio_relations` and `dig_radio_for_artists`. On any error, the DIG
  artist page's radio block shows nothing (the rest of the page is local and
  already drawn) and DIG's radio block is empty (`try?`); both load again on
  the next open.

### Rehearsal (`Scripts/b2-rehearsal.sh`, output in `b2/rehearsal-2026-10-13.txt`)

A throwaway Postgres 17 built from every migration, with the live table
restored from the backup:

- **Backup** (`Scripts/b2-export.py`): all **383,066 rows, every column**
  (metadata and timestamps included), in 16 slices with row counts and md5s
  taken in the same statement, plus the table definition (columns,
  defaults, constraints, indexes, trigger, RLS policy, grants). Exported in
  71 s, 105 MB, kept outside git (`backups/`, excluded locally).
- **Restore**: all 16 slices match live exactly — rows and md5.
- **Sequence**, exactly as the runbook: delete 196,044 single adjacencies;
  drop `to_idx`, `edge_idx` and the primary key; one `alter … using`
  rewrite; recreate primary key, `edge_idx` (unique), `to_idx`; analyze.

| Step | Time (local) | Database |
|---|---|---|
| Start | | 147.6 (table 138.3) |
| Checksums | 209 ms | 147.6 |
| Delete | 121 ms | 147.6 |
| Drop three indexes | 29 ms | 86.7 |
| Rewrite | 263 ms | 37.8 |
| Primary key | 84 ms | 43.5 |
| `edge_idx` | 191 ms | 58.9 |
| `to_idx` | 160 ms | 60.6 |

- **Peak = the starting size.** Sampled every 50 ms, the database never
  exceeded where it began: the drops free 61 MiB before the rewrite needs
  its 28.5 MiB copy.
- **After**: table 138.3 → **51.3 MiB** (heap 28.5, `edge_idx` 15.4,
  primary key 5.6, `to_idx` 1.7). Saved **87.0 MiB**.
- **Integrity**: kept rows identical (id, endpoints, type, count,
  confidence, `updated_at`, source); episode counts carried over from the
  document for the 352,221 rows still holding them there; no stored single
  adjacency or metadata left; primary key, unique `edge_idx`, trigger and RLS
  present; the rebuild runs afterwards.
- **Rollback**: the 196,044 deleted rows restored from the backup in 3.9 s,
  every id back.

### Projection for live

| | MiB |
|---|---|
| Start (2026-10-13) | 496.8 |
| Peak | **496.8** (no step grows the database past its start; highest point after the drops: ~464) |
| After | **≈ 410** (−87) |

Local times will not hold on Supabase's shared CPU; allowing 10–20× the
whole sequence is ~10–20 s, of which the rewrite (the only step that blocks
reads) is ~3–5 s.

### Quota and abort thresholds

The quota is the size of the one database (`postgres`): `pg_database_size`
= 496.8 MiB. It has stood above 500 million bytes without the project going
read-only, so the limit is 500 MiB. The dashboard's own figure should be
read once before the window (it is not visible from here).

- **Before step 4**: database ≤ 498.0 MiB; both cron jobs inactive; neither
  running (`cron.job_run_details`); no `rebuild_dig_edges` job pending; a
  fresh export taken in the window and verified slice by slice; not within
  10 minutes of :23 past a third hour or of 04:23 UTC. Otherwise stop.
- **After step 5**: the database must have dropped by ≥ 55 MiB. Otherwise
  stop: recreate the indexes (nothing is lost), resume cron.
- **Step 6** is one transaction; if it fails, nothing changed: recreate the
  indexes, resume.
- **After step 7**: every integrity check must pass. If not: keep cron
  paused, restore the deleted rows from the export (rehearsed), investigate.
- **Final**: expected ≈ 410 MiB; above 420 means something else grew —
  investigate before resuming.

