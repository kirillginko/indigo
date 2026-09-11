// MusicBrainz asks for one request a second. The worker runs a drain's jobs
// back to back, so the gap has to come from the fetch itself.
//
//     deno test supabase/functions/_shared/musicbrainz_test.ts

import { assert } from "jsr:@std/assert@1";
import { MB_SPACING_MS, pacedFetch } from "./musicbrainz.ts";

Deno.test("requests to MusicBrainz leave at least a second between them", async () => {
  const sent: number[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = ((_input: unknown, _init?: unknown) => {
    sent.push(Date.now());
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as typeof fetch;
  try {
    const url = new URL("https://musicbrainz.org/ws/2/artist");
    await pacedFetch(url, {});
    await pacedFetch(url, {});
    await pacedFetch(url, {});
  } finally {
    globalThis.fetch = realFetch;
  }

  assert(sent.length === 3, `expected three requests, saw ${sent.length}`);
  for (let i = 1; i < sent.length; i++) {
    const gap = sent[i] - sent[i - 1];
    assert(gap >= MB_SPACING_MS - 5, `requests ${i} and ${i + 1} were ${gap}ms apart`);
  }
});
