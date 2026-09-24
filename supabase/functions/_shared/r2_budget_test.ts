// The R2 budget guard (0053): the thing standing between the cache and a
// bill. Nothing may reach R2 without a reservation, and a budget that cannot
// be read must stop writes rather than wave them through.
//
//     deno test supabase/functions/_shared/r2_budget_test.ts

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { R2BudgetExceeded, reserveR2 } from "./release_cache.ts";

function budget(answer: { data?: unknown; error?: { message: string } | null }) {
  const calls: Array<Record<string, unknown>> = [];
  const client = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, ...args });
      return Promise.resolve({ data: answer.data ?? null, error: answer.error ?? null });
    },
  } as unknown as SupabaseClient;
  return { client, calls };
}

Deno.test("a reservation within the budget goes ahead, and says what it takes", async () => {
  const { client, calls } = budget({ data: true });
  await reserveR2(client, 300, 3_000_000);
  assertEquals(calls, [{ name: "r2_reserve", p_writes: 300, p_bytes: 3_000_000 }]);
});

Deno.test("a refusal stops the write", async () => {
  const { client } = budget({ data: false });
  await assertRejects(() => reserveR2(client, 1, 12_000), R2BudgetExceeded);
});

Deno.test("a budget that cannot be read stops the write too", async () => {
  const { client } = budget({ error: { message: "connection reset" } });
  await assertRejects(() => reserveR2(client, 1, 12_000), Error, "r2 budget unavailable");
});

Deno.test("nothing to write asks nothing", async () => {
  const { client, calls } = budget({ data: false });
  await reserveR2(client, 0, 0);
  assertEquals(calls.length, 0);
});
