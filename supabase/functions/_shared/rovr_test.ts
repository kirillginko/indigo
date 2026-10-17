// How a ROVR archived playlist becomes lines, and what each line may claim.
//
// The fixtures are synthetic (testdata/rovr/README.md): ROVR has not granted
// reuse of its tracklists, so none of its own payloads are kept here.
//
//     deno test supabase/functions/_shared/rovr_test.ts

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { parseRovrArchive, ROVR_ARCHIVE_FORMAT, type RovrParse } from "./rovr.ts";
import complete from "./testdata/rovr/1-complete.json" with { type: "json" };
import missing from "./testdata/rovr/2-missing.json" with { type: "json" };
import unicode from "./testdata/rovr/3-unicode.json" with { type: "json" };
import malformed from "./testdata/rovr/4-malformed.json" with { type: "json" };
import mixed from "./testdata/rovr/5-mixed.json" with { type: "json" };

function parsed(payload: unknown): RovrParse {
  const result = parseRovrArchive(payload);
  if (!result.ok) throw new Error(`refused: ${result.error.code} ${result.error.detail}`);
  return result;
}

function codes(result: RovrParse, line: number | null): string[] {
  return result.warnings.filter((warning) => warning.line === line).map((warning) => warning.code).sort();
}

// ---------------------------------------------------------------------------
// 1. Complete
// ---------------------------------------------------------------------------

Deno.test("a complete playlist parses every line, in order, with nothing flagged", () => {
  const result = parsed(complete);
  assertEquals(result.counts, { examined: 5, parsed: 5, partial: 0, skipped: 0, flagged: 0, warnings: 0 });
  assertEquals(result.lines.map((line) => line.position), [0, 1, 2, 3, 4]);
  assertEquals(result.lines.map((line) => line.title), ["Glass Harbour", "Copper Field", "Night Ferry", "Salt Lines", "Last Light"]);
  assertEquals(result.lines.every((line) => line.isrcStatus === "valid"), true);
  assertEquals(result.lines.every((line) => line.missing.length === 0 || line.missing.every((field) => field === "label")), true);
});

Deno.test("the source block says where the playlist came from without fetching it", () => {
  assertEquals(parsed(complete).source, {
    provider: "rovr",
    station: "rovr.live",
    externalID: "synthetic0000000000000001",
    numericID: 900001,
    title: "SYNTHETIC 01 COMPLETE",
    curator: "Synthetic Curator One",
    releasedAt: "2026-09-01T04:00:00.000Z",
    scheduledAt: "2026-09-01T04:00:00.000Z",
    archiveURL: "https://soundcloud.com/synthetic/archive-01",
    apiPath: "playlists/archives/public/synthetic0000000000000001",
    durationSeconds: 1500.25,
  });
});

Deno.test("cue offsets are kept to the millisecond and crossfade overlaps are not warnings", () => {
  const result = parsed(complete);
  assertEquals(result.lines.map((line) => [line.startSeconds, line.endSeconds]), [
    [12.5, 310.25],
    [300.1, 620.875],
    [612, 905.333],
    [900, 1190],
    [1185.5, 1500.25],
  ]);
  assertEquals(result.warnings, []);
});

Deno.test("a numeric year and a string year read the same", () => {
  const result = parsed(complete);
  assertEquals(result.lines[2].year, 2018);
  assertEquals(result.lines[2].raw, undefined);
  assertEquals(result.lines[0].year, 2019);
  assertEquals(result.lines[0].raw, { year: "2019" });
});

// ---------------------------------------------------------------------------
// 2. Missing fields
// ---------------------------------------------------------------------------

Deno.test("missing fields are reported as missing, not as parse failures", () => {
  const result = parsed(missing);
  const first = result.lines[0];
  assertEquals(first.status, "parsed");
  assertEquals(first.isrcStatus, "missing");
  assertEquals(first.year, null);
  assertEquals(first.missing, ["isrc", "album", "label", "year", "offset"]);
  assertEquals(first.warnings, 0);
});

