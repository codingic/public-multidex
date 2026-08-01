// ── Formatting & display utilities ─────────────────────────────────
// Pure helpers (arguments + DOM only — no app state) shared across the UI.
// Extracted from main.js so number/price/time formatting lives in one place.

// Format a quantity for display in the order book / trades list.
// Caps at 5 decimal places and strips trailing zeros (and the trailing
// decimal point if the fractional part rounds to nothing). Examples:
//   0.01250       → "0.0125"
//   1.00000       → "1"
//   0.123456789   → "0.12346"
//   1234.5        → "1234.5"
export function formatQty(n) {
  if (n === 0 || n === undefined || n === null) return "0";
  return Number(n.toFixed(5)).toString();
}

// Decimal places for a PRICE column (Order Book / Trades), targeting a minimum
// of 5 significant digits: decimals = 5 − (integer digits). So single-dollar
// prices show 4 dp (2.6945), tens show 3 dp (82.808), hundreds 2 dp, thousands
// 1 dp (1234.5), and tens-of-thousands+ show 0 dp (73862). We size to the
// SMALLEST-magnitude price in the set so every row keeps ≥5 digits and the
// whole column shares one decimal count (stays aligned). Integer-digit count
// uses string length of the floor (avoids Math.log10 float edge cases at
// powers of ten).
export function priceDecimals(values) {
  let minIntDigits = Infinity;
  for (const v of values) {
    const a = Math.abs(v);
    if (a === 0) continue;
    const intDigits = a >= 1 ? String(Math.floor(a)).length : 1;
    if (intDigits < minIntDigits) minIntDigits = intDigits;
  }
  if (!isFinite(minIntDigits)) return 2; // no non-zero values
  return Math.max(0, 5 - minIntDigits);
}

// Compute the number of decimal places needed for a set of values to be uniform
export function uniformDecimals(values) {
  if (!values.length) return 2;
  // Use the max significant decimal places across all values, capped at 8
  let maxDp = 0;
  for (const v of values) {
    if (v === 0) continue;
    // Determine meaningful decimals: if >= 1000 use 2, >= 1 use 2, else up to 6
    if (v >= 1000) maxDp = Math.max(maxDp, 2);
    else if (v >= 1) maxDp = Math.max(maxDp, 2);
    else if (v >= 0.001) maxDp = Math.max(maxDp, 4);
    else maxDp = Math.max(maxDp, 8);
  }
  return maxDp;
}

export function formatNum(n) {
  if (n === 0 || n === undefined || n === null) return "0.00";
  if (Math.abs(n) >= 1000) return n.toLocaleString("en-US", { maximumFractionDigits: 2 });
  if (Math.abs(n) >= 1)    return n.toFixed(2);
  if (Math.abs(n) >= 0.001) return n.toFixed(4);
  return n.toFixed(8);
}

export function formatPrice(p) {
  if (p === 0) return "—";
  // Keep a consistent decimal count per tier (trailing zeros preserved):
  // without minimumFractionDigits, toLocaleString renders 2745.70 as "2,745.7".
  if (p >= 1000) return p.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  if (p >= 1)    return p.toFixed(2);
  return p.toFixed(6);
}

export function formatTime(timestamp) {
  const ms = typeof timestamp === "bigint" ? Number(timestamp / 1000000n) : Number(timestamp) / 1000000;
  const ago = Date.now() - ms;
  if (ago < 10000) {
    const secs = Math.floor(ago / 1000);
    return secs <= 2 ? "now" : `${secs}s`;
  }
  return new Date(ms).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false });
}

// Restart-and-play a green/red text-colour flash on a price element. Removing
// the class + forcing a reflow lets the same animation re-fire on every tick.
export function flashPriceEl(el, dir) {
  if (!el || !dir) return;
  el.classList.remove("ms-flash-up", "ms-flash-down");
  void el.offsetWidth; // reflow — restarts the CSS animation
  el.classList.add(dir > 0 ? "ms-flash-up" : "ms-flash-down");
}
