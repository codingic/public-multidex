#!/usr/bin/env node
// tests/frontend_display_integrity.test.mjs — guards for the frontend's
// display and cached-state integrity: the e8 money boundary, the units
// contract the assistant hands the model, and the two client caches whose
// cursors can silently desynchronise from the data they index.
//
// WHY THESE ARE WORTH A SUITE. None of the defects these pin lose funds, and
// not one of them throws. A figure 100,000,000x out still renders, still
// formats, still passes the `> 0` gate that decides whether to show it at all;
// a duplicated trade still paints; a chart with three pages missing from its
// middle still draws a continuous line. The failure mode is a confident wrong
// number in front of the person the page exists to inform — a staker reading
// pending yield, an operator reading uncovered bad debt, a model answering
// "how big is my position". Nothing but an explicit assertion catches that.
//
// Two kinds of check, mixed deliberately:
//   · BEHAVIOURAL — money.js is imported and exercised. It is pure, so its
//     contract (which field names scale, what a round trip preserves) can be
//     asserted directly rather than inferred from its source.
//   · STATIC — main.js/explorer.js/assistant.js only run in a browser against
//     a live replica, so their invariants are asserted against the SOURCE.
//     "This render site does not divide", "this poll cannot overlap itself",
//     "this preset's threshold is written in base units" are all properties of
//     the text, and a test that needed a signed-in browser to see them is a
//     test nobody runs.
//
// The assistant section reaches across into src/backend/main.mo on purpose:
// the prompt makes a claim ABOUT the backend's OQL projections, so the only
// way to know it is still true is to check the projections. If the backend
// changes which fields it pre-converts, this suite fails and names the prompt.
//
// Usage:
//   node tests/frontend_display_integrity.test.mjs           # the working tree
//   node tests/frontend_display_integrity.test.mjs <root>    # another checkout
//
// The second form is how the "fails before the fix" half of the contract is
// demonstrated: materialise an older tree (git worktree, or `git show`) and
// point this at it.

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join, dirname, resolve } from "node:path";
import { stripJsComments } from "./_lib.mjs";

const ROOT = process.argv[2]
  ? resolve(process.argv[2])
  : resolve(dirname(fileURLToPath(import.meta.url)), "..");

let passed = 0;
let failed = 0;

function ok(name) { passed++; console.log(`✓ ${name}`); }
function bad(name, detail) {
  failed++;
  console.log(`✗ ${name}`);
  if (detail) console.log(`    ${String(detail).split("\n").join("\n    ")}`);
}
function check(name, cond, detail) { cond ? ok(name) : bad(name, detail); }

const path = (p) => join(ROOT, p);
function read(p) {
  const f = path(p);
  if (!existsSync(f)) return null;
  return readFileSync(f, "utf8");
}
// A file that is supposed to exist but doesn't is a failure, not a crash —
// otherwise one moved file silently skips a whole section of this suite.
function must(p) {
  const s = read(p);
  if (s === null) bad(`${p} exists`, `not found under ${ROOT}`);
  return s;
}

// Brace-matched body of a function, from comment-stripped source. String
// bodies are skipped so a `{` inside a literal cannot unbalance the scan.
function funcBody(src, header) {
  const at = src.indexOf(header);
  if (at < 0) return null;
  let i = src.indexOf("{", at + header.length);
  if (i < 0) return null;
  const start = i;
  let depth = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'" || c === "`") {
      const q = c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === q) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return src.slice(start, i + 1); }
    i++;
  }
  return null;
}

// Lines that READ a money field, i.e. everything except the IDL declaration
// that gives it its Candid type.
function readSites(src, field) {
  return src.split("\n")
    .map((text, i) => ({ ln: i + 1, text: text.trim() }))
    .filter((l) => l.text.includes(field) && !l.text.includes("IDL."));
}
const DIVIDES_BY_E8 = /\/\s*(1e8|100_000_000|100000000)\b/;

console.log(`frontend display-integrity guards — ${ROOT}\n`);

// ════════════════════════════════════════════════════════════════════
// A. money.js — the e8 boundary (behavioural)
// ════════════════════════════════════════════════════════════════════
console.log("A. money.js — the e8 boundary");
let money = null;
try {
  money = await import(pathToFileURL(path("src/frontend/src/money.js")).href);
  ok("money.js imports");
} catch (e) {
  bad("money.js imports", e.message);
}

