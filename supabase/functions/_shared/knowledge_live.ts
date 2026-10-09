// The knowledge jobs' dependencies, as the worker has them: Discogs through
// the same paced fetch every cache request uses (one a second), R2 through the
// signed API and the write budget (reserveR2), and the queue.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { DISCOGS_API, pacedCacheFetch } from "./discogs.ts";
import { getObject, putObject, r2Config } from "./r2.ts";
import { reserveR2 } from "./release_cache.ts";
import type { KnowledgeDeps } from "./knowledge.ts";

const CHUNK = 200;

function chunks<T>(items: T[]): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += CHUNK) out.push(items.slice(i, i + CHUNK));
  return out;
}

export function liveKnowledgeDeps(supabase: SupabaseClient, token: string | undefined): KnowledgeDeps {
  const r2 = r2Config();
  if (!r2) throw new Error("knowledge: R2 is not configured");
  return {
    async fetchPage(discogsID, page, perPage) {
      const response = await pacedCacheFetch(
        `${DISCOGS_API}artists/${discogsID}/releases?sort=year&sort_order=desc&per_page=${perPage}&page=${page}`,
        token,
      );
      if (!response.ok) {
        await response.body?.cancel();
        return { status: response.status };
      }
      return { status: response.status, body: await response.json() };
    },
    getObject: (key) => getObject(r2, key),
    putObject: (key, body) => putObject(r2, key, body),
    reserve: (writes, bytes) => reserveR2(supabase, writes, bytes),
    async cachedReleases(ids) {
      const found = new Set<number>();
      for (const part of chunks(ids)) {
        const { data, error } = await supabase
          .from("releases")
          .select("discogs_id")
          .in("discogs_id", part.map(String))
          .not("discogs_cached_at", "is", null);
        if (error) throw new Error(`knowledge: releases lookup failed: ${error.message}`);
        for (const row of data ?? []) found.add(Number(row.discogs_id));
      }
      return found;
    },
    async pendingReleases(ids) {
      const found = new Set<number>();
      for (const part of chunks(ids)) {
        const { data, error } = await supabase
          .from("enrichment_jobs")
          .select("dedupe_key")
          .eq("job_type", "cache_discogs_release")
          .in("status", ["pending", "running"])
          .in("dedupe_key", part.map(String));
        if (error) throw new Error(`knowledge: queue lookup failed: ${error.message}`);
        for (const row of data ?? []) found.add(Number(row.dedupe_key));
      }
      return found;
    },
    async ownCachedReleases(discogsID) {
      const { data: ids, error } = await supabase
        .from("external_ids")
        .select("entity_id")
        .eq("provider", "discogs").eq("entity_type", "artist").eq("external_id", String(discogsID));
      if (error) throw new Error(`knowledge: identity lookup failed: ${error.message}`);
      const artists = (ids ?? []).map((row) => row.entity_id as string);
      if (artists.length === 0) return [];
      const { data, error: releaseError } = await supabase
        .from("releases")
        .select("discogs_id")
        .in("artist_id", artists)
        .not("discogs_id", "is", null)
        .not("discogs_cached_at", "is", null)
        .limit(1000);
      if (releaseError) throw new Error(`knowledge: own releases lookup failed: ${releaseError.message}`);
      return (data ?? []).map((row) => Number(row.discogs_id)).filter(Number.isInteger);
    },
    async enqueue(jobType, dedupeKey, payload, priority) {
      const { error } = await supabase.rpc("enqueue_enrichment_job", {
        p_provider: "discogs", p_job_type: jobType, p_dedupe_key: dedupeKey, p_payload: payload,
        p_priority: priority, p_entity_type: null, p_entity_id: null,
      });
      if (error) throw new Error(`knowledge: enqueue ${jobType} failed: ${error.message}`);
    },
    now: () => new Date(),
  };
}
