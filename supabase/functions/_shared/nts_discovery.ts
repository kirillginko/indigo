// NTS discovery: which episodes to queue, read off the `recently-added` feed.
//
// NTS publishes its whole archive newest-first as `recently-added`, so one
// feed serves both jobs: `fresh` re-reads the top of it for what was broadcast
// today, and `backfill` walks steadily further back.
//
// Discovery only ever enqueues. Fetching the twelve episodes it finds here
// would turn one job into thirteen upstream requests in a single invocation,
// which is how a polite crawler becomes an impolite one.

import { NTS_API, USER_AGENT } from "./nts.ts";

const DISCOVERY_COLLECTION = "recently-added";
export const DISCOVERY_PAGE = 12;
export const CURSOR = `nts.${DISCOVERY_COLLECTION}`;

/// The slice of the Supabase client discovery uses, so a test can stand in.
export interface DiscoveryDeps {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message: string } | null }>;
  fetch(url: string, init: RequestInit): Promise<Response>;
}

export async function discoverNTS(deps: DiscoveryDeps, mode: string): Promise<void> {
  let offset = 0;

  if (mode === "backfill") {
    const { data, error } = await deps.rpc("advance_enrichment_cursor", {
      p_name: CURSOR,
      p_by: DISCOVERY_PAGE,
    });
    if (error) throw new Error(error.message);
    offset = Number(data ?? 0);
  }

  const url = `${NTS_API}collections/${DISCOVERY_COLLECTION}?offset=${offset}&limit=${DISCOVERY_PAGE}`;
  const response = await deps.fetch(url, {
    headers: { Accept: "application/json", "User-Agent": USER_AGENT },
  });

  // Since 2026-10-10 NTS refuses offsets past about 240 with a 422. A refused
  // offset is as far as this feed goes, so the backfill ends its walk exactly
  // as it does on an empty page; throwing instead would leave the cursor
  // advanced past the cap and fail every run after it (0086). At offset 0 a
  // 4xx is something actually wrong, and a 5xx is an outage either way: those
  // throw, so the queue backs off.
  if (mode === "backfill" && response.status >= 400 && response.status < 500) {
    await response.body?.cancel();
    console.warn(`discover: NTS refused offset ${offset} (${response.status}); starting the walk again`);
    await resetCursor(deps);
    return;
  }
  if (!response.ok) throw new Error(`upstream ${response.status} for ${url}`);

  const page = await response.json() as Record<string, unknown>;
  const results = Array.isArray(page.results) ? page.results as Record<string, unknown>[] : [];

  if (results.length === 0) {
    // Walked off the end. Start again: the archive has grown since we began,
    // and everything already ingested is deduped on the way back through.
    if (mode === "backfill") await resetCursor(deps);
    return;
  }

  for (const episode of results) {
    const show = typeof episode.show_alias === "string" ? episode.show_alias : null;
    const alias = typeof episode.episode_alias === "string" ? episode.episode_alias : null;
    if (!show || !alias) continue;

    const { error } = await deps.rpc("enqueue_enrichment_job", {
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

async function resetCursor(deps: DiscoveryDeps): Promise<void> {
  const { error } = await deps.rpc("reset_enrichment_cursor", { p_name: CURSOR });
  if (error) throw new Error(error.message);
}
