// Which radio artists could get a verified Discogs identity from ids Indigo
// already holds -- asked of MusicBrainz, written nowhere.
//
// 91% of the artists heard on radio have no Discogs id, and DIG's track
// discovery is keyed on Discogs, so they are out of its reach. Two routes
// exist, and only one is evidence:
//
//   * recording route (verified): NTS published a MusicBrainz *recording* id
//     on one of the artist's lines. That recording's credit names MusicBrainz
//     artists; the one whose name is the line's artist is the artist, by the
//     station's own identification. Its MusicBrainz entry then names its
//     Discogs pages (identity.ts, discogsArtistIDs).
//   * artist-mbid route (NOT verified): `artists.musicbrainz_id`, which the
//     origins lane filled by searching MusicBrainz for the name and taking the
//     first exact match (musicbrainz.ts, fetchArtistOrigin). Following it to
//     Discogs would be merging by name. Here it is only measured: how often
//     MusicBrainz holds more than one artist of exactly that name.
//
// Input: candidate exports from the linked CLI (read-only queries; see
// docs/radio-enrichment-pilot.md). Output: a report on stdout and, with --out,
// per-artist results in one local file.
//
//   deno run --allow-read=<dir> --allow-net=musicbrainz.org [--allow-write=<out>] \
//       Scripts/radio-identity-dry-run.ts --recording <route2.json> --artist-mbid <route1.json> [--out <file>]

import { discogsArtistIDs } from "../supabase/functions/_shared/identity.ts";
import { MB_USER_AGENT, MUSICBRAINZ_API, pacedFetch } from "../supabase/functions/_shared/musicbrainz.ts";
import { normalizeName } from "../supabase/functions/_shared/normalize.ts";

type Row = Record<string, unknown>;

const args = Deno.args;
const option = (name: string) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const recordingFile = option("--recording");
const mbidFile = option("--artist-mbid");
const out = option("--out");
if (!recordingFile && !mbidFile) {
  console.error("usage: radio-identity-dry-run.ts --recording <file> --artist-mbid <file> [--out <file>]");
  Deno.exit(2);
}

/// The CLI's envelope: `{ rows: [...] }` after any banner text.
function rows(path: string): Row[] {
  const text = Deno.readTextFileSync(path);
  return JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1)).rows ?? [];
}

async function mb(path: string, params: Record<string, string>): Promise<{ status: number; body?: any }> {
  const url = new URL(path, MUSICBRAINZ_API);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  url.searchParams.set("fmt", "json");
  for (let attempt = 0; attempt < 3; attempt++) {
    const response = await pacedFetch(url, { headers: { Accept: "application/json", "User-Agent": MB_USER_AGENT } });
    if (response.status === 503) {
      await response.body?.cancel();
      await new Promise((resolve) => setTimeout(resolve, 3000));
      continue;
    }
    if (!response.ok) {
      await response.body?.cancel();
      return { status: response.status };
    }
    return { status: 200, body: await response.json() };
  }
  return { status: 503 };
}

// ---------------------------------------------------------------------------
// Recording route
// ---------------------------------------------------------------------------

type RecordingOutcome =
  | "linkable" // credit names this artist; their entry names Discogs page(s)
  | "verified_no_discogs" // credit names this artist; MusicBrainz knows no Discogs page
  | "credit_mismatch" // the recording's credit does not name this artist
  | "recording_missing" // MusicBrainz has no such recording (merged or removed)
  | "lookup_failed";

