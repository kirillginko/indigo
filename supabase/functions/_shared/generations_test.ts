// The generation publisher's dry run, against a cut and an R2 that live in the
// test. The cut answers the frozen pilot demand set (24 nodes, 163 artists),
// shaped as 0075 answers it.
//
//     deno test supabase/functions/_shared/generations_test.ts

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import pilot from "./testdata/pilot_demand_v1.json" with { type: "json" };
import { artistRefKey } from "./knowledge.ts";
import {
  bundleIDs, CURRENT_KEY, Cut, cutProblems, dayKey, Demand, dryRunGeneration, GenerationReadDeps, identitySnapshot,
  PILOT_DEMAND_DIGEST, planGeneration,
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
