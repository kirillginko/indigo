// A ROVR archived playlist -> one deterministic, line-by-line parse.
//
// Evaluation only. Nothing imports this outside its test and
// Scripts/rovr-dry-run.ts: there is no ingest lane for ROVR, and none may be
// added before the station has said its tracklists can be reused (see
// docs/radio-tracklist-audit.md, sections 6 and 10). This file reads no
// network, no database and no disk. It takes a payload somebody already has in
// hand and says what is in it.
//
// The shape is the detail answer of
// `GET strapi.rovr.live/api/playlists/archives/public/{documentId}`, as observed
// on 2026-10-17: the archive's own fields, a `tracks` array with one object per
// line, and `stitchedTracksMetadata.tracks_cues` giving where each line sits in
// the stitched recording. Which of those fields were seen and which are
// assumed is written down in testdata/rovr/README.md.
//
// What a line can and cannot claim:
//
//   * It is what ROVR published -- a curator's selection -- never a verified
//     recording. An ISRC is carried as the station wrote it, checked for
//     syntax only. A well-formed ISRC does not prove the artist and title on
//     the same line, and two lines with different ISRCs are never treated as
//     one record, however alike their names.
//   * A record played twice is two lines. Repeats are marked, never dropped.
//   * A field the station left out is "missing". A field it filled with
//     something unreadable is a warning on that line. The two are counted
//     apart, because only one of them is a parser's problem.
//
//     deno test supabase/functions/_shared/rovr_test.ts

import { normalizeName } from "./normalize.ts";
import { creditedNames } from "./credit.ts";
import { PLACEHOLDER_NAMES } from "./radio.ts";

export const ROVR_PARSER_VERSION = 1;

/// The only format this parser reads. A listing page (`archives/public?page=`)
/// carries no tracks and is refused by name rather than parsed into nothing.
export const ROVR_ARCHIVE_FORMAT = "rovr.archive.detail.v1";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type WarningCode =
  | "malformed_line" // a tracks[] entry that is not an object
  | "blank_line" // neither artist nor title
  | "wrong_type" // a field present with a type the shape never uses
  | "placeholder_artist" // "ID", "Unknown", "Various Artists"
  | "invalid_isrc" // present, but not twelve characters of ISRC syntax
  | "invalid_year"
  | "invalid_duration"
  | "invalid_offset" // a cue whose start/end is negative, non-finite or reversed
  | "out_of_order_offset" // starts before the line above it started
  | "duplicate_cue" // two cues for one track_index; the first is kept
  | "orphan_cue" // a cue for a track_index no line has
  | "invalid_link"; // a link field that is not an http(s) URL

export interface ParseWarning {
  code: WarningCode;
  /// Source index in `tracks[]`, or null for a playlist-level warning.
  line: number | null;
  field: string | null;
  detail: string;
}

export type IsrcStatus = "valid" | "missing" | "invalid";
export type LineStatus = "parsed" | "partial" | "skipped";

export interface RovrLine {
  /// Position in this parse: source order, counting every entry, skipped or
  /// not, so a line keeps its number when its neighbour is unreadable.
  position: number;
  /// ROVR's own id for this playlist row. Per playlist, not per recording:
  /// the same record in two playlists has two of these.
  sourceTrackID: string | null;
  status: LineStatus;
  /// The credit as published, cleaned of invisible characters.
  artist: string | null;
  /// Who the credit names, split only on separators that cannot belong to a
  /// name (see credit.ts). One element for the ordinary case.
  artists: string[];
  title: string | null;
  /// Names a title credits in "(feat. X)", reported and left in the title.
  titleCredits: string[];
  /// Keys a resolver would match on, never used here to merge anything.
  artistKey: string | null;
  titleKey: string | null;
  isrc: string | null;
  isrcStatus: IsrcStatus;
  album: string | null;
  label: string | null;
  year: number | null;
  /// Seconds into the stitched recording, to the millisecond, or null.
  startSeconds: number | null;
  endSeconds: number | null;
  durationSeconds: number | null;
  links: { youtube: string | null; discogs: string | null; spotify: string | null; apple: string | null };
  /// Fields the station left empty, by name, in a fixed order.
  missing: string[];
  /// Earlier position of the same record in this playlist (same ISRC, or
  /// same artist and title where neither line has an ISRC), else null.
  repeatOf: number | null;
  /// Source values that normalization changed, kept to explain the change.
  /// Absent when nothing changed.
  raw?: Partial<Record<"artist" | "title" | "isrc" | "label" | "album" | "year", unknown>>;
  warnings: number;
}