const recordingResults: Row[] = [];
for (const row of recordingFile ? rows(recordingFile) : []) {
  const recording = await mb(`recording/${row.musicbrainz_recording_id}`, { inc: "artist-credits" });
  let outcome: RecordingOutcome;
  let mbid: string | null = null;
  let discogs: number[] = [];
  let credited: string[] = [];
  if (recording.status === 404) outcome = "recording_missing";
  else if (recording.status !== 200) outcome = "lookup_failed";
  else {
    const credit = (recording.body?.["artist-credit"] ?? []) as { name?: string; artist?: { id?: string; name?: string } }[];
    credited = credit.map((part) => part.artist?.name ?? part.name ?? "").filter(Boolean);
    const wanted = String(row.normalized_name ?? "");
    // The credit as printed on the recording, or the artist's own MusicBrainz
    // name: either may be what the station wrote.
    const match = credit.find((part) =>
      normalizeName(part.name ?? "") === wanted || normalizeName(part.artist?.name ?? "") === wanted
    );
    let entry: { status: number; body?: any } | null = null;
    if (match?.artist?.id) {
      mbid = match.artist.id;
      entry = await mb(`artist/${mbid}`, { inc: "url-rels" });
    } else {
      // The credit may be written in another script ("浜渦正志" for Masashi
      // Hamauzu). Each credited artist's own aliases and sort name are still
      // that MusicBrainz id's names, so matching them is not matching by name
      // alone -- the recording id already chose the candidates.
      for (const part of credit.slice(0, 3)) {
        if (!part.artist?.id) continue;
        const candidate = await mb(`artist/${part.artist.id}`, { inc: "aliases+url-rels" });
        if (candidate.status !== 200) continue;
        const sort = String(candidate.body?.["sort-name"] ?? "");
        const names = [
          sort,
          sort.includes(",") ? sort.split(",").map((piece) => piece.trim()).reverse().join(" ") : sort,
          ...((candidate.body?.aliases ?? []) as { name?: string; "sort-name"?: string }[]).flatMap((alias) => [alias.name ?? "", alias["sort-name"] ?? ""]),
        ];
        if (names.some((name) => name && normalizeName(name) === wanted)) {
          mbid = part.artist.id;
          entry = candidate;
          break;
        }
      }
    }
    if (mbid === null) outcome = "credit_mismatch";
    else if (!entry || entry.status !== 200) outcome = "lookup_failed";
    else {
      discogs = discogsArtistIDs(entry.body);
      outcome = discogs.length > 0 ? "linkable" : "verified_no_discogs";
    }
  }
  recordingResults.push({ artist_id: row.artist_id, name: row.name, recording: row.musicbrainz_recording_id, outcome, mbid, discogs, credited });
}

// ---------------------------------------------------------------------------
// Artist-mbid route: namesake risk only
// ---------------------------------------------------------------------------

type MbidOutcome =
  | "unique_name" // MusicBrainz holds one artist of exactly this name
  | "namesakes" // more than one: the stored MBID may be the wrong person
  | "name_not_found"
  | "lookup_failed";

const mbidResults: Row[] = [];
for (const row of mbidFile ? rows(mbidFile) : []) {
  const name = String(row.name ?? "").replace(/["\\]/g, " ").trim();
  const search = await mb("artist", { query: `artist:"${name}"`, limit: "25" });
  let outcome: MbidOutcome;
  let exact = 0;
  if (search.status !== 200) outcome = "lookup_failed";
  else {
    const wanted = String(row.normalized_name ?? normalizeName(name));
    exact = ((search.body?.artists ?? []) as { name?: string }[]).filter((artist) => normalizeName(artist.name ?? "") === wanted).length;
    outcome = exact === 0 ? "name_not_found" : exact === 1 ? "unique_name" : "namesakes";
  }
  // What following the stored MBID would link, were it trusted.
  const entry = outcome === "lookup_failed" ? { status: 0 } : await mb(`artist/${row.musicbrainz_id}`, { inc: "url-rels" });
  const discogs = entry.status === 200 ? discogsArtistIDs(entry.body) : [];
  mbidResults.push({ artist_id: row.id, name: row.name, mbid: row.musicbrainz_id, eps: row.eps, outcome, exact_matches: exact, discogs });
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

const tally = (list: Row[]) => list.reduce<Record<string, number>>((acc, row) => {
  acc[String(row.outcome)] = (acc[String(row.outcome)] ?? 0) + 1;
  return acc;
}, {});

const report = {
  tool: "Scripts/radio-identity-dry-run.ts",
  writes: out ? [out] : [],
  recordingRoute: { sampled: recordingResults.length, outcomes: tally(recordingResults) },
  artistMbidRoute: {
    sampled: mbidResults.length,
    outcomes: tally(mbidResults),
    wouldLinkIfTrusted: mbidResults.filter((row) => (row.discogs as number[]).length > 0).length,
    wouldLinkButNamesakes: mbidResults.filter((row) => row.outcome === "namesakes" && (row.discogs as number[]).length > 0).length,
  },
  linkableDiscogsIDs: [...new Set(recordingResults.flatMap((row) => row.discogs as number[]))].sort((a, b) => a - b),
};

if (out) Deno.writeTextFileSync(out, JSON.stringify({ report, recordingResults, mbidResults }, null, 2) + "\n");
console.log(JSON.stringify(report, null, 2));
