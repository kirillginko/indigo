// Where a cached Discogs release lives: an object in R2 at
// `releases/<id>.json`, and the time it was stored on the release row itself
// (0056). Before that, a `metadata_cache` row pointed at it (0036, 0051).
//
// One module for the three places that touch it — the worker's release job,
// `catalog-refresh`, and the one-off move of what was already stored — so the
// bucket, the key and the read fallback cannot drift between them.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { cachePayloadKey, getObject, isInR2, putObject, R2_PREFIX, r2Config, r2Key } from "./r2.ts";

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

/// A write R2's budget would not allow (0053). Callers treat it as any other
/// failed upload: nothing is cached, and the page is served live instead.
export class R2BudgetExceeded extends Error {}

function byteLength(text: string): number {
  return new TextEncoder().encode(text).length;
}

/// Reserves room in the R2 budget, or throws. Fails closed: a budget that
/// cannot be read is not permission to write.
export async function reserveR2(supabase: SupabaseClient, writes: number, bytes: number): Promise<void> {
  if (writes <= 0) return;
  const { data, error } = await supabase.rpc("r2_reserve", { p_writes: writes, p_bytes: bytes });
  if (error) throw new Error(`r2 budget unavailable: ${error.message}`);
  if (data !== true) {
    throw new R2BudgetExceeded(`r2 budget refused ${writes} write(s) of ${bytes} bytes`);
  }
}

