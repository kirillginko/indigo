// Immutable knowledge generations (SHARED-KNOWLEDGE.md §9) -- the publisher,
// in dry run only.
//
// A generation is one UTC day's answers for the demand set, every one of them
// read by one `knowledge_cut` statement (0075), split into content-addressed
// objects and named by a manifest. Publishing it is §9.6's seven steps; this
// file builds everything those steps would write and reports what writing it
// would cost -- and writes nothing. Its dependencies have no way to write:
// `GenerationReadDeps` is the cut, R2 reads and existence checks, and a clock.
//
// The plan (`planGeneration`) is pure: the same cut and the same bundle
// references give the same objects, digests and manifest, byte for byte.
//
// Objects, under knowledge/v1/generations/ (none of them written here):
//   objects/<aa>/<digest>.json     one entity's answer
//   identity/<aa>/<digest>.json    the generation's identity snapshot
//   manifests/<aa>/<digest>.json   the manifest
//   days/<YYYY-MM-DD>.json         write-once: the day's manifest
//   current.json                   the retained generations, newest first

import { canonicalJSON } from "./artist_bundle.ts";
import { artistRefKey, KNOWLEDGE_ROOT, sha256 } from "./knowledge.ts";

export const GENERATIONS_ROOT = `${KNOWLEDGE_ROOT}/generations`;
export const CURRENT_KEY = `${GENERATIONS_ROOT}/current.json`;
export const CUT_FORMAT = "indigo.knowledge-cut/1";
export const GENERATION_FORMAT = "indigo.knowledge-generation/1";
export const ANSWER_FORMAT = "indigo.knowledge-answer/1";
export const IDENTITY_FORMAT = "indigo.knowledge-identity/1";
export const DAY_FORMAT = "indigo.knowledge-day/1";
export const CURRENT_FORMAT = "indigo.knowledge-current/1";
/// The frozen pilot demand set, as `knowledge_cut` digests it (jsonb text).
export const PILOT_DEMAND_DIGEST = "5754856d891959f5454fc88e44d536269b8a223bb1ac3f1d4bafa9e7c06c88e0";
/// Generations `current.json` keeps (§9.9).
export const RETAINED_GENERATIONS = 7;
/// Reads and writes at once, as the bundle builder does.
export const CONCURRENCY = 8;

const NODE_STATUSES = new Set(["found", "unknown", "unsupported"]);
const ARTIST_STATUSES = new Set(["found", "unknown"]);
/// Evidence that places a Discogs identity on a device (§9.4).
const PLACEABLE = new Set(["discogs-document", "musicbrainz-link", "credit"]);

export const answerKey = (digest: string) => `${GENERATIONS_ROOT}/objects/${digest.slice(0, 2)}/${digest}.json`;
export const identityKey = (digest: string) => `${GENERATIONS_ROOT}/identity/${digest.slice(0, 2)}/${digest}.json`;
export const manifestKey = (digest: string) => `${GENERATIONS_ROOT}/manifests/${digest.slice(0, 2)}/${digest}.json`;
export const dayKey = (date: string) => `${GENERATIONS_ROOT}/days/${date}.json`;

// MARK: - The cut

type JSONObject = Record<string, unknown>;

export interface CutRun {
  jobid: number;
  runid: number;
  start_time: string;
  end_time: string;
}

/// `knowledge_cut`'s answer (0075).
export interface Cut {
  format: string;
  status: string;
  reason: string | null;
  day: string;
  statementAt: string;
  snapshot: string;
  demandDigest: string;
  rebuild: { proof: CutRun | null; latest: CutRun | null } | null;
  nodes: Record<string, JSONObject> | null;
  artists: Record<string, JSONObject> | null;
  batches: number;
}

export interface Demand {
  nodes: { id: string }[];
  artists: { key: string }[];
}

