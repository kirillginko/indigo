// Artist knowledge bundles, derived from real Discogs documents.
//
// The fixtures in testdata/artist_bundle are six artists' documents as R2
// holds them, trimmed to the fields a bundle reads (two are kept whole):
// their own releases, their shelf's first page, and every shelf release with
// a document. Chosen for what they exercise -- Burial's joint records and
// compilations, Mica Levi producing Tirzah, Dean Blunt's self-released and
// featured credits, Kate NV's remixes, Lee Gamble's thin coverage.
//
// Imported as JSON modules, so the suite needs no file permission and runs
// under Scripts/test-functions.sh as it is.
//
//     deno test supabase/functions/_shared/artist_bundle_test.ts

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import {
  bundleDigest, bundleKey, BundleInput, canonicalJSON, creditKind, deriveArtistBundle,
  isPlaceholderLabel, withoutDisambiguator,
} from "./artist_bundle.ts";

import leeGamble from "./testdata/artist_bundle/1274911.json" with { type: "json" };
import deanBlunt from "./testdata/artist_bundle/2419343.json" with { type: "json" };
import micaLevi from "./testdata/artist_bundle/2576890.json" with { type: "json" };
import burial from "./testdata/artist_bundle/306157.json" with { type: "json" };
import tirzah from "./testdata/artist_bundle/508796.json" with { type: "json" };
import kateNV from "./testdata/artist_bundle/5302639.json" with { type: "json" };
import full1 from "./testdata/artist_bundle/full-10117717.json" with { type: "json" };
import full2 from "./testdata/artist_bundle/full-10163374.json" with { type: "json" };

const FIXTURES: Record<number, unknown> = {
  1274911: leeGamble, 2419343: deanBlunt, 2576890: micaLevi, 306157: burial, 508796: tirzah, 5302639: kateNV,
};
const FULL_DOCUMENTS = [full1, full2];

/// A fresh copy each time, so no test can change another's input.
function fixture(id: number): Promise<BundleInput> {
  return Promise.resolve(structuredClone(FIXTURES[id]) as BundleInput);
}
const LEE_GAMBLE = 1274911, DEAN_BLUNT = 2419343, MICA_LEVI = 2576890, BURIAL = 306157, TIRZAH = 508796, KATE_NV = 5302639;
const ALL = [LEE_GAMBLE, DEAN_BLUNT, MICA_LEVI, BURIAL, TIRZAH, KATE_NV];

