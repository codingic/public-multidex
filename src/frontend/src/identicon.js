// ── User avatar / ident icon ───────────────────────────────────────
// Turns a stable identity string — the signed-in user's IC principal — into a
// deterministic little SVG glyph via minidenticons
// (https://github.com/laurentpayot/minidenticons, MIT). Same principal ⇒ same
// icon, so the header chip and the Account card always match, and the glyph is
// tied to the cryptographic identity rather than the (regenerable) username.
import { minidenticon } from "minidenticons";

// The library defaults are 95% saturation / 45% lightness. We lift lightness a
// touch so the coloured squares stay vivid against the app's dark "glacier"
// surfaces (see --bg-hover in base.css), and ease saturation off neon.
const SATURATION = 82;
const LIGHTNESS  = 60;

// Both render sites re-ask for the same seed on every re-render; memoise the
// generated SVG so we hash + build the markup once per principal.
const _cache = new Map();

export function identiconSvg(seed = "") {
  let svg = _cache.get(seed);
  if (svg === undefined) {
    svg = minidenticon(seed, SATURATION, LIGHTNESS);
    _cache.set(seed, svg);
  }
  return svg;
}

// Fill `el` with the identicon for `seed`, tagging it `.has-identicon` so the
// CSS swaps the solid tile for the glyph. With no seed (e.g. mid-sign-in,
// before whoami() resolves the principal) it falls back to a plain initial so
// the tile is never blank. The glyph is decorative — the username beside it is
// the accessible label — so the injected <svg> is marked aria-hidden.
export function setIdenticon(el, seed, fallbackText = "?") {
  if (!el) return;
  if (seed) {
    el.innerHTML = identiconSvg(seed);
    el.classList.add("has-identicon");
    el.firstElementChild?.setAttribute("aria-hidden", "true");
  } else {
    el.textContent = fallbackText;
    el.classList.remove("has-identicon");
  }
}
