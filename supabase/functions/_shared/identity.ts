// One artist, two rows: linking them by what MusicBrainz says, not by name.
//
// Indigo's catalogue can hold the same person twice. "Anika" came in from NTS
// with her MusicBrainz id; "Anika (9)" came in from Discogs with its Discogs
// id. Nothing joined them, so asking about "anika" found the row without a
// Discogs id, and the Discogs knowledge -- her releases, her bundle -- was
// unreachable. Their names are no help: "(9)" is Discogs saying eight other
// artists are called Anika, so stripping it and matching would join her to
// whichever of them got there first.
//
// MusicBrainz records the link itself. An artist's entry lists their pages
// elsewhere ("url-rels"), Discogs among them. This reads that list for a row
// with an MBID and records every Discogs artist page it names, in
// external_ids under its own provider, `musicbrainz_discogs` -- so it is
// always visible where an identity came from, and a link MusicBrainz did not
// make is never recorded. More than one is common and true: Anika's entry
// names "Anika (9)" and "Annika Henderson", her name and her real name, both
// her. Which of them a lookup uses is the reader's decision
// (explore_knowledge uses the ones the catalogue holds data for); recording
// is not.
//
// Deliberately narrow: an MBID-to-Discogs link. Aliases and group membership
// are a separate stage.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { MB_USER_AGENT, MUSICBRAINZ_API, pacedFetch } from "./musicbrainz.ts";

export const LINK_PROVIDER = "musicbrainz_discogs";

/// The artist rows the pilot may link: the For You shadow's seed artists the
/// catalogue holds twice. Nothing else is linked until it has been reviewed.
export const PILOT_LINKS = new Set([
  "22904f8c-b792-413a-a70e-a2e73e7d5f30", // Anika (NTS row; Discogs row is "Anika (9)")
  "5dbab0e3-b85a-42e9-8c35-64529418a062", // Hype Williams (NTS row; Discogs row is "Hype Williams (2)")
]);

/// The Discogs artist ids an entry's url-rels name, sorted, once each.
/// Only artist pages count: a label or release page is not the artist.
export function discogsArtistIDs(entry: unknown): number[] {
  const relations = (entry as { relations?: unknown })?.relations;
  if (!Array.isArray(relations)) return [];
  const ids = new Set<number>();
  for (const relation of relations) {
    const resource = (relation as { url?: { resource?: unknown } })?.url?.resource;
    if (typeof resource !== "string") continue;
    const match = /^https?:\/\/(?:www\.)?discogs\.com\/(?:[a-z]{2}\/)?artist\/(\d+)(?:[-/?#].*)?$/i.exec(resource.trim());
    if (match) ids.add(Number(match[1]));
  }
  return [...ids].sort((a, b) => a - b);
}

export interface IdentityDeps {
  /// MusicBrainz's entry for an MBID with its url-rels.
  fetchArtist(mbid: string): Promise<{ status: number; body?: unknown }>;
  /// Records the link; says whether it was new, already there, or already
  /// claimed by another row.
  link(entityID: string, discogsID: number, sourceURL: string): Promise<"linked" | "exists" | "taken">;
}

export type LinkResult =
  | { status: "linked"; links: { discogsID: number; status: "linked" | "exists" | "taken" }[] }
  | { status: "none" }
  | { status: "unknown-mbid" };

export async function linkDiscogsIdentity(
  deps: IdentityDeps, job: { artistID: string; mbid: string },
): Promise<LinkResult> {
  if (!PILOT_LINKS.has(job.artistID)) throw new Error(`identity: ${job.artistID} is not in the pilot`);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(job.mbid)) {
    throw new Error(`identity: ${job.mbid} is not an MBID`);
  }
  const response = await deps.fetchArtist(job.mbid);
  if (response.status === 404) return { status: "unknown-mbid" };
  if (response.status !== 200) throw new Error(`musicbrainz ${response.status} for ${job.mbid}`);
  const candidates = discogsArtistIDs(response.body);
  if (candidates.length === 0) return { status: "none" };
  const links: { discogsID: number; status: "linked" | "exists" | "taken" }[] = [];
  for (const discogsID of candidates) {
    links.push({ discogsID, status: await deps.link(job.artistID, discogsID, `https://musicbrainz.org/artist/${job.mbid}`) });
  }
  return { status: "linked", links };
}

// MARK: - As the worker has them


export function liveIdentityDeps(supabase: SupabaseClient): IdentityDeps {
  return {
    async fetchArtist(mbid) {
      const url = new URL(`artist/${mbid}`, MUSICBRAINZ_API);
      url.searchParams.set("inc", "url-rels");
      url.searchParams.set("fmt", "json");
      const response = await pacedFetch(url, { headers: { Accept: "application/json", "User-Agent": MB_USER_AGENT } });
      if (!response.ok) {
        await response.body?.cancel();
        return { status: response.status };
      }
      return { status: 200, body: await response.json() };
    },
    async link(entityID, discogsID, sourceURL) {
      const externalID = String(discogsID);
      const { data: held, error } = await supabase
        .from("external_ids").select("entity_id")
        .eq("provider", LINK_PROVIDER).eq("entity_type", "artist").eq("external_id", externalID)
        .maybeSingle();
      if (error) throw new Error(`identity: lookup failed: ${error.message}`);
      if (held) return held.entity_id === entityID ? "exists" : "taken";
      const { error: insertError } = await supabase.from("external_ids").insert({
        entity_type: "artist", entity_id: entityID, provider: LINK_PROVIDER,
        external_id: externalID, source_url: sourceURL,
      });
      if (insertError) throw new Error(`identity: link failed: ${insertError.message}`);
      return "linked";
    },
  };
}
