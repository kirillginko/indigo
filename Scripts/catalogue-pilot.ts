// The catalogue-bundle pilot (DIG-REMEDIATION-PLAN.md §7 step 3), read-only.
//
// For the 300 sampled dead-end artists: reads each one's own cached release
// documents from R2's public host, builds the bundle the worker would build
// (`deriveArtistBundle`, with no discography -- the catalogue's own documents
// only), inverts the same documents into label rosters, and resolves every
// person and label the bundles name against the catalogue by Discogs id.
// Nothing is written anywhere but the local output directory: no R2 write, no
// database write, nothing published.
//
//   supabase db query --linked -f supabase/diagnostics/remediation/pilot.sql > pilot-input.json
//   deno run --allow-net --allow-read --allow-write Scripts/catalogue-pilot.ts pilot-input.json <r2-public-host> <out-dir>
//
// What it measures, per artist:
// - routes, by kind: made-with (a joint main artist, or the main artist of a
//   record they appeared on), credited (somebody credited for a job on their
//   records), label (a label on their records with other catalogued artists);
// - whether each route's other end is a catalogued artist (verified: by the
//   Discogs id the document names) and whether it leads on (that artist is
//   not itself a dead end);
// - weak routes: an engineering-only credit, a label with a roster over
//   LARGE_LABEL artists, a placeholder label;
// - namesake risk: a Discogs id the catalogue files under more than one row.
// A page is "rescued" when it gains a route; "meaningfully" when one of its
// strong routes leads to an artist who is not a dead end.

import {
  type Bundle,
  canonicalJSON,
  deriveArtistBundle,
  type DiscogsReleaseDoc,
} from "../supabase/functions/_shared/artist_bundle.ts";

const LARGE_LABEL = 200;
const CONCURRENCY = 8;

const [inputPath, host, outDir] = Deno.args;
const text = await Deno.readTextFile(inputPath);
const input = JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1)).rows[0].pilot as {
  pilot: { id: string; name: string; discogs: number[]; releases: string[] | null }[];
  artists: Record<string, { rows: number; dead: boolean }>;
  labels: Record<string, number>;
};
await Deno.mkdir(`${outDir}/artists`, { recursive: true });
await Deno.mkdir(`${outDir}/labels`, { recursive: true });

// MARK: Reading the documents

const reads = { requests: 0, missing: 0, failed: 0, bytes: 0, ms: [] as number[] };
const documents = new Map<number, DiscogsReleaseDoc | null>();
async function read(id: number): Promise<DiscogsReleaseDoc | null> {
  if (documents.has(id)) return documents.get(id)!;
  const started = performance.now();
  reads.requests += 1;
  try {
    const response = await fetch(`https://${host}/releases/${id}.json`, { headers: { "User-Agent": "indigo-catalogue-pilot/1" } });
    const body = await response.text();
    reads.ms.push(performance.now() - started);
    if (response.status === 404) { reads.missing += 1; documents.set(id, null); return null; }
    if (!response.ok) { reads.failed += 1; return null; }
    reads.bytes += new TextEncoder().encode(body).length;
    const doc = JSON.parse(body) as DiscogsReleaseDoc;
    documents.set(id, doc);
    return doc;
  } catch {
    reads.failed += 1;
    return null;
  }
}

const wanted = [...new Set(input.pilot.flatMap((p) => (p.releases ?? []).map(Number)))].sort((a, b) => a - b);
for (let i = 0; i < wanted.length; i += CONCURRENCY) await Promise.all(wanted.slice(i, i + CONCURRENCY).map(read));

// MARK: Bundles

const bundles: { pilot: (typeof input.pilot)[number]; bundle: Bundle; bytes: number; buildMs: number }[] = [];
for (const pilot of input.pilot) {
  const docs = (pilot.releases ?? []).map((id) => documents.get(Number(id))).filter((d): d is DiscogsReleaseDoc => !!d);
  const id = Math.min(...pilot.discogs);
  const started = performance.now();
  const bundle = deriveArtistBundle({ artist: { discogsID: id, name: pilot.name }, shelf: null, releases: docs });
  const body = canonicalJSON(bundle);
  const buildMs = performance.now() - started;
  await Deno.writeTextFile(`${outDir}/artists/${id}.json`, body);
  bundles.push({ pilot, bundle, bytes: new TextEncoder().encode(body).length, buildMs });
}

// MARK: Label rosters, inverted from the same documents

const rosters = new Map<number, { name: string; artists: Map<number, string> }>();
for (const doc of documents.values()) {
  if (!doc) continue;
  for (const label of (doc as { labels?: { id?: number; name?: string }[] }).labels ?? []) {
    if (!label.id) continue;
    const roster = rosters.get(label.id) ?? { name: label.name ?? "", artists: new Map() };
    for (const artist of doc.artists ?? []) if (artist.id && artist.id !== 194) roster.artists.set(artist.id, artist.name ?? "");
    rosters.set(label.id, roster);
  }
}
let rosterBytes = 0;
for (const [id, roster] of rosters) {
  const body = canonicalJSON({
    format: "indigo.label-roster/pilot",
    label: { discogsID: id, name: roster.name },
    artists: [...roster.artists].map(([discogsID, name]) => ({ discogsID, name })).sort((a, b) => a.discogsID - b.discogsID),
    catalogued: input.labels[String(id)] ?? 0,
  });
  rosterBytes += new TextEncoder().encode(body).length;
  await Deno.writeTextFile(`${outDir}/labels/${id}.json`, body);
}

// MARK: Routes

type Kind = "made-with" | "credited" | "label";
interface Route { kind: Kind; to: string; verified: boolean; catalogued: boolean; leadsOn: boolean; weak: boolean; namesakeRisk: boolean }

