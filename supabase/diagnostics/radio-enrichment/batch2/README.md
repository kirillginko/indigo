# Tier 1 batch 2 — explicit approval required

Prepared October 19, 2026 EDT. **NOT APPLIED. Production link count remains 463.**

## Ready for review

21 exact-billing identity links, independently checked through publisher NTS
recording IDs → MusicBrainz recording credits → MusicBrainz artist URL relations
→ one Discogs artist page. Reverse MusicBrainz claims are sole-claimant for each
accepted page. The Discogs API also confirms its ID and billing.

Every stored publisher recording witness for each ready artist was checked (58
recordings total), rather than limiting contradiction checks to two. Two played
titles per candidate were searched as a contradiction veto. That check is bounded;
it is not proof that every unidentified line on a same-name radio row is correct.
All aliases/project changes, multiple pages, held destinations and contradictions
are outside the apply file. No artist name is an identity merge instruction.

| Artist | Discogs ID | Recording witnesses | Existing appearances |
|---|---:|---:|---:|
| Lolina | 4304488 | 3 | 38 |
| Nala Sinephro | 8270419 | 1 | 37 |
| Piero Umiliani | 8722 | 1 | 91 |
| Blawan | 1622339 | 4 | 39 |
| Gene Harris | 29966 | 2 | 52 |
| Manu Dibango | 20560 | 1 | 40 |
| Ramsey Lewis | 55738 | 2 | 103 |
| Paul Johnson | 866 | 5 | 34 |
| Monolake | 534 | 1 | 32 |
| Les McCann | 44126 | 2 | 93 |
| Spirit | 270578 | 5 | 29 |
| Barbara Mason | 48720 | 3 | 38 |
| I:Cube | 1029 | 5 | 26 |
| Eddie Harris | 41249 | 3 | 42 |
| Sepehr | 3563778 | 1 | 29 |
| Bill Withers | 59249 | 4 | 26 |
| Martin Denny | 36860 | 3 | 30 |
| Letta Mbulu | 97988 | 1 | 29 |
| Salem | 1300441 | 4 | 28 |
| Squarepusher | 269 | 5 | 25 |
| The S.O.S. Band | 98545 | 2 | 25 |

**Scope of approval:** exactly 21 `external_ids` inserts under
`musicbrainz_discogs`. Expected resulting total: **484** if no unrelated writes
occur. No artist, recording, release, appearance, genre or relationship writes
are in this SQL. The existing 0083 trigger can enqueue 21 portrait jobs: 19
old-rule portraits and two withheld portraits are rechecked on the verified IDs.

## Measured output and cost

- Newly verified artists prepared: **21**. New production artists/links now: **0**.
- Publisher recording MBIDs verified and staged: **58**, none found in current
  `recordings` by those exact MBIDs. **0 new recording rows** are in this apply.
- Potential reach through these identities: **886 existing appearances across
  481 episodes**, 547 distinct artist/title pairs; 451 timed radio lines and
  435 YouTube list appearances representing **232 distinct media URLs**.
- All 21 artist rows have source playback/archive URLs. Five final artists
  returned current shared-reader appearances and relations. This is URL/reader
  availability, not a new end-to-end playback or regional-availability result.
- Supabase: **396,127,379 B** (396.1 MB / 377.8 MiB). Conservative headroom to
  500,000,000 B: **103,872,621 B**. Usable budget to the 440,000,000 B stop:
  **43,872,621 B**. Account egress/compute quotas were not measured.
- Estimated logical identity growth: **5,162 B**, from live `external_ids`
  relation size / live rows, plus transient jobs and portrait updates. Physical
  growth can differ because Postgres reuses pages. Production growth from this
  preparation is zero; initial/final database bytes were identical.
- Actual remote calls: **257 MusicBrainz + 34 Discogs = 291**, including retries.
  278 successful URL responses are preserved. One process paced each host at
  1.1 seconds, stopped on 403/429, and backed off transient server failures.
- Before execution, reverify only these 21 artists using fresh evidence:
  approximately **142 MusicBrainz + 21 Discogs** calls, excluding retries.
  The portrait lane then needs approximately **21 Discogs** requests.
  No paid enrichment API is introduced; quota/billing assumptions are in the plan.

## Prior work reconciled

The prior 700-artist decision ledger was imported and every ID excluded from
selection. The new 40 were prioritized by existing episode/line reach, not a
random yield sample; do not extrapolate acceptance rates from them.
`decisions-ledger.json` now excludes all **740** reviewed IDs in future batches.
Its 21 prepared entries are explicitly **not linked** yet.

All 133 pilot and 326 batch-1 links remain present; their artist rows exist;
no direct keys were added to those rows; **0 orphan links** and **0 verified
portraits belonging to a different linked ID**. All 459 portraits have verified
identity (426 with images, 33 verified without an image).

