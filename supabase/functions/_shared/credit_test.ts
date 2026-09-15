// The splitter has to agree with `ArtistName.split` in the app, because both
// answer "who is on this record" and a disagreement invents a person.
//
// The cases below are the app's own, taken from `CreditParityTests`. Anything
// changed here has to change there.
//
//     deno test supabase/functions/_shared/credit_test.ts

import { assertEquals } from "jsr:@std/assert@1";
import { creditedNames } from "./credit.ts";

Deno.test("a credit naming one artist stays whole", () => {
  assertEquals(creditedNames("Skee Mask"), ["Skee Mask"]);
  assertEquals(creditedNames("Jean-Michel Jarre"), ["Jean-Michel Jarre"]);
});

Deno.test("a comma names several people", () => {
  assertEquals(creditedNames("DJ Krush, Abijah"), ["DJ Krush", "Abijah"]);
  assertEquals(
    creditedNames("Chuck Strangers, Billy Woods, Zeroh"),
    ["Chuck Strangers", "Billy Woods", "Zeroh"],
  );
});

Deno.test("an ampersand does not", () => {
  // The guard the app is explicit about: Holden & Zimpel is a duo and Coco
  // Steel & Lovebomb is a group. Splitting those invents four people.
  assertEquals(creditedNames("Holden & Zimpel"), ["Holden & Zimpel"]);
  assertEquals(creditedNames("Coco Steel & Lovebomb"), ["Coco Steel & Lovebomb"]);
  assertEquals(creditedNames("Alexander Johansson & Mattias Fridell"),
               ["Alexander Johansson & Mattias Fridell"]);
});

Deno.test("nor does the word and", () => {
  assertEquals(creditedNames("Goya Gumbani and Dom P"), ["Goya Gumbani and Dom P"]);
});

Deno.test("the featuring forms name several", () => {
  assertEquals(creditedNames("Mount Kimbie feat. King Krule"), ["Mount Kimbie", "King Krule"]);
  assertEquals(creditedNames("Burial ft. Four Tet"), ["Burial", "Four Tet"]);
  assertEquals(creditedNames("Jah Balla X MikeyNYC X Ibu DaDon"),
               ["Jah Balla", "MikeyNYC", "Ibu DaDon"]);
});

Deno.test("an unspaced hyphen belongs to the name", () => {
  assertEquals(creditedNames("Jean-Michel Jarre"), ["Jean-Michel Jarre"]);
  // Spaced, it is a separator.
  assertEquals(creditedNames("Andrew Cyrille - Anthony Braxton"),
               ["Andrew Cyrille", "Anthony Braxton"]);
});

Deno.test("a placeholder is nobody", () => {
  assertEquals(creditedNames("Various"), []);
  assertEquals(creditedNames("Unknown Artist"), []);
  assertEquals(creditedNames(""), []);
  assertEquals(creditedNames(null), []);
  // But matched whole, never as a prefix.
  assertEquals(creditedNames("Unknown Mortal Orchestra"), ["Unknown Mortal Orchestra"]);
  assertEquals(creditedNames("Various Production"), ["Various Production"]);
});

Deno.test("a placeholder among real names is dropped, the rest kept", () => {
  assertEquals(creditedNames("Skee Mask, Unknown"), ["Skee Mask"]);
});

Deno.test("one name twice is one name", () => {
  assertEquals(creditedNames("Burial, Burial"), ["Burial"]);
});
