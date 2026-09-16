// Where a cached Discogs release lives: an object in Storage, pointed at by a
// row in `metadata_cache`. See 0036.
//
// One module for the three places that touch it — the worker's release job,
// `catalog-refresh`, and the one-off move of what was already stored — so the
// bucket, the key and the read fallback cannot drift between them.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

export const RELEASE_CACHE_BUCKET = "catalog-cache";

/// Always derived from the id, never from the payload, so a refetch overwrites
/// the same object and Storage never holds two copies of one release.
export function releasePayloadPath(releaseID: string): string {
  return `releases/${releaseID}.json`;
}

/// How long the CDN may serve a copy before asking again. A release is cached
/// for sixty days and rarely changes; an hour of staleness after a refetch is
/// invisible.
const CACHE_CONTROL_SECONDS = "3600";

/// Uploads a release and returns the key to record. Throws on failure, so a
/// caller never writes a row pointing at an object that is not there.
export async function storeReleasePayload(
  supabase: SupabaseClient,
  releaseID: string,
  payload: unknown,
): Promise<string> {
  const path = releasePayloadPath(releaseID);
  const { error } = await supabase.storage
    .from(RELEASE_CACHE_BUCKET)
    .upload(path, new Blob([JSON.stringify(payload)], { type: "application/json" }), {
      upsert: true,
      contentType: "application/json",
      cacheControl: CACHE_CONTROL_SECONDS,
    });
  if (error) throw new Error(`storage upload failed for ${path}: ${error.message}`);
  return path;
}

/// The payload a cache row stands for, wherever it is kept.
///
/// Inline first: searches, shelves and NTS never moved, and a release not yet
/// moved still carries its own. Null when the object cannot be read, which a
/// caller treats exactly as a miss and fetches again — the same outcome as a
/// row that was never there.
export async function readCachedPayload(
  supabase: SupabaseClient,
  row: { payload?: unknown; payload_path?: string | null },
): Promise<unknown | null> {
  if (row.payload !== null && row.payload !== undefined) return row.payload;
  if (!row.payload_path) return null;
  const { data, error } = await supabase.storage
    .from(RELEASE_CACHE_BUCKET)
    .download(row.payload_path);
  if (error || !data) return null;
  try {
    return JSON.parse(await data.text());
  } catch {
    return null;
  }
}

/// `fn` over `items`, no more than `limit` at once, results in input order.
export async function mapLimited<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index]);
    }
  });
  await Promise.all(workers);
  return results;
}

/// One batch of the move: upload each payload still held inline, then mark
/// only the ones that landed. A failed upload leaves its row untouched, to be
/// offered again by the next batch.
export async function offloadReleasePayloads(
  supabase: SupabaseClient,
  batch: number,
): Promise<{ offered: number; moved: number; failed: number }> {
  const { data, error } = await supabase.rpc("release_payloads_to_offload", { p_limit: batch });
  if (error) throw new Error(`could not read releases to move: ${error.message}`);
  const rows = (data ?? []) as Array<{ resource_id: string; payload: unknown }>;
  if (rows.length === 0) return { offered: 0, moved: 0, failed: 0 };

  // Storage, not Discogs, so a handful in parallel is fine — and one at a time
  // would take the worker's whole time limit for a single batch.
  const landed = await mapLimited(rows, 8, async (row) => {
    try {
      await storeReleasePayload(supabase, row.resource_id, row.payload);
      return row.resource_id;
    } catch (cause) {
      console.error("offload_upload_failed", row.resource_id, String(cause).slice(0, 200));
      return null;
    }
  });
  const ids = landed.filter((id): id is string => id !== null);

  let moved = 0;
  if (ids.length > 0) {
    const marked = await supabase.rpc("mark_release_payloads_offloaded", { p_resource_ids: ids });
    if (marked.error) throw new Error(`uploaded but could not mark: ${marked.error.message}`);
    moved = Number(marked.data ?? 0);
  }
  return { offered: rows.length, moved, failed: rows.length - ids.length };
}
