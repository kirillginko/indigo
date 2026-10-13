# DIG remediation plan: structural relationships for the whole catalogue

*Prepared 2026-10-12 for review. Nothing here has been deployed, migrated or
backfilled. Every number comes from a read-only query or script in
`supabase/diagnostics/remediation/` and `Scripts/` (named in each section).
The October 11 knowledge generation is untouched; any knowledge this adds
enters a later generation.*

The goal is DIG: an artist page that leads somewhere, for as many artists as
possible. For You's ranking is a consumer of the same knowledge, measured
separately where it matters, never the target.

---

## 0. Baseline, and the constraint that orders everything

### Dead ends today

`baseline.sql` → `baseline-2026-10-12.json`. A **shared-catalogue dead end**
is an artist row from which the backend offers no route: no label it shares
with another artist, and no relationship row (radio neighbour, played-by or
any other) at either end. (A device can still walk Discogs live from such a
page; the backend gives it nothing to start from.)

| Artist rows | 118,607 |
|---|---|
| with a Discogs identity | 28,152 |
| radio names only (NTS key, no Discogs id) | 90,454 |
| with any catalogued release | 40,507 |
| with at least one label peer | 27,479 (23%) |
| with any relationship row | 98,413 |
| **dead ends** | **8,557 (7.2%)** |
| …with a Discogs identity | 7,908 |
| …with catalogued releases (all of them with a cached Discogs document) | 6,628 |
| …radio names with no relationship left | 648 |
| **thin: radio routes only, no label peer** | **82,571** |

Of 38,949 real labels, **24,749 have exactly one catalogued artist**: a label
shared by nobody gives no peer, which is why most dead ends are Discogs
artists *with* releases.

### The sample behind the estimates

`sample.sql` (reproducible) and `Scripts/remediation-sample.py` read 900 cached
release documents from R2: 600 across the catalogue and one each for 300
dead-end artists (of the 6,628 with releases). `Scripts/remediation-measure.py`
→ `measures-2026-10-12.json`. With samples this size, rates are ±4–5
percentage points; extrapolations below are rounded accordingly.

### Capacity: the database is full

**The database is 495 MB of the free plan's 500 MB.** Largest tables:
`music_relationships` 134 MB, `radio_appearances` 116 MB, `releases` 56 MB,
`external_ids` 50 MB, `artists` 37 MB. Any workstream that adds rows to
Postgres must first make room or move to Supabase Pro (paused growth lanes,
0065/0069, are waiting on that same decision). This plan therefore puts
**heavy, derived relationships in R2** (8 GB cap, 1.58 GB written; reads are
free; 2,517 of 800,000 writes used this month) and keeps Postgres to identity
and small summaries. Each workstream says which it needs.

---

## 1. Artist portraits

### What is wrong

`portraits.sql` + `Scripts/portrait-audit.py` decode which Discogs artist each
portrait image actually belongs to (its address encodes `A-<id>`), and compare
it with the row's own identity. 39,042 artist portraits come from Discogs:

| | Rows | Action |
|---|---|---|
| Verified: the image is the row's own Discogs id | 7,532 | keep |
| **Wrong: the row has an id; the image is another artist** | **121** | **re-fetch by id** |
| Ambiguous: no identity; the image is a numbered namesake that has its own catalogue row ("Nez" shows "Nez (13)", "Snow" shows "Snow (2)") | 587 | suppress until identified |
| Ambiguous: no identity; the name has numbered Discogs namesakes | 375 | suppress until identified |
| Unverified: no identity, no evidence either way | 30,409 | keep, mark unverified |
| Undecodable | 18 | leave |

The 121 are in `wrong-portraits-2026-10-12.json` (Hype Williams the duo
showing the director, Nirvana, Logic, Danny Brown, Om, Asa, Firefly, …); 18
show an artist who has a catalogue row of their own, 103 one who does not.

### Cause

`fetchArtistPortrait` (`discogs.ts`) searches Discogs by name and takes the
first result whose name matches once "(2)" is stripped. For any name Discogs
numbers, that is whichever namesake ranks first.

### Fix

1. **Selection rule** (worker code, no schema): when the row has a Discogs id
   (`discogs`, or `musicbrainz_discogs`), fetch the portrait from that
   artist's own document (`/artists/{id}`, primary image) — no search. With
   no id: search, and accept a result only if exactly one result matches the
   name (with or without a disambiguator); several namesakes → record a
   "withheld: ambiguous" miss, never a guess.
