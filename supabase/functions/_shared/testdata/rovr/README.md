# ROVR fixtures — synthetic

Every file here is **synthetic**. No line was copied from ROVR. The names,
titles, labels, ISRCs (all `ZZ`-prefixed) and URLs are invented. Only the
*shape* comes from ROVR: the detail answer of
`GET https://strapi.rovr.live/api/playlists/archives/public/{documentId}`, as
observed in the read-only audit on 2026-10-17
(`docs/radio-tracklist-audit.md` §3.2). No ROVR payload was saved during the
audit, and none was fetched to build these. ROVR has not granted reuse of its
tracklists, so real payloads must not be committed here.

| File | Covers |
|---|---|
| `1-complete.json` | Every field filled, valid ISRCs, cues with sub-millisecond noise, a numeric year |
| `2-missing.json` | Null and empty ISRCs, `"year": "None"`, a missing artist, a missing title, blank lines, an entry with only ids, no cues, `{data, meta}` envelope |
| `3-unicode.json` | Macrons, Icelandic, Cyrillic, Arabic, zero-width characters in a label, `x` collaboration, `&` duo, `feat.` in the artist and in the title, an alias pair (`Lowtide73` / `Lowtide 73`), an unspaced hyphen, a remix credit, a punctuation-only artist, `ID – ID` |
| `4-malformed.json` | Hyphenated and lower-case ISRCs, 5- and 13-character ISRCs, a numeric ISRC, a negative and a reversed cue, a non-numeric cue, a duplicate cue, an orphan cue, a cue with no index, an out-of-order start, repeats by ISRC and by name, same names under different ISRCs, `null` and string entries, wrong-typed fields, a bad URL, unknown keys |
| `5-mixed.json` | 48 lines generated with a fixed seed. Presence rates and string lengths are calibrated on aggregate statistics of 315 real ROVR lines (artist 15 B mean, title 17 B mean, ISRC on 91%). Includes two deliberate repeats. Used for the storage benchmark |

## Verified vs assumed

Verified on real detail answers (8 archives, 2026-10-17):

- Archive keys: `id, documentId, title, releaseDate, scheduleDate, curator
  (object with name), show, aiDescription, hasVoiceOver,
  playlistProcessedAudioDuration, playlistStatus, playlistTags, progress,
  soundcloudPermalinkUrl, soundcloudEmbedUrl, stitchedTracksMetadata, tracks`,
  and others listed in `KNOWN_ARCHIVE_KEYS` in `rovr.ts`.
- Track keys: `id, documentId, title, artist, label, album, duration (float
  seconds), isrc, tuc, year (string), youtube, spotify, apple, discogs,
  aiDetectedGenresData, albumCoverUrl, owner`.
- `stitchedTracksMetadata.tracks_cues[]` = `{cue, start, end, track_index}` in
  float seconds. Neighbouring cues overlap by a few seconds (crossfades).
- `year` arrived once as the literal string `"None"`. Labels carry zero-width
  spaces. Track ids are per playlist row (consecutive), not per recording.

Assumed, never observed:

- How `show` looks when it is not null.
- Whether ISRCs ever arrive hyphenated, lower-case or with an `ISRC:` prefix
  (fixture 4 tests it defensively).
- Negative, reversed, duplicate or orphan cues, and non-object track entries.
  None were seen. They are tested so that one bad line cannot sink a playlist.
- Whether `tracks_cues.track_index` always matches the `tracks[]` position.
  The parser keys cues by `track_index` and reports orphans.
- Whether a playlist page is wrapped in `{data, meta}` on every route. Both
  wrapped and bare objects are accepted.
