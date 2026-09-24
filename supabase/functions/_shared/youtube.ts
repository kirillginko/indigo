// Curated YouTube channels -> Indigo's radio tables.
//
// Some of the rarest music Indigo can point at exists only as somebody's
// upload: a 1976 Polish jazz side, a Japanese library record, a private press
// nobody reissued. Channels like André Navarro II post them one a day, titled
// "ARTIST - Title", and sort them into playlists by region. That is a curator
// doing exactly what a radio host does, so it is filed the same way:
//
//   * the channel is a `radio_shows` row (provider `youtube`),
//   * each of its playlists is a `radio_episodes` row, and so is its uploads,
//   * each video is a line of that "tracklist", carrying its own address in
//     `media_url` so the app can play it (see 0041).
//
// Everything downstream -- artist resolution, "played by" and "played next
// to" edges, For You -- already keys on those tables and not on the station.
//
// Read through the YouTube Data API v3, never by scraping the site: the API is
// what YouTube's terms allow. With no key configured only the channel's public
// Atom feed is read, which carries its fifteen newest uploads -- enough to keep
// up, not enough to walk the back catalogue.
//
// The terms also limit how long API data may be kept without being refreshed;
// every channel is re-read at least every few weeks (`REFRESH_DAYS`), which at
// one request per fifty videos costs next to nothing.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { storeTracklist, type TracklistLine } from "./radio.ts";

export const PROVIDER = "youtube";
const API = "https://www.googleapis.com/youtube/v3/";
const FEED = "https://www.youtube.com/feeds/videos.xml?channel_id=";
const USER_AGENT = "Indigo/1.0 (+https://github.com/kirillginko/indigo)";

/// A playlist whose item count is unchanged is re-read anyway after this
/// long, so what is held never ages past what the API terms allow.
export const REFRESH_DAYS = 25;

/// A channel with more than this many playlists is not a curator's shelf, and
/// reading all of them would spend the day's quota on one channel.
const MAX_PLAYLISTS = 60;
/// Likewise for one list: 6,000 videos is 120 requests. The largest followed
/// channel, oleg_samples, had 5,358 uploads on 2026-09-24.
const MAX_ITEMS = 6000;

/// How long one pass may spend before it stops and leaves the rest for the
/// next. A first read of a large channel is a hundred requests and thousands
/// of rows; the edge function's wall clock is not much longer than that, and
/// a pass cut off by it records nothing. Stopping early and saving after each
/// list means every pass keeps what it did.
export const TIME_BUDGET_MS = 100_000;

// ---------------------------------------------------------------------------
// Reading a title
// ---------------------------------------------------------------------------

const ENTITIES: Record<string, string> = {
  "&amp;": "&", "&quot;": '"', "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
};

export function decodeEntities(value: string): string {
  return value
    .replace(/&(amp|quot|#39|apos|lt|gt);/g, (entity) => ENTITIES[entity] ?? entity)
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)));
}

/// Asides that say nothing about which recording this is. Mirrors the app's
/// `YouTubeTitle.clean`: "(Live at Dekmantel)" or "(Original Mix)" stay.
const NOISE = /^(official|audio|video|music|hd|hq|4k|full|album|lyrics?|visuali[sz]er|remastered|remaster|\d{4}|\d{2,4}s|vinyl|rip|lp|ep|single|1080p|720p|[\s,/&|-])+$/i;

/// Clutter at the very end of a title, outside any brackets: "- FULL ALBUM",
/// "HQ", a year left bare ("Heated Point 1975", "Art-Istry -1972"). Repeated,
/// because channels stack them: "Pale Sky (1971) HQ".
const TRAILER = /(?:(?:\s+|\s*[-–—|~]\s*)(?:full\s+album|hq|hd|official\s+(?:audio|video))|\s+-?\s*(?:19|20)\d{2})\s*$/i;

