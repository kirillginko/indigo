// knowledge-publisher
//
// Publishes today's knowledge generation for the frozen pilot demand set
// (SHARED-KNOWLEDGE.md §9.6, §14) -- once, when asked. Nothing schedules it:
// no cron, no queue, no other caller. Asking again the same day verifies the
// published generation and finishes advertising it; it never publishes a day
// twice.
//
// Only the service role may ask: the gateway checks the key is the project's,
// and the function checks it is the service role's by calling a function only
// the service role can (r2_budget). The publishable key reaches the gateway
// and stops here.

import { createClient } from "jsr:@supabase/supabase-js@2";
import pilot from "../_shared/testdata/pilot_demand_v1.json" with { type: "json" };
import { type Demand, publishGeneration } from "../_shared/generations.ts";
import { liveGenerationDeps } from "../_shared/generations_live.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const caller = createClient(url, key, { auth: { persistSession: false } });
  const { error: denied } = await caller.rpc("r2_budget");
  if (denied) return json({ error: "forbidden" }, 403);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // An empty body asks for nothing.
  }
  if (body.publish !== "pilot-v1") return json({ error: "say what to publish: {\"publish\": \"pilot-v1\"}" }, 400);

  const supabase = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const started = performance.now();
  try {
    const report = await publishGeneration(liveGenerationDeps(supabase, pilot as unknown as Demand), pilot as unknown as Demand);
    const result = { ...report, ms: Math.round(performance.now() - started) };
    console.log("knowledge_publish", JSON.stringify({ status: result.status, date: result.date, manifest: result.manifest, ms: result.ms }));
    return json(result, report.status === "published" || report.status === "resumed" || report.status === "already-published" ? 200 : 409);
  } catch (cause) {
    const detail = String(cause).slice(0, 500);
    console.error("knowledge_publish_failed", detail);
    return json({ status: "failed", error: detail, ms: Math.round(performance.now() - started) }, 500);
  }
});
