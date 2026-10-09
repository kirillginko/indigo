// An artist's knowledge, derived from the Discogs documents Indigo already
// keeps in R2, as one small immutable bundle.
//
// For You's strongest routes -- who an artist made records with, who produced
// and played on them, which labels released them, what they sound like -- are
// all written in Discogs' release documents, and the worker has 150,000 of
// them in R2. Devices cannot read them: an artist's catalogue is dozens of
// documents, and the public host rate-limits. So the worker folds them into
// one bundle per artist, a few kilobytes, which a device can fetch once and
// keep.
//
// Pure: documents in, bundle out. No network, no clock, no randomness. The
// same documents in any order, with duplicates, give the same bytes and the
// same digest, and a bundle is stored under its digest -- an immutable object
// a manifest points at, never one overwritten in place (see the design in the
// For You notes).
//
// What a document says about the artist is kept apart by how it says it,
// because the app's routes mean different things:
// - `releases`: every document used, with the artist's relation to it --
//   `main` (theirs), `joint` (theirs with others named alongside), `track` (on
//   one of its tracks), `credit` (credited for a job on it) -- and whether it
//   is a compilation.
// - `collaborators`: people the artist made records *with*: other main
//   artists on a joint release, and the main artist of a record the artist
//   appeared on, remixed or produced (Discogs' own role, kept). This is the
//   app's "Credited together".
// - `credits`: people credited for a job on the artist's own records, with
//   the role, the release and the tracks. The app's producer and personnel
//   routes. A credit is never a collaboration: Ed Stasium engineering a
//   record is not Ed Stasium making one with its artist.
// - `styles`, `genres`, `years`, `labels`: from the artist's own records
//   only. Labels by Discogs label id; the name is kept as Discogs writes it,
//   with the app's display form beside it. Two labels are never one because
//   their names match.
//
//     deno test supabase/functions/_shared/artist_bundle_test.ts

import { normalizeName } from "./normalize.ts";
import { isRealArtist } from "./credit.ts";

export const BUNDLE_FORMAT = "indigo.artist-knowledge/1";

/// The most people kept in `collaborators`, and in `credits` for each kind of
/// job. Ranked first, so what is cut is the least evidenced; per kind, so a
/// discography thick with remixers cannot crowd out the saxophonist on one
/// record.
export const MAX_COLLABORATORS = 60;
export const MAX_CREDITED_PER_KIND = 60;

/// Discogs' "Various" artist, the main artist of a compilation.
const VARIOUS_ID = 194;

// MARK: - The documents

export interface DiscogsPerson {
  id?: number;
  name?: string;
  anv?: string;
  join?: string;
  role?: string;
  tracks?: string;
}

export interface DiscogsTrack {
  position?: string;
  type_?: string;
  title?: string;
  artists?: DiscogsPerson[];
  extraartists?: DiscogsPerson[];
}

export interface DiscogsReleaseDoc {
  id?: number;
  title?: string;
  year?: number;
  master_id?: number;
  styles?: string[];
  genres?: string[];
  artists?: DiscogsPerson[];
  extraartists?: DiscogsPerson[];
  labels?: { id?: number; name?: string; catno?: string }[];
  formats?: { name?: string; descriptions?: string[] }[];
  tracklist?: DiscogsTrack[];
}

/// One line of `artists/<id>/releases`: a release or master the artist is
/// connected to, with Discogs' word for how.
export interface ShelfEntry {
  id?: number;
  type?: string;
  main_release?: number;
  role?: string;
  artist?: string;
  title?: string;
  year?: number;
}

export interface BundleInput {
  artist: { discogsID: number; name: string };
  shelf?: { total?: number; releases?: ShelfEntry[] } | null;
  releases: DiscogsReleaseDoc[];
  /// Which release speaks for each master, when the caller knows (the
  /// discography's main release). Otherwise the releases the shelf names
  /// do, and then the lowest release id.
  preferred?: number[];
  /// Where the documents came from, written into the bundle as given.
  source?: BundleSource;
}