/// A country tag and a genre list after the title, as Music for empty rooms
/// writes them: "Keep On Trying [US] Soul, Funk". Only a short bracket with
/// plain words after it and nothing else, so "Song [Remix]" is left alone.
const GENRE_TAIL = /\s+\[[^\]]{2,24}\]\s+[\p{L}][\p{L} ,&/'-]{1,60}$/u;

function withoutNoisyAsides(value: string): string {
  let cleaned = value
    .replace(/\s*[\(\[]([^\)\]]*)[\)\]]/g, (whole, inner: string) => (NOISE.test(inner.trim()) ? "" : whole))
    .replace(/\s+/g, " ")
    .trim()
    // After the asides, so "[US] Soul, Funk (1974)" has lost its year and the
    // genres are at the end where the pattern looks for them.
    .replace(GENRE_TAIL, "")
    .trim();
  for (let pass = 0; pass < 4 && TRAILER.test(cleaned); pass++) {
    const shorter = cleaned.replace(TRAILER, "").trim();
    // Never down to nothing: a record called "1975" is still called that.
    if (!shorter) break;
    cleaned = shorter;
  }
  return cleaned;
}

/// Direction marks and zero-width characters, which copy-pasted titles carry
/// invisibly: aquarianrealm's "Carter Jefferson \u200E– The Rise Of Atlantis"
/// has one between the space and the dash, and the split never saw a dash.
const INVISIBLE = /[\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]/g;

/// "SIEGFRIED SCHWAB" -> "Siegfried Schwab", for a name written all in capitals.
///
/// Curators shout the artist so it stands out in a grid, but the first
/// spelling a name arrives in is the one `adopt_radio_artists` shows forever.
/// Matching ignores case, so this only changes what is displayed. A word with
/// no vowel -- DJ, MFSB, a roman numeral like II -- is an initialism or a
/// numeral and is left as it is.
export function softenCapitals(name: string): string {
  if (!/\p{Lu}/u.test(name) || name !== name.toUpperCase()) return name;
  return name.replace(/\p{L}[\p{L}\p{M}']*/gu, (word) => {
    if (!/[AEIOUYÀ-ÖØ-Ý]/i.test(word) || /^[IVXLC]+$/.test(word)) return word;
    return word[0] + word.slice(1).toLowerCase();
  });
}

/// "HIROSHI MIYAGAWA - Life of love" -> artist and title.
///
/// Split on the first spaced dash only: "Hi-Fi Set" and "Tam gdzie nas nie
/// ma - Part 2" both keep their inner dashes. A title with no dash is kept as
/// a title with no artist, which is a line that plays but resolves to nobody --
/// better than guessing which half is the name.
export function parseVideoTitle(raw: string): { artist: string | null; title: string | null } {
  let decoded = decodeEntities(raw).replace(INVISIBLE, "").replace(/\s+/g, " ").trim();
  if (!decoded) return { artist: null, title: null };

  // Two spellings of one title: "田口久美 - Ｏ嬢の物語 // Kumi Taguchi - Mrs O's
  // story". The romanised half is the one the rest of the catalogue uses, so
  // it is the one that can match -- when it has an artist of its own.
  const halves = decoded.split(/\s+\/\/\s+/);
  if (halves.length === 2 && /\s[-–—~]\s/.test(halves[1])) decoded = halves[1];

  // Artist, a dash, and the title in quotes: Selected Sounds writes
  // `Les McCann- "The Harlem Buck Dance Strut"`, with no space before the
  // dash. The quotes make it unambiguous where the unspaced dash alone is not.
  const quoted = decoded.match(/^(.+?)\s*[-–—]\s*["“](.+)["”]$/);
  if (quoted) {
    const artist = quoted[1].trim();
    const title = withoutNoisyAsides(quoted[2].trim());
    if (artist && title) return { artist: softenCapitals(artist), title };
  }

  // A tilde is jazznote89's dash: "Sonny Stitt ~ Autumn In New York".
  const match = decoded.match(/\s[-–—~]\s/);
  if (!match || match.index === undefined) {
    return { artist: null, title: withoutNoisyAsides(decoded) || decoded };
  }
  const artist = decoded.slice(0, match.index).trim();
  const title = withoutNoisyAsides(decoded.slice(match.index + match[0].length));
  return {
    artist: artist.length > 0 ? softenCapitals(artist) : null,
    title: title.length > 0 ? title : null,
  };
}

