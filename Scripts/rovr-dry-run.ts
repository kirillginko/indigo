// What a ROVR ingest *would* do with saved playlists, and what each storage
// shape would cost -- with nothing fetched and nothing written.
//
// Reads only the files it is given. Run it without --allow-net and
// without --allow-write, and Deno itself guarantees that: any network call or
// write would be refused. --out is the one exception, and needs a write
// permission naming exactly that file.
//
//   deno run --allow-read=supabase/functions/_shared/testdata/rovr \
//       Scripts/rovr-dry-run.ts --dir supabase/functions/_shared/testdata/rovr
//
//   deno run --allow-read=supabase/functions/_shared/testdata/rovr --allow-write=/tmp/rovr.json \
//       Scripts/rovr-dry-run.ts --fixture supabase/functions/_shared/testdata/rovr/5-mixed.json --out /tmp/rovr.json
//
// ROVR has not granted reuse of its tracklists. This is an evaluation of a
// parser and of storage shapes, not a step toward ingesting anything; see
// docs/rovr-parser-pilot-results.md.

import { parseRovrArchive, type RovrLine, type RovrParse } from "../supabase/functions/_shared/rovr.ts";
import { normalizeName } from "../supabase/functions/_shared/normalize.ts";

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

function usage(message?: string): never {
  if (message) console.error(message);
  console.error("usage: rovr-dry-run.ts (--fixture <file.json>)... | --dir <directory>  [--out <report.json>] [--json]");
  Deno.exit(2);
}

const files: string[] = [];
let out: string | null = null;
let asJSON = false;
for (let index = 0; index < Deno.args.length; index++) {
  const argument = Deno.args[index];
  if (argument === "--fixture") files.push(Deno.args[++index] ?? usage("--fixture needs a path"));
  else if (argument === "--dir") {
    const directory = Deno.args[++index] ?? usage("--dir needs a path");
    for (const entry of [...Deno.readDirSync(directory)].sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.isFile && entry.name.endsWith(".json")) files.push(`${directory.replace(/\/$/, "")}/${entry.name}`);
    }
  } else if (argument === "--out") out = Deno.args[++index] ?? usage("--out needs a path");
  else if (argument === "--json") asJSON = true;
  else usage(`unknown argument ${argument}`);
}
if (files.length === 0) usage("no fixtures given");

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

interface Parsed {
  file: string;
  parse: RovrParse;
  payloadBytes: number;
}

const parsedPlaylists: Parsed[] = [];
const refused: { file: string; code: string; detail: string }[] = [];
for (const file of files) {
  const text = Deno.readTextFileSync(file);
  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch (cause) {
    refused.push({ file, code: "not_json", detail: String(cause).slice(0, 120) });
    continue;
  }
  const result = parseRovrArchive(payload);
  if (result.ok) parsedPlaylists.push({ file, parse: result, payloadBytes: new TextEncoder().encode(text).length });
  else refused.push({ file, code: result.error.code, detail: result.error.detail });
}

// ---------------------------------------------------------------------------
// Counts
// ---------------------------------------------------------------------------

const allLines = parsedPlaylists.flatMap((p) => p.parse.lines.map((line) => ({ playlist: p.parse.source.externalID ?? p.file, line })));
const kept = allLines.filter(({ line }) => line.status !== "skipped");
const sum = (key: keyof RovrParse["counts"]) => parsedPlaylists.reduce((total, p) => total + p.parse.counts[key], 0);

function tally<T>(values: T[]): Map<T, number> {
  const map = new Map<T, number>();
  for (const value of values) map.set(value, (map.get(value) ?? 0) + 1);
  return map;
}

const validISRCs = kept.filter(({ line }) => line.isrcStatus === "valid").map(({ line }) => line.isrc!);
const pairKey = (line: RovrLine) => line.artistKey !== null && line.titleKey !== null ? `${line.artistKey}\u0000${line.titleKey}` : null;
const pairs = kept.map(({ line }) => pairKey(line)).filter((key): key is string => key !== null);

// Across playlists: a record (ISRC, else name pair) heard in more than one.
const recordKey = (line: RovrLine) => line.isrc !== null ? `isrc:${line.isrc}` : pairKey(line) === null ? null : `name:${pairKey(line)}`;
const playlistsPerRecord = new Map<string, Set<string>>();
for (const { playlist, line } of kept) {
  const key = recordKey(line);
  if (key === null) continue;
  if (!playlistsPerRecord.has(key)) playlistsPerRecord.set(key, new Set());
  playlistsPerRecord.get(key)!.add(playlist);
}