if (money) {
  const { E8, MONEY_KEYS, normMoney, fromE8, toE8 } = money;

  // A1 — getInsuranceFund's record is all-or-nothing. Its five fields are
  // rendered next to each other on four surfaces; one of them left off
  // MONEY_KEYS arrives as a raw bigint among four human Numbers.
  const INSURANCE_FUND_FIELDS = [
    "bufferUsd", "uncoveredBadDebtUsd", "totalShares", "shareValueUsd", "pendingYieldUsd",
  ];
  const missing = INSURANCE_FUND_FIELDS.filter((k) => !MONEY_KEYS.has(k));
  check("every getInsuranceFund money field is in MONEY_KEYS",
    missing.length === 0,
    `absent: ${missing.join(", ")} — normMoney leaves those as raw e8 bigints `
    + "while their siblings become dollars");

  // A2 — the same record, shaped as Candid decodes it, through the real
  // normaliser. This is the boundary the wrapped actor applies exactly once.
  const fund = normMoney({
    bufferUsd: 250_000n * BigInt(E8),
    uncoveredBadDebtUsd: 12_345n * BigInt(E8),
    totalShares: 250_000n * BigInt(E8),
    shareValueUsd: 1n * BigInt(E8),
    pendingYieldUsd: 1_234n * BigInt(E8),
  });
  const wrong = Object.entries(fund).filter(([, v]) => typeof v !== "number");
  check("normMoney converts the whole record to human Numbers",
    wrong.length === 0,
    wrong.map(([k, v]) => `${k} = ${v} (${typeof v})`).join("\n"));
  check("pendingYieldUsd normalises to dollars",
    fund.pendingYieldUsd === 1234,
    `got ${fund.pendingYieldUsd} — the render sites print this verbatim`);
  check("uncoveredBadDebtUsd normalises to dollars",
    fund.uncoveredBadDebtUsd === 12345, `got ${fund.uncoveredBadDebtUsd}`);

  // A3 — fromE8/toE8 are a round trip, not an approximation. `v * 1e8` in
  // floating point drifts a whole base unit past ~2^51: the old formula turned
  // 3355443200000019 into …020.
  const DRIFTED = 3355443200000019n;
  check("the round trip is exact at the first value the float multiply lost",
    toE8(fromE8(DRIFTED)) === DRIFTED,
    `toE8(fromE8(${DRIFTED})) = ${toE8(fromE8(DRIFTED))}`);

  let drift = null;
  for (let x = 3355443200000000n; x < 3355443200002000n && drift === null; x++) {
    if (toE8(fromE8(x)) !== x) drift = x;
  }
  check("the round trip is exact across that whole neighbourhood",
    drift === null,
    drift === null ? "" : `first drift at ${drift} -> ${toE8(fromE8(drift))}`);

  // Exactness holds everywhere a Number can still tell adjacent base units
  // apart, which is up to 2^52 base units (~45M tokens). Above that one ulp is
  // wider than one base unit, so no inverse exists and no implementation can
  // win — asserted in BOTH directions so the ceiling stays a known limit
  // rather than a surprise, and so nobody "extends" it by rounding harder.
  //
  // Full-entropy sampling matters here: `Math.random() * 4.5e15` only ever
  // yields doubles whose low bits are zero, which is exactly the population
  // that round-trips cleanest. This is xorshift64, seeded fixed — a flaky
  // money test is worse than none.
  let s = 0x9E3779B97F4A7C15n;
  const M64 = (1n << 64n) - 1n;
  const rnd = () => { s ^= (s << 13n) & M64; s ^= s >> 7n; s ^= (s << 17n) & M64; return s & M64; };
  const P52 = 4503599627370496n;

  let below = null;
  for (let i = 0; i < 200000 && below === null; i++) {
    const x = rnd() % P52;
    if (toE8(fromE8(x)) !== x) below = x;
  }
  check("the round trip is exact for every value below 2^52 base units",
    below === null,
    below === null ? "" : `drift at ${below} -> ${toE8(fromE8(below))}`);

  let above = null;
  for (let i = 0; i < 200000 && above === null; i++) {
    const x = P52 + (rnd() % P52);
    if (toE8(fromE8(x)) !== x) above = x;
  }
  check("above 2^52 the limit is acknowledged, not papered over",
    above !== null,
    "a round trip that looks exact past 2^52 means this sampler stopped "
    + "exercising the low bits, not that the arithmetic improved");

  // A4 — the ordinary path is untouched. Order entry, slippage and swap
  // amounts all pass through toE8; none of them may move.
  const ORDINARY = [0, 0.05, 0.25, 1, 1.5, 65000.5, 1234.56789012, 0.00000001, 0.15, 100000];
  const moved = ORDINARY.filter((v) => toE8(v) !== BigInt(Math.round(v * E8)));
  check("toE8 is unchanged for ordinary order-entry values",
    moved.length === 0,
    moved.map((v) => `${v}: ${toE8(v)} vs ${BigInt(Math.round(v * E8))}`).join("\n"));
  check("toE8 keeps its sign convention on negatives",
    toE8(-1.5) === -150000000n, `got ${toE8(-1.5)}`);
}

