# Shared knowledge for For You — architecture audit and plan

*2026-10-11. Supersedes the plan behind the first backend shadow comparison
(0072, October 8). Decisions recorded 2026-10-11 (§6). Nothing here has been
started; Phase 1 begins after the real-Mac For You check.*

**Objective.** When the Mac and the iPhone hold the same synced personal data
and the same shared knowledge generation, For You ranks the same
recommendations on both, in the same order, with the same scores — and the
FY diagnostic code says so, part by part.

Not in scope for any phase below until agreed: a global R2 backfill, new
Supabase tables, ranking-weight changes, and making backend knowledge
authoritative before the shadow says it is ready.

---

## 1. Where things stand

### Already identical across devices

| Input | How | Evidence |
|---|---|---|
| Crate, listening, visits, steps, counters | CloudKit (UserData store) | Production rollout verified on Mac + iPhone, 2026-10-03 |
| Evaluation day | `ExplorePeriod` (UTC day) | FY stamp `period` |
| Ranking | `ExploreRanker`, pure function of (personal, knowledge, asOf) | golden + determinism suites; identical stamps → identical offers and score bits |
| Known-artist policy | `KnownArtistPolicy`, pure | unit tests; namesake-safe |
| Presentation order | `presentationKey` tie-breaks | 82e1ea5 |

### Built since the first shadow comparison

- **Artist identity in the graph** (453d247 … d4df0a2). Verified artists are
  nodes keyed `artist:discogs:N`; unresolved artists keep their folded name;
  aliases are separate identities linked by edges; namesakes are separate
  unless something identifies them. Placement rests only on evidence
  (credit, entry link, verified spelling, MusicBrainz link); a filed record
  or a name alone never places an identity. History is canonicalized at read
  time; no synced record is rewritten.
- **Verified spelling equivalence** (`SpellingVerdict` from complete Discogs
  searches) and **separate musical aliases** (`AliasEdgeIdentity`, entry
  links).
- **Identity-aware For You** (05583b9): starting points, walks and history
  under identity; one artist one candidate across starting points;
  known-artist exclusion before cutting; `KnowledgeSnapshot.currentFormat`
  2.
- **Scoped identity digest** in the stamp: the content of exactly the
  evidence each walk rested on; known artists as their own part.
- **FY2 diagnostics**: `FY2.day.personal.shared.device.identity.known.ranked`,
  comparable part by part with another device's code (older 6-part codes
  read as "—").
- **Performance** (d4df0a2): a cold For You no longer assembles the graph's
  tables (real store ~4.3s → ~2.8s; 1.5s before identity) and no longer holds
  DIG up (a page asked for during a cold look: 3.5s vs 7.1s before identity).
  Release-map hand-on verified for in-place updates, replacements, deletions
  and imports (6dc9aa0).

### Shared knowledge that exists today

- **`explore_knowledge(p_nodes, p_artists)`** (0072 → 0073 → 0074): one
  STABLE read-only statement; answers per entity (≤12 starting points, ≤50
  artists per call), so answers can be kept by entity; finds artists by name
  key, MBID or Discogs id and lists the identities it used (format 2);
  returns `generation` (`edges-NNNN`) and `nextGenerationAt`. Labels,
  releases, radio, scene rosters, genres. No credits.
- **Edge generation**: rebuilt every third hour (`:23` UTC), in place
  (0037, 0050: "rebuild without rewriting"). Only the current generation
  can be read.
- **R2 artist knowledge bundles** (`indigo.artist-knowledge/1`,
  `_shared/artist_bundle.ts`): pure fold of an artist's Discogs release
  documents — releases with relation, collaborators, per-role credits with
  Discogs ids and ANVs, labels by Discogs id, styles, genres, years — stored
  by digest, with a per-artist reference naming the current one. Coverage
  is per artist and can be partial (Hype Williams: 71 of 84 documents).
- **R2 release documents**: ~150,000, the source of bundles and of the app's
  release-credit backfill.
- **Device-side backend client** (`BackendKnowledge.swift`,
  `BackendBundles.swift`): per-entity answers kept on disk by edge
  generation; bundles kept by digest; offline ranks from what it has and
  says how old; never fills gaps from local caches. **Shadow only.**

### How far apart they are

The last backend shadow (2026-10-08, this Mac): **top-12 overlap 1/12,
top-20 1/20**, 3 calls, 641 KB, 3.6s cold. Without bundles the backend has
no producer, personnel or collaborator routes; its top 20 was label and radio
routes only. With bundles the route kinds were present but wording and
coverage differed. That was before identity: backend answers name Discogs
identities, the visible For You did not.

## 2. Why the two devices still differ

Every one of these is a way two devices with identical synced data can rank
differently today. Each phase below removes some of them.

| # | Source of difference | Where |
|---|---|---|
| D1 | **Knowledge is each device's own cache**: graph edges exist where that device has browsed | `LocalKnowledgeAdapter`, `GraphStore` stored edges |
| D2 | **Identity evidence is each device's own**: spelling checks, release-credit backfill, filed records — accumulated by browsing | `ArtistSpellingRecord`, `ReleaseCreditRecord`, `DiscogsIdentityRecord`, `DiscogsArtist` (local store) |
| D3 | **Show profiles** come from the appearance log each device has fetched | `ShowSuggestionEngine.profiles` |
| D4 | **Artist tags** (the taste profile) come from the local Discogs cache | `LocalKnowledgeAdapter.artistTags` |
| D5 | **Scenes** come from the local `SceneEngine` catalogue | direction |
| D6 | **Device-local library** edges and counts feed ranking | `KnowledgeSnapshot.deviceLocal` |
| D7 | **Generation skew**: two devices asking hours apart get different edge generations, and an older one cannot be asked for again | in-place rebuild |
| D8 | **Partial coverage** differs if it depends on what each device fetched or when | bundles, answers |

