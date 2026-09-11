// Discogs release payload -> Indigo's normalized tables.
//
// The cache alone keeps a screen fast; this is what makes the data queryable.
// DIG asks Postgres about labels and catalogue numbers, and it can only do that
// once a release is rows rather than a blob of provider JSON.
//
// Runs under the service-role key, which is the only context permitted to write
// these tables.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { normalizeName } from "./normalize.ts";

const PROVIDER = "discogs";

type Payload = Record<string, any>;

/// Finds the Indigo entity behind an upstream id, creating it the first time.
///
/// `external_ids` is the identity, not the name: two artists can share a name,
/// and the same artist can be spelled three ways across a catalogue. The unique
/// constraint on (provider, entity_type, external_id) makes the insert safe to
/// race — a loser re-reads the winner's row rather than creating a duplicate.
async function resolveEntity(
  supabase: SupabaseClient,
  table: string,
  entityType: string,
  externalID: string,
  row: Record<string, unknown>,
): Promise<string | null> {
  const existing = await supabase
    .from("external_ids")
    .select("entity_id")
    .eq("provider", PROVIDER)
    .eq("entity_type", entityType)
    .eq("external_id", externalID)
    .maybeSingle();

  if (existing.data?.entity_id) return existing.data.entity_id as string;

  const inserted = await supabase.from(table).insert(row).select("id").single();
  if (inserted.error || !inserted.data) {
    console.error(`normalize: insert into ${table} failed`, inserted.error?.message);
    return null;
  }
  const entityID = inserted.data.id as string;

  const link = await supabase.from("external_ids").insert({
    entity_type: entityType,
    entity_id: entityID,
    provider: PROVIDER,
    external_id: externalID,
    source_url: `https://www.discogs.com/${entityType}/${externalID}`,
  });

  // Lost a race: another invocation linked this id first. Its entity is the
  // canonical one, so adopt it and drop the row we just made.
  if (link.error) {
    await supabase.from(table).delete().eq("id", entityID);
    const winner = await supabase
      .from("external_ids")
      .select("entity_id")
      .eq("provider", PROVIDER)
      .eq("entity_type", entityType)
      .eq("external_id", externalID)
      .maybeSingle();
    return (winner.data?.entity_id as string) ?? null;
  }

  return entityID;
}

/// Filing conventions, not people. Treated as artists they wreck a graph:
/// every compilation in existence would connect through "Various".
const PLACEHOLDER_NAMES = new Set([
  "various", "various artists", "various artist",
  "unknown artist", "unknown artists", "unknown",
  "no artist", "not on label", "untitled",
]);

function isRealArtist(name: string | undefined): boolean {
  if (!name) return false;
  const key = normalizeName(name);
  return key.length > 0 && !PLACEHOLDER_NAMES.has(key);
}

export async function normalizeDiscogsRelease(
  supabase: SupabaseClient,
  payload: Payload,
): Promise<string | null> {
  const releaseID = payload?.id;
  if (releaseID === undefined || releaseID === null) return null;
  const releaseExternalID = String(releaseID);

  let artistUUID: string | null = null;
  const artist = Array.isArray(payload.artists) ? payload.artists[0] : undefined;
  if (artist?.id && isRealArtist(artist.name)) {
    artistUUID = await resolveEntity(supabase, "artists", "artist", String(artist.id), {
      name: artist.name,
      normalized_name: normalizeName(artist.name),
    });
  }

  let labelUUID: string | null = null;
  const label = Array.isArray(payload.labels) ? payload.labels[0] : undefined;
  if (label?.id && label?.name) {
    labelUUID = await resolveEntity(supabase, "labels", "label", String(label.id), {
      name: label.name,
      normalized_name: normalizeName(label.name),
    });
  }

  // Discogs reports an unknown year as 0, which would read as a real date.
  const year = Number(payload.year);
  const releaseYear = Number.isFinite(year) && year > 0 ? Math.trunc(year) : null;

  const format = Array.isArray(payload.formats) ? payload.formats[0]?.name : undefined;

  const releaseUUID = await resolveEntity(supabase, "releases", "release", releaseExternalID, {
    title: payload.title ?? "Untitled",
    artist_id: artistUUID,
    label_id: labelUUID,
    catalog_number: label?.catno ?? null,
    release_year: releaseYear,
    release_type: format ?? null,
  });

  if (!releaseUUID) return null;

  // Referenced, not re-hosted. Discogs does not clearly license permanent
  // copies of its images, so Indigo stores the URL and leaves the storage
  // paths empty; ArtworkRepository already treats that as a complete answer.
  const image = Array.isArray(payload.images)
    ? payload.images.find((candidate: Payload) => candidate?.type === "primary") ?? payload.images[0]
    : undefined;

  if (image?.uri) {
    const artwork = await supabase.from("artwork").upsert({
      entity_type: "release",
      entity_id: releaseUUID,
      provider: PROVIDER,
      original_url: image.uri,
      width: Number.isFinite(Number(image.width)) ? Math.trunc(Number(image.width)) : null,
      height: Number.isFinite(Number(image.height)) ? Math.trunc(Number(image.height)) : null,
      fetched_at: new Date().toISOString(),
    }, { onConflict: "entity_type,entity_id" });

    if (artwork.error) console.error("normalize: artwork upsert failed", artwork.error.message);
  }

  return releaseUUID;
}

