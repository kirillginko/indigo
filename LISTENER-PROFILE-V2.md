# Listener Profile v2

What For You knows about the listener, what it throws away, and a
prototype that keeps more of it. Prototype only: nothing visible reads it
yet. Personal numbers (artist names, exact counts) stay in the private
reports outside Git; this file gives proportions and code facts.

## Phase 1 — what the history holds and what today's model uses

Measured by `IndigoTests/ListenerDataAudit.swift` (opt-in,
`INDIGO_LISTENER_AUDIT=1`) on copies of one Mac's stores.

**Synced rows** (`UserData.store`): `ListeningEvent`, `CrateItem`,
`DigVisit`, `DigStep`, `DigCounter`. `DiscoverDiagnostics` is local-only.
Nothing here needs a schema change: every field v2 reads already syncs.

**Events.** About a month of history, roughly 1,200 events.
- Skips are the largest action, and more than half of them are a station or
  a show sampled, not a track rejected. Today they weigh 0, which is right;
  they must never become a negative.
- Most plays are 30 seconds to 2 minutes; very few run past 10 minutes.
  `ListeningEvent.weight` caps at 1 for 20 minutes, so a track heard whole
  and a mix sampled for a minute differ less than they should.
- No event carries a Discogs id; under a fifth carry tags; just over a third
  name a radio source.
- About a third of the artists met were only ever skipped.

**Crate.** About 100 items: half recordings, a third shows. One in five
crated recordings is on a record DIG holds, so its styles are known at
record level.

**DIG.** Over a thousand pages visited and as many steps between them —
the richest signal of curiosity, and today it reaches taste only through
the "met" list.

**Where it collapses.**
- `TasteProfile.collected` adds every tag of every encounter into **one
  vector** of ~220 interests. Station tags ("talk", "interview") rank among
  the top ten; distinct tastes average into a blur.
- `ExploreRanker.startingPoints` keeps **12 artists**. They carry **19%** of
  the positive weight; the other 81% never seeds a route.
- Every recording-level event is reduced to its artist: title, record and
  how much of it was heard are dropped.
- Just over half the artists with positive history have Discogs styles on
  the device; the rest are styled by tags or not at all.

## Phase 2 — the prototype (`Indigo/Explore/ListenerProfile.swift`)

A pure struct, a function of the synced rows, the style space and `asOf`.

- **Units at the most specific level known**: the recording played, the
  record crated or opened (editions folded by title and artist), the artist
  only when nothing narrower exists. An alias stays its own project; which
  names are one person is kept apart, by Discogs id (see the alias audit
  under Phase 3 — the first prototype folded by display name).
- **Signals by intent**: crated 3, saved 2.5, full listen 1, partial 0.4,
  DIG page 0.15, skip 0 (counted, never subtracted), dismissed −1.
- **Time**: long-term = log2(1 + sum), so repetition counts without
  drowning the crate; recent = last 14 days, 7-day half-life. A style is
  *emerging* when its recent share is ≥ 4% and at least twice its
  long-term share.
- **Sound**: each unit is placed in Records like yours' PPMI style space
  from the record's styles, else the artist's, else tags the space knows.
- **Clusters**: greedy, heaviest first, cosine ≥ 0.45 to join, at most 8,
  under 4% folds into its nearest. Each says its styles (by the weight its
  members carry), its long-term and recent share, examples, evidence count
  and a confidence.
- **`relevance(styles:)`**: nearest cluster's fit × how much time that
  cluster holds. **`spread(_:limit:)`**: gives a ranked list's slots out
  across clusters in proportion to their share, at least one each.

Tests: `IndigoTests/ListenerProfileTests.swift` (intent order, skips are not
negatives, aliases fold, tastes stay apart, emerging, unknown tags ignored,
order-independence, spread).

## First replay (`IndigoTests/ListenerProfileReplay.swift`)

Opt-in, `INDIGO_PROFILE_REPLAY=1`. Profile built from history before a
cutoff 21 days back (no leakage); For You's own walk pool from the same
store re-ranked four ways; each top 20 scored against what was listened to
after the cutoff.

