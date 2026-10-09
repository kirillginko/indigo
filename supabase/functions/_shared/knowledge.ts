// Discovering an artist's discography, and building their knowledge bundle
// from it -- two jobs, each resumable, each testable without a network.
//
// discover_discography: reads the artist's Discogs discography page by page
// (PAGES_PER_JOB at a time, paced like every other Discogs request), keeping
// each page in R2 as it arrives and the progress in a small state object, so a
// failure or a timeout resumes where it stopped. When every page is in -- or
// the cap is reached -- the pages become one immutable discography snapshot,
// the artist's discography reference is moved to it, the release documents R2
// does not have are queued within a budget, and a build is queued.
//
// build_artist_bundle: reads the current discography snapshot and the
// documents R2 has for it, builds the bundle with the A1 builder, stores it
// under its digest, reads it back to check it, and only then moves the
// artist's bundle reference. Anything that fails before the last step leaves
// the previous reference -- and the bundle it names -- exactly as they were.
// A bundle identical to the current one writes nothing.
//
// Neither re-fetches what it does not need: a newly cached release asks for a
// build, never for the discography again; a discography younger than its
// lifetime is not read again unless forced.
//
// Objects in R2, under knowledge/v1/:
//   pages/<aa>/<digest>.json           one discography page, as Discogs sent it
//   discographies/<aa>/<digest>.json   a whole discography snapshot
//   bundles/<aa>/<digest>.json         an artist knowledge bundle (A1)
//   refs/discographies/<artist>.json   the current snapshot, and its coverage
//   refs/artists/<artist>.json         the current bundle, and its coverage
//   state/discovery/<artist>.json      a discovery in progress
// Content-addressed objects are never overwritten or deleted here; the two
// refs and the state are the only objects that change.

import {
  BundleSource, bundleKey, canonicalJSON, deriveArtistBundle, DiscogsReleaseDoc,
} from "./artist_bundle.ts";
import {
  asShelf, assembleDiscography, Discography, DiscographyPage, MAX_PAGES, PAGES_PER_JOB, PER_PAGE, readPage,
  representativeReleases,
} from "./discography.ts";

export const KNOWLEDGE_ROOT = "knowledge/v1";
/// A discography is read again after this, not before (unless forced).
export const DISCOGRAPHY_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
/// The most missing release documents one discovery queues.
export const MISSING_DOCUMENTS_BUDGET = 40;
/// The most documents one build reads, and how many at once.
export const MAX_DOCUMENTS = 500;
export const READ_CONCURRENCY = 8;

/// The pilot: the For You shadow's artist starting points on the Mac it was
/// measured on, by Discogs id. Nothing else is discovered or built until the
/// pilot has been reviewed.
export const PILOT_ARTISTS = new Set([
  357122, // Eric Kloss
  1982320, // Anika (identity from a device's cache)
  7635391, // Ciro Vitiello
  2419343, // Dean Blunt
  1874027, // Hype Williams (identity from a device's cache)
  5302639, // Kate NV
]);

export interface KnowledgeDeps {
  fetchPage(discogsID: number, page: number, perPage: number): Promise<{ status: number; body?: unknown }>;
  getObject(key: string): Promise<string | null>;
  putObject(key: string, body: string): Promise<void>;
  /// Reserves R2 writes in the budget, or throws.
  reserve(writes: number, bytes: number): Promise<void>;
  /// Which of these releases have documents in R2.
  cachedReleases(ids: number[]): Promise<Set<number>>;
  /// Which of these releases already have a cache job waiting or running.
  pendingReleases(ids: number[]): Promise<Set<number>>;
  /// Releases Indigo has filed under this artist whose documents R2 holds --
  /// often other pressings of the records the discography names, which carry
  /// credits the main release does not. Empty for an artist the catalogue does
  /// not know by Discogs id.
  ownCachedReleases(discogsID: number): Promise<number[]>;
  enqueue(jobType: string, dedupeKey: string, payload: Record<string, unknown>, priority: number): Promise<void>;
  now(): Date;
}

