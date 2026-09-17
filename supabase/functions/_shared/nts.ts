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
import { matchableName, storeTracklist } from "./radio.ts";

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

  await storeTracklist(supabase, episodeID, tracklist.map((track) => ({
    artist: text(track.artist),
    title: text(track.title),
    offsetSeconds: integer(track.offset ?? track.offset_estimate),
    // What NTS identified the record as, which is the part no amount of name
    // matching can recover later. Around two lines in five carry an ISRC and
    // one in three a Deezer id; a version of this function without these
    // three fields dropped every one of them, and the only way back to them is
    // to read the episode again. See migration 0025.
    isrc: text(track.isrc_id),
    deezerTrackID: track.deezer_track_id != null ? String(track.deezer_track_id) : null,
    musicbrainzRecordingID: text(track.musicbrainz_track_id),
  })), "nts");

  return episodeID;
}