- Deterministic: the same profile from reversed input.
- 4–5 clusters with readable labels (ambient/experimental, folk, indie,
  house/techno, spiritual jazz); the largest holds 40–58% of the weight.
- 28% of the weight has no style on the device.
- Read 1.3 s + build 3.7 s on the Mac — must be cached before it sits
  behind a screen.

| top 20 from the same pool       | later finds | fit to later listening | taste clusters | most from one starting point |
|---------------------------------|-------------|------------------------|----------------|------------------------------|
| For You's order today           | 0           | 0.594                  | 3              | 14                           |
| v1 taste vector                 | 0           | 0.540                  | 1              | 12                           |
| v2 relevance                    | 0           | 0.588                  | 1              | 13                           |
| v2 × route score                | 0           | 0.589                  | 3              | 13                           |
| v2 × route, slots by cluster    | 1           | 0.576                  | 3              | 12                           |

**Reading it.** Re-ranking the same pool barely moves anything: the pool
holds only 3 of the ~140 artists found after the cutoff. v2 beats the v1
vector on fit, and slotting by cluster spreads the list and reaches one
later find, at a small cost in fit. The binding limit is **reach**, not
ranking — consistent with the earlier reachability audit (8 of 133 later
artists reachable; two shared radio hops from kept artists would reach
about half of the rest).

## Phase 3 — expanded retrieval (`Indigo/Explore/ListenerRetrieval.swift`)

Prototype only; nothing visible reads it. Replayed by
`IndigoTests/ListenerRetrievalReplay.swift` (opt-in,
`INDIGO_RETRIEVAL_REPLAY=1`; reads the shared catalogue read-only and a few
R2 release documents) at cut-offs 21, 14 and 7 days before the last
activity. Radio is read only from episodes aired before each cut-off.

**Routes.**
- *Seeds*: each cluster's strongest units (recording, release, artist),
  slots in proportion to the cluster's share with a floor of three — about
  36 seeds against For You's 12.
- *Direct* (B): one step in the on-device identity graph — credits and
  releases ("direct musical connection"), labels and scenes ("same label or
  scene"); never a technical credit, never the same person.
- *Radio*: who was played next to a seed (adjacency) and next to *them*
  (second hop), weighted by track distance, programme focus (share of its
  genre mentions held by its top three genres), repetition across episodes
  and programmes, and the episode's genres against the cluster; artists
  every programme plays are damped (√(8 / programmes)). A second hop is
  explained as "played near X on Show; X is played near Seed" — never a
  collaboration.
- *Records like yours*: records on the device whose own styles (≥ 2 the
  space knows) sit nearest a cluster's centre (fit ≥ 0.6).
- *Merging* by verified identity: a Discogs id, else a catalogue row; a bare
  name joins an identity only when exactly one identity has that name.

**Alias audit.** Phase 2 folded aliases into one unit through a union-find
keyed by normalised display names (alphabetically first). Now: an alias is
its own project in the profile (one person, two sounds), and "same person"
is a separate group keyed by the smallest Discogs id, formed only from links
*both* entries confirm. In this history: 98 alias links between names the
listener has met, 78 confirmed; 14 groups by name alone, 12 by confirmed id.

**Results** (later = artists first acted on positively after the cut-off).

| cut-off | later | pool recall A / B / C / C bounded | pool size A / B / C / C bounded |
|---------|-------|-----------------------------------|---------------------------------|
| 21 d    | 141   | 2% / 8% / 33% / 8%                | 163 / 784 / 7,462 / 1,198       |
| 14 d    | 132   | 2% / 8% / 33% / 8%                | 163 / 775 / 8,295 / 1,208       |
| 7 d     | 42    | 7% / 14% / 21% / 14%              | 160 / 736 / 7,352 / 1,120       |

Later finds in the top 20 (best ranker per pool; fit to later listening):

| cut-off | A (today) | B cluster-seeded | C | C bounded |
|---------|-----------|------------------|---|-----------|
| 21 d    | 2 (0.55)  | 6 (0.49, R2)     | 2 (0.48, R3) | 2 (0.47, R3) |
| 14 d    | 2 (0.55)  | 3 (0.45, R2/R3)  | 1 (0.49) | 1 (0.46) |
| 7 d     | 3 (0.65, For You order) | 3 (0.63, R1) | 1 (0.62 R2; 0.43 R3) | 2 (0.42) |

- **Radio reaches, but as noise.** Unbounded, radio takes recall from 8% to
  33%, but the pool grows to ~7,500 with ~1% precision; 45% of adjacency
  candidates have no style anywhere, so no ranker can tell them apart. Half
  the radio "finds" at the 21-day cut-off come from **one episode** whose
  tracklist the listener played through in one evening — one discovery, not
  sixteen. Bounded to 12 per seed and 4 per bridge, radio adds nothing that
  B did not already reach.
- **Second hop**: 2,100–2,800 candidates, 1–5 later finds; 24–38% fit a
  taste cluster, 13–14% clearly don't, the rest unknown. Examples read as
  plausible scene neighbours (the same label circles and programmes) but
  rarely as what the listener went on to play.
- **Records like yours** looked strong (17 later finds) until the pool was
  limited to records provably on the device before the cut-off: records
  carry no date, and ones cached by a *later* visit leaked the answer.
  Dated, it offers ~6 records and none is a later find.
- **B is the real gain**: cluster seeds through the on-device graph take
  pool recall 2–7% → 8–14% and top-20 later finds up at two of three
  cut-offs, at lower fit (0.45–0.49 vs 0.55). Caveat: the device graph
  itself is today's, not the cut-off's, so B's numbers may be optimistic.
- Today's taste vector (R1) collapses on the radio pools (one style, fit
  0.30): it rewards whatever tag mass radio genres carry. v2 relevance and
  spread hold diversity (4–5 clusters, 10–11 styles).

