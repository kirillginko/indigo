// Where a cached release is, and how it is addressed on R2.
//
//     deno test supabase/functions/_shared/r2_test.ts

import { assertEquals } from "jsr:@std/assert@1";
import { cachePayloadKey, isInR2, objectURL, r2Config, r2Key } from "./r2.ts";

Deno.test("R2 is used only when all four secrets are set", () => {
  const full: Record<string, string> = {
    R2_ACCOUNT_ID: "acct", R2_ACCESS_KEY_ID: "id", R2_SECRET_ACCESS_KEY: "secret", R2_BUCKET: "cache",
  };
  assertEquals(r2Config((name) => full[name])?.bucket, "cache");
  for (const missing of Object.keys(full)) {
    const partial = { ...full, [missing]: "" };
    assertEquals(r2Config((name) => partial[name]), null, `${missing} missing`);
  }
});

Deno.test("a row says which store holds its document", () => {
  assertEquals(isInR2("r2:releases/1.json"), true);
  assertEquals(isInR2("releases/1.json"), false, "still in Supabase Storage");
  assertEquals(isInR2(null), false);
  assertEquals(r2Key("r2:releases/1.json"), "releases/1.json");
  assertEquals(r2Key("releases/1.json"), "releases/1.json");
});

Deno.test("keys are addressed segment by segment", () => {
  const config = { accountID: "acct", accessKeyID: "id", secretAccessKey: "s", bucket: "indigo-cache" };
  assertEquals(objectURL(config, "releases/123.json"),
    "https://acct.r2.cloudflarestorage.com/indigo-cache/releases/123.json");
  assertEquals(objectURL(config, "cache/a b?.json"),
    "https://acct.r2.cloudflarestorage.com/indigo-cache/cache/a%20b%3F.json");
});

Deno.test("a cached response has one key, whatever its id looks like", async () => {
  const search = "database/search?label=Warp Records&per_page=100";
  const first = await cachePayloadKey("discogs", "database/search", search);
  assertEquals(first, await cachePayloadKey("discogs", "database/search", search), "a refetch overwrites");
  assertEquals(/^cache\/discogs\/[0-9a-f]{64}\.json$/.test(first), true, first);
  const other = await cachePayloadKey("discogs", "database/search", search + "&page=2");
  assertEquals(first === other, false);
  // The separator keeps "a" + "bc" apart from "ab" + "c".
  assertEquals(
    await cachePayloadKey("discogs", "a", "bc") === await cachePayloadKey("discogs", "ab", "c"),
    false,
  );
});
