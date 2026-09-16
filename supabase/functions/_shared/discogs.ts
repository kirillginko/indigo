// Discogs release payload -> Indigo's normalized tables.
//
// The cache alone keeps a screen fast; this is what makes the data queryable.
// DIG asks Postgres about labels and catalogue numbers, and it can only do that
// once a release is rows rather than a blob of provider JSON.
//
// Runs under the service-role key, which is the only context permitted to write
// these tables.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { storeReleasePayload } from "./release_cache.ts";
import { normalizeName } from "./normalize.ts";

const PROVIDER = "discogs";

type Payload = Record<string, any>;

/// The row Indigo already has for this name, when it is plainly the same
/// entity and not merely a namesake.
///
/// Only ever adopts a row whose *entire* identity is a name — one that
/// `adopt_radio_artists` created because NTS gave it nothing else. Such a row
/// asserts "somebody called this"; attaching the Discogs id answers who.
///
/// Refuses on any hint of ambiguity, and those refusals are the point:
///
///   * two rows share the name — one of them may be the right one and there is
///     nothing here that can say which;
///   * the row already carries an id from some provider — then Discogs has
///     numbered these as different artists, and Disorder (2) is not Disorder
///     (3). On the live project 49 names are exactly this, against 85 that are
///     one artist split in half.
///
/// Refusing means inserting a second row, which is what this did for every name
/// before. No worse than it was, and only ever where the answer is genuinely
/// unknown.
async function adoptNameKeyedRow(
  supabase: SupabaseClient,
  table: string,
  entityType: string,
  externalID: string,
  row: Record<string, unknown>,
): Promise<string | null> {
  const key = typeof row.normalized_name === "string" ? row.normalized_name : "";
  if (!key) return null;

  // Two is already too many to choose between, so ask for two and refuse.
  const named = await supabase.from(table).select("id").eq("normalized_name", key).limit(2);
  if (named.error || !named.data || named.data.length !== 1) return null;

  const candidate = named.data[0].id as string;

  const identities = await supabase
    .from("external_ids")
    .select("id")
    .eq("entity_type", entityType)
    .eq("entity_id", candidate)
    .neq("provider", "nts")
    .limit(1);
  if (identities.error || (identities.data?.length ?? 0) > 0) return null;

  const link = await supabase.from("external_ids").insert({
    entity_type: entityType,
    entity_id: candidate,
    provider: PROVIDER,
    external_id: externalID,
    source_url: `https://www.discogs.com/${entityType}/${externalID}`,
  });

  // Lost a race to another invocation claiming this same id. Whoever won holds
  // the canonical row, and the caller's own lookup will find it.
  if (link.error) return null;
  return candidate;
}

/// Finds the Indigo entity behind an upstream id, creating it the first time.
///
/// `external_ids` is the identity, not the name: two artists can share a name,
/// and the same artist can be spelled three ways across a catalogue. The unique
/// constraint on (provider, entity_type, external_id) makes the insert safe to
/// race — a loser re-reads the winner's row rather than creating a duplicate.
///
/// The one exception is below, and it exists because Indigo files artists two
/// ways. `adopt_radio_artists` has no id to file under — NTS publishes a name
/// and nothing else — so it keys on the name. Looking up only by Discogs id
/// therefore missed those rows every time, and inserted beside them: opening
/// The Beatles wrote a second Beatles, leaving 23 radio appearances on one row
/// and the Discogs id on the other. See migration 0028.
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

  const adopted = await adoptNameKeyedRow(supabase, table, entityType, externalID, row);
  if (adopted) return adopted;

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

// ---------------------------------------------------------------------------
// Filling the release cache
// ---------------------------------------------------------------------------

export const DISCOGS_API = "https://api.discogs.com/";

let lastCacheRequestAt = 0;

/// Cache-filling requests, a second apart.
///
/// Held separately from `pacedPortraitFetch` on purpose: they are different
/// lanes claiming different job types, and a shared cursor would make each wait
/// on the other's clock without either being able to see why. A second apart
/// each, two lanes running, is twenty requests a minute out of sixty — and the
/// portrait lane's own comment already spends thirty of the other forty.
/// Exported for its own test.
export async function pacedCacheFetch(url: string, token: string | undefined): Promise<Response> {
  const wait = lastCacheRequestAt + DISCOGS_SPACING_MS - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  lastCacheRequestAt = Date.now();

  const headers: Record<string, string> = {
    Accept: "application/json",
    "User-Agent": "Indigo/1.0 (+https://github.com/kirillginko/indigo)",
  };
  if (token) headers.Authorization = `Discogs token=${token}`;
  return await fetch(url, { headers });
}

/// How long a cached release is worth reading. Matches
/// `release_cache_lifetime()` in migration 0027 and
/// `MetadataRepository.Lifetime.release` in the app; all three decide the same
/// thing and have to agree about it.
export const RELEASE_CACHE_TTL_SECONDS = 60 * 24 * 60 * 60;

/// How long a shelf is worth reading. Shorter than a release's sixty days: a
/// record never changes, but an artist's discography gains one whenever they
/// put something out. Matches `MetadataRepository.Lifetime.artist`.
export const SHELF_CACHE_TTL_SECONDS = 30 * 24 * 60 * 60;

