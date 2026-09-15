// Who a tracklist line credits, when it credits more than one person.
//
// NTS writes a collaboration as one string — "DJ Krush, Abijah", "Chuck
// Strangers, Billy Woods, Zeroh", "Jah Balla X MikeyNYC X Ibu DaDon" — and the
// ingest keyed `normalized_artist_name` on the whole of it. Every one of those
// became an artist: a page for a group that does not exist, a search result
// that opens onto nothing, and radio plays taken off the people who actually
// made the record. Measured on the live project: 9,013 of 45,158 artist rows,
// twenty percent of the table.
//
// Mirrors `ArtistName.split` in the app, separator for separator, because the
// two have to agree about who is on a record. `CreditParityTests` pins them.

import { normalizeName } from "./normalize.ts";

/// The separators that are safe to split on.
///
/// Deliberately *not* "&" or "and". The app's own comment says why: Holden &
/// Zimpel is a duo and Coco Steel & Lovebomb is a group, and splitting those
/// invents four people who do not exist. A comma does not do that, which is
/// why it is here and they are not — the cost of being wrong runs the other
/// way for them.
///
/// The dashes and the slash are spaced on purpose: an unspaced hyphen belongs
/// to the name carrying it, and splitting on it would make two people out of
/// Jean-Michel Jarre.
export const UNAMBIGUOUS_SEPARATORS = [
  " x ", " X ", " with ", " vs. ", " vs ", ", ",
  " feat. ", " feat ", " ft. ", " ft ", " featuring ",
  " - ", " – ", " — ", " / ",
];

/// Credits that stand for nobody in particular.
///
/// Matched on the whole normalised name, never as a prefix: "Various
/// Production" is a real group and "Unknown Mortal Orchestra" is a real band,
/// and both would be lost to a looser rule. Same list as `ArtistName`.
const PLACEHOLDERS = new Set([
  "various", "various artists", "various artist",
  "unknown artist", "unknown artists", "unknown",
  "no artist", "not on label", "untitled",
]);

export function isRealArtist(name: string | null | undefined): boolean {
  if (!name || name.trim().length === 0) return false;
  const key = normalizeName(name);
  // Nothing but punctuation. `isPlaceholder` in the app treats an empty key
  // as a placeholder, and so does this.
  if (key.length === 0) return false;
  return !PLACEHOLDERS.has(key);
}

/// The people named in a credit, spelled as the credit spelled them.
///
/// Returns the credit whole when it names one artist, which is the ordinary
/// case. Order is the credit's own, so the first is the primary.
export function creditedNames(credit: string | null | undefined): string[] {
  if (!credit || credit.length === 0) return [];

  let parts = [credit];
  for (const separator of UNAMBIGUOUS_SEPARATORS) {
    parts = parts.flatMap((part) => part.split(separator));
  }

  const seen = new Set<string>();
  const found: string[] = [];
  for (const part of parts) {
    const name = part.trim();
    if (!isRealArtist(name)) continue;
    const key = normalizeName(name);
    if (key.length === 0 || seen.has(key)) continue;
    seen.add(key);
    found.push(name);
  }
  return found;
}
