// The generation publisher's dry run, against a cut and an R2 that live in the
// test. The cut answers the frozen pilot demand set (24 nodes, 163 artists),
// shaped as 0075 answers it.
//
//     deno test supabase/functions/_shared/generations_test.ts

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import pilot from "./testdata/pilot_demand_v1.json" with { type: "json" };
import { artistRefKey } from "./knowledge.ts";
import { bundleKey } from "./artist_bundle.ts";
import {
  bundleIDs, compareEdges, CURRENT_KEY, Cut, cutProblems, dayKey, Demand, dryRunGeneration, GenerationReadDeps,
  identitySnapshot, manifestKey, normalizeAnswer, PILOT_DEMAND_DIGEST, planGeneration, publishGeneration,
  PublishDeps, referencedObjects,
} from "./generations.ts";

const DAY = "2026-10-12";
const demand = pilot as unknown as Demand;

function makeCut(overrides: Partial<Cut> = {}): Cut {
  const nodes: Record<string, Record<string, unknown>> = {};
  for (const { id } of demand.nodes) {
    if (id === "artist:zzz nobody files this name") { nodes[id] = { status: "unknown", edges: [], identities: [] }; continue; }
    if (!id.startsWith("artist:")) { nodes[id] = { status: "unsupported", edges: [], identities: [] }; continue; }
    nodes[id] = {
      status: "found",
      identities: [],
      edges: [
        { kind: "sharedLabel", confidence: 0.8, occurrences: 2, reason: "Shared a label",
          to: { kind: "artist", name: "Inga Copeland", rowID: "row-inga", discogsID: "1874031", idEvidence: "discogs-document" } },
        { kind: "frequentlyPlayedNearby", confidence: 0.65, occurrences: 1, reason: "Played next to each other on the radio",
          to: { kind: "artist", name: "Panda Bear", rowID: "row-panda", discogsID: "62012", idEvidence: "adopted-by-name" } },
        { kind: "frequentlyPlayedNearby", confidence: 0.65, occurrences: 1, reason: "Played next to each other on the radio",
          to: { kind: "artist", name: "Nobody Catalogued", rowID: "row-nobody" } },
      ],
    };
  }
  nodes["artist:dean blunt"].seeds = [{ rowID: "row-dean", name: "Dean Blunt", by: ["discogs", "name"], discogsID: "2419343" }];
  nodes["artist:dean blunt"].identities = [{ catalogued: true, discogsID: "2419343", via: "discogs" }];
  nodes["artist:speedy j"].seeds = [
    { rowID: "row-sj1", name: "Speedy J", by: ["identity", "name"], discogsID: "316464" },
    { rowID: "row-sj2", name: "Speedy J", by: ["identity", "mbid", "name"], discogsID: "823" },
  ];
  nodes["artist:speedy j"].ambiguousName = true;
  const artists: Record<string, Record<string, unknown>> = {};
  for (const { key } of demand.artists) {
    artists[key] = key === "zzz nobody files this name"
      ? { status: "unknown", episodes: [], genres: [], rosters: [], identities: [] }
      : { status: "found", episodes: [{ showID: `${key}/1`, title: key }], genres: ["Ambient"], rosters: [], identities: [] };
  }
  return {
    format: "indigo.knowledge-cut/1", status: "ok", reason: null, day: DAY,
    statementAt: `${DAY}T00:41:07Z`, snapshot: "2778250:2778250:", demandDigest: PILOT_DEMAND_DIGEST,
    rebuild: {
      proof: { jobid: 6, runid: 88841, start_time: `${DAY}T00:23:00.1Z`, end_time: `${DAY}T00:23:18.9Z` },
      latest: { jobid: 6, runid: 88841, start_time: `${DAY}T00:23:00.1Z`, end_time: `${DAY}T00:23:18.9Z` },
    },
    nodes, artists, batches: 4,
    ...overrides,
  };
}

