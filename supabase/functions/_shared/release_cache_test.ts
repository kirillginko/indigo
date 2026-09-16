import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import {
  mapLimited,
  offloadReleasePayloads,
  readCachedPayload,
  RELEASE_CACHE_BUCKET,
  releasePayloadPath,
  storeReleasePayload,
} from "./release_cache.ts";

/// Just enough of a client to record what was asked of Storage and the RPCs.
function fakeClient(options: {
  failUploads?: Set<string>;
  objects?: Map<string, string>;
  toOffload?: Array<{ resource_id: string; payload: unknown }>;
} = {}) {
  const uploads: Array<{ bucket: string; path: string; body: string; upsert: boolean }> = [];
  const marked: string[][] = [];
  const objects = options.objects ?? new Map<string, string>();
  const client = {
    storage: {
      from(bucket: string) {
        return {
          async upload(path: string, blob: Blob, opts: { upsert: boolean }) {
            if (options.failUploads?.has(path)) return { error: { message: "boom" } };
            const body = await blob.text();
            uploads.push({ bucket, path, body, upsert: opts.upsert });
            objects.set(path, body);
            return { error: null };
          },
          async download(path: string) {
            const body = objects.get(path);
            return body === undefined
              ? { data: null, error: { message: "not found" } }
              : { data: new Blob([body]), error: null };
          },
        };
      },
    },
    async rpc(name: string, args: Record<string, unknown>) {
      if (name === "release_payloads_to_offload") return { data: options.toOffload ?? [], error: null };
      if (name === "mark_release_payloads_offloaded") {
        const ids = args.p_resource_ids as string[];
        marked.push(ids);
        return { data: ids.length, error: null };
      }
      return { data: null, error: { message: `unexpected rpc ${name}` } };
    },
  };
  return { client: client as unknown as SupabaseClient, uploads, marked, objects };
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("a release is kept at a key made from its id alone", () => {
  assert(releasePayloadPath("74698") === "releases/74698.json", "unexpected key");
});

Deno.test("storing a release uploads the whole payload, overwriting any older copy", async () => {
  const { client, uploads } = fakeClient();
  const payload = { id: 74698, title: "Fly Stereophonic", community: { have: 120 } };
  const path = await storeReleasePayload(client, "74698", payload);
  assert(path === "releases/74698.json", "returned the wrong key");
  assert(uploads.length === 1, "expected one upload");
  assert(uploads[0].bucket === RELEASE_CACHE_BUCKET, "uploaded to the wrong bucket");
  assert(uploads[0].upsert === true, "a refetch must overwrite, not fail");
  assert(JSON.stringify(JSON.parse(uploads[0].body)) === JSON.stringify(payload), "payload was altered");
});

Deno.test("a failed upload throws, so no row points at nothing", async () => {
  const { client } = fakeClient({ failUploads: new Set(["releases/1.json"]) });
  let threw = false;
  try {
    await storeReleasePayload(client, "1", { id: 1 });
  } catch {
    threw = true;
  }
  assert(threw, "an upload that failed was reported as stored");
});

Deno.test("an inline payload is read without touching Storage", async () => {
  const { client } = fakeClient();
  const got = await readCachedPayload(client, { payload: { results: [] }, payload_path: null });
  assert(JSON.stringify(got) === '{"results":[]}', "did not return the inline payload");
});

Deno.test("a moved payload is read back from Storage", async () => {
  const objects = new Map([["releases/9.json", '{"id":9,"title":"Nine"}']]);
  const { client } = fakeClient({ objects });
  const got = await readCachedPayload(client, { payload: null, payload_path: "releases/9.json" }) as {
    title: string;
  };
  assert(got?.title === "Nine", "did not read the stored release");
});

Deno.test("an object that is missing reads as a miss, not an error", async () => {
  const { client } = fakeClient();
  const got = await readCachedPayload(client, { payload: null, payload_path: "releases/404.json" });
  assert(got === null, "a missing object should read as a miss");
});

Deno.test("only releases whose upload landed are marked moved", async () => {
  const { client, marked } = fakeClient({
    failUploads: new Set(["releases/2.json"]),
    toOffload: [
      { resource_id: "1", payload: { id: 1 } },
      { resource_id: "2", payload: { id: 2 } },
      { resource_id: "3", payload: { id: 3 } },
    ],
  });
  const result = await offloadReleasePayloads(client, 250);
  assert(marked.length === 1, "expected one mark call");
  assert(JSON.stringify(marked[0].sort()) === '["1","3"]', `marked ${marked[0]}`);
  assert(result.offered === 3 && result.moved === 2 && result.failed === 1, JSON.stringify(result));
});

Deno.test("an empty batch does nothing at all", async () => {
  const { client, uploads, marked } = fakeClient({ toOffload: [] });
  const result = await offloadReleasePayloads(client, 250);
  assert(result.offered === 0 && uploads.length === 0 && marked.length === 0, "an empty batch did work");
});

Deno.test("parallel work keeps its order and its limit", async () => {
  let running = 0;
  let peak = 0;
  const out = await mapLimited([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 3, async (n) => {
    running++;
    peak = Math.max(peak, running);
    await new Promise((r) => setTimeout(r, 5));
    running--;
    return n * 2;
  });
  assert(peak <= 3, `ran ${peak} at once`);
  assert(JSON.stringify(out) === "[2,4,6,8,10,12,14,16,18,20]", "results out of order");
});
