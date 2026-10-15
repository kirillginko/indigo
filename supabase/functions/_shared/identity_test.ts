// Linking an artist's two catalogue rows through MusicBrainz's own record.
//
//     deno test supabase/functions/_shared/identity_test.ts

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import anika from "./testdata/identity/anika.json" with { type: "json" };
import hypeWilliams from "./testdata/identity/hype-williams.json" with { type: "json" };
import { discogsArtistIDs, IdentityDeps, linkDiscogsIdentity } from "./identity.ts";

const ANIKA_ROW = "22904f8c-b792-413a-a70e-a2e73e7d5f30";
const HYPE_ROW = "5dbab0e3-b85a-42e9-8c35-64529418a062";

function deps(body: unknown, status = 200) {
  const links: [string, number][] = [];
  const held = new Map<number, string>([[777, "someone-else"]]);
  const d: IdentityDeps = {
    fetchArtist: () => Promise.resolve({ status, body }),
    link: (entity, id) => {
      links.push([entity, id]);
      const owner = held.get(id);
      if (owner && owner !== entity) return Promise.resolve("taken");
      if (owner) return Promise.resolve("exists");
      held.set(id, entity);
      return Promise.resolve("linked");
    },
  };
  return { d, links };
}

Deno.test("MusicBrainz's own Discogs pages are read from the real entries", () => {
  assertEquals(discogsArtistIDs(anika), [1982320, 3999072]);
  assertEquals(discogsArtistIDs(hypeWilliams), [1874027]);
});

Deno.test("only artist pages count, in any URL form Discogs uses", () => {
  const entry = { relations: [
    { url: { resource: "https://www.discogs.com/artist/12-Name" } },
    { url: { resource: "http://discogs.com/fr/artist/34" } },
    { url: { resource: "https://www.discogs.com/label/56" } },
    { url: { resource: "https://www.discogs.com/release/78" } },
    { url: { resource: "https://example.com/artist/90" } },
  ] };
  assertEquals(discogsArtistIDs(entry), [12, 34]);
  assertEquals(discogsArtistIDs({}), []);
});

Deno.test("every page MusicBrainz names is linked, with where it came from", async () => {
  const { d, links } = deps(anika);
  const result = await linkDiscogsIdentity(d, { artistID: ANIKA_ROW, mbid: "15c0e62b-3e46-4666-845d-d6c86bd44774" });
  assertEquals(result.status, "linked");
  assertEquals(links, [[ANIKA_ROW, 1982320], [ANIKA_ROW, 3999072]]);
  // Again: already there, nothing new.
  const again = await linkDiscogsIdentity(d, { artistID: ANIKA_ROW, mbid: "15c0e62b-3e46-4666-845d-d6c86bd44774" });
  assertEquals(again.status === "linked" && again.links.map((l) => l.status), ["exists", "exists"]);
});

Deno.test("a page another row already claims is reported, not taken over", async () => {
  const { d } = deps({ relations: [{ url: { resource: "https://www.discogs.com/artist/777" } }] });
  const result = await linkDiscogsIdentity(d, { artistID: HYPE_ROW, mbid: "fdd6ea04-81fa-45a2-96d8-c29ba08bfbde" });
  assertEquals(result.status === "linked" && result.links[0].status, "taken");
});

Deno.test("no Discogs page, an unknown MBID, a bad MBID and a row outside the pilot", async () => {
  assertEquals((await linkDiscogsIdentity(deps({ relations: [] }).d, { artistID: HYPE_ROW, mbid: "fdd6ea04-81fa-45a2-96d8-c29ba08bfbde" })).status, "none");
  assertEquals((await linkDiscogsIdentity(deps({}, 404).d, { artistID: HYPE_ROW, mbid: "fdd6ea04-81fa-45a2-96d8-c29ba08bfbde" })).status, "unknown-mbid");
  await assertRejects(() => linkDiscogsIdentity(deps({}, 503).d, { artistID: HYPE_ROW, mbid: "fdd6ea04-81fa-45a2-96d8-c29ba08bfbde" }));
  await assertRejects(() => linkDiscogsIdentity(deps({}).d, { artistID: HYPE_ROW, mbid: "not-an-mbid" }));
  await assertRejects(() => linkDiscogsIdentity(deps({}).d, { artistID: "00000000-0000-0000-0000-000000000000", mbid: "fdd6ea04-81fa-45a2-96d8-c29ba08bfbde" }));
});
