// What a Discogs search hit is allowed to become.
//
// `searchTarget` decides which results reach `artists` and `labels` and under
// what name, and every mistake it could make is silent: a row filed under
// "Nirvana (2)" matches a search perfectly well and then opens onto a page
// nothing is stored behind. A master id filed as a release id is worse, because
// a later lookup follows it to the wrong record entirely.
//
//     deno test supabase/functions/_shared/discogs_test.ts
//
// Or Scripts/test-functions.sh, which runs everything under supabase/functions.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { DISCOGS_SPACING_MS, fetchArtistPortrait, searchTarget } from "./discogs.ts";

Deno.test("an artist hit becomes a complete artist row", () => {
  const target = searchTarget({ id: 2477159, type: "artist", title: "Purelink", country: "US" });

  assertEquals(target?.table, "artists");
  assertEquals(target?.entityType, "artist");
  assertEquals(target?.externalID, "2477159");
  assertEquals(target?.name, "Purelink");
  assertEquals(target?.country, "US");
});

Deno.test("a label hit becomes a complete label row", () => {
  const target = searchTarget({ id: 54782, type: "label", title: "Ilian Tape", country: "Germany" });

  assertEquals(target?.table, "labels");
  assertEquals(target?.entityType, "label");
  assertEquals(target?.name, "Ilian Tape");
});

Deno.test("Discogs' filing marks are not part of the name", () => {
  // The number separates two bands who share a name; the asterisk says a record
  // credited them under a variant spelling. Filed as written, neither matches
  // anything else in Indigo.
  assertEquals(searchTarget({ id: 1, type: "artist", title: "Nirvana (2)" })?.name, "Nirvana");
  assertEquals(searchTarget({ id: 2, type: "artist", title: "Flowdan*" })?.name, "Flowdan");
  assertEquals(
    searchTarget({ id: 3, type: "artist", title: "Sima Kim* & Saito Koji" })?.name,
    "Sima Kim & Saito Koji",
  );
});

Deno.test("a release hit is not filed", () => {
  // `releases` wants an artist and a label, and a search hit names neither by
  // id — it carries "Artist - Title" as one string. A row built from that is a
  // credit-less stub, and `resolveEntity` would never update it once the full
  // payload came past.
  assertEquals(
    searchTarget({
      id: 12227218,
      type: "release",
      title: "Skee Mask - Compro",
      label: ["Ilian Tape"],
      year: "2018",
    }),
    null,
  );
});

Deno.test("a master hit is not filed", () => {
  // Its `id` is a master id. Written as a release external id, a later
  // `releases/{id}` lookup follows it to the wrong record or to nothing.
  assertEquals(searchTarget({ id: 999, type: "master", title: "Skee Mask - Compro" }), null);
});

Deno.test("filing conventions are not entities", () => {
  // "Not On Label" is exactly as much of a label as "Various" is an artist,
  // and both arrive as ordinary hits.
  assertEquals(searchTarget({ id: 4, type: "label", title: "Not On Label" }), null);
  assertEquals(searchTarget({ id: 5, type: "artist", title: "Various" }), null);
  assertEquals(searchTarget({ id: 6, type: "artist", title: "Unknown Artist" }), null);
});

Deno.test("a hit missing what a row needs is skipped", () => {
  assertEquals(searchTarget({ type: "artist", title: "Purelink" }), null, "no id");
  assertEquals(searchTarget({ id: 7, type: "artist", title: "" }), null, "no name");
  assertEquals(searchTarget({ id: 8, type: "artist", title: "(2)" }), null, "nothing but a mark");
  assertEquals(searchTarget({ id: 9, title: "Purelink" }), null, "no type");
  assertEquals(searchTarget(null as unknown as Record<string, unknown>), null, "no hit");
});

Deno.test("a country is absent rather than empty", () => {
  // Written as "" it would read as a country nobody is from.
  assertEquals(searchTarget({ id: 10, type: "artist", title: "Purelink", country: "" })?.country, null);
  assertEquals(searchTarget({ id: 11, type: "artist", title: "Purelink" })?.country, null);
});

Deno.test("portrait searches leave a second between them", async () => {
  // The portrait lane runs thirty back to back on a credential listeners share.
  const sent: number[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = ((_input: unknown, _init?: unknown) => {
    sent.push(Date.now());
    return Promise.resolve(new Response(JSON.stringify({ results: [] }), { status: 200 }));
  }) as typeof fetch;
  try {
    await fetchArtistPortrait("Purelink", undefined, "IndigoTest/1");
    await fetchArtistPortrait("Skee Mask", undefined, "IndigoTest/1");
    await fetchArtistPortrait("Bandulu", undefined, "IndigoTest/1");
  } finally {
    globalThis.fetch = realFetch;
  }

  assert(sent.length === 3, `expected three requests, saw ${sent.length}`);
  for (let i = 1; i < sent.length; i++) {
    const gap = sent[i] - sent[i - 1];
    assert(gap >= DISCOGS_SPACING_MS - 5, `requests ${i} and ${i + 1} were ${gap}ms apart`);
  }
});