/// What a bundle was built from: the discography snapshot, how complete it
/// was, and how many of its releases had documents.
export interface BundleSource {
  /// "backend" when Indigo's catalogue names the artist's Discogs id;
  /// "device-cache" when a device's own enrichment supplied it.
  identity: "backend" | "device-cache";
  discography: string | null;
  complete: boolean;
  truncated: boolean;
  totalReported: number | null;
  pagesReported: number | null;
  pagesFetched: number;
  entries: number;
  representativeReleases: number;
  documentsRead: number;
  documentsMissing: number;
  documentsTruncated: number;
  /// Documents read for other pressings of the records, from releases the
  /// catalogue already files under the artist.
  otherPressingsRead?: number;
}

// MARK: - The bundle

export type Relation = "main" | "joint" | "track" | "credit";

export interface PersonRef {
  discogsID: number | null;
  /// Discogs' canonical name ("Shabaka Hutchings").
  name: string;
  /// How a record credits them, when it differs ("Shabaka Hutchins") -- the
  /// spelling the app shows. The first in byte order across their records.
  anv?: string;
}

export interface Bundle {
  format: string;
  artist: { discogsID: number; name: string; nameKey: string };
  coverage: {
    shelfEntries: number;
    shelfTotal: number | null;
    documents: number;
    used: number;
    duplicates: number;
    /// Documents that are other pressings of a record already counted: read,
    /// and combined into that record, never counted as records of their own.
    pressings: number;
    unrelated: number;
    malformed: number;
    shelfWithoutDocument: number;
    ownWithoutStyles: number;
    ownWithoutLabels: number;
    ownWithoutYear: number;
    creditsDropped: number;
  };
  releases: { id: number; masterID: number | null; title: string; year: number | null; relation: Relation; compilation: boolean }[];
  source?: BundleSource;
  styles: { name: string; releases: number }[];
  genres: { name: string; releases: number }[];
  /// Styles of records the artist is on but that are not theirs -- a track
  /// on somebody's album, a job on it. Kept apart: what a record the artist
  /// played on sounds like says less about them than their own.
  stylesAround: { name: string; releases: number }[];
  years: { first: number; last: number } | null;
  labels: {
    discogsID: number | null;
    name: string;
    display: string;
    releases: number;
    placeholder: boolean;
    ownName: boolean;
  }[];
  collaborators: { artist: PersonRef; how: string[]; releases: number[] }[];
  credits: {
    artist: PersonRef;
    roles: { role: string; kind: CreditKind | null; releases: { id: number; tracks: string[] }[] }[];
  }[];
}

// MARK: - The app's rules, ported

/// `DiscogsClient.withoutDisambiguator`: "Stroom (2)" -> "Stroom", and the
/// asterisk Discogs marks a name variation with.
export function withoutDisambiguator(name: string): string {
  return name.replace(/\s*\(\d+\)/g, "").replace(/\*/g, "").replace(/\s{2,}/g, " ").trim();
}

const PLACEHOLDER_LABELS = new Set([
  "unknown label", "no label", "none", "unknown", "self released",
  "self release", "self releases", "selfrelease", "selfreleased",
  "self published", "self issued", "self titled", "selftitled",
  "independent", "independently released", "diy", "white label",
  "no label records", "own label", "private press", "bootleg",
]);

/// `LabelName.isPlaceholder`: the absence of a label written down.
export function isPlaceholderLabel(name: string): boolean {
  const key = normalizeName(name);
  return key.length === 0 || key.startsWith("not on label") || PLACEHOLDER_LABELS.has(key);
}

export type CreditKind = "production" | "writing" | "engineering" | "performance";

const PRESENTATION = [
  "design", "artwork", "photograph", "illustration", "layout", "sleeve",
  "cover", "liner notes", "翻訳", "translation", "lacquer", "pressed by",
  "distributed by", "manufactured", "management", "a&r", "legal",
  "copyright", "phonographic", "typography", "concept", "model",
];
const KIND_RANK: Record<CreditKind, number> = { production: 0, writing: 1, performance: 2, engineering: 3 };

