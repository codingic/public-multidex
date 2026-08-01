# Swap limit orders — closing the cross-market gap

*2026-07-08. Status: PROPOSED — recommendation: ship the direct-pair UX slice now (~1 day, see Plan of record); build the cross-market engine when demand shows. Companion to [limit-order-positions-design.md](limit-order-positions-design.md) (the deferred/resting machinery this leans on). Builds on the in-flight `walkFillable`/`quoteSwap` work (uncommitted at time of writing).*

## Where limit swaps stand today

- **Direct pairs (X↔ICPUSD): done, end to end.** `executeSwapDirect`'s `#limitOrder` arm validates (`LiquidityManager.validateNewOrder`), stages sealed via `parkDeferred(…, #limit, …)`, releases on the next GEPTOR, and the remainder **rests on the book as a normal maker order** — in `getMyOrders`, badged staged via `getMyStagedOrderIds`, cancellable, 30-day GTC TTL, per-user cap. Nothing to build.
- **Cross pairs (neither side ICPUSD): an explicit dead end.** `executeSwapCross` returns `#err("Cross-market limit orders not yet supported…")`. The Swap box **defaults to a cross pair**, so the first Limit anyone tries fails — this is why "limit swaps don't work".
- **Market-mode cross machinery that already exists** (`DeferredSwap` / `processDeferredSwaps` / `releaseCrossSwap`): stage with `addReserved` soft-lock → release when BOTH legs' markets are fresh (15 s users-only fallback) → size leg 1 to leg 2's absorb capacity (`crossableDepth`, AMM-mid-anchored cap) → sell leg then buy leg in ONE message → `recordSwapOutcome` (never silent).
- **In flight now**: `walkFillable` (budgeted funded-depth walker: `#base`/`#quote`/`#all` budgets, returns `{base; quote}`) and the read-only `quoteSwap` query that runs it fee-aware, leg-by-leg. These are the exact primitives the cross-limit trigger needs — land them first.

## The semantic: a cross limit is a rate predicate over two books

A cross price (ETH per BTC) doesn't pin either ICPUSD leg — it's a *ratio* of two leg prices. The user's real ask is: **"convert my `amount` of FROM only if I net at least `minToAmount` of TO (fees included)."**

API: one additive variant on `SwapMode` (candid-safe on an argument type — old clients unaffected):

```motoko
public type SwapMode = {
  #marketOrder : { maxSlippage : Nat };
  #limitOrder  : { limitPrice : Nat };      // direct routes only (unchanged, pre-fee CLOB price)
  #minReceive  : { minToAmount : Nat };     // NEW — cross routes: net-of-fees floor on TO received
};
```

Why `minToAmount` (absolute TO units) and not a rate field: an e8 fixed-point *rate* between two base tokens can be brutally coarse (DOGE→BTC ≈ 1e-6 → 100 e8-units → 1% steps). An absolute floor is exact, and the partial-fill predicate stays exact integer cross-multiplication: fill a chunk `A` iff `toChunk × amount ≥ A × minToAmount`. The frontend converts the user's rate input (`1 FROM ≥ R TO`) to `minToAmount = amount × R`.

Honest asymmetry, documented rather than papered over: a **CLOB limit is a price promise, pre-fee** (direct pairs, maker-side, can earn maker rates); a **cross limit is a net-receive promise** that executes as a *taker on both legs* when triggered. It rests in our store, not on any book — it is a conditional taker, not maker liquidity.

## Design: a resting rate-conditional two-leg intent

### Store — new, not an extension

```motoko
type RestingSwap = {
  id : Nat;              // OrderBook.allocateId — shared id space, swapOrderId stays meaningful
  owner : Principal;
  sellMarket : Types.MarketId;  sellToken : Types.TokenId;
  buyMarket  : Types.MarketId;  buyToken  : Types.TokenId;
  amountRemaining : Nat;        // FROM units still unconverted
  minToRemaining  : Nat;        // TO floor still owed (pro-rata reduction on partial fills
                                // preserves the user's rate; round the floor UP — never
                                // against the user)
  noPartialFill : Bool;
  ts : Int;  expiresAt : Int;   // ts + USER_ORDER_TTL_NS (30 d, GTC parity)
};
let restingSwaps = Map.empty<Nat, RestingSwap>();   // new top-level stable map
```

