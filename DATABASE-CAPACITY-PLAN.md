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

## 8. B2 executed (2026-10-13, 00:36–00:40 UTC)

**Quota, as the dashboard counts it.** The dashboard's "Database Size
0.536 / 0.5 GB" is the sum of **all three databases** (`postgres`,
`template0`, `template1`) in **decimal** bytes: 536,238,901 = 520,965,267 +
7,520,783 + 7,752,851. The allowance is 500,000,000 bytes, and the project
was 7% over it while not read-only — so §6's inference that the limit was
500 MiB was wrong. B2's safety did not depend on it (no step grows the
database past its start), and the abort gates are on
`pg_database_size('postgres')`, so they held.

| Step | UTC | Result |
|---|---|---|
| Preflight | 00:36:25 | postgres 496.83 MiB (≤ 498); both jobs active and idle; the 00:23 rebuild finished 00:23:32; no `rebuild_dig_edges` job pending |
| 1 Export | 00:36–00:37 | 383,117 rows, 16 slices, 105 MB, 75 s; **independently verified**: restored into a throwaway Postgres, all 16 slices equal live by rows and md5, and the whole sequence plus rollback re-run on this exact data |
| 2 Pause | 00:38:06 | `cron.alter_job(6/34, active := false)`; both inactive, none running; **live equal to the export**, all 16 slices |
| 3 Checksums | 00:38:25 | 187,073 rows to keep; 196,044 single adjacencies; table 135.61 MiB |
| 4 Delete | | **196,044 deleted**, 187,073 remain; 3.7 s |
| 5 Drop | | `to_idx`, `edge_idx`, primary key; 3.4 s. Measured in a fresh statement (the drops free their files at commit): 496.83 → **435.17 MiB, −61.66 MiB** — gate (≥ 55) **passed** |
| 6 Rewrite | | one transaction, 5.5 s including the CLI round trip; heap 73.95 → **28.5 MiB**; metadata left 0; no lock waiting afterwards |
| 7 Recreate | | primary key 2.5 s, `edge_idx` (unique) 3.0 s, `to_idx` 3.1 s, analyze 2.5 s (each with the round trip); indexes 5.65 / 15.38 / 1.74 MiB |
| 8 Verify | | kept rows **identical** (id, endpoints, type, count, confidence, `updated_at`, source); episode counts **carried over exactly**; 0 single adjacencies, 0 metadata; columns, constraints, indexes, trigger, RLS, policy and grants **identical** to the definition captured in the backup |
| 9 Resume | 00:40:23 | both jobs active again on their schedules |

Writers were paused for 2 min 17 s; the steps that change the table took
about 20 s, of which the rewrite (the only one that blocks reads) ~3 s.

| | Before | Peak | After |
|---|---|---|---|
| `postgres` | 496.83 MiB | **496.83** (never exceeded) | **412.51 MiB** (−84.3) |
| Dashboard measure (all databases) | 536.2 MB | 536.2 | **447.8 MB — 90% of 0.5 GB** |
| `music_relationships` | 135.61 MiB | | **51.28 MiB** |

**DIG after B2**: the four readers' output for the 60 sampled artists and
76 starting points is **identical** to the capture taken just before the
window. DIG page timings on the busiest artists: cold first call 0.36–0.78 s
(was up to 1.9 s after B1), warm 49–219 ms; obscure artists 1–38 ms.

**Backup kept**: `backups/b2-live/export` (local, outside git): every row
and column of the table before the window, with its manifest; checksums in
`supabase/diagnostics/capacity/b2/`.


## 9. P — single-broadcast `played_by` on demand (proposed 2026-10-18)

The same move as B for the other radio edge. **P1 applied 2026-10-18
14:20 UTC** (progress at the end of this section); For You's read and P2 not.

### What is redundant

On 2026-10-18 `music_relationships` holds 192,297 rows (heap 29.0 MiB,
indexes 22.9, total 51.9 MiB; 150 B a tuple, indexes 89–93% dense).
**161,819 of 181,930 `played_by` edges have `episode_count = 1`**: a show
played an artist in one broadcast. Catalogue-wide against
`radio_appearances` (`p1/recon.sql`):

| Stored single-broadcast edges | |
|---|---|
| Reproduced exactly (appearances, episodes, confidence) | **161,553 (99.84%)** |
| Stale: the pair is in no appearance now (the rebuild never deletes) | 266 |
| Became stronger unseen | 0 |