/// R2 as a map, read-only through the deps, counting every call.
class World {
  r2 = new Map<string, string>();
  calls: string[] = [];
  cuts = 0;
  constructor(public cut: Cut = makeCut()) {}
  deps(): GenerationReadDeps {
    const deps: GenerationReadDeps = {
      cut: () => { this.cuts += 1; return Promise.resolve({ cut: this.cut, ms: 900 }); },
      getObject: (key) => { this.calls.push(`get ${key}`); return Promise.resolve(this.r2.get(key) ?? null); },
      exists: (key) => { this.calls.push(`head ${key}`); return Promise.resolve(this.r2.has(key)); },
      now: () => new Date(`${DAY}T00:41:00Z`),
    };
    // Anything else asked of the deps -- a write by any name -- fails the test.
    return new Proxy(deps, {
      get(target, prop) {
        if (!(prop in target)) throw new Error(`dry run reached for deps.${String(prop)}`);
        return target[prop as keyof GenerationReadDeps];
      },
    });
  }
}

Deno.test("the frozen pilot cut passes every check", () => {
  assertEquals(cutProblems(makeCut(), DAY, demand), []);
  assertEquals(demand.nodes.length, 24);
  assertEquals(demand.artists.length, 163);
});

Deno.test("a faulty cut is refused, and says why", () => {
  const refused = (c: Cut) => cutProblems(c, DAY, demand);
  assertEquals(refused(makeCut({ status: "refused", reason: "no-completed-rebuild-today", nodes: null, artists: null })),
    ["refused: no-completed-rebuild-today"]);
  assert(refused(makeCut({ day: "2026-10-11" }))[0].includes("not 2026-10-12"));
  assert(refused(makeCut({ demandDigest: "0".repeat(64) }))[0].includes("not the frozen pilot set"));
  assert(refused(makeCut({ rebuild: { proof: null, latest: null } }))[0] === "no rebuild proof");
  const late = makeCut();
  late.rebuild!.proof = { jobid: 6, runid: 1, start_time: `${DAY}T03:23:00Z`, end_time: `${DAY}T03:23:18Z` };
  assert(refused(late).some((p) => p.includes("outside")));
  const unfinished = makeCut();
  unfinished.rebuild!.proof!.end_time = `${DAY}T00:45:00Z`;
  assert(refused(unfinished).some((p) => p.includes("had not finished")));
  const missing = makeCut();
  delete missing.nodes!["artist:dean blunt"];
  delete missing.artists!["dean blunt"];
  assertEquals(refused(missing), ["node artist:dean blunt is missing", "artist dean blunt is missing"]);
  const extra = makeCut();
  extra.nodes!["artist:somebody"] = { status: "found", edges: [] };
  assertEquals(refused(extra), ["node artist:somebody was not demanded"]);
  const odd = makeCut();
  odd.nodes!["artist:dean blunt"].status = "deferred";
  odd.artists!["dean blunt"].status = "maybe";
  assertEquals(refused(odd), ["node artist:dean blunt has status deferred", "artist dean blunt has status maybe"]);
});

Deno.test("the plan is deterministic and content-addressed", async () => {
  const input = { cut: makeCut(), demand, bundleRefs: new Map(), current: null, publishedAt: `${DAY}T00:42:00Z`, cutMs: 900 };
  const a = await planGeneration(input), b = await planGeneration(input);
  assertEquals(a.manifestDigest, b.manifestDigest);
  assertEquals(a.addressed.map((o) => o.key), b.addressed.map((o) => o.key));
  for (const o of a.addressed) {
    assert(o.key.endsWith(`/${o.digest.slice(0, 2)}/${o.digest}.json`), o.key);
    const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(o.body)))]
      .map((x) => x.toString(16).padStart(2, "0")).join("");
    assertEquals(digest, o.digest);
  }
  // 15 found starting artists + 162 found artists, the identity, the manifest.
  assertEquals(a.addressed.filter((o) => o.kind === "node").length, 15);
  assertEquals(a.addressed.filter((o) => o.kind === "artist").length, 162);
  assertEquals(a.addressed.length, 15 + 162 + 2);
  assertEquals(a.pointers.map((p) => p.key), [dayKey(DAY), CURRENT_KEY]);
  // A different snapshot is a different manifest, but the same answers.
  const c = await planGeneration({ ...input, cut: makeCut({ snapshot: "1:1:" }) });
  assertNotEquals(c.manifestDigest, a.manifestDigest);
  assertEquals(c.addressed.filter((o) => o.kind === "node").map((o) => o.digest), a.addressed.filter((o) => o.kind === "node").map((o) => o.digest));
});