/// Everything wrong with a cut, or nothing. A cut with any problem is not
/// published -- not partly, not with the problem papered over.
export function cutProblems(cut: Cut, day: string, demand: Demand): string[] {
  const problems: string[] = [];
  if (cut.format !== CUT_FORMAT) problems.push(`format ${cut.format}, not ${CUT_FORMAT}`);
  if (cut.status !== "ok") return [...problems, `refused: ${cut.reason ?? "no reason"}`];
  if (cut.day !== day) problems.push(`cut is for ${cut.day}, not ${day}`);
  if (cut.demandDigest !== PILOT_DEMAND_DIGEST) problems.push(`demand digest ${cut.demandDigest} is not the frozen pilot set`);

  // The 00:23 rebuild: succeeded (the cut only lists those), in its slot,
  // finished before the statement began.
  const proof = cut.rebuild?.proof;
  if (!proof) {
    problems.push("no rebuild proof");
  } else {
    const slot = Date.parse(`${day}T00:23:00Z`);
    const start = Date.parse(proof.start_time), end = Date.parse(proof.end_time);
    if (!(start >= slot && start < slot + 7 * 60_000)) problems.push(`rebuild ${proof.runid} started at ${proof.start_time}, outside ${day} 00:23`);
    if (!(end < Date.parse(cut.statementAt))) problems.push(`rebuild ${proof.runid} had not finished before the cut`);
  }

  const nodes = cut.nodes ?? {}, artists = cut.artists ?? {};
  const wantNodes = new Set(demand.nodes.map((n) => n.id)), wantArtists = new Set(demand.artists.map((a) => a.key));
  for (const id of wantNodes) if (!(id in nodes)) problems.push(`node ${id} is missing`);
  for (const id of Object.keys(nodes)) if (!wantNodes.has(id)) problems.push(`node ${id} was not demanded`);
  for (const key of wantArtists) if (!(key in artists)) problems.push(`artist ${key} is missing`);
  for (const key of Object.keys(artists)) if (!wantArtists.has(key)) problems.push(`artist ${key} was not demanded`);
  for (const [id, answer] of Object.entries(nodes)) {
    if (!NODE_STATUSES.has(String(answer.status))) problems.push(`node ${id} has status ${answer.status}`);
    if (!Array.isArray(answer.edges)) problems.push(`node ${id} has no edges list`);
  }
  for (const [key, answer] of Object.entries(artists)) {
    if (!ARTIST_STATUSES.has(String(answer.status))) problems.push(`artist ${key} has status ${answer.status}`);
  }
  return problems;
}

// MARK: - The plan

/// An artist's bundle reference as `refs/artists/<id>.json` holds it.
export interface BundleRef {
  digest: string;
  key: string;
  source?: { complete?: boolean; documentsRead?: number; documentsMissing?: number; representativeReleases?: number };
}

export interface PinnedBundle {
  discogsID: string;
  status: "complete" | "partial" | "missing";
  digest?: string;
  read?: number;
  of?: number;
}

export interface PlannedObject {
  key: string;
  digest: string;
  bytes: number;
  kind: "node" | "artist" | "identity" | "manifest" | "day" | "current";
  body: string;
}

export interface GenerationPlan {
  date: string;
  manifestDigest: string;
  manifest: JSONObject;
  /// Content-addressed: answers (deduplicated), the identity snapshot and the
  /// manifest. These are what step 3–5 write when they are not there yet.
  addressed: PlannedObject[];
  /// Write-once day pointer and the rewritten list (steps 6–7).
  pointers: PlannedObject[];
  bundles: PinnedBundle[];
}

export interface PlanInput {
  cut: Cut;
  demand: Demand;
  /// Bundle references by Discogs id, as read; null where none exists.
  bundleRefs: Map<string, BundleRef | null>;
  /// The current list, if one exists (none until the first publication).
  current: { generations: { date: string; manifest: string }[]; withdrawn?: unknown[] } | null;
  publishedAt: string;
  cutMs: number;
}

