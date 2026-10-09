// Discography discovery and bundle publishing, against an R2, a Discogs and a
// queue that live in the test. Built from real documents (Kate NV and Dean
// Blunt, both in the pilot), paginated the way Discogs paginates.
//
//     deno test supabase/functions/_shared/knowledge_test.ts

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import kateNV from "./testdata/artist_bundle/5302639.json" with { type: "json" };
import deanBlunt from "./testdata/artist_bundle/2419343.json" with { type: "json" };
import type { BundleInput, DiscogsReleaseDoc, ShelfEntry } from "./artist_bundle.ts";
import { MAX_PAGES, PAGES_PER_JOB } from "./discography.ts";
import {
  ArtistJob, ArtistRef, artistRefKey, buildArtistBundle, DiscographyRef, discographyRefKey, discoverDiscography, KnowledgeDeps,
  MISSING_DOCUMENTS_BUDGET, releaseDocumentKey, settleBatches,
} from "./knowledge.ts";

const KATE = { discogsID: 5302639, name: "Kate NV", identity: "backend" as const };
const DEAN = { discogsID: 2419343, name: "Dean Blunt", identity: "backend" as const };

/// Everything outside the code under test, in memory.
class World {
  r2 = new Map<string, string>();
  queue: { type: string; key: string; payload: Record<string, unknown> }[] = [];
  fetched: number[] = [];
  failPages = new Set<number>();
  failPut: ((key: string) => boolean) | null = null;
  pending = new Set<number>();
  /// Releases the catalogue files under the artist (other pressings).
  own: number[] = [];
  clock = new Date("2026-10-09T12:00:00Z");

  constructor(public lines: ShelfEntry[], public perPage: number, documents: DiscogsReleaseDoc[], public reportedPages?: number) {
    for (const doc of documents) this.r2.set(releaseDocumentKey(doc.id!), JSON.stringify(doc));
  }

  get pages(): number { return this.reportedPages ?? Math.max(1, Math.ceil(this.lines.length / this.perPage)); }

  deps(): KnowledgeDeps {
    return {
      fetchPage: (_id, page) => {
        this.fetched.push(page);
        if (this.failPages.has(page)) return Promise.resolve({ status: 502 });
        const releases = this.lines.slice((page - 1) * this.perPage, page * this.perPage);
        return Promise.resolve({
          status: 200,
          body: { pagination: { page, pages: this.pages, items: this.reportedPages ? this.reportedPages * this.perPage : this.lines.length, per_page: this.perPage }, releases },
        });
      },
      getObject: (key) => Promise.resolve(this.r2.get(key) ?? null),
      putObject: (key, body) => {
        if (this.failPut?.(key)) return Promise.reject(new Error(`r2 put failed: ${key}`));
        this.r2.set(key, body);
        return Promise.resolve();
      },
      reserve: () => Promise.resolve(),
      cachedReleases: (ids) => Promise.resolve(new Set(ids.filter((id) => this.r2.has(releaseDocumentKey(id))))),
      pendingReleases: (ids) => Promise.resolve(new Set(ids.filter((id) => this.pending.has(id)))),
      ownCachedReleases: () => Promise.resolve(this.own.filter((id) => this.r2.has(releaseDocumentKey(id)))),
      enqueue: (type, key, payload) => { this.queue.push({ type, key, payload }); return Promise.resolve(); },
      now: () => this.clock,
    };
  }

  /// Runs the discovery jobs it queued for itself until the discovery is done.
  async discoverAll(job: ArtistJob = KATE): Promise<number> {
    let runs = 0;
    let result = await discoverDiscography(this.deps(), job);
    runs += 1;
    while (result.status === "progress") {
      result = await discoverDiscography(this.deps(), job);
      runs += 1;
    }
    return runs;
  }

  ref<T>(key: string): T | null {
    const text = this.r2.get(key);
    return text ? JSON.parse(text) as T : null;
  }
}

function fixtureWorld(fixture: unknown, perPage: number, keepDocuments = (_: DiscogsReleaseDoc) => true, reportedPages?: number) {
  const input = structuredClone(fixture) as BundleInput;
  return new World(input.shelf?.releases ?? [], perPage, input.releases.filter(keepDocuments), reportedPages);
}

// MARK: Discovery

Deno.test("a discography is read to its last page, a few pages a job, and published once", async () => {
  const world = fixtureWorld(kateNV, 7); // 41 lines, 6 pages
  const runs = await world.discoverAll();
  assertEquals(runs, Math.ceil(6 / PAGES_PER_JOB));
  assertEquals(world.fetched, [1, 2, 3, 4, 5, 6]);
  const ref = world.ref<DiscographyRef>(discographyRefKey(KATE.discogsID))!;
  assertEquals(ref.complete, true);
  assertEquals(ref.truncated, false);
  assertEquals(ref.pagesFetched, 6);
  assertEquals(ref.totalReported, 41);
  assertEquals(ref.usage.discogsCalls, 6, "usage is carried across the jobs");
  assert(world.queue.some((q) => q.type === "discover_discography" && q.key === `${KATE.discogsID}:p4`));
  assertEquals(world.queue.filter((q) => q.type === "build_artist_bundle").length, 1);
});