/// A deterministic shuffle, so a failure can be run again.
function shuffled<T>(items: T[], seed: number): T[] {
  const out = [...items];
  let state = seed;
  for (let i = out.length - 1; i > 0; i--) {
    state = (state * 1103515245 + 12345) % 2147483648;
    const j = state % (i + 1);
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

async function gzipSize(text: string): Promise<number> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return (await new Response(stream).arrayBuffer()).byteLength;
}

// MARK: Shape and size

Deno.test("every fixture becomes a bounded bundle that uses every related document", async () => {
  for (const id of ALL) {
    const input = await fixture(id);
    const bundle = deriveArtistBundle(input);
    assertEquals(bundle.format, "indigo.artist-knowledge/1");
    assertEquals(bundle.artist.discogsID, id);
    assertEquals(bundle.coverage.used + bundle.coverage.unrelated + bundle.coverage.malformed, input.releases.length);
    const text = canonicalJSON(bundle);
    assert(text.length < 32_000, `${bundle.artist.name}: ${text.length} bytes`);
    assert(await gzipSize(text) < 6_000, `${bundle.artist.name} compresses`);
  }
});

Deno.test("the shelf's reach is recorded, so a thin bundle says it is thin", async () => {
  const lee = deriveArtistBundle(await fixture(LEE_GAMBLE));
  assertEquals(lee.coverage.shelfTotal, 130);
  assertEquals(lee.coverage.shelfEntries, 50);
  assertEquals(lee.coverage.shelfWithoutDocument, 39);
  const kate = deriveArtistBundle(await fixture(KATE_NV));
  assertEquals(kate.coverage.shelfTotal, 41);
  assertEquals(kate.coverage.shelfWithoutDocument, 0);
});

// MARK: Determinism

Deno.test("the same documents in any order, with duplicates, give the same bytes and digest", async () => {
  for (const id of ALL) {
    const input = await fixture(id);
    const reference = deriveArtistBundle(input);
    const digest = await bundleDigest(reference);
    for (const seed of [1, 2, 3]) {
      const scrambled: BundleInput = {
        artist: input.artist,
        shelf: { total: input.shelf?.total, releases: shuffled(input.shelf?.releases ?? [], seed) },
        releases: shuffled([...input.releases, ...input.releases.slice(0, 3)], seed),
      };
      const again = deriveArtistBundle(scrambled);
      assertEquals(again.coverage.duplicates, Math.min(3, input.releases.length));
      // Coverage counts the duplicates; everything else is identical.
      assertEquals(canonicalJSON({ ...again, coverage: { ...again.coverage, duplicates: 0, documents: 0 } }),
        canonicalJSON({ ...reference, coverage: { ...reference.coverage, duplicates: 0, documents: 0 } }));
    }
    assertEquals(digest, await bundleDigest(deriveArtistBundle(input)));
  }
});

Deno.test("canonical JSON sorts keys and normalises strings", () => {
  assertEquals(canonicalJSON({ b: 1, a: [{ d: 2, c: "Köln" }] }), `{"a":[{"c":"Köln","d":2}],"b":1}`);
});

Deno.test("a bundle is kept under its digest, never at a key it shares with its next version", async () => {
  const bundle = deriveArtistBundle(await fixture(KATE_NV));
  const digest = await bundleDigest(bundle);
  assertEquals(bundleKey(digest), `knowledge/v1/bundles/${digest.slice(0, 2)}/${digest}.json`);
  const changed = deriveArtistBundle({ ...(await fixture(KATE_NV)), releases: (await fixture(KATE_NV)).releases.slice(1) });
  assertNotEquals(await bundleDigest(changed), digest);
});

// MARK: Missing and malformed metadata

Deno.test("documents without ids, styles, labels or years are counted, not fatal", async () => {
  const input = await fixture(KATE_NV);
  const own = input.releases.find((r) => (r.artists ?? []).some((a) => a.id === KATE_NV))!;
  const bare = { id: 999_999_999, title: own.title, artists: own.artists };
  const bundle = deriveArtistBundle({ ...input, releases: [...input.releases, bare, { title: "no id" }] });
  assertEquals(bundle.coverage.malformed, 1);
  const before = deriveArtistBundle(input).coverage;
  assertEquals(bundle.coverage.ownWithoutStyles, before.ownWithoutStyles + 1);
  assertEquals(bundle.coverage.ownWithoutLabels, before.ownWithoutLabels + 1);
  assertEquals(bundle.coverage.ownWithoutYear, before.ownWithoutYear + 1);
  assert(bundle.releases.some((r) => r.id === 999_999_999 && r.year === null));
});

Deno.test("a whole, untrimmed document is read the same way", async () => {
  for (const whole of FULL_DOCUMENTS) {
    // deno-lint-ignore no-explicit-any
    const doc = structuredClone(whole) as any;
    const main = doc.artists[0];
    const bundle = deriveArtistBundle({ artist: { discogsID: main.id, name: main.name }, releases: [doc] });
    assertEquals(bundle.coverage.used, 1);
    // And it is unrelated to somebody it never mentions.
    const other = deriveArtistBundle({ artist: { discogsID: 1, name: "Nobody" }, releases: [doc] });
    assertEquals(other.coverage.unrelated, 1);
  }
});

// MARK: What the relationships mean

Deno.test("a joint record makes collaborators: Burial with Four Tet and Thom Yorke", async () => {
  const burial = deriveArtistBundle(await fixture(BURIAL));
  const fourTet = burial.collaborators.find((c) => c.artist.name === "Four Tet")!;
  assert(fourTet.how.includes("joint"));
  assert(fourTet.releases.length >= 5);
  assert(burial.collaborators.some((c) => c.artist.name === "Thom Yorke" && c.how.includes("joint")));
});

Deno.test("producing someone's record is making it with them, kept with Discogs' word for it", async () => {
  const mica = deriveArtistBundle(await fixture(MICA_LEVI));
  const tirzah = mica.collaborators.find((c) => c.artist.discogsID === TIRZAH)!;
  assert(tirzah.how.includes("Producer"));
  assert(!tirzah.how.some((how) => /photograph/i.test(how)), "a sleeve photograph is not a collaboration");
});

Deno.test("a credit on the artist's own record is a credit, not a collaboration", async () => {
  const tirzah = deriveArtistBundle(await fixture(TIRZAH));
  const mica = tirzah.credits.find((c) => c.artist.discogsID === MICA_LEVI)!;
  const produced = mica.roles.find((r) => r.role === "Producer")!;
  assertEquals(produced.kind, "production");
  assert(produced.releases.length >= 5);

  const burial = deriveArtistBundle(await fixture(BURIAL));
  const goz = burial.credits.find((c) => c.artist.name === "Jason Goz")!;
  assert(goz.roles.every((r) => r.kind === "engineering"));
  assert(!burial.collaborators.some((c) => c.artist.name === "Jason Goz"), "mastering a record is not making it with its artist");
});

Deno.test("a credit keeps the release and the tracks it is on, and the spelling the record uses", async () => {
  const dean = deriveArtistBundle(await fixture(DEAN_BLUNT));
  const shabaka = dean.credits.find((c) => c.artist.discogsID === 1419450)!;
  assertEquals(shabaka.artist.name, "Shabaka Hutchings");
  assertEquals(shabaka.artist.anv, "Shabaka Hutchins");
  assertEquals(shabaka.roles[0].role, "Saxophone");
  assertEquals(shabaka.roles[0].releases[0].id, 15626526);
  const rocky = dean.credits.find((c) => c.artist.discogsID === 2409771)!;
  assert(rocky.roles.flatMap((r) => r.releases).some((r) => r.tracks.length > 0), "track positions are kept");
});

Deno.test("a compilation's main artist is nobody's collaborator", async () => {
  for (const id of ALL) {
    const bundle = deriveArtistBundle(await fixture(id));
    assert(!bundle.collaborators.some((c) => /^various/i.test(c.artist.name)), bundle.artist.name);
  }
  const burial = deriveArtistBundle(await fixture(BURIAL));
  assert(burial.releases.some((r) => r.compilation && (r.relation === "track" || r.relation === "credit")));
});

Deno.test("roles are one each, in one spelling", async () => {
  for (const id of ALL) {
    const bundle = deriveArtistBundle(await fixture(id));
    for (const c of bundle.collaborators) {
      assertEquals(new Set(c.how.map((h) => h.toLowerCase())).size, c.how.length);
      assert(c.how.every((h) => !h.includes(",")));
    }
    for (const c of bundle.credits) assertEquals(new Set(c.roles.map((r) => r.role.toLowerCase())).size, c.roles.length);
  }
});

// MARK: Labels

Deno.test("labels are kept by Discogs id: two labels are never one because their names are alike", async () => {
  const tirzah = deriveArtistBundle(await fixture(TIRZAH));
  const domino = tirzah.labels.filter((l) => l.display.startsWith("Domino"));
  assertEquals(domino.map((l) => l.discogsID).sort(), [26465, 69345]);

  const synthetic = deriveArtistBundle({
    artist: { discogsID: 42, name: "Somebody" },
    releases: [
      { id: 1, artists: [{ id: 42, name: "Somebody" }], labels: [{ id: 100, name: "Stroom" }] },
      { id: 2, artists: [{ id: 42, name: "Somebody" }], labels: [{ id: 2271028, name: "Stroom (2)" }] },
      { id: 3, artists: [{ id: 42, name: "Somebody" }], labels: [{ name: "Stroom" }] },
    ],
  });
  assertEquals(synthetic.labels.length, 3, "same display name, three labels");
  assert(synthetic.labels.every((l) => l.display === "Stroom"));
  assertEquals(synthetic.labels.find((l) => l.discogsID === 2271028)?.name, "Stroom (2)", "the name Discogs gives is kept");
});

Deno.test("self-releases and the artist's own name are labelled as such, not dropped", async () => {
  const dean = deriveArtistBundle(await fixture(DEAN_BLUNT));
  assertEquals(dean.labels.find((l) => l.discogsID === 511609)?.display, "World Music");
  assert(dean.labels.some((l) => l.placeholder && l.name.startsWith("Not On Label")));
  assert(isPlaceholderLabel("Self-Titled"));
  assert(!isPlaceholderLabel("Rough Trade"));
  assertEquals(withoutDisambiguator("Sima Kim* & Saito Koji (2)"), "Sima Kim & Saito Koji");
});

// MARK: Style is not a relationship

Deno.test("artists who share styles but never worked together have no relationship in either bundle", async () => {
  const burial = deriveArtistBundle(await fixture(BURIAL));
  const kate = deriveArtistBundle(await fixture(KATE_NV));
  const shared = burial.styles.map((s) => s.name).filter((s) => kate.styles.some((k) => k.name === s));
  assert(shared.length > 0, `they share styles: ${shared.join(", ")}`);
  const people = (b: typeof burial) => new Set([...b.collaborators, ...b.credits].map((c) => c.artist.discogsID));
  assert(!people(burial).has(KATE_NV));
  assert(!people(kate).has(BURIAL));
});

Deno.test("styles are the artist's own records; records they are on are kept apart", async () => {
  const tirzah = deriveArtistBundle(await fixture(TIRZAH));
  assert(!tirzah.styles.some((s) => s.name === "Hip Hop"), "Hip Hop is on a record she features on");
  assert(tirzah.stylesAround.some((s) => s.name === "Hip Hop"));
});

// MARK: The app's role rules

Deno.test("credit roles mean what they mean in the app (CreditRole.kind)", () => {
  assertEquals(creditKind("Producer"), "production");
  assertEquals(creditKind("Mixed By, Producer"), "production");
  assertEquals(creditKind("Remix"), "production");
  assertEquals(creditKind("Written-By"), "writing");
  assertEquals(creditKind("Mastered By"), "engineering");
  assertEquals(creditKind("Recorded By"), "engineering");
  assertEquals(creditKind("Saxophone"), "performance");
  assertEquals(creditKind("Design"), null);
  assertEquals(creditKind("Photography By"), null);
  assertEquals(creditKind("Lacquer Cut By"), null);
});