2. **Re-fetch the 121** through the new rule (121 paced Discogs requests).
3. **Suppress the 962 ambiguous**: record them as withheld misses
   (`original_url` null, with the reason), so DIG shows no portrait rather
   than a stranger's; they are re-asked when the row gains an identity.
4. **Re-check on identity**: when a row gains a Discogs id (adoption, merge,
   0076-style correction), re-queue its portrait.
5. The 30,409 unverified stay. The new rule governs every future fetch; a
   later pass can re-verify the old ones as rows gain identities.

**Reuses:** the portrait lane (`enqueue_artist_portraits`,
`fetch_artist_portrait`, `record_artist_portrait`, the paced Discogs fetch).
**Writes:** ~1,083 `artwork` rows updated; no growth. **Visible:** DIG
portraits change for those 1,083 artists — the intended fix.

---

## 2. Release indexing: every main artist and every label

### What is lost

`releases` keeps one `artist_id` and one `label_id`; the documents name all
of them. From the samples:

| | Across the catalogue (600) | Dead-end artists (300) |
|---|---|---|
| Joint releases (several main artists, "Various" excluded) | 27% | 35% |
| …with a partner who already has a catalogue row | 20% | 30% |
| Extra main artists per joint release | 1.45 | 1.72 |
| Releases on several labels | 9.7% | 6.3% |
| …dropping a label that has a catalogued roster | 7.8% | 3.7% |
| Mean roster of a dropped label | 49 artists | 44 |

Catalogue-wide, on 154,164 releases with a cached document: **~41,000 joint
releases** (~60,000 extra artist links, ~44,000 of them to catalogued
artists), and **~15,000 multi-label releases**, ~12,000 of them dropping a
label with a roster. The two §19 paths (Ciro Vitiello on Opal Tapes, Eric
Kloss on Music On Vinyl) are one example of each.

### Impact on dead ends

Indexing every main artist and label reaches **~33% of dead-end artists with
releases (≈2,200 of 6,628)**: ~30% through a joint partner who is in the
catalogue (a direct "made X together" route), ~4% through a dropped label with
a roster.

### Proposal

Index, per release: every main artist (by Discogs id, provenance
`release-document`) and every label (by Discogs id), from the documents
already cached. Two places it could live:

- **Postgres** (`release_artists`, `release_labels`, or arrays on
  `releases`): ~60,000 + ~15,000 rows ≈ 8–12 MB with indexes. Lets the SQL
  roster and peer queries (`knowledge_answers`, DIG search) use them
  directly. **Needs room first** (§0) and the standing "no new tables" rule
  lifted.
- **R2** (recommended while the database is full): per-artist and per-label
  derived objects built from cached documents — see §6 — with Postgres
  unchanged. The publisher and DIG read them as they read bundles today.

**Migration and controlled backfill requirements** (either way):

- Only artists and labels identified by **Discogs id from the document**;
  never by name. An extra artist with no catalogue row is recorded by id,
  not created.
- Batched by release id range, resumable, budget-reserved (`r2_reserve`)
  for R2; for Postgres, batches of a few thousand rows with `VACUUM` between
  them (a single large write is what bloated the database before).
- Pilot first: the 300 sampled dead-end artists; measure; then the 6,628
  dead ends; then everything — each a separate approval.
- Read-only verification after each batch: counts against the documents,
  no row without a document, no name-only links.

---

## 3. Credit identity

### What is lost

Every credit in a Discogs document carries the credited artist's id: **99%**
in both samples. 21% are credited under a spelling (ANV) that differs from
the artist's Discogs name — "Frederick Seibert" for Fred Seibert (409922).

- **In DIG on the device**, `GraphStore.addCredits` builds credit nodes from
  `DiscogsReleaseRecord.creditNames` as `.artist(name)` — no id. So a credited
  spelling and a canonical name are two people, and nothing lets the identity
  graph join them.
- **In the shared catalogue**, credits are not indexed at all (only the 15
  pilot bundles carry them). Yet they are the largest structural route for
  dead ends: **86% of dead-end artists' sampled releases credit somebody who
  has a catalogue row**; catalogue-wide, ~58% of releases do, and ~26% of all
  credits name a catalogued artist (~380,000 links of ~1.47 million credits).

