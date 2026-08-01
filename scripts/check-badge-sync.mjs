#!/usr/bin/env node
// Badge definition sync gate — run by scripts/lint-ratchet.sh (check 5).
//
// The backend's badgeCatalog() (served by getBadgeCatalog, src/backend/main.mo)
// is the SOURCE OF TRUTH for badge metadata. Two other copies render before /
// without a canister call and must not drift:
//   • src/frontend/src/main.js   BADGE_META  — the Account→Status badge shelf
//   • src/frontend/src/docs.js   badge table — the user-facing docs page
//
// Everything is parsed out of SOURCE (no replica needed), so this catches:
//   - a badge added/renamed/re-iconed on one side only
//   - badgeName() and the catalog disagreeing
//   - a threshold constant changing while the prose ("$10k lifetime volume")
//     still says the old number — the bar is checked against the description
//     on the backend AND (via the equality check) the frontend
//
// Exit 0 prints a one-line summary; exit 1 prints one line per mismatch.
// If the source is refactored past these parsers, the script fails loudly
// with a "parser:" message — update the regexes alongside the refactor.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.argv[2] ?? ".";
const read = (p) => readFileSync(resolve(root, p), "utf8");
const errs = [];
const die = (msg) => { console.error(msg); process.exit(1); };

// ── Backend: Nat constants, badgeName() cases, badgeCatalog() entries ──
const mo = read("src/backend/main.mo");

const consts = new Map();
for (const m of mo.matchAll(/transient let ([A-Z_0-9]+)\s*:\s*Nat\s*=\s*([0-9_]+);/g)) {
  consts.set(m[1], Number(m[2].replaceAll("_", "")));
}

const nameFn = mo.match(/func badgeName\(id : Nat\) : Text \{([\s\S]*?)\n  \};/);
if (!nameFn) die("parser: badgeName() not found in main.mo");
const beNames = new Map();
for (const m of nameFn[1].matchAll(/case \((\d+)\) \{ "([^"]+)" \};/g)) {
  beNames.set(Number(m[1]), m[2]);
}
if (beNames.size === 0) die("parser: no badgeName() cases matched");

const catFn = mo.match(/func badgeCatalog\(\) : \[BadgeInfo\] \{([\s\S]*?)\n  \};/);
if (!catFn) die("parser: badgeCatalog() not found in main.mo");
const be = [];
const entryRe = /\{ id = (BADGE_[A-Z_]+);\s+name = badgeName\((BADGE_[A-Z_]+)\);\s+icon = "([^"]+)"; description = "([^"]+)";\s+criteria = (.+?) \},/g;
for (const m of catFn[1].matchAll(entryRe)) {
  const [, idSym, nameSym, icon, description, criteria] = m;
  if (idSym !== nameSym) errs.push(`catalog ${idSym}: name resolved via badgeName(${nameSym})`);
  const id = consts.get(idSym);
  if (id == null) { errs.push(`catalog ${idSym}: id constant not found`); continue; }
  be.push({ id, idSym, icon, description, criteria, name: beNames.get(id) });
}
if (be.length === 0) die("parser: no badgeCatalog() entries matched — update the regex with the refactor");

// Catalog ↔ badgeName(): same id set, every entry named.
for (const b of be) {
  if (!b.name) errs.push(`catalog id ${b.id} (${b.idSym}): no badgeName() case`);
}
for (const [id, name] of beNames) {
  if (!be.some((b) => b.id === id)) errs.push(`badgeName(${id}) "${name}" has no badgeCatalog() entry`);
}

// Thresholds quoted in prose must match the constants the criteria carry.
const fmtUsd = (e8) => {
  const usd = e8 / 1e8;
  return usd >= 1e6 ? `$${usd / 1e6}M` : usd >= 1e3 ? `$${usd / 1e3}k` : `$${usd}`;
};
for (const b of be) {
  const vol = b.criteria.match(/#lifetime(?:Maker)?VolumeUsd\((BADGE_[A-Z_]+)\)/);
  if (vol) {
    const bar = consts.get(vol[1]);
    if (bar == null) errs.push(`catalog id ${b.id}: threshold constant ${vol[1]} not found`);
    else if (!b.description.includes(fmtUsd(bar)))
      errs.push(`catalog id ${b.id} ("${b.name}"): description "${b.description}" doesn't mention the ${fmtUsd(bar)} bar (${vol[1]})`);
  }
  const up = b.criteria.match(/minUptimePct = ([A-Z_0-9]+)/);
  if (up) {
    const pct = consts.get(up[1]);
    if (pct == null) errs.push(`catalog id ${b.id}: uptime constant ${up[1]} not found`);
    else if (!b.description.includes(`${pct}%`))
      errs.push(`catalog id ${b.id} ("${b.name}"): description "${b.description}" doesn't mention the ${pct}% uptime gate (${up[1]})`);
  }
}

// ── Frontend shelf: BADGE_META must equal the catalog field-for-field ──
const js = read("src/frontend/src/main.js");
const metaSrc = js.match(/const BADGE_META = \[([\s\S]*?)\n\];/);
if (!metaSrc) die("parser: BADGE_META not found in main.js");
// Parsed textually, like the Motoko side — the lint gate must never EXECUTE
// repository code. One uniform `{ id: N, icon: "…", name: "…", how: "…" }`
// line per entry; a refactor past this shape fails the parser guard below.
const fe = [];
for (const m of metaSrc[1].matchAll(/\{ id: (\d+), icon: "([^"]+)", name: "([^"]+)", how: "([^"]+)" \},/g)) {
  fe.push({ id: Number(m[1]), icon: m[2], name: m[3], how: m[4] });
}
if (fe.length === 0) die("parser: no BADGE_META entries matched — update the regex with the refactor");

if (fe.length !== be.length) errs.push(`count: backend catalog has ${be.length} badges, frontend BADGE_META has ${fe.length}`);
const feById = new Map(fe.map((x) => [x.id, x]));
for (const b of be) {
  const f = feById.get(b.id);
  if (!f) { errs.push(`id ${b.id} ("${b.name}"): missing from frontend BADGE_META`); continue; }
  if (f.name !== b.name) errs.push(`id ${b.id}: FE name "${f.name}" ≠ BE name "${b.name}"`);
  if (f.icon !== b.icon) errs.push(`id ${b.id} ("${b.name}"): FE icon "${f.icon}" ≠ BE icon "${b.icon}"`);
  if (f.how !== b.description) errs.push(`id ${b.id} ("${b.name}"): FE how "${f.how}" ≠ BE description "${b.description}"`);
}

// ── Docs page: every badge row present with the catalog's id + name ──
const docs = read("src/frontend/src/docs.js");
for (const b of be) {
  const row = `<td class="docs-c">${b.id}</td><td class="docs-badge-name">${b.name}</td>`;
  if (!docs.includes(row)) errs.push(`id ${b.id} ("${b.name}"): no matching row on the docs page badge table (docs.js)`);
}

if (errs.length) {
  for (const e of errs) console.error("  • " + e);
  process.exit(1);
}
console.log(`${be.length} badges consistent across the backend catalog, frontend BADGE_META, and the docs page`);