**Stability and determinism.** Dropping one piece of evidence in twenty
(five ways) keeps 4 clusters in four of five trials (one splits into 5),
matched centroids at cosine ≥ 0.94, and 92–100% of seeds. The profile is
identical from shuffled history; radio scores are identical from reordered
input (after summing in a fixed order — the first run was not). With a
tenth of artist styles missing, as on a device whose caches differ, the
profile changes (95% of seeds kept): **a cached profile must be keyed on the
style caches as well as the synced history.**

**The unstyled 28%.** 25.5% of the weight belongs to artists with no Discogs
entry on the device (14.7% artist-level, 13.2% recording-level). R2 cannot
help them directly: its documents are releases by id, and the release ids
come from the Discogs entry. The shared catalogue's radio episode genres
cover 8.8% of all weight (artists with a unique catalogue row whose episodes
carry genres the style space knows); the catalogue also knows a Discogs id
for those same 8.8%. Of artists *with* an entry but no styles (2.3%), R2
documents give styles for few (4 of 21 sampled). No AI enrichment or new
collection is needed to recover the first ~9%; the rest needs each artist's
Discogs entry, which DIG fetches on demand anyway.

**Decision.** Reach improved meaningfully only by flooding the pool; bounded
so the noise is manageable, radio adds nothing over B. That fails the bar
set for moving on, so **Phase 4 integration is not started.** What would
change it:
1. Score radio candidates by evidence the listener can hear — the episode,
   not the artist — and count one episode's tracklist as one find.
2. Give radio candidates styles from episode genres *and* their catalogue
   Discogs id before ranking, so relevance can separate fit from noise.
3. Date the device's knowledge (records and graph edges) so B and records
   like yours can be replayed without leakage.
4. Then re-run the replay; promote B's cluster seeding (the clear win) first.

### Phase 3, second pass — episodes, dated knowledge, sessions

The four changes above, then the replay again (same three cut-offs).

- **Radio by the episode.** An episode offers only its three strongest
  artists (two on the second hop); several seeds on one episode raise it;
  an artist's score is its best episode, raised only by *other programmes*.