// ════════════════════════════════════════════════════════════════════
// B. main.js — normalised money is never divided again
// ════════════════════════════════════════════════════════════════════
console.log("\nB. main.js — no second divide on boundary-normalised money");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    // Both of these are in MONEY_KEYS, so every read site is dollars already.
    // A divide here is not a rounding difference, it is eight orders of
    // magnitude, and it renders green: the guard above each card tests the
    // undivided value, so the alert still fires and only the figure lies.
    for (const field of ["pendingYieldUsd", "uncoveredBadDebtUsd"]) {
      const sites = readSites(src, field);
      check(`${field} has render sites at all`, sites.length > 0,
        "field renamed? this section is then asserting nothing");
      const divided = sites.filter((l) => DIVIDES_BY_E8.test(l.text));
      check(`no ${field} render site divides by 1e8`,
        divided.length === 0,
        divided.map((l) => `main.js:${l.ln}  ${l.text}`).join("\n"));
    }

    // Whole-function guard on the Stats alert cards. Every figure that pane
    // prints comes from an endpoint the wrapped actor already normalised, so
    // NO 1e8 divide belongs anywhere in it — and this is the pane where the
    // insurance shortfall spent a while rendering as rounding dust beside its
    // own copy calling it the venue's most material risk number. (Cycle
    // figures divide by 1e12 and are unaffected.)
    const issues = funcBody(src, "async function renderStatsIssues(");
    check("renderStatsIssues is extractable", issues !== null);
    if (issues) {
      const divides = issues.split("\n").filter((l) => DIVIDES_BY_E8.test(l));
      check("no alert card divides an already-normalised figure by 1e8",
        divides.length === 0,
        divides.map((l) => l.trim()).join("\n"));
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// C. assistant.js — the units contract the model is handed
// ════════════════════════════════════════════════════════════════════
console.log("\nC. assistant.js — units contract vs the backend's projections");
{
  const rawAsst = must("src/frontend/src/assistant.js");
  const asst = rawAsst === null ? null : stripJsComments(rawAsst);
  const mo = must("src/backend/main.mo");

  // What the backend actually does. A payload projection is HUMAN units if it
  // converts inline or delegates to a helper that does; anything else reaches
  // the model as the raw e8 integer.
  const CONVERTERS = ["Fixed.toFloat", "oqlLastPrice", "oqlRefPrice",
    "oqlEvAmount", "oqlEvPrice", "oqlEvQty"];

  // The delegating helpers are whitelisted above by name, so each one's own
  // body has to be checked or the whitelist rots into a false negative.
  if (mo) {
    for (const fn of CONVERTERS.filter((c) => c.startsWith("oql"))) {
      const at = mo.indexOf(`func ${fn}(`);
      const body = at < 0 ? null : mo.slice(at, at + 900).split(/\n  (?:func|transient|public|\/\/) /)[0];
      check(`${fn} converts to human units`,
        body !== null && /Fixed\.toFloat|100_000_000\.0/.test(body),
        at < 0 ? "helper not found in main.mo" : "no conversion in its body");
    }
  }

  function entityBlock(src, name) {
    const parts = src.split("OQL.Entity.manual<");
    const hit = parts.find((p) => new RegExp(`^[^\\n]*>\\(\\s*\\n?\\s*"${name}"`).test(p));
    return hit || null;
  }
  function projectionUnits(src, entity, field) {
    const block = entityBlock(src, entity);
    if (!block) return "no-entity";
    const m = new RegExp(`\\.payload\\(\\s*"${field}"\\s*,([^\\n]*)`).exec(block);
    if (!m) return "no-field";
    return CONVERTERS.some((c) => m[1].includes(c)) ? "human" : "e8";
  }

  // Every money field the model can see, and the unit it actually arrives in.
  // `position` is the one entity that mixes both — its size is converted and
  // its entryPrice is not — which is precisely why a blanket rule misleads.
  const UNIT_CONTRACT = [
    ["position", "size", "human"],
    ["position", "entryPrice", "e8"],
    ["position", "realizedPnl", "e8"],
    ["market", "lastPrice", "human"],
    ["market", "refPrice", "human"],
    ["order", "price", "e8"],
    ["order", "quantity", "e8"],
    ["order", "filled", "e8"],
    ["closedOrder", "price", "e8"],
    ["closedOrder", "quantity", "e8"],
    ["balance", "amount", "e8"],
    ["leaderboard", "profitUsd", "e8"],
    ["userEvent", "amount", "human"],
    ["userEvent", "price", "human"],
    ["userEvent", "qty", "human"],
  ];
  if (mo) {
    const mismatched = UNIT_CONTRACT
      .map(([e, f, want]) => [e, f, want, projectionUnits(mo, e, f)])
      .filter(([, , want, got]) => want !== got);
    check("the backend still projects each OQL money field in the documented unit",
      mismatched.length === 0,
      mismatched.map(([e, f, want, got]) => `${e}.${f}: prompt says ${want}, main.mo projects ${got}`)
        .join("\n") + "\n→ the UNITS section of assistantSystemPrompt must be updated to match");
  }

  if (asst) {
    const prompt = funcBody(asst, "function assistantSystemPrompt(") || "";
    check("the system prompt is extractable", prompt.length > 0);

    // The rule is right for most fields and must survive; asserting it as
    // UNIVERSAL is what makes a compliant model wrong on the pre-converted
    // ones — and `position` is the flagship self-scoped entity, so "show my
    // positions" is where it lands first.
    check("the prompt does not state the e8 rule as universal",
      !/ALWAYS divide by 100,000,000/.test(prompt),
      "one OQL field per entity may be pre-converted; an ALWAYS rule cannot be true");
    check("the prompt still teaches the e8 default",
      /divide by 100,000,000/.test(prompt));
    check("the prompt marks the pre-converted fields as exceptions",
      /EXCEPTIONS/.test(prompt),
      "the exception has to be findable by a model skimming the UNITS block");

    const exceptions = prompt.split("\n").filter((l) => l.includes("EXCEPTIONS")).join(" ");
    for (const [entity, field, unit] of UNIT_CONTRACT) {
      if (unit !== "human") continue;
      check(`the prompt names ${entity}.${field} as already-human`,
        exceptions.includes(field) && exceptions.includes(entity),
        `the model is told to divide it; it is projected through ${CONVERTERS[0]} or a helper`);
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// D. explorer.js — the numeric-filter example teaches the right unit
// ════════════════════════════════════════════════════════════════════
console.log("\nD. explorer.js — preset filter units");
{
  const rawExp = must("src/frontend/src/explorer.js");
  const src = rawExp === null ? null : stripJsComments(rawExp);
  if (src) {
    // `order.price` is projected raw and the results table prints it raw, so a
    // bare human literal is a threshold 1e8 too low: it matches every resting
    // bid, and the preset reads as a working filter while doing nothing. This
    // is the explorer's only numeric-filter example, so it is also where
    // anyone writing one by hand learns the convention.
    const bare = [...src.matchAll(/\{\s*(?:gt|ge|lt|le)\s*:\s*\{\s*field\s*:\s*"(price|quantity|filled|amount)"\s*,\s*value\s*:\s*([0-9.]+)\s*\}/g)];
    check("no preset filters a raw-e8 field with a bare human-unit literal",
      bare.length === 0,
      bare.map((m) => `${m[1]} compared against ${m[2]} — that is $${Number(m[2]) / 1e8}`).join("\n"));

    check("the price-threshold preset is written in base units",
      /field\s*:\s*"price"\s*,\s*value\s*:\s*\d+\s*\*\s*E8/.test(src),
      "expected `value: 1000 * E8` so the unit is legible in the source");
    check("explorer.js takes the scale from the money boundary",
      /import\s*\{[^}]*\bE8\b[^}]*\}\s*from\s*["']\.\/money\.js["']/.test(src),
      "a locally-retyped 100000000 is one edit away from disagreeing with money.js");
    check("the preset's label states the threshold as money",
      /label:\s*"Buy orders above \$[\d,]+/.test(src),
      "the raw box shows 100000000000; only the label connects that to $1,000");
  }
}

// ════════════════════════════════════════════════════════════════════
// E. main.js — cursors that index a shared cache
// ════════════════════════════════════════════════════════════════════
console.log("\nE. main.js — poll + chart cursor integrity");
{
  const rawMain = read("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    // E1 — pollChanges reads every cursor from the shared cache BEFORE its
    // await, so two calls in flight at once send identical cursors and both
    // get the same deltas back. A 2s interval plus the pollMarketStatus() fired
    // after each order placement makes that ordinary, not exotic.
    const poll = funcBody(src, "async function pollChanges()");
    check("pollChanges is extractable", poll !== null);
    if (poll) {
      check("an in-flight flag is declared at module scope",
        /let\s+_pollInFlight\s*=\s*false/.test(src));
      check("pollChanges returns early while one is already in flight",
        /if\s*\([^)]*_pollInFlight[^)]*\)\s*return/.test(poll),
        "the file already does this for checkReleaseRejections (_rejCheckInFlight)");
      const setAt = poll.indexOf("_pollInFlight = true");
      const awaitAt = poll.indexOf("await");
      check("the flag is set before the first await",
        setAt >= 0 && awaitAt >= 0 && setAt < awaitAt,
        "a flag set after the await guards nothing");
      check("the flag is cleared in a finally",
        /finally\s*\{[^}]*_pollInFlight\s*=\s*false/.test(poll),
        "a thrown query would wedge the poll off permanently");

      // E2 — the market-trade cache has no key of its own, and
      // refreshTradesIncremental appends to it from a second cursor, so the
      // same trade can arrive twice. A duplicate prints the fill twice and
      // colours the copy as a zero tick until 100 trades push it out.
      const merge = poll.slice(poll.indexOf("resp.newTrades.length > 0"),
        poll.indexOf("renderTrades("));
      check("the market-trade merge is not a bare concatenation",
        !/\[\s*\.\.\.existing\s*,\s*\.\.\.resp\.newTrades\s*\]/.test(merge),
        "identical newTrades from two polls would both be appended");
      check("the market-trade merge dedups by trade id",
        /\bid\b/.test(merge) && /has\(|some\(|Set\(/.test(merge),
        "the user-trade merge below it already does this by String(t.id)");
    }

    // E3 — refreshChartData refetches page 0 and replaces the series, so the
    // paging cursor has to go back with it. Left at 3, the next scroll-left
    // fetches page 4 and prepends it onto page 0: a history missing pages 1-3,
    // drawn as continuous, that never repairs itself.
    const refresh = funcBody(src, "async function refreshChartData()");
    check("refreshChartData is extractable", refresh !== null);
    if (refresh) {
      check("refreshChartData resets the page cursor with the series",
        /chartCurrentPage\s*=\s*0/.test(refresh),
        "changeChartInterval resets it after the same page-0 refetch");
      check("refreshChartData refreshes hasMore from the response",
        /chartHasMore\s*=\s*resp\.hasMore/.test(refresh),
        "a stale hasMore either blocks paging or pages past the end");
      check("refreshChartData yields to a page load already in flight",
        /if\s*\(\s*chartLoadingMore\s*\)\s*return/.test(refresh),
        "otherwise the older page it is fetching lands on top of a fresh page 0");
    }

    const interval = funcBody(src, "async function changeChartInterval(");
    check("changeChartInterval still resets the cursor too",
      interval !== null && /chartCurrentPage\s*=\s*0/.test(interval),
      "both page-0 refetch paths have to reset, not one");
  }
}

// ── Summary ─────────────────────────────────────────────────────────
console.log("");
if (failed === 0) {
  console.log(`PASS — ${passed} assertions`);
  process.exit(0);
} else {
  console.log(`FAIL — ${failed} of ${passed + failed} assertions failed`);
  process.exit(1);
}