/// `CreditRole.kind`: what a Discogs role is, musically. Null for the jobs
/// around a record rather than on it (design, pressing, legal).
export function creditKind(role: string | undefined): CreditKind | null {
  if (!role) return null;
  let best: CreditKind | null = null;
  for (const part of role.toLowerCase().split(",")) {
    const job = part.trim();
    if (!job) continue;
    if (PRESENTATION.some((word) => job.includes(word))) continue;
    let found: CreditKind;
    if (job.includes("produc") || job.includes("mix") || job.includes("remix")) found = "production";
    else if (job.includes("written") || job.includes("compos") || job.includes("lyric") ||
      job.includes("songwriter") || job.includes("arrang")) found = "writing";
    else if (job.includes("engineer") || job.includes("master") || job.includes("record")) found = "engineering";
    else found = "performance";
    if (best === null || KIND_RANK[found] < KIND_RANK[best]) best = found;
  }
  return best;
}

// MARK: - Deriving

/// The words Discogs' artist shelf uses for a connection that is not a job
/// on the sleeve but is still making the record.
const SHELF_ROLES = new Set(["Appearance", "TrackAppearance", "Remix", "Producer", "Co-producer", "Mixed by"]);

/// "Mixed By, Producer" as its two roles, each trimmed, and one spelling per
/// role whatever its case ("Mixed by" is "Mixed By"). The first spelling in
/// byte order is the one kept, so no input order can change it.
function splitRoles(role: string | undefined): string[] {
  const found = new Map<string, string>();
  for (const part of (role ?? "").split(",")) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const key = trimmed.toLowerCase();
    const held = found.get(key);
    if (held === undefined || trimmed < held) found.set(key, trimmed);
  }
  return [...found.values()];
}

function byText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/// Who a person is, for grouping: their Discogs id when the document gives
/// one, otherwise the name exactly as written. Never a folded name -- that is
/// how two people become one.
function identity(person: PersonRef): string {
  return person.discogsID !== null ? `id:${person.discogsID}` : `name:${person.name}`;
}

function ref(person: DiscogsPerson): PersonRef | null {
  const name = (person.name ?? "").trim();
  if (!name || !isRealArtist(withoutDisambiguator(name))) return null;
  if (person.id === VARIOUS_ID) return null;
  const anv = (person.anv ?? "").trim();
  return { discogsID: typeof person.id === "number" ? person.id : null, name, ...(anv && anv !== name ? { anv } : {}) };
}

/// The same person seen twice: the first name and the first credited
/// spelling in byte order, so the order records arrive in cannot matter.
function mergeRef(held: PersonRef, seen: PersonRef): PersonRef {
  const name = seen.name < held.name ? seen.name : held.name;
  const anvs = [held.anv, seen.anv].filter((a): a is string => !!a).sort(byText);
  return { discogsID: held.discogsID, name, ...(anvs.length ? { anv: anvs[0] } : {}) };
}

function isCompilation(doc: DiscogsReleaseDoc): boolean {
  if ((doc.artists ?? []).some((a) => a.id === VARIOUS_ID)) return true;
  return (doc.formats ?? []).some((f) => (f.descriptions ?? []).some((d) => d.toLowerCase() === "compilation"));
}