- **Dated knowledge.** A Discogs entry counts only if fetched before the
  cut-off and its artist was not first opened after it (548–623 of 661); a
  record only if such an entry or an earlier page lists it (1,924–2,386 of
  2,976); the style space is learned from those records alone. A new direct
  route (Bd) reads the dated entries and records instead of today's
  identity graph (B, kept for reference).
- **Styles before ranking**: the candidate's dated entry by name, else by
  the Discogs id the catalogue gives, else its records, else episode genres.
- **Finds as sessions**: positive actions with no gap over 45 minutes. The
  later finds are 141 / 132 / 42 artists but only **20 / 16 / 10 sessions**:
  discoveries come in bursts.

| cut-off | pool recall, artists / sessions: A · B · Bd · E | E size | best top 20, finds (fit): A · B · Bd · E |
|---------|------------------------------------------------|--------|------------------------------------------|
| 21 d | 2%/15% · 7%/35% · 6%/30% · 9%/40% | 1,666 | 2 (0.65) · 2 (0.45) · 3 (0.40) · 0 (0.52) |
| 14 d | 2%/19% · 6%/38% · 8%/38% · 9%/44% | 1,588 | 2 (0.50) · 1 (0.44) · 2 (0.39) · 0 (0.53) |
| 7 d  | 7%/30% · 14%/40% · 17%/40% · 17%/40% | 1,714 | 3 (0.60) · 1 (0.52) · 2 (0.38) · 0 (0.59) |

(A = For You's walk, which still reads today's device; B = cluster seeds
through today's graph; Bd = the same from dated knowledge; E = Bd + episode
radio + records like yours. Every top-20 find is its own session.)

- **Radio's reach was mostly one evening.** Scored by the episode and read
  from dated knowledge, radio's later finds fall to 3 artists in 2 sessions,
  2 in 1, and 0. The second hop finds nothing at any cut-off, and 21–28% of
  it clearly does not fit (vs 10–15% of adjacency).
- **Cluster seeding holds up without leakage.** Bd's pool reaches 30–40% of
  discovery sessions against For You's 15–30%, and its top 20 matches or
  beats For You at two cut-offs of three (3 vs 2, 2 vs 2, 2 vs 3).
- **But the rankers cannot see most of it.** 95% of direct and shared-label
  candidates have no style the dated device knows, so relevance scores them
  zero and the mixed pool (E) ranks styled radio and similarity candidates
  above them: E's top 20 finds nothing anywhere, while Bd's own finds sink.
  Fit to later listening is lower for Bd (0.30–0.40) for the same reason.
- **Discogs ids did not help**: no radio candidate's catalogue Discogs id
  matched a dated entry the device holds that its name did not.
- **Determinism**: episode-scored radio is identical from reordered input.
- **Attribution gap**: after the cut-off, 3 of 162 newly met artists' first
  events record where they came from (`sourceProviderID`); the history
  cannot say whether a discovery came from DIG, For You, Discover or a
  station, so no replay can credit a surface.

**Decision, again: Phase 4 is not started.** The retrieval win is real but
narrow — cluster seeding through what the device already holds — and it is
not rankable yet: its candidates are unstyled. Radio, once counted
honestly, does not earn a place in the pool. Next, in order:
1. Rank unstyled candidates by route evidence instead of scoring them zero
   (relevance only where a style exists), and re-run Bd vs A.
2. Record the surface on every listening event (which screen, which
   recommendation), so the next replay can say what found what.
3. Only then integrate Bd's seeding behind the Debug switch, with the
   profile cached on synced history *and* the style caches.

### Phase 3, third pass — ranking the unstyled by evidence

`ListenerRetrieval.rank`: evidence first (a candidate's percentile within
each route it came by, lifted 0.15 for every further seed that reached it),
scaled by fit (0.5 + relevance) only where a style exists; an unstyled
candidate takes the pool's median fit. `ListenerProfile.spread` can now
place an unstyled candidate by its seed's cluster. Replayed by
`IndigoTests/ListenerRankingReplay.swift` (opt-in `INDIGO_RANKING_REPLAY=1`,
on the device only, no network) at 21, 14, 10 and 7 days, Bd against A,
dated knowledge throughout. The weights were set before the run and not
tuned on it.

