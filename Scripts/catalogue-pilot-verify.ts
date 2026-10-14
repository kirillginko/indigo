// Verifies the published catalogue-bundle pilot (DIG-REMEDIATION-PLAN.md §7
// step 3) from R2's public host, read-only:
// - each pilot artist's reference names a bundle that reads back as its digest;
// - rebuilt here from the source documents with the worker's own function
//   (`catalogueBundle`), the bundle is the same bytes;
// - the manifest (through its pointer) is its digest, lists exactly the sound
//   bundles, and names every other pilot artist missing;
// - nothing was written under For You's references.
//
//   deno run --allow-net --allow-read Scripts/catalogue-pilot-verify.ts <r2-public-host> <input.json>...
//
// Each input is a pilot.sql or batch1 input (artists with their releases);
// the approved set is the pilot and batch 1 together.

import { canonicalJSON, type DiscogsReleaseDoc } from "../supabase/functions/_shared/artist_bundle.ts";
import { CATALOGUE_PILOT as PILOT } from "../supabase/functions/_shared/catalogue_pilot.ts";
import { CATALOGUE_BATCH1 } from "../supabase/functions/_shared/catalogue_batch1.ts";
const CATALOGUE_PILOT: ReadonlyMap<number, string> = new Map([...PILOT, ...CATALOGUE_BATCH1]);
import {
  artistRefKey, catalogueBundle, type CatalogueRef, catalogueRefKey, cataloguePilotPointerKey, sha256,
} from "../supabase/functions/_shared/knowledge.ts";

const [host, ...inputPaths] = Deno.args;
const releasesOf = new Map<number, number[]>();
for (const inputPath of inputPaths) {
  const text = await Deno.readTextFile(inputPath);
  const input = JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1)).rows[0].pilot as {
    pilot: { name: string; discogs: number[]; releases: string[] | null }[];
  };
  for (const p of input.pilot) releasesOf.set(Math.min(...p.discogs), (p.releases ?? []).map(Number));
}

let reads = 0;
async function get(key: string): Promise<string | null> {
  reads += 1;
  const response = await fetch(`https://${host}/${key}`, {
    headers: { "User-Agent": "indigo-catalogue-verify/1", "Cache-Control": "no-cache" },
  });
  if (response.status === 404) { await response.body?.cancel(); return null; }
  if (!response.ok) throw new Error(`${key}: HTTP ${response.status}`);
  return await response.text();
}

const counts: Record<string, number> = {};
const bump = (k: string) => { counts[k] = (counts[k] ?? 0) + 1; };
const problems: string[] = [];
const sound = new Map<number, string>();

const ids = [...CATALOGUE_PILOT.keys()].sort((a, b) => a - b);
for (let i = 0; i < ids.length; i += 8) {
  await Promise.all(ids.slice(i, i + 8).map(async (id) => {
    const refText = await get(catalogueRefKey(id));
    if (refText === null) { bump("no reference"); problems.push(`${id}: no reference`); return; }
    const ref = JSON.parse(refText) as CatalogueRef;
    const body = await get(ref.key);
    if (body === null || (await sha256(body)) !== ref.digest) { bump("bundle not its digest"); problems.push(`${id}: bundle`); return; }
    const docs: DiscogsReleaseDoc[] = [];
    const own = [...new Set(releasesOf.get(id) ?? [])].sort((a, b) => a - b);
    for (const release of own) {
      const doc = await get(`releases/${release}.json`);
      if (doc !== null) docs.push(JSON.parse(doc));
    }
    const rebuilt = canonicalJSON(catalogueBundle({ discogsID: id, name: CATALOGUE_PILOT.get(id)! }, docs, own.length, 0));
    if (rebuilt !== body) {
      bump("differs from a rebuild");
      problems.push(`${id}: rebuilt ${docs.length}/${own.length} docs, worker read ${ref.documents} (missing ${ref.missing})`);
      return;
    }
    if (await get(artistRefKey(id)) !== null) bump("has a For You reference (pre-existing?)");
    sound.set(id, ref.digest);
    bump("sound: digest and rebuild agree");
  }));
}

const pointer = JSON.parse((await get(cataloguePilotPointerKey)) ?? "null");
let manifestCheck = "no pointer";
if (pointer) {
  const manifest = await get(pointer.manifest);
  if (manifest === null || (await sha256(manifest)) !== pointer.digest) manifestCheck = "manifest is not its digest";
  else {
    const m = JSON.parse(manifest) as { artists: Record<string, { digest: string }>; missing: number[] };
    const listed = Object.entries(m.artists);
    const wrong = listed.filter(([id, a]) => sound.get(Number(id)) !== a.digest).length;
    const unlisted = [...sound.keys()].filter((id) => !m.artists[String(id)]).length;
    const missingRight = m.missing.every((id) => !sound.has(id)) && listed.length + m.missing.length === CATALOGUE_PILOT.size;
    manifestCheck = `listed ${listed.length}, missing ${m.missing.length}, wrong digests ${wrong}, sound but unlisted ${unlisted}, accounting ${missingRight ? "ok" : "BAD"}`;
  }
}
console.log(JSON.stringify({ counts, manifest: manifestCheck, reads, problems: problems.slice(0, 20) }, null, 1));
