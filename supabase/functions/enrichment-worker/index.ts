// enrichment-worker
//
// Drains the enrichment queue (§19). The queue exists so that filling in what
// Indigo knows is not something a screen has to wait for: opening one NTS
// episode enqueues the rest of the residency, and the tracklists arrive over
// the following minutes instead of one at a time as somebody happens to click.
//
// Safe to call repeatedly and from more than one caller at once — claiming is
// `for update skip locked`, so two workers never take the same job. It can only
// ever perform work the backend itself enqueued: `enqueue_enrichment_job` is
// revoked from anon, so this is a drain, not an instruction to fetch anything a
// caller names.

import { createClient } from "jsr:@supabase/supabase-js@2";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { ingestNTSEpisode, ingestNTSShow, NTS_API, USER_AGENT } from "../_shared/nts.ts";

interface Job {
  id: string;
  provider: string;
  job_type: string;
  dedupe_key: string | null;
  payload: Record<string, unknown> | null;
}

const MAX_BATCH = 25;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // A bare ping is a legitimate way to ask for a drain.
  }

  const requested = Number(body.limit ?? 5);
  const limit = Number.isFinite(requested)
    ? Math.min(Math.max(Math.trunc(requested), 1), MAX_BATCH)
    : 5;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: claimed, error } = await supabase.rpc("claim_enrichment_jobs", {
    p_limit: limit,
  });
  if (error) return json({ error: "claim_failed", detail: error.message }, 500);

  const jobs = (claimed ?? []) as Job[];
  const results: Array<{ job: string; type: string; ok: boolean; detail?: string }> = [];

  // One at a time. These are all upstream fetches against one station, and a
  // burst of them in parallel is how a polite client becomes an impolite one.
  for (const job of jobs) {
    let ok = false;
    let detail: string | undefined;
    try {
      await run(supabase, job);
      ok = true;
    } catch (cause) {
      detail = String(cause).slice(0, 300);
      console.error("job_failed", job.job_type, job.dedupe_key, detail);
    }
    await supabase.rpc("complete_enrichment_job", {
      p_job_id: job.id,
      p_succeeded: ok,
      p_error: detail ?? null,
    });
    results.push({ job: job.id, type: job.job_type, ok, detail });
  }

  return json({ claimed: jobs.length, results });
});

async function run(supabase: SupabaseClient, job: Job): Promise<void> {
  switch (job.job_type) {
    case "fetch_nts_episode": {
      const show = String(job.payload?.show ?? "");
      const episode = String(job.payload?.episode ?? "");
      if (!show || !episode) throw new Error("missing show/episode");
      const payload = await fetchJSON(`${NTS_API}shows/${show}/episodes/${episode}`);
      await ingestNTSEpisode(supabase, show, episode, payload);
      return;
    }

    case "fetch_nts_show": {
      const alias = String(job.payload?.alias ?? "");
      if (!alias) throw new Error("missing alias");
      const payload = await fetchJSON(`${NTS_API}shows/${alias}`);
      await ingestNTSShow(supabase, alias, payload);
      return;
    }

    case "discover_nts": {
      await discoverNTS(supabase, String(job.payload?.mode ?? "fresh"));
      return;
    }

    case "resolve_radio_appearances": {
      // No episode id: the whole backlog. A name that matched nothing in March
      // matches in June, and this is what goes back for it.
      const { error } = await supabase.rpc("resolve_radio_appearances", {
        p_episode_id: null,
      });
      if (error) throw new Error(error.message);
      return;
    }

    case "rebuild_dig_edges": {
      const { error } = await supabase.rpc("rebuild_radio_dig_edges");
      if (error) throw new Error(error.message);
      return;
    }

    default:
      throw new Error(`unknown job type ${job.job_type}`);
  }
}

/// NTS publishes its whole archive newest-first as `recently-added`, so one
/// feed serves both jobs: `fresh` re-reads the top of it for what was broadcast
/// today, and `backfill` walks steadily further back.
///
/// Discovery only ever enqueues. Fetching the twelve episodes it finds here
/// would turn one job into thirteen upstream requests in a single invocation,
/// which is how a polite crawler becomes an impolite one.
const DISCOVERY_COLLECTION = "recently-added";
const DISCOVERY_PAGE = 12;
const CURSOR = `nts.${DISCOVERY_COLLECTION}`;

async function discoverNTS(supabase: SupabaseClient, mode: string): Promise<void> {
  let offset = 0;

  if (mode === "backfill") {
    const { data, error } = await supabase.rpc("advance_enrichment_cursor", {
      p_name: CURSOR,
      p_by: DISCOVERY_PAGE,
    });
    if (error) throw new Error(error.message);
    offset = Number(data ?? 0);
  }

  const page = await fetchJSON(
    `${NTS_API}collections/${DISCOVERY_COLLECTION}?offset=${offset}&limit=${DISCOVERY_PAGE}`,
  );
  const results = Array.isArray(page.results) ? page.results as Record<string, unknown>[] : [];

  if (results.length === 0) {
    // Walked off the end. Start again: the archive has grown since we began,
    // and everything already ingested is deduped on the way back through.
    if (mode === "backfill") {
      await supabase.rpc("reset_enrichment_cursor", { p_name: CURSOR });
    }
    return;
  }

  for (const episode of results) {
    const show = typeof episode.show_alias === "string" ? episode.show_alias : null;
    const alias = typeof episode.episode_alias === "string" ? episode.episode_alias : null;
    if (!show || !alias) continue;

    const { error } = await supabase.rpc("enqueue_enrichment_job", {
      p_provider: "nts",
      p_job_type: "fetch_nts_episode",
      p_dedupe_key: `${show}/${alias}`,
      p_payload: { show, episode: alias },
      // What was broadcast today is worth having before what was broadcast in
      // 2019, so the fresh pass jumps the queue.
      p_priority: mode === "fresh" ? 5 : 0,
      p_entity_type: null,
      p_entity_id: null,
    });
    if (error) console.error("discover: enqueue failed", error.message);
  }
}

async function fetchJSON(url: string): Promise<Record<string, unknown>> {
  const response = await fetch(url, {
    headers: { Accept: "application/json", "User-Agent": USER_AGENT },
  });
  if (!response.ok) throw new Error(`upstream ${response.status} for ${url}`);
  return await response.json();
}