### Proposal

1. **Device (DIG graph)**: record each credit's Discogs id alongside its
   credited name; build credit nodes with `discogsID`, keeping the credited
   name for display ("Producer on Now, credited as Frederick Seibert").
   `DiscogsReleaseRecord` lives in the Local cache store (not CloudKit), but
   V8 has written stores, so this is a **new schema version (V9)** with a
   lightweight migration that adds `creditIDs`; existing records fill as
   they are re-read (no backfill, no network: the documents are cached). The
   identity graph then places credited spellings under the artist's id.
2. **Shared catalogue**: index credits the same way as §2 — by Discogs id,
   role and release — **in R2** (~1.5 million credit entries is far too big
   for the database). Credited spellings kept as provenance.

**Impact:** with §2, credits take dead-end reach from ~33% to **~97% of dead
ends with releases (≈6,400 of 6,628)**; ~3% (≈220) have no structural route
in their documents at all.

---

## 4. Styles and eras

### What exists

Release documents carry Discogs **styles** (88% of releases), **genres** and
**year** (98%). Nothing in Postgres stores styles. They are broad:

| Styles by share of sampled releases | |
|---|---|
| Experimental | 13.3% |
| Techno | 12.5% |
| House | 12.2% |
| Ambient | 8.2% |
| Deep House | 5.7% |
| Downtempo | 5.5% |
| Electro | 4.5% |
| … 206 distinct in 600 releases | |

Genres are broader still (Electronic 55%), and are not used.

### Design: resemblance with controls

A style relationship says "sounds alike", not "connected". It must never
outrank or impersonate a verified connection, and must not join everyone to
everyone.

- **Profiles**: per artist, the styles of their own releases (main artist
  only, by Discogs id), weighted by release count, with the decades they
  span.
- **Specificity**: weight each style by inverse frequency across the
  catalogue; styles above ~5% of releases (the six above) count only in
  combination, never alone.
- **Relationship**: two artists are related when they share at least two
  styles of which one is specific (≤ ~2%), and their decades overlap; scored
  by weighted overlap (IDF-weighted Jaccard).
- **Caps**: at most ~20 style neighbours per artist, best first; a style
  edge is a separate kind (`sharedStyle` / `sameEra`), labelled as
  resemblance, and DIG lists it after verified routes.
- **Scope**: computed in R2 alongside §2/§3 from the same documents.

**Impact on dead ends:** 84% of dead-end artists' sampled releases have a
style; **62% (≈4,100 of 6,628) have a specific one (≤2%)**, 75% (≈5,000) at
≤5%. Most of those are also reached by §2/§3; style is the fallback route
and a way to rank them, not the main fix.

**Measured on DIG, not For You**: per-artist page route counts and dead-end
counts before/after, by kind — kept separate from the For You overlap
measurement (§19 of SHARED-KNOWLEDGE.md), which style would also move.

---

## 5. Radio granularity: artist → show → episode

### What exists

`radio.sql` → `radio-2026-10-12.json`: 1,975 shows (NTS 491, Lot Radio
1,406, YouTube 78), 10,555 episodes (9,188 with tracklists), 252,935
appearances (96% resolved to 98,299 artists). Artist→show `played_by` edges:
173,876, summarising 205,693 artist–episode pairs; **89% of artist–show pairs
are a single episode**. Only 11,545 `played_by` edges carry `episode_count`.

### Proposal

Keep three things distinct:

- **Artist → show** (`played_by`): "played on 239EF" — a recurring
  programme. Stays the summary edge, carrying `episode_count` and first/last
  aired dates, so DIG can say "played on 239EF in 3 episodes, latest
  December 2021".
- **Artist → episode**: "played in 239EF, 13 December 2021" — a specific
  broadcast. **Derived on demand** from `radio_appearances`, which is already
  per episode; not stored as edges (no growth). DIG's show page lists the
  episodes featuring the artists you came from; a recommendation names the
  episode only when it is one broadcast that played several of them (the
  §19 case).
- **Show → episode**: already `radio_episodes.radio_show_id`.

**Writes:** filling `episode_count` (and dates) on 162,000 `played_by` rows is
an UPDATE across a 134 MB table — batched, with `VACUUM`, after room is made
(§0). Episode edges add nothing to storage.

