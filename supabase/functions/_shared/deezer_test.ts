// What Deezer is trusted for, and what it is not.
//
// The whole value of this path is that it is exact: a Deezer track id came off
// the tracklist, so the album behind it is *that* record rather than a record
// with the same title. Everything here is about not throwing that away —
// spacing the requests, reading a miss as a miss, and never letting a
// placeholder year or a missing album turn into a row that looks resolved.
//
//     deno test supabase/functions/_shared/deezer_test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import { DEEZER_SPACING_MS, fetchTrackRelease, pacedFetch } from "./deezer.ts";

/// Stands in for Deezer. Returns the body queued for each path, so a test says
/// what the service said rather than what it wishes it had said.
function stub(routes: Record<string, unknown>, seen?: string[]): () => void {
  const realFetch = globalThis.fetch;
  globalThis.fetch = ((input: unknown) => {
    const url = String(input);
    seen?.push(url);
    const key = Object.keys(routes).find((path) => url.includes(path));
    if (key === undefined) return Promise.resolve(new Response("{}", { status: 404 }));
    const body = routes[key];
    if (typeof body === "number") return Promise.resolve(new Response("{}", { status: body }));
    return Promise.resolve(new Response(JSON.stringify(body), { status: 200 }));
  }) as typeof fetch;
  return () => { globalThis.fetch = realFetch; };
}

Deno.test("requests to Deezer are spaced", async () => {
  const sent: number[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (() => {
    sent.push(Date.now());
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as typeof fetch;
  try {
    await pacedFetch("https://api.deezer.com/track/1");
    await pacedFetch("https://api.deezer.com/track/2");
    await pacedFetch("https://api.deezer.com/track/3");
  } finally {
    globalThis.fetch = realFetch;
  }

  assertEquals(sent.length, 3);
  for (let i = 1; i < sent.length; i++) {
    const gap = sent[i] - sent[i - 1];
    assert(gap >= DEEZER_SPACING_MS - 5, `requests ${i} and ${i + 1} were ${gap}ms apart`);
  }
});

Deno.test("a track resolves to the imprint that put the album out", async () => {
  const restore = stub({
    "track/111": { title: "Flyby VFR", isrc: "DEAB12345678", album: { id: 42, title: "Compro" } },
    "album/42": { title: "Compro", label: "Ilian Tape", release_date: "2018-04-27" },
  });
  try {
    const found = await fetchTrackRelease("111");
    assertEquals(found?.trackTitle, "Flyby VFR");
    assertEquals(found?.albumTitle, "Compro");
    assertEquals(found?.albumID, "42");
    assertEquals(found?.label, "Ilian Tape");
    assertEquals(found?.releaseYear, 2018);
    assertEquals(found?.isrc, "DEAB12345678");
  } finally {
    restore();
  }
});

Deno.test("a track Deezer has never heard of is an answer, not an error", async () => {
  // Deezer reports a miss as 200 with an error object rather than a status, so
  // a response that parsed is not yet an answer.
  const restore = stub({ "track/404": { error: { type: "DataException", code: 800 } } });
  try {
    assertEquals(await fetchTrackRelease("404"), null);
  } finally {
    restore();
  }
});

Deno.test("a quota refusal throws, so the queue backs off instead of writing a miss", async () => {
  // The difference that matters: a miss is written down and never asked again,
  // a refusal has to come back. Recording a throttled request as "no album"
  // would lose the record permanently.
  const restore = stub({ "track/1": { error: { type: "Exception", code: 4 } } });
  try {
    let threw = false;
    try { await fetchTrackRelease("1"); } catch { threw = true; }
    assert(threw, "a quota refusal should not be reported as a resolved track");
  } finally {
    restore();
  }
});

Deno.test("an album that will not load still leaves the track it named", async () => {
  const restore = stub({
    "track/111": { title: "Flyby VFR", album: { id: 42, title: "Compro" }, release_date: "2018-04-27" },
    "album/42": 404,
  });
  try {
    const found = await fetchTrackRelease("111");
    assertEquals(found?.albumTitle, "Compro");
    assertEquals(found?.albumID, "42");
    // No label, and the caller writes that down as "asked, nothing found".
    assertEquals(found?.label, null);
  } finally {
    restore();
  }
});

Deno.test("Deezer's placeholder date does not become a year", async () => {
  // Deezer files a release it has no date for as 0000-00-00, and a record
  // shown as released in year 0 is worse than one shown with no year at all.
  const restore = stub({
    "track/111": { title: "Untitled", album: { id: 42 }, release_date: "0000-00-00" },
    "album/42": { title: "White Label", label: "Unknown", release_date: "0000-00-00" },
  });
  try {
    const found = await fetchTrackRelease("111");
    assertEquals(found?.releaseYear, null);
  } finally {
    restore();
  }
});

Deno.test("a track with no album is asked about once, not twice", async () => {
  const seen: string[] = [];
  const restore = stub({ "track/111": { title: "Dubplate" } }, seen);
  try {
    const found = await fetchTrackRelease("111");
    assertEquals(found?.albumID, null);
    assertEquals(found?.trackTitle, "Dubplate");
    assertEquals(seen.length, 1, "a track naming no album should not cost an album request");
  } finally {
    restore();
  }
});