const missingByField = tally(kept.flatMap(({ line }) => line.missing));
const warningsByCode = tally(parsedPlaylists.flatMap((p) => p.parse.warnings.map((warning) => warning.code)));

const counts = {
  playlistsScanned: files.length,
  playlistsParsed: parsedPlaylists.length,
  playlistsRefused: refused.length,
  linesExamined: sum("examined"),
  linesParsed: sum("parsed"),
  linesPartial: sum("partial"),
  linesSkipped: sum("skipped"),
  linesFlagged: sum("flagged"),
  warnings: sum("warnings"),
  linesWithValidISRC: validISRCs.length,
  distinctISRCs: new Set(validISRCs).size,
  invalidISRCs: kept.filter(({ line }) => line.isrcStatus === "invalid").length,
  /// An approximation: normalized names, not recordings. Two pressings of
  /// one record share a pair; two records with one title share one too.
  distinctArtistTitlePairsApprox: new Set(pairs).size,
  repeatsWithinPlaylists: kept.filter(({ line }) => line.repeatOf !== null).length,
  recordsInMoreThanOnePlaylist: [...playlistsPerRecord.values()].filter((set) => set.size > 1).length,
  missingByField: Object.fromEntries([...missingByField.entries()].sort(([a], [b]) => a.localeCompare(b))),
  warningsByCode: Object.fromEntries([...warningsByCode.entries()].sort(([a], [b]) => a.localeCompare(b))),
  matchesToIndigoIdentifiers: "not measured: no local, permission-safe export of Indigo's artists or recordings is available to this script",
  schemaDrift: parsedPlaylists
    .filter((p) => p.parse.schema.unknownArchiveKeys.length + p.parse.schema.unknownTrackKeys.length + p.parse.schema.missingArchiveKeys.length > 0)
    .map((p) => ({ file: p.file, ...p.parse.schema })),
};

// ---------------------------------------------------------------------------
// Storage: how Postgres lays a row out
// ---------------------------------------------------------------------------
//
// Estimates, from Postgres' documented on-disk format: a 23-byte tuple header
// plus a null bitmap, MAXALIGNed to 8; each column aligned to its type; text
// as a 1-byte-header varlena under 127 bytes; a 4-byte line pointer per row;
// 24 bytes of page header per 8 KB page. B-tree leaf entries are an 8-byte
// index tuple header plus the key, MAXALIGNed, plus a line pointer, at the
// default 90% leaf fill. Bloat, dead tuples and TOAST are not modelled; the
// live table's own measured averages are printed beside these for that.

type Column =
  | { type: "uuid" | "int2" | "int4" | "float8" | "timestamptz"; value: unknown }
  | { type: "text"; value: string | null }
  | { type: "text[]"; value: string[] | null };

const encoder = new TextEncoder();
const utf8 = (value: string) => encoder.encode(value).length;
const align = (offset: number, to: number) => Math.ceil(offset / to) * to;
const PAGE_FACTOR = 8192 / (8192 - 24);
const BTREE_FILL = 0.9;

function heapBytes(columns: Column[]): number {
  const hasNull = columns.some((column) => column.value === null || column.value === undefined);
  let offset = align(23 + (hasNull ? Math.ceil(columns.length / 8) : 0), 8);
  for (const column of columns) {
    if (column.value === null || column.value === undefined) continue;
    switch (column.type) {
      case "uuid": offset += 16; break;
      case "int2": offset = align(offset, 2) + 2; break;
      case "int4": offset = align(offset, 4) + 4; break;
      case "float8":
      case "timestamptz": offset = align(offset, 8) + 8; break;
      case "text": {
        const length = utf8(column.value as string);
        offset += length < 127 ? 1 + length : align(offset, 4) - offset + 4 + length;
        break;
      }
      case "text[]": {
        // Array header (16 B + 8 B per dimension) and an element per value.
        const values = column.value as string[];
        offset = align(offset, 4) + 4 + 16 + 8 + values.reduce((total, value) => total + align(4 + utf8(value), 4), 0);
        break;
      }
    }
  }
  return (align(offset, 8) + 4) * PAGE_FACTOR;
}

function btreeBytes(keyBytes: number): number {
  return (align(8 + keyBytes, 8) + 4) / BTREE_FILL * PAGE_FACTOR;
}