export interface RovrSource {
  provider: "rovr";
  station: "rovr.live";
  externalID: string | null;
  numericID: number | null;
  title: string | null;
  curator: string | null;
  releasedAt: string | null;
  scheduledAt: string | null;
  /// Where the recording itself is published, as ROVR links it.
  archiveURL: string | null;
  /// The API path this payload answers, for provenance. Never fetched here.
  apiPath: string | null;
  durationSeconds: number | null;
}

export interface SchemaReport {
  /// Fields the shape has never shown. Their presence is drift, not an error.
  unknownArchiveKeys: string[];
  unknownTrackKeys: string[];
  /// Fields every observed payload had, absent from this one.
  missingArchiveKeys: string[];
}

export interface RovrCounts {
  examined: number;
  parsed: number;
  partial: number;
  skipped: number;
  /// Lines with at least one warning, whatever their status.
  flagged: number;
  warnings: number;
}

export interface RovrParse {
  ok: true;
  format: typeof ROVR_ARCHIVE_FORMAT;
  parserVersion: number;
  source: RovrSource;
  lines: RovrLine[];
  warnings: ParseWarning[];
  counts: RovrCounts;
  schema: SchemaReport;
}

export interface RovrRefusal {
  ok: false;
  format: string;
  parserVersion: number;
  error: { code: "unsupported_format" | "not_an_object" | "listing_not_detail" | "no_tracks"; detail: string };
}

// ---------------------------------------------------------------------------
// What the shape is known to carry
// ---------------------------------------------------------------------------

/// Archive keys seen on the detail answer, 2026-10-17.
const KNOWN_ARCHIVE_KEYS = new Set([
  "aiDescription", "curator", "documentId", "genresData", "hasVoiceOver", "id",
  "overwriteShowDescription", "overwriteShowName", "overwriteShowRadioImage",
  "overwriteShowScheduleImage", "playlistProcessedAudioDuration", "playlistStatus",
  "playlistTags", "progress", "releaseDate", "scheduleDate", "show",
  "showEpisodeNumber", "soundcloudEmbedUrl", "soundcloudPermalinkUrl",
  "stitchedTracksMetadata", "title", "tracks", "voiceSoundcloudEmbedUrl",
  "voiceSoundcloudPermalinkUrl",
]);

/// Present on every detail answer sampled.
const EXPECTED_ARCHIVE_KEYS = ["documentId", "tracks", "stitchedTracksMetadata"];

/// Track keys seen on the detail answer, 2026-10-17.
const KNOWN_TRACK_KEYS = new Set([
  "id", "documentId", "title", "artist", "label", "album", "duration", "isrc",
  "tuc", "year", "youtube", "spotify", "apple", "discogs", "aiDetectedGenresData",
  "albumCoverUrl", "owner",
]);

/// The fields a line reports as missing, in the order it reports them.
const LINE_FIELDS = ["artist", "title", "isrc", "album", "label", "year", "duration", "offset"] as const;

/// ISO 3901: country (2 letters), registrant (3 alphanumerics), year (2
/// digits), designation (5 digits). Syntax only -- the country is not
/// checked against a list, because registries hand out non-ISO prefixes.
const ISRC = /^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$/;

/// Characters with no width that turn up inside ROVR labels
/// ("ST​​​-…") and would otherwise make two keys of one name.
const INVISIBLE = /[​-‍⁠﻿­]/g;

/// Strings that stand for no value. ROVR has been seen sending the year as the
/// literal string "None".
const NULLISH = new Set(["", "none", "null", "undefined", "n/a", "na", "-"]);

const FEATURING = /[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+)[\)\]]/i;

// ---------------------------------------------------------------------------
// Small readers
// ---------------------------------------------------------------------------

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// Seconds to the millisecond. Floating point cues arrive as 16.394000000001.
function millis(value: number): number {
  return Math.round(value * 1000) / 1000;
}

function cleanText(value: string): string {
  return value.replace(INVISIBLE, "").normalize("NFC").replace(/\s+/g, " ").trim();
}

interface Reader {
  warn(code: WarningCode, field: string | null, detail: string): void;
}

/// A text field: null when absent or nullish, a warning when it is not text.
function readText(
  track: Record<string, unknown>,
  field: string,
  reader: Reader,
  raw: Record<string, unknown>,
): string | null {
  const value = track[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    if (typeof value === "number" && Number.isFinite(value)) {
      // A title of 1 is the title "1"; keep it and say so.
      raw[field] = value;
      reader.warn("wrong_type", field, `number ${value} read as text`);
      return String(value);
    }
    reader.warn("wrong_type", field, `expected text, got ${Array.isArray(value) ? "array" : typeof value}`);
    return null;
  }
  const cleaned = cleanText(value);
  if (NULLISH.has(cleaned.toLowerCase())) return null;
  if (cleaned !== value) raw[field] = value;
  return cleaned;
}