The scoped identity digest makes D2 *visible* but cannot prove two devices
share identity knowledge: each digest covers only the evidence that device
encountered. Equal digests mean "placed the same nodes on the same evidence",
not "know the same things".

## 3. Target

**One design rule above the rest: the generation describes music, not For
You.** It holds entities (artists, labels, releases, broadcasts, shows),
their verified identities, and their relationships with kind, source and the
record each rests on — in the vocabulary DIG's graph already uses. For You is
its first reader, not its shape: the same generation should later serve
personalized mixes, curated playlists, discovery journeys and Bandcamp or
SoundCloud exploration without being rebuilt. Anything specific to one
algorithm (scores, cut-offs, which blocks exist) stays on the device.

```
For You  =  rank( personal(CloudKit),  knowledge(G),  identity(G),  day )
```

where **G is one immutable shared knowledge generation** both devices can
name and fetch, and nothing in `knowledge(G)` or `identity(G)` depends on
the device.

- **One generation per UTC day, published atomically**: a manifest in R2,
  immutable, under its digest — the edge generation it was cut from, the
  identity snapshot it carries, the bundle references current at that
  moment, and the format. Objects are written first and the manifest last, so
  a device can never see a generation with parts missing. A small, mutable
  pointer per day names that day's manifest; both devices select the same
  complete generation when one exists, never the newest mutable data.
- **Retention: seven daily generations.** Every object is content-addressed,
  so a bundle or answer unchanged between days is stored once and shared by
  every manifest that names it. An object is removed only when no retained
  manifest references it. A device returning after more than seven days
  moves to the current day's generation and says so in its diagnostics; it
  never ranks from a mix of an old manifest and new objects.
- **Per-entity answers inside the generation**, immutable: what
  `explore_knowledge` answers today for a starting point or an artist, cut
  once per generation and published under digests — so a device can ask for
  generation G's answer for "Dean Blunt" hours later and get the same bytes.
- **An identity snapshot per generation**: the mappings the backend can
  justify — name key → Discogs entry with its evidence class (Discogs id on
  the row, MusicBrainz link, verified spelling, credit), alias links, and
  explicit namesake markers for names more than one entry answers to. For
  You's canonicalizer reads this instead of the device's own evidence.
  DIG's pages can keep using local evidence on top.
- **Identity scope from shared inputs only**: the snapshot covers the
  recommendation neighbourhoods that were asked for and the candidate
  identities inside them. What is asked for is derived from the synced
  personal data (the starting points) and the generation itself — never
  from what a device happens to have cached, so two devices asking for the
  same starting points get the same identities.
- **Pinning**: For You ranks only from one generation at a time; the stamp
  names it. A device that has not got all of G's answers for its starting
  points either fetches them or keeps showing the last complete answer —
  it never mixes generations or fills from local caches.
- **Day-stable choice of generation**: both devices use that UTC day's
  generation, so devices that open For You hours apart still agree for the
  day. Before the day's generation is complete, both keep the previous
  day's.
- **Device-local knowledge stays out of the shared ranked blocks.** Library
  relationships remain in DIG; "Back in your library" stays local and
  unranked against the rest. A library-specific discovery section may come
  later, as its own block.
- **Stamp** gains the generation id; a cross-device test asserts: equal
  `personal` + equal generation ⇒ equal `ranked`.

## 4. Phased proposal

Each phase ends with a measurement, not a switch. No phase changes ranking
weights.

### Phase 1 — Identity-aware shadow parity (app only; no backend change)

Put the backend's answers through the same identity layer the visible For
You uses, and measure where the shared knowledge stands. No generation
publishing, no backend change, no change to the visible For You.

1. Rank three ways through the identity-aware path, from the same personal
   data and the same day: **SQL only**, **SQL + R2 bundles**, and the
   **current visible** (local) knowledge.
2. Canonicalize backend answers with the backend's own identities (format 2
   lists them per node) under the same `GraphCanonicalizer` rules; the same
   one-artist-one-candidate pass and known-artist policy.
