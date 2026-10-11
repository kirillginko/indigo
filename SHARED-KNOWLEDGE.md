# Shared knowledge for For You — architecture audit and plan

*2026-10-11. Supersedes the plan behind the first backend shadow comparison
(0072, October 8). Nothing here has been started.*

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

```
For You  =  rank( personal(CloudKit),  knowledge(G),  identity(G),  day )
```

where **G is one immutable shared knowledge generation** both devices can
name and fetch, and nothing in `knowledge(G)` or `identity(G)` depends on
the device.

- **A generation manifest** in R2, immutable, under its digest: the edge
  generation it was cut from, the identity snapshot it carries, the bundle
  references current at that moment, and the format. A small, mutable
  pointer names the current manifest.
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
- **Pinning**: For You ranks only from one generation at a time; the stamp
  names it. A device that has not got all of G's answers for its starting
  points either fetches them or keeps showing the last complete answer —
  it never mixes generations or fills from local caches.
- **Day-stable choice of generation**: both devices use the latest
  generation published before the start of the evaluation day (UTC), so
  devices that open For You hours apart still agree for that day.
- **Device-local knowledge** stays out of the ranked blocks (decision
  needed, §6). "Back in your library" stays local and unranked against the
  rest.
- **Stamp** gains the generation id; a cross-device test asserts: equal
  `personal` + equal generation ⇒ equal `ranked`.

## 4. Phased proposal

Each phase ends with a measurement, not a switch. No phase changes ranking
weights.

### Phase 1 — Identity-aware shadow parity (app only; no backend change)

Put the backend's answers through the same identity layer the visible For
You uses, and measure the gap on both devices.

1. Canonicalize backend answers with the backend's own identities (format 2
   lists them per node) and the same `GraphCanonicalizer` rules; build the
   snapshot with the same one-artist-one-candidate pass and known-artist
   policy.
2. Shadow report per stage: SQL only; SQL + bundles; by route kind; by
   identity (verified / unresolved / alias); coverage (answers found,
   unknown, partial bundles).
3. FY-style code for the shadow, so the Mac's and iPhone's shadow codes can be
   compared exactly like the visible ones.
4. Run on the Production copy (offline audit) and live on Mac and iPhone.

*Exit*: a categorized list of every top-20 difference between local and
backend knowledge on this Mac, and identical shadow codes on Mac and iPhone
whenever their shadow generations match.

### Phase 2 — Generation pinning, in shadow (worker + R2; no new tables)

1. The worker cuts each edge generation into an immutable manifest plus
   per-entity answers in R2 **for the entities devices ask about** — answers
   are written on demand when first asked for in a generation and kept
   (budgeted through `reserveR2`, no global backfill).
2. Day-stable generation choice in the client; the shadow fetches by
   generation and never mixes two.
3. Identity snapshot v0 published with the manifest, built from what the
   backend already holds: `external_ids` (including `musicbrainz_discogs`),
   Discogs ids on artist rows, and bundles' credit ids — scoped to the
   entities in answers, not the whole catalogue.

*Exit*: two devices fetching the same day's generation hours apart get
byte-identical answers and the same shadow ranking.

### Phase 3 — Close the knowledge gap (worker; bundles; still shadow)

1. Bundles for every starting point and every artist one step out that the
   shadow asks for, built on demand (budgeted), so credit routes stop
   depending on what a device has opened.
2. Shows and artist genres from the generation (D3, D4); scenes from the
   generation's rosters (D5).
3. Coverage rule written down and tested: what an absent bundle or answer
   means for ranking, identically on every device.

*Exit*: backend shadow top-20 overlap with the visible For You on this Mac at
an agreed threshold, every remaining difference explained (coverage,
identity, or a route the device had from browsing).

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

## 6. Decisions needed

1. **Device-local library in ranking.** Identical recommendations require
   the ranked blocks to ignore the library (D6), or to accept that they
   differ by exactly the library. Recommendation: rank from shared knowledge
   only; keep "Back in your library" as its own block.
2. **Generation choice.** Day-stable (latest before the UTC day starts) vs
   newest available. Day-stable is what makes devices agree; newest is
   fresher.
3. **Retention.** How many generations' manifests and answers R2 keeps
   (offline devices, devices that fell behind) within the free-tier budget.
4. **Identity snapshot scope.** Entities in answers only (cheap, grows with
   use) vs a catalogue-wide snapshot (a backfill; out of scope now).
5. **Threshold for Phase 4** (shadow overlap and explained differences).

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