/// What a video removed or hidden since it was listed is called in its place.
export function isUnavailableTitle(title: string): boolean {
  return title === "Private video" || title === "Deleted video";
}

export function watchURL(videoID: string): string {
  return `https://www.youtube.com/watch?v=${videoID}`;
}

/// A channel's uploads live in a playlist whose id is the channel's with "UU"
/// in place of "UC". Used as the uploads episode's id whichever way it is
/// read, so the feed and the API write the same row.
export function uploadsPlaylistID(channelID: string): string {
  return channelID.startsWith("UC") ? `UU${channelID.slice(2)}` : channelID;
}

export interface ChannelVideo {
  videoID: string;
  title: string;
  publishedAt: string | null;
}

/// How a channel titles its uploads. Most write "Artist - Title"; some write
/// only the record ("Sketches of Spain"), and some put the song first and
/// themselves second ("Stop and Go - aldino remix"), where reading the first
/// half as the artist would adopt every song as a person. Those are filed as
/// titles alone: playable, and claiming nobody.
///
/// A few put the title first and the artist second ("Happy Frame Of Mind -
/// Horace Parlan"): `title_artist` reads the same split the other way round.
export type TitleFormat = "artist_title" | "title_artist" | "title_only";

export function readTitle(raw: string, format: TitleFormat): { artist: string | null; title: string | null } {
  if (format === "artist_title") return parseVideoTitle(raw);
  if (format === "title_artist") {
    const split = parseVideoTitle(raw);
    // Only a line that did split is swapped. The artist half has been through
    // `withoutNoisyAsides` as the title, and the title half through
    // `softenCapitals` as the artist; both are harmless the other way round.
    if (split.artist && split.title) return { artist: split.title, title: split.artist };
    return split;
  }
  const decoded = decodeEntities(raw).replace(INVISIBLE, "").replace(/\s+/g, " ").trim();
  const title = withoutNoisyAsides(decoded);
  return { artist: null, title: title || decoded || null };
}

export function linesFor(videos: ChannelVideo[], format: TitleFormat = "artist_title"): TracklistLine[] {
  return videos.map((video) => {
    const parsed = readTitle(video.title, format);
    return {
      artist: parsed.artist,
      title: parsed.title,
      offsetSeconds: null,
      mediaURL: watchURL(video.videoID),
    };
  });
}

// ---------------------------------------------------------------------------
// The public feed
// ---------------------------------------------------------------------------

export interface FeedChannel {
  title: string | null;
  videos: ChannelVideo[];
}

/// The channel's Atom feed: its title and fifteen newest uploads.
export function parseFeed(xml: string): FeedChannel {
  const head = xml.split("<entry>")[0];
  const title = head.match(/<title>([^<]*)<\/title>/)?.[1] ?? null;
  const videos: ChannelVideo[] = [];
  for (const entry of xml.split("<entry>").slice(1)) {
    const videoID = entry.match(/<yt:videoId>([^<]+)<\/yt:videoId>/)?.[1];
    const videoTitle = entry.match(/<title>([^<]*)<\/title>/)?.[1];
    if (!videoID || !videoTitle) continue;
    videos.push({
      videoID,
      title: decodeEntities(videoTitle),
      publishedAt: entry.match(/<published>([^<]+)<\/published>/)?.[1] ?? null,
    });
  }
  return { title: title ? decodeEntities(title) : null, videos };
}

// ---------------------------------------------------------------------------
// The Data API
// ---------------------------------------------------------------------------

type Payload = Record<string, any>;

