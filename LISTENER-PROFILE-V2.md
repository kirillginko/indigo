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
  only when nothing narrower exists. Aliases fold into the artist whose own
  Discogs entry lists them (union-find, alphabetically first, so every
  device agrees).
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

## Next

1. **Retrieval from clusters** (Phase 3): seed routes from each cluster's
   heaviest units rather than twelve recent artists, and widen the pool with
   two shared radio hops weighted by how specific the show is, plus Records
   like yours by cluster centroid. Replay again: later finds is the measure.
2. **Integration** (Phase 4): For You Mix uses `spread` behind a Debug-only
   switch; the profile cached per sync generation.
3. **Evaluation** (Phase 5): replay at several cutoffs, Mac and iOS
   determinism, and the simulator before any TestFlight build.

Constraints kept: no schema or CloudKit change, no backfill, no new server
data, October 11 R2 generation untouched, App Store config unchanged.
