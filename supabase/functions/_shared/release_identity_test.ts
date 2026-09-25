import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { resolveRelease } from "./discogs.ts";
import { readCachedRelease } from "./release_cache.ts";
import type { R2Config } from "./r2.ts";

type Row = Record<string, unknown>;

/// A `releases` table and nothing else, keyed as 0056 keys it: one row per
/// Discogs id. `raceOnInsert` files the id first, as a second worker would.
function fakeReleases(rows: Row[] = [], options: { raceOnInsert?: boolean } = {}) {
  const calls: string[] = [];
  const byDiscogsID = (id: unknown) => rows.find((row) => row.discogs_id === id) ?? null;

  const client = {
    from(table: string) {
      if (table !== "releases") throw new Error(`unexpected table ${table}`);
      return {
        select(_columns: string) {
          return {
            eq(_column: string, id: unknown) {
              return {
                maybeSingle() {
                  calls.push("select");
                  const row = byDiscogsID(id);
                  return Promise.resolve({ data: row, error: null });
                },
              };
            },
          };
        },
        update(fields: Row) {
          return {
            eq(_column: string, id: unknown) {
              return {
                select(_columns: string) {
                  return {
                    maybeSingle() {
                      calls.push("update");
                      const row = byDiscogsID(id);
                      if (row) Object.assign(row, fields);
                      return Promise.resolve({ data: row ? { id: row.id } : null, error: null });
                    },
                  };
                },
              };
            },
          };
        },
        insert(row: Row) {
          return {
            select(_columns: string) {
              return {
                single() {
                  calls.push("insert");
                  if (options.raceOnInsert) {
                    rows.push({ ...row, id: "winner" });
                    return Promise.resolve({ data: null, error: { code: "23505", message: "duplicate" } });
                  }
                  if (byDiscogsID(row.discogs_id)) {
                    return Promise.resolve({ data: null, error: { code: "23505", message: "duplicate" } });
                  }
                  const filed = { ...row, id: `new-${rows.length}` };
                  rows.push(filed);
                  return Promise.resolve({ data: { id: filed.id }, error: null });
                },
              };
            },
          };
        },
      };
    },
  };
  return { client: client as unknown as SupabaseClient, rows, calls };
}

function assertEquals(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: expected ${e}, got ${a}`);
}

Deno.test("a release already on file is found by its Discogs id", async () => {
  const { client, calls } = fakeReleases([{ id: "r1", discogs_id: "249504" }]);
  assertEquals(await resolveRelease(client, "249504", { title: "x" }), "r1", "id");
  assertEquals(calls, ["select"], "one read, no insert");
});

Deno.test("caching a release already on file stamps it in the same call", async () => {
  const { client, rows, calls } = fakeReleases([{ id: "r1", discogs_id: "249504" }]);
  const at = "2026-09-25T00:00:00.000Z";
  assertEquals(await resolveRelease(client, "249504", { title: "x" }, at), "r1", "id");
  assertEquals(rows[0].discogs_cached_at, at, "stamped");
  assertEquals(calls, ["update"], "one call");
});

Deno.test("a new release is filed with its id and stamp on the row", async () => {
  const { client, rows } = fakeReleases();
  const at = "2026-09-25T00:00:00.000Z";
  const id = await resolveRelease(client, "7", { title: "New" }, at);
  assertEquals(id, "new-0", "id");
  assertEquals(
    [rows[0].discogs_id, rows[0].discogs_cached_at, rows[0].title],
    ["7", at, "New"],
    "row",
  );
});

Deno.test("a release filed without its document is left unstamped", async () => {
  const { client, rows } = fakeReleases();
  await resolveRelease(client, "7", { title: "New" });
  assertEquals(rows[0].discogs_cached_at, null, "no stamp");
});

Deno.test("losing the race for an id returns the winner's row", async () => {
  const { client, rows } = fakeReleases([], { raceOnInsert: true });
  assertEquals(await resolveRelease(client, "7", { title: "x" }), "winner", "winner");
  assertEquals(rows.length, 1, "no second row");
});

// -- reading one back ------------------------------------------------------

const r2: R2Config = { accountID: "a", accessKeyID: "k", secretAccessKey: "s", bucket: "b" };
const DAY = 86_400_000;

/// R2 by its S3 API, answered from a map of key -> body.
function withObjects<T>(objects: Map<string, string>, body: () => Promise<T>): Promise<T> {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: Request | URL | string) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const key = decodeURIComponent(url.pathname.split("/").slice(2).join("/"));
    const text = objects.get(key);
    return Promise.resolve(text === undefined ? new Response(null, { status: 404 }) : new Response(text));
  }) as typeof fetch;
  return body().finally(() => {
    globalThis.fetch = original;
  });
}

Deno.test("a cached release is read from R2 by its id alone", async () => {
  const { client } = fakeReleases([
    { id: "r1", discogs_id: "7", discogs_cached_at: new Date(Date.now() - DAY).toISOString() },
  ]);
  const found = await withObjects(
    new Map([["releases/7.json", '{"id":7}']]),
    () => readCachedRelease(client, "7", 60 * DAY, r2),
  );
  assertEquals(found, { payload: { id: 7 }, fresh: true }, "hit");
});

Deno.test("a release past its lifetime is returned, marked stale", async () => {
  const { client } = fakeReleases([
    { id: "r1", discogs_id: "7", discogs_cached_at: new Date(Date.now() - 61 * DAY).toISOString() },
  ]);
  const found = await withObjects(
    new Map([["releases/7.json", '{"id":7}']]),
    () => readCachedRelease(client, "7", 60 * DAY, r2),
  );
  assertEquals(found?.fresh, false, "stale");
});

Deno.test("a release never cached is a miss without asking R2", async () => {
  const { client } = fakeReleases([{ id: "r1", discogs_id: "7", discogs_cached_at: null }]);
  let asked = false;
  const original = globalThis.fetch;
  globalThis.fetch = (() => {
    asked = true;
    return Promise.resolve(new Response(null, { status: 404 }));
  }) as typeof fetch;
  try {
    assertEquals(await readCachedRelease(client, "7", 60 * DAY, r2), null, "miss");
  } finally {
    globalThis.fetch = original;
  }
  assertEquals(asked, false, "no R2 request");
});

Deno.test("a stamped release whose document is gone is a miss", async () => {
  const { client } = fakeReleases([
    { id: "r1", discogs_id: "7", discogs_cached_at: new Date().toISOString() },
  ]);
  const found = await withObjects(new Map(), () => readCachedRelease(client, "7", 60 * DAY, r2));
  assertEquals(found, null, "miss");
});