/// The starting artists' Discogs ids: a node's seeds, then the identities it
/// reports, in that order, distinct.
export function bundleIDs(cut: Cut): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const [id, answer] of Object.entries(cut.nodes ?? {})) {
    if (!id.startsWith("artist:")) continue;
    const ids: string[] = [];
    for (const seed of (answer.seeds as JSONObject[] | undefined) ?? []) {
      if (seed.discogsID != null && !ids.includes(String(seed.discogsID))) ids.push(String(seed.discogsID));
    }
    for (const identity of (answer.identities as JSONObject[] | undefined) ?? []) {
      if (identity.discogsID != null && !ids.includes(String(identity.discogsID))) ids.push(String(identity.discogsID));
    }
    out.set(id, ids);
  }
  return out;
}

function pinBundle(discogsID: string, ref: BundleRef | null | undefined): PinnedBundle {
  if (!ref) return { discogsID, status: "missing" };
  const source = ref.source ?? {};
  const complete = source.complete === true && (source.documentsMissing ?? 0) === 0;
  return complete
    ? { discogsID, status: "complete", digest: ref.digest }
    : { discogsID, status: "partial", digest: ref.digest, read: source.documentsRead ?? 0, of: source.representativeReleases ?? 0 };
}

function nodeCoverage(answer: JSONObject): JSONObject {
  const edges = (answer.edges as JSONObject[] | undefined) ?? [];
  const kinds: Record<string, number> = {};
  const evidence: Record<string, number> = {};
  let byName = 0;
  for (const edge of edges) {
    kinds[String(edge.kind)] = (kinds[String(edge.kind)] ?? 0) + 1;
    const to = (edge.to ?? {}) as JSONObject;
    if (to.kind !== "artist") continue;
    if (typeof to.idEvidence === "string") evidence[to.idEvidence] = (evidence[to.idEvidence] ?? 0) + 1;
    else byName += 1;
  }
  return { edges: edges.length, kinds, idEvidence: evidence, artistTargetsByName: byName };
}

function artistCoverage(answer: JSONObject): JSONObject {
  const count = (k: string) => Array.isArray(answer[k]) ? (answer[k] as unknown[]).length : 0;
  return { episodes: count("episodes"), genres: count("genres"), rosters: count("rosters") };
}

/// §9.5, from the cut alone: every row the generation names with the Discogs
/// id the catalogue holds for it and how that id is known; the names more
/// than one row answers to, as the cut flagged them; and each starting
/// point's seeds. Never derives an id from a name.
export function identitySnapshot(cut: Cut): JSONObject {
  const rows = new Map<string, { rowID: string; name: string; discogsID: string | null; evidence: Set<string> }>();
  const note = (rowID: unknown, name: unknown, discogsID: unknown, evidence: string | null) => {
    if (typeof rowID !== "string") return;
    const row = rows.get(rowID) ?? { rowID, name: String(name ?? ""), discogsID: null, evidence: new Set<string>() };
    if (discogsID != null) row.discogsID = String(discogsID);
    if (evidence) row.evidence.add(evidence);
    rows.set(rowID, row);
  };
  const namesakes = new Map<string, Set<string>>();
  const flag = (name: unknown, rowID: unknown) => {
    if (typeof rowID !== "string") return;
    const set = namesakes.get(String(name)) ?? new Set<string>();
    set.add(rowID);
    namesakes.set(String(name), set);
  };
  const starting: Record<string, JSONObject[]> = {};
  for (const [id, answer] of Object.entries(cut.nodes ?? {})) {
    const seeds = (answer.seeds as JSONObject[] | undefined) ?? [];
    if (seeds.length) starting[id] = seeds;
    for (const seed of seeds) {
      note(seed.rowID, seed.name, seed.discogsID, null);
      if (answer.ambiguousName === true) flag(seed.name, seed.rowID);
    }
    for (const edge of (answer.edges as JSONObject[] | undefined) ?? []) {
      const to = (edge.to ?? {}) as JSONObject;
      if (to.kind !== "artist") continue;
      note(to.rowID, to.name, to.discogsID, typeof to.idEvidence === "string" ? to.idEvidence : null);
      if (to.sharedName === true) flag(to.name, to.rowID);
    }
  }
  const byText = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  return {
    format: IDENTITY_FORMAT,
    rows: [...rows.values()].sort((a, b) => byText(a.rowID, b.rowID)).map((row) => {
      const evidence = [...row.evidence].sort(byText);
      return {
        rowID: row.rowID, name: row.name, discogsID: row.discogsID ?? undefined,
        evidence: evidence.length ? evidence : undefined,
        // A Discogs id is placed only on evidence that it is this entry --
        // never on a name that took it (adopted-by-name) or matched it.
        placeable: row.discogsID != null && evidence.some((e) => PLACEABLE.has(e)),
      };
    }),
    namesakes: [...namesakes.entries()].filter(([, ids]) => ids.size > 1).sort(([a], [b]) => byText(a, b))
      .map(([name, ids]) => ({ name, rowIDs: [...ids].sort(byText) })),
    starting,
  };
}