Deno.test("statuses are explicit; unknown and unsupported carry no object", async () => {
  const plan = await planGeneration({ cut: makeCut(), demand, bundleRefs: new Map(), current: null, publishedAt: "", cutMs: 0 });
  const nodes = plan.manifest.nodes as Record<string, Record<string, unknown>>;
  assertEquals(nodes["artist:zzz nobody files this name"], { status: "unknown" });
  assertEquals(nodes["station:n10as"], { status: "unsupported" });
  assertEquals(nodes["artist:speedy j"].ambiguousName, true);
  assertEquals((plan.manifest.artists as Record<string, unknown>)["zzz nobody files this name"], { status: "unknown" });
  const summary = plan.manifest.summary as Record<string, Record<string, number>>;
  assertEquals(summary.nodes, { found: 15, unknown: 1, unsupported: 8, failed: 0 });
  assertEquals(summary.artists, { found: 162, unknown: 1, failed: 0 });
});

Deno.test("identity evidence stays distinguishable; only documents place an id", () => {
  const snapshot = identitySnapshot(makeCut()) as { rows: Record<string, unknown>[]; namesakes: unknown[]; starting: Record<string, unknown[]> };
  const row = (id: string) => snapshot.rows.find((r) => r.rowID === id)!;
  assertEquals(row("row-inga").evidence, ["discogs-document"]);
  assertEquals(row("row-inga").placeable, true);
  assertEquals(row("row-panda").evidence, ["adopted-by-name"]);
  assertEquals(row("row-panda").placeable, false);
  assertEquals(row("row-nobody").discogsID, undefined);
  assertEquals(row("row-nobody").placeable, false);
  assertEquals(snapshot.namesakes, [{ name: "Speedy J", rowIDs: ["row-sj1", "row-sj2"] }]);
  assertEquals(snapshot.starting["artist:speedy j"].length, 2);
});

Deno.test("bundles are pinned by digest, and coverage says what is missing", async () => {
  const cut = makeCut();
  assertEquals(bundleIDs(cut).get("artist:speedy j"), ["316464", "823"]);
  const refs = new Map([
    ["2419343", { digest: "d".repeat(64), key: "knowledge/v1/bundles/dd/x.json", source: { complete: true, documentsMissing: 0 } }],
    ["316464", { digest: "e".repeat(64), key: "knowledge/v1/bundles/ee/y.json", source: { complete: false, documentsRead: 71, documentsMissing: 13, representativeReleases: 84 } }],
  ]);
  const plan = await planGeneration({ cut, demand, bundleRefs: refs, current: null, publishedAt: "", cutMs: 0 });
  const nodes = plan.manifest.nodes as Record<string, Record<string, unknown>>;
  assertEquals(nodes["artist:dean blunt"].bundles, [{ discogsID: 2419343, status: "complete", digest: "d".repeat(64) }]);
  assertEquals(nodes["artist:speedy j"].bundles, [
    { discogsID: 316464, status: "partial", digest: "e".repeat(64), read: 71, of: 84 },
    { discogsID: 823, status: "missing" },
  ]);
  const summary = plan.manifest.summary as Record<string, Record<string, number>>;
  assertEquals(summary.bundles, { complete: 1, partial: 1, missing: 1, noIdentity: 13 });
});

Deno.test("current.json lists the new day first and keeps seven, withdrawn kept", async () => {
  const older = Array.from({ length: 8 }, (_, i) => ({ date: `2026-10-0${i + 1}`, manifest: String(i).repeat(64) })).reverse();
  const plan = await planGeneration({
    cut: makeCut(), demand, bundleRefs: new Map(), publishedAt: `${DAY}T00:42:00Z`, cutMs: 0,
    current: { generations: older, withdrawn: [{ date: "2026-10-03", reason: "test" }] },
  });
  const current = JSON.parse(plan.pointers[1].body);
  assertEquals(current.generations.length, 7);
  assertEquals(current.generations[0], { date: DAY, manifest: plan.manifestDigest });
  assertEquals(current.generations[1].date, "2026-10-08");
  assertEquals(current.withdrawn, [{ date: "2026-10-03", reason: "test" }]);
  assertEquals(plan.manifest.previous, older[0].manifest);
  assertEquals(JSON.parse(plan.pointers[0].body), { format: "indigo.knowledge-day/1", date: DAY, manifest: plan.manifestDigest, publishedAt: `${DAY}T00:42:00Z` });
});

