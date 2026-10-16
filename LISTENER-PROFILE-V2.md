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

## Next

1. **Retrieval from clusters** (Phase 3): done as a prototype, above.
2. **Integration** (Phase 4): For You Mix uses `spread` behind a Debug-only
   switch; the profile cached per sync generation.
3. **Evaluation** (Phase 5): replay at several cutoffs, Mac and iOS
   determinism, and the simulator before any TestFlight build.

Constraints kept: no schema or CloudKit change, no backfill, no new server
data, October 11 R2 generation untouched, App Store config unchanged.
