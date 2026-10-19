# Last.fm similarity audit

*2026-10-16. Phase 1 (API and licensing) is complete. Phases 2–6 have not
been run: no request has been made to the Last.fm API, because Indigo has no
API key and Last.fm asks that research use be cleared with it **before** the
API is used (§1.1). Nothing in production, R2, Supabase, CloudKit or the App
Store builds was touched.*

**Decision: Research only.** Last.fm's community similarity may be the one
signal Indigo's graph can't build itself: two artists who share no credit,
label or radio show but share an audience. However, the free licence is
non-commercial. It caps stored Last.fm data at 100 MB and forbids
sub-licensing. A shared similarity layer in R2 serving a product with paid
features would breach it on three counts unless Last.fm grants a commercial
agreement. Benefit is unmeasured; the legal ceiling is already known.

---

## 1. Licensing findings

Sources: [API Terms of Service](https://www.last.fm/api/tos),
[API home](https://www.last.fm/api), [API intro](https://www.last.fm/api/intro).
The Terms carry no version or effective date; Last.fm may amend them at any
time (§10.1) and continued use is acceptance.

### 1.1 Before any use

- The API home asks anyone planning **commercial or research/academic** use
  to contact **partners@last.fm** *prior to use*. This audit is research
  done for a product that may become commercial, so it falls under this
  request. Phases 2–6 should wait for that contact.
- A key comes from a registered Last.fm API account (§2.2). Creating that
  account and accepting the Terms is the developer's step, not something an
  agent should do on Indigo's behalf.

### 1.2 What the free licence allows and forbids

| Question | Terms | Effect on Indigo |
|---|---|---|
| Commercial use | §3.1: data may be used "solely for non-commercial purposes". Commercial use needs a separate agreement; without one it is a material breach. Commercial use is not defined. | Any paid tier that uses Last.fm-derived ranking needs a commercial agreement. A free build of a product meant to be sold is a grey area. Ask Last.fm, don't assume. |
| Revenue | Nutshell: Last.fm reserves the right to share in revenue from use of its data, on terms to be negotiated. | Expect a commercial agreement to carry a fee or revenue share. |
| Storage | §4.3.4: only "a small portion" of the data, never above the **Reasonable Usage Cap of 100 MB** in total. A database counts as storage. More needs written consent. | A catalogue-wide similarity layer can't fit (§7). A per-artist, on-demand cache that expires can. |
| Caching | You must cache according to the HTTP headers on responses. | A TTL cache keyed by request is required, not optional. |
| Redistribution | §4.1–4.3: copying and publishing are licensed, but with no sub-licensing to third parties, no added restrictive terms, no DRM, and no "derogatory treatment (distortion or mutilation)". | Showing results to users with credit is fine. Republishing a derived dataset, or letting another service read Indigo's R2 copy, is not. Re-weighting scores inside a ranker is probably not "mutilation", but showing a reshuffled list as "Last.fm says" would be. |
| Attribution | §2.7, §4.2.1–4.2.2, §7.1: credit Last.fm and link to the matching Last.fm page. A "powered by AudioScrobbler" badge is mentioned. Placements and marks need approval and must follow the Brand Guidelines. | Every artist page or DIG row that uses the signal links to that artist on last.fm. Badge placement needs sign-off. |
| Rate limits | §4.4: set at Last.fm's sole discretion; circumventing them is forbidden. The intro page says "several calls per second" sustained risks suspension, and asks for an identifiable User-Agent. No number is published. | Plan for ≤1 request/s per key, from a backend worker, never from page load (intro page). |
| Audio, artwork | §5.1.8: audio and artwork are excluded from the licence. `streamable` is not a playback right. | Last.fm never decides playability. Playback stays with Indigo's existing integrations. Images are not used. |
| Users | §5.1.6: no identifying or contacting users through the data. | Only artist, track and tag endpoints, no user endpoints. |
| Cross-border | Nutshell, §2.5: consents are needed to send data to other countries. | Check with Last.fm. R2 and devices are global. |
| Termination | §9.2–9.3: Last.fm can end access at any time. Indigo must stop and delete Last.fm data "as soon as reasonably possible". | Anything built on it must degrade to the relationship graph alone, and the cache must be deletable as one unit. |

**Can Indigo keep derived similarity in R2?** Under the free licence, only
as a small, expiring cache (well under 100 MB) that Indigo reads for itself.
Derived edges are still "Last.fm Data" in any reasonable reading, so turning
them into a permanent shared knowledge layer needs written consent.
**Permission is needed** for the intended use.

## 2. Endpoint capability matrix (from the documentation)

None of these endpoints need user authentication, but all of them need an
`api_key`. All take `format=json`. The artist methods take `artist` or
`mbid` plus `autocorrect`.

| Endpoint | Returns | Score | IDs | Notes |
|---|---|---|---|---|
| `artist.getSimilar` | similar artists | `match` 0–1 | artist MBID (may be empty), URL | `limit`. **Core candidate signal.** |
| `artist.getTopTags` | tags ordered by popularity | the docs sample shows none (the JSON is reported to carry `count` 0–100; unverified) | — | Scene vs. generic style test (§4) |
| `artist.getInfo` | listeners, plays, bio (300-char summary), tags, ~5 similar | — | MBID, URL | Popularity for de-biasing; bio is licensed data, not ours |
| `artist.getTopAlbums` | albums by popularity, listeners | rank | album MBID | `page`/`limit` (50) |
| `artist.getTopTracks` | tracks by popularity | rank | track MBID | Recording-level seeds |
| `track.getSimilar` | similar tracks with artist | `match` (sample shows 10.95, so the scale is **not** 0–1) | track and artist MBID (sample empty) | Only true recording-level signal |
| `track.getTopTags` | tags | as getTopTags | — | |
| `tag.getSimilar` | similar tags | none | — | Widely reported to return empty lists for years (unverified here) |
| `tag.getTopArtists` | artists for a tag | rank | artist MBID | `page`/`limit` (50). Scene rosters |
| `tag.getTopAlbums` | albums for a tag | rank | album MBID | Scene albums |

Known failure shapes to test once a key exists (from client libraries, e.g.
[Navidrome's spec](https://glama.ai/mcp/servers/@Blakeem/Navidrome-MCP/blob/c0ee251c8dff9236b2fb401b6cf412b504721b83/docs/LAST-FM-API-SPEC.md)):
an MBID Last.fm doesn't know gives error 6 or an "[unknown]" artist, and
clients fall back to name + autocorrect. **That fallback is exactly the
name-only identity path Indigo forbids** (§3). Response times, empty rates
and obscure-artist coverage are **not measured**.

## 3. Identity rules a probe must follow

These are taken from what Indigo already enforces in
`Indigo/Dig/ArtistIdentity.swift`, `Indigo/Graph/GraphIdentity.swift` and
the ExploreRanker known-artist policy:

1. Query by **MBID** only when Indigo holds a MusicBrainz link for a
   Discogs-verified artist. Never query by name with `autocorrect=1` and
   treat the answer as that artist.
2. A returned neighbour becomes a **verified candidate** only if its MBID
   maps, through MusicBrainz's Discogs URL relation, to exactly one Discogs
   id Indigo already knows. A name match, even an exact one, leaves it
   **unresolved**. It may be shown as a discovery candidate but never
   becomes an edge.
3. A neighbour with an empty MBID is unresolved by definition.
4. Last.fm merges namesakes under one name page, so for an artist whose
   name is shared, the whole neighbour list is suspect unless the seed was
   an MBID query.

Test cases to run first: Prefuse 73 (spelling), Hype Williams (duo vs.
video director vs. others), Speedy J (several Discogs entries), Mica Levi /
Micachu (person vs. project), plus Arp / A.R.P. (memory: namevariations are
not identity).

## 4–6. Coverage, quality, track and album discovery: not run

The protocol, ready once §1.1 is cleared and a key exists:

- **Sample:** 240 artists, 30 from each of the brief's seven groups plus 30
  of the 8,557 shared-catalogue dead ends (`DIG-REMEDIATION-PLAN.md` §0).
  Drawn reproducibly from `artists`, like `sample.sql`.
- **Indigo side:** the existing DIG candidates per artist (collaborators,
  label peers, radio neighbours, bundle styles), read-only through
  `explore_knowledge` and R2 bundles.
- **Last.fm side:** `artist.getSimilar` (limit 50) and
  `artist.getTopTags`, with `track.getSimilar` for each artist's top 3
  tracks. About 240 × 5 = 1,200 requests at 1 request/s, about 20 minutes.
  The cache is a scratch directory, deleted after the run, about 15 MB.
- **Measures:** dead-end rescue rate (verified candidates on pages with
  none); novel verified candidates; unresolved share; false identity
  matches (hand-checked); popularity drift (median listeners of candidates
  vs. seed); tag specificity (share of top tags that are generic:
  electronic, rock, experimental, seen live); playability of
  `track.getSimilar` results through Indigo's own providers.
- **Rankings:** A (today), B (Last.fm `match`), C (hybrid: verified
  relationship weight + `match` × specificity-weighted tag overlap − a
  popularity penalty on listeners relative to the seed). The success
  criterion is novel *verified* musicians on pages A leaves thin, not
  overlap with B.

## 7. Storage, request and cost estimates

These are estimates from documented response shapes, not measured.

| Scenario | Size | Requests | Within free licence? |
|---|---|---|---|
| Research run, 240 artists | ~15 MB raw, deleted afterwards | ~1,200 | Yes, once cleared under §1.1 |
| On-demand per page view, TTL cache | bounded by eviction at <100 MB | one per cold page | Non-commercial only |
| Catalogue-wide getSimilar, 118,607 artists × 50 neighbours, compact (two ids + score ≈ 40 B) | **~240 MB** | ~119k, about 33 h at 1 request/s | **No.** Over the cap even when compact. It is a database (§4.3.4), and a shared layer for a paid product. |

API calls cost nothing in money. The costs are the commercial agreement
(unknown, and possibly a revenue share), attribution UI work, and the risk
that access ends with deletion required (§9.3).

## 8. Recommendation

**Research only**, in this order:

1. Email partners@last.fm. Describe Indigo (an independent music-discovery
   app with possible paid features), the intended use (artist similarity
   and tags as one ranking signal, links back to Last.fm, a cache), and ask
   about research clearance, commercial terms, storage above 100 MB, and
   R2 as a shared cache.
2. On research clearance, create the API account, then run §4–6 as written.
   The prototype is about a day of work: a read-only script in `Scripts/`
   that reads the key from the environment, with no Supabase writes.
3. Integrate only with a commercial agreement **and** a measured result
   where the hybrid adds verified musicians to dead-end pages without
   popularity drift. Until then, keep improving the free signals Indigo
   owns (`DIG-REMEDIATION-PLAN.md`).