/// What one job cost, kept with what it wrote.
export interface Usage {
  discogsCalls: number;
  r2Gets: number;
  r2Puts: number;
  r2BytesWritten: number;
  enqueued: number;
}

/// The same dependencies, counting.
export function counting(deps: KnowledgeDeps): { deps: KnowledgeDeps; usage: Usage } {
  const usage: Usage = { discogsCalls: 0, r2Gets: 0, r2Puts: 0, r2BytesWritten: 0, enqueued: 0 };
  return {
    usage,
    deps: {
      ...deps,
      fetchPage: (id, page, per) => { usage.discogsCalls += 1; return deps.fetchPage(id, page, per); },
      getObject: (key) => { usage.r2Gets += 1; return deps.getObject(key); },
      putObject: (key, body) => {
        usage.r2Puts += 1;
        usage.r2BytesWritten += new TextEncoder().encode(body).length;
        return deps.putObject(key, body);
      },
      enqueue: (type, key, payload, priority) => { usage.enqueued += 1; return deps.enqueue(type, key, payload, priority); },
    },
  };
}

export interface ArtistJob {
  discogsID: number;
  name: string;
  identity: "backend" | "device-cache";
  force?: boolean;
}

export async function sha256(text: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const addressed = (kind: string, digest: string) => `${KNOWLEDGE_ROOT}/${kind}/${digest.slice(0, 2)}/${digest}.json`;
export const discographyRefKey = (id: number) => `${KNOWLEDGE_ROOT}/refs/discographies/${id}.json`;
export const artistRefKey = (id: number) => `${KNOWLEDGE_ROOT}/refs/artists/${id}.json`;
export const discoveryStateKey = (id: number) => `${KNOWLEDGE_ROOT}/state/discovery/${id}.json`;
export const releaseDocumentKey = (id: number) => `releases/${id}.json`;

async function readJSON<T>(deps: KnowledgeDeps, key: string): Promise<T | null> {
  const text = await deps.getObject(key);
  if (text === null) return null;
  try {
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

async function put(deps: KnowledgeDeps, key: string, text: string): Promise<void> {
  await deps.reserve(1, new TextEncoder().encode(text).length);
  await deps.putObject(key, text);
}

/// Stores content under its digest, unless it is there already, and reads it
/// back to check it before anybody is pointed at it.
async function putAddressed(deps: KnowledgeDeps, kind: string, text: string): Promise<{ digest: string; key: string }> {
  const digest = await sha256(text);
  const key = addressed(kind, digest);
  const held = await deps.getObject(key);
  if (held === null || (await sha256(held)) !== digest) {
    await put(deps, key, text);
    const back = await deps.getObject(key);
    if (back === null || (await sha256(back)) !== digest) {
      throw new Error(`r2: ${key} did not read back as written`);
    }
  }
  return { digest, key };
}

// MARK: - Discovery

export interface DiscographyRef {
  format: string;
  artist: number;
  digest: string;
  key: string;
  publishedAt: string;
  identity: "backend" | "device-cache";
  totalReported: number | null;
  pagesReported: number | null;
  pagesFetched: number;
  complete: boolean;
  truncated: boolean;
  entries: number;
  representativeReleases: number;
  documentsAvailable: number;
  documentsMissing: number;
  documentsQueued: number;
  usage: Usage;
}

interface DiscoveryState {
  startedAt: string;
  pagesReported: number | null;
  /// Page number to the key its content is kept under.
  pages: Record<string, string>;
  usage: Usage;
}

export type DiscoveryResult =
  | { status: "fresh"; ref: DiscographyRef }
  | { status: "progress"; pagesFetched: number; pagesReported: number | null; next: number }
  | { status: "unknown-artist" }
  | { status: "published"; ref: DiscographyRef };

export async function discoverDiscography(base: KnowledgeDeps, job: ArtistJob): Promise<DiscoveryResult> {
  if (!PILOT_ARTISTS.has(job.discogsID)) throw new Error(`knowledge: ${job.discogsID} is not in the pilot`);
  const { deps, usage } = counting(base);
  const now = deps.now();

  const current = await readJSON<DiscographyRef>(deps, discographyRefKey(job.discogsID));
  if (current && !job.force && now.getTime() - Date.parse(current.publishedAt) < DISCOGRAPHY_LIFETIME_MS) {
    return { status: "fresh", ref: current };
  }

  const stored = await readJSON<DiscoveryState>(deps, discoveryStateKey(job.discogsID));
  const state: DiscoveryState = stored?.pages
    ? stored
    : { startedAt: now.toISOString(), pagesReported: null, pages: {}, usage: emptyUsage() };

  const wanted = () => Math.min(state.pagesReported ?? 1, MAX_PAGES);
  const nextPage = () => {
    for (let n = 1; n <= wanted(); n++) if (!state.pages[String(n)]) return n;
    return null;
  };

  let fetched = 0;
  for (let page = nextPage(); page !== null && fetched < PAGES_PER_JOB; page = nextPage()) {
    const response = await deps.fetchPage(job.discogsID, page, PER_PAGE);
    if (response.status === 404 && page === 1) return { status: "unknown-artist" };
    if (response.status !== 200) {
      // What was fetched stays; the queue's retry resumes from here.
      await saveState(deps, job.discogsID, state, usage);
      throw new Error(`discogs ${response.status} for page ${page} of artist ${job.discogsID}`);
    }
    const read = readPage(response.body, page);
    if (!read) {
      await saveState(deps, job.discogsID, state, usage);
      throw new Error(`discogs page ${page} of artist ${job.discogsID} is not a discography page`);
    }
    const { key } = await putAddressed(deps, "pages", canonicalJSON(read));
    state.pages[String(page)] = key;
    state.pagesReported = read.pages;
    await saveState(deps, job.discogsID, state, usage);
    fetched += 1;
  }

  const next = nextPage();
  if (next !== null) {
    await deps.enqueue("discover_discography", `${job.discogsID}:p${next}`, jobPayload(job), 5);
    return { status: "progress", pagesFetched: Object.keys(state.pages).length, pagesReported: state.pagesReported, next };
  }

  // Every page there is to read: one snapshot.
  const pages: DiscographyPage[] = [];
  for (const key of Object.values(state.pages)) {
    const page = await readJSON<DiscographyPage>(deps, key);
    if (!page) throw new Error(`r2: discography page ${key} is missing`);
    pages.push(page);
  }
  const discography = assembleDiscography({ discogsID: job.discogsID, name: job.name }, job.identity, pages);
  const { digest, key } = await putAddressed(deps, "discographies", canonicalJSON(discography));

  // The documents R2 does not have, queued within the budget, each telling
  // the build when the last of them has landed.
  const releases = representativeReleases(discography);
  const cached = await deps.cachedReleases(releases);
  const missing = releases.filter((id) => !cached.has(id));
  const pending = await deps.pendingReleases(missing);
  const batch = missing.filter((id) => !pending.has(id)).slice(0, MISSING_DOCUMENTS_BUDGET);
  for (const id of batch) {
    await deps.enqueue("cache_discogs_release", String(id), {
      release_id: String(id),
      notify: { ...jobPayload(job), batch },
    }, 0);
  }

  const total = combine(state.usage, usage);
  const ref: DiscographyRef = {
    format: discography.format, artist: job.discogsID, digest, key, publishedAt: now.toISOString(),
    identity: job.identity, totalReported: discography.totalReported, pagesReported: discography.pagesReported,
    pagesFetched: discography.pagesFetched, complete: discography.complete, truncated: discography.truncated,
    entries: discography.entries.length, representativeReleases: releases.length,
    documentsAvailable: releases.length - missing.length, documentsMissing: missing.length,
    documentsQueued: batch.length, usage: total,
  };
  // The reference moves last: before this line, the previous one stands.
  await put(deps, discographyRefKey(job.discogsID), canonicalJSON(ref));
  await put(deps, discoveryStateKey(job.discogsID), canonicalJSON({ finished: now.toISOString() }));
  await deps.enqueue("build_artist_bundle", String(job.discogsID), jobPayload(job), 5);
  return { status: "published", ref };
}

function emptyUsage(): Usage {
  return { discogsCalls: 0, r2Gets: 0, r2Puts: 0, r2BytesWritten: 0, enqueued: 0 };
}

function combine(a: Usage, b: Usage): Usage {
  return {
    discogsCalls: a.discogsCalls + b.discogsCalls, r2Gets: a.r2Gets + b.r2Gets, r2Puts: a.r2Puts + b.r2Puts,
    r2BytesWritten: a.r2BytesWritten + b.r2BytesWritten, enqueued: a.enqueued + b.enqueued,
  };
}

async function saveState(deps: KnowledgeDeps, id: number, state: DiscoveryState, usage: Usage): Promise<void> {
  // The usage so far, carried across the jobs one discovery takes.
  const carried = { ...state, usage: combine(state.usage, usage) };
  await put(deps, discoveryStateKey(id), canonicalJSON(carried));
}

function jobPayload(job: ArtistJob): Record<string, unknown> {
  return { discogs_id: String(job.discogsID), name: job.name, identity: job.identity };
}

export function readArtistJob(payload: Record<string, unknown> | null): ArtistJob {
  const id = Number(payload?.discogs_id);
  if (!Number.isInteger(id) || id <= 0) throw new Error("knowledge: missing discogs_id");
  const name = String(payload?.name ?? "").trim();
  if (!name) throw new Error("knowledge: missing name");
  const identity = payload?.identity === "device-cache" ? "device-cache" : "backend";
  return { discogsID: id, name, identity, force: payload?.force === true };
}

// MARK: - Building

export interface ArtistRef {
  format: string;
  artist: number;
  digest: string;
  key: string;
  builtAt: string;
  discography: string;
  bytes: number;
  source: BundleSource;
  usage: Usage;
  buildMs: number;
}

export type BuildResult =
  | { status: "no-discography" }
  | { status: "unchanged"; ref: ArtistRef }
  | { status: "published"; ref: ArtistRef; previous: string | null };

export async function buildArtistBundle(base: KnowledgeDeps, job: ArtistJob): Promise<BuildResult> {
  if (!PILOT_ARTISTS.has(job.discogsID)) throw new Error(`knowledge: ${job.discogsID} is not in the pilot`);
  const { deps, usage } = counting(base);
  const started = Date.now();
  const discographyRef = await readJSON<DiscographyRef>(deps, discographyRefKey(job.discogsID));
  if (!discographyRef) return { status: "no-discography" };
  const text = await deps.getObject(discographyRef.key);
  if (text === null || (await sha256(text)) !== discographyRef.digest) {
    throw new Error(`r2: discography ${discographyRef.key} is missing or not what its reference says`);
  }
  const discography = JSON.parse(text) as Discography;

  const releases = representativeReleases(discography);
  const cached = await deps.cachedReleases(releases);
  const available = releases.filter((id) => cached.has(id));
  // And the other pressings already in R2: no Discogs request, more credits.
  // The representatives come first, so the cap never cuts one for a pressing.
  const representatives = new Set(releases);
  const pressings = (await deps.ownCachedReleases(job.discogsID)).filter((id) => !representatives.has(id)).sort((a, b) => a - b);
  const toRead = [...available, ...pressings].slice(0, MAX_DOCUMENTS);
  const pressingsRead = toRead.filter((id) => !representatives.has(id)).length;
  const docs: DiscogsReleaseDoc[] = [];
  for (let i = 0; i < toRead.length; i += READ_CONCURRENCY) {
    const read = await Promise.all(toRead.slice(i, i + READ_CONCURRENCY).map(async (id) => {
      const body = await deps.getObject(releaseDocumentKey(id));
      if (body === null) return null;
      try {
        return JSON.parse(body) as DiscogsReleaseDoc;
      } catch {
        return null;
      }
    }));
    for (const doc of read) if (doc) docs.push(doc);
  }

  const source: BundleSource = {
    identity: discography.identity, discography: discographyRef.digest, complete: discography.complete,
    truncated: discography.truncated, totalReported: discography.totalReported,
    pagesReported: discography.pagesReported, pagesFetched: discography.pagesFetched,
    entries: discography.entries.length, representativeReleases: releases.length,
    documentsRead: docs.length - pressingsRead,
    documentsMissing: releases.length - (docs.length - pressingsRead) - Math.max(0, available.length - toRead.length),
    documentsTruncated: Math.max(0, available.length + pressings.length - toRead.length),
    otherPressingsRead: pressingsRead,
  };
  const bundle = deriveArtistBundle({
    artist: { discogsID: job.discogsID, name: job.name },
    shelf: asShelf(discography), releases: docs, preferred: releases, source,
  });
  const body = canonicalJSON(bundle);
  const digest = await sha256(body);

  const current = await readJSON<ArtistRef>(deps, artistRefKey(job.discogsID));
  if (current?.digest === digest) return { status: "unchanged", ref: current };

  const key = bundleKey(digest);
  // Stored, read back, checked -- and only then pointed at.
  const held = await deps.getObject(key);
  if (held === null || (await sha256(held)) !== digest) {
    await put(deps, key, body);
    const back = await deps.getObject(key);
    if (back === null || (await sha256(back)) !== digest) throw new Error(`r2: bundle ${key} did not read back as written`);
  }
  const ref: ArtistRef = {
    format: bundle.format, artist: job.discogsID, digest, key, builtAt: deps.now().toISOString(),
    discography: discographyRef.digest, bytes: new TextEncoder().encode(body).length, source,
    usage, buildMs: Date.now() - started,
  };
  await put(deps, artistRefKey(job.discogsID), canonicalJSON(ref));
  return { status: "published", ref, previous: current?.digest ?? null };
}

// MARK: - Documents arriving

/// Called by the worker after it has written its finished jobs back, with the
/// batches of the release documents it cached in that run. For each artist
/// whose batch has nothing left waiting or running, queues one build -- never
/// a discovery, never one build per document.
///
/// After the write-back, not per job: a worker claims thirty cache jobs at
/// once and marks them finished only when it flushes, so a job asking "is the
/// rest of my batch done?" from inside the run always saw its neighbours still
/// running, and no build was ever queued. Asked after the flush, the run that
/// finishes the batch last sees it empty.
export async function settleBatches(
  deps: KnowledgeDeps, notifies: (Record<string, unknown> | null | undefined)[],
): Promise<number[]> {
  const byArtist = new Map<number, { job: ArtistJob; batch: Set<number> }>();
  for (const notify of notifies) {
    if (!notify) continue;
    const job = readArtistJob(notify);
    const entry = byArtist.get(job.discogsID) ?? { job, batch: new Set<number>() };
    for (const id of Array.isArray(notify.batch) ? notify.batch : []) {
      if (Number.isInteger(Number(id))) entry.batch.add(Number(id));
    }
    byArtist.set(job.discogsID, entry);
  }
  const queued: number[] = [];
  for (const [artist, { job, batch }] of [...byArtist.entries()].sort(([a], [b]) => a - b)) {
    const pending = batch.size ? await deps.pendingReleases([...batch]) : new Set<number>();
    if (pending.size > 0) continue;
    await deps.enqueue("build_artist_bundle", String(artist), jobPayload(job), 5);
    queued.push(artist);
  }
  return queued;
}
