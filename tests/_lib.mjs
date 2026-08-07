// tests/_lib.mjs — shared helpers for the plain-node frontend suites
// (frontend_security.test.mjs, frontend_display_integrity.test.mjs).
//
// Same doctrine as _lib.sh: no dependencies, no build step, importable by any
// suite that needs it. Kept out of the `*.test.mjs` glob that run_all.sh
// discovers by the leading underscore — this file asserts nothing itself.

// ── Comment stripping ───────────────────────────────────────────────
// Every assertion in these suites is about CODE. The frontend files are
// heavily commented, and the comments necessarily quote the very patterns
// being banned ("this used to be `onerror=…`", "a bare 1000 is $0.00001"), so
// scanning raw text would make a suite fail on its own documentation — and,
// worse, would let someone silence a real failure by rewording a comment.
// Strip first, then match.
//
// String- and regex-aware: `//` inside "https://…" is not a comment, and a
// regex literal may contain a slash. Regex-vs-divide is resolved by the usual
// "previous significant token" heuristic, which is sufficient for these files.
export function stripJsComments(src) {
  let out = "";
  let i = 0;
  let prev = "";                       // last significant char emitted
  const REGEX_OK = "(,=:[!&|?{};+-*%~^<>\n";
  while (i < src.length) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "/" && d === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && d === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const quote = c;
      out += c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
        out += src[i];
        if (src[i] === quote) { i++; break; }
        i++;
      }
      prev = quote;
      continue;
    }
    if (c === "/" && REGEX_OK.includes(prev)) {           // regex literal
      out += c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
        if (src[i] === "[") { while (i < src.length && src[i] !== "]") { out += src[i]; i++; } }
        out += src[i];
        if (src[i] === "/") { i++; break; }
        i++;
      }
      prev = "/";
      continue;
    }
    out += c;
    if (!/\s/.test(c)) prev = c;
    i++;
  }
  return out;
}
