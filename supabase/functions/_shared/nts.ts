// NTS episode payload -> Indigo's radio tables.
//
// The point of ingesting a tracklist is not to have a copy of it. It is that
// "Skee Mask" on line fourteen of a Ben UFO show becomes an edge, and the
// artist page can then answer a question no catalogue can: where have I heard
// this on radio.
//
// Runs under the service-role key. Deliberately server-side: the app already
// has this payload in hand when it renders an episode, but accepting tracklist
// rows from a client would let anyone holding the publishable key write
// whatever they liked into the shared graph. The function fetches its own copy.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { normalizeName } from "./normalize.ts";
import { creditedNames } from "./credit.ts";

export const PROVIDER = "nts";

/// NTS writes its genres and moods as `[{ id, value }]`. Empty and duplicate
/// values are dropped here rather than in SQL, so a seed pass counts uses
/// rather than spellings.
function tagValues(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const found: string[] = [];
  for (const entry of raw) {
    const value = typeof entry?.value === "string" ? entry.value.trim() : "";
    if (!value) continue;
    const key = value.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    found.push(value);
  }
  return found;
}

export const USER_AGENT = "Indigo/1.0 (+https://github.com/kirillginko/indigo)";
export const NTS_API = "https://www.nts.live/api/v2/";

type Payload = Record<string, any>;

// NTS publishes rendered HTML in every prose field, titles included
// ("DEBT &amp; REFUGE"). Mirrors HTMLText.decode in the app for the entities
// that actually turn up in show and track names.
const ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  hellip: "…", mdash: "—", ndash: "–",
  lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”",
  laquo: "«", raquo: "»", bull: "•", middot: "·", deg: "°",
  eacute: "é", egrave: "è", ecirc: "ê", euml: "ë", agrave: "à", aacute: "á",
  acirc: "â", auml: "ä", aring: "å", aelig: "æ", ccedil: "ç", iacute: "í",
  ntilde: "ñ", oacute: "ó", ocirc: "ô", ouml: "ö", oslash: "ø", oelig: "œ",
  szlig: "ß", uacute: "ú", uuml: "ü", euro: "€", pound: "£",
};

export function decodeHTML(value: string): string {
  if (!value.includes("&")) return value;
  return value.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (match, entity: string) => {
    if (entity.startsWith("#")) {
      const digits = entity.slice(1);
      const code = digits.startsWith("x") || digits.startsWith("X")
        ? Number.parseInt(digits.slice(1), 16)
        : Number.parseInt(digits, 10);
      return Number.isFinite(code) && code > 0 ? String.fromCodePoint(code) : match;
    }
    return ENTITIES[entity] ?? match;
  });
}

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const cleaned = decodeHTML(value).trim();
  return cleaned.length > 0 ? cleaned : null;
}

function integer(value: unknown): number | null {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.trunc(parsed) : null;
}

function picture(media: Payload | undefined): string | null {
  if (!media) return null;
  return media.picture_large ?? media.picture_medium_large ??
    media.picture_medium ?? media.picture_small ?? null;
}

/// Names NTS uses when a selector did not identify what they played. Resolving
/// them would attach half the network's output to one imaginary artist, so the
/// row keeps its raw text and never gets a normalized form to match on.
const PLACEHOLDER_NAMES = new Set([
  "unknown", "unknown artist", "unknown artists", "id", "ids", "untitled",
  "unreleased", "white label", "various", "various artists", "n a", "tbc",
]);

function matchableName(value: string | null): string | null {
  if (!value) return null;
  const key = normalizeName(value);
  if (key.length === 0 || PLACEHOLDER_NAMES.has(key)) return null;
  return key;
}

/// Who a line credits, and which of them the appearance belongs to.
///
/// NTS writes a collaboration as one string, and this used to be matched whole
/// — so "DJ Krush, Abijah" became an artist, with a page and a search result
/// and DJ Krush's radio plays on it. Twenty percent of the artist table was
/// credits like that.
///
/// The appearance resolves to the primary credit, because `artist_id` is one
/// column and the first name is whose record it is. The rest are kept beside
/// it rather than thrown away: relating an appearance to every artist on it
/// wants a table of its own, and re-reading four thousand episodes to recover
/// names we already had in hand is exactly the cost migration 0025 was written
/// to avoid paying twice.
function credit(raw: string | null): {
  key: string | null;
  names: string[];
  keys: string[];
} {
  const whole = matchableName(raw);
  if (whole === null) return { key: null, names: [], keys: [] };

  const names = creditedNames(raw);
  // One name, or a credit the splitter would not touch. Either way the whole
  // string is the artist, which is the ordinary case.
  if (names.length <= 1) return { key: whole, names: [], keys: [] };

  const keys = names.map(normalizeName).filter((key) => key.length > 0);
  const primary = keys.find((key) => !PLACEHOLDER_NAMES.has(key)) ?? null;
  return { key: primary, names, keys };
}

