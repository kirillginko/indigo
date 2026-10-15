// An artist's whole Discogs discography, from its pages.
//
// The shelf the worker kept was page one: fifty lines of an artist who may
// have hundreds. Burial's is 377. A bundle built from page one describes the
// artist's latest fifty records and calls it the artist. This assembles every
// page that was fetched into one snapshot and says, beside it, how much of the
// artist it is: how many lines Discogs reported, how many pages there were,
// how many were fetched, and whether the cap cut it short.
//
// Masters and releases are kept apart. A shelf line for a master names the
// master and, as `main_release`, the release that stands for it; documents
// are read for that release, and every pressing a document says belongs to the
// same master is one record in the bundle (see artist_bundle.ts). So a record
// pressed four times is one record, and its credits are counted once.
//
// Pure: pages in, snapshot out.

import type { ShelfEntry } from "./artist_bundle.ts";

export const DISCOGRAPHY_FORMAT = "indigo.discography/1";

/// Discogs' largest page.
export const PER_PAGE = 100;
/// The most pages one artist's discography is read to. A thousand lines is
/// more than any artist Indigo's listeners keep has; past it the snapshot is
/// marked truncated rather than read forever.
export const MAX_PAGES = 10;
/// The most pages one job fetches before handing on to the next, so a big
/// discography is many short jobs, each inside the worker's time.
export const PAGES_PER_JOB = 3;

/// One page as Discogs returns it.
export interface DiscographyPage {
  page: number;
  pages: number;
  items: number;
  perPage: number;
  releases: ShelfEntry[];
}

/// One line, with the master and the release kept apart.
export interface DiscographyEntry {
  kind: "master" | "release";
  /// The master's id for a master line, the release's for a release line.
  id: number;
  /// The release documents are read for: a release line's own id, a master
  /// line's main release. Null when Discogs gives none.
  releaseID: number | null;
  role: string;
  artist: string;
  title: string;
  year: number | null;
}

export interface Discography {
  format: string;
  artist: { discogsID: number; name: string };
  identity: "backend" | "device-cache";
  totalReported: number | null;
  pagesReported: number | null;
  pagesFetched: number;
  perPage: number;
  /// Every page there is was fetched.
  complete: boolean;
  /// There were more pages than `MAX_PAGES`.
  truncated: boolean;
  entries: DiscographyEntry[];
}

function byText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/// Reads one Discogs response as a page, or null for one that is not.
export function readPage(body: unknown, page: number): DiscographyPage | null {
  if (!body || typeof body !== "object") return null;
  const value = body as { pagination?: Record<string, unknown>; releases?: unknown };
  if (!Array.isArray(value.releases)) return null;
  const pagination = value.pagination ?? {};
  const number = (v: unknown, fallback: number) => (typeof v === "number" && Number.isFinite(v) ? v : fallback);
  return {
    page: number(pagination.page, page),
    pages: number(pagination.pages, page),
    items: number(pagination.items, value.releases.length),
    perPage: number(pagination.per_page, PER_PAGE),
    releases: value.releases as ShelfEntry[],
  };
}

/// The pages fetched, as one snapshot. Pages may arrive in any order and
/// twice; lines are kept once each, in an order of their content.
export function assembleDiscography(
  artist: { discogsID: number; name: string },
  identity: Discography["identity"],
  pages: DiscographyPage[],
): Discography {
  const byNumber = new Map<number, DiscographyPage>();
  for (const page of pages) if (!byNumber.has(page.page)) byNumber.set(page.page, page);
  const reported = pages.length ? Math.max(...pages.map((p) => p.pages)) : null;
  const total = pages.length ? Math.max(...pages.map((p) => p.items)) : null;
  const wanted = reported === null ? 0 : Math.min(reported, MAX_PAGES);
  let fetched = 0;
  for (let n = 1; n <= wanted; n++) if (byNumber.has(n)) fetched += 1;

  const lines = new Map<string, DiscographyEntry>();
  for (const page of [...byNumber.values()].sort((a, b) => a.page - b.page)) {
    for (const line of page.releases) {
      const kind = line.type === "master" ? "master" : "release";
      if (typeof line.id !== "number") continue;
      const releaseID = kind === "master"
        ? (typeof line.main_release === "number" ? line.main_release : null)
        : line.id;
      const entry: DiscographyEntry = {
        kind, id: line.id, releaseID, role: (line.role ?? "").trim(),
        artist: (line.artist ?? "").trim(), title: (line.title ?? "").trim(),
        year: typeof line.year === "number" && line.year > 0 ? line.year : null,
      };
      const key = `${kind}:${line.id}:${entry.role}`;
      if (!lines.has(key)) lines.set(key, entry);
    }
  }

  return {
    format: DISCOGRAPHY_FORMAT,
    artist,
    identity,
    totalReported: total,
    pagesReported: reported,
    pagesFetched: fetched,
    perPage: pages[0]?.perPage ?? PER_PAGE,
    complete: reported !== null && fetched === reported,
    truncated: reported !== null && reported > MAX_PAGES,
    entries: [...lines.values()].sort((a, b) =>
      byText(a.kind, b.kind) || a.id - b.id || byText(a.role, b.role)
    ),
  };
}

/// The releases documents are wanted for, once each, in id order.
export function representativeReleases(discography: Discography): number[] {
  const ids = new Set<number>();
  for (const entry of discography.entries) if (entry.releaseID !== null) ids.add(entry.releaseID);
  return [...ids].sort((a, b) => a - b);
}

/// The discography as the A1 builder's shelf: every line, with the release
/// documents are read for as its id.
export function asShelf(discography: Discography): { total?: number; releases: ShelfEntry[] } {
  return {
    total: discography.totalReported ?? undefined,
    releases: discography.entries.map((e) => ({
      id: e.id, type: e.kind, main_release: e.kind === "master" ? e.releaseID ?? undefined : undefined,
      role: e.role, artist: e.artist, title: e.title, year: e.year ?? undefined,
    })),
  };
}
