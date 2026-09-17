// What a page of Lot Radio broadcasts writes, and what it leaves alone.
//
// The fresh pass reads the same thirty-two broadcasts every hour. These pin
// the promises that make that safe: a programme is one row however many of its
// broadcasts arrive, a guest is filed under themselves, a broadcast already
// held is not written again, and an empty tracklist never erases a real one.
//
//     deno test supabase/functions/_shared/lotradio_ingest_test.ts

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { assertEquals } from "jsr:@std/assert@1";
import { ingestLotItems } from "./lotradio.ts";

type Row = Record<string, any>;

/// Just enough of PostgREST, over in-memory tables, for the calls ingest makes.
function fakeDatabase() {
  const tables: Record<string, Row[]> = {
    radio_shows: [],
    radio_episodes: [],
    radio_appearances: [],
  };
  const writes: Array<{ table: string; kind: string }> = [];
  const rpcs: Array<{ name: string; args: Row }> = [];
  let nextID = 1;

  class Query {
    filters: Array<(row: Row) => boolean> = [];
    kind = "select";
    values: Row[] = [];
    patch: Row = {};
    conflict: string[] = [];
    head = false;

    constructor(readonly table: string) {}

    select(_columns?: string, options?: { head?: boolean }) {
      if (this.kind === "select") this.head = options?.head ?? false;
      return this;
    }
    eq(column: string, value: unknown) {
      this.filters.push((row) => row[column] === value);
      return this;
    }
    in(column: string, values: unknown[]) {
      this.filters.push((row) => values.includes(row[column]));
      return this;
    }
    not(column: string, _operator: string, list: string) {
      const kept = list.slice(1, -1).split(",").map(Number);
      this.filters.push((row) => !kept.includes(row[column]));
      return this;
    }
    insert(row: Row) {
      this.kind = "insert";
      this.values = [row];
      return this;
    }
    update(patch: Row) {
      this.kind = "update";
      this.patch = patch;
      return this;
    }
    upsert(rows: Row | Row[], options: { onConflict: string }) {
      this.kind = "upsert";
      this.values = Array.isArray(rows) ? rows : [rows];
      this.conflict = options.onConflict.split(",");
      return this;
    }
    delete() {
      this.kind = "delete";
      return this;
    }

    run(): { data: Row[]; count: number } {
      const table = tables[this.table];
      const matches = (row: Row) => this.filters.every((filter) => filter(row));
      if (this.kind !== "select") writes.push({ table: this.table, kind: this.kind });

      if (this.kind === "insert") {
        const row = { id: `id-${nextID++}`, ...this.values[0] };
        table.push(row);
        return { data: [row], count: 1 };
      }
      if (this.kind === "update") {
        const hit = table.filter(matches);
        hit.forEach((row) => Object.assign(row, this.patch));
        return { data: hit, count: hit.length };
      }
      if (this.kind === "upsert") {
        const written = this.values.map((value) => {
          const found = table.find((row) => this.conflict.every((column) => row[column] === value[column]));
          if (found) return Object.assign(found, value);
          const row = { id: `id-${nextID++}`, ...value };
          table.push(row);
          return row;
        });
        return { data: written, count: written.length };
      }
      if (this.kind === "delete") {
        const gone = table.filter(matches);
        tables[this.table] = table.filter((row) => !matches(row));
        return { data: gone, count: gone.length };
      }
      const hit = table.filter(matches);
      return { data: hit, count: hit.length };
    }

    maybeSingle() {
      const { data } = this.run();
      return Promise.resolve({ data: data[0] ?? null, error: null });
    }
    single() {
      const { data } = this.run();
      return Promise.resolve(
        data[0] ? { data: data[0], error: null } : { data: null, error: { message: "no rows" } },
      );
    }
    then(resolve: (value: unknown) => void) {
      const { data, count } = this.run();
      resolve({ data: this.head ? null : data, count, error: null });
    }
  }

  const client = {
    from: (table: string) => new Query(table),
    rpc: (name: string, args: Row) => {
      rpcs.push({ name, args });
      return Promise.resolve({ data: null, error: null });
    },
  };

  return { client: client as unknown as SupabaseClient, tables, writes, rpcs };
}

function broadcast(slug: string, overrides: Row = {}): Row {
  return {
    title: "Yushh",
    slug,
    date: "2026-09-14T21:00:00.000Z",
    startTimestamp: "2026-09-14T21:00:00.000Z",
    endTimestamp: "2026-09-14T23:00:00.000Z",
    transcodedFile: { hls: `https://link.storjshare.io/raw/x/${slug}/index.m3u8` },
    tracklist: [
      { title: "Equilibrium", artist: "Struktur", timestamp: "2026-09-14T21:08:18.000Z" },
      { title: "Fergo", artist: "Marino2", timestamp: "2026-09-14T21:18:01.000Z" },
    ],
    location: { name: "The Lot Radio, NYC" },
    genres: { items: [{ name: "Techno" }] },
    artists: { items: [{ name: "Yushh", slug: "yushh" }] },
    show: { name: "Special Guests", slug: "special-guests", genres: { items: [] }, artists: { items: [] } },
    ...overrides,
  };
}

