// The Lot Radio archive -> Indigo's radio tables.
//
// The same bargain as NTS (see nts.ts): a tracklist is worth ingesting because
// "Heling" on line one of a Yushh set becomes an edge, and the artist page can
// say where it was played. What differs is how the station publishes it.
//
// The Lot has no public API. Its site is a Next.js app over Contentful, and
// every archive listing it renders carries the whole episode as data -- show,
// presenters, genres, HLS archive, and a timestamped tracklist -- so one
// request yields a page of complete broadcasts and there is nothing to fetch
// per episode. robots.txt is not published (the path falls through to the
// app), so nothing is reserved.
//
// Two ways in, both read-only:
//
//   * `fresh`: GET /the-index, whose server render embeds the newest 32
//     episodes. Stable, because it is the page itself.
//   * `backfill`: the "load more" the index calls as it scrolls, a Next.js
//     server action. Its id changes when the site is redeployed, so it is
//     read out of the site's own JavaScript and found again when it stops
//     answering. The cursor it pages with is signed by the site, which is why
//     it is carried forward rather than computed.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { normalizeName } from "./normalize.ts";
import { matchableName, storeTracklist, type TracklistLine } from "./radio.ts";

export const PROVIDER = "lotradio";
export const STATION = "The Lot Radio";
export const LOT_ORIGIN = "https://www.thelotradio.com";
const USER_AGENT = "Indigo/1.0 (+https://github.com/kirillginko/indigo)";

/// The page the index renders and asks for. The action is asked for the same
/// size so its cursor, which records the size it was issued at, stays true.
const PAGE = 32;

/// Where the crawl has got to; a row in `enrichment_cursors` (see 0039).
export const CHECKPOINT = "lotradio.the-index";

type Payload = Record<string, any>;

// ---------------------------------------------------------------------------
// Reading what the site publishes
// ---------------------------------------------------------------------------

// Windows-1252's own characters for bytes 0x80-0x9F, the half of the table
// where it differs from Latin-1.
const CP1252: Record<number, number> = {
  0x20ac: 0x80, 0x201a: 0x82, 0x0192: 0x83, 0x201e: 0x84, 0x2026: 0x85,
  0x2020: 0x86, 0x2021: 0x87, 0x02c6: 0x88, 0x2030: 0x89, 0x0160: 0x8a,
  0x2039: 0x8b, 0x0152: 0x8c, 0x017d: 0x8e, 0x2018: 0x91, 0x2019: 0x92,
  0x201c: 0x93, 0x201d: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
  0x02dc: 0x98, 0x2122: 0x99, 0x0161: 0x9a, 0x203a: 0x9b, 0x0153: 0x9c,
  0x017e: 0x9e, 0x0178: 0x9f,
};

// A UTF-8 lead byte read as Latin-1 (Â-ô) followed by a continuation byte read
// as Windows-1252. "Château" does not match: its â is followed by a t.
const MOJIBAKE =
  /[Â-ô][-¿ŒœŠšŸŽžƒˆ˜–—‘-‚“-„†-•…‰‹›€™]/;

/// Undoes UTF-8 that was decoded as Windows-1252 somewhere upstream.
///
/// Some Lot tracklists arrive as "Peter BrÃ¶tzmann" and "MikoÅ‚aj Trzaska".
/// Left alone, that is not a spelling problem but an identity one: the name
/// normalizes to a key no other station will ever produce, so the artist is
/// adopted a second time under a name nobody can search for. Only a string
/// that re-encodes to valid UTF-8 is changed, so real text is never touched.
export function repairMojibake(value: string): string {
  if (!MOJIBAKE.test(value)) return value;
  const bytes: number[] = [];
  for (const character of value) {
    const code = character.codePointAt(0)!;
    if (code <= 0xff) bytes.push(code);
    else if (CP1252[code] !== undefined) bytes.push(CP1252[code]);
    else return value;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(bytes));
  } catch {
    return value;
  }
}

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const cleaned = repairMojibake(value).replace(/\s+/g, " ").trim();
  return cleaned.length > 0 ? cleaned : null;
}

const SLUG = /^[a-z0-9][a-z0-9-]{0,120}$/i;

function slug(value: unknown): string | null {
  return typeof value === "string" && SLUG.test(value) ? value : null;
}

