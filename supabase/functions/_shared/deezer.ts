// The record behind a tracklist line.
//
// NTS identifies most of what it plays. Every line of a published tracklist can
// carry `isrc_id`, `deezer_track_id` and `musicbrainz_track_id`, and until
// migration 0025 the ingest kept the artist, the title and none of the three.
// That is the difference between knowing a record was played and knowing which
// record it was, and it is not recoverable afterwards by matching names: two
// tracks called "Drift" normalize to the same string and are different records.
//
// Deezer is asked rather than MusicBrainz because MusicBrainz cannot answer.
// Thirty ISRCs taken off real NTS tracklists and looked up at
// `ws/2/isrc/{isrc}` returned nothing at all -- not a poor match, no recording
// -- and took eight minutes of 503s to do it. The same tracks by their Deezer
// id: twenty-five out of twenty-five, twenty-three of them naming the label.
// Honest Jon's Records, Deep Medi Musik, Buh Records, Star Creature, Quindi.
//
// What Deezer is trusted for is deliberately narrow. It names the album, the
// year and the imprint; it is never asked who the artist is. The appearances
// already resolved to an artist through Indigo's own normalizer, and a second
// opinion in Deezer's spelling would be free to disagree with the first.

export const DEEZER_API = "https://api.deezer.com/";

/// Deezer publishes no rate limit worth the name -- the documented ceiling is
/// fifty requests in five seconds per address, and a lookup here is two. This
/// is well under it and leaves the burst allowance for anything else sharing
/// the address. Measured: fifty requests in about fifteen seconds.
export const DEEZER_SPACING_MS = 250;
let lastRequestAt = 0;

/// Every request to Deezer, spaced. Held per worker invocation, which is where
/// a burst would come from: the drain claims thirty jobs and runs them back to
/// back. Exported for its own test.
export async function pacedFetch(url: string): Promise<Response> {
  const wait = lastRequestAt + DEEZER_SPACING_MS - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  lastRequestAt = Date.now();
  return await fetch(url, {
    headers: { Accept: "application/json", "User-Agent": "Indigo/1.0" },
  });
}

export interface TrackRelease {
  trackTitle: string | null;
  albumTitle: string | null;
  albumID: string | null;
  label: string | null;
  releaseYear: number | null;
  isrc: string | null;
}

type Payload = Record<string, any>;

/// Deezer reports a miss as `200` with an `error` object rather than a status,
/// so a response that parsed is not yet an answer.
async function get(path: string): Promise<Payload | null> {
  const response = await pacedFetch(`${DEEZER_API}${path}`);
  if (!response.ok) {
    // A rate limit is worth retrying and a 404 is not, and the queue's backoff
    // is the only thing that can tell them apart -- so only the first throws.
    if (response.status === 429 || response.status >= 500) {
      throw new Error(`deezer ${response.status} for ${path}`);
    }
    return null;
  }
  const payload = await response.json() as Payload;
  if (payload?.error) {
    const code = Number(payload.error?.code);
    // 4 is Deezer's own quota code, and it arrives with a 200.
    if (code === 4) throw new Error(`deezer quota exceeded for ${path}`);
    return null;
  }
  return payload;
}

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const cleaned = value.trim();
  return cleaned.length > 0 ? cleaned : null;
}

/// The year off a Deezer date, which is `YYYY-MM-DD` when it is anything.
///
/// Bounded rather than merely parsed: Deezer files a release it has no date for
/// as `0000-00-00`, and a year of zero on a record's page is worse than no year
/// at all.
function year(value: unknown): number | null {
  const parsed = Number.parseInt(String(value ?? "").slice(0, 4), 10);
  if (!Number.isFinite(parsed)) return null;
  return parsed >= 1900 && parsed <= new Date().getFullYear() + 1 ? parsed : null;
}

/// One track, and the album it came off.
///
/// Two requests, and the second is the one that matters: a Deezer track names
/// its album but not its label, and the label is the whole reason for asking.
/// A track that resolves to no album is still an answer -- the caller writes
/// down that it looked, which is what stops the queue asking again for ever.
export async function fetchTrackRelease(trackID: string): Promise<TrackRelease | null> {
  const track = await get(`track/${encodeURIComponent(trackID)}`);
  if (!track) return null;

  const albumID = track.album?.id != null ? String(track.album.id) : null;
  const found: TrackRelease = {
    trackTitle: text(track.title),
    albumTitle: text(track.album?.title),
    albumID,
    label: null,
    releaseYear: year(track.release_date),
    isrc: text(track.isrc),
  };

  if (!albumID) return found;

  const album = await get(`album/${encodeURIComponent(albumID)}`);
  if (!album) return found;

  found.albumTitle = text(album.title) ?? found.albumTitle;
  found.label = text(album.label);
  found.releaseYear = year(album.release_date) ?? found.releaseYear;
  return found;
}