3. Report, for each pair: ranked overlap; candidate reach (how many of each
   side's candidates the other can reach at all); missing relationship
   categories; identity coverage (verified, unresolved, alias, namesake);
   known-artist exclusions.
4. Attribute every difference to **source knowledge** (an edge or entity one
   side has and the other lacks) or **identity evidence** (the same edges,
   placed differently), by re-running each side's knowledge under the other
   side's identities.
5. Measure response sizes, query timing per call, cache reuse across looks
   and generations, and partial failures (unknown entities, missing or
   partial bundles, timeouts).
6. An FY-style code for the shadow, so the Mac's and iPhone's shadow codes
   compare like the visible ones.
7. Run on the Production copy (offline audit) and live on the Mac; on the
   iPhone when its simulator has network.

*Exit*: no threshold against the local engine. Phase 1 reports, for the
backend knowledge: cross-device determinism (identical shadow codes when
inputs match), identity correctness (no false merges, namesakes apart),
relationship coverage by kind, recommendation quality and diversity (what is
offered, by how many independent routes, across how many kinds), explanation
accuracy (each reason rests on a real record), offline behaviour, and
performance. Those decide what Phases 2 and 3 must improve.

### Phase 2 — Generation pinning, in shadow (worker + R2; no new tables)

1. **Cut once a day, for a demand set, published atomically.** The worker
   computes the day's per-entity answers in one pass from one database
   snapshot, for the *demand set*: every entity devices asked about in the
   retained week, plus the candidate identities one step out of them. It
   writes the objects (content-addressed, unchanged ones not rewritten,
   budgeted through `reserveR2`), then the manifest, then the day's pointer.
   Nothing is computed into a generation after it is published — computing
   later would read newer tables, and the generation would depend on which
   device asked first.
2. **The demand set comes from shared inputs.** Devices ask for entities
   derived from synced personal data (the starting points), so two devices
   with the same data ask for the same ones. A starting point new today
   joins tomorrow's set; until then both devices treat it alike — present in
   the inputs, absent from the generation — and the diagnostics count it.
   Where the demand set is recorded without a new table (an R2 object per
   day, or the existing job queue) is a Phase 2 design question.
3. Day-stable generation choice in the client; the shadow fetches by
   generation and never mixes two.
4. Identity snapshot v0 published inside the manifest, built from what the
   backend already holds: `external_ids` (including `musicbrainz_discogs`),
   Discogs ids on artist rows, and bundles' credit ids — scoped to the
   demand set's neighbourhoods and candidate identities, not the catalogue.
5. Retention: seven manifests; an object is deleted only when no retained
   manifest references it.

*Exit*: two devices fetching the same day's generation hours apart get
byte-identical answers and the same shadow ranking; a device offline for
over a week returns to a retained generation cleanly.

### Phase 3 — Close the knowledge gap (worker; bundles; still shadow)

1. Bundles for every starting point and every artist one step out that the
   shadow asks for, built on demand (budgeted), so credit routes stop
   depending on what a device has opened.
2. Shows and artist genres from the generation (D3, D4); scenes from the
   generation's rosters (D5).
3. Coverage rule written down and tested: what an absent bundle or answer
   means for ranking, identically on every device.

*Exit*: on the same dimensions as Phase 1 — determinism across devices,
identity correctness, coverage by relationship kind, quality, diversity,
explanation accuracy, offline behaviour, performance — the shared knowledge
is at least as good as the local engine's, with every remaining difference
explained. Overlap with the local engine is reported but is not a target.

### Phase 4 — Backend-authoritative For You (behind a switch)

1. Visible For You ranks from the pinned generation; local knowledge is no
   longer an input. `KnowledgeSnapshot.currentFormat` 3; stamp carries the
   generation.
2. Offline: the last complete generation's answers, kept on disk; a device
   that has never fetched any shows the local answer, marked internally as
   non-shared (diagnostics only, no UI indicator).
3. Two-device check: Mac and iPhone FY codes equal part by part on the same
   day; the ranked part equal.

*Exit*: identical For You on Mac and iPhone across a week of real use.

### Phase 5 — Retire

See §5.

## 5. What can be retired once shared knowledge is authoritative

| Local work | Fate | Why |
|---|---|---|
| For You's local walks: `LocalKnowledgeAdapter.neighbourhood/snapshot`, `exploreCache.walked`, walk evidence digests, the identity pass, `IdentityChecks` noting from For You | **Retire** | knowledge and identity come from the generation |
| Release map light read and hand-on (`GraphStore.releaseIDs(creditedTo:)`), scoped credit reads for For You | **Retire** (keep for DIG if DIG still needs it) | For You no longer walks |
| Cold For You cost (~2.8s) and its DIG contention | **Gone** | a pinned generation is a few cached reads |
| Shadow code: `BackendKnowledge` shadow mode, `ExploreIdentityShadowMeasurement`, `ExploreShadowMeasurement` | **Become** verification tests of the authoritative path | |
| `ShowSuggestionEngine.profiles`, `artistTags`, `SceneEngine` catalogue for direction | **Retire for For You** | from the generation |
| Per-device identity evidence *for For You* | **Retire** | identity snapshot |
| `ExploreRanker`, `KnownArtistPolicy`, `PersonalInputs`, stamps, FY diagnostics, `ExploreOffersRecord` | **Keep** | pure and personal; the parts that already agree |
| DIG's graph, `IdentityGraph`, local identity evidence, DEEP/RELATED | **Keep** | pages need depth, radio and the listener's library; may later read bundles and the identity snapshot too |
| Release-credit backfill for DIG pages (`backfillReleaseCredits`) | **Candidate** | bundles carry the same credits for artists that have one |

## 6. Decisions (2026-10-11)

1. **Library out of the shared ranked blocks.** Device-local library
   relationships do not influence For You's shared ranked blocks; they stay
   available in DIG. A library-specific discovery section may be considered
   later.
2. **One immutable generation per UTC day, published atomically.** Both
   devices select the same complete generation when one is available, never
   the newest mutable data.
3. **Seven daily generations retained**, content-addressed so unchanged
   objects are stored once; referenced objects are preserved; devices
   returning after a long time offline move to a retained generation
   cleanly.
4. **Identity scoped to the requested neighbourhoods and their candidate
   identities**, derived from shared inputs only — never from what a device
   has cached.
5. **No overlap threshold against the local engine.** Evaluate cross-device
   determinism, identity correctness, relationship coverage, recommendation
   quality, diversity, explanation accuracy, offline behaviour and
   performance.
6. **General, not For You–specific.** The generation describes entities,
   identities and relationships with provenance, so later features (mixes,
   playlists, discovery journeys, Bandcamp/SoundCloud exploration) can read
   it without new infrastructure (§3).

Still open: where the demand set is recorded without a new table (Phase 2);
the exact on-device fallback for a device that has never fetched any
generation (Phase 4); and whether DIG's pages also read the identity
snapshot.

## 7. Constraints carried forward

- Supabase free plan: 500 MB database (394 MB on 2026-09-16), growth lanes
  paused (0065/0069); anon 3-second statement timeout; app-callable
  functions only via `app_callable_functions()`.
- R2 free tier: every write through `reserveR2`.
- Discogs request budget: devices must not need more Discogs calls to agree.
- `fetchedAt` stamping is load-bearing for local release caches (6dc9aa0); any
  bulk import path must stamp local write time.
- CloudKit records are never rewritten for identity; history is read under
  identity.

## 8. Phase 1 results (2026-10-11)

Measured by `IdentityParityMeasurement` (opt-in,
`TEST_RUNNER_INDIGO_MEASURE_PARITY=1`) on copies of this Mac's Development
and Production stores against the live backend (edge generation
`edges-165903`). Every variant starts from the same synced rows and the same
evaluation day (20737) and goes through the same identity-aware ranker and
known-artist policy. Identity is varied separately from knowledge:
*device* (this Mac's evidence) and *backend* (a MusicBrainz link for a
starting point, a credit's Discogs id for anyone a bundle names; never a
row matched by name).

### Overlap with the visible For You (top 20)

| Knowledge · identity | Development | Production copy |
|---|---|---|
| local shared part (library removed) · device | 20/20 | 20/20 |
| local shared part · backend | 20/20 | 20/20 |
| SQL only · backend | 0/20 | 1/20 |
| SQL + bundles · backend | 0/20 | 1/20 |
| SQL + bundles + styles · backend | 0/20 | 1/20 |
| SQL + bundles · device | 1/20 | 2/20 |

Top 12: 0/12 for every backend variant on both stores.

### Why they disagree

Visible top 20 against SQL + bundles (backend identity):

| Cause | Development | Production |
|---|---|---|
| Knowledge — no route at all | 7 (all label peers) | 8 (all label peers) |
| Selection — reached, ranked lower (#59 … #706) | 13 | 11 |
| Identity | 0 | 0 |

The backend's top 20 against the visible: 19 of 20 (Development) and 18 of
19 (Production) are knowledge the local engine does not have — radio shows
(the backend holds 364 show profiles; this Mac's appearance log 31) and the
peers of labels this Mac never walked (FACT Magazine, World Music, Hyperdub).

### What the measurements say

1. **The two engines rest on different knowledge, not different identities.**
   Local knowledge ranks identically under either identity source. The
   disagreement is about which labels' rosters, which radio and which
   credits each side holds.
2. **Unresolved SQL artist edges split routes under verified identity.**
   Since 0074 the backend's SQL edges carry no artist Discogs ids. Under
   backend identity a bundle's credit reaches an artist as their entry while
   SQL reaches them by name; the two do not add up, and producer and
   collaborator routes fall out of the top 20 (top 20 kinds:
   `playedInShow 6, sharedLabel 14`). Counting single-owner name routes
   toward their entry — what ids on SQL edges would do — restores them
   (`collaborator 3–4, producer 2, personnel 0–1`). This is the largest
   identity effect measured, and it is a knowledge-format gap, not a reason
   to trust names.
3. **The backend's explanations are better evidenced.** Every top-20 reason
   names a record, label or show (20/20 against the visible 15–16/20);
   corroboration by two or more strong starting points is 14–18 of 20
   against the visible 1–2. The visible engine's depth is mostly broad label
   peers counted from several starting points.
4. **Identity coverage comes from bundles.** Backend identity verifies
   249–366 artists one step out (all from bundle credits), the device 0 on
   this collection. Starting points themselves are rarely verified: one has
   a MusicBrainz link. No namesake collisions. Known artists kept out: 14–17
   under backend identity, 0 under the device's.
5. **No alias relationships reach For You from the backend** (0 alias edges
   in any backend variant): bundles do not carry an artist's aliases, groups
   or members.
6. **No scene direction from the backend** (`-` in every backend variant):
   rosters do not make a scene catalogue the ranker can use. The visible
   direction also moves with the library (Manchester HIP HOP with it, Berlin
   DUB without), so decision 1 applies to direction too.
7. **Shows never overlap** (0 of 4–6): the backend's show knowledge is far
   larger and differently built (episode genres) than the local appearance
   log.
8. **Coverage and failures.** Starting points the backend knows: 8 of 12
   (Development), 7 of 12 (Production); the rest unknown (broadcasts,
   stations) or unsupported. Bundles: complete 4–5, partial 1 (Hype Williams
   71/84 documents), missing 1–4. Artists: 140–143 found, 8 unknown.
9. **Performance.** Cold: 3–4 calls, 646–721 KB, 0.3–4.6 s per call; one
   statement timeout retried on Development's first call. Bundles: 13–14
   reads, 104–138 KB. Warm, same generation: 0 calls and 0 reads — full
   reuse.

### Priorities for Phases 2 and 3

1. **Identity on every relationship target (Phase 2, with the identity
   snapshot).** Restore Discogs ids on SQL artist targets, and publish them
   per generation rather than looked up per call (the reason 0074 dropped
   them). Biggest measured effect; prerequisite for verified identity to help
   rather than split routes.
2. **Bundles for starting points and their candidates (Phase 3).** Missing
   and partial bundles are where credit routes vanish; build them for the
   demand set.
3. **Aliases, groups and members in bundles (Phase 3).** None reach For
   You from the backend today.
4. **Scenes and shows from the generation (Phase 3).** No backend direction;
   show knowledge is large but unmatched with the local log. Decide which is
   authoritative for show recommendations before comparing further.
5. **Starting-point identity (Phase 2).** Most starting points are reached
   by name only; the snapshot should carry the MusicBrainz and credit
   evidence that places them, so known-artist exclusion does not depend on
   bundles happening to name the listener's artists.
6. **Immutable generations (Phase 2).** Needed for cross-device determinism;
   Phase 1 could not test it across devices (the iPhone simulator has no
   network), and one cold call hit the statement timeout.

Not measured yet: the iPhone (simulator without network), and recommendation
quality beyond evidence — whether the backend's label- and radio-heavy top
20 is *better* music for this listener is a judgement the numbers above
cannot make.


## 9. Phase 2 design: immutable knowledge generations (proposal, 2026-10-12)

*For review before any publisher code. Pilot-sized; nothing global.*

### 9.1 What a generation is

One generation per UTC day: **every answer in it computed from one Postgres
snapshot**, materialised into immutable R2 objects, and named by a manifest
that is itself immutable. Postgres is read once per generation; after that,
the generation never depends on Postgres again, so a published generation is
reproducible for as long as it is retained, whatever the tables do.

**One snapshot, no new tables.** The worker reaches Postgres through
PostgREST, where every call is its own transaction — so a generation built
from many `explore_knowledge` calls over minutes would mix database states,
and the edge rebuild (every third hour at :23) or radio ingest could land
between two of them. The cut is therefore **one SQL statement**: a new
service-role-only function, `knowledge_cut(p_batches jsonb)`, declared `STABLE`
`LANGUAGE sql`, that applies `explore_knowledge` to every batch of the demand
set inside one query. `STABLE` functions called from a query see that query's
snapshot, so every answer — and the `generation` id each reports — comes
from the same database state. It also returns `pg_current_snapshot()` and the
statement's start time as the generation's source watermark. No table is
added; the function is read-only and not callable by `anon`.

If the pilot's demand set ever outgrows one statement's comfortable runtime,
the fallback is a direct Postgres connection holding one `REPEATABLE READ
READ ONLY` transaction across calls — same guarantee, more moving parts.

**Bundles are pinned by digest.** Artist bundles are built independently and
their `refs/artists/<id>.json` move at any time. The manifest records the
bundle *digest* each starting artist had when the cut read its reference, so
the generation names immutable objects only.

### 9.2 R2 layout

Alongside the existing `knowledge/v1/` objects (pages, discographies,
bundles, refs), under `knowledge/v1/generations/`:

| Key | Mutable | Cache-Control | What |
|---|---|---|---|
| `objects/<aa>/<sha256>.json` | never | immutable, 1 year | one entity's answer (§9.4) |
| `identity/<aa>/<sha256>.json` | never | immutable, 1 year | the generation's identity snapshot (§9.5) |
| `manifests/<aa>/<sha256>.json` | never | immutable, 1 year | a manifest (§9.3) |
| `days/<YYYY-MM-DD>.json` | write-once | immutable | `{date, manifest, publishedAt}` |
| `current.json` | yes | 60 s | the retained, complete generations, newest first |

Every object is content-addressed: an entity answer unchanged since yesterday
is the same digest and is not written again. `days/<date>.json` is written
with `If-None-Match: *` (R2 supports conditional PUT), so a day is published at
most once and can never be overwritten.

### 9.3 Manifest schema (`indigo.knowledge-generation/1`)

General, not For You–specific: entities, their identities, and their
relationships with provenance. Ranking stays on the device.

```json
{
  "format": "indigo.knowledge-generation/1",
  "id": "kg-2026-10-12",
  "date": "2026-10-12",
  "previous": "<manifest sha256 of the last published generation, or null>",
  "source": {
    "cutAt": "2026-10-12T00:41:07Z",
    "snapshot": "<pg_current_snapshot() text>",
    "edgesGeneration": "edges-165911",
    "statementMs": 8421,
    "bundleRefsReadAt": "2026-10-12T00:41:20Z"
  },
  "demand": { "digest": "<sha256 of the sorted demand set>", "nodes": 34, "artists": 312 },
  "identity": "<sha256 of the identity snapshot object>",
  "nodes": {
    "artist:hype williams": {
      "status": "found",
      "answer": "<object sha256>",
      "coverage": { "edges": 241, "kinds": { "sharedLabel": 120, "playedInShow": 31 },
                    "targetsWithDiscogsID": 180, "targetsByName": 61 },
      "bundles": [
        { "discogsID": 1874027, "digest": "<bundle sha256>", "status": "partial", "read": 71, "of": 84 },
        { "discogsID": 398459, "status": "missing" }
      ]
    },
    "broadcast:nts|guests": { "status": "unsupported" },
    "artist:somebody new": { "status": "deferred" }
  },
  "artists": {
    "dean blunt": { "status": "found", "answer": "<object sha256>",
                    "coverage": { "episodes": 12, "genres": 7, "rosters": 2 } }
  },
  "summary": {
    "complete": true,
    "nodes": { "found": 30, "unknown": 2, "unsupported": 2, "failed": 0 },
    "artists": { "found": 300, "unknown": 12, "failed": 0 },
    "bundles": { "complete": 20, "partial": 3, "missing": 4, "noIdentity": 1 },
    "shows": 410, "sceneRosters": 38
  }
}
```

**Statuses** are explicit and closed: `found`, `unknown` (the backend has no
such entity), `unsupported` (a kind it does not walk), `deferred` (not in the
demand set this generation — see §9.7), `failed` (could not be computed).
Partial knowledge (a partial bundle, a neighbourhood with name-only targets)
is `found` with its coverage numbers, never silently filled in.

**Complete** means: every demanded entity has a terminal status (`found`,
`unknown`, `unsupported`) and every object the manifest names was written,
read back and verified by digest. A generation with any `failed` entity is not
complete and is not published.

### 9.4 Entity answers and relationship provenance

An entity answer is `explore_knowledge`'s answer for that one node or artist
(format 3), with every relationship target carrying how it is identified:

```json
{ "kind": "artist", "name": "Dean Blunt", "key": "dean blunt",
  "discogsID": 2419343, "idEvidence": "discogs-document" }
```

| `idEvidence` | Meaning | Places an identity on the device? |
|---|---|---|
| `discogs-document` | the row was created from a Discogs document under this id | yes (an external id) |
| `musicbrainz-link` | MusicBrainz links the row to this Discogs id (`musicbrainz_discogs`) | yes |
| `credit` | a release credit names this entry (bundles) | yes |
| `adopted-by-name` | the row was first filed by name (radio) and later took this Discogs id because it was the only row with that folded name | no — kept, marked consistent, never placed |
| absent | no Discogs id | no — the target stays name-only |

The publisher never derives an id from a name; it only carries ids the
catalogue holds, with the evidence above. `adopted-by-name` exists because the
worker's `resolveEntity` adopts a uniquely named row when a Discogs id arrives
(that is how radio artists gained ids); `external_ids` does not record which
rows that happened to. The pilot classifies them without a new table: a row
holding both an `nts` and a `discogs` external id was adopted; a `discogs`-only
row came from a Discogs document. The pilot reports how many targets fall
into each class before the client trusts any of them.

Restoring ids on SQL artist targets is Phase 1's top priority (§8). They were
dropped in 0074 because looking them up per call cost 1,400 lookups and the
statement timeout; here they are looked up once per generation, by the
service role, without anon's timeout.

Aliases stay distinct: an `aliasOrProject`/`sameAlias` edge keeps both
entities, each with its own id and evidence. Unresolved name-only targets stay
name-only.

### 9.5 Identity snapshot

One object per generation, scoped to the demand set's entities and their
candidate identities (decision 4): for each name key the generation touches,
the Discogs entries with evidence (`discogs-document`, `musicbrainz-link`,
`credit`), explicit **namesake markers** where more than one entry answers to
the same name, and alias/group/member links between entries. Derived only
from catalogue rows, `external_ids` and pinned bundles — never from any
device's cache. The device's canonicalizer reads it as backend identity
evidence (the Phase 1 rule), so a new device has verified identities without
opening pages.

### 9.6 Atomic publication and rollback

The daily job (worker cron, 00:40 UTC, after the 00:23 edge rebuild):

1. **Demand**: read the demand set (§9.7), sort it, digest it.
2. **Cut**: one `knowledge_cut` statement; read the starting artists' bundle
   refs and pin their digests.
3. **Write objects**: each answer and the identity snapshot under its digest,
   skipping digests that already exist (a HEAD, Class B). Every write
   reserves budget through `r2_reserve` first; a refused reservation aborts.
4. **Verify**: read every written object back and check its digest.
5. **Manifest**: write it under its digest; read back; verify.
6. **Publish**: write `days/<date>.json` with `If-None-Match: *`. This is the
   commit point. A second run the same day finds it and stops.
7. **Advertise**: rewrite `current.json` with the new day first and the
   previous six complete days after it.

**Failure before step 6** leaves nothing visible: clients keep using the last
generation in `current.json`; orphaned objects are collected by retention.
**Rollback after publication** never deletes or rewrites anything: a bad
generation is withdrawn by rewriting `current.json` without it (listed under
`withdrawn`, with a reason). Clients that pinned it move to the newest listed
generation at their next look; `days/<date>.json` stays for audit. No day is
ever republished; a corrected generation waits for the next day.

### 9.7 Demand sets and missing demand

**Pilot demand set**: fixed and committed — the starting points and the
artists their rows name, from this Mac's Development and Production rows
(the iPhone's are the same synced rows), plus the existing
`PILOT_ARTISTS`. About 35 nodes and 320 artists.

**After the pilot** (proposal, not built in Phase 2): devices note what they
asked for through a SECURITY DEFINER RPC that enqueues deduplicated
`knowledge_demand` rows in the existing `enrichment_jobs` table (dedupe key:
entity + UTC date; no new table; entity keys only, no user or device id);
the cut reads the last seven days of them. Because demand derives from synced
personal data, two devices with the same rows ask for the same entities.

**Missing demand** (the newly installed iPhone asking for a neighbourhood that
was not in yesterday's cut): **deferred**, as you proposed. In the pinned
generation that entity is `deferred` (or absent, which the client reads as
`deferred`); For You's shared ranked blocks treat it as a starting point with
no neighbourhood, identically on every device holding that generation; the
demand note makes the next generation include it. Never served from an older
generation (that would mix generations) and never fetched live into a shared
ranking. DIG keeps discovering immediately with live and local knowledge,
outside the generation.

### 9.8 Client pinning and offline

- Read `current.json`; choose the newest listed generation whose date is ≤
  the device's UTC date. Fetch its manifest by digest and verify.
- Fetch only the objects for this device's own entities (its starting points
  and the artists its rows name), each by digest, verified; keep them in an
  on-disk content-addressed cache with the manifest.
- Rank from one manifest only. If a needed object cannot be fetched, the
  generation is unusable on this device: use the last fully fetched
  generation — whole — and say so in diagnostics. Never mix objects across
  manifests.
- Offline: the last pinned generation and its objects, indefinitely; on
  return after more than seven days, move to the newest listed generation.
- The FY stamp gains the manifest digest, so two devices' codes say whether
  they ranked from the same generation.
- Shadow only in Phase 2: none of this changes the visible For You.

### 9.9 Retention

Seven complete generations in `current.json`. A weekly sweep lists
`generations/manifests/`, computes the set of objects referenced by every
manifest named in `current.json` and by every `days/` entry younger than
nine days (two days' grace for devices mid-fetch), and deletes generation
objects outside it. It never deletes anything outside `generations/` —
bundles, pages and discographies belong to the existing pipeline, which
never deletes content-addressed objects either. Deletions are logged with
the manifest set that justified them.

### 9.10 Estimated cost (pilot)

From Phase 1's measured sizes (646–721 KB for 12 nodes + ~150 artists):

| | Per generation | Per month |
|---|---|---|
| Objects written (new digests only) | ≤ ~360 (≈ 350 answers + identity + manifest + day; fewer when unchanged) | ≤ ~11,000 Class A — 1.1% of the free million, 1.4% of the 800k cap |
| Bytes written | ≈ 1.5–2.5 MB | ≈ 60 MB |
| Retained storage | ≈ 7 × 2 MB, less after dedupe | ≈ 15 MB of the 8 GB cap |
| Device reads | 1 `current.json` + 1 manifest + ~30 objects per new generation | trivial against 10M Class B |
| Publication time | one statement (to measure; estimated 5–20 s) + ~360 PUTs and GETs at 8-way concurrency | — |

All of this is to be measured in the pilot (§9.11) rather than trusted.

### 9.11 Pilot plan (each step its own commit)

1. **Provenance count**: how many catalogue artist rows hold `discogs`-only,
   `nts`+`discogs`, `musicbrainz_discogs` ids; how many SQL edge targets
   would carry an id under each `idEvidence`. Read-only queries.
2. **`knowledge_cut`** (migration, service role only, read-only) and its
   test against the pilot demand set: one snapshot, answers byte-equal to
   `explore_knowledge` from the same snapshot, statement time measured.
3. **Publisher** (worker, `generations.ts`, pure core plus R2 deps, like
   `knowledge.ts`): steps 1–7, dry-run mode that writes nothing, tests for
   every failure point (abort before commit leaves `current.json` unchanged;
   a second publish the same day is a no-op; a corrupt object fails
   verification).
4. **One real publication** for the pilot demand set; benchmarks: statement
   time, object count and sizes, PUT/GET counts and latency, publication
   time, budget reserved.
5. **Client** (shadow): pin, fetch, verify, cache, fall back; FY stamp with
   the manifest digest; the Phase 1 measurement re-run on the pinned
   generation, and on two copies to show byte-identical answers hours apart.
6. **Retention sweep** in dry-run against the first week's generations.

Out of Phase 2: backend-authoritative For You, a global style index, a
catalogue-wide backfill, any new table, and changes to the visible For You,
DIG, Explore, weights, CloudKit or goldens.

## 10. Phase 2 pilot: provenance audit and the consistent cut (2026-10-12)

Decisions recorded: `knowledge_cut` approved (read-only, publishing worker /
service role only, no tables); 00:40 UTC, publishing only with proof that
the 00:23 rebuild succeeded; the fixed pilot demand set, frozen with its
digest. Results below are read-only measurements on the live database; no
function has been created yet.

### 10.1 Pilot demand set (frozen)

`supabase/functions/_shared/testdata/pilot_demand_v1.json`, sha256
`4058f30adc6862e7f1312cc2653605935c0598b1a97570e8ce14083984bad57d`: **24
nodes** (16 artists, 5 broadcasts, 2 stations, 1 recording) and **163
artists** — smaller than the ~35/320 estimated, because the Development and
Production starting points overlap. Built from the rows as kept
(`PilotDemandExport`), with these cases added and labelled: Prefuse73 /
Prefuse 73 (verified spelling), Hype Williams (namesakes), Anika / Annika
Henderson and Mica Levi / Micachu (aliases), Duenn (lookalike), Attilio
Novellino (radio name and credit), Dean Blunt and Joanne Robertson (known
artists), and a name nobody files (unknown). Stations and a recording cover
`unsupported`.

### 10.2 Identity provenance

Catalogue-wide artist rows (118,561):

| Identity on the row | Rows | Share |
|---|---|---|
| Discogs only — created from Discogs documents | 22,521 | 19% |
| Discogs and NTS — a radio name joined to a Discogs entry by name | 5,587 | 5% |
| MusicBrainz → Discogs link | 2 | 0% |
| NTS only — a radio name | 90,452 | 76% |

`music_relationships` holds **only radio relationships** (202,752 artist
`radio_neighbor` edges, 173,802 `played_by`); label peers come from the
releases Discogs documents describe. So a target's id evidence depends on the
route as well as the row:

| Route to the target (pilot starting artists) | Targets | Id from a Discogs document | Discogs id on a radio-named row | No id |
|---|---|---|---|---|
| Label roster (Discogs releases) | 7,503 | 3,433 | 3,806 | 264 |
| Radio neighbour | 144 | 4 | 47 | 93 |

**Rule for the cut.** A target reached through Discogs data carries its row's
Discogs id as `discogs-document`: the release document names that artist by
id, whatever name the row was also filed under (96.5% of label-roster
targets). A target reached through radio is a radio name; any Discogs id its
row holds was joined to it by name, so it is carried as `adopted-by-name` and
never placed. One more case to report rather than resolve: the catalogue has
two rows filed as "speedy j".

### 10.3 The consistent cut, measured

The whole pilot demand set as **one statement** — `explore_knowledge` applied
to all four batches (12+12 nodes, 50+50+50+13 artists) inside a single
`SELECT`, which is exactly `knowledge_cut`'s body. Run read-only through the
CLI; nothing created.

| | Cold (first run) | Warm |
|---|---|---|
| Wall time incl. CLI connection | 12.9 s | 2.8–3.1 s |
| Database execution | — | 589 ms (planning 0.3 ms) |
| Buffers | — | 69,213 hit, 0 read, 0 temp |
| Answer size | 949,612 bytes | same |
| Edge generations seen | one (`edges-165903`) | one |

`service_role` has no statement timeout (anon 3 s, authenticated 8 s), so
the cut needs no timeout change; the cold first run's extra seconds are disk
reads, once a day, of pages the warm run then holds. The single-statement cut
is practical for the pilot; the `REPEATABLE READ` fallback is not needed.

### 10.4 Proof the 00:23 rebuild completed

The `generation` id in today's answers is **computed from the clock**
(`edges-` ‖ ⌊(now − 23 min) / 3 h⌋), not from the rebuild, so it proves
nothing. The rebuild is pg_cron job 6, `select public.rebuild_radio_dig_edges()`
— one statement, so it commits as one transaction and a snapshot sees all of
it or none. Its last ten runs all `succeeded` in 16.3–18.8 s. `knowledge_cut`
will therefore, inside its own statement, require a `cron.job_run_details` row
for job 6 started at or after today's 00:23 UTC with status `succeeded` and
`end_time` before the statement began; otherwise it returns no answers and the
publisher skips the day. The manifest records that run's id and end time as
the edges watermark in place of the clock-derived label.

### 10.5 What this means for the publisher

- Size: one generation of the pilot is ~950 KB of answers; split per entity
  (≈190 objects) and content-addressed, a day with few changes writes far
  fewer.
- Database load: one warm-cache statement under a second, once a day.
- Next, if approved: the `knowledge_cut` migration (with the rebuild proof and
  target id evidence), then the publisher with its dry-run mode.

## 11. `knowledge_cut` migration review (2026-10-12) — not deployed

**Migration history.** Live had 0070 and 0071, applied from
`trim-the-database-under-500mb` (6db3f36) and missing here. Both files were
brought over unchanged (81d492a) after checking them against the
statements `supabase_migrations.schema_migrations` recorded (identical,
ignoring comments and whitespace). `supabase migration list --linked`: no
mismatches through 0074. `supabase db push --linked --dry-run`: would apply
**only `0075_knowledge_cut.sql`**. Not pushed.

**What 0075 adds** (no tables, nothing written):

- `knowledge_answers(p_nodes, p_artists)` — 0074's query, STABLE, security
  invoker. Artist targets add `rowID`, a Discogs id with `idEvidence`
  (`discogs-document` through a Discogs release document; `adopted-by-name`
  through radio; `name-matched` through a release with no Discogs id;
  `several-ids` never seen) and `sharedName` when two rows under one starting
  point share a name. Each node lists its `seeds` (row, routes, Discogs id)
  and `ambiguousName` when its name matched more than one row — explore's walk
  combines them; that is kept and said, not silent. Format 3. With those
  fields removed, its answer equals `explore_knowledge`'s.
- `knowledge_cut(p_day, p_demand)` — one `LANGUAGE sql STABLE SECURITY DEFINER`
  statement: refuses (`not-today`, `not-the-frozen-demand-set` by jsonb digest
  `5754856d…c88e0`, `out-of-bounds` beyond 48 nodes / 400 artists,
  `no-completed-rebuild-today`) before answering anything; otherwise batches
  the demand set (12 nodes / 50 artists) through `knowledge_answers` inside
  the same statement and returns the answers with `statementAt`,
  `pg_current_snapshot()`, the demand digest, and `rebuild.proof` (today's
  00:23 run: jobid, runid, start, end — succeeded, in its slot, ended before
  the statement) and `rebuild.latest` (the newest finished rebuild the
  snapshot includes).
- Privileges: both revoked from PUBLIC, `anon` and `authenticated` by name;
  `service_role` only; not in `app_callable_functions()`.

**Tested** in a throwaway Postgres 17 (`Scripts/test-migrations.sh`, every
migration then every smoke test; exit 0), `knowledge_cut_smoke.sql`:
privileges (anon, authenticated, PUBLIC cannot; service_role can; not on the
app list); refusal with no run, an unfinished run, yesterday's run, another
day, another demand set; a cut with today's run (24 nodes, 163 artists, 4
batches, proof recorded); explicit `unknown` and `unsupported`; a
Discogs-backed peer carrying its id as `discogs-document`, a peer through an
uncatalogued release `name-matched`, a radio neighbour `adopted-by-name`, two
"Speedy J" rows as two flagged targets and as an `ambiguousName` starting
point; and equality with `explore_knowledge` without the new fields. The
pg_cron stub gained `runid` and `end_time` to match pg_cron.

**Measured on live, read-only** (the function body run as one SELECT with
the pilot set; nothing created): 1.19 MB; artist targets 2,559 —
`discogs-document` 1,903 (74%), `adopted-by-name` 133, `name-matched` 32, no
id 491; one ambiguous starting point (`speedy j`, 2 rows). 73,764 buffer
hits, no disk reads, no temp; execution 1.2–7.6 s across runs for identical
buffer work (the free tier's shared CPU, with drains every five minutes),
against 0.6–2.0 s for 0074's answers alone.