/// Discogs' own filing marks, which are not part of anybody's name.
///
/// "Nirvana (2)" is how Discogs separates two bands that share a name, and the
/// trailing asterisk on "Flowdan*" says a record credited them under a variant
/// spelling. Both belong to the catalogue's bookkeeping rather than to the
/// artist, and filed here they become names nothing else in Indigo is stored
/// under — a row that matches a search and then opens onto an empty page.
///
/// The app strips them at the same boundary; see
/// `DiscogsClient.withoutDisambiguator`.
function withoutDisambiguator(title: string): string {
  return title
    .replace(/\s*\(\d+\)/g, "")
    .replace(/\*/g, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

/// The entities named in a `database/search` response, filed as rows.
///
/// Searches were being cached as a blob and normalized into nothing, so every
/// search anyone had ever run taught the catalogue exactly nothing — and the
/// catalogue is what `search_catalog` reads. This is the difference between a
/// backend that gets cheaper the more it is used and one that gets more
/// expensive.
///
/// **Artists and labels only, on purpose.** Those two tables hold a name, its
/// normalized form and a country, and an artist or label hit carries all
/// three: the row is finished rather than provisional.
///
/// A release hit is not. `releases` wants an artist and a label, and a search
/// result names neither by id — it carries "Artist - Title" as one string and
/// its labels as bare names. Worse, `resolveEntity` returns an existing entity
/// without updating it, so a credit-less stub written now would still be
/// credit-less after somebody opened the record and the full payload went
/// past. Releases reach these tables through `normalizeDiscogsRelease`, which
/// has the ids. A `master` hit is skipped for a second reason: its `id` is a
/// master id, and filing that as a release external id would point a later
/// lookup at the wrong thing entirely.
export async function normalizeDiscogsSearch(
  supabase: SupabaseClient,
  payload: Payload,
): Promise<number> {
  const results = Array.isArray(payload?.results) ? payload.results : [];
  let filed = 0;

  for (const result of results) {
    const target = searchTarget(result);
    if (!target) continue;

    const entityID = await resolveEntity(
      supabase,
      target.table,
      target.entityType,
      target.externalID,
      {
        name: target.name,
        normalized_name: normalizeName(target.name),
        country: target.country,
      },
    );
    if (entityID) filed += 1;
  }

  return filed;
}

/// What a single search hit should become, or nothing.
///
/// Exported for its own tests: everything it decides — which hits are filed at
/// all, and under what name — is invisible until somebody clicks a row that
/// opens onto nothing.
export function searchTarget(result: Payload): {
  table: string;
  entityType: string;
  externalID: string;
  name: string;
  country: string | null;
} | null {
  if (!result || result.id === undefined || result.id === null) return null;

  const type = String(result.type ?? "");
  if (type !== "artist" && type !== "label") return null;

  const name = withoutDisambiguator(String(result.title ?? ""));
  if (name.length === 0) return null;
  // The same filing conventions that must never enter the graph as artists.
  // "Not On Label" arrives as a label hit and is exactly as much of a label as
  // "Various" is an artist.
  if (!isRealArtist(name)) return null;

  const country = typeof result.country === "string" && result.country.length > 0
    ? result.country
    : null;

  return type === "artist"
    ? { table: "artists", entityType: "artist", externalID: String(result.id), name, country }
    : { table: "labels", entityType: "label", externalID: String(result.id), name, country };
}

/// Whether a cached search has already been filed.
///
/// The first hit worth filing stands for the response: normalization runs the
/// whole list in one pass, so if that one is present the rest went with it.
/// One indexed lookup, on a path that runs for every cache hit.
export async function isDiscogsSearchNormalized(
  supabase: SupabaseClient,
  payload: Payload,
): Promise<boolean> {
  const results = Array.isArray(payload?.results) ? payload.results : [];
  const first = results.map(searchTarget).find((target) => target !== null);
  // Nothing in this response belongs in the tables, which is a finished state
  // rather than an outstanding one.
  if (!first) return true;

  const { data } = await supabase
    .from("external_ids")
    .select("id")
    .eq("provider", PROVIDER)
    .eq("entity_type", first.entityType)
    .eq("external_id", first.externalID)
    .maybeSingle();

  return Boolean(data);
}

export const DISCOGS_SPACING_MS = 1000;
let lastPortraitRequestAt = 0;

/// Portrait searches, a second apart.
///
/// The portrait lane runs thirty of these back to back, and unspaced they go
/// out in about ten seconds — half the credential's minute gone in a burst,
/// with catalog-refresh answering listeners on the same token. Spaced, the
/// lane never takes more than thirty in any minute. See migration 0024.
/// Exported for its own test.
export async function pacedPortraitFetch(input: URL, init: RequestInit): Promise<Response> {
  const wait = lastPortraitRequestAt + DISCOGS_SPACING_MS - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  lastPortraitRequestAt = Date.now();
  return await fetch(input, init);
}

/// A picture of an artist, or the finding that Discogs has none.
///
/// Moved here from the app, where it ran as a background loop on every
/// listener's machine and was the largest single consumer of a Discogs budget
/// that all of them share. See migration 0019.
///
/// The name must match. Discogs ranks loosely and will happily return a
/// tribute band, a bootleg label or somebody else entirely for a name it does
/// not have — and a wrong portrait is worse than none, because nothing about
/// the page it lands on will say so. `withoutDisambiguator` is applied before
/// comparing, so the artist really called Bandulu still matches the row
/// Discogs files as "Bandulu (3)".
export async function fetchArtistPortrait(
  name: string,
  token: string | undefined,
  userAgent: string,
): Promise<{ url: string; width: number | null; height: number | null } | null> {
  const clean = name.trim();
  if (!clean) return null;

  const url = new URL("https://api.discogs.com/database/search");
  url.searchParams.set("q", clean);
  url.searchParams.set("type", "artist");
  url.searchParams.set("per_page", "5");

  const headers: Record<string, string> = {
    Accept: "application/json",
    "User-Agent": userAgent,
  };
  if (token) headers.Authorization = `Discogs token=${token}`;

  const response = await pacedPortraitFetch(url, { headers });
  // Thrown rather than swallowed: the queue's own retry is the right answer to
  // being told to slow down, and recording a miss here would write down "no
  // picture exists" on the strength of a refusal.
  if (response.status === 429) throw new Error("discogs_rate_limited");
  if (!response.ok) throw new Error(`discogs_${response.status}`);

  const payload = await response.json() as { results?: Payload[] };
  const wanted = normalizeName(clean);
  const match = (payload.results ?? []).find(
    (result) => normalizeName(withoutDisambiguator(String(result?.title ?? ""))) === wanted,
  );
  if (!match) return null;

  // `thumb` first: this fills a row, not a hero image, and the small cut is
  // the one the app actually draws.
  const picture = usableImage(match.thumb) ?? usableImage(match.cover_image);
  if (!picture) return null;

  return {
    url: picture,
    width: Number.isFinite(Number(match.width)) ? Math.trunc(Number(match.width)) : null,
    height: Number.isFinite(Number(match.height)) ? Math.trunc(Number(match.height)) : null,
  };
}

/// A Discogs image address, or nothing where Discogs is saying there is none.
///
/// A record with no sleeve in the index comes back as a real, loadable URL for
/// a transparent one-pixel gif. Stored, that is a portrait slot filled with
/// nothing — which reads as a picture that failed to load rather than as an
/// artist nobody has photographed, and stops the artist ever being asked about
/// again.
function usableImage(address: unknown): string | null {
  if (typeof address !== "string" || address.length === 0) return null;
  return address.includes("/images/spacer") ? null : address;
}