Deno.test("the dry run reads, reports, and writes nothing", async () => {
  const world = new World();
  world.r2.set(artistRefKey(2419343), JSON.stringify({ digest: "d".repeat(64), key: "knowledge/v1/bundles/dd/x.json", source: { complete: true } }));
  world.r2.set("knowledge/v1/bundles/dd/x.json", "{}");
  const before = new Map(world.r2);
  const report = await dryRunGeneration(world.deps(), demand, {
    budget: { month_writes: 2056, month_write_cap: 800_000, bytes_written_ever: 0, storage_cap_bytes: 8 << 30 },
  });
  assertEquals(report.status, "ready");
  assertEquals(report.problems, []);
  assertEquals(world.r2, before);
  assert(world.calls.every((c) => c.startsWith("get ") || c.startsWith("head ")));
  assertEquals(world.cuts, 1);
  assertEquals(report.r2!.dryRun.puts, 0);
  assertEquals(report.generation!.objects.contentAddressed, 179);
  assertEquals(report.bundles!.complete, 1);
  assertEquals(report.bundles!.objectsPresent, 1);
  assertEquals(report.r2!.alreadyPresent, 0);
  // 179 new objects + day + current.json.
  assertEquals(report.r2!.publication.classA, 181);
  assertEquals(report.r2!.budget!.afterPublication, 2056 + 181);
});

Deno.test("objects already in R2 are not counted as writes", async () => {
  const world = new World();
  const plan = await planGeneration({ cut: world.cut, demand, bundleRefs: new Map(), current: null, publishedAt: "", cutMs: 0 });
  for (const o of plan.addressed.filter((o) => o.kind === "artist")) world.r2.set(o.key, o.body);
  const report = await dryRunGeneration(world.deps(), demand);
  assertEquals(report.r2!.alreadyPresent, 162);
  assertEquals(report.r2!.publication.classA, 179 - 162 + 2);
});

Deno.test("a refused cut stops before any R2 read", async () => {
  const world = new World(makeCut({ status: "refused", reason: "no-completed-rebuild-today", nodes: null, artists: null }));
  const report = await dryRunGeneration(world.deps(), demand);
  assertEquals(report.status, "refused");
  assertEquals(report.problems, ["refused: no-completed-rebuild-today"]);
  assertEquals(world.calls, []);
});

Deno.test("a day already published is reported, not overwritten", async () => {
  const world = new World();
  world.r2.set(dayKey(DAY), "{}");
  const report = await dryRunGeneration(world.deps(), demand);
  assertEquals(report.status, "refused");
  assertEquals(report.problems, [`${dayKey(DAY)} exists: ${DAY} is published already`]);
  assertEquals(world.r2.get(dayKey(DAY)), "{}");
});

// MARK: - Publication

async function digestOf(text: string): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))]
    .map((x) => x.toString(16).padStart(2, "0")).join("");
}

/// R2 in memory, with ETags and conditional writes, and places to break it.
class Bucket {
  objects = new Map<string, { body: string; etag: string }>();
  version = 0;
  cuts = 0;
  reserved = 0;
  cut: Cut = makeCut();
  clock = new Date(`${DAY}T00:41:00Z`);
  /// Called before each create/replace; may throw (an interruption) or
  /// change the bucket (a concurrent writer).
  beforeWrite: ((key: string, body: string) => void) | null = null;
  /// Rewrites what a create stores (a corrupting write).
  mangle: ((key: string, body: string) => string) | null = null;
  refuseBudget = false;

  put(key: string, body: string) { this.objects.set(key, { body, etag: `"v${++this.version}"` }); }

  deps(): PublishDeps {
    return {
      cut: () => { this.cuts += 1; return Promise.resolve({ cut: this.cut, ms: 900 }); },
      now: () => this.clock,
      get: (key) => Promise.resolve(this.objects.get(key) ?? null),
      create: (key, body) => {
        this.beforeWrite?.(key, body);
        if (this.objects.has(key)) return Promise.resolve("exists" as const);
        this.put(key, this.mangle ? this.mangle(key, body) : body);
        return Promise.resolve("created" as const);
      },
      replace: (key, body, etag) => {
        this.beforeWrite?.(key, body);
        const held = this.objects.get(key);
        if ((etag === null && held) || (etag !== null && held?.etag !== etag)) return Promise.resolve("conflict" as const);
        this.put(key, body);
        return Promise.resolve("replaced" as const);
      },
      reserve: (writes) => {
        if (this.refuseBudget) return Promise.reject(new Error("r2 budget refused"));
        this.reserved += writes;
        return Promise.resolve();
      },
    };
  }