/// The people a programme is presented by, read off the title NTS publishes.
///
/// NTS has no host field. What it has is a naming convention its schedule is
/// almost entirely written in -- "Pacing The Platform w/ upsammy", "Peking
/// Spring w/ Jon K", "Ben Sims Presents: Run It Red" -- and 46 of a sample of
/// 120 programmes are the first form alone.
///
/// This matters because a selector is not usually in their own tracklist.
/// `adopt_radio_artists` builds the artist table out of what shows *play*, so
/// the people doing the playing were the one group of names the catalogue could
/// not answer for: Ben UFO and Jane Fitz were the two misses in a twenty-name
/// search test where everything else was found instantly. They are also exactly
/// the names somebody types.
///
/// Conservative on purpose. Only the two forms above, never a bare title --
/// "In Focus" and "The Early Bird Show" are programmes, not people, and there
/// is nothing in the string to say so.
export function hostNames(title: string | null): string[] {
  if (!title) return [];

  let credited: string | null = null;

  // Last rather than first: a programme called "Wigs w/ Imogen w/ guests"
  // credits Imogen, and splitting on the first would credit the rest.
  const withMarker = title.lastIndexOf(" w/ ");
  if (withMarker >= 0) {
    credited = title.slice(withMarker + 4);
  } else {
    const presents = title.match(/^(.+?)\s+[Pp]resents\b/);
    if (presents) credited = presents[1];
  }
  if (!credited) return [];

  const found: string[] = [];
  const seen = new Set<string>();
  for (const part of credited.split(/\s+&\s+|\s+and\s+|,\s*/)) {
    const name = part.trim();
    // One character is an initial or a stray separator, never a name worth a
    // row of its own.
    if (name.length < 2) continue;
    const key = matchableName(name);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    found.push(name);
  }
  return found;
}

/// The programme an episode belongs to, created the first time one of its
/// broadcasts is seen.
///
/// Returns whether it had to be created, because an episode payload does not
/// carry its show's title and a programme called `ben-ufo` is not much of an
/// answer to "which shows have played this".
async function ensureShow(
  supabase: SupabaseClient,
  alias: string,
): Promise<{ id: string; created: boolean } | null> {
  const existing = await supabase
    .from("radio_shows")
    .select("id")
    .eq("provider", PROVIDER)
    .eq("external_id", alias)
    .maybeSingle();

  if (existing.data?.id) return { id: existing.data.id as string, created: false };

  const inserted = await supabase
    .from("radio_shows")
    .insert({
      provider: PROVIDER,
      external_id: alias,
      station: "NTS",
      title: alias,
      provider_url: `https://www.nts.live/shows/${alias}`,
    })
    .select("id")
    .single();

  if (inserted.data?.id) return { id: inserted.data.id as string, created: true };

  // Lost a race against another invocation ingesting a sibling episode. Its
  // row is the canonical one, and it is already being described.
  const winner = await supabase
    .from("radio_shows")
    .select("id")
    .eq("provider", PROVIDER)
    .eq("external_id", alias)
    .maybeSingle();
  return winner.data?.id ? { id: winner.data.id as string, created: false } : null;
}

/// Fills in a programme from its own payload. Separate from the episode path
/// because this happens once per show and the episode path happens hundreds of
/// times per show.
export async function ingestNTSShow(
  supabase: SupabaseClient,
  alias: string,
  payload: Payload,
): Promise<string | null> {
  const show = await ensureShow(supabase, alias);
  if (!show) return null;

  const title = text(payload.name) ?? alias;
  const hosts = hostNames(title);

  const update = await supabase
    .from("radio_shows")
    .update({
      title,
      description: text(payload.description),
      station: "NTS",
      // Written as published rather than as parsed, so the column says what
      // the schedule says. The split-out names go to `artists`, below.
      host_name: hosts.length > 0 ? hosts.join(" & ") : null,
      image_url: picture(payload.media),
      provider_url: `https://www.nts.live/shows/${alias}`,
    })
    .eq("id", show.id);

  if (update.error) console.error("nts: show update failed", update.error.message);

  // Each presenter becomes an artist, sharing the identity a tracklist name
  // would have got. A selector who also turns up in somebody else's tracklist
  // is one artist with both, not two rows that never meet.
  for (const host of hosts) {
    const { error } = await supabase.rpc("adopt_named_artist", {
      p_name: host,
      p_key: normalizeName(host),
      p_source_url: `https://www.nts.live/shows/${alias}`,
    });
    if (error) console.error("nts: host adopt failed", host, error.message);
  }

  await enqueueBackCatalogue(supabase, alias);
  return show.id;
}

