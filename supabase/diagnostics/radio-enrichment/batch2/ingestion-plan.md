# Next published-tracklist ingestion plan

Prepared October 19, 2026 (America/New_York). No production writes, deployments,
cron changes, audio downloads or R2 writes. This continues the October 17 audit
and October 18 pilot; their research was reviewed, not repeated. Current evidence
is in `supabase/diagnostics/radio-enrichment/batch2/`.

## Current coverage and actual gaps

Live database snapshot at 2026-10-20 01:18 UTC (October 19, 9:18 pm EDT):

| Source | Stored episodes | Published lines held | Distinct artist rows | Distinct linked recording rows | Timed lines |
|---|---:|---:|---:|---:|---:|
| NTS | 6,828 | 126,018 | 65,010 | 25,867 | 126,018 |
| The Lot Radio | 3,860 | 60,762 | 31,155 | 1,674 | 60,721 |
| YouTube | 679 playlists/uploads collections | 79,902 | 26,212 | 514 | 0 |

Total: 266,682 appearances. Artists and recordings overlap across providers;
do not sum those columns as unique catalogue totals. YouTube collection entries
can repeat one video across playlists. A recording row is not itself proof that
an individual recording can be played: retain the appearance's media/archive URL.

Only these three providers occur in the shared radio tables. The app also
integrates IDA, LYL, ROVR, Noods, Kiosk, Panik, Radio 80000, dublab, Cashmere,
alHara and n10.as. Their browsing integration does not imply shared ingestion.

| Source | Established evidence of missing published music data | Next bounded action |
|---|---|---|
| NTS | Audit counted 91,077 archive episodes; only 6,828 currently stored. The exact missing count needs a fresh sitemap anti-join, since the archive total grows. Fresh discovery succeeds; the broken offset backfill is absent from current cron. | Use the sitemap/per-show archive route, anti-join `(provider, external_id)`, select 100 missing episodes from 2023 onward with actual tracklists and publisher IDs. Do not restart the old offset walk. |
| Lot | Completed backfill cursor remains `done:true,total:3689`; fresh ingest continues. Current count exceeds that old cursor total, as expected. No measured historical tracklist gap. | Check 20 current public index items against stored IDs and hashes. Repair only demonstrated differences. Do not revisit the private Next-Action backfill endpoint. |
| YouTube | 78 enabled channels; 672 failed crawl jobs and 264 successful jobs updated in the last three days. Failures report `playlists answered 403`. 290 saved playlists across 29 channels are at least 25 days old: 21,728 entries, 621 item pages, with duplicates. | Diagnose the structured 403 reason first. Run one healthy existing channel, then refresh 20 overdue playlists, capped at 1,000 unique videos. Separately diff published upload/playlist IDs against stored media URLs to count genuinely missing videos. |
| IDA | October 17 audit counted 10,096 non-null tracklists among 23,657 episodes; 64% of sampled artist names were absent from Indigo. Zero shared episodes today. These figures describe published text, not verified identities. | Parse 10 saved/approved episode fixtures first; then a 100 non-repeat, playable-archive episode dry run. Read `tracklist`, never infer tracks from `subtitle` or descriptions. |
| LYL | October 17 audit: real `tracks` text in 6/10 episodes; 45% of sampled artist names absent. Zero shared episodes. Some non-empty fields say `NO TRACKLIST`. | Ten fixtures, then 50 episodes whose `tracks` field contains actual listings and whose archive link is playable. Exclude placeholders. |
| ROVR | Existing audit found structured tracks, ISRCs and cue offsets, with a pure parser already built and tested. Its existing fixtures are synthetic, not real payload validation. | Keep the parser; validate five authorized real payloads before a 50-archive dry run. Do not repeat the completed synthetic-parser work. |
| Noods | Audit found tracklist HTML on 5/8 sampled shows, 36% sampled names absent. | Follow IDA/LYL: ten fixtures, then 50 shows with actual `tracklist.html`; no client-bundled RadioCult key. |
| Kiosk / Panik | Kiosk: 2/8 published tracklists. Panik: structured playlist logs exist, but automated rotation and podcast descriptions must be distinguished. | Defer bulk work. Accept only explicit `trackList` entries or dated structured playlist rows, with episode provenance. |
| dublab / Cashmere / alHara / n10.as / Radio 80000 | Earlier audit did not establish usable published historical tracklists through approved sources. | No new ingestion proposal based on descriptions. No Mixcloud harvesting or audio reconstruction. Revisit only with a specific newly published tracklist source. |