One batch-1 destination is now also held by a catalogue row: **Charles Sullivan,
Discogs 258371**, radio row `cdae3f80-e82b-40ad-8ee5-740138cb886b`, catalogue row
`a3eac22a-2595-49f1-8e6b-330a4889e2bf`. No merge or correction was performed.
The latest successful merge run was October 19 04:23 UTC, **before** batch 1.
Its post-merge integrity check is still pending the next run: **October 20
04:23 UTC / October 20 12:23 am EDT**. Re-run the prior integrity query afterward;
check Charles Sullivan specifically. Portrait drains are already complete.

## Excluded cases — no writes proposed

28 candidates passed remote identity evidence; seven were removed by destination
guards. Final result: **21 ready / 19 review / 0 automatically merged**.

| Artist | Review reason |
|---|---|
| Klein | Held by Klein (11) |
| Mike | Held by Mike (408) |
| Sully | multiple_discogs_pages |
| Moin | Held by Moin (2) |
| Djrum | discogs_billing_change |
| Priori | Held by Priori (2) |
| Gemini | multiple_discogs_pages |
| K. Hand | discogs_billing_change; substantive_billing_change |
| Stone | contradictory_title |
| Tinashe | Held by Tinashe (2) |
| Art Of Noise | discogs_billing_change |
| Rosalía | Held by Rosalía (3) |
| Sophie | Held by Sophie (42) |
| Earth | contradictory_or_missing_artist_credit; credit_mismatch_or_alias_requires_review |
| Pangaea | multiple_discogs_pages |
| David Axelrod | credit_mismatch_or_alias_requires_review |
| Solange | multiple_discogs_pages |
| War | multiple_discogs_pages |
| Budgie | contradictory_title |

Review rate is 47.5%, above the earlier approximate 20% stop threshold. Candidate
expansion stopped at this bounded set; no second sweep was started. Nineteen
cases stay out. Explicit approval of the concrete 21-row subset is required;
there is no unattended scale-up or relaxed matching to recover the others.

## Artifacts and execution conditions

- `manifest.json` / `manifest.csv`: full before state, exact insert IDs, source
  appearance IDs, recording witnesses, MusicBrainz/Discogs mapping, review cases.
- `apply.NOT-EXECUTED.sql`: atomic exact-count transaction, short lock timeout,
  capacity guard, unchanged normalized billing and witness-set guards, no existing
  artist/destination identities, no same-name conflicting key or merge pair.
- `rollback.NOT-EXECUTED.sql`: removes only the manifest's exact primary keys,
  entity IDs, provider, external IDs and provenance URLs. The portrait trigger
  rechecks afterward; it does not restore an old potentially wrong portrait.
- `preflight.json`, `reader-and-conflicts.json`, `integrity.json`: production
  read-only evidence; `evidence/`: raw remote replies with source URLs/times.
- `rehearsal.txt`: isolated local PostgreSQL integration checks. Exact apply
  count and actual 0083 trigger; repeated apply refused; exact and repeated
  rollback; changed witness, missing/renamed artist and conflicting/destination
  identity abort the whole batch; unrelated identical-link ownership survives.
- `recordings-staging.json` / `metadata-staging.json`: follow-on recording,
  release-reference, genre/tag and typed-relationship evidence. **Not applied.**
- `post-apply-checks.sql`: read-only portrait/ID integrity and completed merge
  verification. Re-run prior `integrity.sql` too.
- `youtube-refresh-plan.json`: explicit saved playlist IDs, last refresh dates,
  counts and request estimates. No new YouTube calls were made here.

After explicit approval: re-read this frozen manifest; create a separate local
reverification directory containing only its 21 candidates and source details;
collect **fresh**, uncached evidence with `Scripts/radio-enrichment-batch.py`.
Require identical recording credits, artist IDs and single Discogs destinations.
Re-run the read-only preflight and compare with the manifest. Any drift returns
that case to review; do not run apply after a failed comparison. Apply only the
approved SQL file and preserve its hash. Check total/row count immediately,
portrait IDs after drain and integrity after the next scheduled merge. Do not
manually invoke a merge. SQL rehearsals were entirely in a temporary local DB;
no production transaction, including rollback-only rehearsal, was executed.

Existing Release DIG still excludes these links behind `DiscogsIdentityRows`'s
Debug-only gate. Shared SQL readers and opted-in DIG can consume them; do not
claim shipped Release gains or new For You rankings. The ingestion plan is
[`ingestion-plan.md`](ingestion-plan.md).
No CloudKit, October 11 R2 generation, Radio Discover or ranking changes.
