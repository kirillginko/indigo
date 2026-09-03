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
