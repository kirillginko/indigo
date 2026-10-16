# DIG Discover: track availability audit (2026-10-15)

Read-only, from the backend's radio record; playback checked through the
integration that would play each one (YouTube/SoundCloud/Mixcloud oEmbed,
Lot Radio HLS playlist). No listener data.

## Radio track appearances (260,178)

| | appearances |
|---|---|
| by an artist with a verified Discogs identity | 57,530 |
| in an NTS or Lot episode with an archive, at a known moment | 44,775 (38,326 distinct tracks, 8,110 artists) |
| same, moment not known | 11 |
| a YouTube upload of the track itself (all artists) | 79,898 (53,306 distinct videos) |
| …of which by a verified artist | 12,744 |
| Deezer track id only (Indigo does not play Deezer) | 12,881 |

## Playback, deterministic random sample

| kind | plays | does not | could not tell |
|---|---|---|---|
| YouTube track upload (400) | 398 | 2 | 0 |
| NTS episode containing the track (249) | 249 | 0 | 0 |
| Lot Radio episode containing the track (151) | 127 | 0 | 24 |

By episode genre (NTS/Lot sample): hip-hop/r&b 64/64, indie/rock 74/74,
global 69/71, soul/funk/disco 49/51, ambient/experimental 110/113,
techno/house 188/199, jazz 31/33 (jazz is the thinnest: 33 of 400).

## Discover on fourteen radio hosts across genres (each a listener whose crate is the ten verified artists their show plays most)

Every listener got playable tracks; 12 a listener in 13 of 14, 8 for one.
All offered tracks were checked to play; unanswered checks were never offered.
Median 1.8 s to a list, about 15 requests.