export function deriveArtistBundle(input: BundleInput): Bundle {
  const me = input.artist.discogsID;
  const coverage: Bundle["coverage"] = {
    shelfEntries: input.shelf?.releases?.length ?? 0,
    shelfTotal: typeof input.shelf?.total === "number" ? input.shelf.total : null,
    documents: input.releases.length,
    used: 0, duplicates: 0, pressings: 0, unrelated: 0, malformed: 0, shelfWithoutDocument: 0,
    ownWithoutStyles: 0, ownWithoutLabels: 0, ownWithoutYear: 0, creditsDropped: 0,
  };

  // One document per release id. A duplicate is the same record twice; the
  // first by content order is kept, so which copy arrived first cannot matter.
  const byID = new Map<number, DiscogsReleaseDoc>();
  for (const doc of input.releases) {
    if (typeof doc?.id !== "number") { coverage.malformed += 1; continue; }
    const held = byID.get(doc.id);
    if (held) {
      coverage.duplicates += 1;
      if (JSON.stringify(doc) < JSON.stringify(held)) byID.set(doc.id, doc);
      continue;
    }
    byID.set(doc.id, doc);
  }

  // Discogs' own word for each release, from the shelf.
  const shelfRoles = new Map<number, Set<string>>();
  const shelfArtist = new Map<number, string>();
  for (const entry of input.shelf?.releases ?? []) {
    const id = entry.type === "master" ? entry.main_release : entry.id;
    if (typeof id !== "number") continue;
    if (entry.role) {
      const roles = shelfRoles.get(id) ?? new Set<string>();
      roles.add(entry.role);
      shelfRoles.set(id, roles);
    }
    if (entry.artist) shelfArtist.set(id, entry.artist);
    if (!byID.has(id)) coverage.shelfWithoutDocument += 1;
  }

  // One record per master. Pressings of the same record are one record --
  // its collaborators made it once -- but they do not all say the same
  // thing: one pressing lists the producer, another only the label. So every
  // pressing is read, and what they say is combined under one record and
  // counted once. The record is named by the release the shelf names (its
  // main release), else the lowest id, so arrival order cannot choose.
  const preferred = new Set(input.preferred ?? [...shelfRoles.keys(), ...shelfArtist.keys()]);
  const recordOf = new Map<number, number>();
  const pressingsOf = new Map<number, number[]>();
  for (const id of [...byID.keys()].sort((a, b) => a - b)) {
    const master = byID.get(id)!.master_id;
    if (typeof master === "number" && master > 0) {
      const group = pressingsOf.get(master) ?? [];
      group.push(id);
      pressingsOf.set(master, group);
    } else {
      recordOf.set(id, id);
    }
  }
  for (const group of pressingsOf.values()) {
    const record = group.find((id) => preferred.has(id)) ?? group[0];
    for (const id of group) recordOf.set(id, record);
    coverage.pressings += group.length - 1;
  }

  const releases: Bundle["releases"] = [];
  const styles = new Map<string, number>();
  const genres = new Map<string, number>();
  const stylesAround = new Map<string, number>();
  const years: number[] = [];
  const labels = new Map<string, Bundle["labels"][number]>();
  const collaborators = new Map<string, { artist: PersonRef; how: Set<string>; releases: Set<number> }>();
  const credited = new Map<string, { artist: PersonRef; roles: Map<string, Map<number, Set<string>>> }>();

  function addCollaborator(person: PersonRef, how: string, release: number) {
    if (person.discogsID === me) return;
    if (person.discogsID === null && normalizeName(withoutDisambiguator(person.name)) ===
        normalizeName(withoutDisambiguator(input.artist.name))) return;
    const key = identity(person);
    const entry = collaborators.get(key) ?? { artist: person, how: new Set(), releases: new Set() };
    entry.artist = mergeRef(entry.artist, person);
    entry.how.add(how);
    entry.releases.add(release);
    collaborators.set(key, entry);
  }

  // What each document says about the artist.
  interface Seen {
    doc: DiscogsReleaseDoc;
    relation: Relation;
    compilation: boolean;
    roles: Set<string>;
    otherMains: PersonRef[];
  }
  const records = new Map<number, Seen[]>();
  for (const id of [...byID.keys()].sort((a, b) => a - b)) {
    const doc = byID.get(id)!;
    const mains = (doc.artists ?? []).filter((a) => typeof a.id === "number");
    const isMain = mains.some((a) => a.id === me);
    const onTrack = (doc.tracklist ?? []).some((t) => (t.artists ?? []).some((a) => a.id === me));
    const creditsOfMine = [
      ...(doc.extraartists ?? []),
      ...(doc.tracklist ?? []).flatMap((t) => t.extraartists ?? []),
    ].filter((p) => p.id === me);
    const otherMains = mains.map(ref).filter((p): p is PersonRef => p !== null && p.discogsID !== me);

    let relation: Relation;
    if (isMain) relation = otherMains.length > 0 ? "joint" : "main";
    else if (onTrack) relation = "track";
    else if (creditsOfMine.length > 0 || shelfRoles.has(id)) relation = "credit";
    else { coverage.unrelated += 1; continue; }
    coverage.used += 1;

    // The artist's own jobs on it: Discogs' shelf word and every role the
    // document credits them with, one role each, musical ones only -- being
    // photographed for a sleeve is not making a record with somebody.
    const roles = new Set<string>();
    for (const role of shelfRoles.get(id) ?? []) if (SHELF_ROLES.has(role) || creditKind(role) !== null) roles.add(role);
    for (const credit of creditsOfMine) {
      for (const role of splitRoles(credit.role)) if (creditKind(role) !== null) roles.add(role);
    }
    const record = recordOf.get(id) ?? id;
    const seen = records.get(record) ?? [];
    seen.push({ doc, relation, compilation: isCompilation(doc), roles, otherMains });
    records.set(record, seen);
  }

  // Each record once, from everything its pressings say.
  const STRENGTH: Record<Relation, number> = { joint: 0, main: 1, track: 2, credit: 3 };
  const validYear = (year: number | undefined) => typeof year === "number" && year > 1900 && year < 2200;
  for (const record of [...records.keys()].sort((a, b) => a - b)) {
    const seen = records.get(record)!;
    const relation = seen.map((s) => s.relation).sort((a, b) => STRENGTH[a] - STRENGTH[b])[0];
    const compilation = seen.some((s) => s.compilation);
    const named = seen.find((s) => s.doc.id === record)?.doc ?? seen[0].doc;
    const pressingYears = seen.map((s) => s.doc.year).filter(validYear) as number[];
    releases.push({
      id: record,
      masterID: typeof named.master_id === "number" && named.master_id > 0 ? named.master_id : null,
      title: (named.title ?? "").trim(),
      year: pressingYears.length ? Math.min(...pressingYears) : null,
      relation, compilation,
    });
    const otherMains = new Map<string, PersonRef>();
    for (const s of seen) for (const p of s.otherMains) otherMains.set(identity(p), mergeRef(otherMains.get(identity(p)) ?? p, p));

    if (relation === "main" || relation === "joint") {
      // What the artist's own records say about them, once a record.
      const recordStyles = new Set(seen.flatMap((s) => s.doc.styles ?? []));
      if (recordStyles.size === 0) coverage.ownWithoutStyles += 1;
      for (const style of recordStyles) styles.set(style, (styles.get(style) ?? 0) + 1);
      for (const genre of new Set(seen.flatMap((s) => s.doc.genres ?? []))) genres.set(genre, (genres.get(genre) ?? 0) + 1);
      if (pressingYears.length) years.push(Math.min(...pressingYears));
      else coverage.ownWithoutYear += 1;

      const seenHere = new Set<string>();
      for (const label of seen.flatMap((s) => s.doc.labels ?? [])) {
        const name = (label.name ?? "").trim();
        if (!name) continue;
        // By Discogs id; a label with none is only ever itself.
        const key = typeof label.id === "number" ? `id:${label.id}` : `name:${name}`;
        if (seenHere.has(key)) continue;
        seenHere.add(key);
        const display = withoutDisambiguator(name);
        const entry = labels.get(key) ?? {
          discogsID: typeof label.id === "number" ? label.id : null, name, display, releases: 0,
          placeholder: isPlaceholderLabel(display),
          ownName: normalizeName(display) === normalizeName(withoutDisambiguator(input.artist.name)),
        };
        entry.releases += 1;
        labels.set(key, entry);
      }
      if (seenHere.size === 0) coverage.ownWithoutLabels += 1;

      // Made with: the others named alongside.
      for (const other of otherMains.values()) addCollaborator(other, "joint", record);

      // Credited on it: a job, with where on the record -- from every pressing.
      for (const { doc } of seen) {
        const jobs: { person: DiscogsPerson; tracks: string }[] = [
          ...(doc.extraartists ?? []).map((person) => ({ person, tracks: (person.tracks ?? "").trim() })),
          ...(doc.tracklist ?? []).flatMap((track) =>
            (track.extraartists ?? []).map((person) => ({ person, tracks: (track.position ?? "").trim() }))
          ),
        ];
        for (const { person, tracks } of jobs) {
          if (person.id === me) continue;
          const who = ref(person);
          if (!who) continue;
          for (const role of splitRoles(person.role)) {
            if (creditKind(role) === null) { coverage.creditsDropped += 1; continue; }
            const key = identity(who);
            const entry = credited.get(key) ?? { artist: who, roles: new Map() };
            entry.artist = mergeRef(entry.artist, who);
            const onRelease = entry.roles.get(role) ?? new Map<number, Set<string>>();
            const where = onRelease.get(record) ?? new Set<string>();
            if (tracks) for (const t of tracks.split(",").map((t) => t.trim()).filter(Boolean)) where.add(t);
            onRelease.set(record, where);
            entry.roles.set(role, onRelease);
            credited.set(key, entry);
          }
        }
      }
    } else if (!compilation) {
      // Made with: the artist whose record this is, for the jobs the artist
      // did on it. A compilation's main artist is everybody, which is nobody;
      // and a record the artist is only credited on for something
      // non-musical is not one they made with anybody.
      const roles = new Set(seen.flatMap((s) => [...s.roles]));
      if (seen.some((s) => s.relation === "track")) roles.add("TrackAppearance");
      if (roles.size === 0) { coverage.creditsDropped += 1; continue; }
      for (const style of new Set(seen.flatMap((s) => s.doc.styles ?? []))) {
        stylesAround.set(style, (stylesAround.get(style) ?? 0) + 1);
      }
      for (const other of otherMains.values()) for (const role of roles) addCollaborator(other, role, record);
    }
  }

  // Shelf lines whose documents are not here still say who the artist worked
  // with, by name only: Discogs gives no id on a shelf line.
  for (const entry of input.shelf?.releases ?? []) {
    const id = entry.type === "master" ? entry.main_release : entry.id;
    if (typeof id !== "number" || byID.has(id)) continue;
    if (!entry.role || entry.role === "Main" || !entry.artist) continue;
    if (!SHELF_ROLES.has(entry.role) && creditKind(entry.role) === null) continue;
    const who = ref({ name: entry.artist });
    if (who) addCollaborator(who, entry.role, id);
  }

  const sortedCounts = (map: Map<string, number>) =>
    [...map.entries()].map(([name, releases]) => ({ name, releases }))
      .sort((a, b) => b.releases - a.releases || byText(a.name, b.name));

  const rankCollaborator = (a: { artist: PersonRef; releases: Set<number> }, b: typeof a) =>
    b.releases.size - a.releases.size || byText(a.artist.name, b.artist.name) ||
    (a.artist.discogsID ?? 0) - (b.artist.discogsID ?? 0);

  const creditWeight = (entry: { roles: Map<string, Map<number, Set<string>>> }) =>
    new Set([...entry.roles.values()].flatMap((r) => [...r.keys()])).size;
  const bestKind = (entry: { roles: Map<string, Map<number, Set<string>>> }) =>
    Math.min(...[...entry.roles.keys()].map((role) => KIND_RANK[creditKind(role)!]));

  return {
    format: BUNDLE_FORMAT,
    artist: { discogsID: me, name: input.artist.name, nameKey: normalizeName(withoutDisambiguator(input.artist.name)) },
    coverage,
    ...(input.source ? { source: input.source } : {}),
    releases,
    styles: sortedCounts(styles),
    genres: sortedCounts(genres),
    stylesAround: sortedCounts(stylesAround),
    years: years.length ? { first: Math.min(...years), last: Math.max(...years) } : null,
    labels: [...labels.values()].sort((a, b) =>
      b.releases - a.releases || byText(a.display, b.display) || (a.discogsID ?? 0) - (b.discogsID ?? 0) ||
      byText(a.name, b.name)
    ),
    collaborators: [...collaborators.values()].sort(rankCollaborator).slice(0, MAX_COLLABORATORS).map((c) => ({
      artist: c.artist, how: oneSpellingEach([...c.how]), releases: [...c.releases].sort((a, b) => a - b),
    })),
    credits: keepPerKind([...credited.values()]
      .sort((a, b) => creditWeight(b) - creditWeight(a) || bestKind(a) - bestKind(b) ||
        byText(a.artist.name, b.artist.name) || (a.artist.discogsID ?? 0) - (b.artist.discogsID ?? 0)),
      bestKind)
      .map((c) => ({
        artist: c.artist,
        roles: mergeRoleSpellings(c.roles).map(([role, onRelease]) => ({
          role, kind: creditKind(role),
          releases: [...onRelease.entries()].sort(([a], [b]) => a - b)
            .map(([id, tracks]) => ({ id, tracks: [...tracks].sort(byText) })),
        })),
      })),
  };
}