IDA/LYL/ROVR bulk reuse permission remains unconfirmed in the previous audit.
No permission emails were sent. Preserve the existing decision against outreach;
fixture/parser preparation can proceed locally, while bulk retrieval/republication
waits for that source-access question to be resolved. No new station crawls were
performed in this preparation.

## Implementation sequence and budgets

1. Apply only the separately approved Tier 1 identity manifest, after fresh
   re-verification and database guards. Finish portrait checks and the next
   04:23 UTC merge integrity check. Never call `merge_split_artists` manually.
2. Repair YouTube's failure visibility before rescheduling failed jobs. Record
   sanitized API `reason/domain/message`, HTTP status, method and channel/list
   ID; omit keys and token-bearing URLs. Distinguish quota, disabled API,
   invalid/restricted key and forbidden resource errors. A 403 alone establishes
   none of those causes. Stop on 403/429 instead of repeatedly exhausting retries.
3. Prepare the 100-episode NTS sitemap dry run. Select by published IDs and music
   coverage, independent of ranking experiments. Keep the existing fresh lane.
4. Implement IDA and LYL pure text parsers plus provenance fixtures. Only explicit
   artist/title lines count; preserve headings/raw text in local source snapshots.
   No guessed artist splitting on `&`, `and`, or `+`. Parse errors remain visible.
5. Before either new provider writes, add and rehearse a provider-specific gate
   in **both** the resolver and the scheduled `adopt_radio_artists(null)` path.
   Merely skipping adoption inside a new worker is insufficient: the global job
   would adopt unresolved names later. New-source identities require verified IDs;
   unmatched names remain unpublished staging claims until reviewed.
6. Use insert-only pilot manifests. The existing `storeTracklist` deletes stale
   slots, including all slots for an empty result; it cannot be reused unchanged
   for a non-destructive pilot. An empty/failed fetch must never erase a list.
   Stage corrections and shorter replacement lists for separate review.
7. Feed verified appearances/recordings into the existing shared tables and
   readers. Run existing derived-edge jobs on their normal schedule. Do not
   modify Radio Discover or For You scoring/candidate experiments.

| Bounded operation | API budget, excluding retries | Expected incremental DB use (planning estimate) | Stop condition |
|---|---|---|---|
| YouTube 20-list / 1,000-video pilot | ≤100 Data API list calls/units, no `search.list`; playlistItems is 1 unit/call, up to 50 items | Refresh may add zero rows. Cap incremental appearances at 1,000 and total DB growth at 2 MB | First 403/429; missing page token; unexpected item cap; expired source cache |
| NTS 100 eligible episodes | ≤205 requests: sitemap/index budget plus episode details; skip already held IDs | ~2,000 lines ≈0.9 MB at historical 466 B/line, plus episodes and derived edges; **5 MB total cap** | Projected DB ≥440,000,000 B, >3 consecutive 5xx, any 403/429, incomplete tracklist |
| IDA 100 eligible non-repeat episodes | ≤110 station requests at ≤1/2 s; identity lookups have separate capped budget | ~1,400 offered lines from old sample; unresolved new names stay staged; **2 MB total cap** | Unconfirmed bulk source access; parser ambiguity; adoption gate missing |
| LYL 50 eligible episodes | ≤60 station requests at ≤1/2 s | ~1,000 offered lines from old sample; **2 MB total cap** | Same gates as IDA |
| Verified recording/metadata tranche | ≤50 recording IDs and ≤20 Discogs release documents; no automatic full shelf fan-out | Cap 1 MB DB growth; measure actual bytes per 100 records before scaling | Conflicting existing IDs/artist credits, multiple release editions without a specific ID, missing provenance |

These are caps and historical estimates, not achieved additions. Database growth
includes appearances, episode rows, identities, jobs and derived edges. Baseline
is 396,127,379 B; conservative headroom is 103,872,621 B to 500,000,000 B and
43,872,621 B to the proposed 440,000,000 B stop threshold. Supabase documents
the Free database quota separately from total disk space; no account billing or
compute/egress allowance was inferred from `pg_database_size`.

