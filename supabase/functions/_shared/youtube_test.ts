// How a curator's YouTube upload becomes a line of a tracklist.
//
// The title is the only thing that says who made the record, and a wrong
// split is silent: it adopts "Tam gdzie nas nie ma" as an artist rather than
// failing. The titles here are André Navarro II's, as the feed sent them.
//
//     deno test supabase/functions/_shared/youtube_test.ts

import { assertEquals } from "jsr:@std/assert@1";
import {
  isUnchanged,
  linesFor,
  parseFeed,
  parseVideoTitle,
  readTitle,
  REFRESH_DAYS,
  softenCapitals,
  uploadsPlaylistID,
} from "./youtube.ts";

Deno.test("an ARTIST - Title upload splits on the dash", () => {
  assertEquals(parseVideoTitle("SIEGFRIED SCHWAB - Space walk"), {
    artist: "Siegfried Schwab",
    title: "Space walk",
  });
  assertEquals(parseVideoTitle("HASHIRO AYOAMA - Tabi suru san'nin no tēma"), {
    artist: "Hashiro Ayoama",
    title: "Tabi suru san'nin no tēma",
  });
});

Deno.test("only the first spaced dash separates, so names and titles keep theirs", () => {
  assertEquals(parseVideoTitle("HI-FI SET - Yukidoke o machinagara").artist, "Hi-Fi Set");
  assertEquals(parseVideoTitle("HENRIK DEBICH - Tam gdzie nas nie ma - Part 2"), {
    artist: "Henrik Debich",
    title: "Tam gdzie nas nie ma - Part 2",
  });
});

Deno.test("en and em dashes separate too, and doubled spaces are closed", () => {
  assertEquals(parseVideoTitle("MAGIC LADY -  I just wanna be free"), {
    artist: "Magic Lady",
    title: "I just wanna be free",
  });
  assertEquals(parseVideoTitle("Jang Hyun — Milyeon").artist, "Jang Hyun");
  assertEquals(parseVideoTitle("Jang Hyun – Milyeon").artist, "Jang Hyun");
});

Deno.test("entities are decoded before the split", () => {
  assertEquals(
    parseVideoTitle("HANNIBAL (Marvin Peterson) &amp; THE SUNRISE ORCHESTRA - Misty").artist,
    "HANNIBAL (Marvin Peterson) & THE SUNRISE ORCHESTRA",
    "a name that is not all capitals is left exactly as written",
  );
});

Deno.test("promotional and year asides go; asides that name the recording stay", () => {
  assertEquals(parseVideoTitle("COSMOS FACTORY - Hiver (1976)").title, "Hiver");
  assertEquals(parseVideoTitle("X - Y [Full Album]").title, "Y");
  assertEquals(parseVideoTitle("X - Y (Official Audio) [HD]").title, "Y");
  assertEquals(parseVideoTitle("X - Y (Live at Montreux)").title, "Y (Live at Montreux)");
});

Deno.test("capitals are softened, initialisms and numerals are not", () => {
  assertEquals(softenCapitals("JANKO NILOVIC"), "Janko Nilovic");
  assertEquals(softenCapitals("DJ SHADOW"), "DJ Shadow");
  assertEquals(softenCapitals("MFSB"), "MFSB");
  assertEquals(softenCapitals("ANDRÉ NAVARRO II"), "André Navarro II");
  assertEquals(softenCapitals("O'JAYS"), "O'jays");
  assertEquals(softenCapitals("Kate NV"), "Kate NV");
});

Deno.test("a title with no dash plays but claims no artist", () => {
  assertEquals(parseVideoTitle("Untitled tape from a flea market"), {
    artist: null,
    title: "Untitled tape from a flea market",
  });
});

Deno.test("every line carries its own watch address", () => {
  const [line] = linesFor([{ videoID: "abc123XYZ_-", title: "A - B", publishedAt: null }]);
  assertEquals(line.mediaURL, "https://www.youtube.com/watch?v=abc123XYZ_-");
  assertEquals(line.artist, "A");
});

Deno.test("the uploads list shares the channel's id", () => {
  assertEquals(uploadsPlaylistID("UCv5OAW45h67CJEY6kJLyisg"), "UUv5OAW45h67CJEY6kJLyisg");
});

Deno.test("the feed yields the channel title and its uploads", () => {
  const xml = `<?xml version="1.0"?><feed><title>André Navarro II</title>
    <entry><yt:videoId>v1</yt:videoId><title>JANKO NILOVIC - Dans ma tristesse</title>
    <published>2026-09-20T10:00:00+00:00</published></entry>
    <entry><yt:videoId>v2</yt:videoId><title>BELL &amp; JAMES - Wind and rain</title>
    <published>2026-09-19T10:00:00+00:00</published></entry></feed>`;
  const feed = parseFeed(xml);
  assertEquals(feed.title, "André Navarro II");
  assertEquals(feed.videos.map((video) => video.videoID), ["v1", "v2"]);
  assertEquals(feed.videos[1].title, "BELL & JAMES - Wind and rain");
});