Later finds in the top 20, summed over the four cut-offs (each find was its
own session):

| ranker | A For You walk | Bd dated cluster seeds |
|--------|----------------|------------------------|
| For You's own order | **10** | – |
| R1 today's taste vector | 3 | **9** |
| R2 relevance, unknown = 0 | 3 | **9** |
| R4 evidence first | 7 | 0 |
| R5 evidence first, by cluster | 3 | 2 |

- **Evidence-first ranking is worse, not better**, for Bd (9 → 0–2). Only
  3% of Bd's candidates carry a dated style, and that 3% is where its finds
  are: holding a Discogs entry for a stranger is itself a sign it sits near
  the listener (it was fetched as a neighbour of something they opened).
  Scoring the unknown zero was, in effect, a useful filter.
- Evidence first also fills the list with Discogs' "same styles" lists:
  they repeat across many seeds, so corroboration lifts them, and they are
  broad (mainstream R&B beside ambient seeds).
- On A, evidence first recovers most of For You's own order (7 vs 10), as
  expected: it is mostly For You's route scores.
- **Bd with style-first ranking ≈ For You** (9 vs 10 finds in 40 slots), at
  lower fit, from a larger and more diverse pool (4–5 clusters vs 1–2). It
  is not better.

**Where this leaves Phase 3.** Retrieval from the listener's clusters
reaches more of what they go on to find (pool recall of discovery sessions
30–40% vs 15–30%), but no ranker tried here turns that into more finds in
twenty slots than For You already makes, and two of three ways of using the
wider pool made it worse. With ~10 independent finds per replay, smaller
differences cannot be told from chance. Phase 4 should not replace For
You's list; if anything, it could *add* a few cluster-seeded artists from
under-served clusters beside it, judged by listening rather than by this
replay. Recording which surface each listening event came from remains the
missing measurement.

### Attribution — which surface started a listen

`Indigo/Listening/ListeningSurface.swift`. Every play and skip the
`PlaybackWitness` writes now carries where it was started: the screen
(`foryou.mix`, `foryou.tracks`, `foryou.crate`, `foryou.library`,
`foryou.stations`, `dig.discover`, `dig.artist.discover`,
`dig.artist.recommendation`, `dig.artist.listen`, `dig.release`, `crate`),
the listener's artist it was reached through (`via`, folded), and the kind
of recommendation (`route`: track, artist, record, or a station id).
Anything started where the screen says nothing is inferred from the item:
a station is `radio.live`, an archive `radio.archive`, a local file
`library`, else `unattributed`.

- **No schema change.** Stored in the event's existing `tags` under
  reserved prefixes (`surface:`, `via:`, `route:`), which already sync.
  `ListeningEvent.musicTags` leaves them out, and every reader of taste
  (`TasteProfile`, `ExploreKnowledge`, `ListenerProfile`) now reads that. A
  build from before this would see them as unknown tags that match no
  style.
- The player remembers the surface per item, so a queue started from DIG's
  Discover credits every track in it, each with its own `via`; playing the
  same item again from a screen that names nothing clears it. A listen is
  credited to the surface it *started* from, fixed at that moment.
- Checked in the simulator (2026-10-16): a For You mix track
  (`foryou.mix`, via the artist it was played next to), a DIG Discover card
  (`dig.discover`), an artist page's own tracks (`dig.artist.listen`, the
  next track in its queue too) and a crate item (`crate`) were each written
  with the right tags. The first run found a bug: a Discover queue that
  held the track still playing from For You rewrote its credit before the
  listen was written; fixed by fixing the surface when a listen starts.
- Not covered yet: saves, page opens and dismissals (only plays and skips);
  a page *opened* from For You and played there is credited to the page,
  not to For You.
- `ListenerDataAudit` reports the share of events carrying a surface and
  each artist's first positive listen by the surface that found it — the
  measure the replays lacked. It needs a few weeks of history from a build
  that records it before a replay can use it.

