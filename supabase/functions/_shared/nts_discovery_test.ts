// What NTS discovery does with each answer the feed can give.
//
// The case that matters is the 422: since 2026-10-10 NTS refuses offsets past
// about 240, and a backfill that threw on it left its cursor stranded past the
// cap and failed every five minutes for a week (0086).
//
//     deno test supabase/functions/_shared/nts_discovery_test.ts

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { CURSOR, discoverNTS, DISCOVERY_PAGE, type DiscoveryDeps } from "./nts_discovery.ts";

type Call = { fn: string; args: Record<string, unknown> };

function fake(response: () => Response, cursor = 43_668) {
  const calls: Call[] = [];
  const urls: string[] = [];
  const deps: DiscoveryDeps = {
    rpc(fn, args) {
      calls.push({ fn, args });
      return Promise.resolve({ data: fn === "advance_enrichment_cursor" ? cursor : null, error: null });
    },
    fetch(url) {
      urls.push(url);
      return Promise.resolve(response());
    },
  };
  return { deps, calls, urls };
}

const page = (n: number) =>
  Response.json({
    results: Array.from({ length: n }, (_, i) => ({ show_alias: "show", episode_alias: `ep-${i}` })),
  });

Deno.test("a refused offset ends the backfill walk instead of failing it", async () => {
  const { deps, calls, urls } = fake(() =>
    Response.json({ detail: "The requested offset is not allowed" }, { status: 422 })
  );
  await discoverNTS(deps, "backfill");

  assertEquals(urls.length, 1);
  assertEquals(new URL(urls[0]).searchParams.get("offset"), "43668");
  assertEquals(calls.map((c) => c.fn), ["advance_enrichment_cursor", "reset_enrichment_cursor"]);
  assertEquals(calls[1].args, { p_name: CURSOR });
});

Deno.test("an outage still throws, so the queue backs off", async () => {
  const { deps, calls } = fake(() => new Response("bad gateway", { status: 502 }));
  await assertRejects(() => discoverNTS(deps, "backfill"), Error, "upstream 502");
  assertEquals(calls.map((c) => c.fn), ["advance_enrichment_cursor"]);
});

Deno.test("a 4xx on the fresh pass is a real failure", async () => {
  const { deps, calls } = fake(() => new Response("nope", { status: 422 }));
  await assertRejects(() => discoverNTS(deps, "fresh"), Error, "upstream 422");
  assertEquals(calls, []);
});

Deno.test("an empty page starts the backfill walk again", async () => {
  const { deps, calls } = fake(() => page(0));
  await discoverNTS(deps, "backfill");
  assertEquals(calls.map((c) => c.fn), ["advance_enrichment_cursor", "reset_enrichment_cursor"]);
});

Deno.test("a full page queues every episode, fresh ones first", async () => {
  for (const [mode, priority] of [["fresh", 5], ["backfill", 0]] as const) {
    const { deps, calls, urls } = fake(() => page(DISCOVERY_PAGE));
    await discoverNTS(deps, mode);

    const enqueued = calls.filter((c) => c.fn === "enqueue_enrichment_job");
    assertEquals(enqueued.length, DISCOVERY_PAGE);
    assertEquals(enqueued[0].args.p_dedupe_key, "show/ep-0");
    assertEquals(enqueued[0].args.p_priority, priority);
    assertEquals(calls.some((c) => c.fn === "reset_enrichment_cursor"), false);
    assertEquals(new URL(urls[0]).searchParams.get("offset"), mode === "fresh" ? "0" : "43668");
  }
});