async function api(path: string, params: Record<string, string>, key: string): Promise<Payload> {
  const query = new URLSearchParams({ ...params, key });
  const response = await fetch(`${API}${path}?${query}`, {
    headers: { Accept: "application/json", "User-Agent": USER_AGENT },
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) {
    // The key is in the address, so the address is never logged.
    throw new Error(`youtube: ${path} answered ${response.status}`);
  }
  return await response.json();
}

function bestThumbnail(thumbnails: Payload | undefined): string | null {
  for (const size of ["maxres", "standard", "high", "medium", "default"]) {
    const url = thumbnails?.[size]?.url;
    if (typeof url === "string") return url;
  }
  return null;
}

export interface ApiChannel {
  title: string;
  description: string | null;
  imageURL: string | null;
  uploads: string;
  /// Public uploads, which is what the uploads list holds. Lets an unchanged
  /// channel be stepped over without reading its uploads to count them.
  videoCount: number;
}

export async function fetchChannel(channelID: string, key: string): Promise<ApiChannel | null> {
  const page = await api("channels", { part: "snippet,contentDetails,statistics", id: channelID }, key);
  const item = page.items?.[0];
  if (!item) return null;
  return {
    title: String(item.snippet?.title ?? channelID),
    description: typeof item.snippet?.description === "string" ? item.snippet.description : null,
    imageURL: bestThumbnail(item.snippet?.thumbnails),
    uploads: String(item.contentDetails?.relatedPlaylists?.uploads ?? uploadsPlaylistID(channelID)),
    videoCount: Number(item.statistics?.videoCount ?? -1),
  };
}

export interface ApiPlaylist {
  id: string;
  title: string;
  publishedAt: string | null;
  imageURL: string | null;
  itemCount: number;
}

export async function fetchPlaylists(channelID: string, key: string): Promise<ApiPlaylist[]> {
  const found: ApiPlaylist[] = [];
  let pageToken: string | undefined;
  do {
    const page = await api("playlists", {
      part: "snippet,contentDetails",
      channelId: channelID,
      maxResults: "50",
      ...(pageToken ? { pageToken } : {}),
    }, key);
    for (const item of page.items ?? []) {
      found.push({
        id: String(item.id),
        title: String(item.snippet?.title ?? ""),
        publishedAt: item.snippet?.publishedAt ?? null,
        imageURL: bestThumbnail(item.snippet?.thumbnails),
        itemCount: Number(item.contentDetails?.itemCount ?? 0),
      });
    }
    pageToken = page.nextPageToken;
  } while (pageToken && found.length < MAX_PLAYLISTS);
  return found.slice(0, MAX_PLAYLISTS);
}

/// A playlist's videos in the order the curator put them, which is the order
/// the "played next to" edges are read from.
export async function fetchPlaylistItems(playlistID: string, key: string): Promise<ChannelVideo[]> {
  const videos: ChannelVideo[] = [];
  let pageToken: string | undefined;
  do {
    const page = await api("playlistItems", {
      part: "snippet,contentDetails",
      playlistId: playlistID,
      maxResults: "50",
      ...(pageToken ? { pageToken } : {}),
    }, key);
    for (const item of page.items ?? []) {
      const videoID = item.contentDetails?.videoId ?? item.snippet?.resourceId?.videoId;
      const title = item.snippet?.title;
      if (typeof videoID !== "string" || typeof title !== "string" || isUnavailableTitle(title)) continue;
      videos.push({
        videoID,
        title,
        publishedAt: item.contentDetails?.videoPublishedAt ?? item.snippet?.publishedAt ?? null,
      });
    }
    pageToken = page.nextPageToken;
  } while (pageToken && videos.length < MAX_ITEMS);
  return videos.slice(0, MAX_ITEMS);
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

interface ShowFields {
  title: string;
  description: string | null;
  imageURL: string | null;
}

/// The channel's row, written only when what it says has changed (see 0037).
async function ensureShow(supabase: SupabaseClient, channelID: string, fields: ShowFields): Promise<string> {
  const wanted = {
    title: fields.title,
    // What artist pages show beside the curator's name. Not "YouTube": in
    // the app these are Archives, and where they are hosted is not the point.
    station: "Archive",
    host_name: fields.title,
    description: fields.description,
    provider_url: `https://www.youtube.com/channel/${channelID}`,
  };
  const existing = await supabase
    .from("radio_shows")
    .select("id,title,station,host_name,description,provider_url,image_url")
    .eq("provider", PROVIDER)
    .eq("external_id", channelID)
    .maybeSingle();

  if (existing.data) {
    const row = existing.data;
    const imageURL = fields.imageURL ?? row.image_url ?? null;
    // The feed carries no description; one the API gave is not erased by it.
    const description = fields.description ?? row.description ?? null;
    const changed = row.title !== wanted.title || row.station !== wanted.station ||
      row.host_name !== wanted.host_name || row.provider_url !== wanted.provider_url ||
      row.image_url !== imageURL || row.description !== description;
    if (changed) {
      const update = await supabase
        .from("radio_shows")
        .update({ ...wanted, description, image_url: imageURL })
        .eq("id", row.id);
      if (update.error) throw new Error(`youtube: show update failed: ${update.error.message}`);
    }
    return row.id as string;
  }

  const inserted = await supabase
    .from("radio_shows")
    .upsert(
      { provider: PROVIDER, external_id: channelID, image_url: fields.imageURL, ...wanted },
      { onConflict: "provider,external_id" },
    )
    .select("id")
    .single();
  if (inserted.error || !inserted.data) {
    throw new Error(`youtube: show insert failed: ${inserted.error?.message}`);
  }
  return inserted.data.id as string;
}

/// What was read of each list last time, kept in `enrichment_cursors` under
/// the channel's name. A playlist's `itemCount` counts private and deleted
/// videos, which are not written, so it cannot be compared with the rows held
/// -- only with the count it had when it was last read.
interface Checkpoint {
  lists?: Record<string, { count: number; readAt: string }>;
}

export function checkpointName(channelID: string): string {
  return `youtube.${channelID}`;
}

async function readCheckpoint(supabase: SupabaseClient, channelID: string): Promise<Checkpoint> {
  const { data, error } = await supabase
    .from("enrichment_cursors")
    .select("state")
    .eq("name", checkpointName(channelID))
    .maybeSingle();
  if (error) throw new Error(`youtube: checkpoint read failed: ${error.message}`);
  return (data?.state ?? {}) as Checkpoint;
}

async function writeCheckpoint(supabase: SupabaseClient, channelID: string, state: Checkpoint): Promise<void> {
  const { error } = await supabase
    .from("enrichment_cursors")
    .upsert({ name: checkpointName(channelID), state, updated_at: new Date().toISOString() }, { onConflict: "name" });
  if (error) throw new Error(`youtube: checkpoint write failed: ${error.message}`);
}

/// Whether a list can be left as it is: the same count as when it was last
/// read, and read recently enough that what is held has not aged out.
export function isUnchanged(
  last: { count: number; readAt: string } | undefined,
  count: number,
  now = Date.now(),
): boolean {
  if (!last || count < 0 || last.count !== count) return false;
  const age = now - Date.parse(last.readAt);
  return Number.isFinite(age) && age <= REFRESH_DAYS * 86_400_000;
}

/// How many lines an episode holds, so the feed never cuts back a list the
/// API read in full.
async function heldLines(supabase: SupabaseClient, playlistID: string): Promise<number> {
  const { data } = await supabase
    .from("radio_episodes")
    .select("id")
    .eq("provider", PROVIDER)
    .eq("external_id", playlistID)
    .maybeSingle();
  if (!data) return 0;
  const { count } = await supabase
    .from("radio_appearances")
    .select("id", { count: "exact", head: true })
    .eq("radio_episode_id", data.id);
  return count ?? 0;
}

async function writeEpisode(
  supabase: SupabaseClient,
  showID: string,
  playlistID: string,
  title: string,
  airedAt: string | null,
  imageURL: string | null,
  videos: ChannelVideo[],
  format: TitleFormat,
): Promise<void> {
  const written = await supabase
    .from("radio_episodes")
    .upsert({
      radio_show_id: showID,
      provider: PROVIDER,
      external_id: playlistID,
      title,
      aired_at: airedAt,
      archive_url: `https://www.youtube.com/playlist?list=${playlistID}`,
      image_url: imageURL,
      tracklist_status: videos.length > 0 ? "available" : "unavailable",
      genres: [],
      moods: [],
    }, { onConflict: "provider,external_id" })
    .select("id")
    .single();
  if (written.error || !written.data) {
    throw new Error(`youtube: episode upsert failed for ${playlistID}: ${written.error?.message}`);
  }
  if (videos.length > 0) {
    await storeTracklist(supabase, written.data.id as string, linesFor(videos, format), "youtube");
  }
}

export interface ChannelResult {
  channel: string;
  mode: "api" | "feed";
  playlists: number;
  written: number;
  held: number;
  videos: number;
  /// Stopped at the time budget with lists left; the next pass reads them.
  deferred?: boolean;
}

/// Reads one channel and files it. With a key, the uploads and every
/// playlist; without, the fifteen newest uploads from the public feed.
export async function crawlChannel(
  supabase: SupabaseClient,
  channelID: string,
  key: string | undefined,
  format: TitleFormat = "artist_title",
): Promise<ChannelResult> {
  const result: ChannelResult = {
    channel: channelID, mode: key ? "api" : "feed", playlists: 0, written: 0, held: 0, videos: 0,
  };

  if (!key) {
    const response = await fetch(`${FEED}${encodeURIComponent(channelID)}`, {
      headers: { "User-Agent": USER_AGENT },
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`youtube: feed answered ${response.status} for ${channelID}`);
    const feed = parseFeed(await response.text());
    const showID = await ensureShow(supabase, channelID, {
      title: feed.title ?? channelID, description: null, imageURL: null,
    });
    const uploads = uploadsPlaylistID(channelID);
    // The full uploads list, read once with a key, is never cut back to the
    // fifteen the feed carries.
    if (await heldLines(supabase, uploads) > feed.videos.length) {
      result.held++;
      return result;
    }
    await writeEpisode(supabase, showID, uploads, "Uploads",
      feed.videos[0]?.publishedAt ?? null, null, feed.videos, format);
    result.playlists = 1;
    result.written = 1;
    result.videos = feed.videos.length;
    return result;
  }

  const channel = await fetchChannel(channelID, key);
  if (!channel) throw new Error(`youtube: no channel ${channelID}`);
  const showID = await ensureShow(supabase, channelID, {
    title: channel.title, description: channel.description, imageURL: channel.imageURL,
  });

  const playlists = await fetchPlaylists(channelID, key);
  // The uploads list has no entry of its own in `playlists`; its size is the
  // channel's public video count.
  const shelves: Array<ApiPlaylist | { id: string; title: string; publishedAt: null; imageURL: null; itemCount: number }> = [
    { id: channel.uploads, title: "Uploads", publishedAt: null, imageURL: null, itemCount: channel.videoCount },
    ...playlists,
  ];
  result.playlists = shelves.length;

  const started = Date.now();
  const state = await readCheckpoint(supabase, channelID);
  const lists = { ...(state.lists ?? {}) };
  for (const shelf of shelves) {
    if (Date.now() - started > TIME_BUDGET_MS) {
      result.deferred = true;
      break;
    }
    // Unchanged and recently read: the same curator's list at the same size
    // is left alone, the way The Lot's unchanged broadcasts are.
    if (isUnchanged(lists[shelf.id], shelf.itemCount)) {
      result.held++;
      continue;
    }
    const videos = await fetchPlaylistItems(shelf.id, key);
    const airedAt = shelf.publishedAt ?? videos[0]?.publishedAt ?? null;
    await writeEpisode(supabase, showID, shelf.id, shelf.title, airedAt, shelf.imageURL, videos, format);
    lists[shelf.id] = { count: shelf.itemCount, readAt: new Date().toISOString() };
    // After every list, not once at the end: a pass that is cut off keeps
    // what it finished, and the next one starts from what it did not.
    await writeCheckpoint(supabase, channelID, { ...state, lists });
    result.written++;
    result.videos += videos.length;
  }
  return result;
}
