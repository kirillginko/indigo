// How often name-plus-title evidence picks the wrong artist, measured where the
// right answer is known -- asked of MusicBrainz, written nowhere.
//
// Tier 2 would identify a radio artist with no recording id by the titles the
// stations played under its name. Its rule, strict form:
//
//   * at least two distinct played titles (generic ones -- "Intro",
//     "Untitled", bare numbers -- do not count);
//   * for each title, MusicBrainz holds a recording of it credited to exactly
//     this name, and every such recording credits the *same one* MusicBrainz
//     artist (per title, unambiguous);
//   * every counted title lands on that same artist, and no title lands on
//     another.
//
// The candidates here are radio artists that *do* have an NTS recording id, so
// the recording's credit says who they are. The title rule is run blind to it
// and then compared. Each artist is also tagged with how many MusicBrainz
// artists share its exact name and how many recordings its verified artist
// has, so false matches can be read by shared names and by sparse coverage.
//
//   deno run --allow-read=<dir> --allow-net=musicbrainz.org --allow-write=<out> \
//       Scripts/radio-identity-tier2-eval.ts --candidates <file> --out <file>

import { MB_USER_AGENT, MUSICBRAINZ_API, pacedFetch } from "../supabase/functions/_shared/musicbrainz.ts";
import { normalizeName } from "../supabase/functions/_shared/normalize.ts";

type Row = Record<string, unknown>;

const args = Deno.args;
const option = (name: string) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const candidatesFile = option("--candidates");
const out = option("--out");
if (!candidatesFile || !out) {
  console.error("usage: radio-identity-tier2-eval.ts --candidates <file> --out <file>");
  Deno.exit(2);
}

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

const titleKey = (title: string) => normalizeName(title.replace(/[\(\[][^\)\]]*[\)\]]/g, " "));
const GENERIC = /^(intro|outro|interlude|untitled|untitled track|track \d+|skit|reprise|theme|edit|dub|instrumental|version|\d+)$/;
const countable = (title: string) => {
  const key = titleKey(title);
  return key.length > 0 && !GENERIC.test(key) && !/^[A-Z]{2}[A-Z0-9]{3}\d{7}$/.test(title.trim());
};
const lucene = (value: string) => value.replace(/([+\-!(){}\[\]^"~*?:\\\/]|&&|\|\|)/g, " ").replace(/\s+/g, " ").trim();

type Credit = { name?: string; artist?: { id?: string; name?: string } }[];

const results: Row[] = [];
for (const row of rows(candidatesFile)) {
  const name = String(row.name ?? "");
  const wanted = String(row.normalized_name ?? normalizeName(name));

  // Truth: the NTS recording's credit, matched on the credit's own names.
  let truth: string | null = null;
  let truthStatus = "credit_mismatch";
  const recording = await mb(`recording/${row.musicbrainz_recording_id}`, { inc: "artist-credits" });
  if (recording.status !== 200) truthStatus = recording.status === 404 ? "recording_missing" : "lookup_failed";
  else {
    const credit = (recording.body?.["artist-credit"] ?? []) as Credit;
    const match = credit.find((part) => normalizeName(part.name ?? "") === wanted || normalizeName(part.artist?.name ?? "") === wanted);
    if (match?.artist?.id) {
      truth = match.artist.id;
      truthStatus = "verified";
    }
  }

  // Title evidence, blind to the truth.
  const titles = [...new Map(((row.sample_titles ?? []) as string[]).filter(countable).map((t) => [titleKey(t), t])).values()].slice(0, 4);
  const perTitle: Row[] = [];
  let failed = false;
  for (const title of titles) {
    const search = await mb("recording", { query: `recording:"${lucene(title)}" AND artist:"${lucene(name)}"`, limit: "25" });
    if (search.status !== 200) {
      failed = true;
      perTitle.push({ title, verdict: "lookup_failed" });
      continue;
    }
    const holders = new Set<string>();
    for (const rec of (search.body?.recordings ?? []) as { title?: string; "artist-credit"?: Credit }[]) {
      if (titleKey(rec.title ?? "") !== titleKey(title)) continue;
      for (const part of rec["artist-credit"] ?? []) {
        if (!part.artist?.id) continue;
        if (normalizeName(part.name ?? "") === wanted || normalizeName(part.artist.name ?? "") === wanted) holders.add(part.artist.id);
      }
    }
    perTitle.push({ title, holders: [...holders], verdict: holders.size === 0 ? "none" : holders.size === 1 ? "unique" : "shared" });
  }
  const unique = perTitle.filter((t) => t.verdict === "unique");
  const landing = new Set(unique.map((t) => (t.holders as string[])[0]));
  const shared = perTitle.some((t) => t.verdict === "shared");
  let verdict: string;
  if (landing.size > 1 || (shared && landing.size >= 1)) verdict = "contradictory";
  else if (landing.size === 1 && unique.length >= 2) verdict = "tier2_pass";
  else if (landing.size === 1) verdict = "one_title_only";
  else if (shared) verdict = "shared_only";
  else verdict = failed ? "lookup_failed" : "no_match";
  const picked = verdict === "tier2_pass" || verdict === "one_title_only" ? [...landing][0] : null;

  // Tags: namesakes in MusicBrainz, and how much MusicBrainz knows of the truth.
  const search = await mb("artist", { query: `artist:"${lucene(name)}"`, limit: "50" });
  const namesakes = search.status === 200
    ? ((search.body?.artists ?? []) as { name?: string }[]).filter((a) => normalizeName(a.name ?? "") === wanted).length
    : null;
  let truthRecordings: number | null = null;
  if (truth) {
    const browse = await mb("recording", { artist: truth, limit: "1" });
    if (browse.status === 200) truthRecordings = Number(browse.body?.["recording-count"] ?? 0);
  }

  results.push({
    artist_id: row.artist_id, name, stratum: row.stratum, eps: row.eps, titles_played: row.titles,
    truth, truthStatus, verdict, picked,
    correct: picked && truth ? picked === truth : null,
    namesakes, truthRecordings, perTitle,
  });
}

Deno.writeTextFileSync(out, JSON.stringify(results, null, 2) + "\n");
const tally = (list: Row[], key: string) => list.reduce<Record<string, number>>((acc, r) => {
  acc[String(r[key])] = (acc[String(r[key])] ?? 0) + 1;
  return acc;
}, {});
console.log(JSON.stringify({ evaluated: results.length, verdicts: tally(results, "verdict"), truth: tally(results, "truthStatus") }, null, 2));
