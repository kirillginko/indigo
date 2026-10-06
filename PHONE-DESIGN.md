# Phone design principles

How the iPhone layout is set out, so every page reads as one app. The look
follows IDA's app: words in boxes, edge to edge, on a dark moving ground.
When a new phone page is made, it is built from the pieces named here, not
from new ones.

## 1. One fact, one row

Each fact gets its own row, and the rows come in the same order everywhere
they appear.

- **A live show** (Live slide, station page): city · show name · genres ·
  time + NEXT UP · next show's name. Use `NextUpRows`; never set the next
  show's name inline.
- **An episode or show page**: kind or station · name · who was on · genres,
  in `PhoneDetailHero`, then the description, then the play box, then the
  lists.

Rows are 8 pt apart. Boxes in one row touch.

## 2. Boxes touch only when they are one statement

Two boxes sit against each other (no gap) when together they say one thing:

- a title over its artist (`Chip` over a `.lead` `Chip`), in lists, players,
  cards and tracklists;
- a time and its label (`10:00` + `NEXT UP`, `21:00–23:00` + `ON NOW`);
- a count and its label in tallies.

Anything else is a separate row with the ordinary gap. The next show's name
is a separate fact from its time, so it is its own row.

## 3. What each box means

| Box | Use |
|---|---|
| Green (`.lead`) | What a thing is or where: the city, the station, the kind (ARTIST, RELEASE), section titles, who made a track |
| Dark (`.plain`) | Names: shows, episodes, tracks, artists, labels |
| Sheen (`.sheen`) | Times, and what is playing now |

Labels (kinds, sections, NEXT UP, ON NOW) are in small capitals.

## 4. Square content, round controls

- **Square**: everything you read or open: boxes, pictures, cards, rows,
  the play-episode and play-live boxes.
- **Round**: everything that moves you around: back and info
  (`PhoneRoundGlyph`, on the wordmark's sheen), the tab bar and its search
  button, the station name pill at the top, the mini player (small radius).

## 5. Layout

- Everything scrolls one way, down. Nothing scrolls sideways; long sets of
  boxes wrap (`ChipFlow`, `FlowLayout`).
- Grids are two to a row (the Dig shelves, station sections, show grids),
  square cards, the name in a box along the bottom.
- Lists use `PhoneEpisodeRow`: picture, title over who, date, genres, play
  and crate on the right, one dark ground with a line under each.
- Section titles (`DigSection`) sit against the screen's left edge.
- The page margin is `PhoneLayout.margin` (16 pt).
- Text is in boxes centred on the slide for heroes and live slides, and
  left-aligned in lists.

## 6. Navigation

- Every station section the Mac lists is reachable on the phone from the
  station's page (`PhoneStationSection`), and every page those open has a
  phone layout. A Mac-only page reached on the phone is a bug.
- Back from a station returns to Live at the same station; back from a
  section returns to its station.
