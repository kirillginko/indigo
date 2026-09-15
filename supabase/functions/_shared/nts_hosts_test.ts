// Who a programme credits, read off the title NTS publishes.
//
// NTS has no host field, so the only evidence is a naming convention. This is
// the test that keeps the parse conservative: every name it invents becomes a
// row in `artists` that search will offer somebody, and "In Focus" is not a
// person.
//
//     deno test supabase/functions/_shared/nts_hosts_test.ts

import { assertEquals } from "jsr:@std/assert@1";
import { hostNames } from "./nts.ts";

Deno.test("the common form credits the presenter", () => {
  assertEquals(hostNames("Pacing The Platform w/ upsammy"), ["upsammy"]);
  assertEquals(hostNames("Peking Spring w/ Jon K"), ["Jon K"]);
  assertEquals(hostNames("100 Elements w/ YL"), ["YL"]);
});

Deno.test("a programme with two presenters credits both", () => {
  assertEquals(hostNames("Scary Things w/ DJ Bempah & JK"), ["DJ Bempah", "JK"]);
  assertEquals(
    hostNames("Chicken Foot Soup w/ Goya Gumbani and Dom P"),
    ["Goya Gumbani", "Dom P"],
  );
});

Deno.test("the presents form credits the name in front of it", () => {
  assertEquals(hostNames("Ben Sims Presents: Run It Red"), ["Ben Sims"]);
});

Deno.test("a programme that names nobody credits nobody", () => {
  // The whole risk of this parse. These are programmes, and filing them as
  // artists would put four hundred imaginary people into search.
  assertEquals(hostNames("In Focus"), []);
  assertEquals(hostNames("The Early Bird Show"), []);
  assertEquals(hostNames("Post-Geography"), []);
  assertEquals(hostNames(null), []);
  assertEquals(hostNames(""), []);
});

Deno.test("a placeholder is not a presenter", () => {
  // Shares `adopt_radio_artists`' refusal to turn "Unknown" into somebody.
  assertEquals(hostNames("Some Show w/ Unknown"), []);
  assertEquals(hostNames("Some Show w/ Various Artists"), []);
});

Deno.test("the last credit wins", () => {
  // Splitting on the first " w/ " would credit "Imogen w/ guests" as one name.
  assertEquals(hostNames("Wigs w/ Imogen w/ Mica"), ["Mica"]);
});

Deno.test("the same name twice is one credit", () => {
  assertEquals(hostNames("Double w/ Flo & Flo"), ["Flo"]);
});
