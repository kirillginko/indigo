// How a Lot Radio archive item becomes an Indigo broadcast.
//
// Everything here decides identity: which programme a set is filed under,
// which name an artist is adopted as, which place a scene is keyed on. Every
// mistake is silent -- a wrong key makes a second artist, not an error.
//
//     deno test supabase/functions/_shared/lotradio_test.ts

import { assertEquals } from "jsr:@std/assert@1";
import {
  findActionID,
  flightPayload,
  parseActionReply,
  parseIndexPage,
  placeName,
  readEpisode,
  repairMojibake,
  scriptPaths,
} from "./lotradio.ts";

// Shaped like the site's own items, trimmed to what is read.
function item(overrides: Record<string, unknown> = {}) {
  return {
    sys: { id: "57lCQyE65Zt32jJvPeJS2Q" },
    title: "Yushh",
    slug: "2026-09-14-1700",
    date: "2026-09-14T21:00:00.000Z",
    startTimestamp: "2026-09-14T21:02:12.000Z",
    endTimestamp: "2026-09-14T22:59:05.000Z",
    transcodedFile: {
      hls: "https://link.storjshare.io/raw/x/thelot-archive/episodes/57lCQyE65Zt32jJvPeJS2Q/hls/index.m3u8",
    },
    tracklist: [
      { title: "The Ones Beyond the Clouds (云那边的)", artist: "Heling", timestamp: "2026-09-14T21:03:46.000Z" },
      { title: "Eternal Eye", artist: "I.T.Z & Traction Control", timestamp: "2026-09-14T21:30:56.000Z" },
    ],
    location: { name: "The Lot Radio, NYC" },
    genres: { items: [{ name: "Techno" }, { name: "Drum & Bass" }] },
    image: { url: "https://images.ctfassets.net/episode.jpg" },
    artists: { items: [{ name: "Yushh", slug: "yushh", photo: { url: "https://images.ctfassets.net/yushh.jpg" } }] },
    show: {
      name: "Special Guests",
      slug: "special-guests",
      photo: null,
      genres: { items: [] },
      artists: { items: [] },
    },
    ...overrides,
  };
}

Deno.test("a guest set is filed under the guest, not the bucket", () => {
  const episode = readEpisode(item())!;
  assertEquals(episode.externalID, "special-guests/2026-09-14-1700");
  assertEquals(episode.url, "https://www.thelotradio.com/shows/special-guests/2026-09-14-1700");
  assertEquals(episode.show.externalID, "guests/yushh");
  assertEquals(episode.show.title, "Yushh");
  assertEquals(episode.show.hosts.map((host) => host.name), ["Yushh"]);
  assertEquals(episode.show.url, "https://www.thelotradio.com/artists/yushh");
  assertEquals(episode.show.imageURL, "https://images.ctfassets.net/yushh.jpg");
});

Deno.test("a b2b is one programme presented by both", () => {
  const episode = readEpisode(item({
    artists: { items: [{ name: "Gavsborg", slug: "gavsborg" }, { name: "Akanbi", slug: "akanbi" }] },
  }))!;
  assertEquals(episode.show.externalID, "guests/gavsborg+akanbi");
  assertEquals(episode.show.title, "Gavsborg & Akanbi");
});

Deno.test("a guest the site names no artist for is filed under the broadcast's title", () => {
  const episode = readEpisode(item({ title: "Mike Midnight ", artists: { items: [] } }))!;
  assertEquals(episode.show.externalID, "guests/mike-midnight");
  assertEquals(episode.show.title, "Mike Midnight");
  assertEquals(episode.show.hosts, []);
});

Deno.test("a residency keeps its own programme and residents", () => {
  const episode = readEpisode(item({
    slug: "2026-08-24-2200",
    title: "#Superimpositions with Cyrus",
    artists: { items: [{ name: "Cyrus", slug: "cyrus" }] },
    show: {
      name: "#Superimpositions",
      slug: "superimpositions",
      photo: { url: "https://images.ctfassets.net/show.jpg" },
      genres: { items: [{ name: "Prog" }] },
      artists: { items: [{ name: "Cyrus", slug: "cyrus" }] },
    },
  }))!;
  assertEquals(episode.externalID, "superimpositions/2026-08-24-2200");
  assertEquals(episode.show.externalID, "superimpositions");
  assertEquals(episode.show.title, "#Superimpositions");
  assertEquals(episode.show.url, "https://www.thelotradio.com/shows/superimpositions");
  assertEquals(episode.show.imageURL, "https://images.ctfassets.net/show.jpg");
  assertEquals(episode.presenters.map((person) => person.name), ["Cyrus"]);
});

Deno.test("a broadcast carries what it was and where it went out from", () => {
  const episode = readEpisode(item())!;
  assertEquals(episode.title, "Yushh");
  assertEquals(episode.airedAt, "2026-09-14T21:02:12.000Z");
  assertEquals(episode.durationSeconds, 7013);
  assertEquals(episode.genres, ["Techno", "Drum & Bass"]);
  assertEquals(episode.location, "New York");
  assertEquals(episode.imageURL, "https://images.ctfassets.net/episode.jpg");
});