  keys(prefix: string) { return [...this.objects.keys()].filter((k) => k.includes(prefix)); }
}

/// Every object a published generation names is there and right.
async function assertWhole(bucket: Bucket, manifest: string) {
  const held = bucket.objects.get(manifestKey(manifest))!;
  assertEquals(await digestOf(held.body), manifest);
  for (const o of referencedObjects(JSON.parse(held.body))) {
    assertEquals(await digestOf(bucket.objects.get(o.key)!.body), o.digest, o.key);
  }
}

Deno.test("edges are ordered by what they say, not by how they were serialized", () => {
  const edges = (makeCut().nodes!["artist:dean blunt"].edges as Record<string, unknown>[]);
  const reversed = { status: "found", edges: [...edges].reverse(), identities: [] };
  assertEquals(normalizeAnswer(reversed), normalizeAnswer({ status: "found", edges, identities: [] }));
  // Keys in another order are the same edge, in the same place.
  const shuffled = edges.map((e) => Object.fromEntries(Object.entries(e).reverse()));
  assertEquals((normalizeAnswer({ edges: shuffled }).edges as unknown[]).map((e) => JSON.stringify(e, Object.keys(e as object).sort())),
    (normalizeAnswer({ edges }).edges as unknown[]).map((e) => JSON.stringify(e, Object.keys(e as object).sort())));
  // Nothing dropped; same-named targets ordered by row.
  const twins = [
    { kind: "sharedLabel", confidence: 0.8, reason: "x", to: { kind: "artist", name: "Speedy J", rowID: "row-b" } },
    { kind: "sharedLabel", confidence: 0.8, reason: "x", to: { kind: "artist", name: "Speedy J", rowID: "row-a" } },
  ];
  assertEquals([...twins].sort(compareEdges).map((e) => e.to.rowID), ["row-a", "row-b"]);
  assertEquals(normalizeAnswer({ edges: twins }).edges, [twins[1], twins[0]]);
});

Deno.test("shuffled SQL output publishes the same answers", async () => {
  const a = await planGeneration({ cut: makeCut(), demand, bundleRefs: new Map(), current: null, publishedAt: "", cutMs: 0 });
  const shuffledCut = makeCut();
  for (const answer of Object.values(shuffledCut.nodes!)) (answer.edges as unknown[]).reverse();
  const b = await planGeneration({ cut: shuffledCut, demand, bundleRefs: new Map(), current: null, publishedAt: "", cutMs: 0 });
  assertEquals(a.manifestDigest, b.manifestDigest);
});

Deno.test("a publication writes everything, verified, in order, and lists the day", async () => {
  const bucket = new Bucket();
  const order: string[] = [];
  bucket.beforeWrite = (key) => order.push(key);
  const report = await publishGeneration(bucket.deps(), demand);
  assertEquals(report.status, "published");
  assertEquals(report.conditionalWrites, "enforced");
  await assertWhole(bucket, report.manifest!);
  // Objects, then the manifest (and the probe), then the day, then the list.
  const manifestAt = order.indexOf(manifestKey(report.manifest!));
  assert(order.slice(0, manifestAt).every((k) => k.includes("/objects/") || k.includes("/identity/")));
  assertEquals(order.slice(-2), [dayKey(DAY), CURRENT_KEY]);
  const current = JSON.parse(bucket.objects.get(CURRENT_KEY)!.body);
  assertEquals(current.generations, [{ date: DAY, manifest: report.manifest }]);
  assertEquals(JSON.parse(bucket.objects.get(dayKey(DAY))!.body).manifest, report.manifest);
  const manifest = JSON.parse(bucket.objects.get(manifestKey(report.manifest!))!.body);
  assertEquals(manifest.publication.complete, true);
  // Coverage stays apart from completeness: no bundles at all is still complete.
  assertEquals(manifest.summary.bundles, { complete: 0, partial: 0, missing: 3, noIdentity: 13 });
});

Deno.test("publishing twice is a no-op the second time", async () => {
  const bucket = new Bucket();
  const first = await publishGeneration(bucket.deps(), demand);
  const before = new Map(bucket.objects);
  const second = await publishGeneration(bucket.deps(), demand);
  assertEquals(second.status, "already-published");
  assertEquals(second.manifest, first.manifest);
  assertEquals(bucket.objects, before);
  assertEquals(bucket.cuts, 1);
  assertEquals(second.usage.creates + second.usage.replaces, 0);
});