/// Every Next.js page streams its data as `self.__next_f.push([1, "..."])`
/// script tags; a request sent with `RSC: 1` gets the same stream bare. Either
/// is accepted, so the parse does not depend on which one came back.
export function flightPayload(body: string): string {
  if (!body.includes("self.__next_f.push")) return body;
  const pieces: string[] = [];
  for (const match of body.matchAll(/self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)/g)) {
    try {
      pieces.push(JSON.parse(match[1]));
    } catch {
      // One unreadable piece costs the data inside it, not the page.
    }
  }
  return pieces.join("");
}

/// The JSON value that starts at `start`, read by matching brackets rather
/// than by pattern, because tracklists are full of quotes and braces.
function balancedJSON(source: string, start: number): unknown | null {
  const open = source[start];
  if (open !== "{" && open !== "[") return null;
  let depth = 0;
  let inString = false;
  for (let index = start; index < source.length; index++) {
    const character = source[index];
    if (inString) {
      if (character === "\\") index++;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') inString = true;
    else if (character === "{" || character === "[") depth++;
    else if (character === "}" || character === "]") {
      depth--;
      if (depth === 0) {
        try {
          return JSON.parse(source.slice(start, index + 1));
        } catch {
          return null;
        }
      }
    }
  }
  return null;
}

export interface ArchivePage {
  items: Payload[];
  next: string | null;
  total: number | null;
}

function archivePage(value: unknown): ArchivePage | null {
  const page = value as Payload | null;
  if (!page || !Array.isArray(page.items)) return null;
  return {
    items: page.items,
    next: typeof page.pages?.next === "string" ? page.pages.next : null,
    total: typeof page.total === "number" ? page.total : null,
  };
}

/// The first page of the archive, as /the-index renders it.
export function parseIndexPage(payload: string): ArchivePage | null {
  const marker = payload.indexOf('"initialData":');
  if (marker < 0) return null;
  return archivePage(balancedJSON(payload, marker + '"initialData":'.length));
}

/// A later page, as the server action answers. Its reply is a flight stream
/// whose rows are `<id>:<json>`; the one holding the page is the one with
/// `items`, whichever row that happens to be.
export function parseActionReply(body: string): ArchivePage | null {
  for (const line of body.split("\n")) {
    const separator = line.indexOf(":");
    if (separator < 1 || line[separator + 1] !== "{") continue;
    try {
      const page = archivePage(JSON.parse(line.slice(separator + 1)));
      if (page) return page;
    } catch {
      continue;
    }
  }
  return null;
}

/// The id of the index's `getEpisodes` action, from one of the site's scripts.
export function findActionID(script: string): string | null {
  const match = script.match(
    /createServerReference\)?\(\s*"([0-9a-f]{40,64})"[^"]{0,160}"getEpisodes"/,
  );
  return match ? match[1] : null;
}

/// The scripts a page loads, which is where its action ids are declared.
export function scriptPaths(payload: string): string[] {
  const found = new Set<string>();
  for (const match of payload.matchAll(/\/_next\/static\/[A-Za-z0-9_./-]+?\.js/g)) {
    found.add(match[0]);
  }
  return [...found];
}

// ---------------------------------------------------------------------------
// One broadcast
// ---------------------------------------------------------------------------

/// Programmes that are not programmes. The Lot files every one-off guest under
/// "special-guests", which is half its archive; as one show it would top the
/// "played most by" list of nearly every artist the station has played, and
/// say nothing. Each guest is filed as their own programme instead -- the
/// grouping the site itself publishes at /artists/<slug>.
const GUEST_BUCKETS = new Set(["special-guests"]);

export interface LotPerson {
  name: string;
  slug: string | null;
  photoURL: string | null;
}

export interface LotShow {
  externalID: string;
  title: string;
  hosts: LotPerson[];
  imageURL: string | null;
  url: string;
}

export interface LotEpisode {
  externalID: string;
  url: string;
  title: string;
  airedAt: string | null;
  durationSeconds: number | null;
  archiveURL: string | null;
  imageURL: string | null;
  genres: string[];
  location: string | null;
  show: LotShow;
  /// Everyone the episode names as presenting it, residents and guests.
  presenters: LotPerson[];
  lines: TracklistLine[];
}

function people(raw: unknown): LotPerson[] {
  const items: Payload[] = Array.isArray((raw as Payload)?.items) ? (raw as Payload).items : [];
  const found: LotPerson[] = [];
  const seen = new Set<string>();
  for (const item of items) {
    const name = text(item?.name);
    const key = matchableName(name);
    if (!name || !key || seen.has(key)) continue;
    seen.add(key);
    found.push({ name, slug: slug(item?.slug), photoURL: text(item?.photo?.url) });
  }
  return found;
}

function genreNames(...sources: unknown[]): string[] {
  for (const source of sources) {
    const items: Payload[] = Array.isArray((source as Payload)?.items) ? (source as Payload).items : [];
    const seen = new Set<string>();
    const found: string[] = [];
    for (const item of items) {
      const name = text(item?.name);
      if (!name || seen.has(name.toLowerCase())) continue;
      seen.add(name.toLowerCase());
      found.push(name);
    }
    // The episode's own tags when it has any. A show's are what it usually
    // plays, which is a weaker claim about one night.
    if (found.length > 0) return found;
  }
  return [];
}

const PLACE_ALIASES: Record<string, string> = {
  "nyc": "New York",
  "new york city": "New York",
  "brooklyn": "New York",
  "brooklyn, ny": "New York",
};

/// Where a broadcast went out from, spelled the way NTS spells it.
///
/// Scenes key on this string (see 0014 and 0016), and NTS already files 321
/// broadcasts under "New York". The Lot writes "The Lot Radio, NYC", which as
/// a place would be a scene of its own that nothing else joins.
export function placeName(raw: string | null): string | null {
  if (!raw) return null;
  const comma = raw.lastIndexOf(",");
  const place = (comma >= 0 ? raw.slice(comma + 1) : raw).trim();
  if (!place || place.toLowerCase().startsWith("the lot")) return null;
  return PLACE_ALIASES[place.toLowerCase()] ?? place;
}

function seconds(from: string | null, to: unknown): number | null {
  if (!from || typeof to !== "string") return null;
  const difference = (Date.parse(to) - Date.parse(from)) / 1000;
  return Number.isFinite(difference) && difference >= 0 ? Math.floor(difference) : null;
}

/// Which programme a broadcast belongs to in Indigo.
function filedShow(item: Payload, episodeURL: string, title: string, presenters: LotPerson[]): LotShow | null {
  const showSlug = slug(item.show?.slug);

  if (showSlug && !GUEST_BUCKETS.has(showSlug)) {
    const hosts = people(item.show?.artists);
    return {
      externalID: showSlug,
      title: text(item.show?.name) ?? showSlug,
      hosts,
      imageURL: text(item.show?.photo?.url),
      url: `${LOT_ORIGIN}/shows/${showSlug}`,
    };
  }

  // A guest. Keyed on who presented it, so a DJ back for a second visit lands
  // on the same programme as their first.
  const named = presenters.filter((person) => person.slug !== null);
  if (named.length > 0) {
    return {
      externalID: `guests/${named.map((person) => person.slug).join("+")}`,
      title: named.map((person) => person.name).join(" & "),
      hosts: named,
      imageURL: named[0].photoURL,
      url: `${LOT_ORIGIN}/artists/${named[0].slug}`,
    };
  }

  // A guest the site does not name as an artist, which is a quarter of them.
  // The broadcast's title is the only name it has ("Mike Midnight", "emkay"),
  // and it is still a better programme than the bucket.
  const titleKey = normalizeName(title).replace(/ /g, "-");
  if (titleKey) {
    return {
      externalID: `guests/${titleKey}`,
      title,
      hosts: [],
      imageURL: null,
      url: episodeURL,
    };
  }

  return showSlug
    ? { externalID: showSlug, title: text(item.show?.name) ?? showSlug, hosts: [], imageURL: null, url: `${LOT_ORIGIN}/shows/${showSlug}` }
    : null;
}

/// One archive item, as Indigo files it. Null for anything that is not a
/// recognisable broadcast.
export function readEpisode(item: Payload): LotEpisode | null {
  const showSlug = slug(item?.show?.slug);
  const episodeSlug = slug(item?.slug);
  if (!showSlug || !episodeSlug) return null;

  const url = `${LOT_ORIGIN}/shows/${showSlug}/${episodeSlug}`;
  const title = text(item.title) ?? text(item.show?.name) ?? episodeSlug;
  const presenters = people(item.artists);
  const show = filedShow(item, url, title, presenters);
  if (!show) return null;

  const start = typeof item.startTimestamp === "string"
    ? item.startTimestamp
    : typeof item.date === "string" ? item.date : null;

  const tracks: Payload[] = Array.isArray(item.tracklist) ? item.tracklist : [];

  return {
    // The site's own path for the broadcast, so it can always be found again
    // however Indigo chose to file its programme.
    externalID: `${showSlug}/${episodeSlug}`,
    url,
    title,
    airedAt: start,
    durationSeconds: seconds(start, item.endTimestamp),
    archiveURL: text(item.transcodedFile?.hls) ?? url,
    imageURL: text(item.image?.url) ?? text(item.show?.photo?.url),
    genres: genreNames(item.genres, item.show?.genres),
    location: placeName(text(item.location?.name)),
    show,
    presenters: [...presenters, ...show.hosts].filter(
      (person, index, all) => all.findIndex((other) => other.name === person.name) === index,
    ),
    // Timestamps are wall-clock times from the station's recognition, not
    // offsets, so they are measured from when the broadcast actually started.
    lines: tracks.map((track) => ({
      artist: text(track?.artist),
      title: text(track?.title),
      offsetSeconds: seconds(start, track?.timestamp),
    })),
  };
}

// ---------------------------------------------------------------------------
// Writing it down
// ---------------------------------------------------------------------------

interface IngestMemo {
  shows: Map<string, string>;
  adopted: Set<string>;
}

async function adopt(supabase: SupabaseClient, people: LotPerson[], memo: IngestMemo): Promise<void> {
  for (const person of people) {
    const key = normalizeName(person.name);
    if (!key || memo.adopted.has(key)) continue;
    memo.adopted.add(key);
    // The same identity a tracklist line gets, so a selector who is also
    // played by somebody else -- here or on NTS -- is one artist with both.
    const { error } = await supabase.rpc("adopt_named_artist", {
      p_name: person.name,
      p_key: key,
      p_source_url: person.slug ? `${LOT_ORIGIN}/artists/${person.slug}` : null,
    });
    if (error) console.error("lotradio: presenter adopt failed", person.name, error.message);
  }
}

/// The programme's row, written only when what it says has changed. This runs
/// for every broadcast on every page, and an unconditional update would
/// rewrite the same rows each hour (see 0037).
async function ensureShow(supabase: SupabaseClient, show: LotShow, memo: IngestMemo): Promise<string | null> {
  const cached = memo.shows.get(show.externalID);
  if (cached) return cached;

  const wanted = {
    title: show.title,
    station: STATION,
    host_name: show.hosts.length > 0 ? show.hosts.map((host) => host.name).join(" & ") : null,
    provider_url: show.url,
  };

  const existing = await supabase
    .from("radio_shows")
    .select("id,title,station,host_name,provider_url,image_url")
    .eq("provider", PROVIDER)
    .eq("external_id", show.externalID)
    .maybeSingle();

  let id = existing.data?.id as string | undefined;

  if (!id) {
    const inserted = await supabase
      .from("radio_shows")
      .insert({ provider: PROVIDER, external_id: show.externalID, image_url: show.imageURL, ...wanted })
      .select("id")
      .single();
    id = inserted.data?.id as string | undefined;

    if (!id) {
      // Lost a race to another page carrying the same programme.
      const winner = await supabase
        .from("radio_shows")
        .select("id")
        .eq("provider", PROVIDER)
        .eq("external_id", show.externalID)
        .maybeSingle();
      id = winner.data?.id as string | undefined;
    }
    if (!id) return null;
  } else {
    const row = existing.data!;
    // A picture the site has stopped sending is kept rather than erased.
    const imageURL = show.imageURL ?? row.image_url ?? null;
    const changed = row.title !== wanted.title || row.station !== wanted.station ||
      row.host_name !== wanted.host_name || row.provider_url !== wanted.provider_url ||
      row.image_url !== imageURL;
    if (changed) {
      const update = await supabase
        .from("radio_shows")
        .update({ ...wanted, image_url: imageURL })
        .eq("id", id);
      if (update.error) console.error("lotradio: show update failed", update.error.message);
    }
  }

  memo.shows.set(show.externalID, id);
  return id;
}

/// Whether a broadcast already holds everything this copy of it says.
///
/// The fresh pass reads the same thirty-two broadcasts every hour, so without
/// this it would rewrite their tracklists every hour for nothing. A broadcast
/// is read again only when it has no row, or its tracklist has grown or
/// changed length since -- the station's recognition can still be adding
/// lines while a show is on air.
async function alreadyHeld(
  supabase: SupabaseClient,
  episode: LotEpisode,
  existing: { id: string; tracklist_status: string } | undefined,
): Promise<boolean> {
  if (!existing) return false;
  const lines = episode.lines.filter((line) => line.artist !== null || line.title !== null).length;
  if (lines === 0) return true;
  if (existing.tracklist_status !== "available") return false;

  const { count, error } = await supabase
    .from("radio_appearances")
    .select("id", { count: "exact", head: true })
    .eq("radio_episode_id", existing.id);
  return !error && count === lines;
}

export interface IngestResult {
  offered: number;
  written: number;
  held: number;
  unreadable: number;
}

/// A page of archive items, written episode by episode.
export async function ingestLotItems(supabase: SupabaseClient, items: Payload[]): Promise<IngestResult> {
  const episodes = items.map(readEpisode);
  const readable = episodes.filter((episode): episode is LotEpisode => episode !== null);
  const result: IngestResult = {
    offered: items.length,
    written: 0,
    held: 0,
    unreadable: items.length - readable.length,
  };
  if (readable.length === 0) return result;

  const { data: rows, error } = await supabase
    .from("radio_episodes")
    .select("id,external_id,tracklist_status")
    .eq("provider", PROVIDER)
    .in("external_id", readable.map((episode) => episode.externalID));
  if (error) throw new Error(`lotradio: episode lookup failed: ${error.message}`);

  const existing = new Map(
    (rows ?? []).map((row) => [row.external_id as string, row as { id: string; tracklist_status: string }]),
  );
  const memo: IngestMemo = { shows: new Map(), adopted: new Set() };

  for (const episode of readable) {
    if (await alreadyHeld(supabase, episode, existing.get(episode.externalID))) {
      result.held++;
      continue;
    }

    const showID = await ensureShow(supabase, episode.show, memo);
    await adopt(supabase, episode.presenters, memo);

    const hasTracklist = episode.lines.some((line) => line.artist !== null || line.title !== null);
    const written = await supabase
      .from("radio_episodes")
      .upsert({
        radio_show_id: showID,
        provider: PROVIDER,
        external_id: episode.externalID,
        title: episode.title,
        aired_at: episode.airedAt,
        duration_seconds: episode.durationSeconds,
        archive_url: episode.archiveURL,
        image_url: episode.imageURL,
        // "unavailable" is a finding: the fresh pass will look again while
        // the broadcast is still on the index, and stop once it is not.
        tracklist_status: hasTracklist ? "available" : "unavailable",
        genres: episode.genres,
        moods: [],
        location: episode.location,
      }, { onConflict: "provider,external_id" })
      .select("id")
      .single();

    if (written.error || !written.data) {
      console.error("lotradio: episode upsert failed", episode.externalID, written.error?.message);
      continue;
    }

    // An empty tracklist never erases one already held.
    if (hasTracklist) {
      await storeTracklist(supabase, written.data.id as string, episode.lines, "lotradio");
    }
    result.written++;
  }

  return result;
}

// ---------------------------------------------------------------------------
// Walking the archive
// ---------------------------------------------------------------------------

interface Checkpoint {
  /// The site's signed cursor for the next page, or null before the first.
  cursor?: string | null;
  /// The index's `getEpisodes` action, as last found.
  action?: string | null;
  /// The whole archive has been walked once. Fresh keeps up from here.
  done?: boolean;
  total?: number | null;
}

async function readCheckpoint(supabase: SupabaseClient): Promise<Checkpoint> {
  const { data, error } = await supabase
    .from("enrichment_cursors")
    .select("state")
    .eq("name", CHECKPOINT)
    .maybeSingle();
  if (error) throw new Error(`lotradio: checkpoint read failed: ${error.message}`);
  return (data?.state ?? {}) as Checkpoint;
}

async function writeCheckpoint(supabase: SupabaseClient, state: Checkpoint): Promise<void> {
  const { error } = await supabase
    .from("enrichment_cursors")
    .upsert({ name: CHECKPOINT, state, updated_at: new Date().toISOString() }, { onConflict: "name" });
  if (error) throw new Error(`lotradio: checkpoint write failed: ${error.message}`);
}

async function fetchText(url: string, init: RequestInit = {}): Promise<string> {
  const response = await fetch(url, {
    ...init,
    headers: { "User-Agent": USER_AGENT, ...(init.headers ?? {}) },
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`upstream ${response.status} for ${url}`);
  return await response.text();
}

async function fetchIndex(): Promise<{ payload: string; page: ArchivePage }> {
  const payload = flightPayload(
    await fetchText(`${LOT_ORIGIN}/the-index`, { headers: { RSC: "1" } }),
  );
  const page = parseIndexPage(payload);
  if (!page) throw new Error("lotradio: the index carried no archive page");
  return { payload, page };
}

/// Reads the site's scripts, one at a time, until one declares the action.
/// Only happens on the first backfill and after the site is redeployed.
async function discoverAction(indexPayload: string): Promise<string> {
  for (const path of scriptPaths(indexPayload).slice(0, 60)) {
    let script: string;
    try {
      script = await fetchText(`${LOT_ORIGIN}${path}`);
    } catch {
      continue;
    }
    const found = findActionID(script);
    if (found) return found;
  }
  throw new Error("lotradio: no script on the index declares getEpisodes");
}

async function requestPage(action: string, cursor: string): Promise<ArchivePage | null> {
  try {
    const body = await fetchText(`${LOT_ORIGIN}/the-index`, {
      method: "POST",
      headers: {
        Accept: "text/x-component",
        "Content-Type": "text/plain;charset=UTF-8",
        "Next-Action": action,
      },
      body: JSON.stringify([{
        limit: PAGE,
        cursor,
        order: "date:desc",
        filters: {},
        staffChoice: false,
      }]),
    });
    return parseActionReply(body);
  } catch (cause) {
    console.error("lotradio: page request failed", String(cause));
    return null;
  }
}

/// `fresh` reads what the index shows today; `backfill` walks one page further
/// back into the archive per call. Neither enqueues per-episode work: the page
/// already holds every broadcast in full.
export async function discoverLotRadio(supabase: SupabaseClient, mode: string): Promise<IngestResult & { mode: string }> {
  const state = await readCheckpoint(supabase);

  if (mode !== "backfill") {
    const { page } = await fetchIndex();
    const result = await ingestLotItems(supabase, page.items);
    // The first fresh read is also where the walk back starts.
    if (!state.cursor && !state.done && page.next) {
      await writeCheckpoint(supabase, { ...state, cursor: page.next, total: page.total });
    }
    return { mode: "fresh", ...result };
  }

  if (state.done) return { mode: "backfill", offered: 0, written: 0, held: 0, unreadable: 0 };

  if (!state.cursor) {
    // Nothing to continue from yet. Reading the top is the first page of the
    // walk, and it hands out the cursor for the second.
    const { page } = await fetchIndex();
    const result = await ingestLotItems(supabase, page.items);
    await writeCheckpoint(supabase, { ...state, cursor: page.next, done: !page.next, total: page.total });
    return { mode: "backfill", ...result };
  }

  let action = state.action ?? null;
  let page = action ? await requestPage(action, state.cursor) : null;

  if (!page) {
    // Never found, or the site has been redeployed since. Find it again and
    // ask once more.
    const { payload } = await fetchIndex();
    action = await discoverAction(payload);
    page = await requestPage(action, state.cursor);
  }

  if (!page) {
    // A current action that still refuses the cursor means the cursor is what
    // went stale. Start the walk again from the top; everything already held
    // is stepped over on the way back down.
    await writeCheckpoint(supabase, { ...state, action, cursor: null });
    throw new Error("lotradio: the archive refused its cursor; restarting the walk");
  }

  const result = await ingestLotItems(supabase, page.items);
  await writeCheckpoint(supabase, {
    ...state,
    action,
    cursor: page.next,
    done: !page.next,
    total: page.total ?? state.total ?? null,
  });
  return { mode: "backfill", ...result };
}