Expected external request charge: no new paid API service is proposed. YouTube
uses quota units; MusicBrainz uses a rate-limited public API. Current account
quota remaining and any Supabase overage/compute billing were not accessible from
these SQL measurements, so a dollar total is not claimed. Existing edge worker
invocations, response bytes and DB growth must be logged per approved pilot.

The full 290-list YouTube refresh needs at least 621 playlist-item calls plus
channel/list enumeration and any video availability checks. Its 21,728 entries
are refresh work, **not 21,728 new recordings**. The machine-readable queue is
`youtube-refresh-plan.json`; dedupe by video ID across lists when measuring gain.

## Recording and musical metadata path

The identity collector preserves source MusicBrainz recording credits, ISRCs,
release references, artist genres/tags and typed artist relationships in local
evidence files. `metadata-staging.json` contains reviewed artist identities and
their source claims; it is not automatically written into artist genres.

- A publisher recording MBID identifies the recording; credit verification
  identifies its artist. Do not follow the name-derived `artists.musicbrainz_id`.
- Reuse an existing recording only when its MBID/ISRC and artist credits agree.
  If an existing recording points at a different artist, queue it for review;
  never reassign it or unify artists automatically.
- Create a missing recording with its exact source MBID, verified credit and
  provenance. Link only the exact source appearance IDs. A title-only match and
  an ISRC's valid syntax are insufficient. Preserve collaborations as credits.
- A MusicBrainz recording can appear on many releases. Preserve typed references
  without choosing an edition arbitrarily. Fetch ≤20 source-identified Discogs
  releases, confirm their artist IDs and track credits, then derive styles,
  release year/label and musical context from those **release** documents.
- Keep artist tags attributed to MusicBrainz and release styles attributed to
  Discogs, with source IDs, retrieval time and evidence counts. Group membership,
  alias, person/project and renamed-project relations retain their distinct types;
  none becomes an identity merge. Curator/show/channel affinity stays on radio
  evidence, never in artist genres.
- Keep a direct YouTube media URL when the source publishes a video; keep an
  archive URL for episode playback. For IDA/LYL lists without track timestamps,
  store no invented offset. Preserve NTS's current offset policy. A useful
  timestamp is one the publisher actually provides, with estimate/exact status
  retained in staging until the existing timestamp decision is revisited.

## Reader compatibility and practical acceptance

The existing shared SQL readers understand `musicbrainz_discogs`. However,
`DiscogsIdentityRows.isEnabled` still returns false in Release builds, and its
Debug switch controls `TrackDiscoverySource` and `ListenerRetrieval`. No change
to that switch or either ranking implementation is included. New links are
available to the shared readers and the existing opted-in DIG reader; they must
not be reported as shipped Release DIG gains. Releasing the identity reader
needs its own small acceptance/release decision, without another ranking test.
The immutable October 11 R2 generation stays untouched. Live tables serve new
evidence; any later R2 publication must be a separate generation.

For each approved pilot capture a fixed before/after manifest and report:

| Practical output | Measurement |
|---|---|
| Newly verified artists | Count newly inserted, non-conflicting source-proven IDs; never count raw new names |
| Newly accessible recordings | New verified recording IDs with a usable appearance; distinguish existing catalogue rows newly reached from newly created recordings |
| Artist pages with playable music | Distinct verified artist IDs with direct video or supported archive playback; count timestamped clips separately; resolve URLs in focused checks |
| Reachable radio/YouTube candidates | New unique artist/recording/media IDs through shared readers, plus show/episode provenance; dedupe YouTube playlist repetition |
| Growth/cost | Exact inserted/changed rows by table, `pg_database_size` delta, relation-size delta, requests by host/method/status, worker invocations, payload bytes and quota units |
| Integrity | Zero orphan IDs; no conflicting IDs or automatic merges; exact replay adds zero rows; precise rollback preserves unrelated rows |

Use five artists and five representative appearances for reader/playback checks,
plus machine checks over the bounded manifest. Verify the next scheduled merge
and portrait drain after each batch. Do not run a historical recommendation
replay or start another For You experiment.

References: [existing audit](radio-tracklist-audit.md),
[existing pilot](radio-enrichment-pilot.md),
[MusicBrainz API rate limit](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting),
[YouTube playlist-item cost](https://developers.google.com/youtube/data/reference/rest/v3/playlistItems/list),
[Supabase database-size quota](https://supabase.com/docs/guides/platform/database-size).