---

## 6. Infrastructure to reuse

| Need | Reuse |
|---|---|
| Release documents | 154,164 already cached in R2 (`releases/<id>.json`); no Discogs calls |
| Per-artist derived knowledge | `artist_bundle.ts` builder + `build_artist_bundle` job: today it reads a discography; a **catalogue bundle** variant reads the catalogue's own cached documents for an artist (`ownCachedReleases`, already in `knowledge_live.ts`), and adds every main artist, every label, credits by id, styles and years |
| Per-label rosters | the same pass, inverted: a label object listing every artist (by id) on its documents |
| Budget, immutability | `r2_reserve`, content-addressed objects + refs, write–read-back–verify (`knowledge.ts`) |
| Publication | the generation publisher (§14) pins whatever refs exist on its day |
| Identity rules | external ids only; `musicbrainz_discogs` for MusicBrainz-recorded links; 0076's merge rule |
| Portraits | the portrait lane (§1) |

---

## 7. Safe implementation order

Each step is its own commit and its own approval; nothing global without the
pilot's numbers first.

| # | Step | Needs | Writes | Est. effect |
|---|---|---|---|---|
| 0 | **Capacity decision**: reclaim space (e.g. prune or summarise `music_relationships`/`radio_appearances`) or move to Pro | decision | — | unblocks 2, 5 in Postgres |
| 1 | **Portraits**: selection rule by id; re-fetch 121; withhold 962 | worker deploy | ~1,083 artwork rows | 121 wrong faces fixed, 962 stranger risks removed |
| 2 | **Credit ids on the device** (V9 Local schema, `creditIDs`; nodes with `discogsID`) | app build | Local cache only | DIG credit routes join credited spellings to artists |
| 3 | **Catalogue bundles, pilot**: the builder variant over cached documents for the 300 sampled dead-end artists; label rosters for their labels | worker deploy | ~600 R2 objects | measure: dead ends reached, by kind |
| 4 | **Catalogue bundles, dead ends**: the 6,628 | approval after 3 | ~13,000 R2 objects | ≈6,400 dead ends gain routes (§2+§3) |
| 5 | **Style/era relationships** from the same objects, with the §4 controls; measured on DIG pages | approval | R2 only | fallback routes and ranking for ≈4,100 |
| 6 | **Radio**: `episode_count` + dates on `played_by` (batched); episode routes derived on demand | step 0 | 162,000 UPDATEs | show vs episode stated correctly |
| 7 | **Everyone**: catalogue bundles for all 28,152 Discogs artists and their labels | approval | ~70,000 R2 objects (~9% of a month's write cap) | the thin 82,571 radio-only pages gain label/credit routes where their artist is identified |
| 8 | **Postgres indexes** (`release_artists`/`release_labels`) only if SQL needs them directly | step 0 + approval | ~8–12 MB | SQL rosters without R2 |

Throughout: the October 11 generation stays as published; new knowledge is
published only as later generations, by approval; identity provenance kept
(Discogs id from the document, MusicBrainz-recorded links as such, credited
spellings as provenance); CloudKit data and the visible For You unchanged
until a separate switch.

### What this does not fix

- **1,929 dead ends with no catalogued release**: 648 radio names whose
  relationships are gone, ~1,280 Discogs rows from search hits with no
  discography. They need discovery (Discogs API, paced), not indexing.
- **~220 dead ends whose documents name nobody catalogued**: their routes
  arrive only as their collaborators enter the catalogue.
- **Radio-only artists with no identity** (90,454 rows): indexing helps only
  once a radio name is identified; identity work (MusicBrainz links, the
  verified-variation rule from 0076) is its own track.

---

## 9. Portraits: implementation status and what needs approval (2026-10-13)

**Where every artist portrait comes from.** One writer: the worker's
`fetch_artist_portrait` job (`record_artist_portrait`), which searched Discogs
by **name** and kept the first match; `merge_artist_halves` only moves a
portrait between rows it merges. So the 121 wrong, 962 ambiguous and 30,409
unverified portraits were all chosen by that rule — none by identity.

**The rule, rewritten (committed, not deployed):** `chooseArtistPortrait`
(`discogs.ts`), used by the worker job:

- The row's Discogs identity, best first — its own `discogs` id, then any
  `musicbrainz_discogs` — fetches **that artist's own document**
  (`/artists/{id}`, primary image, 150-pixel cut). No search; no namesake can
  answer.
- No identity: a search (25 results) is accepted only when **exactly one**
  Discogs artist carries the name (Discogs' "(2)" stripped, names folded).
  Several → **withheld**, recorded as a miss, so DIG shows no portrait rather
  than a stranger's. None → a miss, as before.
- A refusal (429) is retried, never recorded as "no picture".
- Tests: identity wins without a search; namesakes withheld; unique name
  accepted; spacer, empty document and unknown id are misses; 429 retried
  (`discogs_test.ts`, 5 new).

**The app has the same rule on its side.** `DigWorker.fillPortrait` falls
back to `artistThumbnail(named:)` — one search, first match — and the
device's `ArtistPortrait` cache is keyed by **name**; `adopt` copies the
backend's portraits in by name and never clears one. So a wrong portrait
already cached on a device stays even after the backend corrects it. Fixing
DIG needs both halves.

**Proposed, for approval (each step changes what DIG shows, as intended):**

1. **Deploy** the worker with the new rule. From then on every new portrait
   is chosen by identity or by a unique name.
2. **The 121 wrong**: enqueue `fetch_artist_portrait` for exactly those rows
   (`wrong-portraits-2026-10-12.json`) straight after the deploy. Each has a
   Discogs id, so each gets its own artist's picture, or a recorded miss —
   the wrong face is gone either way.
3. **The 962 ambiguous**: a dry run first — the same rule, run by the worker
   with a `dry_run` flag that logs the choice and records nothing — so we see
   how many the new rule keeps (a name only one Discogs artist carries),
   withholds (several), or finds nothing for, before any portrait is touched.
   Then re-run for real only those the dry run would change, after review.
4. **The app** (Local store only, not CloudKit; a schema change only if a
   field is added — not needed): `fillPortrait` uses the same rule — the
   resolved Discogs id when the row has one, otherwise a name only one
   Discogs artist carries; `adopt` also applies the backend's misses (so a
   withheld portrait clears the cached one), and portraits cached by the
   old name-only search are re-checked once.
5. The 30,409 unverified stay until their rows gain an identity or are
   re-asked; the new rule governs every future fetch.


---

## 10. Status, 2026-10-13: portraits done, catalogue pilot in DIG

**Capacity: closed.** The scheduled rebuilds after B2 (03:23, 06:23, 09:23, 12:23 UTC) all succeeded in 18–20 s; single-play radio links still 0 rows; postgres 413 MiB, all databases 448 MB of 500 MB.

**Portraits.**

| | |
|---|---|
| 121 confirmed wrong | 91 now the artist's own verified picture; 25 removed (own entry has no picture, now answered "no face", 0082); 4 were never wrong (merged Discogs entries keep the old image path); 1 late, verified |
| 6 more, found after | rows that gained an identity after the audit (Hype Williams the duo among them); re-fetched, verified |
| 962 ambiguous (dry run, nothing published) | 940 namesakes with no identity; 22 a unique name showing the same face; 0 resolvable by a verified id |

Invalidation is event-driven (0083): an identity added, moved or removed queues that artist's portrait once; devices read a change feed once a launch and re-read only the cached names it lists. App: identity-keyed portrait cache, no namesake's face on a row that knows its entry, the neutral placeholder otherwise.

**Credit identity.** No V9: V8's kept credits already carry each credit's Discogs id, and DIG has walked them since 453d247.

**Catalogue pilot.** 300 bundles built by the worker from the catalogue's own documents, published under `knowledge/v1/bundles` with references and one manifest under `knowledge/v1/catalogue/` (never For You's references, never a generation); 300/300 rebuild byte-for-byte from their documents (`Scripts/catalogue-pilot-verify.ts`). DIG reads them behind `-INDIGO_DIG_CATALOGUE_PILOT` (development builds only), never waiting on them.