Deliberately **not** a field on `DeferredSwap`: adding fields to a record inside a stable map traps upgrades (reinstall territory), and `deferredSwaps`' 15-second forced-release invariants (users-only fallback at expiry) are exactly what a GTC intent must NOT inherit. A new top-level stable map initializes empty on upgrade — safe.

### Placement (`executeSwapCross`, `#minReceive` arm)

Existing `swap()` gates already run (auth, balance, 10-ICPUSD min-notional with dust exemption, initial-margin). Then: `getAvailable ≥ amount` → `addReserved(owner, sellToken, amount)` → insert → `#ok { swapOrderId = ?id }`. Caps: `MAX_RESTING_SWAPS_PER_USER = 10`, global sanity cap ~2 000 (reject at placement, same spirit as the bounded resting book).

**Enumeration-site audit** (the part that bites if skipped): every place that enumerates `deferredSwaps` must mirror `restingSwaps` — the soft-lock accounting sweep (main.mo ~910–926), the per-user cancel/refund path (~5 448), `resetExchange`, and the conservation folds in the integration suite.

### Trigger — evaluated after every GEPTOR pass, both-fresh only, indexed

Evaluation hooks exactly where `processDeferredSwaps` already runs (the finaliser, after the release pass has settled books and the AMM has requoted — book state is final for this pass). A limit intent has no deadline pressure, so it **never uses the users-only stall fallback**: it releases only when BOTH legs' pools are fresh (AMM takeable, quotes current).

**Per-pass cost must not scale with the resting population.** A linear sweep — even with a cheap per-intent pre-filter — is O(n) every ~2 s forever. Instead, index intents the way a stop-order book indexes triggers:

- `swapTriggerIdx : pairKey → ordered map keyed by (thresholdRate, id)` — threshold = `floor(minToRemaining × SCALE / amountRemaining)`, rounded DOWN so quantization can only over-examine, never miss (the money predicate below stays exact integer cross-multiplication; the e8-rate coarseness that ruled a rate API out doesn't matter in a prune).
- `pairsByMarket : MarketId → Set<pairKey>` — which pair groups a market's requote can affect.
- Both **transient**, rebuilt from `restingSwaps` on first touch after upgrade (O(n) once).

Per pass: each market the GEPTOR touched marks its pair groups dirty (O(1) per market). For each dirty pair with both legs fresh, compute the **top-of-book gross ratio** `ρ_top = bestBid(sellMarket) / bestAsk(buyMarket)` — an upper bound on the blended rate ANY size can achieve, and gross ≥ net, so the prune needs no fee modeling. If the group's lowest threshold exceeds `ρ_top`, the whole group skips in O(1) — the common case. Top-of-book, not AMM mid, is the correct prune: rich bids above a lagging oracle move `ρ_top` instantly, so depth-only changes can't slip past it, and books only change at GEPTOR passes (sealed model), so dirty-marking catches every change. An empty side ⇒ nothing can trigger ⇒ skip.

Only intents with threshold ≤ `ρ_top` — plausibly triggerable — pay for the exact check:

1. **Exact check — dual walk** (this is where `walkFillable` pays off): leg 1 `walkFillable(sellMarket, …, #sell, capSell, #base(remaining))` → gross ICPUSD; subtract `quoteFeeFor(owner, gross, #takerDebit)`; leg 2 walk with `#quote` budget sized with the `10_000/(10_000+takerBps)` fee headroom (same arithmetic as `quoteSwap` / `releaseCrossSwap`) → `toAmt`. Per-leg caps = the protective band the market release path uses — **limits do not bypass `bandCappedSlippage`**; if the ratio is only achievable through stranded-book pathology, the intent keeps resting.
2. **Predicate — partial fills are the default.** Once an order *rests with a price*, gradual filling is the semantic every limit-order user expects; fill the largest `A` (halving probe, ≤ ~6 iterations, floor chunk `MIN_ORDER_ICPUSD` — gradual fill without dust-drip) with `toAmt(A) × amountRemaining ≥ A × minToRemaining` — blended semantics: every release nets at least the user's rate; pro-rata floor reduction preserves the threshold, so re-indexing is a same-key re-insert. `noPartialFill = true` is honored as **opt-in all-or-nothing** (`sellQty == remaining ∧ toAmt ≥ minToRemaining`, one walk, no probe — the checkbox already exists on the form); the form warns when `quoteSwap` reports `exhausted` for an AON size, since an intent bigger than one pass's walkable depth (AMM ladder + user book within protective bands) can only fire when depth grows. *Deliberated 2026-07-08*: AON-only v1 was considered for simplicity and rejected — its failure mode (rate above floor for days, order never fills) is the worst kind of invisible, and the shared machinery (index, dual walk, atomic release) meant it saved only ~half a day. True FOK-at-placement was also rejected: killing whatever can't fill immediately deletes resting entirely and reduces the feature to a slippage floor.

Within a pair, intents are examined **ascending by threshold** (least demanding first — book-style price priority), time-ordered within a threshold. An intent whose exact walk fails on depth (too big) must not block later, smaller intents — the pass continues to the `ρ_top` cutoff. Guard against park-at-market walk spam (thresholds forever ≤ `ρ_top`, walks forever failing): after a failed walk, re-walk only when the pair's `ρ_top` improves past the level that failed it, or after a short cooldown. Net cost per pass: O(dirty pairs) peeks + walks for intents genuinely near trigger + work proportional to actual fills — independent of the total resting count. The global cap (~2 000) becomes a memory guard, not a scaling necessity.

### Execution — atomic in one message

Mirror `releaseCrossSwap` (margin re-gate, sized sell leg, buy leg from available proceeds, stats/rolling24h, `adjustAffectedUsers`, `bumpUserVersion`) with the walked size and per-leg caps set to the **walked marginal prices**. Because the walk and both `executeMarketOrderProtected` calls run in ONE message with no awaits, nothing can interleave: what the walk saw is what execution gets — **no leg risk, no stranded-ICPUSD surprise, the floor holds exactly**.

The one correctness crux is **walk/execution parity**: extend `walkFillable` with the same exclusion rules execution applies — skip the owner's own makers (self-trade prevention cancels them rather than filling) and honor `isNonTakeable`. `quoteSwap` can share the upgraded walker (bonus honesty). Belt-and-braces: after fills, if realized net rate < floor (must be impossible), log a `warn` `[swap]` event — never silent.

On fill: `amountRemaining −= A`, `minToRemaining −= ` pro-rata (rounded up, favoring the user), `subReserved(owner, sellToken, A)`; delete when remaining < dust; `recordSwapOutcome` each release (AON intents fill whole and delete). Margin re-gate failure at release → **kill + refund + outcome notice** (matches today's market-path behavior; a resting order silently pinned by margin would be worse).

### Lifecycle

- **Cancel**: `cancelMySwap(id : Nat)` — owner-gated, `subReserved`, delete, outcome notice, `bumpUserVersion`. Update calls already refuse anonymous at inspect; `requireAuth` like siblings.
- **Expiry**: swept in the existing 5-min TTL heartbeat pass alongside `sweepStaleUserOrders` — refund + "expired unfilled" outcome.
- **Fees**: taker on both quote legs, at the owner's level **at release time** (disclose in docs; levels can drift while resting).

### Microstructure note — latent demand, not hidden depth

Resting intents are not invisible *depth*: depth is a resting willingness to be **hit** (maker side), and an intent rests on no book — it is conditional **taker** demand, the exact analog of a CEX stop book, which is invisible on every venue. Makers on the two ICPUSD books experience a triggered intent as ordinary taker flow; nobody is filled against something they couldn't see. Two real effects to own rather than deny: (1) **threshold clustering** — a ratio move can trip a cluster of intents in one pass, a two-legged taker burst (sell FROM, buy TO). The structure already bounds it: per-pass fills are capped by the protective band, the sealed GEPTOR clears in oracle-anchored bites so a cascade drains across passes instead of gapping the book, per-user/global caps bound the total, and what can't fill within the band simply keeps resting (self-limiting — no overhang cliff). (2) A marginal **maker-liquidity diversion**: an intent replaces what might have been two hand-managed book limits. If resting interest ever gets material, publish it in aggregate — per-pair, threshold-bucketed sums, an open-interest-style query — the way stop-heatmaps make latent flow legible. Transparency beats pretending the flow doesn't exist.

### Rejected alternatives

- *Two resting book orders at fixed leg prices*: over-constrained — either leg moving favorably should compensate the other; pinned prices miss those fills.
- *Sequential legs (rest sell, then place buy on fill)*: leaves the user holding ICPUSD mid-swap, second-leg drift, cascading partials. (Rejected in the 2026-07-08 assessment; still right.)
- *Native cross order books (ETH/BTC)*: fragments liquidity the single-quote architecture exists to concentrate.

## Surfacing

- `getMyRestingSwaps() : [RestingSwapView]` — id, tokens, remaining, floor, **implied rate now** (from refPrices, fee-adjusted), expiry.
- **Rate input, one idiom for every route.** The limit field stops being "Limit Price (ICPUSD)" — that label is only accidentally right for direct pairs (one leg IS ICPUSD, so the price *is* the from↔to ratio) and is meaningless for cross pairs, where the field currently still renders and then fails at submit. Replace it with a uniform exchange-ratio input, `1 {ASSET} = ___ {OTHER}`:
  - **Anchor on the non-ICPUSD asset for direct pairs** — "1 GLDT = ___ ICPUSD" whichever direction the swap runs. Numerically identical to today's limit price (and to the CLOB `limitPrice` the backend expects), so this is a relabel, not a semantics change.
  - **Anchor on FROM for cross pairs** — "1 GLDT = ___ ckBTC"; the form converts to `minToAmount = amount × rate`.
  - A **⇄ flip toggle** inverts the quoting direction; a "market now: X" line (from `quoteSwap`) prefills and shows signed distance ("+2.3% above market") — together these make the classic inverted-rate entry mistake self-evident.
  - **Fee honesty differs by route and the UI must say so**: a direct limit is a *pre-fee book price* (the resting remainder can fill as maker), so show "min received after fees (worst case, taker): Y"; a cross limit is a *net floor* — "you receive at least Y {TO} or it doesn't execute."
- **Rate history chart** (SHIPPED 2026-07-09 as its own box — Swap, Graph, Book/Trades — rather than a tab). Zero backend work: fetch `getCandles(FROM-ICPUSD, interval, 0)` and `getCandles(TO-ICPUSD, interval, 0)`, align buckets (bucket boundaries are the same wall-clock formula for every market), and plot `closeFROM / closeTO` as a **line** in the same anchoring as the rate input (flip toggle flips the chart). A line of per-bucket closes, NOT synthetic candles — dividing two OHLC series fabricates highs/lows (the extremes of two markets don't co-occur within a bucket), and this project doesn't draw made-up wicks. Direct pairs skip the division and can show the market's real candles (the existing mini-chart). The in-flight zero-volume candle fill is what makes this work on quiet markets — both series are gapless at oracle ref prices; genuinely missing buckets (downtime) stay honest gaps in the line. Label it "indicative rate (ref prices, before fees)": the user's net floor sits slightly below the plotted gross line by their fee. Overlay the entered limit rate as a horizontal price line so "where my order sits vs. history" is one glance; the resting-swaps list can reuse the same chart per intent later (polish).
- Swap page: Limit tab enabled for cross pairs; a **Resting swap orders** list under the box (rate distance + Cancel). Placement toast: "resting — fills when 1 X ≥ R Y (up to 30 days)"; skip the 24 s `watchSwapOutcome` poll for resting intents.
- Docs tab `#docs/swap`: replace the "name your price" overpromise with the real story — net-receive floor, taker fees both legs, both-fresh trigger, 30 d TTL, cancel anytime, and the manual per-market alternative.
- OQL (optional, cheap): `restingSwap` table, self-scoped rows, so the assistant can see and explain them.

## Ledger, conservation, upgrades

Fills journal automatically via the `setBalance` delta ledger; reservations are soft-locks (no balance moves), so PoR/replay are untouched. Conservation checks in the integration suite must add `restingSwaps` reservations to the reserved-sum invariant. Upgrade-safety rails (memory-verified): new top-level stable map only; **no** field adds to records in existing stable maps; **no** new `UserEventKind` tags (transit-queue type traps upgrades) — the event log's folded `[swap]` text tags carry lifecycle events.

## Test plan

Integration (sim): rests-above-market → oracle moves → atomic two-leg fill with realized net ≥ floor (assert exactly); treasury accrues 2 taker fees; AON never partially executes (walk falls short ⇒ intent keeps resting, book untouched); oversized intent warns at placement and never mis-fires; `noPartialFill = false` rejected; cancel refunds; expiry sweeps; margin-breach kill notices; per-user cap; conservation incl. reservations; **upgrade persistence** (place → upgrade → rests → fills). Sim gotchas that already burned us: `tr -d '_'` on CLI numerics, `pkill` the sim in teardown, shape books with limit takers + `release()` (market orders can't probe far levels).

## Plan of record — ship the UX slice now; build the engine on a demand signal

The scope call (2026-07-08): cross-market rate targeting is an **expert feature**. Slippage tolerance is not a substitute — slippage is *protection* ("no worse than now − 1%"), a limit is *targeting* ("this rate, maybe Thursday") — but the average user's comprehensible case ("buy BTC when it's $95k") is a direct-pair limit, which already works end to end. The complaint that motivated this design is a papercut: the Swap box *defaults* to a cross pair, where Limit errors out. Experts meanwhile have a workaround (two sequential direct limits, accepting leg risk). So ship the parts that serve everyone now; the engine is fully designed above and waits for evidence anyone wants it — users asking for cross limits, or cross-pair swap volume turning material.

**Now (~1 day, no engine):**

| Step | Scope | Status |
|---|---|---|
| A1 | ~~Friendly unavailable state for cross-pair Limit~~ → superseded: the Market/Limit toggle was **removed from the Swap box entirely** (market-only for now; the backend `#limitOrder` path is untouched and returns with the engine) | DONE 2026-07-09, v0.54 |
| A2 | Rate-input relabel for direct pairs (`1 {ASSET} = ___ ICPUSD`), market-now prefill + signed distance, min-received-after-fees line | moot while the Limit UI is out — ships with the engine's frontend phase |
| A3 | Rate history chart — shipped as its **own box** (Swap, Graph, Book/Trades — three equal columns on desktop, 2-col + spanning book on narrow landscape, stacked on mobile); line-of-closes with anchoring per the rate-input rule; 15m/1H/4H/1D; 60 s refresh on the clock-fill cadence | DONE 2026-07-09, v0.54 |

**On demand signal (the engine, as designed above):**

| Phase | Scope | Est. |
|---|---|---|
| 0 | Land the in-flight `walkFillable` + `quoteSwap` work (other session, uncommitted) — this design extends that walker | — |
| 1 | Backend: `#minReceive` variant, `restingSwaps` store + placement + trigger index + atomic release (partials default, opt-in AON), `cancelMySwap`, TTL sweep, `getMyRestingSwaps`, enumeration-site audit | 1.5–2 d |
| 2 | Frontend: cross Limit tab + resting-swaps panel, oversized-AON warning, outcome copy | 0.5–1 d |
| 3 | Docs page rewrite, OQL table, integration tests green | 0.5–1 d |