async function addressed(kind: PlannedObject["kind"], value: unknown, key: (d: string) => string): Promise<PlannedObject> {
  const body = canonicalJSON(value);
  const digest = await sha256(body);
  return { key: key(digest), digest, bytes: new TextEncoder().encode(body).length, kind, body };
}

/// Steps 1–7 of §9.6 as data: every object a publication would write, the
/// manifest naming them, and the two pointers. Pure.
export async function planGeneration(input: PlanInput): Promise<GenerationPlan> {
  const { cut } = input;
  const date = cut.day;
  const objects = new Map<string, PlannedObject>();
  const keep = (o: PlannedObject) => { if (!objects.has(o.key)) objects.set(o.key, o); return o; };

  const ids = bundleIDs(cut);
  const bundles: PinnedBundle[] = [];
  const nodes: Record<string, JSONObject> = {};
  const summary = {
    nodes: { found: 0, unknown: 0, unsupported: 0, failed: 0 } as Record<string, number>,
    artists: { found: 0, unknown: 0, failed: 0 } as Record<string, number>,
    bundles: { complete: 0, partial: 0, missing: 0, noIdentity: 0 },
  };
  for (const id of Object.keys(cut.nodes ?? {}).sort()) {
    const answer = cut.nodes![id];
    const status = String(answer.status);
    summary.nodes[status] = (summary.nodes[status] ?? 0) + 1;
    if (status !== "found") { nodes[id] = { status }; continue; }
    const object = keep(await addressed("node", { format: ANSWER_FORMAT, kind: "node", id, answer }, answerKey));
    const entry: JSONObject = { status, answer: object.digest, coverage: nodeCoverage(answer) };
    if (answer.ambiguousName === true) entry.ambiguousName = true;
    if (ids.has(id)) {
      const pinned = ids.get(id)!.map((d) => pinBundle(d, input.bundleRefs.get(d)));
      if (pinned.length === 0) summary.bundles.noIdentity += 1;
      for (const b of pinned) { summary.bundles[b.status] += 1; bundles.push(b); }
      entry.bundles = pinned.length ? pinned.map(({ discogsID, ...rest }) => ({ discogsID: Number(discogsID), ...rest })) : [];
    }
    nodes[id] = entry;
  }
  const artists: Record<string, JSONObject> = {};
  for (const key of Object.keys(cut.artists ?? {}).sort()) {
    const answer = cut.artists![key];
    const status = String(answer.status);
    summary.artists[status] = (summary.artists[status] ?? 0) + 1;
    if (status !== "found") { artists[key] = { status }; continue; }
    const object = keep(await addressed("artist", { format: ANSWER_FORMAT, kind: "artist", id: key, answer }, answerKey));
    artists[key] = { status, answer: object.digest, coverage: artistCoverage(answer) };
  }
  const identity = keep(await addressed("identity", identitySnapshot(cut), identityKey));

  const previous = input.current?.generations?.[0]?.manifest ?? null;
  const manifest: JSONObject = {
    format: GENERATION_FORMAT,
    id: `kg-${date}`,
    date,
    previous,
    source: {
      cutAt: cut.statementAt,
      snapshot: cut.snapshot,
      // The rebuild the cut proved, in place of the clock-derived label.
      edges: cut.rebuild?.proof ? { runid: cut.rebuild.proof.runid, endedAt: cut.rebuild.proof.end_time } : null,
      latestRebuild: cut.rebuild?.latest ? { runid: cut.rebuild.latest.runid, endedAt: cut.rebuild.latest.end_time } : null,
      statementMs: input.cutMs,
    },
    demand: { digest: cut.demandDigest, nodes: input.demand.nodes.length, artists: input.demand.artists.length },
    identity: identity.digest,
    nodes,
    artists,
    summary: {
      // Every demanded entity terminal; whether every object was written and
      // verified is the publication's to say, not the plan's.
      terminal: summary.nodes.failed === 0 && summary.artists.failed === 0,
      ...summary,
    },
  };
  const manifestObject = keep(await addressed("manifest", manifest, manifestKey));

  const dayBody = canonicalJSON({ format: DAY_FORMAT, date, manifest: manifestObject.digest, publishedAt: input.publishedAt });
  const listed = [{ date, manifest: manifestObject.digest },
    ...(input.current?.generations ?? []).filter((g) => g.date !== date)].slice(0, RETAINED_GENERATIONS);
  const currentBody = canonicalJSON({
    format: CURRENT_FORMAT, updatedAt: input.publishedAt, generations: listed, withdrawn: input.current?.withdrawn ?? [],
  });
  const pointer = async (kind: "day" | "current", key: string, body: string): Promise<PlannedObject> => ({
    key, kind, body, digest: await sha256(body), bytes: new TextEncoder().encode(body).length,
  });
  return {
    date,
    manifestDigest: manifestObject.digest,
    manifest,
    addressed: [...objects.values()],
    pointers: [await pointer("day", dayKey(date), dayBody), await pointer("current", CURRENT_KEY, currentBody)],
    bundles,
  };
}

