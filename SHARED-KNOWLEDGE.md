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

