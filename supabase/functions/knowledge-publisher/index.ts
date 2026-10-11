// knowledge-publisher
//
// Publishes today's knowledge generation for the frozen pilot demand set
// (SHARED-KNOWLEDGE.md §9.6, §14) -- once, when asked. Nothing schedules it:
// no cron, no queue, no other caller. Asking again the same day verifies the
// published generation and finishes advertising it; it never publishes a day
// twice.
//
// Only the holder of KNOWLEDGE_PUBLISH_TOKEN may ask: a random token set as a
// function secret and kept in Vault (`indigo_publisher_token`), so the one
// manual trigger is a SQL statement run by the database owner and nobody
// handles a key. The worker's Vault key will not do: it is the app's
// publishable key, which every copy of the app holds.

import { createClient } from "jsr:@supabase/supabase-js@2";
import pilot from "../_shared/testdata/pilot_demand_v1.json" with { type: "json" };
import { type Demand, publishGeneration } from "../_shared/generations.ts";
import { liveGenerationDeps } from "../_shared/generations_live.ts";

/// Equal, without stopping at the first difference.
function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const token = Deno.env.get("KNOWLEDGE_PUBLISH_TOKEN") ?? "";
  const presented = req.headers.get("x-publish-token") ?? "";
  if (token.length < 32 || !sameText(presented, token)) return json({ error: "forbidden" }, 403);

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
