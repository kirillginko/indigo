// What every station's tracklist has in common once it reaches Indigo.
//
// NTS and The Lot Radio publish their broadcasts in completely different
// shapes, but a line of a tracklist means the same thing from either: somebody
// played this record, on this show, at this point. So the part that turns a
// line into a `radio_appearances` row, and hands it to Postgres to resolve and
// graph, is written once here. A second copy would drift, and the first thing
// to drift would be which names count as nobody.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { normalizeName } from "./normalize.ts";
import { creditedNames } from "./credit.ts";

/// Names a selector uses when they did not identify what they played.
/// Resolving them would attach half a station's output to one imaginary
/// artist, so the row keeps its raw text and never gets a normalized form to
/// match on.
export const PLACEHOLDER_NAMES = new Set([
  "unknown", "unknown artist", "unknown artists", "id", "ids", "untitled",
  "unreleased", "white label", "various", "various artists", "n a", "tbc",
]);

export function matchableName(value: string | null): string | null {
  if (!value) return null;
  const key = normalizeName(value);
  if (key.length === 0 || PLACEHOLDER_NAMES.has(key)) return null;
  return key;
}

/// Who a line credits, and which of them the appearance belongs to.
///
/// Stations write a collaboration as one string, and this used to be matched
/// whole — so "DJ Krush, Abijah" became an artist, with a page and a search
/// result and DJ Krush's radio plays on it. Twenty percent of the artist table
/// was credits like that.
///
/// The appearance resolves to the primary credit, because `artist_id` is one
/// column and the first name is whose record it is. The rest are kept beside
/// it rather than thrown away: relating an appearance to every artist on it
/// wants a table of its own, and re-reading thousands of episodes to recover
/// names we already had in hand is exactly the cost migration 0025 was written
/// to avoid paying twice.
export function credit(raw: string | null): {
  key: string | null;
  names: string[];
  keys: string[];
} {
  const whole = matchableName(raw);
  if (whole === null) return { key: null, names: [], keys: [] };

  const names = creditedNames(raw);
  // One name, or a credit the splitter would not touch. Either way the whole
  // string is the artist, which is the ordinary case.
  if (names.length <= 1) return { key: whole, names: [], keys: [] };

  const keys = names.map(normalizeName).filter((key) => key.length > 0);
  const primary = keys.find((key) => !PLACEHOLDER_NAMES.has(key)) ?? null;
  return { key: primary, names, keys };
}

/// One line of a tracklist, as a station published it.
export interface TracklistLine {
  artist: string | null;
  title: string | null;
  offsetSeconds: number | null;
  isrc?: string | null;
  deezerTrackID?: string | null;
  musicbrainzRecordingID?: string | null;
  /// Where this one line can be heard on its own. Set by sources whose lines
  /// are each a separate recording -- a curator's YouTube uploads -- and
  /// null for a station's set, which is heard as a whole. See 0041.
  mediaURL?: string | null;
}

/// The rows a tracklist becomes, before anything is written.
///
/// The slot is the position in the published list, not any id the station
/// gives a track: a record played twice in one show is two slots, and the
/// position is what a re-import has to land on. A line with neither artist nor
/// title is dropped, leaving a gap in the numbering on purpose.
export function appearanceRows(episodeID: string, lines: TracklistLine[]) {
  return lines.map((line, index) => {
    const credited = credit(line.artist);
    return {
      radio_episode_id: episodeID,
      track_index: index,
      raw_artist_name: line.artist,
      raw_track_title: line.title,
      normalized_artist_name: credited.key,
      // Every name on the line, kept so a later pass can relate an appearance
      // to all of them without reading the episode again.
      credited_artist_names: credited.names.length > 0 ? credited.names : null,
      credited_artist_keys: credited.keys.length > 0 ? credited.keys : null,
      normalized_title: line.title ? normalizeName(line.title) : null,
      offset_seconds: line.offsetSeconds,
      // What the station identified the record as, where it says. NTS carries
      // these on around two lines in five; see migration 0025.
      isrc: line.isrc ?? null,
      deezer_track_id: line.deezerTrackID ?? null,
      musicbrainz_recording_id: line.musicbrainzRecordingID ?? null,
      media_url: line.mediaURL ?? null,
      identification_source: null,
    };
  }).filter((row) => row.raw_artist_name !== null || row.raw_track_title !== null);
}

/// Writes an episode's tracklist and hands it to Postgres to resolve.
///
/// `label` only prefixes the log lines, so a failure says which station's
/// ingest it came from.
export async function storeTracklist(
  supabase: SupabaseClient,
  episodeID: string,
  lines: TracklistLine[],
  label: string,
): Promise<void> {
  const rows = appearanceRows(episodeID, lines);

  if (rows.length > 0) {
    const written = await supabase
      .from("radio_appearances")
      .upsert(rows, { onConflict: "radio_episode_id,track_index" });
    if (written.error) console.error(`${label}: appearances upsert failed`, written.error.message);
  }

  // A corrected tracklist can be shorter than the one imported last time, and
  // upserting alone would leave the tail behind as tracks the show never
  // played. Keyed on the slots actually written rather than on a count,
  // because a line with neither artist nor title is dropped above and leaves a
  // gap in the numbering.
  const kept = rows.map((row) => row.track_index);
  let trimming = supabase.from("radio_appearances").delete().eq("radio_episode_id", episodeID);
  if (kept.length > 0) trimming = trimming.not("track_index", "in", `(${kept.join(",")})`);
  const trimmed = await trimming;
  if (trimmed.error) console.error(`${label}: stale slot delete failed`, trimmed.error.message);

  if (rows.length === 0) return;

  // Matching happens in Postgres, against rows it already has indexed. Doing
  // it here would mean a round trip per line of the tracklist.
  const resolved = await supabase.rpc("resolve_radio_appearances", { p_episode_id: episodeID });
  if (resolved.error) console.error(`${label}: resolve failed`, resolved.error.message);

  // Rebuilding the graph reads every appearance, so it is not something to do
  // once per episode while a page of them is landing. Queued instead, where
  // the dedupe key collapses the burst into a single rebuild.
  const queued = await supabase.rpc("enqueue_enrichment_job", {
    p_provider: "indigo",
    p_job_type: "rebuild_dig_edges",
    p_dedupe_key: "radio",
    p_payload: null,
    p_priority: -1,
    p_entity_type: null,
    p_entity_id: null,
  });
  if (queued.error) console.error(`${label}: rebuild enqueue failed`, queued.error.message);
}
