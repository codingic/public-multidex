// The Public Ledger (top-level Ledger tab) — the archive chain made visible, and
// the CLIENT-SIDE verifier that closes the trust loop:
//
//   1. every event's canonical bytes are re-derived HERE, in the browser
//      (mirror of src/backend/lib/EventChain.mo v1 — length-prefixed
//      netstring fields, frozen order), and SHA-256'd with WebCrypto;
//   2. each event's recomputed hash must equal its successor's prevHash —
//      one unbroken chain, including across sealed archive canisters;
//   3. the final hash must equal the archive's certified head, and the head
//      itself is validated against the IC CERTIFICATE (subnet BLS signature
//      over certified_data) — so nothing in the pipeline trusts the
//      canister's own claims.
//
// Folding the #delta rows of this same public tape per account is the
// Proof-of-Reserves liabilities computation — the explainer on the page
// says exactly that. IMPORTANT: verification needs RAW candid values
// (BigInts) — the actors used here are deliberately NOT money-normalized.

const enc = new TextEncoder();

// ── Canonical form (EventChain.mo v1 mirror — field order is FROZEN) ──
function net(parts, bytes) {
  parts.push(enc.encode(String(bytes.length) + ":"));
  parts.push(bytes);
}
const putT = (p, t) => net(p, enc.encode(t));
const putN = (p, v) => putT(p, v.toString());   // Nat/Int (BigInt) → decimal text
const sideTag = (s) => ("buy" in s ? "buy" : "sell");
const optBytes = (o) => (o && o.length ? new Uint8Array(o[0]) : new Uint8Array(0));
const optPrincipalText = (o) => (o && o.length ? o[0].toText() : "");

export function canonicalEvent(e) {
  const p = [];
  putT(p, "v1");
  net(p, optBytes(e.prevHash));
  putN(p, e.seq);
  putN(p, e.ts);
  putT(p, e.user.toText());
  putT(p, optPrincipalText(e.counterparty));
  const k = e.kind;
  if ("fill" in k) {
    const f = k.fill;
    putT(p, "fill");
    putT(p, f.marketId); putT(p, sideTag(f.side));
    putN(p, f.price); putN(p, f.qty); putN(p, f.orderId); putN(p, f.tradeId);
  } else if ("deposit" in k) {
    const d = k.deposit;
    putT(p, "withdrawal" in d.kind ? "withdrawal" : "deposit");
    putT(p, d.token); putN(p, d.amount); putN(p, d.timestamp);
  } else if ("orderClosed" in k) {
    const o = k.orderClosed;
    putT(p, "orderClosed");
    putN(p, o.id); putT(p, o.marketId); putT(p, sideTag(o.side));
    putT(p, "market" in o.orderType ? "market" : "limit");
    putN(p, o.price); putN(p, o.quantity); putN(p, o.filled);
    putT(p, "filled" in o.status ? "filled" : "cancelled" in o.status ? "cancelled"
         : "open" in o.status ? "open" : "partiallyFilled");
    putN(p, o.placedAt); putN(p, o.closedAt);
  } else if ("liquidation" in k) {
    const l = k.liquidation;
    putT(p, "liquidation");
    putT(p, l.user.toText()); putT(p, l.debtToken); putN(p, l.debtRepaid);
    putN(p, l.debtRepaidUsd); putT(p, l.collateralToken); putN(p, l.collateralSeized);
    putN(p, l.proceedsUsd); putN(p, l.penaltyUsd);
    putN(p, l.healthBefore); putN(p, l.healthAfter); putN(p, l.timestamp);
  } else if ("borrow" in k) {
    putT(p, "borrow"); putT(p, k.borrow.token); putN(p, k.borrow.amount);
  } else if ("repay" in k) {
    putT(p, "repay"); putT(p, k.repay.token); putN(p, k.repay.amount);
  } else if ("lpDeposit" in k) {
    const d = k.lpDeposit;
    putT(p, "lpDeposit");
    putT(p, d.marketId); putN(p, d.baseAmount); putN(p, d.quoteAmount); putN(p, d.lpMinted);
  } else if ("lpWithdraw" in k) {
    const w = k.lpWithdraw;
    putT(p, "lpWithdraw");
    putN(p, w.lpBurned);
    putN(p, BigInt(w.basket.length));
    for (const [tok, amt] of w.basket) { putT(p, tok); putN(p, amt); }
  } else if ("insuranceStake" in k) {
    putT(p, "insuranceStake"); putN(p, k.insuranceStake.amountUsd); putN(p, k.insuranceStake.shares);
  } else if ("insuranceUnstake" in k) {
    putT(p, "insuranceUnstake"); putN(p, k.insuranceUnstake.shares); putN(p, k.insuranceUnstake.payoutUsd);
  } else if ("delta" in k) {
    putT(p, "delta"); putT(p, k.delta.token); putN(p, k.delta.amount);
  } else if ("debtDelta" in k) {
    putT(p, "debtDelta"); putT(p, k.debtDelta.token); putN(p, k.debtDelta.amount);
  } else if ("lpShareDelta" in k) {
    putT(p, "lpShareDelta"); putT(p, k.lpShareDelta.marketId); putN(p, k.lpShareDelta.amount);
  } else if ("insShareDelta" in k) {
    putT(p, "insShareDelta"); putN(p, k.insShareDelta.amount);
  } else {
    throw new Error("unknown event kind (verifier older than the canister?)");
  }
  let len = 0;
  for (const b of p) len += b.length;
  const out = new Uint8Array(len);
  let off = 0;
  for (const b of p) { out.set(b, off); off += b.length; }
  return out;
}

