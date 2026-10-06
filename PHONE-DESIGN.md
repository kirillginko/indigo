# Mineral on the iPhone — design notes

How the iPhone layout is set out, so every page reads as one app. The Mac
keeps its own layout; everything here applies when `isPhoneLayout` is set
(`PhoneRootView`).

The look follows IDA Radio's app: words set in boxes, edge to edge, on a
dark ground that moves. Every page is built from the pieces named below.
**A new phone page uses these pieces; it does not invent a section of its
own.** If a page needs something none of them do, add it here first.

---

## 1. Principles

1. **One fact, one row.** Each fact gets its own row, in the same order
   wherever it appears. Nothing is squeezed beside something else.
2. **Boxes touch only when they are one statement.** A title over its
   artist; a time and its label (`22:00` + `NEXT UP`); a count and its
   label. Anything else is its own row, 8 pt apart.
3. **Colour says what a box is** (§2), never decorates.
4. **Square content, round controls.** What you read or open is square;
   what moves you around is round (§5).
5. **One direction.** Pages scroll down. Nothing scrolls sideways; sets of
   boxes wrap.
6. **One builder per thing.** A station's broadcast is turned into a row in
   one place (`PhoneEpisodeRows.swift`), so its rows are the same on every
   page. Never build a `PhoneEpisode` by hand for a station.
7. **Everything reachable.** Every section the Mac lists for a station is
   reachable on the phone, and every page it opens has a phone layout. A
   Mac page reached on the phone is a bug.

---

## 2. Colour

| Token | Value | Means |
|---|---|---|
| `Chip.green` | IDA's green | **What or where**: the city, the station, the kind (ARTIST, RELEASE, TRACK), section titles, who made a track, the play box |
| `Chip.black` | near-black | **Names**: shows, episodes, tracks, artists, labels; neutral buttons |
| `.sheen` (`MineralSheenSurface`) | the wordmark's moving metal | **Time and now**: a show's slot, the next show's time, the row playing now; round controls |
| `Chip.greens` | five greens, all light enough for dark ink | **Telling neighbours apart**: genres and tracklist artists |
| `Chip.ink` | dark green-black | words on any green or sheen |
| `PlayerShaderBackdrop` | the player's moving field | the mini player, the station pill, a page with no picture |
| `IndigoGlassBackground.header` | the headers' shade | page headers, and the status-bar and home-bar strips |
| `PhoneShowPage.rowGround` | see-through dark | list rows, so the moving ground shows under them |

- **Genres** are always `Chip.genre(_:)`: a green chosen from the genre's
  name, so "Disco" is the same green everywhere and genres side by side
  read apart.
- **Tracklists** step through `Chip.green(at:)` down the list, one shade a
  line, on the artist box.
- Text on dark boxes is white at 92%; secondary text (dates, notes) white at
  55–60%.

---

## 3. Type

| Use | Font |
|---|---|
| Everything in boxes, labels, dates, notes | `Typeface.mono` |
| Labels (kinds, sections, NEXT UP, ON NOW, genres) | mono, small capitals (`uppercase: true`), tracking 1.2 |
| Hero name | mono 20 in a dark box |
| Row title | mono 13 in a dark box, up to 3 lines |
| Row second line | mono 12 in a green box, 1 line |
| Genres | mono 11 in green boxes |
| Description | mono 12.5, white 72%, line spacing 3 |

The Mac's `Typeface.display` and `body` are not used on phone pages.

---

## 4. Layout and spacing

- **Margin**: `PhoneLayout.margin`, 16 pt. Section titles (`DigSection`)
  sit against the screen's left edge, past the margin.
- **Rows** are 8 pt apart inside a block; sections 18–26 pt apart.
- **Grids** are two to a row, 2 pt gutters, square cards, the name in a box
  along the bottom (Shows grids, Dig shelves, station sections).
- **Heroes** are the picture the width of the screen, square, darkened
  towards the bottom, with the words centred over it.
- **Edges**: no empty bands. Phone headers keep no room for the Mac's
  window buttons; the status-bar and home-bar strips take the headers'
  shade; the home bar fades; the tab bar sits down in its strip.
- **Orientation**: the iPhone stays upright. A full-screen video opens
  upright and turns only if the phone is turned; minimised (the round
  button, or a swipe down), the phone stands back up (`OrientationLock`).
- **Sharp pictures**: a picture is asked for at the size it is drawn
  (`ArtworkSizing`): a full-width hero asks NTS, Mixcloud, Contentful,
  WordPress and YouTube for a larger cut than a list does, with the
  station's own cut as the preview. Never set a row's small cut (a
  `thumbnailURL`) as a hero's picture.
- **No picture**: a show, artist, record or station with no picture, or one
  that failed to load, is the wordmark's moving green on the phone
  (`MineralSheenSurface(lowResolution: true)`, drawn once per size) -- one
  fallback everywhere, never a blank, a glyph or a mosaic.
- **Discogs pictures** are the cover (600 px), never the 150 px thumb:
  their addresses are signed, so the size cannot be asked of the thumb.

---

## 5. Controls

| Control | Shape | Piece |
|---|---|---|
| Back, info, close player, video full screen / minimise | round, 46 pt, on the sheen | `PhoneRoundGlyph`, `PhoneBackGlyph` |
| Tab bar | glass capsule, the current tab in `Chip.green` | `PhoneTabBar` |
| Search | round, beside the tab bar | `PhoneTabBar` |
| Station name at the top | rounded pill on the player's field, red dot | Live slide, station page |
| Mini player | small radius (12), the player's field | `PhoneMiniPlayer` |
| Play an episode / Play live | square green box, full width | page intro |
| Play in a row | square green box, 32 pt | `PhoneEpisodeRow` |
| Crate | square glyph | the station's `…CrateButton`, or `BroadcastCrateButton` |