/// What COPY would send for a row: a directly measured serialization, before
/// Postgres adds any overhead of its own.
function copyBytes(columns: Column[]): number {
  return utf8(columns.map((column) => {
    if (column.value === null || column.value === undefined) return "\\N";
    if (column.type === "uuid") return "00000000-0000-0000-0000-000000000000";
    if (column.type === "timestamptz") return "2026-10-17 00:00:00+00";
    if (column.type === "text[]") return `{${(column.value as string[]).map((value) => JSON.stringify(value)).join(",")}}`;
    return String(column.value);
  }).join("\t")) + 1;
}

const UUID = { type: "uuid" as const, value: "x" };
const NOW = { type: "timestamptz" as const, value: "x" };

/// A `radio_appearances` row as `appearanceRows` in radio.ts would write it,
/// in the table's column order, with `artist_id` assumed resolved (16 B more
/// than unresolved; today's resolver adopts every unmatched name).
function appearanceRow(line: RovrLine): Column[] {
  const multiple = line.artists.length > 1;
  return [
    UUID, // id
    { type: "uuid", value: null }, // recording_id
    { type: "int4", value: line.startSeconds === null ? null : Math.round(line.startSeconds) },
    { type: "float8", value: null }, // confidence
    NOW, // created_at
    UUID, // radio_episode_id
    { type: "int4", value: line.position },
    { type: "text", value: line.artist },
    { type: "text", value: line.title },
    { type: "text", value: line.artistKey },
    { type: "text", value: line.titleKey },
    UUID, // artist_id
    { type: "int4", value: line.endSeconds === null ? null : Math.round(line.endSeconds) },
    { type: "text", value: "normalized_artist" },
    { type: "text", value: line.isrc },
    { type: "text", value: null }, // deezer_track_id
    { type: "text", value: null }, // musicbrainz_recording_id
    { type: "timestamptz", value: null }, // release_checked_at
    { type: "text[]", value: multiple ? line.artists : null },
    { type: "text[]", value: multiple ? line.artists.map(normalizeName) : null },
    { type: "text", value: null }, // media_url
  ];
}

/// Hybrid index row, minimal: enough for "which shows played this artist",
/// counts, and "where was this ISRC played".
function hybridMinimalRow(line: RovrLine): Column[] {
  return [
    UUID, // radio_episode_id
    { type: "int2", value: line.position },
    UUID, // artist_id
    { type: "text", value: line.isrc },
  ];
}

/// Hybrid index row that can also answer the artist page
/// (`artist_radio_appearances` returns title and offset per line).
function hybridArtistPageRow(line: RovrLine): Column[] {
  return [
    ...hybridMinimalRow(line),
    { type: "text", value: line.title },
    { type: "int4", value: line.startSeconds === null ? null : Math.round(line.startSeconds) },
  ];
}

/// The compact document for R2: one per playlist, lines as arrays in a fixed
/// column order so keys are not repeated per line.
const DOCUMENT_COLUMNS = ["position", "artist", "title", "isrc", "start", "end", "duration", "album", "label", "year", "youtube", "discogs"];
function documentFor(parse: RovrParse): string {
  return JSON.stringify({
    v: 1,
    parser: parse.parserVersion,
    source: parse.source,
    columns: DOCUMENT_COLUMNS,
    lines: parse.lines.filter((line) => line.status !== "skipped").map((line) => [
      line.position, line.artist, line.title, line.isrc, line.startSeconds, line.endSeconds,
      line.durationSeconds, line.album, line.label, line.year, line.links.youtube, line.links.discogs,
    ]),
  });
}

async function gzipBytes(text: string): Promise<number> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return (await new Response(stream).arrayBuffer()).byteLength;
}

// Live averages, measured read-only on 2026-10-17 (pg_relation_size of each
// relation / 262,306 rows; radio_episodes / 11,118 rows). They include bloat.
const LIVE = {
  appearanceHeap: 61_857_792 / 262_306,
  appearancePkey: 12_173_312 / 262_306,
  appearanceSlot: 16_293_888 / 262_306,
  appearanceArtist: 7_716_864 / 262_306,
  appearanceWholeTable: 122_298_368 / 262_306,
  episodeWholeTable: 10_240_000 / 11_118,
};

// ---------------------------------------------------------------------------
// Storage: measure every playlist
// ---------------------------------------------------------------------------

let relationalCopy = 0, relationalHeap = 0, relationalIndex = 0;
let minimalHeap = 0, minimalIndex = 0, artistPageHeap = 0, artistPageIndex = 0;
let documentJSON = 0, documentGzip = 0;
const documentKeys: string[] = [];