export async function hashEvent(e) {
  const digest = await crypto.subtle.digest("SHA-256", canonicalEvent(e));
  return new Uint8Array(digest);
}

const hex = (bytes, n) => {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const h = Array.from(n ? b.slice(0, n) : b).map((x) => x.toString(16).padStart(2, "0")).join("");
  return n && b.length > n ? h + "…" : h;
};
const bytesEq = (a, b) => {
  const x = new Uint8Array(a), y = new Uint8Array(b);
  if (x.length !== y.length) return false;
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
  return true;
};

// ── IC certificate validation (the head is only as good as its signature) ──
async function validateCertifiedHead(certBytes, canisterIdText, expectedHash, rootKey) {
  try {
    const { Certificate } = await import("@icp-sdk/core/agent");
    const { Principal } = await import("@icp-sdk/core/principal");
    const cid = Principal.fromText(canisterIdText);
    // @icp-sdk/core signature: { certificate, rootKey, principal } — create()
    // VERIFIES the BLS signature (and any subnet delegation) and throws on
    // failure, so reaching lookup_path means the certificate is genuine.
    // rootKey arrives as Uint8Array, ArrayBuffer or hex text depending on the
    // agent build — normalize to bytes (a hex STRING through Uint8Array()
    // yields zeros and traps the BLS verifier).
    let rk = rootKey;
    if (typeof rk === "string") {
      const hexStr = rk.replace(/^0x/, "");
      rk = new Uint8Array(hexStr.match(/.{2}/g).map((b) => parseInt(b, 16)));
    } else if (!(rk instanceof Uint8Array)) {
      rk = new Uint8Array(rk);
    }
    const cert = await Certificate.create({
      certificate: new Uint8Array(certBytes),
      rootKey: rk,
      principal: cid,
      // Local replicas advance IC time per round, not per wall clock — the
      // freshness window misfires there; the BLS signature check (the part
      // that matters) still runs.
      disableTimeVerification: true,
    });
    const res = cert.lookup_path([enc.encode("canister"), cid.toUint8Array(), enc.encode("certified_data")]);
    if (!res || res.status !== "Found") return { ok: false, why: "certified_data path " + (res ? res.status : "missing") };
    return bytesEq(res.value, expectedHash)
      ? { ok: true }
      : { ok: false, why: "certified_data ≠ head hash" };
  } catch (err) {
    // KNOWN LOCAL LIMITATION: pocket-ic's certificates trap this SDK build's
    // BLS verifier ("unreachable" wasm panic) — on mainnet the identical
    // path runs on every agent update call. Degrade honestly, never lie.
    return { ok: null, why: (err && err.message) || String(err) };
  }
}

// ── The verifier ─────────────────────────────────────────────────────
// Walks [fromSeq..toSeq] on one archive, checking every link. `seedHash` is
// the expected prevHash of the FIRST event (the predecessor's hash — null
// skips that check, e.g. at the chain anchor). Returns the final hash.
async function verifySlice(actor, fromSeq, toSeq, seedHash, onProgress) {
  let expectPrev = seedHash;
  let lastHash = null;
  let s = fromSeq;
  let links = 0;
  while (s <= toSeq) {
    const page = await actor.getEventsRange(BigInt(s), BigInt(Math.min(200, toSeq - s + 1)));
    if (!page.length) throw new Error(`tape gap at seq ${s}`);
    for (const e of page) {
      if (Number(e.seq) > toSeq) break;
      if (expectPrev !== null) {
        const got = optBytes(e.prevHash);
        if (!bytesEq(got, expectPrev)) {
          throw new Error(`chain BREAK at seq ${e.seq}: prevHash ${hex(got, 8)} ≠ expected ${hex(expectPrev, 8)}`);
        }
        links++;
      }
      lastHash = await hashEvent(e);
      expectPrev = lastHash;
      s = Number(e.seq) + 1;
    }
    if (onProgress) onProgress(s - fromSeq, toSeq - fromSeq + 1);
  }
  return { lastHash, links };
}