Deno.test("a page that fails is fetched again, and the pages before it are not", async () => {
  const world = fixtureWorld(kateNV, 7);
  world.failPages.add(2);
  await assertRejects(() => discoverDiscography(world.deps(), KATE));
  assertEquals(world.fetched, [1, 2]);
  assertEquals(world.ref(discographyRefKey(KATE.discogsID)), null, "nothing is published from half a discography");
  world.failPages.clear();
  await world.discoverAll();
  assertEquals(world.fetched, [1, 2, 2, 3, 4, 5, 6], "it resumed at page 2");
  assertEquals(world.ref<DiscographyRef>(discographyRefKey(KATE.discogsID))!.complete, true);
});

Deno.test("past the page cap, the discography is published as truncated, not read forever", async () => {
  const world = fixtureWorld(deanBlunt, 3, () => true, MAX_PAGES + 2);
  await world.discoverAll(DEAN);
  const ref = world.ref<DiscographyRef>(discographyRefKey(DEAN.discogsID))!;
  assertEquals(ref.truncated, true);
  assertEquals(ref.complete, false);
  assertEquals(ref.pagesFetched, MAX_PAGES);
  assertEquals(world.fetched.length, MAX_PAGES);
});

Deno.test("documents R2 lacks are queued within the budget, without the ones already waiting", async () => {
  // Half of Dean Blunt's documents are missing from R2; one is already queued.
  const world = fixtureWorld(deanBlunt, 25, (doc) => doc.id! % 2 === 0);
  const missingOdd = (structuredClone(deanBlunt) as BundleInput).releases.map((d) => d.id!).filter((id) => id % 2 === 1);
  world.pending.add(missingOdd[0]);
  await world.discoverAll(DEAN);
  const ref = world.ref<DiscographyRef>(discographyRefKey(DEAN.discogsID))!;
  const queued = world.queue.filter((q) => q.type === "cache_discogs_release");
  assert(ref.documentsMissing > 0);
  assertEquals(queued.length, Math.min(MISSING_DOCUMENTS_BUDGET, ref.documentsMissing - 1));
  assert(!queued.some((q) => q.key === String(missingOdd[0])), "a release already waiting is not queued twice");
  const notify = queued[0].payload.notify as { batch: number[] };
  assertEquals(notify.batch.length, queued.length, "each knows its batch");
});

Deno.test("a discography read recently is not read again unless forced", async () => {
  const world = fixtureWorld(kateNV, 50);
  await world.discoverAll();
  const calls = world.fetched.length;
  const again = await discoverDiscography(world.deps(), KATE);
  assertEquals(again.status, "fresh");
  assertEquals(world.fetched.length, calls);
  await world.discoverAll({ ...KATE, force: true });
  assertEquals(world.fetched.length, calls * 2);
});

// MARK: Building

Deno.test("a build publishes a verified bundle, and building again from the same inputs writes nothing", async () => {
  const world = fixtureWorld(kateNV, 50);
  await world.discoverAll();
  const first = await buildArtistBundle(world.deps(), KATE);
  assertEquals(first.status, "published");
  const ref = world.ref<ArtistRef>(artistRefKey(KATE.discogsID))!;
  assert(world.r2.has(ref.key));
  assertEquals(ref.source.complete, true);
  assert(ref.source.documentsRead > 0);
  const puts = world.r2.size;
  const second = await buildArtistBundle(world.deps(), KATE);
  assertEquals(second.status, "unchanged");
  assertEquals(world.r2.size, puts);
});

Deno.test("a bundle that fails to publish leaves the previous one in place", async () => {
  const world = fixtureWorld(kateNV, 50, (doc) => doc.id! % 3 !== 0);
  await world.discoverAll();
  await buildArtistBundle(world.deps(), KATE);
  const before = world.ref<ArtistRef>(artistRefKey(KATE.discogsID))!;

  // New documents arrive, so the next bundle differs -- and its upload fails.
  for (const doc of (structuredClone(kateNV) as BundleInput).releases) world.r2.set(releaseDocumentKey(doc.id!), JSON.stringify(doc));
  world.failPut = (key) => key.includes("/bundles/");
  await assertRejects(() => buildArtistBundle(world.deps(), KATE));
  assertEquals(world.ref<ArtistRef>(artistRefKey(KATE.discogsID))!.digest, before.digest);
  assert(world.r2.has(before.key), "the previous bundle is still there");

  // And one that uploads but reads back wrong is not pointed at either.
  world.failPut = null;
  const put = world.deps().putObject;
  const corrupting: KnowledgeDeps = { ...world.deps(), putObject: (key, body) => put(key, key.includes("/bundles/") ? body + " " : body) };
  await assertRejects(() => buildArtistBundle(corrupting, KATE));
  assertEquals(world.ref<ArtistRef>(artistRefKey(KATE.discogsID))!.digest, before.digest);

  // Once it can, it publishes.
  const after = await buildArtistBundle(world.deps(), KATE);
  assertEquals(after.status, "published");
  if (after.status === "published") assertEquals(after.previous, before.digest);
});

