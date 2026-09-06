// MusicBrainz, crawled once for everybody.
//
// A scene page could only ever list the artists the listener's own catalogue
// had already met — eight names under "New York / Jazz", which is a story
// about one record collection rather than about a scene. MusicBrainz knows the
// rest: an artist there carries an area and a set of tags, which is exactly
// the two halves of a scene's address.
//
// It has to be crawled from here rather than from the app, and that is the
// reason this file exists. MusicBrainz asks for one request a second from a
// named client. A phone opening a scene page cannot honour that on its own,
// and a few hundred copies of the app cannot honour it at all — every one of
// them would be a separate anonymous client hammering the same endpoint. One
// crawler that paces itself fills a table in, and every copy reads the answer.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { normalizeName } from "./normalize.ts";

export const MUSICBRAINZ_API = "https://musicbrainz.org/ws/2/";
// MusicBrainz requires a client that says who it is and how to be reached.
// An anonymous or generic agent is throttled harder and may be refused.
export const MB_USER_AGENT = "Indigo/1.0 (+https://github.com/kirillginko/indigo)";

/// A hundred is MusicBrainz's own maximum, and one page is one request. A job
/// takes exactly one and enqueues the next, so a scene of four hundred names
/// is four polite requests spread over four drains rather than four at once.
export const MB_PAGE = 100;
/// However many names a scene runs to, past this it is a directory rather than
/// a scene, and nobody reads a directory.
export const MB_MAX_MEMBERS = 400;

interface MBArtist {
  id?: string;
  name?: string;
  score?: number;
  disambiguation?: string;
  area?: { name?: string };
  "life-span"?: { begin?: string; end?: string };
}

interface MBSearchResponse {
  count?: number;
  offset?: number;
  artists?: MBArtist[];
}

export interface SceneMember {
  name: string;
  normalized_name: string;
  mbid: string | null;
  area: string | null;
  began: string | null;
  ended: string | null;
  disambiguation: string | null;
  score: number;
}

/// The Lucene query a scene is.
///
/// Both halves are quoted and their own quotes stripped, so a place or a tag
/// cannot close the string and add clauses of its own. These values arrive
/// from `request_scene_roster`, which anybody may call.
export function sceneQuery(place: string | null, sound: string | null): string {
  const clean = (value: string) => value.replace(/["\\]/g, " ").trim();
  const parts: string[] = [];
  if (place && clean(place)) parts.push(`area:"${clean(place)}"`);
  if (sound && clean(sound)) parts.push(`tag:"${clean(sound)}"`);
  // A scene is a place, a sound, or both — Fourth World is not from anywhere,
  // and neither is spiritual jazz. Neither half is required; both being empty
  // is refused, because that query is "every artist".
  if (parts.length === 0) throw new Error("scene has neither a place nor a sound");
  return parts.join(" AND ");
}

/// One page of the artists MusicBrainz has in a place, making a sound.
export async function fetchScenePage(
  place: string | null,
  sound: string | null,
  offset: number,
): Promise<{ members: SceneMember[]; total: number; nextOffset: number }> {
  const url = new URL("artist", MUSICBRAINZ_API);
  url.searchParams.set("query", sceneQuery(place, sound));
  url.searchParams.set("fmt", "json");
  url.searchParams.set("limit", String(MB_PAGE));
  url.searchParams.set("offset", String(Math.max(0, offset)));

  const response = await fetch(url, {
    headers: { Accept: "application/json", "User-Agent": MB_USER_AGENT },
  });
  if (response.status === 503) {
    // MusicBrainz says so when it wants to be left alone. Treated as a
    // failure so the queue's own back-off decides when to try again.
    throw new Error("musicbrainz_busy");
  }
  if (!response.ok) throw new Error(`musicbrainz_${response.status}`);

  const payload = (await response.json()) as MBSearchResponse;
  const artists = payload.artists ?? [];
  const members: SceneMember[] = [];
  for (const artist of artists) {
    const name = (artist.name ?? "").trim();
    const normalized = normalizeName(name);
    if (!name || !normalized) continue;
    members.push({
      name,
      normalized_name: normalized,
      mbid: artist.id ?? null,
      area: artist.area?.name ?? null,
      began: year(artist["life-span"]?.begin),
      ended: year(artist["life-span"]?.end),
      disambiguation: artist.disambiguation ?? null,
      score: Number(artist.score ?? 0),
    });
  }
  const total = Number(payload.count ?? members.length);
  return { members, total, nextOffset: offset + artists.length };
}

function year(value: string | undefined): string | null {
  if (!value) return null;
  const found = value.slice(0, 4);
  return /^\d{4}$/.test(found) ? found : null;
}

/// Walks one page of a scene and records it, then asks for the next.
///
/// One page per job on purpose. Fetching the whole of a four-hundred-name
/// scene in a single invocation would be four requests inside one second,
/// which is how a polite crawler becomes an impolite one — the same reasoning
/// `discoverNTS` is built on.
export async function fillSceneRoster(
  supabase: SupabaseClient,
  rosterId: string,
  place: string | null,
  sound: string | null,
  offset: number,
): Promise<{ recorded: number; finished: boolean }> {
  const page = await fetchScenePage(place, sound, offset);
  const reached = page.nextOffset;
  const finished = page.members.length === 0
    || reached >= Math.min(page.total, MB_MAX_MEMBERS);

  const { error } = await supabase.rpc("record_scene_members", {
    p_roster_id: rosterId,
    p_members: page.members,
    p_next_offset: reached,
    p_total: page.total,
    p_finished: finished,
  });
  if (error) throw new Error(error.message);

  if (!finished) {
    // The same dedupe key as the request that started this, so a scene being
    // walked never has two jobs waiting for it.
    await supabase.rpc("enqueue_enrichment_job", {
      p_provider: "musicbrainz",
      p_job_type: "fetch_scene_roster",
      p_dedupe_key: `${place ? normalizeName(place) : ""}|${sound ? normalizeName(sound) : ""}`,
      p_payload: { roster_id: rosterId, place, sound },
      p_priority: 0,
      p_entity_type: null,
      p_entity_id: null,
    });
  }
  return { recorded: page.members.length, finished };
}