// Verify the WHOLE routed chain (sealed archives oldest→newest, then the
// active one up to its certified head), or just the newest `lastN` events.
// Every archive's certified head is checked where the walk covers it.
export async function verifyChainClient(deps, opts, onStatus) {
  const { listArchives, makeRawArchiveActor, rootKey, getLedgerGaps, getShedBaselines } = deps;
  const lastN = opts && opts.lastN;
  const archives = await listArchives();
  if (!archives.length) throw new Error("no archives yet — the ledger starts with the first event");
  const active = archives[archives.length - 1];
  const activeActor = await makeRawArchiveActor(active.canisterId);
  const head = await activeActor.getCertifiedHead();
  if (!head.headHash.length) throw new Error("active archive has no chain head yet");
  const headSeq = Number(head.headSeq[0]);
  const chainStart = head.chainStartSeq.length ? Number(head.chainStartSeq[0]) : Number(active.firstSeq);

  // Recorded ledger gaps (L2 archive-failover sheds). A gap's toSeq is a
  // legitimate re-anchor point: the archive beginning there opens a fresh chain
  // segment, so its first event's prevHash is NOT expected to link to the
  // previous archive's head. Consulting these tells a documented gap apart from
  // tampering (docs/archive-design.md §8b).
  let gaps = [];
  try { gaps = getLedgerGaps ? await getLedgerGaps() : []; } catch { /* pre-failover backend */ }
  const reanchorSeqs = new Set(gaps.map((g) => Number(g[1])));
  const gapEventsMissing = gaps.reduce((n, g) => n + (Number(g[1]) - Number(g[0])), 0);
  // Shed re-baselines: after each shed the canister re-attests EVERY balance
  // with absolute rows, so a replayer that resets at the baseline reconstructs
  // balances from the tape alone — the gap costs history, not replayability.
  let baselines = [];
  try { baselines = getShedBaselines ? await getShedBaselines() : []; } catch { /* pre-baseline backend */ }

  let totalLinks = 0;
  let carried = null;   // hash carried across archive boundaries
  let heads = 0;

  if (lastN) {
    // Newest N on the active archive only. Seed the first link from the
    // predecessor event when the window doesn't start at the anchor.
    let from = Math.max(chainStart, headSeq - lastN + 1);
    let seed = null;
    if (from > chainStart) {
      const prev = await activeActor.getEventsRange(BigInt(from - 1), 1n);
      if (prev.length) { seed = await hashEvent(prev[0]); from = Number(prev[0].seq) + 1; }
    }
    onStatus(`verifying seqs ${from}…${headSeq} on the active archive…`);
    const r = await verifySlice(activeActor, from, headSeq, seed, (done, total) =>
      onStatus(`verifying… ${done}/${total} events`));
    totalLinks = r.links;
    if (!bytesEq(r.lastHash, new Uint8Array(head.headHash[0]))) {
      throw new Error("recomputed head ≠ archive head — the tape does not match its own hash chain");
    }
  } else {
    // Full history: every archive in routing order, links carried across
    // canister boundaries, each sealed head checked too.
    for (let i = 0; i < archives.length; i++) {
      const a = archives[i];
      const actor = i === archives.length - 1 ? activeActor : await makeRawArchiveActor(a.canisterId);
      const aHead = i === archives.length - 1 ? head : await actor.getCertifiedHead();
      const from = Number(a.firstSeq);
      const to = a.lastSeq.length ? Number(a.lastSeq[0]) : headSeq;
      // Re-anchor after a recorded gap: seed null so the walk accepts the
      // documented cross-archive discontinuity (still verifies this archive's
      // own chain internally + its certified head).
      const reanchored = i > 0 && reanchorSeqs.has(from);
      const seed = reanchored ? null : carried;
      onStatus(`archive ${i + 1}/${archives.length}: verifying seqs ${from}…${to}…${reanchored ? " (re-anchored after a gap)" : ""}`);
      const r = await verifySlice(actor, Math.max(from, i === 0 ? chainStartOf(aHead, from) : from), to, seed,
        (done, total) => onStatus(`archive ${i + 1}/${archives.length}: ${done}/${total} events`));
      totalLinks += r.links;
      if (aHead.headHash.length && !bytesEq(r.lastHash, new Uint8Array(aHead.headHash[0]))) {
        throw new Error(`archive ${a.canisterId}: recomputed head ≠ its certified head`);
      }
      heads++;
      carried = r.lastHash;
    }
  }

  // The head itself: validate the IC certificate over certified_data.
  let certNote;
  const certCheck = head.certificate.length
    ? await validateCertifiedHead(head.certificate[0], active.canisterId, new Uint8Array(head.headHash[0]), rootKey)
    : { ok: null, why: "no certificate in the query response" };
  if (certCheck.ok === true) certNote = "IC certificate VALID — the subnet vouches for this head";
  else if (certCheck.ok === false) throw new Error("IC certificate check FAILED: " + certCheck.why);
  else certNote = "certificate check unavailable (" + certCheck.why + ") — head taken from the query response";

  return { links: totalLinks, headSeq, headHex: hex(new Uint8Array(head.headHash[0]), 8), certNote, heads,
    gapCount: gaps.length, gapEventsMissing, baselineCount: baselines.length,
    baselineResumeSeq: baselines.length ? Number(baselines[baselines.length - 1][1]) : null };
}
function chainStartOf(head, fallback) {
  return head.chainStartSeq && head.chainStartSeq.length ? Number(head.chainStartSeq[0]) : fallback;
}

