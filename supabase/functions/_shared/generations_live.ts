// The publisher's dependencies, as the backend has them: the cut through the
// service role, R2 through the signed API with conditional writes, and the
// write budget (reserveR2).

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { getObjectTagged, putObjectConditional, r2Config } from "./r2.ts";
import { reserveR2 } from "./release_cache.ts";
import type { Cut, Demand, PublishDeps } from "./generations.ts";

export function liveGenerationDeps(supabase: SupabaseClient, demand: Demand): PublishDeps {
  const r2 = r2Config();
  if (!r2) throw new Error("generations: R2 is not configured");
  return {
    async cut(day) {
      const started = performance.now();
      const { data, error } = await supabase.rpc("knowledge_cut", { p_day: day, p_demand: demand });
      if (error) throw new Error(`generations: knowledge_cut failed: ${error.message}`);
      return { cut: data as Cut, ms: Math.round(performance.now() - started) };
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