function readISRC(
  track: Record<string, unknown>,
  reader: Reader,
  raw: Record<string, unknown>,
): { isrc: string | null; status: IsrcStatus } {
  const value = track.isrc;
  if (value === undefined || value === null) return { isrc: null, status: "missing" };
  if (typeof value !== "string") {
    raw.isrc = value;
    reader.warn("invalid_isrc", "isrc", `expected text, got ${typeof value}`);
    return { isrc: null, status: "invalid" };
  }
  const compact = value.replace(INVISIBLE, "").replace(/^\s*ISRC[:\s]*/i, "").replace(/[\s\-\.]/g, "").toUpperCase();
  if (NULLISH.has(compact.toLowerCase())) return { isrc: null, status: "missing" };
  if (compact !== value) raw.isrc = value;
  if (!ISRC.test(compact)) {
    raw.isrc = value;
    reader.warn("invalid_isrc", "isrc", `"${value}" is not ISRC syntax`);
    return { isrc: null, status: "invalid" };
  }
  return { isrc: compact, status: "valid" };
}

function readYear(track: Record<string, unknown>, reader: Reader, raw: Record<string, unknown>): number | null {
  const value = track.year;
  if (value === undefined || value === null) return null;
  const text = typeof value === "number" ? String(value) : typeof value === "string" ? value.trim() : null;
  if (text === null) {
    reader.warn("wrong_type", "year", `expected a year, got ${typeof value}`);
    return null;
  }
  if (NULLISH.has(text.toLowerCase())) {
    if (text !== "") raw.year = value;
    return null;
  }
  if (!/^\d{4}$/.test(text) || Number(text) < 1877 || Number(text) > 2100) {
    raw.year = value;
    reader.warn("invalid_year", "year", `"${text}" is not a year`);
    return null;
  }
  if (typeof value !== "number") raw.year = value;
  return Number(text);
}

function readDuration(track: Record<string, unknown>, reader: Reader): number | null {
  const value = track.duration;
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    reader.warn("invalid_duration", "duration", `${JSON.stringify(value)} is not a positive number of seconds`);
    return null;
  }
  return millis(value);
}

function readLink(track: Record<string, unknown>, field: string, reader: Reader): string | null {
  const value = track[field];
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || !/^https?:\/\/\S+$/i.test(value.trim())) {
    reader.warn("invalid_link", field, `${JSON.stringify(value).slice(0, 80)} is not a URL`);
    return null;
  }
  return value.trim();
}

function textField(record: Record<string, unknown>, field: string): string | null {
  const value = record[field];
  if (typeof value !== "string") return null;
  const cleaned = cleanText(value);
  return cleaned.length > 0 ? cleaned : null;
}