Deno.test("pressings of one record are read but counted once", async () => {
  // Dean Blunt's fixture holds several pressings of the same masters.
  const world = fixtureWorld(deanBlunt, 50);
  await world.discoverAll(DEAN);
  await buildArtistBundle(world.deps(), DEAN);
  const ref = world.ref<ArtistRef>(artistRefKey(DEAN.discogsID))!;
  const bundle = JSON.parse(world.r2.get(ref.key)!);
  const masters = bundle.releases.map((r: { masterID: number | null }) => r.masterID).filter((m: number | null) => m !== null);
  assertEquals(new Set(masters).size, masters.length, "one record per master");
});

Deno.test("a discography listing a release twice, under two roles, keeps both roles and one document", async () => {
  const input = structuredClone(kateNV) as BundleInput;
  const lines = input.shelf!.releases!;
  const twice = [...lines, { ...lines[0], role: "Remix" }, lines[1]];
  const world = new World(twice, 50, input.releases);
  await world.discoverAll();
  const ref = world.ref<DiscographyRef>(discographyRefKey(KATE.discogsID))!;
  assertEquals(ref.entries, lines.length + (lines[0].role === "Remix" ? 0 : 1));
  assertEquals(ref.representativeReleases, new Set(lines.map((l) => l.type === "master" ? l.main_release : l.id)).size);
});

// MARK: Documents arriving

Deno.test("a batch claimed together is settled after its run is written back, once", async () => {
  // The worker claims a whole batch at once; until it flushes, every job in
  // it is still marked running. Settling inside the run would see that and
  // queue nothing -- which is what happened in the pilot.
  const world = fixtureWorld(kateNV, 50);
  const notify = (batch: number[]) => ({ discogs_id: "5302639", name: "Kate NV", identity: "backend", batch });
  world.pending = new Set([1, 2, 3]);
  assertEquals(await settleBatches(world.deps(), [notify([1, 2, 3])]), [], "mid-run: the batch looks busy");

  // After the flush the finished jobs are gone. Three notifications from one
  // run, one build.
  world.pending = new Set();
  assertEquals(await settleBatches(world.deps(), [notify([1, 2, 3]), notify([1, 2, 3]), notify([1, 2, 3])]), [5302639]);
  assertEquals(world.queue.map((q) => q.type), ["build_artist_bundle"]);
  assertEquals(world.fetched.length, 0, "never a discovery");

  // A run that finishes only part of a batch leaves the rest to whichever
  // run finishes last.
  world.queue = [];
  world.pending = new Set([3]);
  assertEquals(await settleBatches(world.deps(), [notify([1, 2, 3])]), []);
  assertEquals(await settleBatches(world.deps(), []), []);
});

Deno.test("another pressing already in R2 is read, and its credits reach the bundle", async () => {
  // A pressing of one of Kate NV's records, not the one her discography
  // names, carrying a credit the main release lacks.
  const input = structuredClone(kateNV) as BundleInput;
  const main = input.releases.find((d) => (d.artists ?? []).some((a) => a.id === 5302639) && typeof d.master_id === "number")!;
  const pressing: DiscogsReleaseDoc = {
    ...structuredClone(main), id: 999_000_001,
    extraartists: [...(main.extraartists ?? []), { id: 424242, name: "Somebody On Another Pressing", role: "Mastered By" }],
  };
  const world = fixtureWorld(kateNV, 50);
  world.r2.set(releaseDocumentKey(pressing.id!), JSON.stringify(pressing));
  world.own = [pressing.id!];
  await world.discoverAll();
  await buildArtistBundle(world.deps(), KATE);
  const ref = world.ref<ArtistRef>(artistRefKey(KATE.discogsID))!;
  const bundle = JSON.parse(world.r2.get(ref.key)!);
  assertEquals(ref.source.otherPressingsRead, 1);
  assert(bundle.credits.some((c: { artist: { discogsID: number } }) => c.artist.discogsID === 424242));
  assert(!bundle.releases.some((r: { id: number }) => r.id === pressing.id), "it is one record with its main release");
});

Deno.test("nothing outside the pilot is discovered or built", async () => {
  const world = fixtureWorld(kateNV, 50);
  await assertRejects(() => discoverDiscography(world.deps(), { discogsID: 306157, name: "Burial", identity: "backend" }));
  await assertRejects(() => buildArtistBundle(world.deps(), { discogsID: 306157, name: "Burial", identity: "backend" }));
  assertEquals(world.fetched.length, 0);
});