Deno.test("a list is left alone only at the same size and while still fresh", () => {
  const now = Date.parse("2026-09-24T00:00:00Z");
  const recent = { count: 120, readAt: "2026-09-20T00:00:00Z" };
  assertEquals(isUnchanged(recent, 120, now), true);
  assertEquals(isUnchanged(recent, 121, now), false, "a new video means a re-read");
  assertEquals(isUnchanged(undefined, 120, now), false, "never read");
  assertEquals(isUnchanged(recent, -1, now), false, "the uploads list, whose size is unknown");
  const old = { count: 120, readAt: new Date(now - (REFRESH_DAYS + 1) * 86_400_000).toISOString() };
  assertEquals(isUnchanged(old, 120, now), false, "aged out of what the terms allow keeping");
});

Deno.test("an invisible direction mark before the dash does not hide it", () => {
  assertEquals(parseVideoTitle("Carter Jefferson \u200E– The Rise Of Atlantis 1979"), {
    artist: "Carter Jefferson",
    title: "The Rise Of Atlantis",
  });
});

Deno.test("a tilde separates, as jazznote89 writes it", () => {
  assertEquals(parseVideoTitle("Terumasa Hino Sextet ~ Be And Know (1972)"), {
    artist: "Terumasa Hino Sextet",
    title: "Be And Know",
  });
});

Deno.test("trailing clutter goes, however it is stacked", () => {
  assertEquals(parseVideoTitle("The Pharaohs - Sun Sketches: Heb Sed Jubilee - FULL ALBUM").title,
    "Sun Sketches: Heb Sed Jubilee");
  assertEquals(parseVideoTitle("Mainhorse - Pale Sky (1971) HQ").title, "Pale Sky");
  assertEquals(parseVideoTitle("Frank Rothman - Bright Jaunty Boop  -1969").title, "Bright Jaunty Boop");
  assertEquals(parseVideoTitle("Joe Marillo Quartet ~ Tribute to Wayne Shorter 1978").title,
    "Tribute to Wayne Shorter");
});

Deno.test("clutter is never stripped down to nothing, or out of a word", () => {
  assertEquals(parseVideoTitle("Prince - 1999").title, "1999");
  assertEquals(parseVideoTitle("X - Orchard").title, "Orchard");
  assertEquals(parseVideoTitle("X - Mhd").title, "Mhd");
});

Deno.test("a titles-only channel claims no artist, however its titles look", () => {
  assertEquals(readTitle("Stop and Go - aldino remix", "title_only"), {
    artist: null,
    title: "Stop and Go - aldino remix",
  });
  assertEquals(readTitle("Sketches of Spain", "title_only").title, "Sketches of Spain");
  assertEquals(readTitle("Stop and Go - aldino remix", "artist_title").artist, "Stop and Go");
});

Deno.test("a quoted title after an unspaced dash splits", () => {
  assertEquals(parseVideoTitle('Les McCann- "The Harlem Buck Dance Strut"'), {
    artist: "Les McCann",
    title: "The Harlem Buck Dance Strut",
  });
  assertEquals(parseVideoTitle('Eddie Harris-"It\'s Crazy"').artist, "Eddie Harris");
  assertEquals(parseVideoTitle("Hi-Fi Set - Yukidoke").artist, "Hi-Fi Set", "no quotes: the spaced dash rules");
});

Deno.test("a title with no separator at all is not guessed at", () => {
  assertEquals(parseVideoTitle("Donald Byrd Beast Of Burden").artist, null);
});

Deno.test("a title-first channel is read the other way round", () => {
  assertEquals(readTitle("Happy Frame Of Mind - Horace Parlan", "title_artist"), {
    artist: "Horace Parlan",
    title: "Happy Frame Of Mind",
  });
  assertEquals(readTitle("A lone title", "title_artist").artist, null);
});

Deno.test("of two spellings, the romanised one is read", () => {
  assertEquals(parseVideoTitle("田口久美 - Ｏ嬢の物語 // Kumi Taguchi - Mrs O's story"), {
    artist: "Kumi Taguchi",
    title: "Mrs O's story",
  });
  // A second half with no artist of its own leaves the whole line to the
  // ordinary split.
  assertEquals(parseVideoTitle("Artist - Title // live").artist, "Artist");
});

Deno.test("a country tag and genre list after the title go", () => {
  assertEquals(parseVideoTitle("The Scorpion - Keep On Trying [US] Soul, Funk (1974)").title, "Keep On Trying");
  assertEquals(
    parseVideoTitle("Marilia Medalha - Nós Os Grandes Artistas [Brazil] Soul, Bossa Nova, MPB (1978)").title,
    "Nós Os Grandes Artistas",
  );
  assertEquals(parseVideoTitle("X - Song [Remix]").title, "Song [Remix]");
});