/// The ranked list, keeping at most `MAX_CREDITED_PER_KIND` people whose best
/// job is each kind, in rank order.
function keepPerKind<T>(ranked: T[], kindOf: (entry: T) => number): T[] {
  const taken = new Map<number, number>();
  return ranked.filter((entry) => {
    const kind = kindOf(entry);
    const count = taken.get(kind) ?? 0;
    if (count >= MAX_CREDITED_PER_KIND) return false;
    taken.set(kind, count + 1);
    return true;
  });
}

/// Roles that differ only by case are one role, under its first spelling.
function oneSpellingEach(roles: string[]): string[] {
  const found = new Map<string, string>();
  for (const role of roles) {
    const key = role.toLowerCase();
    const held = found.get(key);
    if (held === undefined || role < held) found.set(key, role);
  }
  return [...found.values()].sort(byText);
}

function mergeRoleSpellings(roles: Map<string, Map<number, Set<string>>>): [string, Map<number, Set<string>>][] {
  const merged = new Map<string, { role: string; onRelease: Map<number, Set<string>> }>();
  for (const [role, onRelease] of roles) {
    const key = role.toLowerCase();
    const held = merged.get(key) ?? { role, onRelease: new Map() };
    if (role < held.role) held.role = role;
    for (const [id, tracks] of onRelease) {
      const where = held.onRelease.get(id) ?? new Set<string>();
      for (const t of tracks) where.add(t);
      held.onRelease.set(id, where);
    }
    merged.set(key, held);
  }
  return [...merged.values()].map(({ role, onRelease }) => [role, onRelease] as [string, Map<number, Set<string>>])
    .sort(([a], [b]) => byText(a, b));
}

// MARK: - Bytes and digest

/// JSON with keys sorted at every level and strings NFC-normalised: the same
/// bundle is the same bytes on every run.
export function canonicalJSON(value: unknown): string {
  if (value === null || typeof value !== "object") {
    return typeof value === "string" ? JSON.stringify(value.normalize("NFC")) : JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => [k.normalize("NFC"), v] as const)
    .sort(([a], [b]) => byText(a, b));
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJSON(v)}`).join(",")}}`;
}

export async function bundleDigest(bundle: Bundle): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalJSON(bundle));
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Where a bundle is kept: by its digest, so it is never overwritten.
export function bundleKey(digest: string): string {
  return `knowledge/v1/bundles/${digest.slice(0, 2)}/${digest}.json`;
}