const counts: Record<string, number> = {};
const bump = (key: string, by = 1) => { counts[key] = (counts[key] ?? 0) + by; };
const examples: Record<string, string[]> = {};
const example = (key: string, line: string) => { (examples[key] ??= []).length < 6 && examples[key].push(line); };
const perArtist: unknown[] = [];

for (const { pilot, bundle } of bundles) {
  const self = new Set(pilot.discogs);
  const routes: Route[] = [];
  const person = (id: number | null, name: string, kind: Kind, weak: boolean) => {
    if (id === null) { routes.push({ kind, to: name, verified: false, catalogued: false, leadsOn: false, weak, namesakeRisk: false }); return; }
    if (self.has(id)) return;
    const known = input.artists[String(id)];
    routes.push({
      kind, to: `${name} (${id})`, verified: true, catalogued: !!known,
      leadsOn: !!known && !known.dead, weak, namesakeRisk: !!known && known.rows > 1,
    });
  };
  for (const c of bundle.collaborators) person(c.artist.discogsID, c.artist.name, "made-with", false);
  for (const c of bundle.credits) {
    const strong = c.roles.some((r) => r.kind === "production" || r.kind === "writing" || r.kind === "performance");
    person(c.artist.discogsID, c.artist.name, "credited", !strong);
  }
  for (const label of bundle.labels) {
    if (label.discogsID === null) continue;
    const catalogued = input.labels[String(label.discogsID)] ?? 0;
    const others = Math.max(0, catalogued - 1);
    // Only a label the catalogue files somebody else under: a co-artist on
    // the same record is already a made-with route, not a label peer.
    if (others === 0) continue;
    routes.push({
      kind: "label", to: `${label.name} (${label.discogsID}, ${catalogued} catalogued)`, verified: true, catalogued: true,
      // A label leads on through its other artists; the catalogue's roster
      // says they exist, and they are not this dead end.
      leadsOn: true, weak: label.placeholder || catalogued > LARGE_LABEL, namesakeRisk: false,
    });
  }

  const usable = routes.filter((r) => r.verified && r.catalogued);
  const meaningful = usable.filter((r) => r.leadsOn && !r.weak);
  bump("artists");
  bump(`documents per artist: ${Math.min(bundle.coverage.used, 5)}${bundle.coverage.used >= 5 ? "+" : ""}`);
  if (bundle.coverage.used === 0) bump("no document readable");
  if (usable.length > 0) bump("rescued: any verified route to a catalogued artist or label");
  if (meaningful.length > 0) bump("rescued meaningfully: a strong route that leads on");
  else if (usable.length > 0) bump("rescued, weak only (engineering, huge or placeholder label, or into another dead end)");
  else if (routes.some((r) => r.verified)) bump("still a dead end: names people/labels, none catalogued");
  else bump("still a dead end: documents name nobody else");
  for (const kind of ["made-with", "credited", "label"] as Kind[]) {
    if (meaningful.some((r) => r.kind === kind)) bump(`meaningful via ${kind}`);
    if (meaningful.length > 0 && meaningful.every((r) => r.kind === kind)) bump(`meaningful ONLY via ${kind}`);
  }
  bump("routes", routes.length);
  bump("routes verified by Discogs id", routes.filter((r) => r.verified).length);
  bump("routes name-only (unresolved, not used)", routes.filter((r) => !r.verified).length);
  bump("routes to catalogued", usable.length);
  bump("routes meaningful", meaningful.length);
  bump("routes weak", usable.filter((r) => r.weak).length);
  bump("routes into another dead end", usable.filter((r) => !r.leadsOn).length);
  bump("routes with namesake risk (id on >1 row)", usable.filter((r) => r.namesakeRisk).length);
  if (usable.some((r) => r.namesakeRisk)) bump("artists with a namesake-risk route");
  const key = meaningful.length ? "meaningful" : usable.length ? "weak" : "dead";
  example(key, `${pilot.name}: ${(meaningful.length ? meaningful : usable.length ? usable : routes).slice(0, 3).map((r) => `${r.kind} → ${r.to}`).join("; ") || "—"}`);
  perArtist.push({ artist: pilot.name, discogs: pilot.discogs, documents: bundle.coverage.used, routes });
}

// Duplicates: one artist reached twice by the same kind.
const sorted = (xs: number[]) => [...xs].sort((a, b) => a - b);
const pct = (xs: number[], p: number) => sorted(xs)[Math.min(xs.length - 1, Math.floor(xs.length * p))] ?? 0;
const bundleBytes = bundles.map((b) => b.bytes);
const report = {
  counts,
  examples,
  reads: {
    requests: reads.requests, missing: reads.missing, failed: reads.failed, bytes: reads.bytes,
    p50ms: Math.round(pct(reads.ms, 0.5)), p95ms: Math.round(pct(reads.ms, 0.95)),
  },
  objects: {
    bundles: bundles.length, bundleBytesTotal: bundleBytes.reduce((a, b) => a + b, 0),
    bundleP50: pct(bundleBytes, 0.5), bundleP95: pct(bundleBytes, 0.95), bundleMax: Math.max(...bundleBytes),
    rosters: rosters.size, rosterBytesTotal: rosterBytes,
    buildMsTotal: Math.round(bundles.reduce((a, b) => a + b.buildMs, 0)),
    // What a worker run would write: a bundle and its ref per artist, a roster per label.
    r2WritesIfStored: bundles.length * 2 + rosters.size,
  },
};
await Deno.writeTextFile(`${outDir}/per-artist.json`, JSON.stringify(perArtist, null, 1));
console.log(JSON.stringify(report, null, 1));