// MARK: - Dry run

/// Reads only. There is no way to write through this.
export interface GenerationReadDeps {
  /// One `knowledge_cut` statement, and how long it took.
  cut(day: string): Promise<{ cut: Cut; ms: number }>;
  getObject(key: string): Promise<string | null>;
  exists(key: string): Promise<boolean>;
  now(): Date;
}

/// R2 prices and free allowances (Standard storage), for the projection.
export const R2_PRICING = {
  classAPerMillion: 4.5, classBPerMillion: 0.36, storagePerGBMonth: 0.015,
  freeClassA: 1_000_000, freeClassB: 10_000_000, freeStorageGB: 10,
};

export interface Budget {
  month_writes: number;
  month_write_cap: number;
  bytes_written_ever: number;
  storage_cap_bytes: number;
}

export interface DryRunReport {
  dryRun: true;
  date: string;
  status: "ready" | "refused";
  problems: string[];
  cut?: { ms: number; statementAt: string; snapshot: string; rebuild: Cut["rebuild"]; demandDigest: string; batches: number };
  generation?: {
    manifest: string;
    bytes: { answers: number; identity: number; manifest: number; pointers: number; total: number; cut: number };
    objects: { answers: number; answersBeforeDedupe: number; identity: 1; manifest: 1; contentAddressed: number; pointers: 2 };
    largest: { key: string; bytes: number };
    nodes: Record<string, number>;
    artists: Record<string, number>;
  };
  bundles?: { pinned: PinnedBundle[]; complete: number; partial: number; missing: number; noIdentity: number; startingArtists: number; objectsPresent: number };
  r2?: {
    dryRun: { gets: number; heads: number; puts: 0 };
    alreadyPresent: number;
    publication: { classA: number; classB: number; bytesWritten: number };
    budget?: { monthWrites: number; cap: number; afterPublication: number; shareOfCapPerMonth: string };
  };
  time?: { cutMs: number; planMs: number; readsMs: number; medianReadMs: number; estimatedPublicationMs: number };
  projection?: {
    perMonth: { classA: number; classB: number; retainedBytes: number };
    devicesBreakEven: string;
    costUSD: { classA: number; classB: number; storage: number; total: number };
    assumptions: string[];
  };
}

