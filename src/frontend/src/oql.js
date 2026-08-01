// ── OQL display helpers ─────────────────────────────────────────────
// Shared by the Data Explorer (explorer.js) and the Assistant (in main.js):
// decode OQL cell values into plain JS, and format a cell as pre-escaped HTML.
// Pure (no app state) — depends on nothing but the values passed in.

function oqlCellVal(v) {
  if ("text" in v) return v.text;
  if ("nat" in v) return Number(v.nat);
  if ("int" in v) return Number(v.int);
  if ("float" in v) return v.float;
  if ("bool" in v) return v.bool;
  return null;
}
export function oqlRowsToObjects(res) {
  return (res.rows || []).map((row) => {
    const o = {};
    for (const c of row) o[c.name] = oqlCellVal(c.value);
    return o;
  });
}

// Format a cell for display. Timestamp columns (ts, *At, timestamp, time) carry
// nanoseconds-since-epoch — Time.now() is Int ns — so a raw cell looks like
// 1781722768147934000, not a date. Render those as a readable local datetime
// (keeping the exact ns in the tooltip); leave every other column untouched. The
// year-range guard means a value only reformats if, read as ns, it lands in
// 2000–2100, so non-timestamp numbers are never mangled.
const OQL_TS_COL = /^ts$|At$|^timestamp$|^time$/;
const OQL_PRINCIPAL = /^[a-z0-9]{5}(-[a-z0-9]{3,7}){2,}$/;   // IC principal text (e.g. tz2ag-…-cai)
// Format a cell for display, typed by the column's schema field (`fld`) when
// known. Returns pre-escaped HTML + an optional tooltip with the exact value.
export function oqlFormatCell(col, val, fld) {
  if (val === undefined || val === null || val === "") return { html: '<span class="dx-null">—</span>', title: "" };
  const t = fld && fld.typeName;
  if (t === "Bool" || typeof val === "boolean") {
    const b = val === true || val === "true";
    return { html: `<span class="dx-badge ${b ? "dx-badge-on" : "dx-badge-off"}">${b}</span>`, title: "" };
  }
  if (OQL_TS_COL.test(col) && typeof val === "number" && val > 0) {
    const d = new Date(val / 1e6), yr = d.getFullYear();   // ns → ms
    if (yr >= 2000 && yr <= 2100) return { html: dxEsc(d.toLocaleString()), title: val + " ns" };
  }
  if (typeof val === "number") {
    const isFloat = t === "Float" || !Number.isInteger(val);
    if (isFloat) {
      // Order-book formatting rule (format.js formatPrice/priceDecimals):
      // ≥1000 → 2 dp with separators; ≥1 → ≤5 significant digits; <1 → ≤6 dp;
      // trailing zeros stripped below the thousands tier. Also swallows
      // Fixed.toFloat artifacts like 1774.9999999999998 → "1,775.00".
      const a = Math.abs(val);
      let out;
      if (a >= 1000) out = val.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
      else if (a >= 1) out = String(Number(val.toFixed(5 - String(Math.floor(a)).length)));
      else out = String(Number(val.toFixed(6)));
      return { html: dxEsc(out), title: "" };
    }
    return { html: dxEsc(val.toLocaleString("en-US")), title: "" };
  }
  if (typeof val === "string" && val.length > 16 && OQL_PRINCIPAL.test(val)) {
    return { html: `<span class="dx-principal">${dxEsc(val.slice(0, 5) + "…" + val.slice(-5))}</span>`, title: val };
  }
  return { html: dxEsc(String(val)), title: "" };
}

// HTML-escape for safe interpolation into innerHTML (used throughout OQL rendering).
export function dxEsc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }

// Distill an agent/replica error down to the trap reason. The engine traps
// with self-describing messages ("OQL: unknown field 'foo'", "OQL: path '…'
// exceeds 4 hops") but the agent wraps them in a page of reject metadata
// (request id, reject code, canister id). Surface just the OQL line — or the
// reject text, or the plain message — so the status line reads like a
// diagnosis instead of a stack dump.
export function oqlErrorMessage(e) {
  const m = String((e && e.message) || e);
  const t = m.match(/(OQL:[^\n]+)/) || m.match(/trapped explicitly:\s*([^\n]+)/i) || m.match(/Reject text:\s*([^\n]+)/i);
  return (t ? t[1] : m).trim();
}