Deno.test("an artist-only or title-only line is partial and keeps what it has", () => {
  const result = parsed(missing);
  assertEquals([result.lines[1].status, result.lines[1].artist, result.lines[1].title], ["partial", null, "Second Hand Dub"]);
  assertEquals([result.lines[2].status, result.lines[2].artist, result.lines[2].isrc], ["partial", "Calder Moss", "ZZX0Y2000013"]);
});

Deno.test("blank lines are skipped and counted, and do not renumber the rest", () => {
  const result = parsed(missing);
  assertEquals(result.lines.map((line) => line.status), ["parsed", "partial", "partial", "skipped", "skipped", "parsed"]);
  assertEquals(result.lines[5].position, 5);
  assertEquals(codes(result, 3), ["blank_line"]);
  assertEquals(codes(result, 4), ["blank_line"]);
  assertEquals(result.counts, { examined: 6, parsed: 2, partial: 2, skipped: 2, flagged: 2, warnings: 2 });
});

Deno.test("no cues at all means no offsets, not a warning", () => {
  const result = parsed(missing);
  assertEquals(result.lines.every((line) => line.startSeconds === null && line.endSeconds === null), true);
  assertEquals(result.warnings.some((warning) => warning.field === "offset"), false);
  assertEquals(result.source.durationSeconds, null);
});

// ---------------------------------------------------------------------------
// 3. Names
// ---------------------------------------------------------------------------

Deno.test("names keep their spelling; keys fold accents for matching only", () => {
  const result = parsed(unicode);
  assertEquals(result.lines[0].artist, "Ōtomo Kazurō");
  assertEquals(result.lines[0].artistKey, "otomo kazuro");
  assertEquals(result.lines[7].artistKey, "ансамбль тишина");
  assertEquals(result.lines[8].artist, "فرقة الصدى");
  assert(result.lines[8].artistKey !== null && result.lines[8].artistKey.length > 0);
});

Deno.test("invisible characters are removed and the original is kept to explain it", () => {
  const line = parsed(unicode).lines[0];
  assertEquals(line.label, "Fictional Records");
  assertEquals(line.raw, { label: "Fic​​​tional Records", year: "2024" });
});

Deno.test("credits split only on separators that cannot be part of a name", () => {
  const lines = parsed(unicode).lines;
  assertEquals(lines[1].artists, ["Halvard Oste", "Mira Quell"]);
  assertEquals(lines[2].artists, ["Sunna & Lóa"]);
  assertEquals(lines[3].artists, ["DJ Kōji", "Lina Ré"]);
  assertEquals(lines[6].artists, ["Jean-Paul Méchin"]);
});

Deno.test("a featuring credit in the title is reported and the title is left alone", () => {
  const line = parsed(unicode).lines[11];
  assertEquals(line.title, "Copper Field (feat. Orrin Vale, Wren Abbot)");
  assertEquals(line.titleCredits, ["Orrin Vale", "Wren Abbot"]);
  assertEquals(line.artist, "Mira Quell");
});

Deno.test("aliases are not merged: Lowtide73 and Lowtide 73 stay two keys and two records", () => {
  const lines = parsed(unicode).lines;
  assertNotEquals(lines[4].artistKey, lines[5].artistKey);
  assertEquals(lines[5].repeatOf, null);
  assertEquals(lines[6].title, "Rivière (Lowtide 73 Remix)");
  assertEquals(lines[6].artists, ["Jean-Paul Méchin"]);
});

Deno.test("a punctuation-only artist has no key, and ID names nobody", () => {
  const result = parsed(unicode);
  assertEquals([result.lines[9].artist, result.lines[9].artistKey], ["~ ~ ~", null]);
  assertEquals([result.lines[10].artist, result.lines[10].status], [null, "partial"]);
  assertEquals(codes(result, 10), ["placeholder_artist"]);
});