### Readers of `played_by`

| Reader | Reads | Change |
|---|---|---|
| `artist_radio_relations` (DIG artist page) | artist → shows | P1: stored ≥ 2 broadcasts + the rest derived |
| `explore_knowledge` (app), `knowledge_answers` (worker, via `knowledge_cut`) | artist → shows **and** show → artists (broadcast nodes) | P1: both ends, same rule |
| `dig_radio_for_artists` | appearances directly, not `played_by` | none |
| **`ListenerRetrieval.showsPlaying` (app, For You)** | `music_relationships` rows per artist, counted: shows playing the artist (`popularityStep`, `hubDamping`, the ≤ 40 bridge cut) | **Must move before P2** — see below |
| `rebuild_radio_dig_edges` (writer) | — | P1: store only ≥ 2 broadcasts |
| `merge_artist_halves` (writer) | — | none: it re-points and sums; the next rebuild corrects counts |
| `enrichment_status.radio_edges` | a diagnostic count | none; the number drops after P2 |

**For You dependency (flagged, not changed).** If the app keeps counting
table rows after P2, **94,247 of 101,710 artists read a different show
count and 85,990 read zero** — every hub-damping and popularity step in
radio retrieval would move. The draft adds `artist_show_counts(uuid[])`
(the same count from the appearances; equal to today's table count for
101,434 artists catalogue-wide and for 60/60 sampled, the rest stale or
newer than the last rebuild). Switching `showsPlaying`'s fetch to it is a
one-closure change in `ListenerRetrieval.swift` — a For You file, so it
needs the owner's approval. Installed builds that still read the table
would degrade after P2; P2 waits until the builds that matter have the
change.

### P1 (migration, no space change)

`0087_shows_played_once_on_demand`: the writer adds `having count(distinct re.id) >= 2`
to its `played_by` branch; the three readers read stored edges with
`episode_count >= 2` and derive every other artist–show pair from the
appearances with the rebuild's counting (appearances, distinct episodes)
and confidence (`least(0.95, 0.5 + 0.45 * (1 - 1/(1 + episodes)))`); plus
`artist_show_counts` in `app_callable_functions()`. Built from the live
definitions (equal to 0078); everything else byte-for-byte.

**Validated** (`Scripts/p1-capture.py`, the B1 method extended to the show's
end; the proposed bodies loaded as session-local `pg_temp` functions, so
nothing shared was written; 60 artists — top, p5, p25, p50, p95 by radio
plays — 30 shows the same way, and the pilot demand set; `p1/`):

- `artist_radio_relations`, `played_by` rows: **60/60 identical**. The
  neighbour rows differ on 4 of the most-played pages only by which tied
  (evidence 1, 0.65) single adjacencies fill the 200-row limit — the tie B1
  documented.
- `explore_knowledge` / `knowledge_answers`, `playedInShow`: **106/114
  nodes identical**; every other edge type identical on all 114. Of the 15
  differing edges, the 11 gone are all stale stored pairs, the 4 new are
  pairs newer than the last rebuild. No current pair lost, none invented.
- Throwaway Postgres (`Scripts/test-migrations.sh` on a copy with the draft
  as 0087): every migration and smoke test passes.
- Timing (warm, three runs): DIG page unchanged (Coltrane 72–74 ms, median
  artists ~2 ms); `explore_knowledge` for the busiest show (13,016
  appearances) 163 → 250–365 ms, second busiest 75–99 → 148–176 ms; a
  12-artist batch 1.25–1.3 s either way. Inside anon's 3 s.