for (const { parse } of parsedPlaylists) {
  const lines = parse.lines.filter((line) => line.status !== "skipped");
  for (const line of lines) {
    const row = appearanceRow(line);
    relationalCopy += copyBytes(row);
    relationalHeap += heapBytes(row);
    // pkey (uuid), slot (uuid, int4), artist (uuid). The trigram index is
    // partial on media_url, which a ROVR line would not set.
    relationalIndex += btreeBytes(16) + btreeBytes(20) + btreeBytes(16);

    minimalHeap += heapBytes(hybridMinimalRow(line));
    // (episode, position) primary key, artist, and ISRC where present.
    const indexes = btreeBytes(18) + btreeBytes(16) + (line.isrc ? btreeBytes(13) : 0);
    minimalIndex += indexes;
    artistPageHeap += heapBytes(hybridArtistPageRow(line));
    artistPageIndex += indexes;
  }
  const document = documentFor(parse);
  documentJSON += utf8(document);
  documentGzip += await gzipBytes(document);
  documentKeys.push(`radio/rovr/${parse.source.externalID}.v${parse.parserVersion}.json.gz`);
}
// The source payloads themselves, compressed, for comparison only: storing
// them is copying ROVR's database, which has not been agreed.
let payloadGzip = 0;
for (const { file } of parsedPlaylists) payloadGzip += await gzipBytes(Deno.readTextFileSync(file));

const lineCount = kept.length;
const per = (bytes: number) => lineCount === 0 ? 0 : Math.round(bytes / lineCount * 10) / 10;
const perPlaylist = (bytes: number) => parsedPlaylists.length === 0 ? 0 : Math.round(bytes / parsedPlaylists.length);

/// The audit measured 26 lines per real ROVR playlist; the fixtures are
/// smaller on average, so projections use 26 for playlist counts.
const LINES_PER_PLAYLIST = 26;
const SCALES = [6_000, 14_000, 100_000, 1_000_000];
const project = (perLine: number, perPlaylistFixed: number) =>
  Object.fromEntries(SCALES.map((lines) => [lines, Math.round(perLine * lines + perPlaylistFixed * lines / LINES_PER_PLAYLIST)]));

const episodeRow = LIVE.episodeWholeTable;
const strategies = {
  A_fullRelational: {
    measuredCopyBytesPerLine: per(relationalCopy),
    estimatedHeapBytesPerLine: per(relationalHeap),
    estimatedIndexBytesPerLine: per(relationalIndex),
    estimatedTotalPerLine: per(relationalHeap + relationalIndex),
    liveMeasuredSameIndexesPerLine: Math.round(LIVE.appearanceHeap + LIVE.appearancePkey + LIVE.appearanceSlot + LIVE.appearanceArtist),
    liveMeasuredWholeTablePerLine: Math.round(LIVE.appearanceWholeTable),
    episodeRowBytes: Math.round(episodeRow),
    projectedPostgresBytes: project(LIVE.appearanceHeap + LIVE.appearancePkey + LIVE.appearanceSlot + LIVE.appearanceArtist, episodeRow),
  },
  B_r2Document: {
    measuredDocumentJSONBytesPerPlaylist: perPlaylist(documentJSON),
    measuredDocumentGzipBytesPerPlaylist: perPlaylist(documentGzip),
    measuredGzipBytesPerLine: per(documentGzip),
    sourcePayloadGzipBytesPerPlaylist: perPlaylist(payloadGzip),
    objectKeyExample: documentKeys[0] ?? null,
    episodeRowBytes: Math.round(episodeRow),
    projectedR2Bytes: project(documentGzip / Math.max(1, lineCount), 0),
    projectedPostgresBytes: project(0, episodeRow),
  },
  C1_hybridMinimal: {
    estimatedHeapBytesPerLine: per(minimalHeap),
    estimatedIndexBytesPerLine: per(minimalIndex),
    estimatedTotalPerLine: per(minimalHeap + minimalIndex),
    projectedPostgresBytes: project((minimalHeap + minimalIndex) / Math.max(1, lineCount), episodeRow),
    projectedR2Bytes: project(documentGzip / Math.max(1, lineCount), 0),
  },
  C2_hybridArtistPage: {
    estimatedHeapBytesPerLine: per(artistPageHeap),
    estimatedIndexBytesPerLine: per(artistPageIndex),
    estimatedTotalPerLine: per(artistPageHeap + artistPageIndex),
    projectedPostgresBytes: project((artistPageHeap + artistPageIndex) / Math.max(1, lineCount), episodeRow),
    projectedR2Bytes: project(documentGzip / Math.max(1, lineCount), 0),
  },
};