// ---------------------------------------------------------------------------
// 4. Malformed
// ---------------------------------------------------------------------------

Deno.test("ISRCs: compacted when only formatting differs, refused when the syntax is wrong", () => {
  const lines = parsed(malformed).lines;
  assertEquals([lines[0].isrc, lines[0].isrcStatus, lines[0].raw?.isrc], ["ZZX0Y0900004", "valid", "zz-x0y-09-00004"]);
  assertEquals([lines[2].isrc, lines[2].isrcStatus], [null, "invalid"]);
  assertEquals([lines[3].isrc, lines[3].isrcStatus], [null, "invalid"]);
  assertEquals([lines[10].isrc, lines[10].isrcStatus, lines[10].raw?.isrc], [null, "invalid", 123456789012]);
  assertEquals([lines[11].isrc, lines[11].isrcStatus], ["ZZX0Y2100002", "valid"]);
});

Deno.test("an invalid ISRC never drops an otherwise useful line", () => {
  const line = parsed(malformed).lines[2];
  assertEquals([line.status, line.artist, line.title], ["parsed", "Calder Moss", "Grey Water"]);
});

Deno.test("repeats are kept and marked, by ISRC first and by name only without one", () => {
  const lines = parsed(malformed).lines;
  // Same ISRC once the hyphens are gone: a repeat.
  assertEquals(lines[1].repeatOf, 0);
  // Same names, no ISRC on either: a repeat.
  assertEquals(lines[5].repeatOf, 4);
  // Same names, different ISRCs: two records, never merged.
  assertEquals([lines[6].repeatOf, lines[7].repeatOf], [null, null]);
  // Both ISRCs invalid, so neither line has one and the names decide.
  assertEquals(lines[3].repeatOf, 2);
  assertEquals(lines.length, 12);
});

Deno.test("bad cues are refused line by line; duplicates and orphans are reported", () => {
  const result = parsed(malformed);
  assertEquals([result.lines[1].startSeconds, result.lines[1].endSeconds], [190, 400]);
  assertEquals(codes(result, 1), ["duplicate_cue"]);
  assertEquals([result.lines[2].startSeconds, codes(result, 2)], [null, ["invalid_isrc", "invalid_offset", "invalid_year"]]);
  assertEquals([result.lines[3].startSeconds, result.lines[3].endSeconds], [null, null]);
  assert(codes(result, 3).includes("invalid_offset"));
  assertEquals(codes(result, 4), ["invalid_link", "out_of_order_offset"]);
  assertEquals(result.lines[4].startSeconds, 150);
  const playlistLevel = result.warnings.filter((warning) => warning.line === null).map((warning) => warning.code).sort();
  assertEquals(playlistLevel, ["invalid_offset", "orphan_cue"]);
});

Deno.test("entries that are not objects are skipped with a reason, and the rest still parse", () => {
  const result = parsed(malformed);
  assertEquals([result.lines[8].status, codes(result, 8)], ["skipped", ["malformed_line"]]);
  assertEquals([result.lines[9].status, codes(result, 9)], ["skipped", ["malformed_line"]]);
  assertEquals(result.lines[11].status, "parsed");
});

Deno.test("wrong types: a numeric title is kept as text, an array artist is dropped, both flagged", () => {
  const result = parsed(malformed);
  const line = result.lines[10];
  assertEquals([line.title, line.artist, line.status], ["1", null, "partial"]);
  assertEquals(codes(result, 10), ["invalid_isrc", "wrong_type", "wrong_type"]);
});

Deno.test("counts add up and every warning is accounted for", () => {
  const result = parsed(malformed);
  const { examined, parsed: ok, partial, skipped, flagged, warnings } = result.counts;
  assertEquals(examined, ok + partial + skipped);
  assertEquals(warnings, result.warnings.length);
  assertEquals(flagged, result.lines.filter((line) => line.warnings > 0).length);
  assertEquals(result.counts, { examined: 12, parsed: 9, partial: 1, skipped: 2, flagged: 8, warnings: 17 });
});

