// The checks a Tier 1 identity link must pass before it is written -- asked of
// MusicBrainz, written nowhere.
//
// Tier 1 links a radio artist row to Discogs through a recording id NTS
// published (radio-identity-dry-run.ts, recording route). One recording is one
// witness. This asks two more questions of each linkable candidate:
//
//   * Do the artist's *other* NTS recording ids credit the same MusicBrainz
//     artist? A row whose recordings credit two different MBIDs is a name that
//     holds two people ("Ruins"), and linking it to one of them is a merge.
//   * Is the Discogs page linked from that one MusicBrainz artist only? If two
//     MusicBrainz artists claim one Discogs page, MusicBrainz itself is unsure.
//
// Input: the dry run's recording results and the candidates' recording ids
// (read-only CLI exports). Output: one local JSON file.
//
//   deno run --allow-read=<dir> --allow-net=musicbrainz.org --allow-write=<out> \
//       Scripts/radio-identity-tier1-checks.ts --candidates <file> --recordings <file> --out <file>

import { MB_USER_AGENT, MUSICBRAINZ_API, pacedFetch } from "../supabase/functions/_shared/musicbrainz.ts";

type Row = Record<string, unknown>;

const args = Deno.args;
const option = (name: string) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const candidatesFile = option("--candidates");
const recordingsFile = option("--recordings");
const out = option("--out");
if (!candidatesFile || !recordingsFile || !out) {
  console.error("usage: radio-identity-tier1-checks.ts --candidates <file> --recordings <file> --out <file>");
  Deno.exit(2);
}

function rows(path: string): Row[] {
  const text = Deno.readTextFileSync(path);
  const parsed = JSON.parse(text.slice(Math.min(...["{", "["].map((c) => text.indexOf(c)).filter((i) => i >= 0))));
  return Array.isArray(parsed) ? parsed : parsed.rows ?? [];
}

async function mb(path: string, params: Record<string, string>): Promise<{ status: number; body?: any }> {
  const url = new URL(path, MUSICBRAINZ_API);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  url.searchParams.set("fmt", "json");
  for (let attempt = 0; attempt < 3; attempt++) {
    const response = await pacedFetch(url, { headers: { Accept: "application/json", "User-Agent": MB_USER_AGENT } });
    if (response.status === 503) {
      await response.body?.cancel();
      await new Promise((resolve) => setTimeout(resolve, 3000 * (attempt + 1)));
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

const recordingsByArtist = new Map<string, string[]>();
for (const row of rows(recordingsFile)) {
  const list = recordingsByArtist.get(String(row.artist_id)) ?? [];
  const id = String(row.musicbrainz_recording_id);
  if (!list.includes(id)) list.push(id);
  recordingsByArtist.set(String(row.artist_id), list);
}

const results: Row[] = [];
for (const candidate of rows(candidatesFile)) {
  if (candidate.outcome !== "linkable") continue;
  const mbid = String(candidate.mbid);

  // Other recordings: same MBID credited, a different one, or unknown.
  const others = (recordingsByArtist.get(String(candidate.artist_id)) ?? [])
    .filter((id) => id !== candidate.recording).slice(0, 2);
  const otherRecordings: Row[] = [];
  for (const id of others) {
    const recording = await mb(`recording/${id}`, { inc: "artist-credits" });
    if (recording.status !== 200) {
      otherRecordings.push({ recording: id, verdict: recording.status === 404 ? "recording_missing" : "lookup_failed" });
      continue;
    }
    const credit = (recording.body?.["artist-credit"] ?? []) as { artist?: { id?: string; name?: string } }[];
    const ids = credit.map((part) => part.artist?.id).filter(Boolean) as string[];
    otherRecordings.push({
      recording: id,
      verdict: ids.includes(mbid) ? "same_artist" : "other_artist",
      credited: credit.map((part) => `${part.artist?.name} ${part.artist?.id}`),
    });
  }

  // Reverse: which MusicBrainz artists link each Discogs page.
  const discogsClaims: Row[] = [];
  for (const discogs of candidate.discogs as number[]) {
    const lookup = await mb("url", { resource: `https://www.discogs.com/artist/${discogs}`, inc: "artist-rels" });
    if (lookup.status !== 200) {
      discogsClaims.push({ discogs, verdict: lookup.status === 404 ? "url_not_found" : "lookup_failed" });
      continue;
    }
    const claimants = [...new Set(((lookup.body?.relations ?? []) as { artist?: { id?: string } }[])
      .map((relation) => relation.artist?.id).filter(Boolean))] as string[];
    discogsClaims.push({
      discogs,
      claimants,
      verdict: claimants.length === 1 && claimants[0] === mbid ? "sole_claimant"
        : claimants.includes(mbid) ? "shared_claim" : "not_claimed_by_mbid",
    });
  }

  results.push({ artist_id: candidate.artist_id, mbid, otherRecordings, discogsClaims });
}

Deno.writeTextFileSync(out, JSON.stringify(results, null, 2) + "\n");
console.log(JSON.stringify({
  checked: results.length,
  otherRecordings: results.flatMap((r) => r.otherRecordings as Row[]).reduce<Record<string, number>>((acc, r) => {
    acc[String(r.verdict)] = (acc[String(r.verdict)] ?? 0) + 1;
    return acc;
  }, {}),
  discogsClaims: results.flatMap((r) => r.discogsClaims as Row[]).reduce<Record<string, number>>((acc, r) => {
    acc[String(r.verdict)] = (acc[String(r.verdict)] ?? 0) + 1;
    return acc;
  }, {}),
}, null, 2));