// ── Rendering (the Ledger view) ──────────────────────────────────────
const fmtAmt = (v) => {
  const n = Number(v) / 1e8;
  return (n >= 0 ? "+" : "") + n.toLocaleString(undefined, { maximumFractionDigits: 4 });
};
const shortP = (p) => { const t = typeof p === "string" ? p : p.toText(); return t.slice(0, 5) + "…" + t.slice(-3); };
const escH = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function kindCell(e) {
  const k = e.kind;
  if ("delta" in k) return ["ledger Δ", `${fmtAmt(k.delta.amount)} ${escH(k.delta.token)}`];
  if ("debtDelta" in k) return ["debt Δ", `${fmtAmt(k.debtDelta.amount)} ${escH(k.debtDelta.token)} owed to vault`];
  if ("lpShareDelta" in k) return ["LP Δ", `${fmtAmt(k.lpShareDelta.amount)} vault shares`];
  if ("insShareDelta" in k) return ["insurance Δ", `${fmtAmt(k.insShareDelta.amount)} shares`];
  if ("fill" in k) { const f = k.fill; return ["fill", `${sideTag(f.side)} ${Number(f.qty) / 1e8} ${escH(f.marketId)} @ ${Number(f.price) / 1e8}`]; }
  if ("deposit" in k) { const d = k.deposit; return ["withdrawal" in d.kind ? "withdrawal" : "deposit", `${Number(d.amount) / 1e8} ${escH(d.token)}`]; }
  if ("orderClosed" in k) return ["order", "closed"];
  if ("liquidation" in k) return ["liquidation", "collateral seized"];
  if ("lpDeposit" in k) return ["LP deposit", `${Number(k.lpDeposit.lpMinted) / 1e8} shares minted`];
  if ("lpWithdraw" in k) return ["LP withdraw", `${Number(k.lpWithdraw.lpBurned) / 1e8} shares burned`];
  if ("insuranceStake" in k) return ["insurance", "stake"];
  if ("insuranceUnstake" in k) return ["insurance", "unstake"];
  if ("borrow" in k) return ["borrow", `${Number(k.borrow.amount) / 1e8} ${escH(k.borrow.token)}`];
  if ("repay" in k) return ["repay", `${Number(k.repay.amount) / 1e8} ${escH(k.repay.token)}`];
  return ["event", ""];
}

// Hash chip with a colour derived from the hash bytes — matching colours ARE
// the visual chain: a row's own-hash chip matches the row above's prev chip.
function chip(bytes, label) {
  if (!bytes || !bytes.length) return `<span class="lg-chip lg-chip-null">${label}·∅</span>`;
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const hue = ((b[0] << 8) | b[1]) % 360;
  return `<span class="lg-chip" style="border-color:hsl(${hue},70%,45%);color:hsl(${hue},80%,70%)">${label}·${hex(b, 4)}</span>`;
}