### Attribution validation pass (2026-10-17)

- **Off in the App Store build.** `ListeningAttributionFeature` (key
  `INDIGO_LISTENING_ATTRIBUTION`, refused in release binaries by
  `Scripts/release-enrichment-guard.sh`): on in internal builds, a Debug
  switch otherwise. Reason, measured by `ListeningAttributionAudit`: a build
  from before attribution reads every tag as an interest. The surface tag
  rides on every attributed row and becomes its strongest "interest". That
  scales every music interest to 1–3% of its weight, and all 25–28
  interests above the 0.15 a scene needs fall below it, even with only the
  last 30 days attributed. Reading is safe everywhere. Writing for everyone
  waits until builds that read tags as music are gone.
- **Verified ids beside names.** `viaid:` carries `discogs-artist:<id>` or
  `discogs-release:<id>` only where the source already holds a verified id:
  Discover seeds, artist pages, records. A For You route names its origin
  only, so it carries no id. No name is ever resolved to an id.
- **Surface vs origin.** The surface is where playback started. `origin:` is
  the recommendation that opened the page it started on (For You → artist →
  track). It is carried only by that page while it is on top, plus the queue
  started there. Opening another page, going back past it, searching or
  changing section drops it. Both are fixed when a listen starts and never
  rewritten.
- **One playback.** The witness writes a recording row and an artist row
  (or a show and a station) for one listen. They already share the moment,
  action, seconds, completion and surface, which is the key in
  `ListeningPlayback`; no field was added. Grouping is checked on both
  histories: 687 and 656 listens from 1,155 and 1,124 rows, 0 listens whose
  rows disagree.
- **Read-only summary.** `AttributionSummary` counts each listen once by
  surface and by origin; `ListeningAttributionAudit` reports it for a
  store.
- **Simulator** (iPhone 16 Pro, attribution on), each written as expected:
  - For You → artist page → track: `dig.artist.listen` with the page's id
    and origin `foryou.mix` via the artist it was credited with.
  - The page's next track keeps both.
  - Unrelated navigation (an alias page opened from that page): no origin.
  - DIG Discover → queue advancement: each track its own `via` and id.
  - A 12-second play is a skip with its surface.
  - Crate, including queue advancement: `crate`.
  - Live radio pressed where the screen says nothing: `radio.live`.
  - Pausing excluded the paused time.
- **Not covered:**
  - Audio interruption: it can't be driven in the simulator.
  - For You → record → play: the record had no playable recordings.
  - Killing the app mid-listen loses that listen (existing behaviour: a
    listen is written when the next item starts or playback stops). Nothing
    is restored on relaunch, so nothing is misattributed.
  - An embedded track left playing overnight recorded 22,010 seconds heard
    at 13% complete, a heard-time bug in the embed path, separate from
    attribution.

### Before Phase 3 resumed (2026-10-17)

- **Builds and CloudKit.** Debug builds (Xcode, the simulator) are signed
  for CloudKit's Development environment and keep their own store
  (`Application Support/Development/`) and zone. Every archived build is
  Production-signed and syncs the listener's real store, which any older
  build on the same Apple ID also reads. That includes internal TestFlight
  builds (`INDIGO_INTERNAL`) and the App Store build. So attribution is now
  written only when `CloudKitEnvironment.current` is Development, and only
  with the Debug switch on. Internal TestFlight builds no longer write it.
  Real-outcome evaluation runs on Debug builds, whose rows never reach
  Production.
- **Embedded heard time** (2b0757c, plus tests here). Seeks bank what was
  heard and re-anchor where they land. Loading, buffering and reopening are
  not audible. A stall or a frozen widget moves the clock, not the
  playhead, so it is not credited. A loop between samples reads as the
  playhead going backwards and credits that stretch nothing. A failure
  followed by recovery credits only the playing on both sides. Pause banks.
  A finished item is closed at its end before the engine rewinds. A skip
  closes one stint and starts the next. All of these err toward
  under-crediting.