/// How many broadcasts back to go when a residency is first seen.
///
/// The whole archive would be thousands of requests for a station nobody has
/// asked about yet. A dozen is enough to make a show's page worth opening and
/// to give the graph something to connect, and the rest can be asked for when
/// somebody actually goes looking.
const BACK_CATALOGUE = 12;

/// Queues a show's recent broadcasts instead of fetching them here.
///
/// This is what stops radio provenance depending on somebody clicking every
/// episode individually: opening one residency asks for its last dozen, and
/// they arrive over the following minutes without a screen waiting on any of
/// them.
async function enqueueBackCatalogue(supabase: SupabaseClient, alias: string): Promise<void> {
  try {
    const response = await fetch(
      `${NTS_API}shows/${alias}/episodes?offset=0&limit=${BACK_CATALOGUE}`,
      { headers: { Accept: "application/json", "User-Agent": USER_AGENT } },
    );
    if (!response.ok) return;

    const page = await response.json() as Payload;
    const episodes: Payload[] = Array.isArray(page.results) ? page.results : [];

    for (const episode of episodes) {
      const episodeAlias = typeof episode.episode_alias === "string" ? episode.episode_alias : null;
      const showAlias = typeof episode.show_alias === "string" ? episode.show_alias : alias;
      if (!episodeAlias) continue;

      // Newest first, so a show opened today starts with what it just played.
      const { error } = await supabase.rpc("enqueue_enrichment_job", {
        p_provider: "nts",
        p_job_type: "fetch_nts_episode",
        p_dedupe_key: `${showAlias}/${episodeAlias}`,
        p_payload: { show: showAlias, episode: episodeAlias },
        p_priority: 0,
        p_entity_type: null,
        p_entity_id: null,
      });
      if (error) console.error("nts: enqueue failed", error.message);
    }
  } catch (cause) {
    // A residency whose listing did not answer is one Indigo will fill in the
    // next time somebody opens it.
    console.error("nts: back catalogue enqueue failed", String(cause));
  }
}

/// Describes a programme the first time one of its broadcasts arrives.
///
/// One upstream request per show for the entire life of the database, and the
/// alternative is a graph whose most visible strings are URL slugs. Failure is
/// tolerated: the shell row is already usable and the next new episode is
/// another chance.
async function describeShow(supabase: SupabaseClient, alias: string): Promise<void> {
  try {
    const response = await fetch(`${NTS_API}shows/${alias}`, {
      headers: { Accept: "application/json", "User-Agent": USER_AGENT },
    });
    if (!response.ok) return;
    await ingestNTSShow(supabase, alias, await response.json());
  } catch (cause) {
    console.error("nts: show describe failed", String(cause));
  }
}