Rollback: re-create the four functions from `pg_get_functiondef` as captured
(they equal 0078's text); drop `artist_show_counts`, restore the allowlist.

### P2 (deletion window, after P1 has run one rebuild cycle and the app reads `artist_show_counts`)

Simpler than B2: `metadata` is already null and `episode_count` filled, so
no column rewrite is needed and at 419 MiB a plain `VACUUM FULL` fits.

1. Export (`Scripts/b2-export.py`, whole table, ~50 MB, outside git); verify.
2. Pause `indigo-rebuild-edges` (6) and `indigo-merge-split-artists` (34);
   gates as in §7 (not near :23 of a third hour or 04:23 UTC).
3. Checksums of the rows kept; the P1 capture.
4. `delete from music_relationships where relationship_type = 'played_by'
   and coalesce(episode_count, 0) < 2` — 161,819 rows.
5. `vacuum full analyze music_relationships` — copies 30,478 rows and
   rebuilds the three indexes; ACCESS EXCLUSIVE for a few seconds.
6. Verify checksums, zero stored single-broadcast edges, the capture
   identical to step 3; resume cron; watch one rebuild.

| | `postgres` MiB | Dashboard (all DBs, decimal) |
|---|---|---|
| Now | 419.4 | 455.1 MB (91%) |
| Peak (old + new copy) | ~428 | |
| After | **≈ 376 (−43.5)**; table 51.9 → ~8.5 MiB | **≈ 410 MB (82%)** |

### To decide

1. Approve P1 (the migration; no space change).
2. Approve moving `showsPlaying` to `artist_show_counts` (For You).
3. Approve P2's window, separately, once 1 and 2 are live.

### Progress (2026-10-18)

| | Status |
|---|---|
| P1 — 0087 | **Applied** 14:20 UTC with `db query -f` in one transaction — not `db push`, which would also have applied 0086 (committed, not yet applied, another session's). 0087 is idempotent, so a later push that records both is harmless. Grants unchanged; `artist_show_counts` listed and executable by anon. Live capture before vs after (`p1/compare-live-2026-10-18.json`) **exactly as predicted**: `played_by` on the DIG page 60/60 identical; `playedInShow` 106/114, the 11 gone stale and the 4 new not yet rebuilt; nothing else changed. Rollback: `p1/rollback-0087.sql`. Still to watch: one rebuild (15:23 UTC) inserting no single-broadcast edge. |
| `showsPlaying` → `artist_show_counts` | Awaiting For You approval |
| P2 — deletion window | Awaiting approval; after both rows above |

## 10. P follow-up (2026-10-18): For You's read, older builds, P2 preflight

### For You's show counts → `artist_show_counts` (`979ab23`, not pushed)

`ListenerRetrieval.showsPlaying` now calls `artist_show_counts` instead of
counting `played_by` rows. Scoring (`popularityStep`, `hubDamping`, the ≤ 40
bridge cut) is untouched. Same chunks of ten, one request per chunk, rows
asked once per build of the pool.

- **Semantics** — the same number: shows that played the row. Old and new,
  as `anon` (the app's role), against today's table:

  | Group | Artists | Same | Old read wrong after P2 |
  |---|---|---|---|
  | Sample (top, p5, p25, p50, p95) | 60 | **60** | 55 |
  | Single-broadcast only | 15 | **15** | 15 (all would read 0) |
  | Most shows (62–87) | 10 | **10** | 10 |
  | No appearances | 10 | **10** (0) | 0 |
  | Aliases (MusicBrainz→Discogs links, shared names) | 6 | **6** | 4 |

  Catalogue-wide: equal for 101,434 of 101,710 artists; the 276 others
  are stale stored pairs or pairs newer than the last rebuild. The count is
  per catalogue row, as before: two rows for one person are counted apart
  under both (Discogs ids are never shared across rows: 0).
- **Zero vs failure — one deliberate change, failure path only.** A row
  the answer leaves out is 0, as before. A *failed* request used to record
  0 for its rows; it now leaves them unknown (nil) and asks again the next
  time they are wanted. Downstream that differs in one place: a failed
  *source* used to damp a step to a more-played candidate
  (`popularityStep(from: 0, …)`), and now does not (`nil` → 1). Identical
  whenever requests succeed.
- **Over HTTP** (publishable key, warm): 0.17–0.39 s vs the old read's
  0.34–0.43 s for ten artists.
- **Who runs it**: `ListenerRetrieval.radio` is called only by the replay
  measurements in `IndigoTests` (`ListenerRetrievalReplay`,
  `ListenerExpansionReplay`); no app code path calls it today.
- Tests: `ListenerRetrievalTests` 13/13 on macOS, including
  `testAFailedDegreeReadIsUnknownNotZero`.

### Older builds

| Build | Reads `played_by` | After P2 |
|---|---|---|
| App Store 1.0 (`production-ios-1.0-1`, `production-macos-1.0-1`, 2026-10-03) | only through `artist_radio_relations` (RPC); no direct read of `music_relationships` (its table reads: `metadata_cache`, `scene_members`, `scene_rosters`) | **unaffected**: the server-side reader already derives (0087) and never reads a single-broadcast row |
| Internal TestFlight 2026101502–2026101603 | `artist_radio_relations`, `explore_knowledge` (RPCs); direct `music_relationships` reads in `TrackDiscoverySource` are `radio_neighbor` only, already without singles since B2 | **unaffected** |
| Any build with `showsPlaying` | the direct count | never shipped on a path users reach (replay tests only) |
| Edge Functions (worker, publisher) | none read `music_relationships`; `knowledge_cut` goes through `knowledge_answers` | unaffected |

Every server function that names `played_by` was listed from the live
catalogue (`pg_proc`): the three readers and the rebuild, all on 0087. No
view or materialised view reads the table. Old clients cache radio
relations only as answers to RPCs, which do not change.

### P2 preflight

**Rehearsal** (`Scripts/p2-rehearsal.sh` on a throwaway Postgres 17 built
from every migration, the live table restored from a read-only export of
2026-10-18, all 16 slices equal to live by rows and md5;
`p2/rehearsal-2026-10-18.txt`):

| | Result |
|---|---|
| Selection | `relationship_type = 'played_by' and coalesce(episode_count, 0) < 2`: **161,819** rows; 0 `played_by` without `episode_count`; includes the 266 stale ones |
| Delete | 95 ms locally |
| `vacuum full analyze` | 206 ms locally; peak +8.7 MiB over the start (the new copy), then the old files go |
| Table after | **8.66 MiB** (heap 4.59, `edge_idx` 2.52, pkey 0.93, `to_idx` 0.61); 30,478 rows |
| Integrity | kept rows identical (id, endpoints, counts, episodes, confidence, `updated_at`, source); 0 single-broadcast left; pkey, unique `edge_idx`, trigger, RLS present; the rebuild runs |
| Rollback | deleted rows re-inserted from the export in 2.6 s; all 16 slices equal live again, every column |

**Live projection**: table 51.9 → 8.7 MiB, **−43.3 MiB**; `postgres` 419.4
→ ~376 MiB; peak ~428 MiB. Dashboard (all databases, decimal): 455.1 → ~410
MB of 500; peak ~464. Allowing 10–20× local times, the exclusive lock of
`VACUUM FULL` is 2–4 s.

**Migration order.** `schema_migrations` ends at 0085. 0086 (NTS backfill
pause) is committed and **not applied** — `indigo-discover-backfill` is
still active — and 0087 was applied out of band and is **not recorded**.
So: the next `supabase db push` will apply 0086 and re-run 0087, in order;
re-running 0087 is harmless (`create or replace`, grants). Do not record
0087 by hand: that would put 0086 behind the last remote version and make
the push need `--include-all`. A migration after 0087 that redefines the
same functions must start from 0087's text. P2 is a window, not a
migration, as B2 was; it does not depend on 0086.

**Rebuild after the deletion.** The writer only inserts pairs with ≥ 2
broadcasts and only updates pairs it wants, so it cannot re-create a
deleted row; `merge_artist_halves` re-points and sums existing rows only.
A pair that becomes ≥ 2 later is inserted then, as it should be.

## 11. P2 readiness (2026-10-18 15:30 UTC) — GO, approved and executed (§12)

### The first rebuild after 0087

`indigo-rebuild-edges` 15:23:00.12–15:23:21.84 UTC, **succeeded**, no
error. Source data did not move in between (262,478 appearances, 0 new
since 14:49). Baseline at 14:49 vs after:

| Check | Expected | Observed | |
|---|---|---|---|
| Run completed | succeeded | succeeded, 21.7 s | PASS |
| Pairs newly at ≥ 2 broadcasts inserted | 3 | **3**: Bob Degen, Lisle Atkinson, James Williams on Vinyl Life – Piano Trio, 2 broadcasts each | PASS |
| Stored pairs with changed counts updated | 4 | **4** updated; stored multi-broadcast rows that differ from the tracklists 4 → **0** (e.g. Cedar Walton 3 → 5) | PASS |
| Single-broadcast rows inserted | 0 | **0**; rows updated into a single 0; stored singles still 161,819 | PASS |
| Archie Whitewater / André Navarro II (1 broadcast) | not stored | **not stored**; derived 1 broadcast | PASS |
| Multi-broadcast rows | 20,111 + 3 | **20,114**: 20,107 exactly as the tracklists say, 7 stale (pair gone; the rebuild never deletes) | PASS |
| Pairs at ≥ 2 broadcasts not stored | 0 | 3 → **0** | PASS |
| `radio_neighbor` | only ≥ 2 | 3 inserted, all 2 adjacencies in 2 episodes | PASS |
| Row count | +3 played_by | 192,297 → **192,303** (+3 played_by, +3 radio_neighbor) | PASS |

**Readers after the rebuild** (`p1/compare-rebuild-2026-10-18.json`, the
same capture as before it): DIG page 60/60 identical, every edge type;
knowledge answers 113/114 identical, the one change being Cedar Walton's
count update. **Single-broadcast pairs are still served**: 26 random
stored single-broadcast pairs plus Archie Whitewater, called as `anon`,
appear on the DIG page (1 broadcast, confidence 0.725), in
`explore_knowledge` from the artist's end and from the show's, and in
`artist_show_counts` — **26/26** on every reader, before and after the
rebuild.

### Fresh measurements (15:26 UTC)

| | Rehearsal (export 14:30) | Now |
|---|---|---|
| Rows | 192,297 | **192,303** |
| Eligible (`played_by`, `coalesce(episode_count, 0) < 2`) | 161,819 | **161,819** (0 with null `episode_count`) |
| Retained | 30,478 | **30,484** |
| Table | 51.93 MiB | 51.93 MiB |
| `postgres` / all databases | 419.4 MiB / 455.1 MB | 419.4 MiB / **455.1 MB** |
| Indexes, constraints, trigger | pkey, unique `edge_idx`, `to_idx`; 3 checks; `touch_updated_at` | unchanged; no FKs into the table, no publication |
| Replication slots, prepared, old snapshots | | **0 / 0 / 0** |

The six extra rows are 0.003% of the retained set: the rehearsal still
represents production. **Expected**: delete 161,819, keep 30,484; table
51.93 → ~8.7 MiB (**−43.3 MiB**); `postgres` 419.4 → ~376 MiB; dashboard
455.1 → **~410 MB**; peak during compaction **~464 MB** (+~9 MB, the new
copy; local peak +8.7 MiB).

### Migration order (0086 now applied)

`schema_migrations` ends at **0086** (applied with the new worker by the
NTS session; `indigo-discover-backfill` is gone). 0087 is applied but not
recorded.

1. The next `supabase db push` would execute **0087 only**.
2. **0087 is idempotent, demonstrated**: in a throwaway Postgres built from
   every migration, the six functions' definitions equal live by md5;
   re-running 0087 there leaves definitions and grants identical.
3. Hazards: re-running 0087 rewrites `app_callable_functions()` with its
   list — identical to live today, but a migration that adds a name before
   0087 is recorded must carry 0087's list forward (as every allowlist
   migration does). A later migration redefining the three readers or the
   rebuild must start from 0087's text, or it silently re-reads stored
   singles (none would exist after P2) or re-stores them.
4. Reconcile — a separate decision: either `supabase migration repair
   --status applied 0087` (writes one history row, runs nothing), or let the
   next push re-run it (harmless, shown above). Not done.

### Runbook

`p2/runbook.sql`, rehearsed block by block on a copy of the live table
(`p2/runbook-rehearsal-2026-10-18.txt`). Two corrections over §9 came from
rehearsing it:

- **`VACUUM FULL` is out.** The CLI sends one call as one implicit
  transaction, where `VACUUM` fails (25001, checked live), and the CLI
  session has no `lock_timeout` (0) to bound it. `CLUSTER … USING
  music_relationships_pkey` rewrites the heap and every index the same way
  and may run in a transaction, so it carries `set local lock_timeout =
  '5s'`: same result (8.66 MiB, 190 ms locally); under a held lock it gives
  up after 5 s with nothing changed; the clustered flag is cleared after.
- **Delete and compaction must be separate calls.** In one transaction
  CLUSTER copies the rows that transaction deleted and frees nothing
  (rehearsed: 52.30 MiB before and after).

The delete is a single `DO` block: counts the eligible rows live, refuses
outside 150,000–161,819, fingerprints the kept rows before and after, and
raises — rolling everything back — if the deleted count or the fingerprint
differ (rehearsed: a wrong range deletes nothing).

**Rollback vs restore.** Until block 3 commits, any failure rolls back by
itself. After it commits, undoing is a restore: (a) exact, from the block-0
export, every column and id (rehearsed locally in 2.6 s); sending ~40 MB of
rows through the CLI has not been tried on live — over psql `\copy` it is
the rehearsed path; (b) derived: `p1/rollback-0087.sql` plus one rebuild
re-materialises every current single-broadcast pair (new ids; not the 266
stale ones, which are in the export). If the compaction fails after the
delete committed: readers are correct (they never read these rows); retry
block 4; until it succeeds the space stays allocated and autovacuum makes
it reusable.

**Abort**: any preflight `ok_*` false; dashboard ≥ 470 MB; eligible
outside the range; any old snapshot, slot or prepared transaction before
block 4; a rebuild or merge running; within 10 minutes of a :23 slot or
04:23 UTC.

### GO / NO-GO

| Gate | | Evidence |
|---|---|---|
| Post-P1 rebuild | **PASS** | 15:23 run: 3 inserted, 4 updated, 0 singles, Archie absent; readers unchanged |
| For You compatibility | **PASS** | `979ab23`: counts equal for 110 artists + 6 alias rows; 13/13 tests |
| Older app compatibility | **PASS** | App Store 1.0 and every TestFlight build read `played_by` only through RPCs on 0087 |
| Deletion eligibility | **PASS** | 161,819 live = rehearsal; every one reproduced from the tracklists or stale; served by all readers when derived |
| Storage headroom | **PASS** | 455.1 MB now, peak ~464 MB, after ~410 MB of 500 |
| Rollback readiness | **PASS** (with the note above) | in-transaction rollback automatic; export restore rehearsed locally; derived restore available |
| Migration safety | **PASS** | P2 is no migration; 0087 idempotent and equal to live; reconciliation separate |

**GO — ready for explicit production approval.** Approved 2026-10-18; executed, §12.

## 12. P2 executed (2026-10-18, 16:57–17:06 UTC)

Block by block per `p2/runbook.sql`; no abort criterion met.

| Block | UTC | Result |
|---|---|---|
| 0 Backup | 16:57–16:59 | `backups/p2-live/export` (local, outside git): 192,303 rows, 16 slices; restored into a throwaway Postgres, all 16 equal live by rows and md5; the full rehearsal on it passed, rollback included (`p2/rehearsal-live-export.txt`) |
| 1 Preflight | 16:59 | every `ok_*` true; eligible 161,819, retained 30,484; dashboard 455.1 MB |
| 2 Pause | 16:59:31 | jobs 6 and 34 inactive, none running; reader capture taken |
| 3 Delete | 17:01:37–17:01:47 | the guarded `DO` block committed: **161,819 deleted**, 30,484 kept, kept-row fingerprint equal before and after inside the transaction |
| 4a Snapshots | 17:02 | old snapshots 0, slots holding xmin 0, prepared 0 |
| 4b `CLUSTER` | 17:02:10–17:02:15 | 4.7 s including the round trip; no lock wait |
| 5 Verify | 17:02–17:05 | below |
| 6 Resume | 17:05:54 | both jobs active on their schedules; writers paused 6 min 23 s |

| | Before | After |
|---|---|---|
| `music_relationships` | 51.93 MiB (heap 28.98, indexes 22.91), 192,303 rows | **8.66 MiB** (heap 4.59, indexes 4.06), 30,484 rows |
| `postgres` | 419.4 MiB | **376.2 MiB (−43.2)** |
| Dashboard (all databases) | 455.1 MB | **409.7 MB** — 82% of 0.5 GB |

**Verified**: 0 single-broadcast `played_by` left; primary key, unique
`edge_idx`, `to_idx`, trigger, RLS, 1 policy and 28 grants as in the
backup's definition; clustered flag cleared. Kept rows **identical to the
export** (id, endpoints, type, evidence, episodes: md5 equal over all
30,484). Readers (`p2/compare-live-2026-10-18.json`): the DIG page 60/60
identical; `explore_knowledge` and `knowledge_answers` 114/114 identical
on every edge kind once artist names are compared by their letters and
digits — `indigo-relabel-credits` renamed 262 artists at 17:00:00.58
("YOUNG THUG" → "Young Thug", "Bnyx" → "BNYX®"), between the two
captures, which is not P2. The 26 single-broadcast pairs and Archie
Whitewater are still served by every reader (26/26).

**Observed, not P2's**: the non-radio edges of the sample went back at
17:03 to exactly their 10:06 state, after reading a second state from
10:19 to 17:01 — artist display names appear to alternate between two
spellings across relabel runs.

**Still to watch**: the 18:23 UTC rebuild — succeeded, and 0
single-broadcast rows created.

**Backups kept**: `backups/p2-live/export` and
`backups/p2-preflight-2026-10-18/export` (local, outside git).
