// Checks a host serving Indigo's R2 bucket before the app is pointed at it
// (CATALOG_CACHE_HOST in Config/Indigo.xcconfig). Read-only.
//
//   deno run --allow-net Scripts/r2-domain-check.ts <host> [<reference-host>]
//
// <reference-host> is the host the app uses today (the bucket's r2.dev URL):
// every object read from <host> must be byte-identical to it. Checks:
// - TLS: https answers with a certificate the system trusts; plain http
//   redirects to https (or is refused), never serves content;
// - MIME: JSON objects are served as application/json;
// - caching: addressed objects (bundles, release documents) carry a long,
//   immutable Cache-Control; the pilot pointer a short one; a second read is
//   served from the edge where the host has one (cf-cache-status);
// - conditional requests: an ETag, and If-None-Match answered 304;
// - CORS: what an Origin header gets back (only matters for a web client);
// - integrity: pointer -> manifest -> 20 bundles, each its digest;
// - latency: 20 reads of the pointer, p50 and p95.

const [host, reference] = Deno.args;
if (!host) throw new Error("usage: r2-domain-check.ts <host> [<reference-host>]");
const POINTER = "knowledge/v1/catalogue/pilot.json";
const RELEASE = "releases/863079.json";

type Check = { check: string; pass: boolean | null; detail: string };
const checks: Check[] = [];
const add = (check: string, pass: boolean | null, detail: string) => checks.push({ check, pass, detail });

async function sha256(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function get(h: string, key: string, headers: Record<string, string> = {}) {
  const started = performance.now();
  const response = await fetch(`https://${h}/${key}`, { headers: { "User-Agent": "indigo-domain-check/1", ...headers }, redirect: "manual" });
  const body = new Uint8Array(await response.arrayBuffer());
  return { status: response.status, headers: response.headers, body, ms: performance.now() - started };
}

// TLS and redirects.
try {
  const r = await get(host, POINTER);
  add("https answers with a trusted certificate", r.status === 200, `HTTP ${r.status}`);
} catch (error) {
  add("https answers with a trusted certificate", false, String(error));
}
try {
  const r = await fetch(`http://${host}/${POINTER}`, { redirect: "manual" });
  await r.body?.cancel();
  const location = r.headers.get("location") ?? "";
  add("http never serves content", r.status !== 200, `HTTP ${r.status}${location ? ` -> ${location}` : ""}`);
  add("http redirects to https", r.status >= 300 && r.status < 400 && location.startsWith("https://"), `HTTP ${r.status}`);
} catch (error) {
  add("http never serves content", true, `refused: ${String(error).slice(0, 80)}`);
  add("http redirects to https", null, "refused rather than redirected");
}

// MIME and caching, per kind of object.
const pointer = await get(host, POINTER);
const pointerJSON = JSON.parse(new TextDecoder().decode(pointer.body));
const manifest = await get(host, pointerJSON.manifest);
const manifestJSON = JSON.parse(new TextDecoder().decode(manifest.body));
const bundleKeys = Object.values(manifestJSON.artists as Record<string, { key: string; digest: string }>).slice(0, 20);
const bundle = await get(host, bundleKeys[0].key);
const release = await get(host, RELEASE);
for (const [name, r] of [["pointer", pointer], ["manifest", manifest], ["bundle", bundle], ["release document", release]] as const) {
  const type = r.headers.get("content-type") ?? "";
  add(`${name}: application/json`, type.startsWith("application/json"), type || "none");
  add(`${name}: Cache-Control`, null, r.headers.get("cache-control") ?? "none");
}
add("bundle: immutable", /immutable/.test(bundle.headers.get("cache-control") ?? ""), bundle.headers.get("cache-control") ?? "none");
add("pointer: short-lived", /max-age=(\d+)/.test(pointer.headers.get("cache-control") ?? "") &&
  Number(/max-age=(\d+)/.exec(pointer.headers.get("cache-control")!)![1]) <= 300, pointer.headers.get("cache-control") ?? "none");
const again = await get(host, bundleKeys[0].key);
add("edge cache on a second read", null, again.headers.get("cf-cache-status") ?? "no cf-cache-status (no edge cache)");

// Conditional requests and CORS.
const etag = bundle.headers.get("etag");
add("ETag present", !!etag, etag ?? "none");
if (etag) {
  const conditional = await get(host, bundleKeys[0].key, { "If-None-Match": etag });
  add("If-None-Match answered 304", conditional.status === 304, `HTTP ${conditional.status}`);
}
const cors = await get(host, POINTER, { Origin: "https://example.com" });
add("CORS (web clients only)", null, cors.headers.get("access-control-allow-origin") ?? "no Access-Control-Allow-Origin");

// Integrity, and identical bytes to the reference host.
add("manifest is its digest", (await sha256(manifest.body)) === pointerJSON.digest, pointerJSON.digest.slice(0, 12));
let sound = 0, same = 0;
for (const entry of bundleKeys) {
  const r = await get(host, entry.key);
  if ((await sha256(r.body)) === entry.digest) sound += 1;
  if (reference) {
    const ref = await get(reference, entry.key);
    if ((await sha256(ref.body)) === (await sha256(r.body))) same += 1;
  }
}
add("20 bundles are their digests", sound === bundleKeys.length, `${sound}/${bundleKeys.length}`);
if (reference) {
  add("byte-identical to the reference host", same === bundleKeys.length, `${same}/${bundleKeys.length}`);
  const refRelease = await get(reference, RELEASE);
  add("release document identical", (await sha256(refRelease.body)) === (await sha256(release.body)), RELEASE);
}

// Latency.
const ms: number[] = [];
for (let i = 0; i < 20; i++) ms.push((await get(host, POINTER, { "Cache-Control": "no-cache" })).ms);
ms.sort((a, b) => a - b);
add("pointer latency", null, `p50 ${Math.round(ms[10])} ms, p95 ${Math.round(ms[18])} ms`);

const failed = checks.filter((c) => c.pass === false);
console.log(JSON.stringify({ host, reference: reference ?? null, ready: failed.length === 0, checks }, null, 1));