Deno.test("an interrupted object write leaves nothing visible, and a retry reuses what landed", async () => {
  const bucket = new Bucket();
  let writes = 0;
  bucket.beforeWrite = (key) => { if (key.includes("/objects/") && ++writes === 40) throw new Error("connection reset"); };
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "connection reset");
  assertEquals(bucket.keys("/manifests/"), []);
  assertEquals(bucket.keys("/days/"), []);
  assert(!bucket.objects.has(CURRENT_KEY));
  const landed = bucket.keys("/objects/").length;
  assert(landed >= 32 && landed < 177, `${landed}`);

  bucket.beforeWrite = null;
  const retry = await publishGeneration(bucket.deps(), demand);
  assertEquals(retry.status, "published");
  assertEquals(retry.objects!.reused, landed);
  assertEquals(bucket.keys("/objects/").length, 177);
  await assertWhole(bucket, retry.manifest!);
});

Deno.test("a corrupt object already at a digest's key blocks publication", async () => {
  const bucket = new Bucket();
  const plan = await planGeneration({ cut: bucket.cut, demand, bundleRefs: new Map(), current: null, publishedAt: "", cutMs: 0 });
  const victim = plan.addressed.find((o) => o.kind === "artist")!;
  bucket.put(victim.key, victim.body.replace("Ambient", "Ambiant"));
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "do not match their digest");
  assertEquals(bucket.objects.get(victim.key)!.body.includes("Ambiant"), true);
  assertEquals(bucket.keys("/manifests/"), []);
  assertEquals(bucket.keys("/days/"), []);
});

Deno.test("a write that reads back wrong blocks publication", async () => {
  const bucket = new Bucket();
  bucket.mangle = (key, body) => key.includes("/objects/") ? body + " " : body;
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "read back corrupt");
  assertEquals(bucket.keys("/days/"), []);
});

Deno.test("a manifest that fails verification is never committed", async () => {
  const bucket = new Bucket();
  bucket.mangle = (key, body) => key.includes("/manifests/") ? body.replace('"complete":true', '"complete":false') : body;
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "write-manifest");
  assertEquals(bucket.keys("/days/"), []);
  assert(!bucket.objects.has(CURRENT_KEY));
});

Deno.test("a pinned bundle that is not what its reference says blocks publication", async () => {
  const bucket = new Bucket();
  const digest = "d".repeat(64);
  bucket.put(artistRefKey(2419343), JSON.stringify({ digest, key: bundleKey(digest), source: { complete: true } }));
  bucket.put(bundleKey(digest), "{}");
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "bundle 2419343");
  assertEquals(bucket.keys("/manifests/"), []);
});

Deno.test("missing and partial bundles are recorded and published", async () => {
  const bucket = new Bucket();
  const body = '{"bundle":"dean"}', digest = await digestOf(body);
  bucket.put(artistRefKey(2419343), JSON.stringify({ digest, key: bundleKey(digest), source: { complete: false, documentsRead: 3, representativeReleases: 9 } }));
  bucket.put(bundleKey(digest), body);
  const report = await publishGeneration(bucket.deps(), demand);
  assertEquals(report.status, "published");
  const manifest = JSON.parse(bucket.objects.get(manifestKey(report.manifest!))!.body);
  assertEquals(manifest.nodes["artist:dean blunt"].bundles, [{ discogsID: 2419343, status: "partial", digest, read: 3, of: 9 }]);
  assertEquals(manifest.nodes["artist:speedy j"].bundles.map((b: { status: string }) => b.status), ["missing", "missing"]);
  assert(referencedObjects(manifest).some((o) => o.key === bundleKey(digest)));
});

Deno.test("a day published meanwhile is never overwritten", async () => {
  const bucket = new Bucket();
  const theirs = JSON.stringify({ format: "indigo.knowledge-day/1", date: DAY, manifest: "f".repeat(64), publishedAt: "x" });
  bucket.beforeWrite = (key) => { if (key === dayKey(DAY) && !bucket.objects.has(key)) bucket.put(key, theirs); };
  const report = await publishGeneration(bucket.deps(), demand);
  assertEquals(report.status, "conflict");
  assertEquals(bucket.objects.get(dayKey(DAY))!.body, theirs);
  assert(!bucket.objects.has(CURRENT_KEY));
});