const report = {
  tool: "Scripts/rovr-dry-run.ts",
  readOnly: true,
  writes: out ? [out] : [],
  files,
  refused,
  counts,
  storage: {
    note: "measured = bytes produced here; estimated = Postgres layout arithmetic; live = averages of the live tables, read-only, 2026-10-17. Projections assume 26 lines per playlist.",
    linesMeasured: lineCount,
    playlistsMeasured: parsedPlaylists.length,
    strategies,
  },
};

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

if (out) Deno.writeTextFileSync(out, JSON.stringify(report, null, 2) + "\n");

if (asJSON) {
  console.log(JSON.stringify(report, null, 2));
} else {
  const kb = (bytes: number) => `${(bytes / 1024).toFixed(1)} KB`;
  const mb = (bytes: number) => `${(bytes / 1_048_576).toFixed(2)} MB`;
  const row = (label: string, value: unknown) => console.log(`  ${label.padEnd(44)} ${value}`);
  console.log("ROVR dry run — read-only. Nothing fetched, nothing written" + (out ? ` except ${out}` : "") + ".\n");
  console.log("Playlists");
  row("scanned / parsed / refused", `${counts.playlistsScanned} / ${counts.playlistsParsed} / ${counts.playlistsRefused}`);
  for (const refusal of refused) row(`  refused ${refusal.file}`, `${refusal.code}: ${refusal.detail}`);
  console.log("Lines");
  row("examined", counts.linesExamined);
  row("parsed / partial / skipped", `${counts.linesParsed} / ${counts.linesPartial} / ${counts.linesSkipped}`);
  row("flagged (≥1 warning) / warnings", `${counts.linesFlagged} / ${counts.warnings}`);
  row("with a valid ISRC / distinct ISRCs", `${counts.linesWithValidISRC} / ${counts.distinctISRCs}`);
  row("invalid ISRCs", counts.invalidISRCs);
  row("artist–title pairs (approximation)", counts.distinctArtistTitlePairsApprox);
  row("repeats within a playlist", counts.repeatsWithinPlaylists);
  row("records in more than one playlist", counts.recordsInMoreThanOnePlaylist);
  row("missing, by field", JSON.stringify(counts.missingByField));
  row("warnings, by code", JSON.stringify(counts.warningsByCode));
  row("matches to Indigo identifiers", "not measured");
  row("schema drift", counts.schemaDrift.length === 0 ? "none" : JSON.stringify(counts.schemaDrift));
  console.log(`\nStorage (${lineCount} lines in ${parsedPlaylists.length} playlists)`);
  const a = strategies.A_fullRelational, b = strategies.B_r2Document, c1 = strategies.C1_hybridMinimal, c2 = strategies.C2_hybridArtistPage;
  row("A relational: COPY bytes / line (measured)", a.measuredCopyBytesPerLine);
  row("A relational: heap + index / line (est.)", `${a.estimatedHeapBytesPerLine} + ${a.estimatedIndexBytesPerLine} = ${a.estimatedTotalPerLine}`);
  row("A relational: same indexes, live / line", a.liveMeasuredSameIndexesPerLine);
  row("B R2 doc: JSON / gzip per playlist (meas.)", `${b.measuredDocumentJSONBytesPerPlaylist} / ${b.measuredDocumentGzipBytesPerPlaylist}`);
  row("B R2 doc: gzip / line (measured)", b.measuredGzipBytesPerLine);
  row("B source payload gzip / playlist (meas.)", b.sourcePayloadGzipBytesPerPlaylist);
  row("C1 hybrid minimal: Postgres / line (est.)", `${c1.estimatedHeapBytesPerLine} + ${c1.estimatedIndexBytesPerLine} = ${c1.estimatedTotalPerLine}`);
  row("C2 hybrid + title/offset: Postgres / line", `${c2.estimatedHeapBytesPerLine} + ${c2.estimatedIndexBytesPerLine} = ${c2.estimatedTotalPerLine}`);
  row("episode row (live average, every design)", a.episodeRowBytes);
  console.log("\nProjected Postgres (A uses live per-line costs; C uses estimates; all add one episode row per 26 lines)");
  for (const scale of SCALES) {
    row(`${scale.toLocaleString("en")} lines`, `A ${mb(a.projectedPostgresBytes[scale])} · B ${mb(b.projectedPostgresBytes[scale])} + R2 ${kb(b.projectedR2Bytes[scale])} · C1 ${mb(c1.projectedPostgresBytes[scale])} · C2 ${mb(c2.projectedPostgresBytes[scale])}`);
  }
}