- **Old rows read defensively.** `ListenerProfile.plausibleWeight` ignores
  a recorded length over four hours, or one that makes the item longer than
  six hours by its own completion, and reads the completion instead. The
  overnight 22,010-second row counts as a 13% listen. Synced rows are never
  changed.
- **Pairing** stays heuristic (limits in `ListeningPlayback.swift`): one
  listen is the rows sharing moment, action, seconds, completion and
  surface. Checked on both histories, with no listen whose rows disagree.

### Phase 3 resumed: a bigger pool, judged by what can be played (2026-10-17)

`IndigoTests/ListenerExpansionReplay.swift` (opt-in `INDIGO_EXPANSION_REPLAY=1`;
read-only against the catalogue, R2 and YouTube oEmbed). Dated knowledge
throughout; cut-offs 21, 14, 10 and 7 days, plus today for examples.
Pools are cumulative, so For You's own routes stay in every one:

- **A**: For You today.
- **AB**: plus one step from every taste cluster through dated entries and
  records.
- **ABR**: plus bounded radio (episode-scored, three artists per tracklist).
- **ABRS**: plus records near each cluster's centre.

A is in its own order; the others use relevance × evidence with slots by
cluster. The list a listener would see is **the first 20 that can be
played**, taken from each ranking's first 60. Playable means confirmed to
play, in this order of preference:

- a recording of their own from a release's catalogued videos;
- a recording a radio tracklist links;
- the moment in an archived show where they were played.

Each needs a verified Discogs id: the catalogue's, or the device's entry for
that exact name.

Summed over the four cut-offs (80 slots each):

| pool | slots filled with something playable | of those, own recordings | later finds (sessions) |
|------|------|------|------|
| A For You today | 22 | 4 | 4 (4) |
| AB + cluster seeds | 49 | ~19 | 6 (6) |
| ABR + bounded radio | 80 | ~25 | 10 (10) |
| ABRS + album similarity | 77 | ~25 | 9 (9) |

Pool recall of later artists: A 2–10%; AB 7–24%; ABR and ABRS 9–24%.

- **Playability is For You's binding limit.** Of For You's first 60
  candidates today, only 8 have a verified Discogs id and 6 can be played.
  Its list cannot fill 20 slots at any cut-off.
- **The wider pool fills the list:** ABR fills every slot, at lower fit to
  later listening (0.49–0.56 against For You's 0.50–0.65 over its 5–6
  playable items).
- **The later finds** in the playable lists came through cluster-seeded
  direct routes, a shared label and For You's own routes. Radio mainly
  makes the list *playable*: most of what it adds is heard as a radio
  moment, not a recording.
- **Most failures are unverifiable, not broken:** a candidate with no
  verified id, or one the radio catalogue doesn't hold and no stored shelf
  covers. The shelf cache also expires after 30 days.
- **Seen in the examples:**
  - A styling error from a shared name. "Gas" was styled as alternative
    rock from another artist's entry, so styling by name needs the same
    one-identity rule as merging.
  - Radio adjacency to a popular seed brings in well-known names (Fred
    Again.., Sampha, ASAP Rocky). Hub damping is not enough for an
    R&B/pop cluster.

**Before integrating anything visible**, in this order:
1. Style candidates only through a verified identity, never a bare name.
2. Damp popularity in the radio route for pop-adjacent clusters.
3. Prefer own recordings over radio moments when filling the list.
4. Then an internal, Debug-only For You that keeps For You's routes and
   fills the remaining slots from AB/ABR. Judge it by the attributed
   listens it gets (Debug builds only, Development store).

### The three fixes, and the replay again (2026-10-17)

- **Styles only through identity** (`ListenerRetrieval.StyleBook`, `style`):
  - A candidate with a Discogs id reads that entry, or the records credited
    to that id.
  - A credit known by name alone reads the device's entry for that exact
    name.
  - A catalogue row with no id gets nothing from names.
  - Fallback: the genres of the programmes that played that very catalogue
    artist.
- **Popularity damped relative to the seed** (`popularityStep`): a radio
  step to an artist played on more programmes than the seed is damped by
  √((seed + 5) / (candidate + 5)).