export async function ingestNTSEpisode(
  supabase: SupabaseClient,
  showAlias: string,
  episodeAlias: string,
  payload: Payload,
): Promise<string | null> {
  const externalID = `${showAlias}/${episodeAlias}`;
  const show = await ensureShow(supabase, showAlias);
  if (show?.created) await describeShow(supabase, showAlias);

  const sources: Payload[] = Array.isArray(payload.audio_sources) ? payload.audio_sources : [];
  const archive = sources.find((source) => typeof source?.url === "string")?.url ??
    (typeof payload.mixcloud === "string" ? payload.mixcloud : null);

  // `embeds.tracklist` is a paged object when a tracklist exists and a bare
  // `[]` when it does not, so it has no single shape to read.
  const embedded = payload.embeds?.tracklist;
  const tracklist: Payload[] = Array.isArray(embedded?.results)
    ? embedded.results
    : Array.isArray(embedded)
    ? embedded
    : [];

  // "unavailable" is a finding, not a failure: most NTS guest sets never get a
  // published tracklist, and recording that stops the next pass re-asking.
  const episode = await supabase
    .from("radio_episodes")
    .upsert({
      radio_show_id: show?.id ?? null,
      provider: PROVIDER,
      external_id: externalID,
      title: text(payload.name) ?? episodeAlias,
      description: text(payload.description),
      aired_at: typeof payload.broadcast === "string" ? payload.broadcast : null,
      archive_url: archive,
      image_url: picture(payload.media),
      tracklist_status: tracklist.length > 0 ? "available" : "unavailable",
      // What the station files this under, and where it went out from.
      //
      // Read past until now, and it is the only listing scenes ever had: the
      // backend has no genre column anywhere else and an `artists.country`
      // nothing fills, so without this it cannot know that Manchester has a
      // hip hop scene. See `seed_scenes_from_radio`.
      genres: tagValues(payload.genres),
      moods: tagValues(payload.moods),
      location: text(payload.location_long) ?? text(payload.location_short),
    }, { onConflict: "provider,external_id" })
    .select("id")
    .single();

  if (episode.error || !episode.data) {
    console.error("nts: episode upsert failed", episode.error?.message);
    return null;
  }
  const episodeID = episode.data.id as string;

  if (tracklist.length === 0) return episodeID;

  const rows = tracklist.map((track, index) => {
    const artist = text(track.artist);
    const title = text(track.title);
    const credited = credit(artist);
    return {
      radio_episode_id: episodeID,
      // The slot, not the uid. NTS repeats a uid when a record is played twice
      // in one show, and the position is what a re-import has to land on.
      track_index: index,
      raw_artist_name: artist,
      raw_track_title: title,
      normalized_artist_name: credited.key,
      // Every name on the line, kept so a later pass can relate an appearance
      // to all of them without reading the episode again.
      credited_artist_names: credited.names.length > 0 ? credited.names : null,
      credited_artist_keys: credited.keys.length > 0 ? credited.keys : null,
      normalized_title: title ? normalizeName(title) : null,
      offset_seconds: integer(track.offset ?? track.offset_estimate),
      // What NTS identified the record as, which is the part no amount of
      // name matching can recover later. Around two lines in five carry an
      // ISRC and one in three a Deezer id; a version of this function without
      // these three fields dropped every one of them, and the only way back
      // to them is to read the episode again. See migration 0025.
      isrc: text(track.isrc_id),
      deezer_track_id: track.deezer_track_id != null
        ? String(track.deezer_track_id)
        : null,
      musicbrainz_recording_id: text(track.musicbrainz_track_id),
      identification_source: null,
    };
  }).filter((row) => row.raw_artist_name !== null || row.raw_track_title !== null);

  if (rows.length > 0) {
    const written = await supabase
      .from("radio_appearances")
      .upsert(rows, { onConflict: "radio_episode_id,track_index" });
    if (written.error) console.error("nts: appearances upsert failed", written.error.message);
  }

  // A corrected tracklist can be shorter than the one imported last time, and
  // upserting alone would leave the tail behind as tracks the show never
  // played. Keyed on the slots actually written rather than on a count,
  // because a line with neither artist nor title is dropped above and leaves a
  // gap in the numbering.
  const kept = rows.map((row) => row.track_index);
  let trimming = supabase.from("radio_appearances").delete().eq("radio_episode_id", episodeID);
  if (kept.length > 0) trimming = trimming.not("track_index", "in", `(${kept.join(",")})`);
  const trimmed = await trimming;
  if (trimmed.error) console.error("nts: stale slot delete failed", trimmed.error.message);

  // Matching happens in Postgres, against rows it already has indexed. Doing
  // it here would mean a round trip per line of the tracklist.
  const resolved = await supabase.rpc("resolve_radio_appearances", { p_episode_id: episodeID });
  if (resolved.error) console.error("nts: resolve failed", resolved.error.message);

  // Rebuilding the graph reads every appearance, so it is not something to do
  // once per episode while twelve of them are landing. Queued instead, where
  // the dedupe key collapses the burst into a single rebuild.
  const queued = await supabase.rpc("enqueue_enrichment_job", {
    p_provider: "indigo",
    p_job_type: "rebuild_dig_edges",
    p_dedupe_key: "radio",
    p_payload: null,
    p_priority: -1,
    p_entity_type: null,
    p_entity_id: null,
  });
  if (queued.error) console.error("nts: rebuild enqueue failed", queued.error.message);

  return episodeID;
}