Deno.test("two visits by one guest are one programme with two broadcasts", async () => {
  const db = fakeDatabase();
  const result = await ingestLotItems(db.client, [
    broadcast("2026-09-14-1700"),
    broadcast("2026-08-01-1400"),
  ]);

  assertEquals(result, { offered: 2, written: 2, held: 0, unreadable: 0 });
  assertEquals(db.tables.radio_shows.length, 1);
  const show = db.tables.radio_shows[0];
  assertEquals([show.provider, show.external_id, show.title, show.station, show.host_name],
    ["lotradio", "guests/yushh", "Yushh", "The Lot Radio", "Yushh"]);

  assertEquals(db.tables.radio_episodes.map((episode) => episode.external_id),
    ["special-guests/2026-09-14-1700", "special-guests/2026-08-01-1400"]);
  assertEquals(db.tables.radio_episodes.every((episode) => episode.radio_show_id === show.id), true);
  assertEquals(db.tables.radio_episodes[0].location, "New York");
  assertEquals(db.tables.radio_episodes[0].tracklist_status, "available");

  assertEquals(db.tables.radio_appearances.length, 4);
  assertEquals(db.tables.radio_appearances[0].normalized_artist_name, "struktur");
  assertEquals(db.tables.radio_appearances[0].offset_seconds, 498);

  // The presenter is adopted once for the page, not once per broadcast.
  assertEquals(db.rpcs.filter((call) => call.name === "adopt_named_artist").map((call) => call.args.p_key), ["yushh"]);
  assertEquals(db.rpcs.filter((call) => call.name === "resolve_radio_appearances").length, 2);
});

Deno.test("reading the same page again writes nothing", async () => {
  const db = fakeDatabase();
  const page = [broadcast("2026-09-14-1700"), broadcast("2026-09-14-1500", { tracklist: [] })];
  await ingestLotItems(db.client, page);
  db.writes.length = 0;
  db.rpcs.length = 0;

  const again = await ingestLotItems(db.client, page);

  assertEquals(again, { offered: 2, written: 0, held: 2, unreadable: 0 });
  assertEquals(db.writes, []);
  assertEquals(db.rpcs, []);
});

Deno.test("a tracklist that has grown since is read again", async () => {
  const db = fakeDatabase();
  await ingestLotItems(db.client, [broadcast("2026-09-14-1700", { tracklist: [] })]);
  assertEquals(db.tables.radio_episodes[0].tracklist_status, "unavailable");

  const later = await ingestLotItems(db.client, [broadcast("2026-09-14-1700")]);

  assertEquals(later.written, 1);
  assertEquals(db.tables.radio_episodes.length, 1);
  assertEquals(db.tables.radio_episodes[0].tracklist_status, "available");
  assertEquals(db.tables.radio_appearances.length, 2);
});

Deno.test("an empty tracklist never erases one already held", async () => {
  const db = fakeDatabase();
  await ingestLotItems(db.client, [broadcast("2026-09-14-1700")]);

  const result = await ingestLotItems(db.client, [broadcast("2026-09-14-1700", { tracklist: [] })]);

  assertEquals(result.held, 1);
  assertEquals(db.tables.radio_episodes[0].tracklist_status, "available");
  assertEquals(db.tables.radio_appearances.length, 2);
});

Deno.test("a programme is updated only when what it says has changed", async () => {
  const db = fakeDatabase();
  const residency = (slug: string, hosts: Row[]) =>
    broadcast(slug, {
      artists: { items: hosts },
      show: { name: "Magic City", slug: "magic-city", photo: { url: "https://img/magic.jpg" }, artists: { items: hosts } },
    });

  await ingestLotItems(db.client, [residency("2026-09-01-1800", [{ name: "Ron", slug: "ron" }])]);
  db.writes.length = 0;

  await ingestLotItems(db.client, [residency("2026-09-08-1800", [{ name: "Ron", slug: "ron" }])]);
  assertEquals(db.writes.filter((write) => write.table === "radio_shows"), []);

  await ingestLotItems(db.client, [
    residency("2026-09-15-1800", [{ name: "Ron", slug: "ron" }, { name: "Kay", slug: "kay" }]),
  ]);
  assertEquals(db.writes.filter((write) => write.table === "radio_shows"), [{ table: "radio_shows", kind: "update" }]);
  assertEquals(db.tables.radio_shows.length, 1);
  assertEquals(db.tables.radio_shows[0].host_name, "Ron & Kay");
  assertEquals(db.tables.radio_shows[0].image_url, "https://img/magic.jpg");
});

Deno.test("an item that is not a broadcast is counted, not written", async () => {
  const db = fakeDatabase();
  const result = await ingestLotItems(db.client, [broadcast("2026-09-14-1700", { show: null })]);
  assertEquals(result, { offered: 1, written: 0, held: 0, unreadable: 1 });
  assertEquals(db.writes, []);
});