async function inParallel<T, R>(items: T[], work: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = [];
  for (let i = 0; i < items.length; i += CONCURRENCY) out.push(...await Promise.all(items.slice(i, i + CONCURRENCY).map(work)));
  return out;
}

const median = (values: number[]) => {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};

/// Plans today's generation and reports what publishing it would write, read
/// and cost. Writes nothing: no object, no manifest, no day pointer, no
/// `current.json`. A refused or faulty cut stops it before any R2 read.
export async function dryRunGeneration(
  deps: GenerationReadDeps, demand: Demand, options: { budget?: Budget } = {},
): Promise<DryRunReport> {
  const date = deps.now().toISOString().slice(0, 10);
  const { cut, ms: cutMs } = await deps.cut(date);
  const problems = cutProblems(cut, date, demand);
  if (problems.length) return { dryRun: true, date, status: "refused", problems };

  let gets = 0, heads = 0;
  const readTimes: number[] = [];
  const timed = async <T>(read: () => Promise<T>) => {
    const t = performance.now();
    try { return await read(); } finally { readTimes.push(performance.now() - t); }
  };
  const readsStarted = performance.now();

  gets += 1;
  const currentText = await timed(() => deps.getObject(CURRENT_KEY));
  const current = currentText ? JSON.parse(currentText) : null;

  const wanted = [...new Set([...bundleIDs(cut).values()].flat())].sort();
  const bundleRefs = new Map<string, BundleRef | null>();
  await inParallel(wanted, async (id) => {
    gets += 1;
    const text = await timed(() => deps.getObject(artistRefKey(Number(id))));
    bundleRefs.set(id, text ? JSON.parse(text) as BundleRef : null);
  });

  const planStarted = performance.now();
  const plan = await planGeneration({ cut, demand, bundleRefs, current, publishedAt: deps.now().toISOString(), cutMs });
  const planMs = performance.now() - planStarted;

  // What is there already: pinned bundles, and the content-addressed objects
  // a publication would skip.
  const pinned = plan.bundles.filter((b) => b.digest);
  const bundlePresent = await inParallel(pinned, async (b) => {
    heads += 1;
    return await timed(() => deps.exists(bundleRefs.get(b.discogsID)!.key));
  });
  const present = await inParallel(plan.addressed, async (o) => {
    heads += 1;
    return await timed(() => deps.exists(o.key));
  });
  const dayTaken = await timed(() => deps.exists(plan.pointers[0].key));
  heads += 1;
  const readsMs = performance.now() - readsStarted - planMs;
  if (dayTaken) problems.push(`${plan.pointers[0].key} exists: ${date} is published already`);

  const toWrite = plan.addressed.filter((_, i) => !present[i]);
  const answers = plan.addressed.filter((o) => o.kind === "node" || o.kind === "artist");
  const sum = (os: PlannedObject[]) => os.reduce((n, o) => n + o.bytes, 0);
  const cutBytes = new TextEncoder().encode(JSON.stringify(cut)).length;
  const answersBeforeDedupe = Object.values(cut.nodes ?? {}).filter((a) => a.status === "found").length +
    Object.values(cut.artists ?? {}).filter((a) => a.status === "found").length;
  const largest = [...plan.addressed].sort((a, b) => b.bytes - a.bytes)[0];

  // A publication: one existence check per addressed object, a write and a
  // read-back for each new one, current.json read, the day pointer
  // (conditional write, read back) and current.json rewritten; plus the bundle
  // references it pins.
  const classA = toWrite.length + 2;
  const classB = 1 + wanted.length + plan.addressed.length + toWrite.length + 1 + 1;
  const bytesWritten = sum(toWrite) + sum(plan.pointers);
  const medianReadMs = median(readTimes);
  const estimatedPublicationMs = Math.round(cutMs + planMs + readsMs +
    Math.ceil(toWrite.length / CONCURRENCY) * 2 * medianReadMs + 3 * medianReadMs);

  // A month of daily generations, at worst every answer new every day.
  const perMonthA = classA * 30, perMonthB = classB * 30;
  const retainedBytes = RETAINED_GENERATIONS * (sum(plan.addressed) + sum(plan.pointers));
  const over = (used: number, free: number, perMillion: number) => Math.max(0, used - free) / 1e6 * perMillion;
  const costA = over(perMonthA, R2_PRICING.freeClassA, R2_PRICING.classAPerMillion);
  const costB = over(perMonthB, R2_PRICING.freeClassB, R2_PRICING.classBPerMillion);
  const costStorage = Math.max(0, retainedBytes / 1e9 - R2_PRICING.freeStorageGB) * R2_PRICING.storagePerGBMonth;
  // A device fetches current.json, the manifest and its own objects (§9.8).
  const deviceReads = 2 + answers.length;
  const budget = options.budget;

  return {
    dryRun: true,
    date,
    status: problems.length ? "refused" : "ready",
    problems,
    cut: { ms: cutMs, statementAt: cut.statementAt, snapshot: cut.snapshot, rebuild: cut.rebuild, demandDigest: cut.demandDigest, batches: cut.batches },
    generation: {
      manifest: plan.manifestDigest,
      bytes: {
        answers: sum(answers), identity: sum(plan.addressed.filter((o) => o.kind === "identity")),
        manifest: sum(plan.addressed.filter((o) => o.kind === "manifest")), pointers: sum(plan.pointers),
        total: sum(plan.addressed) + sum(plan.pointers), cut: cutBytes,
      },
      objects: { answers: answers.length, answersBeforeDedupe, identity: 1, manifest: 1, contentAddressed: plan.addressed.length, pointers: 2 },
      largest: { key: largest.key, bytes: largest.bytes },
      nodes: (plan.manifest.summary as JSONObject).nodes as Record<string, number>,
      artists: (plan.manifest.summary as JSONObject).artists as Record<string, number>,
    },
    bundles: {
      pinned: plan.bundles,
      ...(plan.manifest.summary as { bundles: { complete: number; partial: number; missing: number; noIdentity: number } }).bundles,
      startingArtists: bundleIDs(cut).size,
      objectsPresent: bundlePresent.filter(Boolean).length,
    },
    r2: {
      dryRun: { gets, heads, puts: 0 },
      alreadyPresent: present.filter(Boolean).length,
      publication: { classA, classB, bytesWritten },
      budget: budget
        ? {
          monthWrites: budget.month_writes, cap: budget.month_write_cap, afterPublication: budget.month_writes + classA,
          shareOfCapPerMonth: `${(perMonthA / budget.month_write_cap * 100).toFixed(2)}%`,
        }
        : undefined,
    },
    time: { cutMs, planMs: Math.round(planMs), readsMs: Math.round(readsMs), medianReadMs: Math.round(medianReadMs), estimatedPublicationMs },
    projection: {
      perMonth: { classA: perMonthA, classB: perMonthB, retainedBytes },
      devicesBreakEven: `${Math.floor((R2_PRICING.freeClassB - perMonthB) / (deviceReads * 30))} devices reading every object daily stay in the free Class B allowance`,
      costUSD: { classA: costA, classB: costB, storage: costStorage, total: costA + costB + costStorage },
      assumptions: [
        "worst case: every answer is new every day (unchanged answers keep their digest and are not written)",
        `${RETAINED_GENERATIONS} generations retained, none sharing an object`,
        "R2 Standard prices and free allowances; publication reads are Class B, writes Class A",
        "publication time: the cut, the plan, these reads, then write + read-back per new object at the measured median read latency, " +
        `${CONCURRENCY} at a time`,
      ],
    },
  };
}