On real pages (30 of the 300, live; `pilot-pages-{mac,ios}-2026-10-13.json`):

| | Mac | iOS simulator |
|---|---|---|
| pages offering a verified route, pilot off (store only) | 0/30 | 0/30 |
| …pilot on | 28/30 | 26–27/30 (two 10 s simulator timeouts fell back to the page as it was) |
| routes checked, each opening its own entry | 201, 0 wrong | 180, 0 wrong |
| first paint | 27 ms | 4 ms |
| bundle to routes: cold / disk / memory, p50 | 151 / 99 / 0 ms | 95 / 92 / 0 ms |

The 2 pages with nothing are the pilot's remaining dead ends (documents name nobody catalogued). A caveat on "off": the test host does not call Discogs, and the real app does when a page opens — Magic Carpathians Project's page fetched its 30 releases live — so the pilot's gain on a real device is routes at once, without the Discogs budget, rather than routes where there would never have been any. Seen on the iPhone simulator: the page lists the bundle's "Credited together" and personnel rows (Six Organs Of Admittance, Ben Chasny, …) with the record each rests on.

Not done: no rollout beyond the 300; the r2.dev public host is fine at pilot scale but rate-limited, so a wider rollout wants the bucket on a custom domain first.

---

## 11. Limited-release preparation (2026-10-13)