- **Own recordings first:** the list takes recordings, in rank order,
  before radio moments.
- **For You keeps its routes:** they stay first, in For You's order, and the
  wider pool fills what is left, each half with its own 60 looked at. The
  first replay ranked everything together; with genre styling, radio then
  crowded out For You and every later find (0 finds), so this is the
  integration design, not a tuning.

Summed over four cut-offs (80 slots):

| list | playable slots filled | later finds | fit to later listening |
|------|------|------|------|
| For You today | 22 | 4 | 0.50–0.65 |
| For You + cluster seeds | 25 | 7 | 0.39–0.65 |
| For You + cluster seeds + bounded radio | 60 | 4 | 0.36–0.39 |
| … + album similarity | 57 | 4 | 0.36–0.41 |

- The first run's "every slot filled, 10 finds" leaned on two things
  removed here: styles borrowed through shared names, and undamped
  popularity. With them gone, radio still fills the list with playable
  things (40 of the 60), but adds no later finds, and fit falls.
- Cluster seeds add finds (7 against 4) but few playable slots. Their
  candidates are mostly known by name only, and only 8 of 120 looked at
  have a verified id to find a recording by.
- Fred Again.., Sampha and similar are gone from radio. ASAP Rocky remains,
  through For You's own route.
- "Gas" is still styled as alternative rock: the shared catalogue links
  the radio "Gas" to a different Discogs artist. A catalogue identity
  error, outside this work.

**So, before anything visible:** the useful expansion is cluster seeds plus
a way to verify them. Resolving name-only credits to Discogs ids would let
their recordings be found. Radio is a source of *playable moments*, not of
better recommendations, at least on this history. A Debug-only For You
should keep For You's list and add cluster-seeded artists that verify and
play, with radio filling only the slots still empty, labelled as radio.

### Cluster-seed credits resolved through the seeds' own releases (2026-10-17)

`ListenerRetrieval.credits` reads the people a seed's own release documents
credit by entry: co-headliners, track artists, and musical or creative
credits, never technical ones. It reads up to eight of the releases the
dated entry lists, from R2. Those credits are offered with their Discogs
ids. A name on the seed's entry takes an id only when exactly one entry on
those releases goes by it. Label rosters and Discogs' same-style lists stay
names. Nothing is matched by name beyond the seed's own records.

- Cluster-seed candidates with a verified id: **0 → 33–36%** (392 of
  1,264 at 21 days; 456 of 1,380 today). That took 942–1,147 credits from
  about 400 R2 documents over the whole run.
- Playable list, summed over four cut-offs (80 slots):

  | list | playable slots | later finds | fit |
  |------|------|------|------|
  | For You today | 22 | 4 | 0.50–0.65 |
  | For You + cluster seeds | **76** (was 25) | **9** (was 7) | 0.28–0.45 |
  | … + bounded radio | 66 | 4 | 0.35–0.39 |
  | … + album similarity | 60 | 4 | 0.33–0.39 |

- **Cluster seeds are now the expansion to build on.** With For You's
  routes kept first, they fill the list with things that play and reach
  more later artists than For You alone. Radio and album similarity on top
  still add slots, not finds.
- **Fit to later listening falls.** Many credited people have no dated
  style, and those that do range wider than the listener's recent sound.
- **Mislabelled route, to fix before anything visible:** artists on a DJ
  mix or compilation a seed made ("A Mixed Tape Made By …", "DJ-Kicks") are
  offered as "direct musical connection". They are the seed's *selections*,
  not collaborators, and need their own route and wording.

## Next

1. **Retrieval from clusters** (Phase 3): done as a prototype, above.
2. **Integration** (Phase 4): For You Mix uses `spread` behind a Debug-only
   switch; the profile cached per sync generation.
3. **Evaluation** (Phase 5): replay at several cutoffs, Mac and iOS
   determinism, and the simulator before any TestFlight build.

Constraints kept: no schema or CloudKit change, no backfill, no new server
data, October 11 R2 generation untouched, App Store config unchanged.