/// One release, fetched and written to the shared cache.
///
/// The point of the whole path: this record is described once here instead of
/// once per listener per page open. Returns false when Discogs would not answer,
/// so the queue can back off rather than record a record that does not exist.
export async function cacheDiscogsRelease(
  supabase: SupabaseClient,
  releaseID: string,
  token: string | undefined,
): Promise<boolean> {
  if (!/^[0-9]{1,12}$/.test(releaseID)) {
    throw new Error(`refusing a release id that is not digits: ${releaseID}`);
  }

  const response = await pacedCacheFetch(`${DISCOGS_API}releases/${releaseID}`, token);

  // A release that does not exist is an answer, and it is the queue's job to
  // stop asking. Everything else — a throttle, an outage — has to come back.
  if (response.status === 404) return false;
  if (!response.ok) throw new Error(`discogs ${response.status} for releases/${releaseID}`);

  const payload = await response.json();

  // The document to Storage, and a row that says where (0036). Uploaded first
  // and awaited, so a failure throws before any row can point at nothing, and
  // the queue's backoff brings the job round again.
  const payloadPath = await storeReleasePayload(supabase, releaseID, payload);

  const written = await supabase
    .from("metadata_cache")
    .upsert({
      provider: PROVIDER,
      resource_type: "release",
      resource_id: releaseID,
      payload: null,
      payload_path: payloadPath,
      fetched_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + RELEASE_CACHE_TTL_SECONDS * 1000).toISOString(),
    }, { onConflict: "provider,resource_type,resource_id" });

  if (written.error) throw new Error(written.error.message);

  // The normalized tables too, not just the blob. `search_catalog` reads
  // `releases` and `labels`, and a cache that only fed the app's release page
  // would leave search exactly as empty as it is now.
  await normalizeDiscogsRelease(supabase, payload);
  return true;
}

/// An artist's shelf, turned into one job per release on it.
///
/// Fans out rather than fetching here. A shelf is fifty records and this
/// function has one invocation's worth of time; queued individually they spread
/// across the lane's own pace, and a shelf half-walked when the function times
/// out is still a shelf half-cached rather than nothing.
/// The shelf query the app sends, and the key it will look under.
///
/// Both halves have to match `DiscogsClient.artistShelf` exactly: the app
/// reads this row straight out of Postgres without going through
/// catalog-refresh, so a different `per_page` here is a row nobody ever finds.
/// The key format is `resolvePath`'s — path, then the params sorted and joined
/// raw — and `CatalogPathKeyTests` pins the two sides together.
export const SHELF_QUERY = "per_page=50&sort=year&sort_order=desc";

export function shelfPath(discogsID: string): string {
  return `artists/${discogsID}/releases`;
}

export async function cacheDiscogsShelf(
  supabase: SupabaseClient,
  artistID: string | null,
  discogsID: string,
  token: string | undefined,
): Promise<number> {
  if (!/^[0-9]{1,12}$/.test(discogsID)) {
    throw new Error(`refusing an artist id that is not digits: ${discogsID}`);
  }

  const path = shelfPath(discogsID);
  const response = await pacedCacheFetch(
    `${DISCOGS_API}${path}?sort=year&sort_order=desc&per_page=50`,
    token,
  );
  // An artist Discogs files nothing under is a finding; the caller stamps it
  // either way, which is what stops the crawl returning to them.
  if (response.status === 404) return 0;
  if (!response.ok) {
    throw new Error(`discogs ${response.status} for ${path}`);
  }

  const page = await response.json() as Payload;

  // The listing itself, kept rather than thrown away once it has been read
  // for ids.
  //
  // This is the request a cold artist page waits on and the slowest one it
  // makes — measured at 2,727ms for Ryuichi Sakamoto and 1,916ms for Haruomi
  // Hosono against a Discogs that was not refusing anything. The crawl was
  // already fetching exactly this listing, for exactly these artists, and
  // discarding it after enqueuing the releases named in it.
  const stored = await supabase
    .from("metadata_cache")
    .upsert({
      provider: PROVIDER,
      resource_type: path,
      resource_id: `${path}?${SHELF_QUERY}`,
      payload: page,
      fetched_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + SHELF_CACHE_TTL_SECONDS * 1000).toISOString(),
    }, { onConflict: "provider,resource_type,resource_id" });
  if (stored.error) console.error("shelf: cache write failed", stored.error.message);

  const listed: Payload[] = Array.isArray(page.releases) ? page.releases : [];

  let queued = 0;
  for (const entry of listed) {
    // `main_release` is the id of the actual pressing behind a master; the
    // master's own id is not a release and `releases/{id}` does not answer for
    // it. Where there is no master, `id` is already the release.
    const id = entry.type === "master"
      ? (entry.main_release ?? null)
      : (entry.id ?? null);
    if (id === null || id === undefined) continue;
    const releaseID = String(id);
    if (!/^[0-9]{1,12}$/.test(releaseID)) continue;

    const { error } = await supabase.rpc("enqueue_enrichment_job", {
      p_provider: PROVIDER,
      p_job_type: "cache_discogs_release",
      p_dedupe_key: releaseID,
      p_payload: { release_id: releaseID },
      // Below a page's own request at 1. Nobody is reading this shelf yet.
      p_priority: 0,
      p_entity_type: null,
      p_entity_id: null,
    });
    if (error) {
      console.error("shelf: enqueue failed", releaseID, error.message);
      continue;
    }
    queued += 1;
  }

  // A shelf asked for by a page has no Indigo artist row to stamp — the app
  // knows the Discogs id and nothing else. The crawl's own jobs always carry
  // one, and that is what stops it returning to the same artist.
  if (artistID) {
    const stamped = await supabase.rpc("record_shelf_cached", { p_artist_id: artistID });
    if (stamped.error) throw new Error(stamped.error.message);
  }
  return queued;
}
