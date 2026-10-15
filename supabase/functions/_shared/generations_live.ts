// The publisher's dependencies, as the backend has them: the cut over a
// direct database connection, R2 through the signed API with conditional
// writes, and the write budget (reserveR2).
//
// Not the cut through PostgREST: every request there inherits the API
// connection's 8 s statement timeout, whatever role it runs as, and a cold
// cut takes longer (the first live publication failed there, 2026-10-11).
// Over its own connection the cut runs in one REPEATABLE READ READ ONLY
// transaction with a timeout of its own -- read-only by the transaction, not
// only by the function's volatility.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import postgres from "npm:postgres@3.4.5";
import { getObjectTagged, putObjectConditional, r2Config } from "./r2.ts";
import { reserveR2 } from "./release_cache.ts";
import type { Cut, Demand, PublishDeps } from "./generations.ts";

export function liveGenerationDeps(supabase: SupabaseClient, demand: Demand): PublishDeps {
  const r2 = r2Config();
  if (!r2) throw new Error("generations: R2 is not configured");
  return {
    async cut(day) {
      const dbURL = Deno.env.get("SUPABASE_DB_URL");
      if (!dbURL) throw new Error("generations: SUPABASE_DB_URL is not set");
      const sql = postgres(dbURL, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 15 });
      try {
        const started = performance.now();
        const cut = await sql.begin("isolation level repeatable read read only", async (tx) => {
          await tx`set local statement_timeout = '120s'`;
          const [row] = await tx`select public.knowledge_cut(${day}::date, ${sql.json(demand as never)}) as cut`;
          return row.cut as Cut;
        });
        return { cut, ms: Math.round(performance.now() - started) };
      } finally {
        await sql.end({ timeout: 5 });
      }
    },
    now: () => new Date(),
    get: (key) => getObjectTagged(r2, key),
    async create(key, body, cacheControl) {
      return await putObjectConditional(r2, key, body, { ifNoneMatch: "*" }, cacheControl) === "written" ? "created" : "exists";
    },
    async replace(key, body, etag, cacheControl) {
      const condition = etag === null ? { ifNoneMatch: "*" as const } : { ifMatch: etag };
      return await putObjectConditional(r2, key, body, condition, cacheControl) === "written" ? "replaced" : "conflict";
    },
    reserve: (writes, bytes) => reserveR2(supabase, writes, bytes),
  };
}
