// Name normalization, kept in step with RecordingKey.normalize in the app.
//
// Both sides have to agree character for character: the app queries
// `normalized_name` with its own normalizer, so any divergence turns into a
// lookup that silently finds nothing rather than an error. The Swift side is
// pinned to this one by NormalizationParityTests.
//
// Swift does `folding(.diacriticInsensitive, .caseInsensitive, .widthInsensitive)`
// and then maps every scalar outside Foundation's alphanumerics to a space,
// collapsing runs. Reproduced here as: fold full-width forms, decompose
// canonically and drop the combining marks, lowercase, and keep only Unicode
// letters and numbers.

// Canonical (NFD), never compatibility (NFKD). NFKD looks like a shortcut to
// width folding but also rewrites things Swift leaves alone: it turns "½" into
// "1/2", where Swift keeps it as a single alphanumeric scalar.
function foldWidth(value: string): string {
  return [...value]
    .map((character) => {
      const code = character.codePointAt(0)!;
      // Full-width ASCII variants sit 0xFEE0 above their plain forms.
      if (code >= 0xff01 && code <= 0xff5e) return String.fromCodePoint(code - 0xfee0);
      // Ideographic space.
      if (code === 0x3000) return " ";
      return character;
    })
    .join("");
}

export function normalizeName(value: string): string {
  const folded = [...foldWidth(value).normalize("NFD")]
    .filter((character) => !/\p{M}/u.test(character))
    .join("")
    .toLowerCase();

  // Iterated by code point, as Swift iterates unicodeScalars — splitting by
  // UTF-16 unit would cut surrogate pairs in half.
  return [...folded]
    .map((character) => (/[\p{L}\p{N}]/u.test(character) ? character : " "))
    .join("")
    .split(/\s+/)
    .filter((part) => part.length > 0)
    .join(" ");
}