Deno.test("an episode with no genres of its own takes its show's", () => {
  const episode = readEpisode(item({
    genres: { items: [] },
    show: { name: "Magic City", slug: "magic-city", genres: { items: [{ name: "Jazz" }] }, artists: { items: [] } },
  }))!;
  assertEquals(episode.genres, ["Jazz"]);
});

Deno.test("track timestamps become offsets from when the broadcast started", () => {
  const episode = readEpisode(item())!;
  assertEquals(episode.lines, [
    { artist: "Heling", title: "The Ones Beyond the Clouds (云那边的)", offsetSeconds: 94 },
    { artist: "I.T.Z & Traction Control", title: "Eternal Eye", offsetSeconds: 1724 },
  ]);
});

Deno.test("an item without a show or slug is not a broadcast", () => {
  assertEquals(readEpisode(item({ show: null })), null);
  assertEquals(readEpisode(item({ slug: "../../etc" })), null);
});

Deno.test("text decoded as Windows-1252 is put back", () => {
  assertEquals(repairMojibake("Peter BrÃ¶tzmann / Joe McPhee"), "Peter Brötzmann / Joe McPhee");
  assertEquals(repairMojibake("Joe McPhee, MikoÅ‚aj Trzaska, Jay Rosen"), "Joe McPhee, Mikołaj Trzaska, Jay Rosen");
  assertEquals(repairMojibake("AndrÃ© Jaume"), "André Jaume");
  assertEquals(repairMojibake("Joe McPhee With Michael Bisio â€¢ Dominic Duval"), "Joe McPhee With Michael Bisio • Dominic Duval");
});

Deno.test("real accents and scripts are left alone", () => {
  for (const name of ["Château Flight", "Björk", "云那边的", "Âme", "Sébastien Tellier", "Ã"]) {
    assertEquals(repairMojibake(name), name);
  }
});

Deno.test("repaired names reach the tracklist", () => {
  const episode = readEpisode(item({
    tracklist: [{ title: "Guts", artist: "McPhee, BrÃ¶tzmann", timestamp: "2026-09-14T21:05:00.000Z" }],
  }))!;
  assertEquals(episode.lines[0].artist, "McPhee, Brötzmann");
});

Deno.test("places are spelled the way NTS spells them", () => {
  assertEquals(placeName("The Lot Radio, NYC"), "New York");
  assertEquals(placeName("The Lot Radio"), null);
  assertEquals(placeName("Dekmantel, Amsterdam"), "Amsterdam");
  assertEquals(placeName(null), null);
});

Deno.test("the index's first page is read out of its flight stream", () => {
  const page = {
    items: [item()],
    total: 3558,
    pages: { next: "sig.W3sibGltaXQiOjMyfV0", prev: null },
  };
  const stream = `3b:["$","$L3c",null,{"children":["$","$L3d",null,{"initialData":${
    JSON.stringify(page)
  },"pageSize":16,"order":"date:desc"}]}]\n`;
  const html = `<script>self.__next_f.push([1,${JSON.stringify(stream.slice(0, 40))}])</script>` +
    `<script>self.__next_f.push([1,${JSON.stringify(stream.slice(40))}])</script>`;

  for (const body of [stream, html]) {
    const parsed = parseIndexPage(flightPayload(body))!;
    assertEquals(parsed.items.length, 1);
    assertEquals(parsed.total, 3558);
    assertEquals(parsed.next, "sig.W3sibGltaXQiOjMyfV0");
  }
});

Deno.test("a later page is read out of the action's reply", () => {
  const reply = `0:{"a":"$@1","f":"","q":"","i":false}\n1:${
    JSON.stringify({ items: [item(), item()], total: 3558, pages: { next: null, prev: "x" } })
  }\n`;
  const page = parseActionReply(reply)!;
  assertEquals(page.items.length, 2);
  assertEquals(page.next, null);
  assertEquals(parseActionReply("0:{\"a\":\"$@1\"}\n"), null);
  assertEquals(parseActionReply("<!DOCTYPE html><html>Not found</html>"), null);
});

Deno.test("the action id is found where the site declares it", () => {
  const script =
    `33488,e=>{"use strict";var t=e.i(360541);let s=(0,t.createServerReference)("404c777e51da10a130ababf450109e62056d9dae07",t.callServer,void 0,t.findSourceMapURL,"getEpisodes");e.s(["getEpisodes",0,s])}`;
  assertEquals(findActionID(script), "404c777e51da10a130ababf450109e62056d9dae07");
  assertEquals(
    findActionID(`(0,t.createServerReference)("7f00aa11bb22cc33dd44ee55ff6677889900aabbcc",t.callServer,void 0,t.findSourceMapURL,"getShows")`),
    null,
  );
  assertEquals(
    scriptPaths(`3f:I[501675,["/_next/static/immutable/chunks/3vq875e1bfioq.js","/_next/static/immutable/chunks/3vq875e1bfioq.js"],"Tracklist"]`),
    ["/_next/static/immutable/chunks/3vq875e1bfioq.js"],
  );
});