// ---------------------------------------------------------------------------
// Shape and format
// ---------------------------------------------------------------------------

Deno.test("schema drift is reported, not fatal", () => {
  const result = parsed(malformed);
  assertEquals(result.schema, { unknownArchiveKeys: ["aiMood"], unknownTrackKeys: ["bpm"], missingArchiveKeys: [] });
  assertEquals(parsed(missing).schema.missingArchiveKeys, []);
  const stripped = structuredClone(complete.data) as Record<string, unknown>;
  delete stripped.stitchedTracksMetadata;
  assertEquals(parsed(stripped).schema.missingArchiveKeys, ["stitchedTracksMetadata"]);
  assertEquals(parsed(complete).schema, { unknownArchiveKeys: [], unknownTrackKeys: [], missingArchiveKeys: [] });
});

Deno.test("unsupported input is refused by name, never parsed into an empty success", () => {
  const refusal = (payload: unknown, format?: string) => {
    const result = parseRovrArchive(payload, format);
    assertEquals(result.ok, false);
    return result.ok ? null : result.error.code;
  };
  assertEquals(refusal(complete, "rovr.archive.list.v1"), "unsupported_format");
  assertEquals(refusal({ data: [complete.data], meta: {} }), "listing_not_detail");
  assertEquals(refusal(null), "not_an_object");
  assertEquals(refusal("Artist - Title\nArtist - Title"), "not_an_object");
  assertEquals(refusal({ data: { documentId: "x", title: "no tracks" } }), "no_tracks");
  assertEquals(parsed(complete.data).format, ROVR_ARCHIVE_FORMAT);
});

// ---------------------------------------------------------------------------
// Determinism and purity
// ---------------------------------------------------------------------------

Deno.test("identical input gives byte-identical output, and the input is not mutated", () => {
  for (const fixture of [complete, missing, unicode, malformed, mixed]) {
    const before = JSON.stringify(fixture);
    const once = JSON.stringify(parseRovrArchive(structuredClone(fixture)));
    const twice = JSON.stringify(parseRovrArchive(structuredClone(fixture)));
    assertEquals(once, twice);
    parseRovrArchive(fixture);
    assertEquals(JSON.stringify(fixture), before);
  }
});

Deno.test("the parser makes no network, file or environment calls", () => {
  const original = { fetch: globalThis.fetch, read: Deno.readTextFile, readSync: Deno.readTextFileSync, env: Deno.env.get };
  const touched: string[] = [];
  globalThis.fetch = (() => { touched.push("fetch"); throw new Error("no network"); }) as typeof fetch;
  Deno.readTextFile = (() => { touched.push("readTextFile"); throw new Error("no disk"); }) as typeof Deno.readTextFile;
  Deno.readTextFileSync = (() => { touched.push("readTextFileSync"); throw new Error("no disk"); }) as typeof Deno.readTextFileSync;
  Deno.env.get = ((name: string) => { touched.push(`env:${name}`); return undefined; }) as typeof Deno.env.get;
  try {
    for (const fixture of [complete, missing, unicode, malformed, mixed]) parseRovrArchive(fixture);
  } finally {
    globalThis.fetch = original.fetch;
    Deno.readTextFile = original.read;
    Deno.readTextFileSync = original.readSync;
    Deno.env.get = original.env;
  }
  assertEquals(touched, []);
});

// ---------------------------------------------------------------------------
// 5. Mixed
// ---------------------------------------------------------------------------

Deno.test("the mixed playlist parses whole, with its two repeats marked", () => {
  const result = parsed(mixed);
  assertEquals(result.counts.examined, 48);
  assertEquals(result.counts.skipped, 0);
  assertEquals(result.lines.filter((line) => line.repeatOf !== null).map((line) => [line.position, line.repeatOf]), [[30, 13], [41, 24]]);
  assertEquals(result.lines.filter((line) => line.isrcStatus === "valid").length, 44);
});
