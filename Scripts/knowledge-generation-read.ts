// Reader A: reads a published knowledge generation through the bucket's
// public host, as a device would, verifies every digest, checks the contract
// and keeps every byte it read under <out-dir>/<key>.
//
//   deno run --allow-net=<host> --allow-write=<out-dir> Scripts/knowledge-generation-read.ts <host> <out-dir> [date]

import {
  compareEdges, CURRENT_KEY, dayKey, manifestKey, PILOT_DEMAND_DIGEST, referencedObjects,
} from "../supabase/functions/_shared/generations.ts";

const [host, out, wanted] = Deno.args;
const sha = async (bytes: Uint8Array<ArrayBuffer>) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
const read: { key: string; sha256: string; bytes: number }[] = [];

async function fetchKey(key: string): Promise<Uint8Array<ArrayBuffer>> {
  const response = await fetch(`https://${host}/${key}`, { cache: "no-store" });
  if (!response.ok) throw new Error(`${key}: ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  await Deno.mkdir(`${out}/${key.split("/").slice(0, -1).join("/")}`, { recursive: true });
  await Deno.writeFile(`${out}/${key}`, bytes);
  read.push({ key, sha256: await sha(bytes), bytes: bytes.length });
  return bytes;
}
const text = (b: Uint8Array) => new TextDecoder().decode(b);

const current = JSON.parse(text(await fetchKey(CURRENT_KEY)));
const date = wanted ?? current.generations[0].date;
const day = JSON.parse(text(await fetchKey(dayKey(date))));
const listed = current.generations.find((g: { date: string }) => g.date === date);
const problems: string[] = [];
if (!listed || listed.manifest !== day.manifest) problems.push("current.json and the day pointer disagree");

const manifestBytes = await fetchKey(manifestKey(day.manifest));
if (await sha(manifestBytes) !== day.manifest) problems.push("manifest digest mismatch");
const manifest = JSON.parse(text(manifestBytes));
const objects = referencedObjects(manifest);
const bodies = new Map<string, unknown>();
for (let i = 0; i < objects.length; i += 8) {
  await Promise.all(objects.slice(i, i + 8).map(async (o) => {
    const bytes = await fetchKey(o.key);
    if (await sha(bytes) !== o.digest) problems.push(`${o.key} digest mismatch`);
    if (o.kind !== "bundle") bodies.set(o.digest, JSON.parse(text(bytes)));
  }));
}

// The contract.
const count = (entries: Record<string, { status: string }>) =>
  Object.values(entries).reduce((m, e) => ({ ...m, [e.status]: (m[e.status] ?? 0) + 1 }), {} as Record<string, number>);
if (manifest.demand.digest !== PILOT_DEMAND_DIGEST) problems.push("not the frozen demand set");
if (Object.keys(manifest.nodes).length !== 24) problems.push("not 24 starting points");
if (Object.keys(manifest.artists).length !== 163) problems.push("not 163 artists");
if (manifest.publication?.complete !== true) problems.push("manifest does not say complete");
if (manifest.nodes["station:n10as"]?.status !== "unsupported") problems.push("station:n10as is not unsupported");
if (manifest.nodes["artist:zzz nobody files this name"]?.status !== "unknown") problems.push("the unknown name is not unknown");
if (manifest.nodes["artist:speedy j"]?.ambiguousName !== true) problems.push("speedy j is not flagged ambiguous");

const identity = bodies.get(manifest.identity) as {
  rows: { evidence?: string[]; placeable: boolean; discogsID?: string }[]; namesakes: { name: string; rowIDs: string[] }[];
};
const evidence: Record<string, number> = {};
let placeable = 0, placedOnName = 0;
for (const row of identity.rows) {
  for (const e of row.evidence ?? []) evidence[e] = (evidence[e] ?? 0) + 1;
  if (row.placeable) placeable += 1;
  if (row.placeable && !(row.evidence ?? []).some((e) => ["discogs-document", "musicbrainz-link", "credit"].includes(e))) placedOnName += 1;
}
if (placedOnName) problems.push(`${placedOnName} identities placed without document evidence`);
const speedy = identity.namesakes.find((n) => n.name === "Speedy J");
if (speedy?.rowIDs.length !== 2) problems.push("Speedy J is not two namesake rows");

let edgesOutOfOrder = 0, edges = 0;
for (const entry of Object.values(manifest.nodes) as { answer?: string }[]) {
  if (!entry.answer) continue;
  const list = ((bodies.get(entry.answer) as { answer: { edges: Record<string, unknown>[] } }).answer.edges);
  edges += list.length;
  for (let i = 1; i < list.length; i++) if (compareEdges(list[i - 1], list[i]) > 0) edgesOutOfOrder += 1;
}
if (edgesOutOfOrder) problems.push(`${edgesOutOfOrder} edges out of order`);

read.sort((a, b) => (a.key < b.key ? -1 : 1));
const fingerprint = await sha(new TextEncoder().encode(read.filter((r) => r.key !== CURRENT_KEY).map((r) => `${r.key} ${r.sha256}`).join("\n")));
console.log(JSON.stringify({
  reader: "A (deno)", date, manifest: day.manifest, publishedAt: day.publishedAt, fingerprint,
  objectsRead: read.length, bytesRead: read.reduce((n, r) => n + r.bytes, 0),
  source: manifest.source, demand: manifest.demand, nodes: count(manifest.nodes), artists: count(manifest.artists),
  bundles: manifest.summary.bundles, identity: { rows: identity.rows.length, placeable, evidence, namesakes: identity.namesakes },
  edges, problems,
}, null, 2));
if (problems.length) Deno.exit(1);