Deno.test("a day that names a broken generation is not advertised", async () => {
  const bucket = new Bucket();
  bucket.put(dayKey(DAY), JSON.stringify({ manifest: "f".repeat(64) }));
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "verify-published");
  assert(!bucket.objects.has(CURRENT_KEY));
  assertEquals(bucket.cuts, 0);
});

Deno.test("an interrupted current.json update is finished by the retry, once", async () => {
  const bucket = new Bucket();
  bucket.put(CURRENT_KEY, JSON.stringify({ format: "indigo.knowledge-current/1", generations: [{ date: "2026-10-11", manifest: "a".repeat(64) }],
    withdrawn: [{ date: "2026-10-09", reason: "bad edges" }], note: "kept" }));
  bucket.beforeWrite = (key) => { if (key === CURRENT_KEY) throw new Error("worker killed"); };
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "worker killed");
  assert(bucket.objects.has(dayKey(DAY)));
  assertEquals(JSON.parse(bucket.objects.get(CURRENT_KEY)!.body).generations.length, 1);

  bucket.beforeWrite = null;
  const retry = await publishGeneration(bucket.deps(), demand);
  assertEquals(retry.status, "resumed");
  assertEquals(bucket.cuts, 1);
  const current = JSON.parse(bucket.objects.get(CURRENT_KEY)!.body);
  assertEquals(current.generations.map((g: { date: string }) => g.date), [DAY, "2026-10-11"]);
  assertEquals(current.withdrawn, [{ date: "2026-10-09", reason: "bad edges" }]);
  assertEquals(current.note, "kept");
  assertEquals((await publishGeneration(bucket.deps(), demand)).status, "already-published");
});

Deno.test("a concurrent current.json change is merged, not lost", async () => {
  const bucket = new Bucket();
  bucket.put(CURRENT_KEY, JSON.stringify({ generations: [], withdrawn: [] }));
  let once = true;
  bucket.beforeWrite = (key) => {
    if (key === CURRENT_KEY && once) {
      once = false;
      bucket.put(CURRENT_KEY, JSON.stringify({ generations: [], withdrawn: [{ date: "2026-10-10", reason: "revoked meanwhile" }] }));
    }
  };
  const report = await publishGeneration(bucket.deps(), demand);
  assertEquals(report.status, "published");
  const current = JSON.parse(bucket.objects.get(CURRENT_KEY)!.body);
  assertEquals(current.withdrawn, [{ date: "2026-10-10", reason: "revoked meanwhile" }]);
  assertEquals(current.generations[0].date, DAY);
});

Deno.test("a withdrawn day is not listed again", async () => {
  const bucket = new Bucket();
  bucket.put(CURRENT_KEY, JSON.stringify({ generations: [], withdrawn: [{ date: DAY, reason: "test" }] }));
  await assertRejectsWith(publishGeneration(bucket.deps(), demand), "was withdrawn");
  assertEquals(JSON.parse(bucket.objects.get(CURRENT_KEY)!.body).generations, []);
});

Deno.test("a refused cut or a refused budget writes nothing", async () => {
  const refused = new Bucket();
  refused.cut = makeCut({ status: "refused", reason: "no-completed-rebuild-today", nodes: null, artists: null });
  assertEquals((await publishGeneration(refused.deps(), demand)).status, "refused");
  assertEquals(refused.objects.size, 0);
  const broke = new Bucket();
  broke.refuseBudget = true;
  await assertRejectsWith(publishGeneration(broke.deps(), demand), "budget refused");
  assertEquals(broke.objects.size, 0);
});

Deno.test("an R2 that ignores create-only is caught before the day is written", async () => {
  const bucket = new Bucket();
  const deps = bucket.deps();
  const lax: PublishDeps = { ...deps, create: (key, body) => { bucket.put(key, body); return Promise.resolve("created"); } };
  await assertRejectsWith(publishGeneration(lax, demand), "probe-conditional-write");
  assertEquals(bucket.keys("/days/"), []);
});

async function assertRejectsWith(promise: Promise<unknown>, text: string) {
  try {
    await promise;
  } catch (error) {
    assert(String(error).includes(text), `expected "${text}", got ${error}`);
    return;
  }
  throw new Error(`expected a rejection with "${text}"`);
}