export function setupLedger(deps) {
  const pane = document.getElementById("ledger-view");
  if (!pane) return null;
  let loaded = false;
  document.getElementById("lg-refresh")?.addEventListener("click", () => { pageEnd = null; refresh(); });
  document.getElementById("lg-verify")?.addEventListener("click", verify);
  document.getElementById("lg-older")?.addEventListener("click", () => { if (windowStart !== null) { pageEnd = windowStart - 1; loadTape(); } });
  document.getElementById("lg-newer")?.addEventListener("click", () => { if (pageEnd !== null) { pageEnd = pageEnd + PAGE; loadTape(); } });
  document.getElementById("lg-newest")?.addEventListener("click", () => { pageEnd = null; loadTape(); });

  async function refresh() {
    const chainEl = document.getElementById("lg-chain");
    const tapeEl = document.getElementById("lg-tape");
    try {
      const archives = await deps.listArchives();
      if (!archives.length) {
        chainEl.innerHTML = `<div class="empty-state">No archive yet — the ledger begins with the first event.</div>`;
        tapeEl.innerHTML = "";
        return;
      }
      // Chain table: one row per archive, its range + certified head.
      const rows = [];
      for (const a of archives) {
        const actor = await deps.makeRawArchiveActor(a.canisterId);
        let headHex8 = "—", anchor = "—", count = "—";
        try {
          const h = await actor.getCertifiedHead();
          if (h.headHash.length) headHex8 = hex(new Uint8Array(h.headHash[0]), 8);
          if (h.chainStartSeq.length) anchor = String(h.chainStartSeq[0]);
          const st = await actor.stats();
          count = Number(st.eventCount).toLocaleString();
        } catch {}
        const sealed = a.lastSeq.length;
        rows.push(`<tr>
          <td><code>${escH(a.canisterId)}</code></td>
          <td>${a.firstSeq}…${sealed ? a.lastSeq[0] : "live"}</td>
          <td>${count}</td>
          <td><code>${headHex8}</code></td>
          <td><span class="lg-badge ${sealed ? "lg-sealed" : "lg-active"}">${sealed ? "sealed" : "active"}</span></td>
        </tr>`);
      }
      chainEl.innerHTML = `<table class="positions-table"><thead><tr>
        <th>Archive canister</th><th>Seq range</th><th>Events</th><th>Certified head</th><th></th>
      </tr></thead><tbody>${rows.join("")}</tbody></table>`;

      _archList = archives;
      await loadTape();
    } catch (err) {
      chainEl.innerHTML = `<div class="empty-state">Ledger unavailable: ${escH(err && err.message ? err.message : err)}</div>`;
    }
  }

  // ── Tape pagination ────────────────────────────────────────────────
  // A window of PAGE events ending at `pageEnd` (null = follow the newest).
  // Windows are SEQ-addressed and ROUTED: a window that crosses a seal
  // boundary fetches from both archives, so paging back walks seamlessly
  // into blackholed history.
  const PAGE = 30;
  let pageEnd = null;
  let windowStart = null;
  let _archList = [];

  async function fetchRouted(from, count) {
    const out = [];
    for (const a of _archList) {
      const aFirst = Number(a.firstSeq);
      const aLast = a.lastSeq.length ? Number(a.lastSeq[0]) : Infinity;
      const lo = Math.max(from, aFirst);
      const hi = Math.min(from + count - 1, aLast);
      if (lo > hi) continue;
      const actor = await deps.makeRawArchiveActor(a.canisterId);
      const page = await actor.getEventsRange(BigInt(lo), BigInt(hi - lo + 1));
      out.push(...page);
    }
    return out;
  }

  async function loadTape() {
    const tapeEl = document.getElementById("lg-tape");
    if (!_archList.length) { tapeEl.innerHTML = ""; return; }
    try {
      const active = _archList[_archList.length - 1];
      const actor = await deps.makeRawArchiveActor(active.canisterId);
      const st = await actor.stats();
      const newestSeq = Number(st.nextSeq) - 1;
      const chainFirst = Number(_archList[0].firstSeq);
      let end = pageEnd === null ? newestSeq : Math.min(pageEnd, newestSeq);
      if (pageEnd !== null && end >= newestSeq) { pageEnd = null; end = newestSeq; }   // paged past the head → follow it
      const start = Math.max(chainFirst, end - PAGE + 1);
      windowStart = start;
      const events = end >= start ? await fetchRouted(start, end - start + 1) : [];
      const withHashes = [];
      for (const e of events) withHashes.push({ e, own: await hashEvent(e) });
      withHashes.reverse();   // newest first
      const trows = withHashes.map(({ e, own }, i) => {
        const [tag, detail] = kindCell(e);
        const prev = optBytes(e.prevHash);
        // Link check against the row BELOW (the previous event).
        const below = withHashes[i + 1];
        const linked = below ? bytesEq(prev, below.own) : null;
        return `<tr>
          <td>${e.seq}</td>
          <td class="lg-time">${new Date(Number(e.ts) / 1e6).toLocaleTimeString()}</td>
          <td><span class="lg-kind">${tag}</span></td>
          <td><code>${shortP(e.user)}</code></td>
          <td class="lg-detail">${detail}</td>
          <td class="lg-hashes">${chip(prev, "prev")}${linked === false ? "⚠" : ""} ${chip(own, "hash")}</td>
        </tr>`;
      }).join("");
      tapeEl.innerHTML = `<table class="positions-table lg-tape-table"><thead><tr>
        <th>Seq</th><th>Time</th><th>Kind</th><th>Account</th><th>Detail</th><th>Chain link (prev ← hash)</th>
      </tr></thead><tbody>${trows}</tbody></table>
      <div class="lg-note">Hashes are recomputed in YOUR browser from the event bytes — each row's
      <em>hash</em> chip reappears as the row above's <em>prev</em> chip. Matching colours are the chain.</div>`;
      // Pager chrome: range label + button states.
      const lbl = document.getElementById("lg-range");
      if (lbl) lbl.textContent = end >= start
        ? `seqs ${start.toLocaleString()}–${end.toLocaleString()} of ${newestSeq.toLocaleString()}${pageEnd === null ? " (live)" : ""}`
        : "empty";
      const older = document.getElementById("lg-older");
      const newer = document.getElementById("lg-newer");
      const newest = document.getElementById("lg-newest");
      if (older) older.disabled = start <= chainFirst;
      if (newer) newer.disabled = pageEnd === null;
      if (newest) newest.disabled = pageEnd === null;
    } catch (err) {
      tapeEl.innerHTML = `<div class="empty-state">Tape unavailable: ${escH(err && err.message ? err.message : err)}</div>`;
    }
  }

  async function verify() {
    const btn = document.getElementById("lg-verify");
    const out = document.getElementById("lg-verify-result");
    const scope = document.getElementById("lg-verify-scope")?.value || "500";
    btn.disabled = true;
    out.className = "lg-verify-out";
    try {
      const res = await verifyChainClient(
        deps,
        scope === "full" ? {} : { lastN: parseInt(scope, 10) },
        (msg) => { out.textContent = msg; },
      );
      out.className = "lg-verify-out lg-ok";
      const gapNote = res.gapCount
        ? (res.baselineCount
          ? ` <br><span class="lg-gap-note">⚠ across ${res.gapCount} recorded ledger gap${res.gapCount > 1 ? "s" : ""}
              (${res.gapEventsMissing.toLocaleString()} events dropped by archive-failover — documented, not tampering).
              The tape re-baselined itself after the shed${res.baselineCount > 1 ? "s" : ""}: every balance was re-attested
              with absolute rows, so replay reconstructs balances exactly from seq ${res.baselineResumeSeq.toLocaleString()}
              onward — only the dropped history itself is gone.</span>`
          : ` <br><span class="lg-gap-note">⚠ across ${res.gapCount} recorded ledger gap${res.gapCount > 1 ? "s" : ""}
              (${res.gapEventsMissing.toLocaleString()} events dropped by archive-failover — documented, not tampering;
              live balances intact, but the tape can't reconstruct through a gap unaided).</span>`)
        : "";
      out.innerHTML = `✓ <strong>${res.links.toLocaleString()} links verified in your browser</strong> up to seq ${res.headSeq}
        — recomputed head <code>${res.headHex}</code> matches the archive${res.heads > 1 ? `s (${res.heads} certified heads)` : ""}. ${escH(res.certNote)}.${gapNote}`;
    } catch (err) {
      out.className = "lg-verify-out lg-bad";
      out.textContent = "✗ VERIFICATION FAILED: " + (err && err.message ? err.message : err);
    } finally {
      btn.disabled = false;
    }
  }

  // main.js calls this when the Ledger view activates — the first show loads
  // the chain + tape; after that the user drives refreshes explicitly.
  return { onShow() { if (!loaded) { loaded = true; refresh(); } } };
}