**Portraits.** The 940 identity-ambiguous portraits are withheld (guarded, reversible: `portrait-withhold-2026-10-13/`); devices drop the cached faces through the change feed (verified live). The 22 unique-name portraits are `unresolved`: shown, never verified.

**Pilot behaviour, measured in the running app** (iOS simulator, the app's own Discogs and R2 reads on; `pilot-pages-app-ios-2026-10-13.json`): every one of 22 pilot pages shows its bundle (140 rows, 101 people the same session's own discovery had not shown); 21/21 bundle rows opened their own artist; no duplicates, no alias offered as a collaborator; bundle-only routes rank a shade under the device's own (95%), so they never push out what the page found itself. Time to the first route on the test host: 277 ms p50 with the pilot, 771 ms from the device's own discovery. The pilot saves no Discogs requests yet: discovery runs as before (a later optimisation, not before release).

**Remote switch (0084).** `public.dig_enrichment_config()` — a function, no table, independent of every generation:

| field | now | meaning |
|---|---|---|
| enabled | true | false turns every device off at its next check |
| cohorts | `debug` | who may receive it: `debug`, `testflight`, `appstore` |
| manifest | `5d20a44c…` | the one manifest devices read: the 300 approved artists |
| ttlSeconds | 900 | asked again after 15 min, in the background |
| offlineGraceSeconds | 86400 | offline, the last answer holds 24 h, then off |

Never read: off. Checked at every bundle read, cached ones included. Off deletes nothing. `Scripts/dig-enrichment-switch.sh off | on <cohorts…> | show`. A limited release is `on debug testflight`; nothing reaches the App Store cohort until it is listed.

**Custom domain (not done: needs the Cloudflare account).**
1. Cloudflare → R2 → the `indigo` bucket → Settings → Custom Domains → Connect Domain: a dedicated hostname on a zone in the same account (e.g. `cache.<domain>`). Same bucket, same paths; nothing moves.
2. Caching → Cache Rules: for that hostname, *Eligible for cache*, Edge TTL *use cache-control header if present*. Cloudflare does not cache `.json` by default; without this rule the edge cache check fails.
3. `deno run --allow-net Scripts/r2-domain-check.ts <hostname> pub-480815b6ab564616ae87a484cb506184.r2.dev` until `ready: true` and the second read shows `cf-cache-status: HIT`.
4. Then, and only then, `CATALOG_CACHE_HOST` in `Config/Indigo.xcconfig`, a Mac and an iPhone run, and a release.

**Manual Mac check (Debug build from Xcode, `-INDIGO_DIG_CATALOGUE_PILOT YES` not needed: the switch is on for debug).**
- Magic Carpathians Project: "Credited together" Six Organs Of Admittance and Vibracathedral Orchestra; personnel Ben Chasny et al.; each opens its own page.
- Hype Williams: the duo's picture or none — never the film director's.
- A namesake (e.g. Speedy J): no face that belongs to the other entry.
- An artist outside the pilot (e.g. Prefuse 73): unchanged.
- From a credited release, a credit opens the credited artist, not a namesake.
- `Scripts/dig-enrichment-switch.sh off`, then wait out the 15-minute TTL (a relaunch keeps the last answer until then): the pilot rows are gone; `on debug`, 15 minutes again: back.