---

## 6. Components

| Piece | Use it for |
|---|---|
| `Chip` | every word in a box |
| `Chip.genre(_:)` | every genre |
| `ChipFlow` | a run of boxes, wrapped and centred |
| `NextUpRows` | what comes on next — time + NEXT UP, then the name |
| `PhoneDetailHero` | the head of any detail page |
| `PhoneDetailTopBar` / `PhoneDetailChrome` | back and crate over a hero |
| `DigSection` | a titled section, the title in a green box at the left edge |
| `DigLine` | a link: the name over its detail, two boxes touching |
| `PhoneEpisodeRow` | any broadcast in a list |
| `PhoneLinkRow` | a way out with a picture and why (Continue digging, Played alongside) |
| `PhoneShowPage` | a show, DJ, curator, mood, resident or collection |
| `PhoneEpisodePage` | an episode, a Noods or alHara recording |
| `PhoneStationPage` | a station |
| `PhoneStationSectionPage` | a station's Latest / Archive / Episodes / Podcasts / Index / Discover / Mixtapes / Moods / Residents / Collections / Curators |
| `PhoneShowsView` | the Shows tab, and a station's shows grid |

---

## 7. Rows

Every broadcast in every list is a `PhoneEpisodeRow`, built by its
station's builder in `PhoneEpisodeRows.swift`:

```
[ picture ] [ TITLE — the broadcast's own name      ]  date
            [ who was on  ]                            [▶] [+]
            [ GENRE ] [ GENRE ] [ GENRE ]
```

- **Title**: the broadcast's own name. Never the show's name repeated on
  every row.
- **Second line**: who was on. Where a station names nobody and the list
  spans shows, the show's name; on the show's own page (or a "More from"
  list of the same show), nothing rather than repeat the page.
- **Genres**: up to three, as fit, each in its own green.
- **Date**: top right, day first (06.10.2026), with room of its own.
- **Play and crate**: centred in the row's height, always both.

| Station | Who | Show (lists across shows) | Genres | Crate |
|---|---|---|---|---|
| IDA | subtitle or show artist | show title | yes | IDA's |
| The Lot | residents | show name | yes | Lot's |
| Cashmere | — | show name | yes | Cashmere's |
| LYL | artists | show title | styles | LYL's |
| Radio 80000 | — | show title | yes | 80000's |
| Panik | — | show title | — (none published) | Panik's |
| ROVR | curator | show title | tags | ROVR's |
| n10.as | guest | programme | yes | n10.as's |
| dublab | performer | show name | yes | dublab's |
| alHara | — | — | yes | alHara's |
| Kiosk | — | — | yes | Kiosk's |
| Noods | artist | — | yes | `BroadcastCrateButton` |
| NTS | — | — | yes | `BroadcastCrateButton`, audio found on play |

The crate's own rows and an archive's YouTube uploads are the two lists not
built from a station's broadcast; they use the same `PhoneEpisodeRow`.

---

## 8. Page templates

**For You** — first screen: the For You shader uncovered, an ASCII globe
turning in it (`PhoneForYouGlobe`), and IDA boxes pinned about its
surface, kind or city in green over the name: the suggestions the Mac's
For You has, or before anything is kept, every station (tap to play) and
one Archives box. Boxes fade round the back and stay on screen at the
edges; the globe turns by hand sideways; swiping up goes to the
suggestions, one a screen.

**Live slide** — picture full-bleed; top: info (round), station pill;
bottom, one row each: city · show · genres · `NextUpRows` · PLAY.

**Station page** — hero (city, show, station, genres); PLAY LIVE; slot +
ON NOW; `NextUpRows`; About; Browse (the station's sections as boxes);
Shows (the station's grid).

**Show page** (`PhoneShowPage`) — hero (station, host, name, genres);
description; the episodes as rows, reading on as the end comes into view.

**Episode page** (`PhoneEpisodePage`) — hero (city or station, name, who,
genres); description; date and length; PLAY EPISODE, the show's name, the
crate; Tracklist (title over artist, artist in the next green); More from
the show.

**DIG pages** (artist, track, release, label) — hero with the kind (ARTIST,
TRACK, RELEASE, LABEL), back and crate; counts as pairs of boxes; sections
stacked, never side by side.

**Section page** — round back to the station, the station over the
section's name; a list of rows or a grid of two.

**Shows tab** — every station as a row; tapping opens it out (accordion,
arrow right → down) to its shows and its sections.

**Crate** — header (compact), genres filter, days, rows.

---

## 9. Navigation

- Tabs: For You, Live, Shows, Crate; Search (Dig) beside them.
- Back from a station returns to Live at the same station; back from a
  section returns to where it was opened (the station, or the Shows list).
- Detail pages stack and pop with back.

---

## 10. Audit — 2026-10-06

What the audit of every station's rows found, and what was done:

| Found | Fixed |
|---|---|
| 40 hand-built rows in 28 files | 37 now come from `PhoneEpisodeRows.swift`; the crate's and YouTube's are their own kinds |
| IDA's show page titled every row with the show's name | the episode's own name |
| No crate on any episode page's "More from" list (11 stations) | crate on every row |
| No crate on NTS or Noods rows | `BroadcastCrateButton` |
| The second line was who, or the show, or nothing, for the same station | one rule (§7) |
| dublab titled rows with the show name | the broadcast's title, the performer under it |

Still open: Panik publishes no genres; Cashmere, Radio 80000, Kiosk,
alHara and NTS name nobody per broadcast, so their rows have no second
line on a show's own page.