/// Uploads a release and returns the key to record. Throws on failure, so a
/// caller never writes a row pointing at an object that is not there.
///
/// To R2 once its secrets are set (0051), recorded as `r2:releases/<id>.json`;
/// to Supabase Storage until then.
export async function storeReleasePayload(
  supabase: SupabaseClient,
  releaseID: string,
  payload: unknown,
): Promise<string> {
  const path = releasePayloadPath(releaseID);
  const r2 = r2Config();
  if (r2) {
    const body = JSON.stringify(payload);
    await reserveR2(supabase, 1, byteLength(body));
    await putObject(r2, path, body);
    return `${R2_PREFIX}${path}`;
  }
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
  if (isInR2(row.payload_path)) {
    const r2 = r2Config();
    if (!r2) return null;
    try {
      const text = await getObject(r2, r2Key(row.payload_path));
      return text === null ? null : JSON.parse(text);
    } catch {
      return null;
    }
  }
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

/// A cached release, read by its Discogs id alone (0056).
///
/// No `metadata_cache` row stands for a release any more: the release row
/// says when its document was stored, and the document is in R2 at a key made
/// from the id. Null for a release never cached, or a document that will not
/// load -- a miss, as before. `fresh` is false for one older than `lifetimeMs`,
/// which a caller may still serve when the provider will not answer.
export async function readCachedRelease(
  supabase: SupabaseClient,
  releaseID: string,
  lifetimeMs: number,
  r2 = r2Config(),
): Promise<{ payload: unknown; fresh: boolean } | null> {
  if (!r2) return null;
  const { data, error } = await supabase
    .from("releases")
    .select("discogs_cached_at")
    .eq("discogs_id", releaseID)
    .maybeSingle();
  const cachedAt = error ? NaN : Date.parse(String(data?.discogs_cached_at ?? ""));
  if (!Number.isFinite(cachedAt)) return null;
  try {
    const text = await getObject(r2, releasePayloadPath(releaseID));
    if (text === null) return null;
    return { payload: JSON.parse(text), fresh: Date.now() - cachedAt < lifetimeMs };
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

// ---------------------------------------------------------------------------
// The move to R2 (0051)
// ---------------------------------------------------------------------------

/// Where the move has got to, in `enrichment_cursors`: the last release id
/// taken. Walked in id order on the cache's own unique index, so each batch is
/// an index range rather than a scan for rows not yet moved.
export const R2_MOVE_CHECKPOINT = "release-cache.r2-move";

export interface MoveResult {
  offered: number;
  moved: number;
  failed: number;
  done: boolean;
}

/// Moves one batch of release documents from Supabase Storage to R2.
///
/// Copy, then point the rows at the copy, then remove the originals -- in
/// that order, so a failure anywhere leaves every row pointing at an object
/// that exists. An original left behind by a failure after the rows moved is
/// only a file nobody reads, and the storage sweep at the end finds it.
export async function moveReleasePayloadsToR2(
  supabase: SupabaseClient,
  batch: number,
): Promise<MoveResult> {
  const r2 = r2Config();
  if (!r2) throw new Error("r2 is not configured; set the R2_* secrets first");

  const { data: cursorRow, error: cursorError } = await supabase
    .from("enrichment_cursors")
    .select("state")
    .eq("name", R2_MOVE_CHECKPOINT)
    .maybeSingle();
  if (cursorError) throw new Error(`could not read the move's checkpoint: ${cursorError.message}`);
  const after = String((cursorRow?.state as { after?: string } | null)?.after ?? "");

  const { data, error } = await supabase
    .from("metadata_cache")
    .select("resource_id,payload_path")
    .eq("provider", "discogs")
    .eq("resource_type", "release")
    .gt("resource_id", after)
    .order("resource_id")
    .limit(batch);
  if (error) throw new Error(`could not read releases to move: ${error.message}`);
  const rows = (data ?? []) as Array<{ resource_id: string; payload_path: string | null }>;
  if (rows.length === 0) return { offered: 0, moved: 0, failed: 0, done: true };

  const waiting = rows.filter((row) => row.payload_path && !isInR2(row.payload_path));

  // Read first, then reserve the whole batch in one go, then write: the
  // budget is asked once per batch rather than once per file, and a batch it
  // refuses writes nothing at all.
  const read = await mapLimited(waiting, 8, async (row) => {
    try {
      const { data: blob, error: downloadError } = await supabase.storage
        .from(RELEASE_CACHE_BUCKET)
        .download(row.payload_path!);
      if (downloadError || !blob) throw new Error(downloadError?.message ?? "no object");
      return { row: row as { resource_id: string; payload_path: string }, body: await blob.text() };
    } catch (cause) {
      console.error("r2_move_read_failed", row.resource_id, String(cause).slice(0, 200));
      return null;
    }
  });
  const ready = read.filter((item): item is { row: { resource_id: string; payload_path: string }; body: string } =>
    item !== null);
  await reserveR2(supabase, ready.length, ready.reduce((sum, item) => sum + byteLength(item.body), 0));

  const landed = await mapLimited(ready, 8, async ({ row, body }) => {
    try {
      await putObject(r2, row.payload_path, body);
      return row;
    } catch (cause) {
      console.error("r2_move_failed", row.resource_id, String(cause).slice(0, 200));
      return null;
    }
  });
  const copied = landed.filter((row): row is { resource_id: string; payload_path: string } => row !== null);

  if (copied.length > 0) {
    const marked = await supabase.rpc("mark_release_payloads_in_r2", {
      p_resource_ids: copied.map((row) => row.resource_id),
    });
    if (marked.error) throw new Error(`copied but could not repoint: ${marked.error.message}`);

    // Up to a thousand paths per call; a batch is never that large.
    const removed = await supabase.storage
      .from(RELEASE_CACHE_BUCKET)
      .remove(copied.map((row) => row.payload_path));
    if (removed.error) console.error("r2_move_remove_failed", removed.error.message);
  }

  // Forward past the whole batch, failures included: a release that would not
  // copy keeps its Storage copy and its row, and is still read from there.
  const last = rows[rows.length - 1].resource_id;
  const { error: advanceError } = await supabase
    .from("enrichment_cursors")
    .upsert({ name: R2_MOVE_CHECKPOINT, state: { after: last }, updated_at: new Date().toISOString() },
      { onConflict: "name" });
  if (advanceError) throw new Error(`could not advance the move: ${advanceError.message}`);

  return {
    offered: waiting.length,
    moved: copied.length,
    failed: waiting.length - copied.length,
    done: false,
  };
}

// ---------------------------------------------------------------------------
// Everything else in the cache (0052)
// ---------------------------------------------------------------------------

/// Puts a cached response other than a release in R2 and returns the path to
/// record, or null when R2 is not configured -- in which case the caller keeps
/// it inline, as before. Throws when the upload fails, so a row is never
/// written pointing at an object that is not there.
export async function storeCachePayload(
  supabase: SupabaseClient,
  provider: string,
  resourceType: string,
  resourceID: string,
  payload: unknown,
): Promise<string | null> {
  const r2 = r2Config();
  if (!r2) return null;
  const key = await cachePayloadKey(provider, resourceType, resourceID);
  const body = JSON.stringify(payload);
  await reserveR2(supabase, 1, byteLength(body));
  await putObject(r2, key, body);
  return `${R2_PREFIX}${key}`;
}

/// Moves one batch of responses still held inline in `metadata_cache` to R2.
///
/// Searches, artist and label pages, shelves and NTS documents: 4,927 rows and
/// 36 MB when this was written, all of it in Postgres. A moved row keeps its
/// key, expiry and everything else; only where the document is changes.
/// Set once the inline move finds nothing left, so later runs ask one indexed
/// question instead of scanning the cache for rows that are not there (0054).
export const R2_INLINE_DONE_CHECKPOINT = "release-cache.r2-inline-done";

export async function moveInlinePayloadsToR2(
  supabase: SupabaseClient,
  batch: number,
): Promise<MoveResult> {
  const r2 = r2Config();
  if (!r2) throw new Error("r2 is not configured; set the R2_* secrets first");

  const { data: finished } = await supabase
    .from("enrichment_cursors")
    .select("name")
    .eq("name", R2_INLINE_DONE_CHECKPOINT)
    .maybeSingle();
  if (finished) return { offered: 0, moved: 0, failed: 0, done: true };

  const { data, error } = await supabase
    .from("metadata_cache")
    .select("id,provider,resource_type,resource_id,payload")
    .not("payload", "is", null)
    .limit(batch);
  if (error) throw new Error(`could not read inline payloads: ${error.message}`);
  const rows = (data ?? []) as Array<{
    id: string; provider: string; resource_type: string; resource_id: string; payload: unknown;
  }>;
  if (rows.length === 0) {
    // New writes go to R2 from here on, so nothing inline will appear again
    // unless an upload fails; the remaining stragglers are left to that.
    await supabase.from("enrichment_cursors").upsert(
      { name: R2_INLINE_DONE_CHECKPOINT, state: { at: new Date().toISOString() }, updated_at: new Date().toISOString() },
      { onConflict: "name" },
    );
    return { offered: 0, moved: 0, failed: 0, done: true };
  }

  const bodies = rows.map((row) => JSON.stringify(row.payload));
  await reserveR2(supabase, rows.length, bodies.reduce((sum, body) => sum + byteLength(body), 0));

  const landed = await mapLimited(rows.map((row, index) => ({ row, body: bodies[index] })), 8, async ({ row, body }) => {
    try {
      const key = await cachePayloadKey(row.provider, row.resource_type, row.resource_id);
      await putObject(r2, key, body);
      return { id: row.id, path: `${R2_PREFIX}${key}` };
    } catch (cause) {
      console.error("r2_inline_move_failed", row.id, String(cause).slice(0, 200));
      return null;
    }
  });
  const copied = landed.filter((row): row is { id: string; path: string } => row !== null);

  if (copied.length > 0) {
    const marked = await supabase.rpc("mark_inline_payloads_in_r2", {
      p_ids: copied.map((row) => row.id),
      p_paths: copied.map((row) => row.path),
    });
    if (marked.error) throw new Error(`copied but could not repoint: ${marked.error.message}`);
  }
  return { offered: rows.length, moved: copied.length, failed: rows.length - copied.length, done: false };
}