function numberField(record: Record<string, unknown>, field: string): number | null {
  const value = record[field];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

// ---------------------------------------------------------------------------
// Cues
// ---------------------------------------------------------------------------

interface Cue {
  start: number | null;
  end: number | null;
}

/// `tracks_cues` keyed by `track_index`. The array's own order is not trusted:
/// a cue says which line it belongs to.
function readCues(archive: Record<string, unknown>, warnings: ParseWarning[]): Map<number, Cue> {
  const cues = new Map<number, Cue>();
  const metadata = archive.stitchedTracksMetadata;
  const list = isObject(metadata) ? metadata.tracks_cues : undefined;
  if (!Array.isArray(list)) return cues;

  for (const entry of list) {
    if (!isObject(entry) || typeof entry.track_index !== "number" || !Number.isInteger(entry.track_index)) {
      warnings.push({ code: "invalid_offset", line: null, field: "tracks_cues", detail: "a cue with no integer track_index" });
      continue;
    }
    const index = entry.track_index;
    if (cues.has(index)) {
      warnings.push({ code: "duplicate_cue", line: index, field: "offset", detail: `second cue for track_index ${index} ignored` });
      continue;
    }
    const start = typeof entry.start === "number" && Number.isFinite(entry.start) && entry.start >= 0 ? millis(entry.start) : null;
    const end = typeof entry.end === "number" && Number.isFinite(entry.end) && entry.end >= 0 ? millis(entry.end) : null;
    const reversed = start !== null && end !== null && end <= start;
    if ((entry.start !== undefined && start === null) || (entry.end !== undefined && end === null) || reversed) {
      warnings.push({
        code: "invalid_offset",
        line: index,
        field: "offset",
        detail: `cue start ${JSON.stringify(entry.start)} end ${JSON.stringify(entry.end)} is unusable`,
      });
      cues.set(index, { start: null, end: null });
      continue;
    }
    cues.set(index, { start, end });
  }
  return cues;
}

// ---------------------------------------------------------------------------
// The parse
// ---------------------------------------------------------------------------

/// Reads one decoded detail payload. `format` is required so that a caller
/// holding something else -- a listing page, another station's archive --
/// gets a refusal that says so, not an empty success.
export function parseRovrArchive(payload: unknown, format: string = ROVR_ARCHIVE_FORMAT): RovrParse | RovrRefusal {
  const refuse = (code: RovrRefusal["error"]["code"], detail: string): RovrRefusal => ({
    ok: false,
    format,
    parserVersion: ROVR_PARSER_VERSION,
    error: { code, detail },
  });

  if (format !== ROVR_ARCHIVE_FORMAT) {
    return refuse("unsupported_format", `this parser reads ${ROVR_ARCHIVE_FORMAT}, not ${format}`);
  }
  // Strapi answers `{ data, meta }`; a payload already unwrapped is accepted.
  const envelope = isObject(payload) && "data" in payload ? payload.data : payload;
  if (Array.isArray(envelope)) {
    return refuse("listing_not_detail", "a list of archives is a listing page, which carries no tracks");
  }
  if (!isObject(envelope)) return refuse("not_an_object", `expected an archive object, got ${envelope === null ? "null" : typeof envelope}`);
  const archive = envelope;
  if (!Array.isArray(archive.tracks)) {
    return refuse("no_tracks", "no tracks array: not a detail answer, or the shape has changed");
  }

  const warnings: ParseWarning[] = [];
  const cues = readCues(archive, warnings);
  const tracks = archive.tracks as unknown[];
  const lines: RovrLine[] = [];
  const unknownTrackKeys = new Set<string>();
  const firstSeen = new Map<string, number>();
  let previousStart: number | null = null;

  tracks.forEach((entry, position) => {
    const reader: Reader = {
      warn(code, field, detail) {
        warnings.push({ code, line: position, field, detail });
      },
    };
    const empty: RovrLine = {
      position, sourceTrackID: null, status: "skipped", artist: null, artists: [], title: null,
      titleCredits: [], artistKey: null, titleKey: null, isrc: null, isrcStatus: "missing",
      album: null, label: null, year: null, startSeconds: null, endSeconds: null, durationSeconds: null,
      links: { youtube: null, discogs: null, spotify: null, apple: null },
      missing: [...LINE_FIELDS], repeatOf: null, warnings: 0,
    };

    if (!isObject(entry)) {
      reader.warn("malformed_line", null, `entry is ${entry === null ? "null" : Array.isArray(entry) ? "an array" : typeof entry}`);
      lines.push(empty);
      return;
    }
    for (const key of Object.keys(entry)) if (!KNOWN_TRACK_KEYS.has(key)) unknownTrackKeys.add(key);

    const raw: Record<string, unknown> = {};
    let artist = readText(entry, "artist", reader, raw);
    const title = readText(entry, "title", reader, raw);
    if (artist !== null && PLACEHOLDER_NAMES.has(normalizeName(artist))) {
      raw.artist = entry.artist;
      reader.warn("placeholder_artist", "artist", `"${artist}" names nobody`);
      artist = null;
    }
    const { isrc, status: isrcStatus } = readISRC(entry, reader, raw);
    const album = readText(entry, "album", reader, raw);
    const label = readText(entry, "label", reader, raw);
    const year = readYear(entry, reader, raw);
    const durationSeconds = readDuration(entry, reader);
    const links = {
      youtube: readLink(entry, "youtube", reader),
      discogs: readLink(entry, "discogs", reader),
      spotify: readLink(entry, "spotify", reader),
      apple: readLink(entry, "apple", reader),
    };

    const cue = cues.get(position);
    const startSeconds = cue?.start ?? null;
    const endSeconds = cue?.end ?? null;
    if (startSeconds !== null && previousStart !== null && startSeconds < previousStart) {
      // Kept as published and in source order. Overlap with the line above
      // (a crossfade) is ordinary; starting before it started is not.
      reader.warn("out_of_order_offset", "offset", `starts at ${startSeconds}s, before the line above (${previousStart}s)`);
    }
    if (startSeconds !== null) previousStart = startSeconds;

    const sourceTrackID = typeof entry.documentId === "string" && entry.documentId.length > 0
      ? entry.documentId
      : typeof entry.id === "number" ? String(entry.id) : null;

    if (artist === null && title === null) {
      reader.warn("blank_line", null, "neither artist nor title");
      lines.push({ ...empty, sourceTrackID, isrc, isrcStatus, ...(Object.keys(raw).length > 0 ? { raw } : {}) });
      return;
    }

    const artists = artist === null ? [] : creditedNames(artist).map(cleanText).filter((name) => name.length > 0);
    const featuring = title?.match(FEATURING)?.[1];
    const titleCredits = featuring ? creditedNames(cleanText(featuring)) : [];
    const artistKey = artist === null ? null : normalizeName(artist) || null;
    const titleKey = title === null ? null : normalizeName(title) || null;

    // The same record twice in one playlist. Identity is the ISRC where the
    // line has one; names only stand in when neither line does, so two
    // different ISRCs under one name stay two records.
    const repeatKey = isrc !== null
      ? `isrc:${isrc}`
      : artistKey !== null && titleKey !== null ? `name:${artistKey}\u0000${titleKey}` : null;
    let repeatOf: number | null = null;
    if (repeatKey !== null) {
      repeatOf = firstSeen.get(repeatKey) ?? null;
      if (repeatOf === null) firstSeen.set(repeatKey, position);
    }

    const missing: string[] = [];
    const present: Record<(typeof LINE_FIELDS)[number], boolean> = {
      artist: artist !== null,
      title: title !== null,
      isrc: isrcStatus !== "missing",
      album: album !== null,
      label: label !== null,
      year: year !== null || (entry.year !== undefined && entry.year !== null && !NULLISH.has(String(entry.year).trim().toLowerCase())),
      duration: durationSeconds !== null || (entry.duration !== undefined && entry.duration !== null),
      offset: cue !== undefined,
    };
    for (const field of LINE_FIELDS) if (!present[field]) missing.push(field);

    lines.push({
      position,
      sourceTrackID,
      status: artist !== null && title !== null ? "parsed" : "partial",
      artist,
      artists,
      title,
      titleCredits,
      artistKey,
      titleKey,
      isrc,
      isrcStatus,
      album,
      label,
      year,
      startSeconds,
      endSeconds,
      durationSeconds,
      links,
      missing,
      repeatOf,
      ...(Object.keys(raw).length > 0 ? { raw } : {}),
      warnings: 0,
    });
  });

  for (const index of [...cues.keys()].sort((a, b) => a - b)) {
    if (index < 0 || index >= tracks.length) {
      warnings.push({ code: "orphan_cue", line: null, field: "offset", detail: `cue for track_index ${index}, which no line has` });
    }
  }

  // Cue warnings are raised before the lines exist, so a line's own count is
  // taken from the list once everything has been read.
  const perLine = new Map<number, number>();
  for (const warning of warnings) {
    if (warning.line !== null) perLine.set(warning.line, (perLine.get(warning.line) ?? 0) + 1);
  }
  for (const line of lines) line.warnings = perLine.get(line.position) ?? 0;

  const curator = isObject(archive.curator) ? textField(archive.curator, "name") : null;
  const externalID = typeof archive.documentId === "string" && archive.documentId.length > 0 ? archive.documentId : null;
  const source: RovrSource = {
    provider: "rovr",
    station: "rovr.live",
    externalID,
    numericID: numberField(archive, "id"),
    title: textField(archive, "title"),
    curator,
    releasedAt: textField(archive, "releaseDate"),
    scheduledAt: textField(archive, "scheduleDate"),
    archiveURL: textField(archive, "soundcloudPermalinkUrl"),
    apiPath: externalID ? `playlists/archives/public/${externalID}` : null,
    durationSeconds: (() => {
      const value = numberField(archive, "playlistProcessedAudioDuration");
      return value !== null && value > 0 ? millis(value) : null;
    })(),
  };

  const counts: RovrCounts = {
    examined: lines.length,
    parsed: lines.filter((line) => line.status === "parsed").length,
    partial: lines.filter((line) => line.status === "partial").length,
    skipped: lines.filter((line) => line.status === "skipped").length,
    flagged: lines.filter((line) => line.warnings > 0).length,
    warnings: warnings.length,
  };

  return {
    ok: true,
    format: ROVR_ARCHIVE_FORMAT,
    parserVersion: ROVR_PARSER_VERSION,
    source,
    lines,
    warnings,
    counts,
    schema: {
      unknownArchiveKeys: Object.keys(archive).filter((key) => !KNOWN_ARCHIVE_KEYS.has(key)).sort(),
      unknownTrackKeys: [...unknownTrackKeys].sort(),
      missingArchiveKeys: EXPECTED_ARCHIVE_KEYS.filter((key) => !(key in archive)),
    },
  };
}
